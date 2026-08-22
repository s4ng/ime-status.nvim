local backend = require("ime-status.backend")

local M = {}

local function luv_version()
  local uv = vim.uv or vim.loop
  return uv.version_string and uv.version_string() or "unknown"
end

-- Linux only: why the in-process D-Bus backend is not serving. Worth saying
-- even when a tool *was* found, because "input-source tool found" otherwise
-- reads like a clean bill of health while quietly hiding that the cheaper path
-- was skipped -- and the reasons it gets skipped need different fixes.
--
-- No version requirement is documented for the plugin on purpose: the D-Bus
-- backend degrades to the tool on its own, and which Neovim a given user needs
-- depends on their bus address, not on their OS. Saying it here says it
-- accurately, per machine, instead of approximately in four READMEs.
local function linux_native_note(h)
  local o = require("ime-status.config").options
  if o.tool or o.cmd or o.set_cmd then
    h.info("native D-Bus backend disabled by opts.tool / opts.cmd / opts.set_cmd — unset them to use it")
    return
  end

  local ok, dbus = pcall(require, "ime-status.dbus_linux")
  local why = ok and dbus.diagnose() or "no_bus"

  if why == "unreachable" then
    h.warn(
      "the session bus is on an abstract socket, which needs luv 1.46+ (Neovim 0.10+) — this build has luv "
        .. luv_version(),
      {
        "fcitx5 may well be running: this Neovim just cannot open that kind of socket",
        "upgrade Neovim to drop the external tool, or keep using the tool reported below",
      }
    )
  elseif why == "stale_bus" then
    h.warn("$DBUS_SESSION_BUS_ADDRESS names a socket that is not there — the session bus is not running", {
      "normal in WSL, a bare TTY or a container: the variable outlived the daemon it pointed at",
      "check :echo $DBUS_SESSION_BUS_ADDRESS against ls -l on that path",
    })
  elseif why == "no_bus" then
    h.info(
      "no session bus found — $DBUS_SESSION_BUS_ADDRESS is unset here and /run/user/<uid>/bus does not exist "
        .. "(check :echo $DBUS_SESSION_BUS_ADDRESS)"
    )
  else
    h.info("fcitx5 does not own org.fcitx.Fcitx5 on the session bus — not running, or started against another bus")
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
      h.ok("native Linux backend active (D-Bus to fcitx5, no FFI) — no external tool needed")
      h.info("reads the same names fcitx5-remote -n prints; fcitx5-remote on PATH is ignored")
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
    h.error("no D-Bus path to fcitx5 (see above) and no input-source tool on PATH", {
      "ibus users: ibus lives on a private bus, so it still needs its CLI on PATH — " .. path_hint,
      "otherwise: install ibus or fcitx5",
    })
  end
end

return M
