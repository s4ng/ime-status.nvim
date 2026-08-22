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
-- Covers both Linux input methods, which do not share a bus: fcitx5 answers on
-- the session bus, ibus runs a *private* one whose address has to be found
-- first. So there are two connections here, and whichever daemon is actually
-- running wins; a machine with neither never dials at all.
--
-- The two are not symmetrical. fcitx5 declares no signal for "the current input
-- method changed", so it is polled -- cheaply, over a socket that is already
-- open. ibus emits GlobalEngineChanged on every switch, so it is not polled at
-- all: the value is pushed and a poll is a table read.

local M = {}

-- No OS guard here on purpose: backend.lua already picks this module by OS,
-- and leaving it OS-agnostic is what lets test/dbus_transport_spec.lua point it
-- at a fake bus on any machine. Without a session bus to find, it simply never
-- reports itself available.
local uv = vim.uv or vim.loop

local FCITX_NAME = "org.fcitx.Fcitx5"
local FCITX_PATH = "/controller"
local FCITX_IFACE = "org.fcitx.Fcitx.Controller1"

local IBUS_NAME = "org.freedesktop.IBus"
local IBUS_PATH = "/org/freedesktop/IBus"
local IBUS_IFACE = "org.freedesktop.IBus"

local BUS_NAME = "org.freedesktop.DBus"
local BUS_PATH = "/org/freedesktop/DBus"
local BUS_IFACE = "org.freedesktop.DBus"

local LE = string.byte("l") -- the byte order we announce, and therefore encode
local MSG_CALL, MSG_RETURN, MSG_SIGNAL = 1, 2, 4
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
      elseif code == F_MEMBER then
        m.member = v
      elseif code == F_IFACE then
        m.iface = v
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

-- ------------------------------------------------------------ address lookup

-- One socket out of a D-Bus address, which may list several separated by
-- semicolons. Returns the path and whether it is an abstract socket.
---@return string|nil path, boolean abstract
local function parse_addr(addr)
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
        return " " .. a, true
      end
    end
  end
  return nil, false
end

-- The session bus socket, where fcitx5 lives. DBUS_SESSION_BUS_ADDRESS is
-- authoritative; the systemd default is the fallback for shells that never got
-- the variable exported -- a GUI-launched Neovim, again.
---@return string|nil path, boolean abstract
local function bus_path()
  local addr = vim.env.DBUS_SESSION_BUS_ADDRESS
  if addr then
    local p, abstract = parse_addr(addr)
    if p then
      return p, abstract
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

-- --------------------------------------------------------- ibus value decoding

-- The engine name out of what ibus answers GetGlobalEngine with: a VARIANT
-- holding an IBusEngineDesc, whose signature is (sa{sv}ssssssssusssssss) and
-- whose third field is the name we want ("hangul", "xkb:us::eng").
--
-- Reaching it does not need a general unmarshaller. The two fields in the way
-- are a string, which carries its own length, and an a{sv}, which carries the
-- byte length of its contents -- so the dict can be *skipped* rather than
-- parsed, whatever ends up in it. That is the difference between the ~25 lines
-- here and a variant/dict reader the size of the rest of this file.
---@return string|nil
local function ibus_engine_name(body, le)
  local sig, i = get_sig(body, 1)
  -- Anything but a struct opening with a string means ibus changed the shape
  -- under us; better to report nothing than to read the wrong field.
  if not sig:match("^%(s") then
    return nil
  end
  i = align(i, 8) -- STRUCT
  local _, j = get_str(body, i, le) -- "IBusEngineDesc"
  j = align(j, 4)
  local len = get_u32(body, j, le)
  if not len then
    return nil
  end
  -- An array length is followed by padding to the element alignment -- 8 for a
  -- dict entry -- and that padding is there even when the array is empty,
  -- which in practice it always is.
  j = align(j + 4, 8) + len
  local name = get_str(body, j, le)
  return name ~= "" and name or nil
end

-- ------------------------------------------------------------------ transport

