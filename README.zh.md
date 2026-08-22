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

只需要 Neovim。在所有受支持的系统上，插件都在进程内读取 IME —— macOS 和 Windows 通过
内置的 LuaJIT FFI，Linux 则直接用 D-Bus 与输入法守护进程对话。没有需要一并安装的
二进制文件，也不用在 `PATH` 里查找任何东西。

| 操作系统 | 需要安装什么                                                         |
| -------- | -------------------------------------------------------------------- |
| macOS    | 无 —— 内置 FFI 后端（Carbon TIS）                                    |
| Windows  | 无 —— 内置 FFI 后端（user32/imm32）                                  |
| Linux    | 无 —— 内置 D-Bus 后端（fcitx5 与 ibus）                               |

macOS 后端调用 Carbon 的 TIS API，因此读到的输入源 id 与系统全局使用的完全一致。
Windows 后端走 user32/imm32，这也让中文/韩语/日语 IME **内部的中英文切换状态**变得
可见 —— 这是 `im-select` 这类只查询键盘布局的工具根本无法得知的状态。

**Linux 没有可调用的系统级 API。** 状态归输入法所有，且只通过它自己的 IPC 暴露。
不过实际会用到的两个守护进程都讲 D-Bus，所以插件也用 D-Bus 回话 —— 不用 FFI，纯 Lua
操作套接字，既不创建进程也不查 `PATH`。

两者不共用总线：fcitx5 在会话总线上应答，而 ibus 自己起一条私有总线，并把地址写到
`~/.config/ibus/bus/`。插件对两者各保持一条连接，用**实际在运行的那一个**。因此两个
都没有的机器根本不会打开套接字，而中途启动或停止某个守护进程也能跟上。

两者并不对称，这决定了 `interval` 的真实开销：

- **fcitx5** 没有声明“当前输入法已改变”的信号 —— 它的 `Controller1` 只有一个信号，
  而那是关于输入法**组**的。所以它需要轮询。一次采样就是在已经打开的套接字上做一次
  `CurrentInputMethod` 往返，也就是 `fcitx5-remote -n` 所做的同一个调用，只是不创建
  进程。
- **ibus** 每次切换都会发出 `GlobalEngineChanged`，因此**完全不轮询**。插件订阅一次，
  之后一次采样就只是读取守护进程早已推送过来的值。

两条连接还都监听 `NameOwnerChanged`，所以启动或停止守护进程会在下一次重绘时反映出来，
而不必等重试计时器。

> 有一个 D-Bus 也解决不了的 ibus 限制：ibus 不暴露输入法**内部**的中英文切换状态 ——
> 用那个切换时标签会保持不变。请把切换键配置为切换 ibus **引擎**，或者改用 fcitx5。
> 运行 `:checkhealth ime-status` 会说明当前情况。

> 用纯 Lua 而非 LuaJIT 构建的 Neovim 没有 FFI。此时 macOS/Windows 后端会在 `PATH`
> 中存在 `macism` / `im-select.exe` 时回退到它们。Linux 后端不使用 FFI，不受影响。

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
  tool = nil,            -- 用于关闭原生后端：外部工具的名称或绝对路径，
                         -- 读取状态和切换都会使用，例如 "/usr/bin/ibus"
  cmd = nil,             -- 底层：仅覆盖检测命令
  set_cmd = nil,         -- 底层：仅覆盖切换命令。传列表时会在末尾追加目标 id，
                         -- 也可以传 function(id) -> { ... }
  labels = {             -- 采用第一个匹配的规则（不区分大小写的子串匹配）
    { match = "korean",   text = "한" },  -- 以及 hangul
    { match = "japanese", text = "あ" },  -- 以及 kotoeri, anthy, mozc, kkc, skk
    { match = "chinese",  text = "中" },  -- 以及 pinyin, shuangpin, bopomofo, zhuyin,
  },                                      -- cangjie, chewing, wubi, scim, tcim, …
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

默认规则大多是**引擎名**而不是语言名，因为后端实际报告的就是引擎名。在 Linux 上，原始
id 就是输入法对自己的称呼，而没有任何一个日文引擎的名字里含有 "japanese" —— `anthy`、
`mozc`、`kkc`、`skk` 都是如此。中文这边同理：只有 `pinyin` 系的名字能靠语言名碰巧匹配
上，`cangjie`、`bopomofo`、`chewing`、`wubi` 都不行。自己传 `labels` 会**整体替换**
这个列表，所以想保留的规则要一并写上。

如果某个引擎明明启用了却显示成 `EN`，请先运行 `:IMEStatusReload`，再用
`:lua print(require("ime-status").raw)` 查看它实际报告的 id，然后为它加一条规则 ——
也欢迎带上该 id 提 issue。

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
  Linux 在 fcitx5 上是 `keyboard-us`、在 ibus 上是 `xkb:us::eng`，Windows `"en"` ——
  FFI 后端在不改变键盘布局的情况下仅将 IME 切换到英文模式）。Linux 的两套 id 并不通用，
  因此默认值取决于实际应答的后端。
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

- **轮询，以及哪里不需要轮询。** 在终端环境中没有“IME 刚刚改变”这样的系统事件，因此
  状态会每隔 `interval`（毫秒）采样一次（并在模式切换时立即采样）。一次采样的开销取决
  于后端：macOS 和 Windows 上是一次进程内的 FFI 调用，fcitx5 是在已经打开的套接字上
  往返一次，而 ibus **完全没有开销** —— 它是被推送而不是被询问。只有外部工具这条回退
  路径每次采样都会启动进程，也只有那种情况下调高 `interval` 或设置
  `insert_only = true` 才真正有意义。
- **Linux 上没有运行输入法？** 插件会优雅地停用 —— `get()` 返回 `default`，不会报错。
  两条连接都会持续重试，所以之后再启动 fcitx5 或 ibus 都无需重启 Neovim 即可开始工作；
  想立即验证可以运行 `:IMEStatusReload`。`:checkhealth ime-status` 会告诉你在这台机器
  上每个守护进程处于什么状态，以及**为什么**。
- **用 fcitx5 却一直显示 `?`？** fcitx5 返回的是**当前获得焦点的客户端**所用的
  输入法，因此没有任何窗口获得焦点时它会返回空名字，标签退回 `unknown`。Neovim 在
  后台时这是正常的（`pause_on_focus_lost = true` 会直接停止轮询）。若始终只有 `?`，
  多半是你的终端并非 fcitx5 客户端 —— 检查 `GTK_IM_MODULE` / `QT_IM_MODULE` /
  `XMODIFIERS`，或用 `unknown = ""` 隐藏它。
- **在终端里正常，但从 GUI 启动 Neovim 就不行？** 只有当你指定了 `tool`/`cmd` 从而
  关闭原生后端时才会出现。`.desktop` 启动器、Neovide、macOS 的 `.app` 等不会读取
  shell 的 rc 文件，因此在终端里能用的工具在那里却不在 `PATH` 中。请用 `:echo $PATH`
  确认，然后修复启动器的环境，或直接指定绝对路径：

  ```lua
  require("ime-status").setup({ tool = "/usr/bin/ibus" })
  ```

  原生后端从不查看 `PATH`。Linux 后端对 fcitx5 读取 `$DBUS_SESSION_BUS_ADDRESS`
  （缺失时回退到 `/run/user/<uid>/bus`），对 ibus 读取 `$IBUS_ADDRESS`（缺失时回退到
  ibus 写在 `~/.config/ibus/bus/` 下的文件）。若这些值在 Neovim 内为空或已失效，
  `:checkhealth ime-status` 会指出是哪一个以及该怎么办。

## 许可证

MIT
