local M = {}

---@class IMEStatusLabel
---@field match string  Lua pattern matched (case-insensitively) against the raw input-source id
---@field text  string  Text shown in the statusline when matched

---@class IMEStatusConfig
---@field interval integer        Polling interval in milliseconds
---@field insert_only boolean     Only poll while in insert mode (saves CPU)
---@field cmd string[]|nil        Override the detection command (list form for vim.system); nil = auto-detect per OS
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
  cmd = nil,
  -- Matched in order against the lower-cased raw id reported by the backend.
  -- Covers the common identifiers across macism / im-select / ibus / fcitx5.
  labels = {
    { match = "korean", text = "한" },
    { match = "hangul", text = "한" },
    { match = "japanese", text = "あ" },
    { match = "pinyin", text = "中" },
    { match = "chinese", text = "中" },
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
