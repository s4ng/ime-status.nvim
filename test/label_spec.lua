-- Label rules against real input-source ids. Run:
--   nvim --headless -l test/label_spec.lua
--
-- Runs on any OS: the backend is swapped for one that answers whatever the test
-- hands it, so ids from all four platforms can be checked on one machine.
--
-- Every id below was observed, not invented. The Linux ones came from ibus
-- 1.5.32 and fcitx5 5.1.12 on a live daemon; the macOS and Windows ones are the
-- shapes those backends produce (ffi_mac reports the TIS input-source id,
-- ffi_win reports a literal language name once the IME is in native mode).
--
-- The failure this guards against is not a crash. It is the statusline
-- confidently reading `EN` while a Japanese IME is active -- which is what
-- every Japanese engine did before these rules existed, because none of them
-- is named after the language it types.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local backend = require("ime-status.backend")
local ime = require("ime-status")

-- Answer with whatever the current case is, so nothing here depends on a
-- daemon, a tool, or the OS the suite happens to run on.
local feed
backend.available = function()
  return true
end
backend.get = function(cb)
  cb(feed)
end
ime.setup({})

-- M.state is assigned inside a vim.schedule callback, so the loop has to be
-- given a turn before get() reflects the new id.
local function label(raw)
  feed = raw
  ime.refresh()
  vim.wait(150, function()
    return false
  end, 10)
  return ime.get()
end

local EN, KO, JA, ZH = "EN", "한", "あ", "中"

local CASES = {
  -- Linux / fcitx5: bare engine names, as `fcitx5-remote -n` prints them.
  { "keyboard-us", EN },
  { "hangul", KO },
  { "anthy", JA },
  { "mozc", JA },
  { "kkc", JA },
  { "pinyin", ZH },
  { "shuangpin", ZH },
  { "cangjie", ZH },
  { "wbpy", ZH },
  { "wbx", ZH },
  { "erbi", ZH },

  -- Linux / ibus: engine names again, but a different vocabulary for the same
  -- languages -- and a latin id that is an xkb layout rather than a name.
  { "xkb:us::eng", EN },
  { "xkb:kr:kr104:kor", EN },
  { "anthy", JA },
  { "mozc-jp", JA },
  { "libpinyin", ZH },
  { "sunpinyin", ZH },
  { "libbopomofo", ZH },
  { "chewing", ZH },

  -- macOS: reverse-DNS TIS ids. The Chinese ones name the mode, not the
  -- language, which is why SCIM/TCIM have to be matched directly.
  { "com.apple.keylayout.ABC", EN },
  { "com.apple.keylayout.Dvorak", EN },
  { "com.apple.inputmethod.Korean.2SetKorean", KO },
  { "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", JA },
  { "com.apple.inputmethod.SCIM.ITABC", ZH },
  { "com.apple.inputmethod.TCIM.Cangjie", ZH },
  { "com.apple.inputmethod.TCIM.Pinyin", ZH },

  -- Windows: the FFI backend reports the language when the IME is in native
  -- mode, and the layout's locale name otherwise -- so a Korean *layout* in
  -- latin mode must stay EN. That distinction is the reason it reports two
  -- different vocabularies, and getting it backwards would light up the label
  -- while the user is typing ASCII.
  { "korean", KO },
  { "japanese", JA },
  { "chinese", ZH },
  { "en-US", EN },
  { "ko-KR", EN },
  { "ja-JP", EN },
  { "zh-CN", EN },
}

local bad = {}
for _, case in ipairs(CASES) do
  local got = label(case[1])
  if got ~= case[2] then
    bad[#bad + 1] = ("%s -> %s (want %s)"):format(case[1], got, case[2])
  end
end
assert(#bad == 0, "mislabelled:\n  " .. table.concat(bad, "\n  "))

-- An id nothing matches is `default`, not `unknown`: the plugin only says "?"
-- when the backend produced nothing at all.
assert(label("com.example.some.unknown.source") == EN, "an unmatched id must fall through to default")
assert(label("") == "?", "an empty answer is unknown, not default")

-- Supplying `labels` replaces the list wholesale rather than merging by index,
-- so a user who wants only Korean does not inherit the Japanese rules.
ime.setup({}) -- setup() is once-only; reconfigure through config directly
require("ime-status.config").setup({ labels = { { match = "hangul", text = "KO" } } })
assert(label("hangul") == "KO", "user labels must win")
assert(label("anthy") == EN, "user labels replace the defaults instead of merging")

print("ok")
