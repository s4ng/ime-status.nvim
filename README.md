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

**Just Neovim.** No companion binary to install, nothing to find on `PATH` — the
plugin reads the input method in-process on every supported OS.

| OS      | How it reads the IME                                          |
| ------- | ------------------------------------------------------------- |
| macOS   | Carbon TIS, through the built-in LuaJIT FFI                   |
| Windows | user32/imm32, through the built-in LuaJIT FFI                 |
| Linux   | D-Bus, straight to fcitx5 or ibus — plain Lua, no FFI         |

See [**doc/backends.md**](doc/backends.md) for what each backend actually does,
what a poll costs on it, and the caveats that belong to each input method.

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {
    auto_switch = true,          -- normal mode is always latin, so j/k stay j/k
    pause_on_focus_lost = true,  -- no polling while the window is unfocused
  },
}
```

`opts` is passed straight to `setup()`. Calling `setup()` is what starts the
polling timer, so it must run once. Both options above ship *off*; see
[Auto-switch](#auto-switch--stop-normal-mode-jk-from-typing-한글) for what they
do and how to have typing resume in the IME you left.

## Statusline integration

The plugin is statusline-agnostic. `require("ime-status").component()` returns
the current label, already passed through `format`, and never blocks — it reads
a cache, so calling it on every redraw costs nothing. When the label changes the
plugin calls `redrawstatus` and fires a `User IMEStatusChanged` autocmd, which
is what the event-driven statuslines below hang off.

Each snippet below assumes the spec above is already installed, and only adds
the component.

### lualine

```lua
{
  "nvim-lualine/lualine.nvim",
  dependencies = { "s4ng/ime-status.nvim" },
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, { require("ime-status").component })

    -- lualine repaints from its own timer (refresh.statusline, 1000 ms) and a
    -- fixed event list with no "User" in it, so the plugin's redraw does not
    -- reach it and the label can sit up to a second behind the IME. Refresh it
    -- on the change event instead.
    vim.api.nvim_create_autocmd("User", {
      pattern = "IMEStatusChanged",
      callback = function()
        require("lualine").refresh({ place = { "statusline" } })
      end,
    })
  end,
}
```

### mini.statusline

`content.active` replaces the whole line rather than merging into it, so the IME
section goes into a copy of mini's own default layout:

```lua
{
  "echasnovski/mini.statusline",
  dependencies = { "s4ng/ime-status.nvim" },
  config = function()
    local MiniStatusline = require("mini.statusline")
    MiniStatusline.setup({
      content = {
        active = function()
          local mode, mode_hl = MiniStatusline.section_mode({ trunc_width = 120 })
          local git = MiniStatusline.section_git({ trunc_width = 40 })
          local diagnostics = MiniStatusline.section_diagnostics({ trunc_width = 75 })
          local filename = MiniStatusline.section_filename({ trunc_width = 140 })
          local location = MiniStatusline.section_location({ trunc_width = 75 })
          return MiniStatusline.combine_groups({
            { hl = mode_hl, strings = { mode } },
            { hl = "MiniStatuslineDevinfo", strings = { git, diagnostics } },
            "%<",
            { hl = "MiniStatuslineFilename", strings = { filename } },
            "%=",
            { hl = "MiniStatuslineFileinfo", strings = { require("ime-status").component() } },
            { hl = mode_hl, strings = { location } },
          })
        end,
      },
    })
  end,
}
```

### heirline

heirline re-evaluates a component only on the events its `update` field names,
so point that at the plugin's own event — nothing else has to redraw for it:

```lua
local IME = {
  provider = function()
    return " " .. require("ime-status").component() .. " "
  end,
  update = { "User", pattern = "IMEStatusChanged" },
}

require("heirline").setup({
  statusline = { Mode, Space, FileName, Align, IME, Ruler },
})
```

This is also the shape AstroNvim's statusline takes, since it is heirline
underneath.

### lightline.vim

lightline components are Vimscript functions, so the getter is reached through
`luaeval()`:

```lua
vim.cmd([[
  function! IMEStatusLightline() abort
    return luaeval("require('ime-status').component()")
  endfunction
]])