-- One connection to one bus. fcitx5 and ibus do not share a bus, so the plugin
-- keeps two of these. Each sits idle until something happens on it, and the one
-- whose daemon is absent never dials at all -- there is no address to dial.
--
-- `spec` supplies what differs between them: where to dial, whose name to
-- watch, which signals to ask for, and what to do once the daemon is there.
local function new_conn(spec)
  local c = {
    -- idle       nothing open; ensure() may dial once retry_at has passed
    -- connecting socket open, handshake in flight
    -- waiting    connected and subscribed, but the daemon does not own its
    --            name. A definite answer, not a transient one: we sit on the
    --            open socket and let NameOwnerChanged say when that changes,
    --            instead of re-dialling and re-handshaking every RETRY_MS.
    -- ready      the daemon is there and answering
    state = "idle",
    pipe = nil,
    buf = "",
    auth = true, -- still in the text (SASL) phase
    serial = 0,
    pending = {}, -- serial -> { cb, timer }
    getting = false, -- one poll already in flight
    retry_at = 0,
    cache = nil, -- last value a signal pushed, for providers that get one
    spec = spec,
  }

  -- Answer one in-flight call exactly once and release its timer.
  local function finish(serial, msg)
    local p = c.pending[serial]
    if not p then
      return
    end
    c.pending[serial] = nil
    p.timer:stop()
    p.timer:close()
    p.cb(msg)
  end

  -- Drop the connection and fail every in-flight call, so a socket that died
  -- cannot leave a caller waiting forever. `cooldown` holds off the next try.
  local function reset(cooldown)
    local pipe = c.pipe
    c.pipe = nil
    if pipe then
      pcall(pipe.read_stop, pipe)
      pcall(pipe.close, pipe)
    end
    for serial in pairs(c.pending) do
      finish(serial, nil)
    end
    c.buf, c.auth, c.serial, c.getting, c.cache = "", true, 0, false, nil
    c.state = "idle"
    c.retry_at = now_ms() + (cooldown or 0)
  end
  c.reset = reset

  ---@param args string[]
  ---@param cb fun(reply:table|nil)
  local function call(dest, path, iface, member, args, cb)
    if not c.pipe then
      cb(nil)
      return
    end
    c.serial = c.serial + 1
    local serial = c.serial
    local timer = uv.new_timer()
    c.pending[serial] = { cb = cb, timer = timer }
    timer:start(CALL_TIMEOUT, 0, function()
      finish(serial, nil)
    end)
    local ok = pcall(function()
      c.pipe:write(encode_call(serial, dest, path, iface, member, args), function(err)
        if err then
          finish(serial, nil)
        end
      end)
    end)
    if not ok then
      finish(serial, nil)
    end
  end
  c.call = call

  -- The daemon appearing on or leaving the bus. NameOwnerChanged carries
  -- (name, old_owner, new_owner), and the match rule pins arg0 to the name we
  -- watch, so only the new owner matters -- empty means it just left. This is
  -- what turns "start the daemon, wait up to RETRY_MS for a re-probe" into
  -- "start the daemon, the next redraw has it".
  local function on_signal(m)
    if m.iface == BUS_IFACE and m.member == "NameOwnerChanged" then
      local _, i = get_str(m.body, 1, m.le) -- the name, already known from arg0
      local _, j = get_str(m.body, i, m.le) -- previous owner, not ours to care about
      local owner = get_str(m.body, j, m.le)
      if owner and owner ~= "" then
        c.state = "ready"
        if spec.on_ready then
          spec.on_ready(c)
        end
      else
        c.state, c.cache = "waiting", nil
      end
      return
    end
    if spec.on_signal then
      spec.on_signal(c, m)
    end
  end

  -- Register with the bus, subscribe, then decide whether this backend can
  -- serve at all. The rules go on one at a time because each is a round trip
  -- and the probe must not run until every one of them is in place.
  local function hello()
    call(BUS_NAME, BUS_PATH, BUS_IFACE, "Hello", {}, function(m)
      if not m then
        return reset(RETRY_MS)
      end
      local n = 0
      local function next_rule()
        n = n + 1
        if n > #spec.rules then
          -- Ask the bus who owns the name rather than calling the daemon to see
          -- what happens: it is one round trip, it cannot auto-start an input
          -- method, and a "no" here is what lets backend.lua fall back.
          return call(BUS_NAME, BUS_PATH, BUS_IFACE, "NameHasOwner", { spec.name }, function(r)
            -- BOOLEAN travels as a u32.
            if r and get_u32(r.body, 1, r.le) == 1 then
              c.state = "ready"
              if spec.on_ready then
                spec.on_ready(c)
              end
            else
              c.state = "waiting"
            end
          end)
        end
        -- Subscribe *before* probing. The other order has a hole: a daemon that
        -- starts between the probe and the subscription is missed entirely, and
        -- nothing would ever come along to correct it.
        call(BUS_NAME, BUS_PATH, BUS_IFACE, "AddMatch", { spec.rules[n] }, function(added)
          if not added then
            return reset(RETRY_MS)
          end
          next_rule()
        end)
      end
      next_rule()
    end)
  end

  local function on_read(err, chunk)
    if err or not chunk then
      reset(RETRY_MS) -- EOF: the bus went away
      return
    end
    c.buf = c.buf .. chunk

    if c.auth then
      -- The SASL phase is line based; everything after the OK line is binary.
      local line, rest = c.buf:match("^(.-)\r\n(.*)$")
      if not line then
        return
      end
      if not line:match("^OK") then
        reset(RETRY_MS) -- REJECTED / ERROR: nothing here can fix that
        return
      end
      c.buf, c.auth = rest, false
      pcall(function()
        c.pipe:write("BEGIN\r\n")
      end)
      hello()
    end

    while true do
      local total = frame_len(c.buf)
      if not total or #c.buf < total then
        break
      end
      local msg = decode(c.buf:sub(1, total))
      c.buf = c.buf:sub(total + 1)
      if msg then
        if msg.reply_serial then
          finish(msg.reply_serial, msg.type == MSG_RETURN and msg or nil)
        elseif msg.type == MSG_SIGNAL then
          on_signal(msg)
        end
      end
    end
  end

  local function connect()
    local path, abstract = spec.address()
    if not path or (abstract and not uv.pipe_connect2) then
      -- No bus, or an abstract address on a Neovim too old for connect2
      -- (luv < 1.46). Either way: nothing to talk to, try again later.
      c.state = "idle"
      c.retry_at = now_ms() + RETRY_MS
      return
    end
    local pipe = uv.new_pipe(false)
    c.pipe = pipe
    c.state = "connecting"
    local function connected(cerr)
      if cerr or c.pipe ~= pipe then
        return reset(RETRY_MS)
      end
      pipe:read_start(on_read)
      -- SASL EXTERNAL: the kernel already told the bus our uid over the socket,
      -- so "authenticating" is just naming it -- as the hex of its decimal
      -- spelling, after the NUL byte the protocol opens with.
      local uid = tostring(uv.getuid and uv.getuid() or 0)
      local hex = uid:gsub(".", function(ch)
        return ("%02x"):format(ch:byte())
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

  function c.ensure()
    if c.state ~= "idle" or now_ms() < c.retry_at then
      return
    end
    connect()
  end

  return c
end

-- ------------------------------------------------------------------ providers

-- Ask the bus to forward just the signals we act on. arg0 narrows a
-- NameOwnerChanged to the one name we watch, so the daemon filters for us and a
-- busy session bus costs us nothing.
local function owner_rule(name)
  return table.concat({
    "type='signal'",
    "sender='" .. BUS_NAME .. "'",
    "path='" .. BUS_PATH .. "'",
    "interface='" .. BUS_IFACE .. "'",
    "member='NameOwnerChanged'",
    "arg0='" .. name .. "'",
  }, ",")
end

local fcitx5 = {
  id = "fcitx5",
  -- fcitx5 calls its latin input method "keyboard-us"; ibus calls the same
  -- thing "xkb:us::eng", and handing one the other's id is a silent no-op.
  latin = "keyboard-us",
}
fcitx5.conn = new_conn({
  name = FCITX_NAME,
  address = bus_path,
  rules = { owner_rule(FCITX_NAME) },
})

-- fcitx5 has no signal for "the current input method changed" -- its
-- Controller1 declares exactly one signal, InputMethodGroupsChanged, which is
-- about groups. So this one still asks, once per poll, over a connection that
-- is already open.
function fcitx5.get(cb)
  local c = fcitx5.conn
  if c.getting then
    return
  end
  c.getting = true
  c.call(FCITX_NAME, FCITX_PATH, FCITX_IFACE, "CurrentInputMethod", {}, function(m)
    c.getting = false
    if not m then
      -- On the bus but not answering: drop the connection so the next polls
      -- re-probe instead of timing out one by one.
      c.reset(RETRY_MS)
      cb(nil)
      return
    end
    cb((get_str(m.body, 1, m.le)))
  end)
end

function fcitx5.set(id, done)
  fcitx5.conn.call(FCITX_NAME, FCITX_PATH, FCITX_IFACE, "SetCurrentIM", { id }, done)
end

-- ibus is not on the session bus. Its address is in $IBUS_ADDRESS, or in a file
-- under ~/.config/ibus/bus/ named <machine-id>-<hostname>-<display>.
--
-- Rather than rebuild that name -- three lookups, each with its own way of
-- being wrong, and two files on a machine that has both an X and a Wayland
-- display -- read whatever is in the directory and take the first entry whose
-- socket actually exists. A daemon that exited leaves its file behind with an
-- empty IBUS_ADDRESS=, and a daemon that was replaced leaves a path that no
-- longer resolves; both fall out of that check for free.
---@return string|nil path, boolean abstract
local function ibus_path()
  -- An abstract socket cannot be stat()ed, so it is taken on trust and the
  -- connect is left to fail if it is gone. A path can be checked, and is:
  -- ibus names its socket after the daemon instance, so a stale one is a file
  -- that still exists with nothing behind it.
  local function usable(addr)
    if not addr or addr == "" then
      return nil, false
    end
    local path, abstract = parse_addr(addr)
    if path and (abstract or uv.fs_stat(path)) then
      return path, abstract
    end
    return nil, false
  end

  -- $IBUS_ADDRESS wins, but only while it still names something. Inheriting a
  -- variable that outlived its daemon is ordinary -- a shell opened before the
  -- last restart has one -- and the file on disk is then the *newer* answer, so
  -- a dead variable falls through to it rather than pinning us to a corpse.
  local path, abstract = usable(vim.env.IBUS_ADDRESS)
  if path then
    return path, abstract
  end

  local home = vim.env.XDG_CONFIG_HOME
  home = (home and home ~= "" and home) or ((vim.env.HOME or "") .. "/.config")
  local dir = home .. "/ibus/bus"
  local fd = uv.fs_scandir(dir)
  if not fd then
    return nil, false
  end
  while true do
    local entry = uv.fs_scandir_next(fd)
    if not entry then
      return nil, false
    end
    local f = io.open(dir .. "/" .. entry, "r")
    if f then
      local text = f:read("*a") or ""
      f:close()
      -- The file opens with comment lines, so match the assignment, not line 1.
      -- A daemon that exited leaves the file behind with an empty value.
      path, abstract = usable(text:match("IBUS_ADDRESS=([^\n\r]*)"))
      if path then
        return path, abstract
      end
    end
  end
end

local ibus = {
  id = "ibus",
  latin = "xkb:us::eng",
}
ibus.conn = new_conn({
  name = IBUS_NAME,
  address = ibus_path,
  rules = {
    owner_rule(IBUS_NAME),
    table.concat({
      "type='signal'",
      "sender='" .. IBUS_NAME .. "'",
      "path='" .. IBUS_PATH .. "'",
      "interface='" .. IBUS_IFACE .. "'",
      "member='GlobalEngineChanged'",
    }, ","),
  },
  -- The initial value is the only thing that needs the variant unpacked; every
  -- change after it arrives as a plain string on GlobalEngineChanged.
  on_ready = function(c)
    c.call(IBUS_NAME, IBUS_PATH, IBUS_IFACE, "GetGlobalEngine", {}, function(m)
      -- An error reply here is ordinary, not a fault: a freshly started daemon
      -- with nothing selected answers "No global engine." Leave the cache empty
      -- and let the first switch fill it.
      c.cache = m and ibus_engine_name(m.body, m.le) or nil
    end)
  end,
  on_signal = function(c, m)
    if m.iface == IBUS_IFACE and m.member == "GlobalEngineChanged" then
      c.cache = get_str(m.body, 1, m.le)
    end
  end,
})

-- No round trip: ibus pushes every change, so a poll is a table read. This is
-- what the polling interval costs on ibus once the subscription is up.
function ibus.get(cb)
  cb(ibus.conn.cache)
end

function ibus.set(id, done)
  ibus.conn.call(IBUS_NAME, IBUS_PATH, IBUS_IFACE, "SetGlobalEngine", { id }, done)
end

-- Order is preference. A machine running both is unusual and nothing on either
-- bus says which one the terminal is actually talking to, so the tie is broken
-- the same way every time rather than cleverly.
local PROVIDERS = { fcitx5, ibus }

---@return table|nil
local function active()
  for _, p in ipairs(PROVIDERS) do
    if p.conn.state == "ready" then
      return p
    end
  end
  return nil
end

-- ----------------------------------------------------------------- public API

-- True once a handshake finished *and* that daemon owns its bus name. False
-- while connecting, which is why it kicks the state machines on the way out:
-- the first poll starts the connections, a later one finds one ready.
---@return boolean
function M.available()
  -- Every provider gets kicked, not just until one answers. Warming the standby
  -- connection is what makes the hand-over instant when the preferred daemon
  -- exits -- and it is nearly free: ensure() returns immediately unless the
  -- connection is idle and past its backoff, and a machine without the second
  -- daemon has no address to dial, so it never opens a socket at all.
  for _, p in ipairs(PROVIDERS) do
    p.conn.ensure()
  end
  return active() ~= nil
end

-- Which daemon is answering: "fcitx5", "ibus", or nil. backend.lua needs it
-- because the two do not share an id vocabulary for the latin input method.
---@return string|nil
function M.provider()
  local p = active()
  return p and p.id
end

-- The id this provider calls its latin/english input method.
---@return string|nil
function M.latin()
  local p = active()
  return p and p.latin
end

-- Fetch the current input method name ("hangul", "keyboard-us", "xkb:us::eng").
--
-- Staying silent is deliberate for the transient cases -- not connected yet, or
-- a poll still in flight. The caller renders nil as `unknown`, and a "?"
-- blinking through the statusline whenever a reply is late is worse than
-- showing the previous label one tick longer. Real failures answer nil.
---@param cb fun(raw:string|nil)
function M.get_async(cb)
  local p = active()
  if p then
    return p.get(cb)
  end
  M.available() -- nothing ready; keep the state machines turning
  for _, q in ipairs(PROVIDERS) do
    if q.conn.state == "waiting" then
      -- Connected, and the bus says the daemon is not here. That is an answer,
      -- not a transient miss, so give it: otherwise a daemon that exits
      -- mid-session leaves the label frozen on whatever it last reported.
      cb(nil)
      return
    end
  end
end

-- Switch the input method. `cb` always runs exactly once, success or not, so
-- the caller's follow-up refresh cannot be lost.
---@param id string
---@param cb fun()|nil
function M.set_async(id, cb)
  local done = cb or function() end
  local p = active()
  if not p then
    M.available()
    done()
    return
  end
  p.set(id, done)
end

-- Backs :IMEStatusReload -- reconnect now rather than after the backoff.
function M.reload()
  for _, p in ipairs(PROVIDERS) do
    p.conn.reset(0)
  end
end

-- Why a backend is not serving, for :checkhealth. Separates the cases that look
-- identical from the outside -- the label just never changes -- but need
-- opposite fixes. `which` is "fcitx5" (the default) or "ibus".
---@param which string|nil
---@return "ready"|"no_bus"|"stale_bus"|"unreachable"|"no_daemon"
function M.diagnose(which)
  local p = (which == "ibus") and ibus or fcitx5
  if p.conn.state == "ready" then
    return "ready"
  end
  local path, abstract = p.conn.spec.address()
  if not path then
    return "no_bus"
  end
  -- An abstract address is named by a leading NUL, so connecting to it needs
  -- uv_pipe_connect2 (luv 1.46 / Neovim 0.10). Older builds can *find* the bus
  -- and still never reach it: the one case where the external tool is not a
  -- workaround but the only way in.
  if abstract and not uv.pipe_connect2 then
    return "unreachable"
  end
  -- The variable outliving the daemon is the normal state of a WSL shell, a
  -- bare TTY or a container: the address is inherited but nothing is listening.
  -- Indistinguishable from "the daemon is not running" at the socket, and the
  -- two send the user to opposite fixes, so separate them here.
  if not abstract and not uv.fs_stat(path) then
    return "stale_bus"
  end
  return "no_daemon"
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
  ibus_path = ibus_path,
  ibus_engine_name = ibus_engine_name,
}

return M
