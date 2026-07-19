local M = {}

-- Resolved in-process (FFI) backend module, or false once probing failed.
---@type table|false|nil
local native_cache

-- The in-process backend for this OS, or nil. Currently Windows only: LuaJIT
-- FFI over user32/imm32, which needs no external tool and can see the
-- hangul/latin toggle inside a CJK IME (im-select cannot).
---@return table|nil
function M.native()
  if native_cache == nil then
    native_cache = false
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
      local ok, win = pcall(require, "ime-status.ffi_win")
      if ok and win.available() then
        native_cache = win
      end
    end
  end
  return native_cache or nil
end

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

-- Resolve the command that *sets* the input source to `id`, or nil when the
-- current OS tool does not support switching. macism / im-select / im-select.exe
-- all take the target id as their first argument; ibus uses `engine <name>`.
---@param id string
---@return string[]|nil
function M.set_cmd(id)
  if vim.fn.has("mac") == 1 then
    if vim.fn.executable("macism") == 1 then
      return { "macism", id }
    end
    if vim.fn.executable("im-select") == 1 then
      return { "im-select", id }
    end
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    if vim.fn.executable("im-select.exe") == 1 then
      return { "im-select.exe", id }
    end
  else
    if vim.fn.executable("ibus") == 1 then
      return { "ibus", "engine", id }
    end
  end
  return nil
end

-- A sensible default "latin / english" input-source id per OS, used by
-- auto_switch when the user did not set `latin_source`. Returns nil on Windows
-- because im-select expects a locale id (e.g. "1033") that varies per machine.
---@return string|nil
function M.default_latin()
  if vim.fn.has("mac") == 1 then
    return "com.apple.keylayout.ABC"
  elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    -- The FFI backend understands the symbolic id "en" (clear the IME's native
    -- conversion mode, keeping the layout); im-select has no such id.
    return M.native() and "en" or nil
  end
  return "xkb:us::eng"
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

-- True when *some* detection path exists (FFI backend or an external tool).
---@return boolean
function M.available()
  return M.native() ~= nil or M.default_cmd() ~= nil
end

-- Fetch the current raw id and hand it to `cb` (nil on failure). Prefers the
-- in-process FFI backend — in which case `cb` runs synchronously — and falls
-- back to spawning the external tool.
---@param cb fun(raw:string|nil)
function M.get(cb)
  local native = M.native()
  if native then
    cb(native.get())
    return
  end
  local cmd = M.default_cmd()
  if not cmd then
    cb(nil)
    return
  end
  M.spawn(cmd, cb)
end

-- Set the input source to `id` via the FFI backend or the external tool.
-- `cb` (optional) runs after the attempt, synchronously on the FFI path.
---@param id string
---@param cb fun()|nil
function M.set(id, cb)
  local native = M.native()
  if native then
    native.set(id)
    if cb then
      cb()
    end
    return
  end
  local cmd = M.set_cmd(id)
  if not cmd then
    if cb then
      cb()
    end
    return
  end
  M.spawn(cmd, function()
    if cb then
      cb()
    end
  end)
end

return M
