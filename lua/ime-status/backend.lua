local M = {}

-- Resolve the command that prints the *current* input source / engine id on
-- this OS, or nil when no supported tool is installed. The returned value is a
-- list suitable for vim.system / jobstart.
---@return string[]|nil
function M.default_cmd()
  if vim.fn.has("mac") == 1 then
    if vim.fn.executable("macism") == 1 then
      return { "macism" }
    end
    if vim.fn.executable("im-select") == 1 then
      return { "im-select" }
    end
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    if vim.fn.executable("im-select.exe") == 1 then
      return { "im-select.exe" }
    end
  else
    -- Linux / other unix. ibus reports a name like "hangul" or "xkb:us::eng";
    -- fcitx5 with -n reports the active input method name. Both feed the
    -- label-matching rules in config.lua.
    if vim.fn.executable("ibus") == 1 then
      return { "ibus", "engine" }
    end
    if vim.fn.executable("fcitx5-remote") == 1 then
      return { "fcitx5-remote", "-n" }
    end
  end
  return nil
end

-- Run `cmd` asynchronously and hand its trimmed stdout to `cb` (nil on failure).
-- Prefers vim.system (nvim >= 0.10) and falls back to jobstart otherwise so the
-- plugin still works on 0.9.
---@param cmd string[]
---@param cb fun(out:string|nil)
function M.spawn(cmd, cb)
  if vim.system then
    vim.system(cmd, { text = true }, function(obj)
      cb(obj.code == 0 and obj.stdout or nil)
    end)
    return
  end

  local chunks = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        chunks = data
      end
    end,
    on_exit = function(_, code)
      cb(code == 0 and table.concat(chunks, "\n") or nil)
    end,
  })
end

return M
