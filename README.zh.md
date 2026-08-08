<h1 align="center">ime-status.nvim</h1>

<p align="center">
  <img width="500" height="312" alt="nvim demonstration" src="https://github.com/user-attachments/assets/e8986d4a-7f85-4cae-8c6c-aa17696a9a8e" />
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a> | <a href="README.ja.md">日本語</a> | <b>中文</b>
</p>

在 Neovim 状态栏中显示当前键盘输入法（한 / EN / あ / 中 …）。

Neovim 本身并不知道操作系统当前处于哪种 IME 状态 —— 中英文切换由操作系统管理，而非
编辑器。本插件直接从操作系统读取当前输入源，**缓存**结果，并在定时器和模式切换时
异步刷新，同时提供一个可嵌入任意状态栏的快速 getter。它**并不局限于 lualine** ——
lualine 只是下面示例之一。

## 依赖

只需要 Neovim。在 macOS 和 Windows 上，插件通过内置的 LuaJIT FFI 在进程内直接查询
IME —— 没有需要一并安装的二进制文件，也不用在 `PATH` 里查找任何东西。

| 操作系统 | 需要安装什么                                                         |
| -------- | -------------------------------------------------------------------- |
| macOS    | 无 —— 内置 FFI 后端（Carbon TIS）                                    |
| Windows  | 无 —— 内置 FFI 后端（user32/imm32）                                  |
| Linux    | `ibus` 或 `fcitx5-remote`（实验性 —— 可能需要自定义 `cmd`）          |

macOS 后端调用 Carbon 的 TIS API，因此读到的输入源 id 与系统全局使用的完全一致。
Windows 后端走 user32/imm32，这也让中文/韩语/日语 IME **内部的中英文切换状态**变得
可见 —— 这是 `im-select` 这类只查询键盘布局的工具根本无法得知的状态。

**Linux 是唯一的例外。** 那里没有可调用的系统级 API，输入法只通过自己的 CLI 暴露
状态，所以插件只能去执行 `ibus` 或 `fcitx5-remote`（取决于你用的是哪个输入法）。
本插件**不会替你安装它**（Neovim 插件管理器只管理 git 仓库，不管理系统二进制
文件）。运行 `:checkhealth ime-status` 会告诉你需要安装什么。

> 用纯 Lua 而非 LuaJIT 构建的 Neovim 没有 FFI。此时若 `PATH` 中存在
> `macism` / `im-select.exe`，插件会回退到它们。

## 安装

使用 [lazy.nvim](https://github.com/folke/lazy.nvim)：

```lua
{
  "s4ng/ime-status.nvim",
  event = "VeryLazy",
  opts = {},
}
```

`opts` 会直接传给 `setup()`。启动轮询定时器的正是 `setup()`，因此它必须被调用一次。

## 状态栏集成

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

### 原生 statusline / heirline / 其他

`require("ime-status").get()` 返回当前的标签字符串，且绝不会阻塞。

```lua
require("ime-status").setup()
vim.o.statusline = "%{v:lua.require'ime-status'.get()} %f"
```

每当标签发生变化时，插件会触发 `User IMEStatusChanged` autocmd，因此事件驱动的状态栏
可以在精确的时机刷新。

## 配置

默认值：

```lua
require("ime-status").setup({
  interval = 300,        -- 轮询间隔（毫秒）
  insert_only = false,   -- 仅在插入模式下轮询
  tool = nil,            -- 用于 Linux，或用于关闭原生后端：输入源工具的名称或绝对路径，
                         -- 读取状态和切换都会使用，例如 "/usr/bin/fcitx5-remote"
  cmd = nil,             -- 底层：仅覆盖检测命令
  set_cmd = nil,         -- 底层：仅覆盖切换命令。传列表时会在末尾追加目标 id，
                         -- 也可以传 function(id) -> { ... }
  labels = {             -- 采用第一个匹配的规则（不区分大小写的子串匹配）
    { match = "korean",   text = "한" },
    { match = "hangul",   text = "한" },
    { match = "japanese", text = "あ" },
    { match = "pinyin",   text = "中" },
    { match = "chinese",  text = "中" },
  },
  default = "EN",        -- 没有规则匹配时显示
  unknown = "?",         -- 后端没有返回内容时显示
  format = function(label) return label end,

  -- 自动切换（见下文）—— 全部默认关闭
  auto_switch = false,         -- 在 InsertLeave / 普通模式下获得焦点时强制切换到 latin_source
  latin_source = nil,          -- 要切换到的 id；nil = 操作系统默认值（macOS: com.apple.keylayout.ABC）
  restore_on_insert = false,   -- 进入插入模式时，恢复自动切换之前使用的 IME
  pause_on_focus_lost = false, -- 当 Neovim / 终端失去焦点时停止轮询
})
```

### 自动切换 —— 解决普通模式下 `j`/`k` 被输入成中文/韩文的问题

如果你常驻一个 Neovim 缓冲区，进入后立刻按 `j`/`k`，而 IME 仍停留在中文/韩文状态，
这些按键会被当作输入法字符吞掉，移动失效。`auto_switch = true` 不只是*显示*状态，而是
**消除根因**：在你离开插入模式、或在普通模式下使窗口获得焦点时，强制将 IME 切换到
`latin_source`，从而保证普通模式按键始终有效。

```lua
require("ime-status").setup({
  auto_switch = true,        -- 普通模式始终为拉丁文
  restore_on_insert = true,  -- 但输入时恢复到你上次使用的 IME
})
```

- `latin_source` 默认为操作系统的拉丁键盘布局（macOS `com.apple.keylayout.ABC`，
  Linux ibus `xkb:us::eng`，Windows `"en"` —— FFI 后端在不改变键盘布局的情况下
  仅将 IME 切换到英文模式）。
- `restore_on_insert` 会记住插入期间使用的 IME，并在下一次 `InsertEnter` 时恢复 ——
  对需要输入 CJK 的缓冲区很方便。
- `pause_on_focus_lost = true` 会在 Neovim 失去焦点时停止轮询定时器（在 `FocusGained`
  时恢复并刷新）—— 用于节省电量。

添加图标的示例：

```lua
format = function(label)
  return label == "한" and ("\u{f1ab} " .. label) or ("\u{f11c} " .. label)
end
```

## 说明与权衡

- **轮询是必要的。** 在终端环境中没有“操作系统刚刚切换了 IME”这样的事件，因此状态会
  每隔 `interval`（毫秒）采样一次（并在模式切换时立即采样）。在 macOS 和 Windows 上，
  一次采样就是一次进程内的 FFI 调用，所以默认的 300 ms 几乎没有开销。在 Linux 上每次
  采样都会启动 `ibus`/`fcitx5-remote`，若觉得有负担，可调高 `interval` 或设置
  `insert_only = true`。
- **Linux 上没有安装工具？** 插件会优雅地停用 —— `get()` 返回 `default`，不会报错。
  检测会在使用过程中持续重试，所以之后再安装工具也无需重启 Neovim；想立即验证可以
  运行 `:IMEStatusReload`。另请参阅 `:checkhealth ime-status`。
- **在终端里正常，但从 GUI 启动 Neovim 就不行？** 这是 Linux 上的问题；在
  macOS/Windows 上只有当你指定了 `tool`/`cmd` 从而关闭原生后端时才会出现。
  `.desktop` 启动器、Neovide、macOS 的 `.app` 等不会读取 shell 的 rc 文件，因此在
  `PATH` 中找不到工具。请用 `:echo $PATH` 确认，然后修复启动器的环境，或直接指定
  绝对路径：

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/fcitx5-remote" })
  ```

## 许可证

MIT
