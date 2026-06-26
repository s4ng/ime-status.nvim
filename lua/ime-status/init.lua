local config = require("ime-status.config")
local backend = require("ime-status.backend")

local M = {}

-- Last resolved label. nil until the first successful detection; readers fall
-- back to config.default so the statusline always renders something sane.
---@type string|nil
M.state = nil

local timer
local started = false

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

-- True when polling should run right now. With `insert_only`, we skip work
-- outside insert mode where the IME state is irrelevant to the buffer.
local function should_poll()
  if not config.options.insert_only then
    return true
  end
  return vim.fn.mode():sub(1, 1) == "i"
end

-- Kick off one asynchronous detection. Cheap to call; the actual statusline
-- redraw only happens when the resolved label changes.
function M.refresh()
  local opts = config.options
  local cmd = opts.cmd or backend.default_cmd()
  if not cmd then
    return
  end
  backend.spawn(cmd, function(out)
    local label = resolve(out and vim.trim(out) or nil)
    vim.schedule(function()
      if M.state ~= label then
        M.state = label
        vim.api.nvim_exec_autocmds("User", { pattern = "IMEStatusChanged" })
        vim.cmd("redrawstatus")
      end
    end)
  end)
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
  local cmd = config.options.cmd or backend.default_cmd()
  if not cmd then
    return M
  end

  M.refresh()

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

  vim.api.nvim_create_autocmd({ "InsertEnter", "InsertLeave", "ModeChanged", "FocusGained" }, {
    group = vim.api.nvim_create_augroup("IMEStatus", { clear = true }),
    callback = function()
      M.refresh()
    end,
  })

  return M
end

return M
