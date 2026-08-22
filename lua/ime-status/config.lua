local M = {}

---@class IMEStatusLabel
---@field match string  Lua pattern matched (case-insensitively) against the raw input-source id
---@field text  string  Text shown in the statusline when matched

---@class IMEStatusConfig
---@field interval integer        Polling interval in milliseconds
---@field insert_only boolean     Only poll while in insert mode (saves CPU)
---@field tool string|nil         Name or absolute path of the input-source tool, used for both reading and switching; nil = auto-detect per OS
---@field cmd string[]|nil        Low-level override of the *detection* command (list form for vim.system); nil = derive from `tool`
---@field set_cmd string[]|fun(id:string):string[]|nil  Low-level override of the *switch* command; a list gets `id` appended. nil = derive from `tool`
---@field labels IMEStatusLabel[] Ordered rules mapping a raw id to display text; first match wins
---@field default string         Shown when no label rule matches (typically the latin/english state)
---@field unknown string         Shown when the backend produced no usable output
---@field format fun(label:string):string  Final transform applied before display
---@field auto_switch boolean       Force the IME to `latin_source` on leaving insert / focusing in normal mode
---@field latin_source string|nil   Input-source id to switch to; nil = OS default (macOS: com.apple.keylayout.ABC)
---@field restore_on_insert boolean On entering insert, restore the IME that was active before the last auto-switch
---@field pause_on_focus_lost boolean  Stop polling while Neovim/the terminal is not focused

---@type IMEStatusConfig
M.defaults = {
  interval = 300,
  insert_only = false,
  tool = nil,
  cmd = nil,
  set_cmd = nil,
  -- Matched in order against the lower-cased raw id reported by the backend;
  -- first match wins, anything unmatched falls through to `default`.
  --
  -- Most of these are engine names rather than language names, because that is
  -- what the backends actually report. Only macOS and the Windows FFI backend
  -- name the language: on Linux the id is whatever the input method calls
  -- itself, and not one Japanese engine -- anthy, mozc, kkc, skk -- has
  -- "japanese" anywhere in it. Matching on language alone silently labelled
  -- every one of them `EN`, which is worse than `unknown`: it states, with
  -- confidence, that you are in latin mode while you are not.
  --
  -- Verified against ibus 1.5.32 and fcitx5 5.1.12 (see test/label_spec.lua).
  -- Deliberately absent: `rime`, which is a schema engine used for Chinese,
  -- Japanese and Korean alike, so its name says nothing about the language.
  labels = {
    { match = "korean", text = "한" },
    { match = "hangul", text = "한" },

    { match = "japanese", text = "あ" }, -- macOS: ...RomajiTyping.Japanese
    { match = "kotoeri", text = "あ" },
    { match = "anthy", text = "あ" },
    { match = "mozc", text = "あ" },
    { match = "kkc", text = "あ" },
    { match = "skk", text = "あ" },

    { match = "chinese", text = "中" },
    { match = "pinyin", text = "中" }, -- also libpinyin, sunpinyin
    { match = "shuangpin", text = "中" },
    { match = "bopomofo", text = "中" },
    { match = "zhuyin", text = "中" },
    { match = "cangjie", text = "中" },
    { match = "chewing", text = "中" },
    { match = "wubi", text = "中" },
    { match = "wbpy", text = "中" },
    { match = "wbx", text = "中" },
    { match = "erbi", text = "中" },
    -- macOS names these after the mode, not the language: SCIM = simplified,
    -- TCIM = traditional. com.apple.inputmethod.SCIM.ITABC is the default
    -- simplified-Chinese input method and matches nothing else here.
    { match = "scim", text = "中" },
    { match = "tcim", text = "中" },
  },
  default = "EN",
  unknown = "?",
  format = function(label)
    return label
  end,
  auto_switch = false,
  latin_source = nil,
  restore_on_insert = false,
  pause_on_focus_lost = false,
}

---@type IMEStatusConfig
M.options = vim.deepcopy(M.defaults)

---@param opts table|nil
---@return IMEStatusConfig
function M.setup(opts)
  opts = opts or {}
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- `labels` is a list: a deep-merge by index would leave stale defaults behind,
  -- so when the user supplies their own rules we replace the list wholesale.
  if opts.labels ~= nil then
    M.options.labels = opts.labels
  end
  return M.options
end

return M
