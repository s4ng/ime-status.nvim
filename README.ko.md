<h1 align="center">ime-status.nvim</h1>

<p align="center">
  <img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />
</p>

<p align="center">
  <a href="README.md">English</a> | <b>한국어</b> | <a href="README.ja.md">日本語</a> | <a href="README.zh.md">中文</a>
</p>

현재 키보드 입력기(한 / EN / あ / 中 …)를 Neovim 상태줄(statusline)에 표시합니다.

Neovim은 OS의 IME 상태를 알지 못합니다. 한/영 전환은 운영체제가 관리하고, 그
사실은 에디터에 전달되지 않습니다. 이 플러그인은 현재 입력 소스를 OS에서 직접 읽어
그 결과를 **캐싱**한 뒤, 타이머와 모드 전환 시점에 비동기로 갱신하고, 어떤
상태줄에든 꽂을 수 있는 빠른 게터(getter)를 제공합니다. 아래 예시에는 상태줄
다섯 종이 나옵니다.

## 요구 사항

**Neovim만 있으면 됩니다.** 함께 설치할 바이너리도, `PATH`에서 찾아야 할 것도
없습니다. 지원하는 모든 OS에서 입력기를 프로세스 안에서 직접 읽습니다.

| OS      | 입력기를 읽는 방식                                  |
| ------- | --------------------------------------------------- |
| macOS   | Carbon TIS, 내장 LuaJIT FFI 경유                    |
| Windows | user32/imm32, 내장 LuaJIT FFI 경유                  |
| Linux   | D-Bus로 fcitx5 또는 ibus에 직접, 순수 Lua (FFI 없음) |

각 백엔드가 어떻게 동작하는지, 폴링 한 번의 비용이 얼마인지, 입력기별 제약이
무엇인지는 [**doc/backends.md**](doc/backends.md)를 보세요 (영문).

## 설치

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {
    auto_switch = true,          -- 노멀 모드는 항상 영문 → j/k가 j/k로 동작
    pause_on_focus_lost = true,  -- 창이 포커스를 잃으면 폴링 중지
  },
}
```

<details>
<summary>다른 플러그인 관리자</summary>

이 플러그인에는 `plugin/` 디렉터리가 없어서, `setup()`을 부르기 전까지는 아무 일도
일어나지 않습니다. lazy.nvim은 `opts`가 대신 불러주지만, 그 외에는 직접 호출해야
합니다.

### vim.pack (Neovim 0.12+ 내장)

```lua
vim.pack.add({ "https://github.com/s4ng/ime-status.nvim" })

require("ime-status").setup({
  auto_switch = true,
  pause_on_focus_lost = true,
})
```

### mini.deps

```lua
MiniDeps.add("s4ng/ime-status.nvim")

MiniDeps.later(function()
  require("ime-status").setup({
    auto_switch = true,
    pause_on_focus_lost = true,
  })
end)
```

### vim-plug

```lua
vim.cmd([[
  call plug#begin(stdpath('data') . '/plugged')
  Plug 's4ng/ime-status.nvim'
  call plug#end()
]])

