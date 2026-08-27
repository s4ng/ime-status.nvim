# ime-status.nvim

Shows the current OS input method (한 / EN / あ / 中 …) in the Neovim statusline.

## Layout

```
lua/ime-status/
  init.lua        setup(), the polling timer, autocmds, label resolution, get()
  config.lua      defaults, including the `labels` rules
  backend.lua     picks a backend: native for this OS, else an external tool
  ffi_mac.lua     macOS   — CoreFoundation + Carbon TIS via LuaJIT FFI
  ffi_win.lua     Windows — user32/imm32 via LuaJIT FFI
  dbus_linux.lua  Linux   — D-Bus to fcitx5 and ibus, hand-written, no FFI
  health.lua      :checkhealth ime-status
```

`dbus_linux.lua` is the big one: a D-Bus client (SASL handshake, marshalling,
stream framing, reconnect) plus two providers over one connection factory.

## Documentation — five files, all of which must agree

| File                                       | Scope                                     |
| ------------------------------------------ | ----------------------------------------- |
| `README.md`                                | English, canonical                        |
| `README.ko.md`, `README.ja.md`, `README.zh.md` | translations, kept in step with the English one |
| `doc/ime-status.txt`                       | vimdoc: option reference and `:help` tags |
| `doc/backends.md`                          | **English only** — how each backend works |

**`doc/backends.md` is the deep one, and it is easy to forget.** The READMEs
deliberately keep only a one-line-per-OS summary and link to it, so anything
about *mechanism* — what a backend calls, what a poll costs, which signals
exist, address discovery, per-input-method caveats, structural limits — belongs
there and usually only there. If you change a backend, that file is part of the
change, not a follow-up.

Rules of thumb:

- Behaviour visible in `setup()` options → vimdoc **and** all four READMEs.
- Behaviour visible in *how a backend talks to the OS* → `doc/backends.md`.
- Translations are not optional. A change to `README.md` that is not mirrored
  into the other three leaves three files stating something untrue.

## Tests

```sh
nvim --headless -l test/backend_spec.lua        # which backend gets picked
nvim --headless -l test/dbus_spec.lua           # D-Bus codec, golden bytes
nvim --headless -l test/dbus_transport_spec.lua # D-Bus stream, against a fake bus
nvim --headless -l test/health_spec.lua         # :checkhealth diagnosis
nvim --headless -l test/label_spec.lua          # raw id -> label, all four OSes
nvim --headless -l test/switch_spec.lua         # auto_switch target, sample counts
```

Each prints `ok` and exits non-zero on failure. They all run on any OS: the
transport spec stands up a fake bus on a pipe, and the label spec swaps the
backend for one that answers whatever it is handed.

The D-Bus byte fixtures are **captured from real daemons**, not synthesised, and
the specs say so. Keep it that way — a fabricated frame that the parser happens
to accept proves nothing. Recapture rather than hand-edit; a fixture whose reply
serial drifts out of step with the handshake shows up as a call that never gets
answered.

## Verifying Linux changes

The D-Bus backend cannot be meaningfully verified on macOS or Windows. Test
against a live fcitx5 **and** a live ibus, in all four states: both running,
each alone, neither. Several defects in this backend were only reachable on a
real daemon — a session-bus address naming a socket that no longer exists, a
stale `$IBUS_ADDRESS`, a standby connection that was never warmed.

`:checkhealth ime-status` is the fastest signal, and its per-daemon diagnosis is
worth re-reading after any change to connection state.

Measured facts worth not re-deriving (fcitx5 5.1.12, ibus 1.5.32):

- fcitx5 declares **no** signal for "the current input method changed" — its
  `Controller1` has one signal and it is about input-method *groups*. Polling
  cannot be removed for fcitx5.
- ibus **does** emit `GlobalEngineChanged` with a plain string, so it is not
  polled at all.
- `CurrentInputMethod` answers `""` when no input context has focus. That is
  normal headless, not a protocol failure.
- Modern ibus uses a filesystem socket, not an abstract one.

## Conventions

- Commit messages: **English**, `type: subject`, no gitmoji. Types in use are
  `feat:`, `fix:`, `docs:`, `test:`, `chore:`; keep the subject lowercase and
  under ~72 characters, e.g. `feat: native ibus D-Bus backend, dropping the
  last external-tool dependency`. Explain *why*, and what was measured, not
  just what changed.

  The reason the language matters here: a Neovim plugin is distributed **as its
  git repository**, so everyone who installs it clones the whole log. These
  messages are user-facing text, not a private notebook. The Korean history up
  to `docs: add statusline integration examples for five statuslines` was
  rewritten into English for that reason — don't reintroduce a second language.
- Comments explain the non-obvious — why a thing is done, what breaks otherwise.
  Match the density already in the file; do not narrate the code.
- Never let the plugin error or block. A missing daemon, tool or bus degrades to
  "shows `default` and quietly retries". `get()` is called from the statusline
  and must never do I/O.
