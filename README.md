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
})
```

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
