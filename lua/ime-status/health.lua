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

  local cmd = backend.default_cmd()
  if cmd then
    h.ok("input-source tool found: " .. table.concat(cmd, " "))
    return
  end

  if vim.fn.has("mac") == 1 then
    h.error("no input-source tool found on PATH", {
      "brew install laishulu/homebrew/macism",
      "or: brew install im-select",
    })
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    h.error("im-select.exe not found on PATH", {
      "scoop install im-select",
      "or download from https://github.com/daipeihust/im-select",
    })
  else
    h.error("no input-source tool found on PATH", {
      "install ibus or fcitx5,",
      "or set opts.cmd to a command that prints the current input id",
    })
  end
end

return M
