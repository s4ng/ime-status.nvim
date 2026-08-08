# Handoff: native macOS backend via LuaJIT FFI

**Status:** not started. Design below is desk research — *nothing here has been run on a Mac.*
**Goal:** drop the `macism` / `im-select` dependency on macOS, the way `ffi_win.lua` dropped
`im-select.exe` on Windows.

## Why

Every macOS bug so far traces back to the external tool rather than to IME logic. The
motivating case: opening a file through an Automator action that launches Ghostty + Neovim.
That path never reads your shell rc, so `PATH` is the launchd default, `/opt/homebrew/bin` is
missing, `vim.fn.executable("macism")` is 0, and the plugin does nothing. Commit `813a662`
made that failure *diagnosable* (checkhealth names PATH, detection retries, `tool` pins an
absolute path). An in-process backend makes it *impossible*: no PATH, no Homebrew, no
`brew install` step in the README, and no fork+exec every 300 ms.

## Interface to implement

Create `lua/ime-status/ffi_mac.lua` exposing exactly what `ffi_win.lua` does — `backend.lua`
already consumes this shape and needs no new concepts:

```lua
M.available() -> boolean          -- false = fall back to macism, silently
M.get()       -> string|nil       -- raw input-source id
M.set(id)     -> boolean
```

**The raw ids are already correct.** `TISPropertyInputSourceID` returns exactly what `macism`
prints (`com.apple.keylayout.ABC`, `com.apple.inputmethod.Korean.2SetKorean`), because macism
is a thin CLI over the same API. The label rules in `config.lua` match `korean` / `japanese` /
`pinyin` / `chinese` as case-insensitive substrings, so they keep working unchanged. This is a
drop-in replacement, not a new id vocabulary — unlike Windows, where the FFI backend had to
invent `korean` / `ko-KR` because `im-select` only reported layout numbers.

**No hidden IME state on macOS.** The Windows backend exists partly because the hangul/latin
toggle lives in the IME's conversion mode, invisible to `im-select`. macOS has no equivalent:
the 한/영 key switches the *input source itself*, so `TISCopyCurrentKeyboardInputSource` is the
complete answer. Don't go looking for a conversion-mode equivalent.

## APIs

Two frameworks. TIS lives in HIToolbox (a Carbon subframework); loading Carbon pulls it in, but
loading HIToolbox directly is more precise:

```
/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation
/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox
```

> Since macOS 11 these files **do not exist on disk** — system frameworks live in the dyld
> shared cache. `dlopen`, and therefore `ffi.load`, still resolves these paths. Do not gate on
> `vim.loop.fs_stat` or `filereadable`; it will always fail.

```c
typedef const void* CFTypeRef;
typedef const struct __CFString* CFStringRef;
typedef const struct __CFArray*  CFArrayRef;
typedef void* TISInputSourceRef;
typedef signed long CFIndex;
typedef unsigned char Boolean;
typedef int32_t OSStatus;

void        CFRelease(CFTypeRef cf);
CFIndex     CFArrayGetCount(CFArrayRef);
const void* CFArrayGetValueAtIndex(CFArrayRef, CFIndex);
const char* CFStringGetCStringPtr(CFStringRef, uint32_t encoding);
Boolean     CFStringGetCString(CFStringRef, char* buf, CFIndex size, uint32_t encoding);
CFIndex     CFStringGetLength(CFStringRef);

TISInputSourceRef TISCopyCurrentKeyboardInputSource(void);
void*             TISGetInputSourceProperty(TISInputSourceRef, CFStringRef key);
CFArrayRef        TISCreateInputSourceList(const void* properties, Boolean includeAllInstalled);
OSStatus          TISSelectInputSource(TISInputSourceRef);

CFStringRef kTISPropertyInputSourceID;   /* extern global, read via the HIToolbox namespace */
```

`kCFStringEncodingUTF8` is `0x08000100`.

### Memory rules — this is where a polling plugin gets punished

Core Foundation's Create/Get rule, at 300 ms intervals:

| Call | Ownership | Action |
|---|---|---|
| `TISCopyCurrentKeyboardInputSource` | **+1** | must `CFRelease` |
| `TISCreateInputSourceList` | **+1** | must `CFRelease` (elements belong to the array) |
| `TISGetInputSourceProperty` | Get rule | **never** release |

Leaking the first one is ~200 objects/minute of steady growth. Release it before returning,
including on the error paths.

### `get()`

```
src = TISCopyCurrentKeyboardInputSource()
ref = TISGetInputSourceProperty(src, kTISPropertyInputSourceID)   -- CFStringRef, borrowed
id  = cfstring_to_lua(ref)
CFRelease(src)
return id
```

### `set(id)` — iterate, don't build a CFDictionary

The documented way to find a source is `TISCreateInputSourceList` with a filter dictionary, but
building a `CFDictionary` through FFI is far more code than it's worth. Enumerate instead:

