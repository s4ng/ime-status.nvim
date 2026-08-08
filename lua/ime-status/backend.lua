local config = require("ime-status.config")

local M = {}

local is_mac = vim.fn.has("mac") == 1
local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

-- Most tools print the current id with no arguments and take the target id as
-- their only argument.
local function id_arg(id)
  return { id }
end

-- Known external tools for this OS, in preference order. `get` holds the args
-- that make the tool print the current input-source id; `set` builds the args
-- that switch to `id`. A tool with no `set` can only report, never switch.
local ADAPTERS
if is_mac then
  ADAPTERS = {
    { exe = "macism", get = {}, set = id_arg },
    { exe = "im-select", get = {}, set = id_arg },
  }
elseif is_win then
  ADAPTERS = {
    { exe = "im-select.exe", get = {}, set = id_arg },
  }
else
  -- Linux / other unix. ibus reports a name like "hangul" or "xkb:us::eng";
  -- fcitx5 with -n reports the active input method name. Both feed the
  -- label-matching rules in config.lua.
  ADAPTERS = {
    { exe = "ibus", get = { "engine" }, set = function(id)
      return { "engine", id }
    end },
    { exe = "fcitx5-remote", get = { "-n" } },
  }
end

-- Resolved in-process (FFI) backend module, or false once probing failed.
---@type table|false|nil
local native_cache

-- Resolved external tool adapter, false once a probe found nothing.
---@type table|false|nil
local tool_cache

-- Timestamp (ms) of the last failed probe. A negative result is only cached for
-- RETRY_MS so that installing the tool (or fixing PATH) mid-session recovers on
-- its own, without a restart. hrtime rather than uv.now() so it also advances
-- between loop ticks.
local probed_at
local RETRY_MS = 5000

local function now_ms()
  return (vim.uv or vim.loop).hrtime() / 1e6
end

-- True when the user pinned the tool or the commands by hand. Explicit config
-- always wins over auto-detection, including over the native FFI backend.
local function explicit()
  local o = config.options
  return o.tool ~= nil or o.cmd ~= nil or o.set_cmd ~= nil
end

-- "C:\bin\im-select.exe" -> "im-select"; used to recognise a user-supplied
-- absolute path as one of the known tools so its argument shape is reused.
---@param path string
---@return string
local function basename(path)
  local name = path:gsub("[\\/]+$", ""):match("[^\\/]+$") or path
  return (name:gsub("%.exe$", ""):lower())
end

-- Build an adapter for `exe` (a name or an absolute path). Falls back to the
-- common "id as the only argument" shape for tools we do not know.
---@param exe string
---@return table
local function adapter_for(exe)
  local name = basename(exe)
  for _, a in ipairs(ADAPTERS) do
    if basename(a.exe) == name then
      return { exe = exe, get = a.get, set = a.set }
    end
  end
  return { exe = exe, get = {}, set = id_arg }
end

---@return table|nil
local function probe()
  local override = config.options.tool
  if override then
    -- Honour it only once it is actually runnable: vim.system raises on a
    -- missing executable, and a typo should degrade quietly (checkhealth
    -- explains it) rather than error on every mode change.
    return vim.fn.executable(override) == 1 and adapter_for(override) or nil
  end
  for _, a in ipairs(ADAPTERS) do
    if vim.fn.executable(a.exe) == 1 then
      return a
    end
  end
  return nil
end

-- The external tool to use, or nil. A hit is cached for the session; a miss is
-- re-probed at most every RETRY_MS.
---@return table|nil
local function tool()
  if tool_cache then
    return tool_cache
  end
  local now = now_ms()
  if probed_at and (now - probed_at) < RETRY_MS then
    return nil
  end
  probed_at = now
  tool_cache = probe() or false
  return tool_cache or nil
end

-- Drop every cached probe result so the next call re-detects. Backs
-- `:IMEStatusReload`.
function M.reload()
  native_cache = nil
  tool_cache = nil
  probed_at = nil
end

-- The in-process backend for this OS, or nil. LuaJIT FFI over user32/imm32 on
-- Windows (which also sees the hangul/latin toggle inside a CJK IME, invisible
-- to im-select) and over CoreFoundation/TIS on macOS. Neither needs a tool on
-- PATH — the failure mode of GUI-launched Neovim.
---@return table|nil
function M.native()
  if explicit() then
    return nil
  end
  if native_cache == nil then
    native_cache = false
    local mod = (is_win and "ime-status.ffi_win") or (is_mac and "ime-status.ffi_mac") or nil
    if mod then
      local ok, native = pcall(require, mod)
      if ok and native.available() then
        native_cache = native
      end
    end
  end
  return native_cache or nil
end

-- The command that prints the *current* input source / engine id, or nil when
-- no tool is available. The returned value is a list suitable for vim.system /
-- jobstart.
---@return string[]|nil
function M.get_cmd()
  if config.options.cmd then
    return config.options.cmd
  end
  local t = tool()
  if not t then
    return nil
  end
  return vim.list_extend({ t.exe }, t.get or {})
end

-- The command that *sets* the input source to `id`, or nil when no tool is
-- available or the resolved tool cannot switch (fcitx5-remote -n).
---@param id string
---@return string[]|nil
function M.set_cmd(id)
  local o = config.options
  local override = o.set_cmd
  if override then
    if type(override) == "function" then
      return override(id)
    end
    local cmd = vim.list_extend({}, override)
    cmd[#cmd + 1] = id
    return cmd
  end
  -- `cmd` alone used to override detection only, leaving switching broken. Its
  -- executable is the same binary, so derive the setter from it.
  if o.cmd and not o.tool then
    local a = adapter_for(o.cmd[1])
    return a.set and vim.list_extend({ a.exe }, a.set(id)) or nil
  end
  local t = tool()
  if not t or not t.set then
    return nil
  end
  return vim.list_extend({ t.exe }, t.set(id))
end

-- A sensible default "latin / english" input-source id per OS, used by
-- auto_switch when the user did not set `latin_source`. Returns nil on Windows
-- without the FFI backend because im-select expects a locale id (e.g. "1033")
-- that varies per machine.
---@return string|nil
function M.default_latin()
  if is_mac then
    return "com.apple.keylayout.ABC"
  elseif is_win then
    -- The FFI backend understands the symbolic id "en" (clear the IME's native
    -- conversion mode, keeping the layout); im-select has no such id.
    return M.native() and "en" or nil
  end
  return "xkb:us::eng"
end

-- Run `cmd` asynchronously and hand its trimmed stdout to `cb` (nil on failure).
-- Prefers vim.system (nvim >= 0.10) and falls back to jobstart otherwise so the
-- plugin still works on 0.9. A tool that vanished between probe and spawn must
-- not raise, so both paths report failure through `cb`.
---@param cmd string[]
---@param cb fun(out:string|nil)
function M.spawn(cmd, cb)
  if vim.system then
    local ok = pcall(vim.system, cmd, { text = true }, function(obj)
      cb(obj.code == 0 and obj.stdout or nil)
    end)
    if not ok then
      cb(nil)
    end
    return
  end

  local chunks = {}
  local ok, job = pcall(vim.fn.jobstart, cmd, {
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
  if not ok or job <= 0 then
    cb(nil)
  end
end

-- True when *some* detection path exists (FFI backend or an external tool).
-- Cheap enough to call per poll: it reads a cached probe result.
---@return boolean
function M.available()
  return M.native() ~= nil or M.get_cmd() ~= nil
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
  local cmd = M.get_cmd()
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
