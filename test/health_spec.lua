-- Diagnosis checks for the native Linux backend. Run:
--   nvim --headless -l test/health_spec.lua
--
-- Runs on any OS: dbus_linux is deliberately OS-agnostic, and diagnose() only
-- reads the bus address and the luv feature test.
--
-- These four answers are what :checkhealth turns into four different fixes --
-- upgrade Neovim, export the address, start fcitx5, install a tool -- and
-- getting one wrong sends the user down the wrong one. That is the whole
-- reason the plugin documents no minimum Neovim version: which build a user
-- needs depends on their bus address, not on their OS, so the answer is
-- computed per machine here instead of approximated in the README.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local dbus = require("ime-status.dbus_linux")
local uv = vim.uv or vim.loop
local connect2 = uv.pipe_connect2

---@param addr string|nil  what $DBUS_SESSION_BUS_ADDRESS holds
---@param has_connect2 boolean  luv 1.46+ (Neovim 0.10+)
local function diagnose(addr, has_connect2)
  vim.env.DBUS_SESSION_BUS_ADDRESS = addr
  uv.pipe_connect2 = has_connect2 and connect2 or nil
  local why = dbus.diagnose("fcitx5")
  uv.pipe_connect2 = connect2
  return why
end

-- ibus is asked the same four questions, but about $IBUS_ADDRESS and the
-- private bus behind it. XDG_CONFIG_HOME is redirected at an empty directory
-- throughout so the answer never depends on whether the machine running the
-- suite happens to have an ibus address file lying around.
local scratch = vim.fn.tempname()
vim.fn.mkdir(scratch, "p")
vim.env.XDG_CONFIG_HOME = scratch

---@param addr string|nil  what $IBUS_ADDRESS holds
---@param has_connect2 boolean
local function diagnose_ibus(addr, has_connect2)
  vim.env.IBUS_ADDRESS = addr
  uv.pipe_connect2 = has_connect2 and connect2 or nil
  local why = dbus.diagnose("ibus")
  uv.pipe_connect2 = connect2
  return why
end

local function eq(got, want, msg)
  assert(got == want, ("%s: got %s, want %s"):format(msg, got, want))
end

-- Nothing to connect to. Distinct from "connected and fcitx5 is absent"
-- because the fix is exporting the variable, not starting a daemon.
--
-- Only when the systemd fallback is absent too: bus_path() answers an unset
-- variable with /run/user/<uid>/bus when that socket exists, and on a Linux box
-- with a live session it usually does. Asserting no_bus unconditionally passes
-- on Windows and fails on exactly the machines this backend is for.
local uv_ = vim.uv or vim.loop
local fallback = uv_.getuid and uv_.fs_stat(("/run/user/%d/bus"):format(uv_.getuid()))
eq(diagnose(nil, true), fallback and "no_daemon" or "no_bus", "no address")

-- The address exists but names an abstract socket, which needs
-- uv_pipe_connect2. On an older build fcitx5 can be running and still be
-- unreachable -- the one case where the external tool is not a workaround.
eq(diagnose("unix:abstract=/tmp/dbus-Xyz,guid=deadbeef", false), "unreachable", "abstract without connect2")
eq(diagnose("unix:abstract=/tmp/dbus-Xyz,guid=deadbeef", true), "no_daemon", "abstract with connect2")

-- A path socket (the systemd default) never needs connect2, so a plain
-- filesystem address must not be reported as unreachable on any build. The
-- path below does not exist here, which is its own answer -- see stale_bus.
eq(diagnose("unix:path=/run/user/1000/bus", false), "stale_bus", "path socket on an old build")

-- The address outliving the daemon is the normal state of a WSL shell, a bare
-- TTY or a container -- observed on WSL Debian, where the variable is exported
-- but /run/user/0/bus was never created. Reporting that as "fcitx5 is not
-- running" would send the user to start a daemon that cannot help.
eq(diagnose("unix:path=/definitely/not/a/socket", true), "stale_bus", "address without a socket")

-- A path that *does* exist gets as far as the bus, so the remaining suspect is
-- fcitx5 itself. Any existing path stands in for the socket here: diagnose()
-- only stat()s it, and this spec has to run on Windows too.
local live = debug.getinfo(1, "S").source:sub(2):gsub("\\", "/")
eq(diagnose("unix:path=" .. live, true), "no_daemon", "socket present, fcitx5 absent")

-- Several addresses may be listed; the first usable one wins, and a guid-only
-- entry is not an address.
eq(diagnose("unix:guid=abc;unix:path=" .. live, true), "no_daemon", "address list")

-- ibus, same four answers. Nothing in $IBUS_ADDRESS and nothing in the config
-- directory means there is no daemon to find -- which is the normal state on a
-- machine that runs fcitx5 instead, and must not be reported as a fault.
eq(diagnose_ibus(nil, true), "no_bus", "ibus: no address anywhere")
-- A dead $IBUS_ADDRESS is not the end of the search: the file on disk may hold
-- a newer one. With the config directory empty there is nothing to fall back
-- to, so this still reports no address rather than a stale one.
eq(diagnose_ibus("unix:path=/definitely/not/a/socket", true), "no_bus", "ibus: dead address, nothing on disk")
eq(diagnose_ibus("unix:path=" .. live, true), "no_daemon", "ibus: socket present, daemon absent")

-- Older ibus put its bus on an abstract socket; 1.5.32 does not, but a build
-- without connect2 still cannot reach one when it happens.
eq(diagnose_ibus("unix:abstract=/tmp/dbus-ibus,guid=abc", false), "unreachable", "ibus: abstract without connect2")
eq(diagnose_ibus("unix:abstract=/tmp/dbus-ibus,guid=abc", true), "no_daemon", "ibus: abstract with connect2")

-- Address discovery from the file ibus leaves in ~/.config/ibus/bus/. Two
-- things there are easy to get wrong and both were seen on a real machine: the
-- file opens with comment lines, so the value cannot be read off line 1; and a
-- daemon that exited leaves the file behind with an empty value, which must not
-- be mistaken for an address.
vim.env.IBUS_ADDRESS = nil
local busdir = scratch .. "/ibus/bus"
vim.fn.mkdir(busdir, "p")

local function write(name, body)
  local f = assert(io.open(busdir .. "/" .. name, "w"))
  f:write(body)
  f:close()
end

write("dead-unix-0", "# This file is created by ibus-daemon.\nIBUS_ADDRESS=\nIBUS_DAEMON_PID=1\n")
eq(dbus._codec.ibus_path(), nil, "an emptied address file is not an address")

write("live-unix-0", "# comment\n# another\nIBUS_ADDRESS=unix:path=" .. live .. ",guid=deadbeef\nIBUS_DAEMON_PID=2\n")
eq(dbus._codec.ibus_path(), live, "the address is read past the comments, with the guid stripped")

-- $IBUS_ADDRESS still wins when it is live...
vim.env.IBUS_ADDRESS = "unix:path=" .. live
eq(dbus._codec.ibus_path(), live, "a live IBUS_ADDRESS is used as-is")

-- ...but a variable that outlived its daemon must not pin us to a corpse while
-- the file on disk names the daemon that replaced it. This is what a shell
-- opened before the last ibus restart hands us.
vim.env.IBUS_ADDRESS = "unix:path=/definitely/not/a/socket"
eq(dbus._codec.ibus_path(), live, "a dead IBUS_ADDRESS falls through to the file on disk")
vim.env.IBUS_ADDRESS = nil

print("ok")
