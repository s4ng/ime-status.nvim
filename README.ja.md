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

Neovim だけです。macOS と Windows では内蔵の LuaJIT FFI を通じてプロセス内で IME を
直接照会するため、一緒に入れるバイナリも、`PATH` から探すものもありません。

| OS      | インストールするもの                                                  |
| ------- | -------------------------------------------------------------------- |
| macOS   | なし — 内蔵 FFI バックエンド（Carbon TIS）                            |
| Windows | なし — 内蔵 FFI バックエンド（user32/imm32）                          |
| Linux   | `ibus` または `fcitx5-remote`（実験的 — `cmd` の指定が必要な場合あり） |

macOS のバックエンドは Carbon の TIS API を呼ぶため、入力ソース id はシステム全体で
使われる値とまったく同じです。Windows のバックエンドは user32/imm32 を経由し、その
おかげで日本語/韓国語/中国語 IME **内部のかな/英数トグル状態**まで見えます —
`im-select` のようなレイアウト照会ツールでは原理的に分からない状態です。

**Linux だけが例外です。** 呼び出せる OS レベルの API がなく、入力メソッドが状態を
自身の CLI 経由でしか公開していないため、プラグインは `ibus` か `fcitx5-remote`
（お使いの入力メソッドに付属する方）を実行するほかありません。それを**代わりに
インストールはしません**（Neovim のプラグインマネージャは git リポジトリのみを管理し、
システムバイナリは管理しません）。`:checkhealth ime-status` を実行すると、何を
インストールすべきか教えてくれます。

> LuaJIT ではなく素の Lua でビルドされた Neovim には FFI がありません。その場合は
> `macism` / `im-select.exe` が `PATH` にあればそちらにフォールバックします。

## インストール

[lazy.nvim](https://github.com/folke/lazy.nvim) の場合:

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts` はそのまま `setup()` に渡されます。ポーリングタイマーを開始するのは
`setup()` なので、必ず一度は呼び出される必要があります。

## ステータスライン連携

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

### ネイティブ statusline / heirline / その他

`require("ime-status").get()` は現在のラベル文字列を返し、決してブロックしません。

```lua
require("ime-status").setup()
vim.o.statusline = "%{v:lua.require'ime-status'.get()} %f"
```

ラベルが変わるたびに `User IMEStatusChanged` autocmd が発火するので、イベント駆動の
ステータスラインは正確なタイミングで更新できます。

## 設定

デフォルト値:

```lua
require("ime-status").setup({
  interval = 300,        -- ポーリング間隔（ミリ秒）
  insert_only = false,   -- 挿入モードのときだけポーリング
  tool = nil,            -- Linux 用、またはネイティブバックエンドを無効にする場合: 入力
                         -- ソースツールの名前または絶対パス。状態の取得と切り替えの
                         -- 両方に使われる。例: "/usr/bin/fcitx5-remote"
  cmd = nil,             -- 低レベル: 検出コマンドだけを上書き
  set_cmd = nil,         -- 低レベル: 切り替えコマンドだけを上書き。リストを渡すと末尾に
                         -- 対象 id が追加される。function(id) -> { ... } も可
  labels = {             -- 最初にマッチしたルールを適用（大文字小文字を無視した部分一致）
    { match = "korean",   text = "한" },
    { match = "hangul",   text = "한" },
    { match = "japanese", text = "あ" },
    { match = "pinyin",   text = "中" },
    { match = "chinese",  text = "中" },
  },
  default = "EN",        -- どのルールにもマッチしないときに表示
  unknown = "?",         -- バックエンドが何も返さないときに表示
  format = function(label) return label end,

  -- 自動切り替え（下記参照）— すべてデフォルト off
  auto_switch = false,         -- InsertLeave / ノーマルモードでのフォーカス時に latin_source へ強制切り替え
  latin_source = nil,          -- 切り替え先の id; nil = OS デフォルト（macOS: com.apple.keylayout.ABC）
  restore_on_insert = false,   -- InsertEnter 時に、自動切り替え直前の IME を復元
  pause_on_focus_lost = false, -- Neovim / ターミナルが非フォーカスのときポーリングを停止
})
```

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

- `latin_source` のデフォルトは OS のラテン配列です（macOS `com.apple.keylayout.ABC`、
  Linux ibus `xkb:us::eng`、Windows `"en"` — FFI バックエンドはキーボード配列を
  変えずに IME だけを英数モードへ切り替えます）。
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

- **ポーリングは避けられません。** ターミナル環境には「OS がたった今 IME を切り替えた」
  というイベントがないため、状態は `interval`（ミリ秒）ごとに（さらにモード変更時には
  即座に）サンプリングされます。macOS と Windows では 1 回のサンプリングがプロセス内の
  FFI 呼び出しなので、デフォルトの 300 ms でもコストはほぼゼロです。Linux では
  サンプリングのたびに `ibus`/`fcitx5-remote` が起動するため、気になる場合は
  `interval` を上げるか `insert_only = true` にしてください。
- **Linux でツールが未インストールなら?** プラグインは穏やかに無効化されます — `get()`
  は `default` を返し、エラーは発生しません。検出は作業中も再試行されるので、あとから
  ツールをインストールしても Neovim の再起動は不要です。すぐ確認したい場合は
  `:IMEStatusReload` を実行してください。`:checkhealth ime-status` も参照してください。
- **ターミナルでは動くのに GUI から起動すると動かない?** Linux で起こる問題で、
  macOS/Windows では `tool`/`cmd` を指定してネイティブバックエンドを無効にした場合
  のみ該当します。`.desktop` ランチャー、Neovide、macOS の `.app` などはシェルの rc
  ファイルを読まないため、`PATH` からツールを見つけられません。`:echo $PATH` で
  確認し、ランチャー側の環境を直すか、絶対パスを直接指定してください:

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/fcitx5-remote" })
  ```

## ライセンス

MIT
