<h1 align="center">ime-status.nvim</h1>

<p align="center">
  <img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />
</p>

<p align="center">
  <b>English</b> | <a href="README.ko.md">한국어</a> | <a href="README.ja.md">日本語</a> | <a href="README.zh.md">中文</a>
</p>

Show the current keyboard input method (한 / EN / あ / 中 …) in your Neovim
statusline.

Neovim itself has no idea which IME the OS is in — 한/영 switching is handled by
the operating system, not the editor. This plugin reads the current input source
straight from the OS, **caches** the result, refreshes it asynchronously on a
timer and on mode changes, and exposes a fast getter you can drop into any
statusline. It is **not** lualine-specific; lualine is just one of the examples
below.

## Requirements

Just Neovim. On macOS and Windows the plugin queries the IME in-process through
the built-in LuaJIT FFI — there is no companion binary to install and nothing to
find on `PATH`.

| OS      | What to install                                                    |
| ------- | ------------------------------------------------------------------ |
| macOS   | nothing — built-in FFI backend (Carbon TIS)                        |
| Windows | nothing — built-in FFI backend (user32/imm32)                      |
| Linux   | nothing for fcitx5 — built-in D-Bus backend; ibus needs its `ibus` CLI |

The macOS backend calls Carbon's TIS API, so input-source ids read exactly as
they do system-wide. The Windows backend goes through user32/imm32, which also
sees the hangul/latin toggle *inside* the Korean/Japanese/Chinese IME — state a
layout-reporting tool like `im-select` cannot report at all.

**Linux has no OS-level API to call** — the input method owns the state and only
exposes it over its own IPC. fcitx5 answers on the session bus, so the plugin
speaks D-Bus to it directly, in plain Lua over a socket: the same
`org.fcitx.Fcitx.Controller1.CurrentInputMethod` call `fcitx5-remote -n` makes,
without the process spawn or the `PATH` lookup.

ibus is still driven through its `ibus` CLI, because it lives on a *private* bus
and answers `GetGlobalEngine` with a serialised engine descriptor rather than a
name. Two caveats there: the plugin does not install that CLI for you (Neovim
plugin managers manage git repos, not system binaries), and ibus does not expose
the hangul/latin toggle *inside* ibus-hangul at all — with that toggle the label
stays on `한`. Configure the 한/영 key to switch ibus *engines* instead, or use
fcitx5. Run `:checkhealth ime-status` for guidance.

> Neovim built against plain Lua rather than LuaJIT has no FFI. There the macOS
> and Windows backends fall back to `macism` / `im-select.exe` if one happens to
> be on `PATH`. The Linux backend uses no FFI and is unaffected.

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
  tool = nil,            -- ibus, or to opt out of the native backend: name or absolute
                         -- path of the input-source tool, used for both reading and
                         -- switching, e.g. "/usr/bin/ibus"
  cmd = nil,             -- low-level: override only the detection command
  set_cmd = nil,         -- low-level: override only the switch command; a list gets
                         -- the target id appended, or pass function(id) -> { ... }
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
  Linux fcitx5 `keyboard-us` / ibus `xkb:us::eng`, Windows `"en"` — the FFI
  backend switches the IME to latin mode without changing the keyboard layout).
  The two Linux vocabularies are not interchangeable, so the default follows
  whichever backend answers.
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
  mode change). On macOS and Windows a sample is an in-process FFI call, so the
  default 300 ms costs approximately nothing, and so does a fcitx5 sample — a
  round trip on an already-open socket. Only the ibus path spawns a process per
  sample, so raise `interval` or set `insert_only = true` if that shows up.
- **Linux with no input method running?** The plugin degrades gracefully:
  `get()` returns `default` and nothing errors. Detection is retried while you
  work, so starting fcitx5 or installing the `ibus` CLI later starts working
  without restarting Neovim — or run `:IMEStatusReload` to re-detect right away.
  See `:checkhealth ime-status`.
- **Label stuck on `?` under fcitx5?** fcitx5 reports the input method of the
  *focused* client, so when nothing has focus it answers with an empty name and
  the label falls back to `unknown`. That is normal while Neovim is in the
  background (`pause_on_focus_lost = true` avoids the work entirely). If it
  never shows anything else, your terminal is probably not a fcitx5 client —
  check `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` — or set `unknown = ""`
  to hide it.
- **Works in a terminal but not when Neovim is launched from a GUI?** An ibus
  concern — or a macOS/Windows one only if you pinned `tool`/`cmd` and opted out
  of the native backend. A `.desktop` launcher, Neovide or a macOS `.app` does
  not read your shell rc, so the tool is missing from `PATH` and cannot be found.
  Check `:echo $PATH`, and either fix the launcher's environment or pin an
  absolute path:

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/ibus" })
  ```

  fcitx5 users are not affected: the D-Bus backend reads
  `$DBUS_SESSION_BUS_ADDRESS` (falling back to `/run/user/<uid>/bus`), never
  `PATH`. If that variable is missing inside Neovim, `:checkhealth ime-status`
  says so.

## License

MIT
