local backend = require("ime-status.backend")

local M = {}

local function luv_version()
  local uv = vim.uv or vim.loop
  return uv.version_string and uv.version_string() or "unknown"
end

-- Where each of the two Linux daemons stands. Reported per provider because
-- they live on different buses and fail for unrelated reasons -- and reported
-- even when an external tool *was* found, because "input-source tool found"
-- otherwise reads like a clean bill of health while quietly hiding that the
-- cheaper path was skipped.
--
-- No minimum Neovim version is documented for the plugin on purpose: the D-Bus
-- backends degrade to the tool on their own, and which build a given user needs
-- depends on their bus address, not on their OS -- an abstract socket needs
-- 0.10, the systemd default does not, and ibus 1.5.32 no longer uses one.
-- Saying it here says it accurately, per machine, instead of approximately in
-- four READMEs.
local PROVIDERS = {
  {
    id = "fcitx5",
    unreachable = "the session bus is on an abstract socket",
    stale = "$DBUS_SESSION_BUS_ADDRESS names a socket that is not there — the session bus is not running",
    stale_advice = {
      "normal in WSL, a bare TTY or a container: the variable outlived the daemon it pointed at",
      "check :echo $DBUS_SESSION_BUS_ADDRESS against ls -l on that path",
    },
    none = "no session bus found — $DBUS_SESSION_BUS_ADDRESS is unset here and /run/user/<uid>/bus does not exist",
    absent = "fcitx5 is not on the session bus — not running, or started against another bus",
  },
  {
    id = "ibus",
    unreachable = "the private bus ibus runs is on an abstract socket",
    stale = "ibus left an address behind but nothing is listening on it — the daemon is not running",
    stale_advice = { "a daemon that exited leaves its file in ~/.config/ibus/bus/ with a dead address" },
    none = "no ibus address — $IBUS_ADDRESS is unset and ~/.config/ibus/bus/ has no live entry",
    absent = "the bus ibus runs is reachable but nothing owns org.freedesktop.IBus",
  },
}

local function linux_native_note(h)
  local o = require("ime-status.config").options
  if o.tool or o.cmd or o.set_cmd then
    h.info("native D-Bus backends disabled by opts.tool / opts.cmd / opts.set_cmd — unset them to use one")
    return
  end

  local ok, dbus = pcall(require, "ime-status.dbus_linux")
  if not ok then
    h.info("the D-Bus backend module failed to load")
    return
  end

  for _, p in ipairs(PROVIDERS) do
    local why = dbus.diagnose(p.id)
    if why == "unreachable" then
      -- The one case where the external tool is not a workaround but the only
      -- way in, so it gets a warning rather than a note.
      h.warn(p.unreachable .. ", which needs luv 1.46+ (Neovim 0.10+) — this build has luv " .. luv_version(), {
        p.id .. " may well be running: this Neovim just cannot open that kind of socket",
        "upgrade Neovim to drop the external tool, or keep using the tool reported below",
      })
    elseif why == "stale_bus" then
      h.warn(p.stale, p.stale_advice)
    elseif why == "no_bus" then
      h.info(p.none)
    else
      h.info(p.absent)
    end
  end
end

-- Backed by `:checkhealth ime-status`.
function M.check()
  local h = vim.health
  h.start("ime-status")

  if vim.system then
    h.ok("vim.system available (async detection)")
  else
    h.info("vim.system missing (nvim < 0.10) — falling back to jobstart")
  end

  local tool = require("ime-status.config").options.tool
  if tool and vim.fn.executable(tool) ~= 1 then
    h.error("opts.tool is not executable: " .. tool)
  end

  local is_mac = vim.fn.has("mac") == 1
  local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local is_linux = not (is_mac or is_win)

  -- The Linux backend connects and shakes hands asynchronously, so it is not
  -- ready on the first call the way the FFI ones are. Give it a moment rather
  -- than reporting "no native backend" at a machine that has fcitx5 running.
  if is_linux then
    vim.wait(300, function()
      return backend.native() ~= nil
    end, 20)
  end

  if backend.native() then
    if is_mac then
      h.ok("native macOS backend active (LuaJIT FFI, CoreFoundation/TIS) — no external tool needed")
      h.info("reads the same input-source ids macism prints; macism/im-select on PATH is ignored")
    elseif is_win then
      h.ok("native Windows backend active (LuaJIT FFI, user32/imm32) — no external tool needed")
      h.info("detects the hangul/latin toggle inside the IME; im-select on PATH is ignored")
    else
      local loaded, dbus = pcall(require, "ime-status.dbus_linux")
      local who = (loaded and dbus.provider()) or "an input method"
      h.ok(("native Linux backend active (D-Bus to %s, no FFI) — no external tool needed"):format(who))
      if who == "ibus" then
        -- Worth calling out: ibus pushes every change, so on this path
        -- `interval` stops costing a round trip at all.
        h.info("subscribed to GlobalEngineChanged — the poll reads a cache, it does not ask the daemon")
      else
        h.info("reads the same names fcitx5-remote -n prints; fcitx5-remote on PATH is ignored")
      end
    end
    return
  end

  -- Reaching here means the in-process path is out. On Linux that has a
  -- specific, checkable cause, and the answer differs per machine.
  if is_linux then
    linux_native_note(h)
  end

  local cmd = backend.get_cmd()
  if cmd then
    h.ok("input-source tool found: " .. table.concat(cmd, " "))
    if not backend.set_cmd("test") then
      h.warn("this tool can report the input source but not switch it — auto_switch will do nothing")
    end
    return
  end

  -- GUI-launched Neovim (.app, Automator, Neovide, ...) never reads your shell
  -- rc files, so a tool that works in a terminal can be invisible here. Naming
  -- that is what turns "already installed, still broken" into a 10-second fix.
  local path_hint =
    "already installed? GUI-launched Neovim (.app / Automator / Neovide) does not read your shell rc, "
    .. "so PATH differs — check :echo $PATH, or set opts.tool to an absolute path"

  if is_mac then
    -- The FFI backend covers every standard Neovim build, so reaching here
    -- means either a LuaJIT-less build or opts.tool/cmd opting out of it.
    h.error("no native FFI backend (LuaJIT-less build, or disabled by opts.tool/cmd) and no macism on PATH", {
      path_hint,
      "otherwise: brew install laishulu/homebrew/macism",
    })
  elseif is_win then
    -- The FFI backend covers every standard Neovim build, so reaching here
    -- means either a LuaJIT-less build or opts.tool/cmd opting out of it.
    h.error("no native FFI backend (LuaJIT-less build, or disabled by opts.tool/cmd) and im-select.exe not on PATH", {
      path_hint,
      "otherwise: scoop install im-select, or https://github.com/daipeihust/im-select",
    })
  else
    -- The note above already said why D-Bus is out; this is only about the
    -- fallback being missing too.
    h.error("no D-Bus path to fcitx5 or ibus (see above) and no input-source tool on PATH", {
      path_hint,
      "otherwise: install ibus or fcitx5",
    })
  end
end

return M
