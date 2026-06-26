local config = require("ime-status.config")
local backend = require("ime-status.backend")

local M = {}

-- Last resolved label. nil until the first successful detection; readers fall
-- back to config.default so the statusline always renders something sane.
---@type string|nil
M.state = nil

-- Last raw input-source id seen (needed for restore_on_insert).
---@type string|nil
M.raw = nil

local timer
local started = false
-- IME that was active just before the last auto-switch to latin; restored on
-- the next InsertEnter when restore_on_insert is enabled.
local saved_source = nil

-- Map a raw backend id (e.g. "com.apple.inputmethod.Korean.2SetKorean",
-- "hangul") to its display label using the ordered rules in config.
---@param raw string|nil
---@return string
local function resolve(raw)
  local opts = config.options
  if not raw or raw == "" then
    return opts.unknown
  end
  local low = raw:lower()
  for _, rule in ipairs(opts.labels) do
    if low:find(rule.match:lower(), 1, true) then
      return rule.text
    end
  end
  return opts.default
end

local function get_cmd()
  return config.options.cmd or backend.default_cmd()
end

local function latin_source()
  return config.options.latin_source or backend.default_latin()
end

-- True when polling should run right now. With `insert_only`, we skip work
-- outside insert mode where the IME state is irrelevant to the buffer.
local function should_poll()
  if not config.options.insert_only then
    return true
  end
  return vim.fn.mode():sub(1, 1) == "i"
end

-- Fetch the current raw id asynchronously and hand it to `cb` (nil on failure).
---@param cb fun(raw:string|nil)
local function fetch(cb)
  local cmd = get_cmd()
  if not cmd then
    cb(nil)
    return
  end
  backend.spawn(cmd, function(out)
    cb(out and vim.trim(out) or nil)
  end)
end

-- Kick off one asynchronous detection. Cheap to call; the actual statusline
-- redraw only happens when the resolved label changes.
function M.refresh()
  fetch(function(raw)
    M.raw = raw
    local label = resolve(raw)
    vim.schedule(function()
      if M.state ~= label then
        M.state = label
        vim.api.nvim_exec_autocmds("User", { pattern = "IMEStatusChanged" })
        vim.cmd("redrawstatus")
      end
    end)
  end)
end

-- Set the OS input source to `id` (fire-and-forget), then refresh the display.
---@param id string|nil
local function set_source(id)
  if not id then
    return
  end
  local cmd = backend.set_cmd(id)
  if not cmd then
    return
  end
  backend.spawn(cmd, function()
    vim.schedule(M.refresh)
  end)
end

-- Force the IME to the latin/english source (the core of auto_switch).
local function switch_to_latin()
  set_source(latin_source())
end

-- Current label string. Fast: reads the cache, never spawns a process. Use this
-- from any statusline (lualine, heirline, native).
---@return string
function M.get()
  return M.state or config.options.default
end

-- Same as get() but passed through config.format — the function to wire into a
-- statusline component.
---@return string
function M.component()
  return config.options.format(M.get())
end

local function start_polling()
  if timer or not get_cmd() then
    return
  end
  timer = assert((vim.uv or vim.loop).new_timer())
  timer:start(
    config.options.interval,
    config.options.interval,
    vim.schedule_wrap(function()
      if should_poll() then
        M.refresh()
      end
    end)
  )
end

local function stop_polling()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

---@param opts table|nil  See IMEStatusConfig
---@return table
function M.setup(opts)
  if started then
    return M
  end
  started = true
  config.setup(opts)

  -- No backend available: stay silent (get() returns the default label, and
  -- `:checkhealth ime-status` explains how to install a tool). Never error.
  if not get_cmd() then
    return M
  end

  local o = config.options
  M.refresh()
  start_polling()

  local group = vim.api.nvim_create_augroup("IMEStatus", { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      if o.auto_switch and o.restore_on_insert and saved_source then
        set_source(saved_source)
      else
        M.refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      if not o.auto_switch then
        M.refresh()
        return
      end
      -- Remember the IME used during insert, then force latin so normal-mode
      -- motions (j/k/...) are never swallowed by a CJK input method.
      fetch(function(raw)
        local latin = latin_source()
        if o.restore_on_insert and raw and raw ~= latin then
          saved_source = raw
        end
        vim.schedule(switch_to_latin)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      M.refresh()
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      if o.pause_on_focus_lost then
        start_polling()
      end
      -- Switching into the window in normal mode is exactly when a stale CJK
      -- IME bites; force latin there. Don't disturb an active insert session.
      if o.auto_switch and vim.fn.mode():sub(1, 1) ~= "i" then
        switch_to_latin()
      else
        M.refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      if o.pause_on_focus_lost then
        stop_polling()
      end
    end,
  })

  return M
end

return M
