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
  assert(backend.native() == nil, "no native backend expected on this OS")
end

print("ok")
