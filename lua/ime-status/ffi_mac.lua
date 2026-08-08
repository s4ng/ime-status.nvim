-- Native macOS backend using LuaJIT FFI (CoreFoundation + Carbon's TIS API).
-- Replaces macism / im-select with in-process calls: no PATH lookup — the
-- failure mode of GUI-launched Neovim, which never reads your shell rc — no
-- Homebrew install step, and no fork+exec per poll.
--
-- The raw ids are the same ones macism prints
-- ("com.apple.keylayout.ABC", "com.apple.inputmethod.Korean.2SetKorean"),
-- because macism is a thin CLI over this same API. Drop-in, not a new id
-- vocabulary. Unlike Windows there is no hidden conversion mode to read: the
-- 한/영 key switches the input source itself.

local M = {}

local kCFStringEncodingUTF8 = 0x08000100

-- Since macOS 11 these paths do not exist on disk (system frameworks live in
-- the dyld shared cache), but dlopen still resolves them. Never stat them.
local CORE_FOUNDATION = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
local HI_TOOLBOX =
  "/System/Library/Frameworks/Carbon.framework/Versions/A/Frameworks/HIToolbox.framework/Versions/A/HIToolbox"

local ffi, CF, TIS
local ready = false

do
  local ok_ffi
  ok_ffi, ffi = pcall(require, "ffi")
  if ok_ffi and vim.fn.has("mac") == 1 then
    -- pcall: another plugin may have cdef'd some of these already; a redefine
    -- error still leaves the earlier (identical) declarations usable. Opaque
    -- CF types are spelled `const void*` rather than typedef'd so a clash in
    -- one line cannot cost us the whole block.
    pcall(ffi.cdef, [[
      void        CFRelease(const void* cf);
      long        CFArrayGetCount(const void* arr);
      void*       CFArrayGetValueAtIndex(const void* arr, long idx);
      const char* CFStringGetCStringPtr(const void* str, uint32_t encoding);
      unsigned char CFStringGetCString(const void* str, char* buf, long size, uint32_t encoding);
      long        CFStringGetLength(const void* str);

      void*       TISCopyCurrentKeyboardInputSource(void);
      void*       TISGetInputSourceProperty(void* src, const void* key);
      const void* TISCreateInputSourceList(const void* properties, unsigned char includeAllInstalled);
      int32_t     TISSelectInputSource(void* src);
      const void* kTISPropertyInputSourceID;
    ]])
    local ok
    ok, CF = pcall(ffi.load, CORE_FOUNDATION)
    if ok then
      ok, TIS = pcall(ffi.load, HI_TOOLBOX)
    end
    -- Probe every symbol once: a hardened-runtime build that refuses the load,
    -- or a missing symbol, must degrade to macism rather than error per poll.
    ready = ok
      and pcall(function()
        return CF.CFRelease,
          CF.CFStringGetCStringPtr,
          TIS.TISCopyCurrentKeyboardInputSource,
          TIS.TISGetInputSourceProperty,
          TIS.TISCreateInputSourceList,
          TIS.TISSelectInputSource,
          TIS.kTISPropertyInputSourceID
      end)
  end
end

---@return boolean
function M.available()
  return ready
end

-- CFStringRef -> Lua string. The pointer fast path returns NULL for perfectly
-- normal strings, so the copy fallback is mandatory, not defensive.
---@param ref ffi.cdata*|nil
---@return string|nil
local function cfstring(ref)
  if ref == nil then
    return nil
  end
  local p = CF.CFStringGetCStringPtr(ref, kCFStringEncodingUTF8)
  if p ~= nil then
    return ffi.string(p)
  end
  local n = tonumber(CF.CFStringGetLength(ref)) * 4 + 1 -- worst-case UTF-8
  local buf = ffi.new("char[?]", n)
  if CF.CFStringGetCString(ref, buf, n, kCFStringEncodingUTF8) ~= 0 then
    return ffi.string(buf)
  end
  return nil
end

-- The input-source id of `src`. Get rule: the property is borrowed, never
-- released.
---@param src ffi.cdata*
---@return string|nil
local function source_id(src)
  return cfstring(TIS.TISGetInputSourceProperty(src, TIS.kTISPropertyInputSourceID))
end

---@return string|nil
function M.get()
  if not ready then
    return nil
  end
  local src = TIS.TISCopyCurrentKeyboardInputSource()
  if src == nil then
    return nil
  end
  local id = source_id(src)
  CF.CFRelease(src) -- Copy rule: +1. Leaking this at 300ms is ~200 objects/min.
  return id
end

---@param id string
---@return boolean
function M.set(id)
  if not ready then
    return false
  end
  -- Enabled sources only: TISSelectInputSource returns paramErr for a source
  -- that is installed but not enabled, so the wider list only fails silently.
  -- Not cached — it goes stale when input sources are edited in System
  -- Settings, and set() is rare.
  local list = TIS.TISCreateInputSourceList(nil, 0)
  if list == nil then
    return false
  end
  local ok = false
  for i = 0, tonumber(CF.CFArrayGetCount(list)) - 1 do
    local src = CF.CFArrayGetValueAtIndex(list, i)
    if source_id(src) == id then
      ok = TIS.TISSelectInputSource(src) == 0
      break
    end
  end
  CF.CFRelease(list) -- Create rule: +1; the elements belong to the array.
  return ok
end

return M
