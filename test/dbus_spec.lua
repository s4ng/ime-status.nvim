-- D-Bus codec checks for the native Linux backend. Run:
--   nvim --headless -l test/dbus_spec.lua
--
-- Runs on any OS: it exercises the marshalling, not a connection.
--
-- Every hex string below was captured from a real session, replaying this
-- encoder's own output against dbus-daemon 1.14 with a service owning
-- org.fcitx.Fcitx5. The requests are the bytes the daemon accepted; the
-- replies are what it and the service sent back. Wire format bugs are silent
-- by nature -- a daemon answers a malformed message by hanging up, which just
-- looks like "the statusline stopped updating" -- so the golden bytes are the
-- test.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local c = require("ime-status.dbus_linux")._codec
local unpack = unpack or table.unpack

local function hex(s)
  return (s:gsub(".", function(ch)
    return ("%02x"):format(ch:byte())
  end))
end

local function unhex(s)
  return (s:gsub("%x%x", function(pair)
    return string.char(tonumber(pair, 16))
  end))
end

local function eq(got, want, msg)
  assert(got == want, ("%s: got %s, want %s"):format(msg, vim.inspect(got), vim.inspect(want)))
end

local BUS, BUS_PATH, BUS_IFACE = "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus"
local FCITX, FCITX_PATH, FCITX_IFACE = "org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1"

-- ------------------------------------------------------------------ requests

local REQUESTS = {
  {
    name = "Hello",
    call = { 1, BUS, BUS_PATH, BUS_IFACE, "Hello", {} },
    wire = "6c01020100000000010000006e00000001016f00150000002f6f72672f667265656465736b746f702f4442757300"
      .. "000006017300140000006f72672e667265656465736b746f702e444275730000000002017300140000006f72672e"
      .. "667265656465736b746f702e4442757300000000030173000500000048656c6c6f000000",
  },
  {
    name = "NameHasOwner",
    call = { 2, BUS, BUS_PATH, BUS_IFACE, "NameHasOwner", { FCITX } },
    wire = "6c01020115000000020000007f00000001016f00150000002f6f72672f667265656465736b746f702f4442757300"
      .. "000006017300140000006f72672e667265656465736b746f702e444275730000000002017300140000006f72672e"
      .. "667265656465736b746f702e4442757300000000030173000c0000004e616d654861734f776e657200000000080167"
      .. "0001730000100000006f72672e66636974782e46636974783500",
  },
  {
    name = "CurrentInputMethod",
    call = { 3, FCITX, FCITX_PATH, FCITX_IFACE, "CurrentInputMethod", {} },
    wire = "6c01020100000000030000007b00000001016f000b0000002f636f6e74726f6c6c657200000000000601730010"
      .. "0000006f72672e66636974782e4663697478350000000000000000020173001b0000006f72672e66636974782e46"
      .. "636974782e436f6e74726f6c6c6572310000000000030173001200000043757272656e74496e7075744d6574686f"
      .. "64000000000000",
  },
  {
    name = "SetCurrentIM",
    call = { 4, FCITX, FCITX_PATH, FCITX_IFACE, "SetCurrentIM", { "hangul" } },
    wire = "6c0102010b000000040000007f00000001016f000b0000002f636f6e74726f6c6c657200000000000601730010"
      .. "0000006f72672e66636974782e4663697478350000000000000000020173001b0000006f72672e66636974782e46"
      .. "636974782e436f6e74726f6c6c6572310000000000030173000c00000053657443757272656e74494d0000000008"
      .. "016700017300000600000068616e67756c00",
  },
}

