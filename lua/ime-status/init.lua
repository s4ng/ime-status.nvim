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
-- Latin source the user was last actually in — the inverse of saved_source, and
-- what auto_switch returns to. nil until one is observed.
local latin_seen = nil

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

-- Remember `raw` if it is a latin source we could safely return to later.
--
-- Two tests, not one. `backend.is_latin` knows each OS's id vocabulary and is
-- what keeps an unlabelled *CJK* engine out of here; the label check then keeps
-- out anything the user's own `labels` rules consider non-latin, since they get
-- the last word on what the statusline calls it.
---@param raw string|nil
local function note_latin(raw)
  if backend.is_latin(raw) and resolve(raw) == config.options.default then
    latin_seen = raw
  end
end

-- Where auto_switch sends the IME. An explicit `latin_source` wins; otherwise
-- return to the latin source the user was last in, and only guess when none has
-- been seen yet.
--
-- Returning to the observed source is the whole point: the guess is
-- `com.apple.keylayout.ABC` on macOS, so before this every InsertLeave rewrote a
-- Dvorak, Colemak or national latin layout to ABC — and failed silently when ABC
-- was not among the enabled sources.
local function latin_source()
  return config.options.latin_source or latin_seen or backend.default_latin()
end

-- True when polling should run right now. With `insert_only`, we skip work
-- outside insert mode where the IME state is irrelevant to the buffer.
local function should_poll()
  if not config.options.insert_only then
    return true
  end
  return vim.fn.mode():sub(1, 1) == "i"
end

-- True for the mode names InsertEnter/InsertLeave already fire on — Replace
-- mode included, since those autocmds cover it too.
---@param mode string|nil  A `v:event` mode name from ModeChanged
---@return boolean
local function insert_ish(mode)
  local c = (mode or ""):sub(1, 1)
  return c == "i" or c == "R"
end

-- Refresh, but only when polling is wanted right now. `should_poll` used to be
-- consulted by the timer alone, so `insert_only` throttled the timer and nothing
-- else: a mode change or a focus gained still sampled the IME in normal mode,
-- which is exactly the work the option asks us not to do.
local function poll()
  if should_poll() then
    M.refresh()
  end
end

-- Fetch the current raw id and hand it to `cb` (nil on failure). `cb` may run
-- synchronously (FFI backend) or async (external tool).
---@param cb fun(raw:string|nil)
local function fetch(cb)
  backend.get(function(out)
    cb(out and vim.trim(out) or nil)
  end)
end

-- Kick off one asynchronous detection. Cheap to call; the actual statusline
-- redraw only happens when the resolved label changes.
--
-- With no backend at all we leave M.state untouched rather than resolving to
-- `unknown`, so a user with no tool installed keeps seeing `default` instead of
-- a permanent "?".
function M.refresh()
  if not backend.available() then
    return
  end
  fetch(function(raw)
    M.raw = raw
    local label = resolve(raw)
    note_latin(raw)
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
  backend.set(id, function()
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

-- The timer starts even with no backend resolved yet: M.refresh() is a no-op
-- until one appears, and polling is what lets a tool installed (or a PATH
-- fixed) after startup start working without restarting Neovim.
local function start_polling()
  if timer then
    return
  end
  timer = assert((vim.uv or vim.loop).new_timer())
  timer:start(
    config.options.interval,
    config.options.interval,
    vim.schedule_wrap(poll)
  )
end

local function stop_polling()
  if timer then
    timer:stop()
    timer:close()
    timer = nil
  end
end

-- Pick up a changed `interval`: the timer was started with the old one.
local function restart_polling()
  stop_polling()
  start_polling()
end

---@param opts table|nil  See IMEStatusConfig
---@return table
function M.setup(opts)
  if started then
    -- A second call used to drop `opts` on the floor without a word. Plugin
    -- managers make that easy to hit — a spec with `opts` alongside a `config`
    -- that calls setup() itself, or two plugins each depending on this one —
    -- and whichever call lost the race silently lost the user's whole
    -- configuration. Re-merge instead.
    --
    -- An empty second call is left alone on purpose: a bare setup() from
    -- somebody else's dependency spec must not reset the options to defaults.
    if opts and next(opts) ~= nil then
      config.setup(opts)
      restart_polling()
      M.refresh()
    end
    return M
  end
  started = true
  config.setup(opts)

  -- Autocmds and the timer are registered unconditionally, even when no backend
  -- can be found right now. Detection is resolved lazily per call and re-probed
  -- periodically, so a missing tool means "silently does nothing for now"
  -- rather than "permanently disabled for this session". Never error.
  --
  -- The callbacks below read `config.options` on every call rather than closing
  -- over it: config.setup() installs a *new* table, so a captured one would go
  -- stale the moment setup() is called a second time.
  M.refresh()
  start_polling()

  local group = vim.api.nvim_create_augroup("IMEStatus", { clear = true })

  vim.api.nvim_create_autocmd("InsertEnter", {
    group = group,
    callback = function()
      local o = config.options
      if o.auto_switch and o.restore_on_insert and saved_source then
        set_source(saved_source)
      else
        -- Unconditional, not poll(): entering insert is the one sample
        -- `insert_only` definitely wants, and mode() can still report the
        -- outgoing mode here, which would make should_poll() skip it.
        M.refresh()
      end
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      local o = config.options
      if not o.auto_switch then
        poll()
        return
      end
      -- Remember the IME used during insert, then force latin so normal-mode
      -- motions (j/k/...) are never swallowed by a CJK input method.
      fetch(function(raw)
        note_latin(raw)
        local latin = latin_source()
        if raw and raw == latin then
          -- Already latin — typing never left it. Switching to the source we
          -- are in is an OS call for nothing.
          vim.schedule(poll)
          return
        end
        if o.restore_on_insert and raw then
          saved_source = raw
        end
        vim.schedule(switch_to_latin)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("ModeChanged", {
    group = group,
    callback = function()
      -- InsertEnter/InsertLeave own the insert transitions (Replace mode
      -- included — it fires those too). Handling them here as well meant two
      -- refreshes per transition, and under auto_switch it was worse than
      -- wasteful: this one raced InsertLeave's fetch -> set -> refresh and
      -- cached the pre-switch IME, so the label flashed 한 before correcting
      -- itself to EN.
      local e = vim.v.event
      if insert_ish(e.old_mode) or insert_ish(e.new_mode) then
        return
      end
      poll()
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local o = config.options
      if o.pause_on_focus_lost then
        start_polling()
      end
      -- Switching into the window in normal mode is exactly when a stale CJK
      -- IME bites; force latin there. Don't disturb an active insert session.
      if o.auto_switch and vim.fn.mode():sub(1, 1) ~= "i" then
        switch_to_latin()
      else
        poll()
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusLost", {
    group = group,
    callback = function()
      if config.options.pause_on_focus_lost then
        stop_polling()
      end
    end,
  })

  -- Re-detect on demand, so installing the tool mid-session does not need a
  -- restart to verify.
  vim.api.nvim_create_user_command("IMEStatusReload", function()
    backend.reload()
    local cmd = backend.native() and { "native backend" } or backend.get_cmd()
    vim.notify(
      cmd and ("ime-status: using " .. table.concat(cmd, " "))
        or "ime-status: no input-source tool found (see :checkhealth ime-status)",
      cmd and vim.log.levels.INFO or vim.log.levels.WARN
    )
    M.refresh()
  end, { desc = "Re-detect the ime-status input-source backend" })

  return M
end

return M
