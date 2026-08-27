-- Where auto_switch sends the IME, and how often the IME gets sampled. Run:
--   nvim --headless -l test/switch_spec.lua
--
-- Runs on any OS: the backend is swapped for one that answers whatever the test
-- hands it and records what it was asked to switch to, so the macOS id shapes
-- can be checked from anywhere. The one exception is the is_latin block at the
-- top, which tests the real per-OS predicate and so only asserts the branch
-- belonging to the machine it runs on.
--
-- The failures this guards against:
--
--   * auto_switch rewriting a Dvorak/Colemak/national latin layout to
--     com.apple.keylayout.ABC on every InsertLeave. The ABC id is a guess, and
--     it also fails outright when ABC is not among the *enabled* sources.
--   * `rime` being read as latin. It is left out of the label rules on purpose
--     -- a schema engine that types Chinese, Japanese and Korean alike -- so
--     "no rule matched" does not mean "latin", and auto_switch must not switch
--     *into* it.
--   * setup() called twice dropping the second call's options, which is what a
--     plugin spec carrying `opts` next to a `config` that calls setup() does.
--   * ModeChanged double-refreshing the insert transitions InsertEnter and
--     InsertLeave already own -- and, under auto_switch, racing InsertLeave's
--     fetch -> set -> refresh so the label flashes the pre-switch IME.
--   * insert_only throttling the timer and nothing else.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local backend = require("ime-status.backend")
local config = require("ime-status.config")
local ime = require("ime-status")

local function eq(got, want, what)
  assert(got == want, string.format("%s: got %s, want %s", what, vim.inspect(got), vim.inspect(want)))
end

-- ---------------------------------------------------------------------------
-- backend.is_latin -- the real one, on whichever OS we are.
-- ---------------------------------------------------------------------------
eq(backend.is_latin(nil), false, "nil is not a latin source")
eq(backend.is_latin(""), false, "empty is not a latin source")

if vim.fn.has("mac") == 1 then
  eq(backend.is_latin("com.apple.keylayout.Dvorak"), true, "a keylayout is latin")
  eq(backend.is_latin("com.apple.inputmethod.Korean.2SetKorean"), false, "an input method is not")
elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
  -- Only the im-select fallback needs a remembered id; the FFI backend has the
  -- better answer already ("en" clears the conversion mode without touching the
  -- layout), so it opts out.
  local real_native = backend.native
  backend.native = function()
    return nil
  end
  eq(backend.is_latin("1042"), true, "an im-select numeric locale is latin")
  eq(backend.is_latin("en-US"), false, "a locale name is not im-select vocabulary")
  backend.native = real_native
else
  eq(backend.is_latin("keyboard-us"), true, "fcitx5 spells layouts keyboard-*")
  eq(backend.is_latin("xkb:us::eng"), true, "ibus spells them xkb:*")
  eq(backend.is_latin("hangul"), false, "an engine name is not a layout")
end

-- ---------------------------------------------------------------------------
-- A backend that answers whatever the case feeds it and records set() calls.
-- ---------------------------------------------------------------------------
local feed, set_calls = nil, {}

backend.available = function()
  return true
end
backend.get = function(cb)
  cb(feed)
end
backend.set = function(id, cb)
  set_calls[#set_calls + 1] = id
  if cb then
    cb()
  end
end
backend.default_latin = function()
  return "com.apple.keylayout.ABC"
end
-- The macOS rule, stated here so the ids below mean the same thing on every OS.
backend.is_latin = function(raw)
  return raw ~= nil and raw:find("com.apple.keylayout.", 1, true) == 1
end

-- M.state and the switch both land in vim.schedule callbacks, so the loop needs
-- a turn before either is observable.
local function tick()
  vim.wait(120, function()
    return false
  end, 10)
end

local function sample(raw)
  feed = raw
  ime.refresh()
  tick()
end

local function insert_leave(raw)
  set_calls = {}
  feed = raw
  vim.api.nvim_exec_autocmds("InsertLeave", {})
  tick()
end

local KOREAN = "com.apple.inputmethod.Korean.2SetKorean"

-- ---------------------------------------------------------------------------
-- setup() is not one-shot.
-- ---------------------------------------------------------------------------
ime.setup({})
ime.setup({ auto_switch = true, restore_on_insert = true, interval = 500 })
eq(config.options.auto_switch, true, "a second setup() must not drop its opts")
eq(config.options.interval, 500, "a second setup() must not drop interval")

ime.setup({})
eq(config.options.auto_switch, true, "an empty setup() must not reset the options")
eq(config.options.default, "EN", "the defaults survive a re-merge")

-- ---------------------------------------------------------------------------
-- auto_switch returns to the layout actually in use.
-- ---------------------------------------------------------------------------
sample("com.apple.keylayout.Dvorak") -- seen while in normal mode
insert_leave(KOREAN)
eq(set_calls[1], "com.apple.keylayout.Dvorak", "auto_switch returns to the observed layout")

-- restore_on_insert still carries the CJK source back into insert.
set_calls = {}
vim.api.nvim_exec_autocmds("InsertEnter", {})
tick()
eq(set_calls[1], KOREAN, "restore_on_insert restores the IME used during insert")

-- An unlabelled CJK engine resolves to `default`, and must still not be taken
-- for a latin source: the switch target stays the last real layout.
sample("rime")
insert_leave("rime")
eq(set_calls[1], "com.apple.keylayout.Dvorak", "rime must not be recorded as latin")

-- Already latin on InsertLeave: nothing to switch, so no OS call at all.
sample("com.apple.keylayout.Dvorak")
insert_leave("com.apple.keylayout.Dvorak")
eq(#set_calls, 0, "no switch when the source is already latin")

-- The per-OS guess remains the fallback for before anything has been observed.
eq(backend.default_latin(), "com.apple.keylayout.ABC", "the fallback is still there")

-- ---------------------------------------------------------------------------
-- How many samples a mode change costs.
-- ---------------------------------------------------------------------------
local calls = 0
local real_refresh = ime.refresh
ime.refresh = function()
  calls = calls + 1
  return real_refresh()
end

ime.setup({ auto_switch = false, insert_only = false })
feed = "com.apple.keylayout.Dvorak"
calls = 0
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ihello<Esc>", true, false, true), "x", false)
tick()
-- InsertEnter and InsertLeave, and not the two ModeChanged transitions they
-- already cover. This was 4 before ModeChanged learned to skip them.
eq(calls, 2, "an insert round trip samples twice")

ime.setup({ insert_only = true })
calls = 0
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("vj<Esc>", true, false, true), "x", false)
tick()
-- insert_only used to gate the timer alone, so a visual round trip still
-- sampled the IME in a mode where the answer cannot matter.
eq(calls, 0, "insert_only suppresses the non-insert autocmd paths")

print("ok")
