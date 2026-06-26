# ime-status.nvim

<img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />

### **English** | [한국어](README.ko.md)

Show the current keyboard input method (한 / EN / あ / 中 …) in your Neovim
statusline.

Neovim itself has no idea which IME the OS is in — 한/영 switching is handled by
the operating system, not the editor. This plugin asks a small external tool for
the current input source, **caches** the result, refreshes it asynchronously on
a timer and on mode changes, and exposes a fast getter you can drop into any
statusline. It is **not** lualine-specific; lualine is just one of the examples
below.

## Requirements

An external tool that reports the current input source. The plugin does **not**
install it for you (Neovim plugin managers manage git repos, not system
binaries) — run `:checkhealth ime-status` and it will tell you what to install.

| OS      | Tool                                                                 |
| ------- | -------------------------------------------------------------------- |
| macOS   | [`macism`](https://github.com/laishulu/macism) or `im-select`        |
| Windows | [`im-select.exe`](https://github.com/daipeihust/im-select)           |
| Linux   | `ibus` or `fcitx5-remote` (experimental — may need a custom `cmd`)   |

```sh
# macOS — use the full tap path. Plain `brew install macism` fails:
# macism lives in a tap, not homebrew-core.
brew install laishulu/homebrew/macism
```

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts` is passed straight to `setup()`. Calling `setup()` is what starts the
polling timer, so it must run once.

## Statusline integration

### lualine

```lua
{
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    require("ime-status").setup()
    table.insert(opts.sections.lualine_x, 1, { require("ime-status").component })
  end,
}
```

### Native statusline / heirline / anything else

`require("ime-status").get()` returns the current label string and never blocks.

```lua
require("ime-status").setup()
vim.o.statusline = "%{v:lua.require'ime-status'.get()} %f"
```

The plugin fires a `User IMEStatusChanged` autocmd whenever the label changes, so
event-driven statuslines can refresh precisely.

## Configuration

Defaults:

```lua
require("ime-status").setup({
  interval = 300,        -- polling interval (ms)
  insert_only = false,   -- only poll while in insert mode
  cmd = nil,             -- override detection command, e.g. { "im-select" }
  labels = {             -- first match (case-insensitive substring) wins
    { match = "korean",   text = "한" },
    { match = "hangul",   text = "한" },
    { match = "japanese", text = "あ" },
    { match = "pinyin",   text = "中" },
    { match = "chinese",  text = "中" },
  },
  default = "EN",        -- shown when no rule matches
  unknown = "?",         -- shown when the backend returns nothing
  format = function(label) return label end,

  -- auto-switch (see below) — all default off
  auto_switch = false,         -- on InsertLeave / focusing in normal mode, force latin_source
  latin_source = nil,          -- id to switch to; nil = OS default (macOS: com.apple.keylayout.ABC)
  restore_on_insert = false,   -- on InsertEnter, restore the IME used before the auto-switch
  pause_on_focus_lost = false, -- stop polling while Neovim / the terminal is unfocused
})
```

### Auto-switch — stop normal-mode `j`/`k` from typing 한글

If you keep an always-on Neovim buffer and jump in to press `j`/`k`, a leftover
Korean IME turns those into `ㅓ`/`ㅏ` and motions break. `auto_switch = true`
fixes the cause rather than just displaying it: it forces the IME to
`latin_source` whenever you leave insert mode or focus the window in normal
mode, so normal-mode keys always work.

```lua
require("ime-status").setup({
  auto_switch = true,        -- normal mode is always latin
  restore_on_insert = true,  -- but typing resumes in the IME you last used
})
```

- `latin_source` defaults to the OS latin layout (macOS `com.apple.keylayout.ABC`,
  Linux ibus `xkb:us::eng`). On Windows set it explicitly to your im-select id.
- `restore_on_insert` remembers the IME active during insert and restores it on
  the next `InsertEnter` — handy for buffers you write CJK in.
- `pause_on_focus_lost = true` stops the polling timer while Neovim is
  unfocused (it resumes, and refreshes, on `FocusGained`) to save battery.

Add an icon, for example:

```lua
format = function(label)
  return label == "한" and ("\u{f1ab} " .. label) or ("\u{f11c} " .. label)
end
```

## Notes & tradeoffs

- **Polling is necessary.** In a terminal there is no event for "the OS just
  switched IME", so the state is sampled every `interval` ms (plus immediately on
  mode change). Lower `interval` = snappier but more subprocess spawns; raise it,
  or set `insert_only = true`, to reduce cost.
- **No tool installed?** The plugin degrades gracefully: `get()` returns
  `default` and nothing errors. See `:checkhealth ime-status`.

## License

MIT
