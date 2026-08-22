-- Backend resolution checks. Run:  nvim --headless -l test/backend_spec.lua
--
-- Covers the option combinations that decide *which* backend answers, since
-- that logic (native FFI vs. external tool vs. nothing) is where the OS
-- branches live and where regressions are silent — a wrong pick degrades to
-- "the plugin quietly does nothing" rather than erroring.

vim.opt.rtp:prepend(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))

local config = require("ime-status.config")
local backend = require("ime-status.backend")

local is_mac = vim.fn.has("mac") == 1
local is_win = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

-- nvim is on PATH by definition here, so it stands in for "some installed tool".
local EXE = "nvim"

local function setup(opts)
  config.setup(opts)
  backend.reload()
end

local function eq(got, want, msg)
  assert(vim.deep_equal(got, want), ("%s: got %s, want %s"):format(msg, vim.inspect(got), vim.inspect(want)))
end

-- Explicit config wins over the native backend, in all three spellings.
for _, opts in ipairs({ { tool = EXE }, { cmd = { EXE } }, { set_cmd = { EXE } } }) do
  setup(opts)
  assert(backend.native() == nil, "explicit " .. vim.inspect(opts) .. " must disable the native backend")
end

-- `tool` drives both reading and switching.
setup({ tool = EXE })
eq(backend.get_cmd(), { EXE }, "tool -> get_cmd")
eq(backend.set_cmd("x"), { EXE, "x" }, "tool -> set_cmd")

-- A tool that is not executable degrades quietly instead of erroring.
setup({ tool = "definitely-not-a-real-binary" })
assert(backend.get_cmd() == nil, "missing tool -> no get_cmd")
assert(backend.available() == false, "missing tool -> unavailable")

-- `cmd` alone still yields a working setter, derived from cmd[1].
setup({ cmd = { EXE, "--headless" } })
eq(backend.get_cmd(), { EXE, "--headless" }, "cmd -> get_cmd")
eq(backend.set_cmd("x"), { EXE, "x" }, "cmd -> derived set_cmd")

-- A function `set_cmd` is called with the id.
setup({ set_cmd = function(id)
  return { "custom", id }
end })
eq(backend.set_cmd("x"), { "custom", "x" }, "set_cmd function")

-- Auto-detection: macOS and Windows resolve the in-process FFI backend, which
-- must then satisfy available() without any tool on PATH.
setup({})
if is_mac or is_win then
  local native = backend.native()
  assert(native ~= nil, "expected the native FFI backend on this OS")
  assert(backend.available(), "native backend must satisfy available()")
  local raw = native.get()
  assert(type(raw) == "string" and raw ~= "", "native get() returned " .. vim.inspect(raw))
  if is_mac then
    -- A reverse-DNS id: com.apple.keylayout.ABC, or a third-party IME's own.
    assert(raw:match("^%w+%.[%w.]+$"), "expected a macOS input-source id, got " .. raw)
    -- Setting an id no enabled source has must fail rather than lie.
    assert(native.set("com.example.no.such.source") == false, "set() of an unknown id must return false")
  end
else
  -- Linux resolves a native backend only when fcitx5 answers on the session
  -- bus, and it does so asynchronously — so both outcomes are legitimate here
  -- and what matters is that each one is coherent.
  vim.wait(500, function()
    return backend.native() ~= nil
  end, 20)
  local native = backend.native()
  if native then
    assert(type(native.get_async) == "function", "the Linux backend must be the async kind")
    local raw, answered
    native.get_async(function(v)
      raw, answered = v, true
    end)
    assert(vim.wait(2000, function()
      return answered
    end, 20), "get_async never answered although fcitx5 is on the bus")
    -- A string, but not necessarily a non-empty one: fcitx5 answers
    -- CurrentInputMethod with "" whenever no input context has focus, which is
    -- the normal state on a headless box (and, in a terminal, whenever the
    -- terminal itself is unfocused). init.lua renders that as `unknown`, so an
    -- empty answer is a documented outcome rather than a protocol failure --
    -- observed against fcitx5 5.1.12 on WSL Debian.
    assert(type(raw) == "string", "native get_async returned " .. vim.inspect(raw))
    -- fcitx5 ids, unlike ibus ones, are bare names: "hangul", "keyboard-us".
    eq(backend.default_latin(), "keyboard-us", "fcitx5 latin id")
  else
    -- No fcitx5 on the bus: detection has to fall through to the external
    -- tool, and availability must say exactly that.
    eq(backend.available(), backend.get_cmd() ~= nil, "without a native backend the tool decides")
  end
end

print("ok")
