local backend = require("ime-status.backend")

local M = {}

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

  -- The Linux backend connects and shakes hands asynchronously, so it is not
  -- ready on the first call the way the FFI ones are. Give it a moment rather
  -- than reporting "no native backend" at a machine that has fcitx5 running.
  if not (is_mac or is_win) then
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
    -- fcitx5 needs nothing installed for Neovim's sake — the native backend
    -- talks to it over the session bus — so landing here means it is not
    -- running (or there is no session bus), and ibus, which still needs its
    -- CLI, was not found either.
    h.error("fcitx5 is not on the session bus and no input-source tool is on PATH", {
      "fcitx5 users: check that the daemon is running (fcitx5-remote -n) and that "
        .. "$DBUS_SESSION_BUS_ADDRESS is set in Neovim (:echo $DBUS_SESSION_BUS_ADDRESS)",
      "ibus users: ibus needs its CLI on PATH — " .. path_hint,
      "otherwise: install ibus or fcitx5",
    })
  end
end

return M
