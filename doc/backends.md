# Backends

How ime-status.nvim reads — and switches — the input method on each OS, what a
poll costs, and the caveats that belong to the input method rather than to the
plugin.

You do not need any of this to use the plugin. It is here for when the label
does something you did not expect, or when you want to know what the polling
timer is actually doing.

> This document is English only. The READMEs are translated; this is not.

---

## The problem

Neovim has no idea which IME the OS is in. 한/영 switching happens below the
editor, and nothing tells the terminal about it. So the state has to be *asked
for* — and every OS answers through a different mechanism, none of which is a
Neovim API.

The plugin does that in-process on all three: no companion binary, no
`fork`+`exec` per poll, and nothing looked up on `PATH`. That last point matters
more than it sounds: Neovim launched from a GUI (a `.desktop` launcher, Neovide,
a macOS `.app`) never reads your shell rc, so a tool that works in your terminal
is simply missing there. A backend that does not use `PATH` cannot fail that way.

---

## macOS — Carbon TIS via LuaJIT FFI

`lua/ime-status/ffi_mac.lua`

Calls Carbon's Text Input Sources API (`TISCopyCurrentKeyboardInputSource`)
through the LuaJIT FFI, with CoreFoundation for the string handling.

**Raw ids** are reverse-DNS input-source identifiers, exactly as `macism`
prints them — because `macism` is a thin CLI over this same API:

```
com.apple.keylayout.ABC
com.apple.inputmethod.Korean.2SetKorean
com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese
com.apple.inputmethod.SCIM.ITABC
```

Switching goes through `TISSelectInputSource`, over the list of **enabled**
sources only — selecting a source that is installed but not enabled returns
`paramErr`, so the wider list would just fail silently.

**Cost per poll:** one in-process C call.

**Caveats**

- There is no hidden conversion mode to read, unlike Windows: on macOS the 한/영
  key switches the input *source* itself, so the id always tells the whole story.
- With no `latin_source` set, `auto_switch` returns to **the last
  `com.apple.keylayout.*` source it saw you in** — so Dvorak, Colemak and the
  national latin layouts survive. `com.apple.keylayout.ABC` is only the fallback
  for before any latin source has been observed, and it is a guess, not a
  lookup: if ABC is not among your *enabled* sources, selecting it fails
  outright. Set `latin_source` explicitly to skip both.
- The Chinese input methods are named after the mode rather than the language
  (`SCIM` = simplified, `TCIM` = traditional), which is why the default label
  rules match those strings directly.

---

## Windows — user32/imm32 via LuaJIT FFI

`lua/ime-status/ffi_win.lua`

Takes the foreground window, reads the `LANGID` of its keyboard layout
(`GetKeyboardLayout`), and — for a CJK layout — asks the IME window for its
open state and conversion mode (`WM_IME_CONTROL`).

That second step is the reason this backend exists. `im-select` reports the
keyboard *layout* (e.g. `1042`) and nothing else, so the hangul/latin toggle
**inside** the Korean IME is invisible to it: the layout stays Korean whether
you are typing 한글 or ASCII. Reading the conversion mode makes that toggle
visible.

**Raw ids** come in two shapes:

| Shape                              | Meaning                                     |
| ---------------------------------- | ------------------------------------------- |
| `korean` / `japanese` / `chinese`  | CJK layout **and** the IME in native mode   |
| `ko-KR`, `en-US`, …                | anything else: the layout's locale name     |

So a Korean layout sitting in latin mode reports `ko-KR` and resolves to
`default` (`EN`) — which is the correct answer, because you are typing ASCII.

Switching accepts a language-ish string (turn the IME on), a bare number
(im-select-style locale id, requests a layout switch), or anything else (latin:
close the IME / clear native conversion mode). `latin_source` defaults to the
symbolic `"en"`, which clears the conversion mode **without** changing your
keyboard layout — a better answer than any id worth remembering, so this backend
is the one place `auto_switch` does not learn from what it sees.

The im-select fallback is the exception. Its vocabulary is bare numeric locale
ids (`1033`, `1042`) that differ per machine, so nothing sensible can be guessed
in advance and `auto_switch` used to do nothing at all there. It now returns to
the last numeric id that resolved to `default`.

**Cost per poll:** a few in-process C calls (the `WM_IME_CONTROL` sends use
`SMTO_ABORTIFHUNG`, so a wedged IME cannot block the editor).

---

## Linux — D-Bus, in plain Lua

`lua/ime-status/dbus_linux.lua`