for _, r in ipairs(REQUESTS) do
  local got = c.encode_call(unpack(r.call))
  eq(hex(got), r.wire, r.name .. " must encode to the bytes dbus-daemon accepted")
  -- What the daemon actually enforces: the body starts on an 8 byte boundary
  -- and the frame length is exactly the message.
  local total, body_off = c.frame_len(got)
  eq(total, #got, r.name .. " frame length")
  eq(body_off % 8, 0, r.name .. " body alignment")
end

-- ------------------------------------------------------------------- replies

-- METHOD_RETURN, reply serial 3, signature "s", body "hangul".
local REPLY_CURRENTIM = "6c0201010b000000030000002d00000006017300040000003a312e33000000000501750003000000"
  .. "080167000173000007017300040000003a312e31000000000600000068616e67756c00"
-- METHOD_RETURN, reply serial 2, signature "b", body true.
local REPLY_NAMEHASOWNER = "6c02010104000000030000003d00000006017300040000003a312e3300000000050175000200"
  .. "0000080167000162000007017300140000006f72672e667265656465736b746f702e444275730000000001000000"
-- METHOD_RETURN, reply serial 4, no body -- SetCurrentIM's acknowledgement.
local REPLY_SETIM = "6c02010100000000040000002500000006017300040000003a312e3300000000050175000400000007"
  .. "017300040000003a312e3100000000"
-- ERROR org.freedesktop.DBus.Error.NameHasNoOwner for reply serial 3, captured
-- from a run where nothing owned org.fcitx.Fcitx5 -- exactly what a stopped
-- fcitx5 produces.
local REPLY_ERROR = "6c0301012b000000040000007500000006017300050000003a312e353100000004017300290000006f72"
  .. "672e667265656465736b746f702e444275732e4572726f722e4e616d654861734e6f4f776e65720000000000000005017500"
  .. "03000000080167000173000007017300140000006f72672e667265656465736b746f702e4442757300000000260000004e61"
  .. "6d6520226f72672e66636974782e4663697478352220646f6573206e6f7420657869737400"
-- The NameAcquired signal the bus pushes right after Hello, unasked. A client
-- that treats it as a reply reads the wrong answer for its next call.
local SIGNAL_NAMEACQUIRED = "6c0401010a000000020000008d00000001016f00150000002f6f72672f667265656465736b74"
  .. "6f702f4442757300000002017300140000006f72672e667265656465736b746f702e4442757300000000030173000c000000"
  .. "4e616d6541637175697265640000000006017300050000003a312e3531000000080167000173000007017300140000006f72"
  .. "672e667265656465736b746f702e4442757300000000050000003a312e353100"

local m = c.decode(unhex(REPLY_CURRENTIM))
eq(m.type, 2, "CurrentInputMethod reply is a METHOD_RETURN")
eq(m.reply_serial, 3, "CurrentInputMethod reply serial")
eq(c.get_str(m.body, 1, m.le), "hangul", "CurrentInputMethod body")

m = c.decode(unhex(REPLY_NAMEHASOWNER))
eq(m.reply_serial, 2, "NameHasOwner reply serial")
eq(c.get_u32(m.body, 1, m.le), 1, "NameHasOwner body: BOOLEAN travels as a u32")

m = c.decode(unhex(REPLY_SETIM))
eq(m.reply_serial, 4, "SetCurrentIM reply serial")
eq(m.body, "", "SetCurrentIM returns nothing")

m = c.decode(unhex(REPLY_ERROR))
eq(m.type, 3, "a stopped fcitx5 answers with an ERROR")
eq(m.reply_serial, 3, "error reply serial")
eq(m.error, "org.freedesktop.DBus.Error.NameHasNoOwner", "error name")

m = c.decode(unhex(SIGNAL_NAMEACQUIRED))
eq(m.type, 4, "NameAcquired is a SIGNAL")
eq(m.reply_serial, nil, "a signal answers no call, so it must never be dispatched as one")

-- --------------------------------------------------------------- the stream

-- The socket delivers slices, not messages: several may arrive at once and the
-- last one may be cut anywhere.
do
  local a, b = unhex(REPLY_CURRENTIM), unhex(SIGNAL_NAMEACQUIRED)
  local stream = a .. b
  eq(c.frame_len(stream), #a, "two messages in one read: the first frame stops at its own end")
  eq(c.frame_len(stream:sub(#a + 1)), #b, "and the second follows immediately")

  assert(c.frame_len(a:sub(1, 15)) == nil, "under 16 bytes the length is not knowable yet")
  local total = c.frame_len(a:sub(1, 16))
  eq(total, #a, "the fixed header alone already gives the total length")
  assert(total > 16, "a truncated message must be recognised as incomplete")
end

-- A big-endian peer is exotic but legal, and getting the swap wrong would
-- misread every field rather than fail loudly. Same message as
-- REPLY_CURRENTIM, re-marshalled with 'B' byte order.
do
  local be = "420201010000000b000000030000002d06017300000000043a312e33000000000501750000000003080167000173"
    .. "000007017300000000043a312e31000000000000000668616e67756c00"
  local msg = c.decode(unhex(be))
  eq(msg.le, false, "byte order flag 'B' is recognised")
  eq(msg.reply_serial, 3, "big-endian reply serial")
  eq(c.get_str(msg.body, 1, msg.le), "hangul", "big-endian body")
end

-- ------------------------------------------------------------- bus discovery

do
  local saved = vim.env.DBUS_SESSION_BUS_ADDRESS

  vim.env.DBUS_SESSION_BUS_ADDRESS = "unix:path=/run/user/1000/bus,guid=abc123"
  local path, abstract = c.bus_path()
  eq(path, "/run/user/1000/bus", "systemd-style address")
  eq(abstract, false, "a filesystem socket is not abstract")

  -- What dbus-launch and dbus-run-session hand out.
  vim.env.DBUS_SESSION_BUS_ADDRESS = "unix:abstract=/tmp/dbus-Ab3xY,guid=deadbeef"
  path, abstract = c.bus_path()
  eq(path, "\0/tmp/dbus-Ab3xY", "abstract sockets are named by a leading NUL")
  eq(abstract, true, "abstract flag")

  -- The variable may list several addresses; take the first usable one.
  vim.env.DBUS_SESSION_BUS_ADDRESS = "tcp:host=localhost,port=1234;unix:path=/tmp/second"
  eq((c.bus_path()), "/tmp/second", "a non-unix address is skipped, not parsed")

  vim.env.DBUS_SESSION_BUS_ADDRESS = saved
end

print("ok")
