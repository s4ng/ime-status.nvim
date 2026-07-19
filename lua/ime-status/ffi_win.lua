-- Native Windows backend using LuaJIT FFI (user32 + imm32). Replaces
-- im-select.exe with in-process calls: no process spawn per poll, and — unlike
-- im-select, which only reports the keyboard layout (e.g. "1042") — it reads
-- the IME conversion mode, so the hangul/latin toggle *inside* the Korean IME
-- (and the equivalent for Japanese/Chinese) is actually visible.
--
-- Raw ids produced by get():
--   "korean" / "japanese" / "chinese"  CJK layout with the IME in native mode
--                                      (matches the default label rules)
--   "ko-KR", "en-US", ...              otherwise: the layout's locale name
--                                      (resolves to config.default)
--
-- Ids accepted by set():
--   containing korean/hangul/japanese/kana/chinese/pinyin/native
--                     -> turn the IME on (open + native conversion mode)
--   a bare number     -> im-select-style locale id: request a layout switch
--   anything else     -> latin: close the IME / clear native conversion mode

local M = {}

local WM_INPUTLANGCHANGEREQUEST = 0x0050
local WM_IME_CONTROL = 0x0283
local IMC_GETCONVERSIONMODE = 0x0001
local IMC_SETCONVERSIONMODE = 0x0002
local IMC_GETOPENSTATUS = 0x0005
local IMC_SETOPENSTATUS = 0x0006
local IME_CMODE_NATIVE = 0x0001
local IME_CMODE_FULLSHAPE = 0x0008
local SMTO_ABORTIFHUNG = 0x0002

-- LANGID primary-language ids that have a native/latin IME toggle.
local CJK = {
  [0x12] = "korean",
  [0x11] = "japanese",
  [0x04] = "chinese",
}

local ffi, bit, imm32
local ready = false

do
  local ok_ffi
  ok_ffi, ffi = pcall(require, "ffi")
  local ok_bit
  ok_bit, bit = pcall(require, "bit")
  if ok_ffi and ok_bit and (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) then
    -- pcall: another plugin may have cdef'd some of these already; a redefine
    -- error still leaves the earlier (identical) declarations usable.
    pcall(ffi.cdef, [[
      void* GetForegroundWindow(void);
      uint32_t GetWindowThreadProcessId(void* hwnd, uint32_t* pid);
      void* GetKeyboardLayout(uint32_t idThread);
      int PostMessageW(void* hwnd, uint32_t msg, uintptr_t wparam, intptr_t lparam);
      intptr_t SendMessageTimeoutW(void* hwnd, uint32_t msg, uintptr_t wparam,
                                   intptr_t lparam, uint32_t flags, uint32_t timeout,
                                   uintptr_t* result);
      int LCIDToLocaleName(uint32_t lcid, uint16_t* name, int size, uint32_t flags);
      void* ImmGetDefaultIMEWnd(void* hwnd);
    ]])
    local ok_imm
    ok_imm, imm32 = pcall(ffi.load, "imm32")
    -- Verify every symbol resolves (user32/kernel32 are in ffi.C on Windows).
    ready = ok_imm
      and pcall(function()
        return ffi.C.GetForegroundWindow, ffi.C.SendMessageTimeoutW, ffi.C.LCIDToLocaleName, imm32.ImmGetDefaultIMEWnd
      end)
  end
end

---@return boolean
function M.available()
  return ready
end

-- Send one WM_IME_CONTROL message to the IME window, bounded so a hung
-- foreground app can never freeze the UI thread we poll from.
---@return integer|nil
local function ime_control(ime_hwnd, wparam, lparam)
  local out = ffi.new("uintptr_t[1]")
  local ok = ffi.C.SendMessageTimeoutW(ime_hwnd, WM_IME_CONTROL, wparam, lparam, SMTO_ABORTIFHUNG, 100, out)
  if ok == 0 then
    return nil
  end
  return tonumber(out[0])
end

-- Locale name ("ko-KR") for a LANGID; nil when the lookup fails.
---@param langid integer
---@return string|nil
local function locale_name(langid)
  local buf = ffi.new("uint16_t[85]") -- LOCALE_NAME_MAX_LENGTH
  local n = ffi.C.LCIDToLocaleName(langid, buf, 85, 0)
  if n <= 1 then
    return nil
  end
  local chars = {}
  for i = 0, n - 2 do -- n includes the terminating NUL; names are ASCII
    chars[#chars + 1] = string.char(tonumber(buf[i]) % 128)
  end
  return table.concat(chars)
end

-- Foreground window plus the LANGID of its keyboard layout.
---@return ffi.cdata*|nil hwnd, integer langid
local function foreground()
  local hwnd = ffi.C.GetForegroundWindow()
  if hwnd == nil then
    return nil, 0
  end
  local tid = ffi.C.GetWindowThreadProcessId(hwnd, nil)
  -- Keep the HKL as cdata: on x64 it may be sign-extended past 2^53, where a
  -- plain tonumber() would lose the low bits we need.
  local hkl = ffi.cast("uintptr_t", ffi.C.GetKeyboardLayout(tid))
  return hwnd, tonumber(hkl % 0x10000)
end

---@return string|nil
function M.get()
  if not ready then
    return nil
  end
  local hwnd, langid = foreground()
  if hwnd == nil then
    return nil
  end
  local name = locale_name(langid)
  local lang = CJK[langid % 0x400] -- PRIMARYLANGID
  if lang then
    local ime = imm32.ImmGetDefaultIMEWnd(hwnd)
    if ime ~= nil then
      local open = ime_control(ime, IMC_GETOPENSTATUS, 0)
      local conv = ime_control(ime, IMC_GETCONVERSIONMODE, 0)
      if open and open ~= 0 and conv and bit.band(conv, IME_CMODE_NATIVE) ~= 0 then
        return lang
      end
    end
    -- CJK layout but latin mode (or no IME window): report the locale name so
    -- no CJK label rule matches and the default ("EN") shows.
    return name or "latin"
  end
  return name or string.format("0x%04x", langid)
end

---@param id string
---@return boolean
function M.set(id)
  if not ready then
    return false
  end
  local hwnd = foreground()
  if hwnd == nil then
    return false
  end
  local low = tostring(id):lower()

  if low:match("^%d+$") then
    return ffi.C.PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST, 0, tonumber(low)) ~= 0
  end

  local ime = imm32.ImmGetDefaultIMEWnd(hwnd)
  if ime == nil then
    return false
  end

  local native = false
  for _, word in ipairs({ "korean", "hangul", "japanese", "kana", "chinese", "pinyin", "native" }) do
    if low:find(word, 1, true) then
      native = true
      break
    end
  end

  local conv = ime_control(ime, IMC_GETCONVERSIONMODE, 0) or 0
  if native then
    ime_control(ime, IMC_SETOPENSTATUS, 1)
    local mode = bit.bor(conv, IME_CMODE_NATIVE)
    if low:find("japanese", 1, true) or low:find("kana", 1, true) then
      mode = bit.bor(mode, IME_CMODE_FULLSHAPE) -- hiragana needs full-shape too
    end
    ime_control(ime, IMC_SETCONVERSIONMODE, mode)
  else
    ime_control(ime, IMC_SETCONVERSIONMODE, bit.band(conv, bit.bnot(IME_CMODE_NATIVE)))
    ime_control(ime, IMC_SETOPENSTATUS, 0)
  end
  return true
end

return M