**Linux has no OS-level API to call.** X11's XIM only ever describes your *own*
input context, and Wayland's `text-input-v3` only the focused surface — which,
for Neovim in a terminal, belongs to the terminal emulator, not to you. The one
component that knows the global state is the input method daemon, and both
daemons people actually run answer on D-Bus.

So the plugin speaks D-Bus itself: the wire protocol, SASL handshake and message
marshalling, in plain Lua over a `vim.uv` socket. No FFI (so it works on
LuaJIT-less builds too), no process spawn, no `PATH`.

`fcitx5-remote` and `ibus engine` are thin wrappers around the same calls. Doing
it in-process removes the spawn, not the round trip.

### Two daemons, two buses

They do not share a bus, so the plugin keeps a connection to each and uses
whichever daemon is actually running. A machine with neither never opens a
socket at all — there is no address to dial.

|                  | fcitx5                                    | ibus                                                     |
| ---------------- | ----------------------------------------- | -------------------------------------------------------- |
| Bus              | session bus                               | a private bus it starts itself                            |
| Address from     | `$DBUS_SESSION_BUS_ADDRESS`, else `/run/user/<uid>/bus` | `$IBUS_ADDRESS`, else the file under `~/.config/ibus/bus/` |
| Service          | `org.fcitx.Fcitx5` `/controller`          | `org.freedesktop.IBus` `/org/freedesktop/IBus`            |
| Read             | `CurrentInputMethod` → `s`                | `GetGlobalEngine` → `v` (an `IBusEngineDesc`)             |
| Switch           | `SetCurrentIM(s)`                         | `SetGlobalEngine(s)`                                      |
| Change signal    | **none**                                  | `GlobalEngineChanged(s)`                                  |
| Latin id         | `keyboard-us`                             | `xkb:us::eng`                                             |

The two latin ids are not interchangeable — handing one daemon the other's id is
a silent no-op — so `latin_source` follows whichever daemon answered. Those two
are the fallback; where a latin layout has already been observed (`keyboard-*`
on fcitx5, `xkb:*` on ibus) `auto_switch` returns to that one instead, which is
what keeps a `keyboard-de` or `xkb:dvorak` user on their own layout.

### Why only one of them is polled

**fcitx5 declares no signal for "the current input method changed."** Its
`org.fcitx.Fcitx.Controller1` interface has exactly one signal,
`InputMethodGroupsChanged`, and that is about input-method *groups*. Verified by
introspection on fcitx5 5.1.12, and by watching the whole bus across
`SetCurrentIM` / `Activate` / `Toggle` / `Deactivate` — not one signal from
fcitx5. So fcitx5 is polled: one `CurrentInputMethod` round trip per
`interval`, on a socket that is already open.

(The `kimpanel` addon does broadcast IM changes, but only when it is enabled,
which depends on which panel UI you run. Correctness cannot hang on that.)

**ibus emits `GlobalEngineChanged` on every switch**, carrying a plain string.
So it is not polled: the plugin subscribes once, and each poll is a read of a
value the daemon already pushed.

Both connections also subscribe to `NameOwnerChanged` for their daemon's name,
so starting or stopping a daemon is noticed on the next redraw instead of after
a retry timer, with no reconnect and no second handshake.

### Address discovery for ibus

`$IBUS_ADDRESS` wins — but only while it still names a live socket. A shell
opened before the last ibus restart hands down a dead one, and the file on disk
is then the newer answer, so a stale variable falls through to it rather than
pinning the plugin to a corpse.

The files under `~/.config/ibus/bus/` are named
`<machine-id>-<hostname>-<display>`, and there are usually two of them (X and
Wayland). Rather than rebuild that name, the plugin reads the directory and
takes the first entry whose socket actually exists. Two things fall out of that
check for free: the comment lines the file opens with, and the empty
`IBUS_ADDRESS=` a daemon leaves behind when it exits.

### Reading `GetGlobalEngine`

ibus answers with a `VARIANT` holding a serialised `IBusEngineDesc`:

```
variant (sa{sv}ssssssssusssssss) {
  "IBusEngineDesc"      the serialisable's name
  []                    an a{sv} of attachments, empty in practice
  "hangul"              ← the engine name, and all we want
  "Hangul", "Korean Input Method", "ko", "GPL", …
}
```

Reaching the third field does not need a general unmarshaller. Both fields in
the way carry their own length — a string its own, an array the byte length of
its contents — so the dict is *skipped* rather than parsed, whatever ends up in
it. That is the difference between ~25 lines and a variant reader the size of
the rest of the module.

