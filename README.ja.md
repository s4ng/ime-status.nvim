<h1 align="center">ime-status.nvim</h1>

<p align="center">
  <img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <b>日本語</b> | <a href="README.zh.md">中文</a>
</p>

現在のキーボード入力メソッド（한 / EN / あ / 中 …）を Neovim のステータスラインに
表示します。

Neovim 自体は OS の IME 状態を知りません — かな/英数の切り替えはエディタではなく
OS が管理しているためです。このプラグインは現在の入力ソースを OS から直接読み取り、
結果を**キャッシュ**し、タイマーとモード変更のタイミングで非同期に更新し、どんな
ステータスラインにも組み込める高速なゲッターを提供します。**lualine 専用では
ありません** — lualine は以下の例の一つにすぎません。

## 必要なもの

**Neovim だけです。** 一緒に入れるバイナリも、`PATH` から探すものもありません ——
対応するすべての OS でプロセス内から入力メソッドを読み取ります。

| OS      | 入力メソッドの読み取り方                                      |
| ------- | ------------------------------------------------------------- |
| macOS   | Carbon TIS、内蔵の LuaJIT FFI 経由                            |
| Windows | user32/imm32、内蔵の LuaJIT FFI 経由                          |
| Linux   | D-Bus で fcitx5 または ibus に直接 —— 素の Lua、FFI なし      |

