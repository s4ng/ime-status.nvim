-- Transport checks for the native Linux backend, against a fake bus. Run:
--   nvim --headless -l test/dbus_transport_spec.lua
--
-- Runs on any OS: the "bus" is a uv pipe this file listens on, replaying the
-- exact bytes dbus-daemon sent during the capture session that produced
-- test/dbus_spec.lua. The codec spec proves we can read a message; this one
-- proves we can survive a *stream* — an unsolicited signal arriving between a
-- request and its reply, two messages landing in one read, a reply split
-- across two — which is where a hand-written client actually breaks.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local uv = vim.uv or vim.loop
local dbus = require("ime-status.dbus_linux")

local function unhex(s)
  return (s:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

-- Replies as captured, in the order this client asks for them: the serials
-- below (1, 2, 3) are the ones it really sends.
local REPLY_HELLO = unhex("6c02010109000000010000003d00000006017300040000003a312e3300000000050175000100"
  .. "0000080167000173000007017300140000006f72672e667265656465736b746f702e4442757300000000040000003a312e3300")
local SIGNAL_NAMEACQUIRED = unhex("6c0401010a000000020000008d00000001016f00150000002f6f72672f66726565646573"
  .. "6b746f702f4442757300000002017300140000006f72672e667265656465736b746f702e4442757300000000030173000c00"
  .. "00004e616d6541637175697265640000000006017300050000003a312e3531000000080167000173000007017300140000006f"
  .. "72672e667265656465736b746f702e4442757300000000050000003a312e353100")
local REPLY_NAMEHASOWNER = unhex("6c02010104000000030000003d00000006017300040000003a312e33000000000501750002"
  .. "000000080167000162000007017300140000006f72672e667265656465736b746f702e444275730000000001000000")
local REPLY_CURRENTIM = unhex("6c0201010b000000030000002d00000006017300040000003a312e33000000000501750003000"
  .. "000080167000173000007017300040000003a312e31000000000600000068616e67756c00")

local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local sock = is_win and ([[\\.\pipe\ime-status-test-%d]]):format(uv.os_getpid()) or vim.fn.tempname()

-- ------------------------------------------------------------------ fake bus

local server = uv.new_pipe(false)
assert(server:bind(sock))

local log = {}
server:listen(4, function(err)
  assert(not err, tostring(err))
  local client = uv.new_pipe(false)
  server:accept(client)
  local buf, authed, frames = "", false, 0
  client:read_start(function(rerr, chunk)
    if rerr or not chunk then
      return
    end
    buf = buf .. chunk
    if not authed then
      local line, rest = buf:match("^(.-)\r\n(.*)$")
      if not line then
        return
      end
      log.auth = line
      buf, authed = rest, true
      client:write("OK 0123456789abcdef0123456789abcdef\r\n")
    end
    -- BEGIN closes the text phase; everything after it is binary, and the
    -- client sends it in the same breath as its first method call.
    if not log.began then
      local rest = buf:match("^BEGIN\r\n(.*)$")
      if not rest then
        return
      end
      buf, log.began = rest, true
    end
    while true do
      local total = dbus._codec.frame_len(buf)
      if not total or #buf < total then
        break
      end
      buf = buf:sub(total + 1)
      frames = frames + 1
      log.frames = frames
      if frames == 1 then
        -- Hello. The real bus answers and immediately pushes NameAcquired at
        -- us, both in one write: two messages, one read.
        client:write(REPLY_HELLO .. SIGNAL_NAMEACQUIRED)
      elseif frames == 2 then
        -- NameHasOwner, split mid-message so the reader has to wait for the
        -- rest instead of decoding a truncated frame.
        client:write(REPLY_NAMEHASOWNER:sub(1, 20))
        vim.defer_fn(function()
          client:write(REPLY_NAMEHASOWNER:sub(21))
        end, 20)
      elseif frames == 3 then
        client:write(REPLY_CURRENTIM)
      end
    end
  end)
end)

-- ------------------------------------------------------------------- the run

local saved = vim.env.DBUS_SESSION_BUS_ADDRESS
vim.env.DBUS_SESSION_BUS_ADDRESS = "unix:path=" .. sock

assert(dbus.available() == false, "available() must not claim readiness before the handshake")

local ok = vim.wait(3000, function()
  return dbus.available()
end, 10)
assert(ok, "the backend never became available against the fake bus")

assert(log.auth ~= nil, "no SASL line arrived")
-- The uid is sent as the hex of its decimal spelling, after the opening NUL.
local uid_hex = log.auth:match("^%zAUTH EXTERNAL (%x+)$")
assert(uid_hex, "unexpected SASL line: " .. vim.inspect(log.auth))
assert(#uid_hex % 2 == 0, "the hex uid must be whole bytes: " .. uid_hex)

local raw, answered
dbus.get_async(function(v)
  raw, answered = v, true
end)
assert(vim.wait(3000, function()
  return answered
end, 10), "get_async never answered")
assert(raw == "hangul", "get_async returned " .. vim.inspect(raw))

-- Polling every 300ms over a socket that has gone quiet must not pile up one
-- request per tick. The fake bus stops answering after the third reply, so the
-- frame count is the evidence: two more calls, one more request on the wire.
assert(log.frames == 3, "expected 3 requests so far, saw " .. tostring(log.frames))
dbus.get_async(function() end)
dbus.get_async(function() end)
dbus.get_async(function() end)
vim.wait(200)
assert(log.frames == 4, "overlapping polls must coalesce; saw " .. tostring(log.frames) .. " requests")

-- reload() drops the connection, which is what :IMEStatusReload promises.
dbus.reload()
assert(dbus.available() == false, "reload() must put the backend back to unconnected")

vim.env.DBUS_SESSION_BUS_ADDRESS = saved
server:close()
if not is_win then
  os.remove(sock)
end

print("ok")
