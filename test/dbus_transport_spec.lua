-- Transport checks for the native Linux backend, against a fake bus. Run:
--   nvim --headless -l test/dbus_transport_spec.lua
--
-- Runs on any OS: the "bus" is a uv pipe this file listens on, replaying the
-- exact bytes dbus-daemon sent during the capture session that produced
-- test/dbus_spec.lua. The codec spec proves we can read a message; this one
-- proves we can survive a *stream* — an unsolicited signal arriving between a
-- request and its reply, two messages landing in one read, a reply split
-- across two — which is where a hand-written client actually breaks.
--
-- It also covers the one signal the backend acts on. NameOwnerChanged is the
-- difference between "start fcitx5, wait up to RETRY_MS for a re-probe" and
-- "start fcitx5, the next redraw has it" — and, going the other way, between a
-- label frozen on a dead daemon's last answer and an honest `unknown`.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local uv = vim.uv or vim.loop
local dbus = require("ime-status.dbus_linux")

local function unhex(s)
  return (s:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

-- Replies as captured against a live dbus-daemon, in the order this client
-- really asks for them: Hello(1), AddMatch(2), NameHasOwner(3), and the first
-- CurrentInputMethod(4). The serials below are those, so a fixture that drifts
-- out of step with the handshake shows up as a call that never gets answered.
local REPLY_HELLO = unhex("6c0201010a000000010000003d00000006017300050000003a312e3435000000050175000100000008016700017300000701"
  .. "7300140000006f72672e667265656465736b746f702e4442757300000000050000003a312e343500")

-- The bus pushes this the instant Hello returns, in the same write: two
-- messages, one read.
local SIGNAL_NAMEACQUIRED = unhex("6c0401010a000000020000008d00000001016f00150000002f6f72672f667265656465736b746f702f444275730000000201"
  .. "7300140000006f72672e667265656465736b746f702e4442757300000000030173000c0000004e616d654163717569726564"
  .. "0000000006017300050000003a312e3435000000080167000173000007017300140000006f72672e667265656465736b746f"
  .. "702e4442757300000000050000003a312e343500")

-- An empty METHOD_RETURN -- its own edge case, since a message with a
-- zero-length body has to be framed from its header alone.
local REPLY_ADDMATCH = unhex("6c02010100000000030000003500000006017300050000003a312e3435000000050175000200000007017300140000006f72"
  .. "672e667265656465736b746f702e4442757300000000")

local REPLY_NAMEHASOWNER = unhex("6c02010104000000040000003d00000006017300050000003a312e3435000000050175000300000008016700016200000701"
  .. "7300140000006f72672e667265656465736b746f702e444275730000000001000000")

-- Body: an empty string. That is what fcitx5 really answers when no input
-- context has focus -- the normal state headless, and in a terminal whenever
-- the terminal itself is unfocused. Reading the payload back is dbus_spec's
-- job (it decodes a real "hangul" reply, both endiannesses); what matters
-- here is that an empty answer still arrives as a string and not as failure.
local REPLY_CURRENTIM = unhex("6c02010105000000180000002e000000050175000400000006017300050000003a312e343500000008016700017300000701"
  .. "7300050000003a312e34300000000000000000")

-- NameOwnerChanged(name, old_owner, new_owner), captured by killing fcitx5 and
-- starting it again with a subscription open. Losing the name leaves the *new*
-- owner empty; gaining it leaves the *old* one empty.
local SIGNAL_OWNER_LOST = unhex("6c04010129000000040000008900000001016f00150000002f6f72672f667265656465736b746f702f444275730000000201"
  .. "7300140000006f72672e667265656465736b746f702e444275730000000003017300100000004e616d654f776e6572436861"
  .. "6e676564000000000000000007017300140000006f72672e667265656465736b746f702e4442757300000000080167000373"
  .. "73730000000000000000100000006f72672e66636974782e46636974783500000000040000003a312e330000000000000000"
  .. "00")

local SIGNAL_OWNER_GAINED = unhex("6c0401012a000000050000008900000001016f00150000002f6f72672f667265656465736b746f702f444275730000000201"
  .. "7300140000006f72672e667265656465736b746f702e444275730000000003017300100000004e616d654f776e6572436861"
  .. "6e676564000000000000000007017300140000006f72672e667265656465736b746f702e4442757300000000080167000373"
  .. "73730000000000000000100000006f72672e66636974782e466369747835000000000000000000000000050000003a312e34"
  .. "3000")

local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
local sock = is_win and ([[\\.\pipe\ime-status-test-%d]]):format(uv.os_getpid()) or vim.fn.tempname()

-- ------------------------------------------------------------------ fake bus

local server = uv.new_pipe(false)
assert(server:bind(sock))

local log = {}
-- Kept so the test can push a signal at the client the way a daemon does:
-- unsolicited, with no request of ours to hang it off.
local client
server:listen(4, function(err)
  assert(not err, tostring(err))
  client = uv.new_pipe(false)
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
        client:write(REPLY_ADDMATCH)
      elseif frames == 3 then
        -- NameHasOwner, split mid-message so the reader has to wait for the
        -- rest instead of decoding a truncated frame.
        client:write(REPLY_NAMEHASOWNER:sub(1, 20))
        vim.defer_fn(function()
          client:write(REPLY_NAMEHASOWNER:sub(21))
        end, 20)
      elseif frames == 4 then
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
assert(raw == "", "get_async returned " .. vim.inspect(raw))

-- Three requests to get here (Hello, AddMatch, NameHasOwner) and one to serve
-- the poll above.
assert(log.frames == 4, "expected 4 requests so far, saw " .. tostring(log.frames))

-- fcitx5 exits. Nothing was asked; the daemon simply pushes.
client:write(SIGNAL_OWNER_LOST)
assert(vim.wait(1000, function()
  return dbus.available() == false
end, 10), "a lost name must stop the backend claiming readiness")

-- And it must say so rather than going quiet, or the statusline keeps showing
-- what a daemon that is no longer running last reported.
local gone, gone_answered
dbus.get_async(function(v)
  gone, gone_answered = v, true
end)
assert(vim.wait(1000, function()
  return gone_answered
end, 10), "get_async went silent instead of reporting the daemon gone")
assert(gone == nil, "expected nil once fcitx5 left, got " .. vim.inspect(gone))
assert(log.frames == 4, "answering from the signal must not cost a round trip")

-- fcitx5 comes back. The point of subscribing is that this costs nothing: no
-- reconnect, no second handshake, no waiting out a backoff.
client:write(SIGNAL_OWNER_GAINED)
assert(vim.wait(1000, function()
  return dbus.available()
end, 10), "a regained name must bring the backend back")
assert(log.frames == 4, "recovery must not re-probe; saw " .. tostring(log.frames) .. " requests")

-- Polling every 300ms over a socket that has gone quiet must not pile up one
-- request per tick. The fake bus stops answering after the fourth reply, so the
-- frame count is the evidence: three more calls, one more request on the wire.
dbus.get_async(function() end)
dbus.get_async(function() end)
dbus.get_async(function() end)
vim.wait(200)
assert(log.frames == 5, "overlapping polls must coalesce; saw " .. tostring(log.frames) .. " requests")

-- reload() drops the connection, which is what :IMEStatusReload promises.
dbus.reload()
assert(dbus.available() == false, "reload() must put the backend back to unconnected")

vim.env.DBUS_SESSION_BUS_ADDRESS = saved
server:close()
if not is_win then
  os.remove(sock)
end

print("ok")