各バックエンドが実際に何をしているか、1 回のポーリングのコスト、入力メソッドごとの
注意点は [**doc/backends.md**](doc/backends.md) を参照してください（英語）。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim) の場合:

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {
    auto_switch = true,          -- ノーマルモードは常に英字 → j/k が j/k のまま
    pause_on_focus_lost = true,  -- ウィンドウが非フォーカスの間はポーリング停止
  },
}
```

`opts` はそのまま `setup()` に渡されます。ポーリングタイマーを開始するのは
`setup()` なので、必ず一度は呼び出される必要があります。2 回目以降の呼び出しは
無視されずオプションを再マージするので、このプラグインを設定する 2 つのスペックが
互いの設定を黙って打ち消し合うことはありません。上の 2 つのオプションは
既定では*オフ*です。それぞれの働きと、入力を再開したときに直前の入力メソッドへ
戻す方法は
[自動切り替え](#自動切り替え--ノーマルモードで-jk-がかなで入力される問題を解決)
を参照してください。

## ステータスライン連携

このプラグインは特定のステータスラインに依存しません。
`require("ime-status").component()` は `format` を通した現在のラベルを返し、
決してブロックしません — キャッシュを読むだけなので、再描画のたびに呼んでも
コストはありません。ラベルが変わるとプラグイン自身が `redrawstatus` を呼び、
`User IMEStatusChanged` autocmd を発火します。以下のイベント駆動な
ステータスラインが引っ掛けるのは、このイベントです。

以下のスニペットは上のインストール指定が済んでいる前提で、コンポーネントだけを
追加します。

### lualine

```lua
{
  "nvim-lualine/lualine.nvim",
  dependencies = { "s4ng/ime-status.nvim" },
  opts = function(_, opts)
    table.insert(opts.sections.lualine_x, 1, { require("ime-status").component })

    -- lualine は自前のタイマー（refresh.statusline、1000 ms）と "User" を含まない
    -- 固定のイベント一覧でしか再描画しません。そのためプラグインの再描画要求が
    -- 届かず、ラベルが最大 1 秒ほど遅れることがあります。代わりに変更イベントで
    -- lualine を更新します。
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

`content.active` はマージではなく行全体を置き換えるので、mini 自身の既定
レイアウトを写した上に IME セクションを差し込みます:

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

heirline はコンポーネントの `update` に挙げたイベントでしか再評価しません。
そこにプラグイン自身のイベントを指定すれば済みます — ほかの何かが再描画する
必要はありません:

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

AstroNvim のステータスラインも中身は heirline なので、同じ形になります。

### lightline.vim

lightline のコンポーネントは Vimscript の関数なので、`luaeval()` 経由でゲッターに
到達します:

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

### ネイティブ statusline、そのほか

```lua
vim.o.statusline = " %f %m%r%=[%{v:lua.require'ime-status'.component()}] %l:%c "
```

再描画のたびに `&statusline` を評価し直すステータスラインなら、これだけで十分です
— 再描画の要求はプラグインが出しています。結果をキャッシュする側（上の lualine と
heirline）には `User IMEStatusChanged` autocmd が必要です。

## 設定

デフォルト値:

```lua
require("ime-status").setup({
  interval = 300,        -- ポーリング間隔（ミリ秒）
  insert_only = false,   -- 挿入モードのときだけポーリング
  tool = nil,            -- ネイティブバックエンドを無効にする場合: 外部ツールの名前
                         -- または絶対パス。状態の取得と切り替えの両方に使われる。
                         -- 例: "/usr/bin/ibus"
  cmd = nil,             -- 低レベル: 検出コマンドだけを上書き
  set_cmd = nil,         -- 低レベル: 切り替えコマンドだけを上書き。リストを渡すと末尾に
                         -- 対象 id が追加される。function(id) -> { ... } も可
  labels = {             -- 最初にマッチしたルールを適用（大文字小文字を無視した部分一致）
    { match = "korean",   text = "한" },  -- および hangul
    { match = "japanese", text = "あ" },  -- および kotoeri, anthy, mozc, kkc, skk
    { match = "chinese",  text = "中" },  -- および pinyin, shuangpin, bopomofo, zhuyin,
  },                                      -- cangjie, chewing, wubi, scim, tcim, …
  default = "EN",        -- どのルールにもマッチしないときに表示
  unknown = "?",         -- バックエンドが何も返さないときに表示
  format = function(label) return label end,

  -- 自動切り替え（下記参照）— すべてデフォルト off
  auto_switch = false,         -- InsertLeave / ノーマルモードでのフォーカス時に latin_source へ強制切り替え
  latin_source = nil,          -- 切り替え先の id; nil = 最後に使っていたラテン配列
  restore_on_insert = false,   -- InsertEnter 時に、自動切り替え直前の IME を復元
  pause_on_focus_lost = false, -- Neovim / ターミナルが非フォーカスのときポーリングを停止
})
```

既定のルールの多くは言語名ではなく**エンジン名**です。バックエンドが実際に報告するのが
それだからです。Linux での生の id は入力メソッドが自分を呼ぶ名前であり、日本語エンジンで
名前に "japanese" を含むものは一つもありません — `anthy`、`mozc`、`kkc`、`skk` の
すべてです。`labels` を自分で渡すとリストは**丸ごと置き換わる**ので、残したいルールも
一緒に書いてください。

あるエンジンが有効なのに `EN` と表示される場合は、`:IMEStatusReload` のあと
`:lua print(require("ime-status").raw)` で実際の id を確認してルールを追加してください。
その id を添えた issue も歓迎します。

### 自動切り替え — ノーマルモードで `j`/`k` がかなで入力される問題を解決

常駐させた Neovim バッファに入ってすぐ `j`/`k` を押したとき、IME がかなのままだと
`ま`/`の` のような文字が入力され、移動が効きません。`auto_switch = true` はこれを
*表示*するだけでなく、**原因そのものを取り除きます** — 挿入モードを抜けたとき、または
ノーマルモードでウィンドウにフォーカスが入ったときに IME を `latin_source` へ強制し、
ノーマルモードのキーが常に動作するようにします。

```lua
require("ime-status").setup({
  auto_switch = true,        -- ノーマルモードは常にラテン文字
  restore_on_insert = true,  -- ただし入力は直前に使っていた IME で再開
})
```

- `latin_source` を `nil` のままにすると、**最後に使っていたラテン配列**へ戻ります。
  ポーリングの過程でその配列を覚えているので、Dvorak や Colemak、各国のラテン配列が
  上書きされることはありません。まだ一度も観測していない場合にだけ OS のデフォルトへ
  フォールバックします（macOS `com.apple.keylayout.ABC`、Linux は fcitx5 なら
  `keyboard-us`、ibus なら `xkb:us::eng`、Windows `"en"` — FFI バックエンドはキーボード
  配列を変えずに IME だけを英数モードへ切り替えます）。Linux の二つの id 体系は互換では
  ないため、そのフォールバックは実際に応答するバックエンドに合わせて決まります。固定
  したい場合は `latin_source` を明示してください。
- `restore_on_insert` は挿入中に使っていた IME を記憶し、次の `InsertEnter` で
  復元します — CJK を入力するバッファに便利です。
- `pause_on_focus_lost = true` は Neovim が非フォーカスの間ポーリングタイマーを
  停止します（`FocusGained` で再開・更新）— バッテリー節約用です。

アイコンを付ける例:

```lua
format = function(label)
  return label == "한" and ("\u{f1ab} " .. label) or ("\u{f11c} " .. label)
end
```

## 注意点とトレードオフ

- **ポーリング、そしてポーリングが要らない場所。** ターミナル環境には「たった今 IME が
  変わった」という OS イベントがないため、状態は `interval`（ミリ秒）ごとに（さらに
  モード変更時には即座に）サンプリングされます。1 回のコストはバックエンド次第です。
  macOS と Windows はプロセス内の FFI 呼び出し、fcitx5 はすでに開いているソケットの
  往復 1 回、そして ibus は**まったくゼロ**です — 尋ねるのではなく押し込まれるので。
  プロセスが起動するのは外部ツールのフォールバックだけで、`interval` を上げたり
  `insert_only = true` にしたりが効くのもその場合だけです。
- **Linux で入力メソッドが動いていない場合は?** プラグインは穏やかに無効化されます —
  `get()` は `default` を返し、エラーは発生しません。両方の接続が再試行を続けるので、
  あとから fcitx5 や ibus を起動すれば Neovim の再起動なしに動き始めます。すぐ確認
  したい場合は `:IMEStatusReload` を実行してください。`:checkhealth ime-status` は、
  このマシンで各デーモンがどういう状態で、**なぜ**そうなのかを教えてくれます。
- **fcitx5 なのにラベルが `?` のままなら?** fcitx5 は**フォーカスされている
  クライアント**の入力メソッドを返すため、どこにもフォーカスがないと空の名前を
  返し、ラベルは `unknown` に落ちます。Neovim が背面にあるときは正常で、
  `pause_on_focus_lost = true` ならポーリング自体が止まります。ずっと `?` のままなら、
  お使いのターミナルが fcitx5 クライアントでない可能性が高いです —
  `GTK_IM_MODULE` / `QT_IM_MODULE` / `XMODIFIERS` を確認するか、`unknown = ""` で
  隠してください。
- **ターミナルでは動くのに GUI から起動すると動かない?** `tool`/`cmd` を指定して
  ネイティブバックエンドを無効にした場合のみ該当します。`.desktop` ランチャー、
  Neovide、macOS の `.app` などはシェルの rc ファイルを読まないため、ターミナルでは
  動いていたツールを `PATH` から見つけられません。`:echo $PATH` で確認し、ランチャー
  側の環境を直すか、絶対パスを直接指定してください:

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/ibus" })
  ```

  ネイティブバックエンドは `PATH` を見ません。Linux のものは fcitx5 について
  `$DBUS_SESSION_BUS_ADDRESS`（無ければ `/run/user/<uid>/bus`）を、ibus について
  `$IBUS_ADDRESS`（無ければ ibus が `~/.config/ibus/bus/` に書くファイル）を見ます。
  Neovim 内でこれらが空だったり古かったりする場合は、`:checkhealth ime-status` が
  どちらなのかと何をすべきかを教えてくれます。

## ライセンス

MIT