This runs once, on connect. Everything after it arrives as a plain string on
`GlobalEngineChanged`. An error reply here is ordinary rather than a fault: a
freshly started daemon with nothing selected answers `No global engine.`

### Caveats

- **fcitx5 reports the input method of the _focused_ client.** With nothing
  focused it answers with an empty string, and the label falls back to `unknown`
  (`?`). That is expected while Neovim is in the background. A label that never
  becomes anything else usually means your terminal is not a fcitx5 client —
  check `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS`.
- **ibus does not expose the hangul/latin toggle inside ibus-hangul.** If you
  switch with that toggle, the engine stays `hangul` and so does the label.
  Configure the 한/영 key to switch ibus *engines* instead, or use fcitx5.
- **An abstract socket needs Neovim 0.10+** (luv 1.46+, for
  `uv_pipe_connect2`). Modern ibus uses a filesystem path, and so does the
  systemd session bus, so this rarely comes up — which is exactly why no minimum
  Neovim version is documented: which build you need depends on your bus
  address, not on your OS. `:checkhealth ime-status` answers it for your machine.

---

## Fallback: external tools

Used only when no native backend is available — a LuaJIT-less Neovim on
macOS/Windows, an input method that speaks neither D-Bus dialect (uim, nabi,
hime, kime in standalone XIM mode), or when you opted out on purpose with
`tool` / `cmd` / `set_cmd`.

This is the only path that spawns a process per sample, and the only one where
raising `interval` or setting `insert_only = true` earns its keep.

| OS      | Auto-detected on `PATH`      |
| ------- | ---------------------------- |
| macOS   | `macism`, `im-select`        |
| Windows | `im-select.exe`              |
| Linux   | `ibus`, `fcitx5-remote`      |

Anything else works through `cmd` / `set_cmd`:

```lua
require("ime-status").setup({
  cmd = { "my-ime-tool", "--current" },
  set_cmd = { "my-ime-tool", "--set" },   -- the target id is appended
})
```

---

## What a poll costs

| Backend                | Per sample                                    |
| ---------------------- | --------------------------------------------- |
| macOS FFI              | one in-process C call                         |
| Windows FFI            | a few in-process C calls                      |
| Linux / fcitx5 D-Bus   | one round trip on an already-open socket      |
| Linux / ibus D-Bus     | **nothing** — a read of a pushed value        |
| External tool          | `fork` + `exec` + the tool's own startup      |

`get()` never blocks on any of them: it returns the cached label, and refreshing
happens asynchronously.

**When a sample is taken.** The `interval` timer, and the mode and focus
autocmds. `InsertEnter` and `InsertLeave` own the insert transitions; the
`ModeChanged` handler skips those, so an insert round trip costs two samples
rather than four. `insert_only` gates every one of these paths except
`InsertEnter` itself, which is the one moment the option most wants a fresh
value — and where `mode()` may still report the outgoing mode.

`auto_switch` costs a *write* on top: one per `InsertLeave` and per focus gained
in normal mode, skipped when the source read back is already the latin one.

---

## Limits that are not the plugin's to fix

- **A terminal Neovim does not own the IME — the terminal emulator does.** Over
  SSH or in a remote session, the daemon the plugin can reach is the *local*
  one, so the label describes the wrong machine. GUI clients (Neovide,
  goneovim) are a different case.
- **Wayland's `text-input-v3` gives clients no way to query IME state** — the
  compositor only pushes to the focused surface. That is why talking to the
  daemon over D-Bus remains the approach rather than an interim hack.

---

## Checking what you have

```
:checkhealth ime-status
```

reports which backend is active, and on Linux says per daemon why the D-Bus path
is not being used when it is not — no bus address, an address naming a socket
that is not there, a socket this Neovim cannot open, or a reachable bus with no
daemon on it. Those need four different fixes.

`:IMEStatusReload` re-detects immediately instead of waiting for the retry
backoff, and `:lua print(require("ime-status").raw)` shows the raw id behind the
current label — which is what to include in a bug report about a mislabelled
input method.

Poking at the daemons directly:

```sh
# fcitx5
busctl --user introspect org.fcitx.Fcitx5 /controller
busctl --user call org.fcitx.Fcitx5 /controller \
  org.fcitx.Fcitx.Controller1 CurrentInputMethod

# ibus (its own bus, not the session bus)
export DBUS_SESSION_BUS_ADDRESS=$(sed -n 's/^IBUS_ADDRESS=//p' ~/.config/ibus/bus/*)
dbus-send --print-reply --dest=org.freedesktop.IBus /org/freedesktop/IBus \
  org.freedesktop.IBus.GetGlobalEngine
```
