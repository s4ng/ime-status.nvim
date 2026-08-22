<h1 align="center">ime-status.nvim</h1>

<p align="center">
  <img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />
</p>

<p align="center">
  <a href="README.md">English</a> | <b>한국어</b> | <a href="README.ja.md">日本語</a> | <a href="README.zh.md">中文</a>
</p>

현재 키보드 입력기(한 / EN / あ / 中 …)를 Neovim 상태줄(statusline)에 표시합니다.

Neovim 자체는 OS의 IME 상태를 알지 못합니다 — 한/영 전환은 에디터가 아니라
운영체제가 관리하기 때문입니다. 이 플러그인은 현재 입력 소스를 OS에서 직접 읽어
그 결과를 **캐싱**한 뒤, 타이머와 모드 전환 시점에 비동기로 갱신하고, 어떤
상태줄에든 꽂을 수 있는 빠른 게터(getter)를 제공합니다. **lualine 전용이
아닙니다** — lualine은 아래 예시 중 하나일 뿐입니다.

## 요구 사항

**Neovim만 있으면 됩니다.** 함께 설치할 바이너리도, `PATH`에서 찾아야 할 것도
없습니다 — 지원하는 모든 OS에서 입력기를 프로세스 안에서 직접 읽습니다.

| OS      | 입력기를 읽는 방식                                            |
| ------- | ------------------------------------------------------------- |
| macOS   | Carbon TIS, 내장 LuaJIT FFI 경유                              |
| Windows | user32/imm32, 내장 LuaJIT FFI 경유                            |
| Linux   | D-Bus로 fcitx5 또는 ibus에 직접 — 순수 Lua, FFI 없음          |

각 백엔드가 실제로 무엇을 하는지, 폴링 한 번의 비용이 얼마인지, 입력기별 제약이
무엇인지는 [**doc/backends.md**](doc/backends.md)를 보세요 (영문).

## 설치

