# Native macOS backend via LuaJIT FFI

**Status:** done — `lua/ime-status/ffi_mac.lua`, wired into `backend.native()`.
macOS no longer needs `macism` on `PATH`; it is only a fallback for Neovim builds
without LuaJIT (or when `tool`/`cmd`/`set_cmd` pins an external tool by hand).

Built as designed in the original handoff: `available()` / `get()` / `set(id)`, the same
shape `ffi_win.lua` exposes, over CoreFoundation + Carbon's TIS API. Raw ids are byte-identical
to what `macism` prints, so the label rules in `config.lua` were unchanged.

## Verified on macOS 26.5.2 (Apple Silicon), Neovim 0.12.4, Homebrew build

- `ffi.load` resolves both framework paths despite them not existing on disk (dyld shared
  cache), as expected. `available()` is true.
- `get()` returns `com.apple.keylayout.ABC` / `com.apple.inputmethod.Korean.2SetKorean`,
  matching `macism` exactly.
- `set()` of an id no *enabled* source has returns false rather than lying.
- **No leak.** 20 000 `get()` calls — ~100 minutes of polling at 300 ms — moved RSS by 0 KB.
  5 000 full `set()` list enumerations moved it 48 KB (allocator noise, not per-call CF).
- `:checkhealth ime-status` reports the native macOS branch and no tool.
- `test/backend_spec.lua` covers backend resolution across the option combinations
  (`nvim --headless -l test/backend_spec.lua`).

## Open: switching *away* from an active IME

Not reproduced as a plugin bug, but not cleared either.

From a process spawned by a background agent harness (not the frontmost app itself, though
Ghostty was frontmost), `TISSelectInputSource` switching **ABC → Korean works**, while
**Korean → ABC returns `noErr` and does nothing**. `macism` behaves identically in the same
context — including on retry with delays — so this is the platform, not the FFI port, and
parity with `macism` (the bar this work was held to) holds.

Still unverified interactively: run Neovim in a foreground terminal with `auto_switch = true`,
type Korean in insert mode, press Esc, and confirm the source returns to ABC. If it does not,
the cause is shared with `macism` and the fix belongs in `set()` for both backends — likely
related to per-application input sources ("Automatically switch to a document's input source"
in System Settings → Keyboard).

Then the case this whole change exists for: open a file through the Automator + Ghostty action
with `macism` removed from `PATH` entirely. Status display and `auto_switch` must both work.

## Follow-up (still out of scope, same area)

`default_latin()` hardcodes `com.apple.keylayout.ABC`. On Dvorak, Colemak or a national latin
layout, `auto_switch` silently rewrites the keyboard layout on every `InsertLeave` — and if
ABC is not among the *enabled* sources, `set()` now returns false and auto_switch does nothing
at all. The fix is to remember the last non-CJK source seen and return to *that*, the inverse
of the `saved_source` logic in `init.lua`. Cheap now that reading the current source is free.
