-- Native Linux backend: speaks the D-Bus wire protocol straight to fcitx5 over
-- the session bus, replacing the fcitx5-remote fork+exec on every poll.
--
-- Why a wire-protocol implementation rather than an API call: Linux has no
-- OS-level input-source API to FFI into. X11's XIM only ever describes *your
-- own* input context, and Wayland's text-input protocols only the focused
-- surface -- which, for Neovim in a terminal, belongs to the terminal. The one
-- component that knows the global state is the IME daemon, and it answers on
-- D-Bus. fcitx5-remote is a thin wrapper around the single call this module
-- makes:
--
--   org.fcitx.Fcitx5 /controller org.fcitx.Fcitx.Controller1.CurrentInputMethod
--
-- so spawning it three times a second only buys us the marshalling, which is
-- the 80 lines below. Doing it in-process also drops the PATH dependency --
-- the failure mode of GUI-launched Neovim, which never reads your shell rc.
--
-- No FFI: everything here is plain Lua over a vim.uv pipe, so it works on
-- LuaJIT-less builds too. Unlike the macOS/Windows backends the calls are
-- asynchronous, which is why this module exposes get_async/set_async rather
-- than get/set.
--
-- Scope: fcitx5 only. ibus lives on a *private* bus whose address has to be
-- dug out of ~/.config/ibus/bus/<machine-id>-<host>-<display>, usually on an
-- abstract socket, and answers GetGlobalEngine with a serialised
-- IBusEngineDesc struct instead of a plain string. ibus users keep the
-- external `ibus` CLI, which backend.lua still resolves whenever available()
-- here says no.

local M = {}

-- No OS guard here on purpose: backend.lua already picks this module by OS,
-- and leaving it OS-agnostic is what lets test/dbus_transport_spec.lua point it
-- at a fake bus on any machine. Without a session bus to find, it simply never
-- reports itself available.
local uv = vim.uv or vim.loop

local FCITX_NAME = "org.fcitx.Fcitx5"
local FCITX_PATH = "/controller"
local FCITX_IFACE = "org.fcitx.Fcitx.Controller1"

local BUS_NAME = "org.freedesktop.DBus"
local BUS_PATH = "/org/freedesktop/DBus"
local BUS_IFACE = "org.freedesktop.DBus"

local LE = string.byte("l") -- the byte order we announce, and therefore encode
local MSG_CALL, MSG_RETURN = 1, 2
-- Header field codes (D-Bus spec 4.1): only the ones we send or read.
local F_PATH, F_IFACE, F_MEMBER, F_ERROR, F_REPLY_SERIAL, F_DEST, F_SIG = 1, 2, 3, 4, 5, 6, 8
-- fcitx5 ships a D-Bus activation file, so an ordinary method call would
-- *start* an input method just because a statusline polled. NO_AUTO_START
-- turns that into an error reply, which is what we actually want to hear.
local NO_AUTO_START = 0x02

-- A reply that never comes must not pin a callback forever; 1s is far beyond
-- any local round trip (sub-millisecond) yet short enough to recover within a
-- couple of poll ticks.
local CALL_TIMEOUT = 1000
-- Backoff after a failed connect or probe, mirroring backend.lua's tool retry:
-- starting fcitx5 mid-session recovers on its own, without a restart.
local RETRY_MS = 5000

local function now_ms()
  return uv.hrtime() / 1e6
end

-- ---------------------------------------------------------------- marshalling

-- Every D-Bus type has an alignment (u32 4, string 4 because of its u32 length
-- prefix, struct 8) and the padding bytes must be zero, so the encoder tracks
-- the running byte offset instead of just concatenating.
local Enc = {}
Enc.__index = Enc

local function enc()
  return setmetatable({ buf = {}, n = 0 }, Enc)
end

function Enc:raw(s)
  self.buf[#self.buf + 1] = s
  self.n = self.n + #s
end

function Enc:pad(align)
  local r = self.n % align
  if r ~= 0 then
    self:raw(string.rep("\0", align - r))
  end
end

function Enc:byte(b)
  self:raw(string.char(b))
end

-- LuaJIT is Lua 5.1, which has no string.pack, so u32 is spelled out.
function Enc:u32(v)
  self:pad(4)
  self:raw(string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256))
end