require("ime-status").setup({
  auto_switch = true,
  pause_on_focus_lost = true,
})
```

새 설정에서는 위 `require`가 아직 읽을 것이 없습니다. `:PlugInstall`을 실행하고
Neovim을 한 번 다시 켜면 그 뒤로는 문제없습니다.

</details>

`opts`는 그대로 `setup()`으로 넘어갑니다. 폴링 타이머는 `setup()`이 시작하므로 한
번은 호출해야 합니다. 두 번째 호출은 옵션을 다시 병합하므로, 이 플러그인을 함께
설정하는 두 스펙이 서로의 설정을 지우는 일은 없습니다. 위 두 옵션의 기본값은
*꺼짐*입니다. 각각 무엇을 하는지, 그리고 입력을 시작할 때 쓰던 입력기로
되돌아오게 하는 방법은
[자동 전환](#자동-전환-노멀-모드에서-jk가-한글로-입력되는-문제-해결) 절을 보세요.

## 상태줄 연동

이 플러그인은 특정 상태줄에 묶여 있지 않습니다.
`require("ime-status").component()`는 `format`을 거친 현재 라벨을 반환하며
블로킹하지 않습니다. 캐시를 읽기 때문에 매 redraw마다 호출해도 비용이 없습니다.
라벨이 바뀌면 플러그인이 직접 `redrawstatus`를 호출하고 `User IMEStatusChanged`
autocmd를 발생시킵니다. 아래의 이벤트 기반 상태줄들은 이 autocmd에 붙습니다.

아래 스니펫은 설치와 `setup()`이 끝난 것을 전제로, 컴포넌트만 추가합니다.

### lualine

```lua
{
  "nvim-lualine/lualine.nvim",
  dependencies = { "s4ng/ime-status.nvim" },
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, { require("ime-status").component })

    -- lualine은 자체 타이머(refresh.statusline, 1000 ms)와 "User"가 들어 있지
    -- 않은 고정 이벤트 목록으로만 다시 그립니다. 그래서 플러그인의 redraw 요청이
    -- 닿지 않아 라벨이 최대 1초까지 뒤처질 수 있습니다. 대신 변경 이벤트에서
    -- lualine을 갱신하세요.
    vim.api.nvim_create_autocmd("User", {
      pattern = "IMEStatusChanged",
      callback = function()
        require("lualine").refresh({ place = { "statusline" } })
      end,
    })
  end,
}
```

### mini.statusline

`content.active`는 상태줄 전체를 교체하므로, mini의 기본 레이아웃을 복사한 뒤 그
안에 IME 구획을 넣습니다:

```lua
{
  "echasnovski/mini.statusline",
  dependencies = { "s4ng/ime-status.nvim" },
  config = function()
    local MiniStatusline = require("mini.statusline")
    MiniStatusline.setup({
      content = {
        active = function()
          local mode, mode_hl = MiniStatusline.section_mode({ trunc_width = 120 })
          local git = MiniStatusline.section_git({ trunc_width = 40 })
          local diagnostics = MiniStatusline.section_diagnostics({ trunc_width = 75 })
          local filename = MiniStatusline.section_filename({ trunc_width = 140 })
          local location = MiniStatusline.section_location({ trunc_width = 75 })
          return MiniStatusline.combine_groups({
            { hl = mode_hl, strings = { mode } },
            { hl = "MiniStatuslineDevinfo", strings = { git, diagnostics } },
            "%<",
            { hl = "MiniStatuslineFilename", strings = { filename } },
            "%=",
            { hl = "MiniStatuslineFileinfo", strings = { require("ime-status").component() } },
            { hl = mode_hl, strings = { location } },
          })
        end,
      },
    })
  end,
}
```

### heirline

heirline은 컴포넌트의 `update`에 적힌 이벤트에서만 다시 평가합니다. 그러니 그
자리에 플러그인의 이벤트를 넣으면 됩니다. 다른 것이 redraw될 필요는 없습니다:

```lua
local IME = {
  provider = function()
    return " " .. require("ime-status").component() .. " "
  end,
  update = { "User", pattern = "IMEStatusChanged" },
}

require("heirline").setup({
  statusline = { Mode, Space, FileName, Align, IME, Ruler },
})
```

AstroNvim의 상태줄도 속은 heirline이므로 형태가 같습니다.

### lightline.vim

lightline의 컴포넌트는 Vimscript 함수이므로, `luaeval()`을 통해 게터에 닿습니다:

```lua
vim.cmd([[
  function! IMEStatusLightline() abort
    return luaeval("require('ime-status').component()")
  endfunction
]])

vim.g.lightline = {
  active = {
    left = { { "mode", "paste" }, { "readonly", "filename", "modified" } },
    right = { { "lineinfo" }, { "percent" }, { "ime", "filetype" } },
  },
  component_function = { ime = "IMEStatusLightline" },
}
```

### 기본 statusline, 그리고 그 외

```lua
vim.o.statusline = " %f %m%r%=[%{v:lua.require'ime-status'.component()}] %l:%c "
```

redraw할 때마다 `&statusline`을 다시 평가하는 상태줄이라면 이것으로 끝입니다.
redraw 요청은 플러그인이 이미 보냅니다. 결과를 캐시하는 쪽(위의 lualine과
heirline)에는 `User IMEStatusChanged` autocmd가 필요합니다.

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

  -- 자동 전환 (아래 설명), 전부 기본 off
  auto_switch = false,         -- InsertLeave / 노멀 모드 포커스 시 latin_source로 강제 전환
  latin_source = nil,          -- 전환할 id; nil = 마지막으로 쓰던 영문 레이아웃
  restore_on_insert = false,   -- InsertEnter 시, 자동 전환 직전 쓰던 IME로 복원
  pause_on_focus_lost = false, -- Neovim / 터미널이 비포커스일 때 폴링 중단
})
```

기본 규칙은 대부분 **엔진 이름**을 매칭합니다. 백엔드가 보고하는 것이 그 이름이기
때문입니다. Linux에서 원시 id는 입력기가 스스로를 부르는 이름인데, 일본어 엔진
(`anthy`, `mozc`, `kkc`, `skk`) 중 이름에 "japanese"가 들어가는 것은 없습니다.
`labels`를 직접 주면 목록이 **통째로 교체**되므로, 남기고 싶은 규칙은 함께 적어
주세요.

어떤 엔진이 켜져 있는데 `EN`으로 보인다면, `:IMEStatusReload` 후
`:lua print(require("ime-status").raw)`로 실제 id를 확인하고 규칙을 추가하세요.
그 id를 담은 이슈도 환영합니다.

