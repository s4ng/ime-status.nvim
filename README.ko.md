# ime-status.nvim

<img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />

### [English](README.md) | **한국어**

현재 키보드 입력기(한 / EN / あ / 中 …)를 Neovim 상태줄(statusline)에 표시합니다.

Neovim 자체는 OS의 IME 상태를 알지 못합니다 — 한/영 전환은 에디터가 아니라
운영체제가 관리하기 때문입니다. 이 플러그인은 외부 도구에 현재 입력 소스를
물어보고, 그 결과를 **캐싱**한 뒤, 타이머와 모드 전환 시점에 비동기로 갱신하고,
어떤 상태줄에든 꽂을 수 있는 빠른 게터(getter)를 제공합니다. **lualine 전용이
아닙니다** — lualine은 아래 예시 중 하나일 뿐입니다.

## 요구 사항

현재 입력 소스를 출력해 주는 외부 도구가 필요합니다. 이 플러그인은 해당 도구를
**대신 설치하지 않습니다**(Neovim 플러그인 매니저는 git 레포만 관리하며 시스템
바이너리는 관리하지 않습니다). `:checkhealth ime-status`를 실행하면 무엇을
설치해야 하는지 알려줍니다.

| OS      | 도구                                                                 |
| ------- | -------------------------------------------------------------------- |
| macOS   | [`macism`](https://github.com/laishulu/macism) 또는 `im-select`      |
| Windows | [`im-select.exe`](https://github.com/daipeihust/im-select)           |
| Linux   | `ibus` 또는 `fcitx5-remote` (실험적 — `cmd` 직접 지정이 필요할 수 있음) |

```sh
# macOS — 반드시 tap 경로를 포함해야 합니다. 그냥 `brew install macism`은
# 실패합니다 (macism은 homebrew-core가 아니라 별도 tap에 있습니다).
brew install laishulu/homebrew/macism
```

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
  cmd = nil,             -- 탐지 명령 직접 지정, 예: { "im-select" }
  labels = {             -- 첫 번째로 매칭되는 규칙 적용 (대소문자 무시 부분 문자열)
    { match = "korean",   text = "한" },
    { match = "hangul",   text = "한" },
    { match = "japanese", text = "あ" },
    { match = "pinyin",   text = "中" },
    { match = "chinese",  text = "中" },
  },
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
  Linux ibus `xkb:us::eng`). Windows에서는 im-select id를 직접 지정하세요.
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

- **폴링은 불가피합니다.** 터미널 환경에는 "방금 OS가 IME를 전환했다"는 이벤트가
  없으므로, 상태는 `interval`(ms)마다(그리고 모드 전환 시 즉시) 샘플링됩니다.
  `interval`을 낮추면 반응이 빠르지만 그만큼 서브프로세스가 자주 실행되고, 높이거나
  `insert_only = true`로 두면 비용이 줄어듭니다.
- **도구가 설치되지 않았다면?** 플러그인은 우아하게 비활성화됩니다 — `get()`은
  `default`를 반환하고 에러는 발생하지 않습니다. `:checkhealth ime-status`를
  참고하세요.

## 라이선스

MIT