-- STRING / OBJECT_PATH: u32 length, the bytes, then a NUL it does not count.
function Enc:str(s)
  self:u32(#s)
  self:raw(s)
  self:byte(0)
end

-- SIGNATURE: the same shape with a single length byte, since it is <= 255.
function Enc:sig(s)
  self:byte(#s)
  self:raw(s)
  self:byte(0)
end

function Enc:done()
  return table.concat(self.buf)
end

-- One (BYTE, VARIANT) header field. Fields are struct-typed, so each one
-- starts on an 8 byte boundary.
local function put_field(e, code, type_char, value)
  e:pad(8)
  e:byte(code)
  e:sig(type_char)
  if type_char == "g" then
    e:sig(value)
  else -- "s" and "o" share their layout
    e:str(value)
  end
end

-- A METHOD_CALL carrying zero or more string arguments -- the only shape this
-- plugin ever sends.
---@param serial integer
---@param args string[]
---@return string
local function encode_call(serial, dest, path, iface, member, args)
  local body = enc()
  for _, a in ipairs(args) do
    body:str(a)
  end
  body = body:done()

  -- The field array starts at offset 16, a multiple of 8, so encoding it
  -- standalone gives exactly the padding it will have in place.
  local fields = enc()
  put_field(fields, F_PATH, "o", path)
  put_field(fields, F_DEST, "s", dest)
  put_field(fields, F_IFACE, "s", iface)
  put_field(fields, F_MEMBER, "s", member)
  if #args > 0 then
    put_field(fields, F_SIG, "g", string.rep("s", #args))
  end
  fields = fields:done()

  local m = enc()
  m:byte(LE)
  m:byte(MSG_CALL)
  m:byte(NO_AUTO_START)
  m:byte(1) -- protocol version
  m:u32(#body)
  m:u32(serial)
  m:u32(#fields)
  m:raw(fields)
  m:pad(8) -- the body always starts on an 8 byte boundary
  m:raw(body)
  return m:done()
end

-- Reading is the mirror image. Offsets are 1-based Lua string indices, so an
-- alignment of n lands where (i - 1) % n == 0.
local function align(i, n)
  local r = (i - 1) % n
  return r == 0 and i or i + (n - r)
end

local function get_u32(s, i, le)
  local a, b, c, d = s:byte(i, i + 3)
  if not d then
    return nil
  end
  if not le then
    a, b, c, d = d, c, b, a
  end
  return a + b * 256 + c * 65536 + d * 16777216
end

-- STRING / OBJECT_PATH at `i`; also returns the index just past its NUL.
local function get_str(s, i, le)
  i = align(i, 4)
  local len = get_u32(s, i, le)
  if not len then
    return nil, i
  end
  return s:sub(i + 4, i + 3 + len), i + 4 + len + 1
end

local function get_sig(s, i)
  local len = s:byte(i) or 0
  return s:sub(i + 1, i + len), i + 1 + len + 1
end

-- Total on-the-wire size of the message at the head of `s`, plus where its
-- body starts (0-based) and its byte order. nil while too few bytes have
-- arrived to tell -- the socket hands us arbitrary slices, not messages.
---@return integer|nil total, integer|nil body_off, boolean|nil le
local function frame_len(s)
  if #s < 16 then
    return nil
  end
  local le = s:byte(1) == LE
  local body_len = get_u32(s, 5, le)
  local fields_len = get_u32(s, 13, le)
  local body_off = 16 + fields_len
  body_off = body_off + (8 - body_off % 8) % 8
  return body_off + body_len, body_off, le
end

-- Split one complete message into the three things we ever care about: what
-- kind it is, which call it answers, and its body.
---@return table|nil
local function decode(msg)
  local total, body_off, le = frame_len(msg)
  if not total then
    return nil
  end
  local m = { type = msg:byte(2), le = le, body = msg:sub(body_off + 1) }
  local i = 17
  local stop = 17 + get_u32(msg, 13, le)
  while i < stop do
    i = align(i, 8)
    if i >= stop then
      break
    end
    local code = msg:byte(i)
    local sig
    sig, i = get_sig(msg, i + 1)
    if sig == "s" or sig == "o" then
      local v
      v, i = get_str(msg, i, le)
      if code == F_ERROR then
        m.error = v
      end
    elseif sig == "g" then
      local _
      _, i = get_sig(msg, i)
    elseif sig == "u" then
      i = align(i, 4)
      if code == F_REPLY_SERIAL then
        m.reply_serial = get_u32(msg, i, le)
      end
      i = i + 4
    else
      -- A field we cannot measure hides where the next one starts, so the
      -- whole message becomes unreadable rather than quietly misread.
      return nil
    end
  end
  return m
end

-- ------------------------------------------------------------------ transport

local conn = {
  state = "idle", -- idle | connecting | ready
  pipe = nil,
  buf = "",
  auth = true, -- still in the text (SASL) phase
  serial = 0,
  pending = {}, -- serial -> { cb, timer }
  getting = false, -- one poll already in flight
  retry_at = 0,
}

local ensure, hello

-- The session bus socket. DBUS_SESSION_BUS_ADDRESS is authoritative and may
-- list several addresses; the systemd default is the fallback for shells that
-- never got the variable exported -- a GUI-launched Neovim, again.
---@return string|nil path, boolean abstract
local function bus_path()
  local addr = vim.env.DBUS_SESSION_BUS_ADDRESS
  if addr then
    for part in addr:gmatch("[^;]+") do
      if part:match("^unix:") then
        local p = part:match("[,:]path=([^,]*)")
        if p and p ~= "" then
          return p, false
        end
        -- Abstract sockets are named by a leading NUL, which uv_pipe_connect
        -- would cut the name at; connect2 takes an explicit length instead.
        local a = part:match("[,:]abstract=([^,]*)")
        if a and a ~= "" then
          return "\0" .. a, true
        end
      end
    end
  end
  local uid = uv.getuid and uv.getuid()
  if uid then
    local p = ("/run/user/%d/bus"):format(uid)
    if uv.fs_stat(p) then
      return p, false
    end
  end
  return nil, false
end

-- Answer one in-flight call exactly once and release its timer.
local function finish(serial, msg)
  local p = conn.pending[serial]
  if not p then
    return
  end
  conn.pending[serial] = nil
  p.timer:stop()
  p.timer:close()
  p.cb(msg)
end

-- Drop the connection and fail every in-flight call, so a socket that died
-- cannot leave a caller waiting forever. `cooldown` holds off the next attempt.
local function reset(cooldown)
  local pipe = conn.pipe
  conn.pipe = nil
  if pipe then
    pcall(pipe.read_stop, pipe)
    pcall(pipe.close, pipe)
  end
  for serial in pairs(conn.pending) do
    finish(serial, nil)
  end
  conn.buf, conn.auth, conn.serial, conn.getting = "", true, 0, false
  conn.state = "idle"
  conn.retry_at = now_ms() + (cooldown or 0)
end

---@param args string[]
---@param cb fun(reply:table|nil)
local function call(dest, path, iface, member, args, cb)
  if not conn.pipe then
    cb(nil)
    return
  end
  conn.serial = conn.serial + 1
  local serial = conn.serial
  local timer = uv.new_timer()
  conn.pending[serial] = { cb = cb, timer = timer }
  timer:start(CALL_TIMEOUT, 0, function()
    finish(serial, nil)
  end)
  local ok = pcall(function()
    conn.pipe:write(encode_call(serial, dest, path, iface, member, args), function(err)
      if err then
        finish(serial, nil)
      end
    end)
  end)
  if not ok then
    finish(serial, nil)
  end
end

local function on_read(err, chunk)
  if err or not chunk then
    reset(RETRY_MS) -- EOF: the bus went away
    return
  end
  conn.buf = conn.buf .. chunk

  if conn.auth then
    -- The SASL phase is line based; everything after the OK line is binary.
    local line, rest = conn.buf:match("^(.-)\r\n(.*)$")
    if not line then
      return
    end
    if not line:match("^OK") then
      reset(RETRY_MS) -- REJECTED / ERROR: nothing here can fix that
      return
    end
    conn.buf, conn.auth = rest, false
    pcall(function()
      conn.pipe:write("BEGIN\r\n")
    end)
    hello()
  end

  while true do
    local total = frame_len(conn.buf)
    if not total or #conn.buf < total then
      break
    end
    local msg = decode(conn.buf:sub(1, total))
    conn.buf = conn.buf:sub(total + 1)
    -- Anything without a reply serial is a broadcast signal we never asked for.
    if msg and msg.reply_serial then
      finish(msg.reply_serial, msg.type == MSG_RETURN and msg or nil)
    end
  end
end

-- Register with the bus, then decide whether this backend can serve at all.
function hello()
  call(BUS_NAME, BUS_PATH, BUS_IFACE, "Hello", {}, function(m)
    if not m then
      return reset(RETRY_MS)
    end
    -- Ask the bus who owns the name rather than calling fcitx5 to see what
    -- happens: it is one round trip, it cannot auto-start an input method, and
    -- a "no" here is what lets backend.lua fall back to the ibus CLI.
    call(BUS_NAME, BUS_PATH, BUS_IFACE, "NameHasOwner", { FCITX_NAME }, function(r)
      -- BOOLEAN travels as a u32.
      if r and get_u32(r.body, 1, r.le) == 1 then
        conn.state = "ready"
      else
        reset(RETRY_MS)
      end
    end)
  end)
end

local function connect()
  local path, abstract = bus_path()
  if not path or (abstract and not uv.pipe_connect2) then
    -- No bus, or an abstract address on a Neovim too old for connect2
    -- (luv < 1.46). Either way: nothing to talk to, try again later.
    conn.state = "idle"
    conn.retry_at = now_ms() + RETRY_MS
    return
  end
  local pipe = uv.new_pipe(false)
  conn.pipe = pipe
  conn.state = "connecting"
  local function connected(cerr)
    if cerr or conn.pipe ~= pipe then
      return reset(RETRY_MS)
    end
    pipe:read_start(on_read)
    -- SASL EXTERNAL: the kernel already told the bus our uid over the socket,
    -- so "authenticating" is just naming it -- as the hex of its decimal
    -- spelling, after the NUL byte the protocol opens with.
    local uid = tostring(uv.getuid and uv.getuid() or 0)
    local hex = uid:gsub(".", function(c)
      return ("%02x"):format(c:byte())
    end)
    pcall(function()
      pipe:write("\0AUTH EXTERNAL " .. hex .. "\r\n")
    end)
  end
  local ok = pcall(function()
    if abstract then
      pipe:connect2(path, nil, connected)
    else
      pipe:connect(path, connected)
    end
  end)
  if not ok then
    reset(RETRY_MS)
  end
end

function ensure()
  if conn.state ~= "idle" or now_ms() < conn.retry_at then
    return
  end
  connect()
end

-- ----------------------------------------------------------------- public API

-- True once the handshake finished *and* fcitx5 owns its bus name. False while
-- connecting, which is why it kicks the state machine on the way out: the
-- first poll starts the connection, a later one finds it ready.
---@return boolean
function M.available()
  if conn.state == "ready" then
    return true
  end
  ensure()
  return false
end

-- Fetch the current input method name ("hangul", "keyboard-us", ...).
--
-- Staying silent is deliberate for the two transient cases -- not connected
-- yet, or a poll still in flight. The caller renders nil as `unknown`, and a
-- "?" blinking through the statusline whenever a reply is late is worse than
-- showing the previous label one tick longer. Real failures (error reply,
-- timeout) do answer nil.
---@param cb fun(raw:string|nil)
function M.get_async(cb)
  if conn.state ~= "ready" then
    ensure()
    return
  end
  if conn.getting then
    return
  end
  conn.getting = true
  call(FCITX_NAME, FCITX_PATH, FCITX_IFACE, "CurrentInputMethod", {}, function(m)
    conn.getting = false
    if not m then
      -- fcitx5 stopped answering; drop the connection so the next polls
      -- re-probe instead of timing out one by one.
      reset(RETRY_MS)
      cb(nil)
      return
    end
    cb((get_str(m.body, 1, m.le)))
  end)
end

-- Switch the input method. `cb` always runs exactly once, success or not, so
-- the caller's follow-up refresh cannot be lost.
---@param id string
---@param cb fun()|nil
function M.set_async(id, cb)
  local done = cb or function() end
  if conn.state ~= "ready" then
    ensure()
    done()
    return
  end
  call(FCITX_NAME, FCITX_PATH, FCITX_IFACE, "SetCurrentIM", { id }, done)
end

-- Backs :IMEStatusReload -- reconnect now rather than after the backoff.
function M.reload()
  reset(0)
end

-- Exposed for test/dbus_spec.lua: the codec is the half that can be checked
-- without a running bus.
M._codec = {
  encode_call = encode_call,
  decode = decode,
  frame_len = frame_len,
  get_str = get_str,
  get_u32 = get_u32,
  bus_path = bus_path,
}

return M