### 자동 전환: 노멀 모드에서 `j`/`k`가 한글로 입력되는 문제 해결

항상 켜둔 Neovim 버퍼에 진입해 바로 `j`/`k`를 누를 때, IME가 한글로 남아 있으면
`ㅓ`/`ㅏ`가 입력되어 라인 이동이 안 됩니다. `auto_switch = true`는 **원인을
제거**합니다. 인서트 모드를 벗어나거나 노멀 모드에서 창에 포커스가 들어올 때 IME를
`latin_source`로 강제하므로, 노멀 모드 키가 계속 동작합니다.

```lua
require("ime-status").setup({
  auto_switch = true,        -- 노멀 모드는 항상 영문
  restore_on_insert = true,  -- 단, 타이핑은 직전에 쓰던 IME로 재개
})
```

- `latin_source`를 `nil`로 두면 **마지막으로 쓰던 영문 레이아웃**으로 돌아갑니다.
  폴링하면서 그 값을 기억해 두므로 Dvorak, Colemak, 각국 라틴 레이아웃이 그대로
  유지됩니다. 아직 한 번도 관측하지 못했을 때만 OS 기본값으로 폴백합니다
  (macOS `com.apple.keylayout.ABC`, Linux는 fcitx5 `keyboard-us` / ibus
  `xkb:us::eng`, Windows `"en"`. 이 값은 키보드 레이아웃을 유지한 채 IME만 영문
  모드로 바꿉니다). Linux의 두 id 체계는 서로 호환되지 않으므로, 그 폴백은 실제로
  응답하는 백엔드에 맞춰 정해집니다. 고정하고 싶으면 `latin_source`를 직접
  지정하세요.
- `restore_on_insert`는 인서트 중 쓰던 IME를 기억했다가 다음 `InsertEnter`에서
  복원합니다. 한글을 자주 입력하는 버퍼에 유용합니다.
- `pause_on_focus_lost = true`는 Neovim이 비포커스일 때 폴링 타이머를 멈춥니다
  (`FocusGained` 시 재개 및 갱신). 배터리 절약용입니다.

아이콘을 붙이는 예시:

```lua
format = function(label)
  return label == "한" and ("\u{f1ab} " .. label) or ("\u{f11c} " .. label)
end
```

## 참고 사항 및 트레이드오프

- **폴링, 그리고 그 비용.** 터미널 환경에는 "방금 IME가 바뀌었다"는 OS 이벤트가
  없으므로, 플러그인이 `interval`(ms)마다, 그리고 모드가 바뀔 때 상태를
  샘플링합니다. 한 번의 샘플링 비용은 백엔드마다 다릅니다. macOS와 Windows는
  프로세스 내부 FFI 호출, fcitx5는 이미 열려 있는 소켓 위의 왕복 한 번, ibus는
  **아무 비용도 없습니다**. 값을 먼저 밀어 넣어 주기 때문입니다. 프로세스를 띄우는
  것은 외부 도구 폴백뿐이고, `interval`을 높이거나 `insert_only = true`를 두는 것이
  값을 하는 경우도 그때뿐입니다.
- **Linux에 입력기가 없을 때.** `get()`은 `default`를 반환하고 에러는 발생하지
  않습니다. 두 연결 모두 계속 재시도하므로, 나중에 fcitx5나 ibus를 켜면 Neovim을
  재시작할 필요 없이 동작하기 시작합니다. 바로 확인하려면 `:IMEStatusReload`를
  실행하세요. `:checkhealth ime-status`는 이 머신에서 각 데몬이 어떤 상태이고
  **왜** 그런지 알려줍니다.
- **fcitx5에서 라벨이 `?`에 머무를 때.** fcitx5는 **포커스된 클라이언트**의 입력기를
  알려주므로, 포커스가 아무 데도 없으면 빈 이름을 반환하고 라벨은 `unknown`으로
  떨어집니다. Neovim이 백그라운드일 때는 정상이며, `pause_on_focus_lost = true`면
  아예 폴링을 멈춥니다. 계속 `?`만 보인다면 쓰시는 터미널이 fcitx5 클라이언트가
  아닐 수 있습니다. `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS`를 확인하시거나,
  `unknown = ""`으로 숨기세요.
- **터미널 대신 GUI로 Neovim을 띄웠을 때.** `tool`/`cmd`를 지정해 네이티브 백엔드를
  끈 경우에만 해당됩니다. `.desktop` 런처, Neovide, macOS `.app` 등은 셸 rc 파일을
  읽지 않으므로, 터미널에서는 되던 도구를 `PATH`에서 찾지 못합니다. `:echo $PATH`로
  확인한 뒤, 런처의 환경을 고치거나 절대경로를 직접 지정하세요:

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