[lazy.nvim](https://github.com/folke/lazy.nvim) 기준:

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts`는 그대로 `setup()`에 전달됩니다. 폴링 타이머를 시작하는 것이 `setup()`
이므로, 반드시 한 번은 호출되어야 합니다.

## 상태줄 연동

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

### Native statusline / heirline / 그 외

`require("ime-status").get()`은 현재 라벨 문자열을 반환하며 절대 블로킹하지
않습니다.

```lua
require("ime-status").setup()
vim.o.statusline = "%{v:lua.require'ime-status'.get()} %f"
```

라벨이 바뀔 때마다 `User IMEStatusChanged` autocmd가 발생하므로, 이벤트 기반
상태줄은 정확한 시점에 갱신할 수 있습니다.

## 설정

기본값:

```lua
require("ime-status").setup({
  interval = 300,        -- 폴링 주기 (ms)
  insert_only = false,   -- 인서트 모드일 때만 폴링
  tool = nil,            -- 네이티브 백엔드를 끌 때: 외부 도구의 이름 또는 절대경로.
                         -- 상태 읽기와 전환에 모두 사용. 예: "/usr/bin/ibus"
  cmd = nil,             -- 저수준: 탐지 명령만 직접 지정
  set_cmd = nil,         -- 저수준: 전환 명령만 직접 지정. 리스트를 주면 뒤에 대상 id가
                         -- 붙고, function(id) -> { ... } 형태도 가능
  labels = {             -- 첫 번째로 매칭되는 규칙 적용 (대소문자 무시 부분 문자열)
    { match = "korean",   text = "한" },  -- 그리고 hangul
    { match = "japanese", text = "あ" },  -- 그리고 kotoeri, anthy, mozc, kkc, skk
    { match = "chinese",  text = "中" },  -- 그리고 pinyin, shuangpin, bopomofo, zhuyin,
  },                                      -- cangjie, chewing, wubi, scim, tcim, …
  default = "EN",        -- 어떤 규칙에도 안 맞을 때 표시
  unknown = "?",         -- 백엔드가 아무것도 반환하지 않을 때 표시
  format = function(label) return label end,

  -- 자동 전환 (아래 설명) — 전부 기본 off
  auto_switch = false,         -- InsertLeave / 노멀 모드 포커스 시 latin_source로 강제 전환
  latin_source = nil,          -- 전환할 id; nil = OS 기본값 (macOS: com.apple.keylayout.ABC)
  restore_on_insert = false,   -- InsertEnter 시, 자동 전환 직전 쓰던 IME로 복원
  pause_on_focus_lost = false, -- Neovim / 터미널이 비포커스일 때 폴링 중단
})
```

기본 규칙의 대부분은 언어 이름이 아니라 **엔진 이름**입니다. 백엔드가 실제로 그걸
보고하기 때문입니다. Linux에서 원시 id는 입력기가 스스로를 부르는 이름인데, 일본어
엔진 중 이름에 "japanese"가 들어가는 것은 하나도 없습니다 — `anthy`, `mozc`, `kkc`,
`skk` 전부요. `labels`를 직접 주면 목록이 **통째로 교체**되므로, 남기고 싶은 규칙은
함께 적어 주세요.

어떤 엔진이 켜져 있는데 `EN`으로 보인다면, `:IMEStatusReload` 후
`:lua print(require("ime-status").raw)`로 실제 id를 확인하고 규칙을 추가하세요.
그 id를 담은 이슈도 환영합니다.

### 자동 전환 — 노멀 모드에서 `j`/`k`가 한글로 입력되는 문제 해결

항상 켜둔 Neovim 버퍼에 진입해 바로 `j`/`k`를 누를 때, IME가 한글로 남아 있으면
`ㅓ`/`ㅏ`가 입력되어 라인 이동이 안 됩니다. `auto_switch = true`는 이걸 *표시*만
하는 게 아니라 **원인을 제거**합니다 — 인서트 모드를 벗어나거나 노멀 모드에서 창에
포커스가 들어올 때 IME를 `latin_source`로 강제해, 노멀 모드 키가 항상 동작합니다.

```lua
require("ime-status").setup({
  auto_switch = true,        -- 노멀 모드는 항상 영문
  restore_on_insert = true,  -- 단, 타이핑은 직전에 쓰던 IME로 재개
})
```

- `latin_source`의 기본값은 OS 영문 레이아웃입니다 (macOS `com.apple.keylayout.ABC`,
  Linux는 fcitx5 `keyboard-us` / ibus `xkb:us::eng`, Windows `"en"` — FFI 백엔드가
  키보드 레이아웃은 유지한 채 IME만 영문 모드로 전환합니다). Linux의 두 id 체계는
  서로 호환되지 않으므로, 실제로 응답하는 백엔드에 맞춰 기본값이 정해집니다.
- `restore_on_insert`는 인서트 중 쓰던 IME를 기억했다가 다음 `InsertEnter`에서
  복원합니다 — 한글을 자주 입력하는 버퍼에 유용합니다.
- `pause_on_focus_lost = true`는 Neovim이 비포커스일 때 폴링 타이머를 멈춥니다
  (`FocusGained` 시 재개 및 갱신) — 배터리 절약용입니다.

아이콘을 붙이는 예시:

```lua
format = function(label)
  return label == "한" and ("\u{f1ab} " .. label) or ("\u{f11c} " .. label)
end
```

## 참고 사항 및 트레이드오프

- **폴링, 그리고 폴링이 필요 없는 곳.** 터미널 환경에는 "방금 IME가 바뀌었다"는 OS
  이벤트가 없으므로, 상태는 `interval`(ms)마다(그리고 모드 전환 시 즉시) 샘플링됩니다.
  한 번의 샘플링 비용은 백엔드마다 다릅니다. macOS와 Windows는 프로세스 내부 FFI 호출,
  fcitx5는 이미 열려 있는 소켓 위의 왕복 한 번, ibus는 **아무 비용도 없습니다** —
  묻는 게 아니라 밀어 넣어 주니까요. 프로세스를 띄우는 것은 외부 도구 폴백뿐이고,
  `interval`을 높이거나 `insert_only = true`를 두는 것이 값을 하는 경우도 그때뿐입니다.
- **Linux에서 입력기가 안 돌고 있다면?** 플러그인은 우아하게 비활성화됩니다 —
  `get()`은 `default`를 반환하고 에러는 발생하지 않습니다. 두 연결 모두 계속
  재시도하므로, 나중에 fcitx5나 ibus를 켜면 Neovim을 재시작할 필요 없이 동작하기
  시작합니다. 바로 확인하려면 `:IMEStatusReload`를 실행하세요.
  `:checkhealth ime-status`는 이 머신에서 각 데몬이 어떤 상태이고 **왜** 그런지
  알려줍니다.
- **fcitx5인데 라벨이 계속 `?`로 보인다면?** fcitx5는 **포커스된 클라이언트**의
  입력기를 알려주므로, 포커스가 아무 데도 없으면 빈 이름을 반환하고 라벨은
  `unknown`으로 떨어집니다. Neovim이 백그라운드일 때는 정상이며,
  `pause_on_focus_lost = true`면 아예 폴링을 멈춥니다. 계속 `?`만 보인다면 쓰시는
  터미널이 fcitx5 클라이언트가 아닐 가능성이 큽니다 — `GTK_IM_MODULE` /
  `QT_IM_MODULE` / `XMODIFIERS`를 확인하시거나, `unknown = ""`으로 숨기세요.
- **터미널에서는 되는데 GUI로 Neovim을 띄우면 안 된다면?** `tool`/`cmd`를 지정해
  네이티브 백엔드를 끈 경우에만 해당됩니다. `.desktop` 런처, Neovide, macOS `.app` 등은
  셸 rc 파일을 읽지 않으므로, 터미널에서는 되던 도구를 `PATH`에서 찾지 못합니다.
  `:echo $PATH`로 확인한 뒤, 런처의 환경을 고치거나 절대경로를 직접 지정하세요:

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/ibus" })
  ```

  네이티브 백엔드는 `PATH`를 보지 않습니다. Linux 백엔드는 fcitx5에 대해
  `$DBUS_SESSION_BUS_ADDRESS`(없으면 `/run/user/<uid>/bus`)를, ibus에 대해
  `$IBUS_ADDRESS`(없으면 ibus가 `~/.config/ibus/bus/`에 쓴 파일)를 봅니다. Neovim
  안에서 이 값들이 비어 있거나 낡았다면 `:checkhealth ime-status`가 어느 쪽인지와
  무엇을 해야 하는지 알려줍니다.

## 라이선스

MIT
