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
  local why = dbus.diagnose()
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
eq(diagnose(nil, true), fallback and "no_fcitx5" or "no_bus", "no address")

-- The address exists but names an abstract socket, which needs
-- uv_pipe_connect2. On an older build fcitx5 can be running and still be
-- unreachable -- the one case where the external tool is not a workaround.
eq(diagnose("unix:abstract=/tmp/dbus-Xyz,guid=deadbeef", false), "unreachable", "abstract without connect2")
eq(diagnose("unix:abstract=/tmp/dbus-Xyz,guid=deadbeef", true), "no_fcitx5", "abstract with connect2")

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
eq(diagnose("unix:path=" .. live, true), "no_fcitx5", "socket present, fcitx5 absent")

-- Several addresses may be listed; the first usable one wins, and a guid-only
-- entry is not an address.
eq(diagnose("unix:guid=abc;unix:path=" .. live, true), "no_fcitx5", "address list")

print("ok")