vim.g.lightline = {
  active = {
    left = { { "mode", "paste" }, { "readonly", "filename", "modified" } },
    right = { { "lineinfo" }, { "percent" }, { "ime", "filetype" } },
  },
  component_function = { ime = "IMEStatusLightline" },
}
```

### Native statusline, and anything else

```lua
vim.o.statusline = " %f %m%r%=[%{v:lua.require'ime-status'.component()}] %l:%c "
```

Any statusline that re-evaluates `&statusline` on redraw needs nothing more:
the plugin already asks for the redraw. One that caches instead — lualine and
heirline above — wants the `User IMEStatusChanged` autocmd.

## Configuration

Defaults:

```lua
require("ime-status").setup({
  interval = 300,        -- polling interval (ms)
  insert_only = false,   -- only poll while in insert mode
  tool = nil,            -- opt out of the native backend: name or absolute path of an
                         -- external tool, used for both reading and switching,
                         -- e.g. "/usr/bin/ibus"
  cmd = nil,             -- low-level: override only the detection command
  set_cmd = nil,         -- low-level: override only the switch command; a list gets
                         -- the target id appended, or pass function(id) -> { ... }
  labels = {             -- first match (case-insensitive substring) wins
    { match = "korean",   text = "한" },  -- and hangul
    { match = "japanese", text = "あ" },  -- and kotoeri, anthy, mozc, kkc, skk
    { match = "chinese",  text = "中" },  -- and pinyin, shuangpin, bopomofo, zhuyin,
  },                                      -- cangjie, chewing, wubi, scim, tcim, …
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

Most of the default rules are *engine* names, not language names, because that
is what the backends report. On Linux the raw id is whatever the input method
calls itself, and not one Japanese engine — `anthy`, `mozc`, `kkc`, `skk` — has
"japanese" anywhere in it. Supplying your own `labels` replaces the list
wholesale, so keep the entries you still want.

If an engine shows as `EN` while it is active, run `:IMEStatusReload` and check
what id it reports (`:lua print(require("ime-status").raw)`), then add a rule for
it — a bug report with that id is welcome too.

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

- **Polling, and where it is not needed.** In a terminal there is no OS event
  for "the IME just changed", so the state is sampled every `interval` ms (plus
  immediately on mode change). What a sample costs depends on the backend: an
  in-process FFI call on macOS and Windows, one round trip on an already-open
  socket for fcitx5, and nothing at all for ibus, which pushes changes instead
  of being asked. Only the external-tool fallback spawns a process per sample —
  that is the case where raising `interval` or setting `insert_only = true`
  earns its keep.
- **Linux with no input method running?** The plugin degrades gracefully:
  `get()` returns `default` and nothing errors. Both connections keep trying, so
  starting fcitx5 or ibus later begins working without restarting Neovim — or
  run `:IMEStatusReload` to re-detect right away. `:checkhealth ime-status`
  reports where each daemon stands, and why, for this machine.
- **Label stuck on `?` under fcitx5?** fcitx5 reports the input method of the
  *focused* client, so when nothing has focus it answers with an empty name and
  the label falls back to `unknown`. That is normal while Neovim is in the
  background (`pause_on_focus_lost = true` avoids the work entirely). If it
  never shows anything else, your terminal is probably not a fcitx5 client —
  check `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` — or set `unknown = ""`
  to hide it.
- **Works in a terminal but not when Neovim is launched from a GUI?** Only a
  concern if you pinned `tool`/`cmd` and opted out of the native backend. A
  `.desktop` launcher, Neovide or a macOS `.app` does not read your shell rc, so
  a tool that works in a terminal is missing from `PATH` there. Check
  `:echo $PATH`, and either fix the launcher's environment or pin an absolute
  path:

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/ibus" })
  ```

  The native backends never look at `PATH`. The Linux one reads
  `$DBUS_SESSION_BUS_ADDRESS` (falling back to `/run/user/<uid>/bus`) for fcitx5
  and `$IBUS_ADDRESS` (falling back to the file ibus writes under
  `~/.config/ibus/bus/`) for ibus. If those are missing or stale inside Neovim,
  `:checkhealth ime-status` says which one and what to do.

## License

MIT