```
list = TISCreateInputSourceList(nil, false)   -- false = enabled sources only
for i = 0, CFArrayGetCount(list) - 1 do
  src = CFArrayGetValueAtIndex(list, i)
  if cfstring_to_lua(TISGetInputSourceProperty(src, kTISPropertyInputSourceID)) == id then
    ok = TISSelectInputSource(src) == 0
    break
  end
end
CFRelease(list)
```

`includeAllInstalled = false` is deliberate: `TISSelectInputSource` returns `paramErr` for a
source that is installed but not enabled, so the wider list only produces silent failures.
Don't cache the array either — it goes stale when the user edits input sources in System
Settings, and `set()` is called rarely.

### CFString → Lua

```lua
local function cfstring_to_lua(ref)
  if ref == nil then return nil end
  local p = CF.CFStringGetCStringPtr(ref, 0x08000100)
  if p ~= nil then return ffi.string(p) end          -- fast path, often NULL
  local n = tonumber(CF.CFStringGetLength(ref)) * 4 + 1
  local buf = ffi.new("char[?]", n)
  if CF.CFStringGetCString(ref, buf, n, 0x08000100) ~= 0 then return ffi.string(buf) end
  return nil
end
```

`CFStringGetCStringPtr` returning `NULL` is normal, not an error — the copy fallback is
mandatory. Input-source ids are ASCII so the fast path usually hits, but never assume it.

Follow `ffi_win.lua`'s guard style: wrap `ffi.cdef` in `pcall` (another plugin may have cdef'd
CoreFoundation types already, and a redefine error still leaves the identical earlier
declarations usable), wrap `ffi.load` in `pcall`, then probe every symbol once and store the
result in a `ready` boolean that `available()` returns.

## Integration points

1. **`lua/ime-status/backend.lua`** — `M.native()` currently gates on `is_win` only. Extend to
   pick `ime-status.ffi_mac` on macOS; a small `{ win = ..., mac = ... }` table beats another
   branch. The surrounding machinery needs no change: `available() == false` already falls
   through to the `macism` path, and the `explicit()` guard already lets a user opt out of the
   native backend with `tool` / `cmd` / `set_cmd`.
2. **`M.default_latin()`** — still returns `com.apple.keylayout.ABC` on mac, still correct
   enough to ship. See the follow-up below.
3. **`lua/ime-status/health.lua`** — the `backend.native()` branch hardcodes "native Windows
   backend … im-select on PATH is ignored". Make it OS-aware.
4. **Docs** — README ×4 (the requirements table around line 35, and the macOS install
   instructions) plus `doc/ime-status.txt`. macOS stops needing an external tool at all.

## Risks — verify these first, in this order

1. **Does `TISSelectInputSource` work from Neovim inside a terminal?** Make-or-break. Expected
   yes, since `macism` is the same call from a plain CLI binary and works today. Verify before
   writing anything else.
2. **"Automatically switch to a document's input source"** (System Settings → Keyboard → Input
   Sources) makes the input source per-application and changes switching behavior for a
   non-frontmost process. `macism` has the same caveat, so parity is the bar, not perfection.
3. **Main thread.** TIS wants to be called on the main thread. `M.get()` runs synchronously
   from `backend.get()` on Neovim's main loop, so this holds today — just never call it from a
   libuv thread or a `vim.uv` work request.
4. **`ffi.load` under a hardened runtime.** Homebrew's nvim is not hardened; check the official
   `nvim-macos` tarball build. If it fails, `available()` returns false and macism takes over
   automatically — degraded, not broken.
5. Apple Silicon vs Intel: same API, no difference expected.

## Test plan

```vim
:lua =require("ime-status.ffi_mac").available()
:lua =require("ime-status.ffi_mac").get()      " toggle 한/영, run again
:lua =require("ime-status.ffi_mac").set("com.apple.keylayout.ABC")
:lua =require("ime-status.ffi_mac").get()      " expect the ABC id
:checkhealth ime-status                         " expect the native branch, no macism
```

Then the two that actually matter:

- **Leaks.** Leave nvim polling 5 minutes, watch RSS in Activity Monitor or run `leaks <pid>`.
  Steady growth means a missing `CFRelease`.
- **The original bug.** Open a file through the Automator + Ghostty action with `macism`
  removed from `PATH` entirely. Status display and `auto_switch` must both work. That is the
  whole point of this work.

There is no test suite in the repo. Commit `813a662` was verified with a throwaway harness run
as `nvim --headless -l test.lua` that prepends the repo to `rtp`, drives
`config.setup` + `backend.reload()` to exercise option combinations, and asserts on
`backend.get_cmd()` / `set_cmd()` / `available()`. Worth rebuilding — and this time committing
— if you touch backend resolution.

## Related follow-up (out of scope, same area)

`default_latin()` hardcodes `com.apple.keylayout.ABC`. For anyone on Dvorak, Colemak, or a
national latin layout, `auto_switch` silently rewrites their keyboard layout on every
`InsertLeave`. The fix is to remember the last non-CJK source seen and return to *that* — the
inverse of the `saved_source` logic already in `init.lua`. Cheap once the FFI backend makes
reading the current source free, so it's a natural rider on this work.
