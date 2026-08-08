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

  if backend.native() then
    h.ok("native Windows backend active (LuaJIT FFI, user32/imm32) — no external tool needed")
    h.info("detects the hangul/latin toggle inside the IME; im-select on PATH is ignored")
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

  if vim.fn.has("mac") == 1 then
    h.error("no input-source tool found on PATH", {
      path_hint,
      "otherwise: brew install laishulu/homebrew/macism",
    })
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    -- The FFI backend covers every standard Neovim build, so reaching here
    -- means either a LuaJIT-less build or opts.tool/cmd opting out of it.
    h.error("no native FFI backend (LuaJIT-less build, or disabled by opts.tool/cmd) and im-select.exe not on PATH", {
      path_hint,
      "otherwise: scoop install im-select, or https://github.com/daipeihust/im-select",
    })
  else
    h.error("no input-source tool found on PATH", {
      path_hint,
      "otherwise: install ibus or fcitx5",
    })
  end
end

return M
