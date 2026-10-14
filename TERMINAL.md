# 集成终端标签页 —— 设计方案

> 目标：在 Search 中加入一个终端标签页（terminal tab），文字由 Metal 直接绘制（参考、学习 [metalterm.dev](https://metalterm.dev/) 的做法，但代码全部自写 —— Metalterm 源码闭源，且本项目除 Apple 自带框架外零依赖）。

---

## 一、现状盘点（方案所依赖的事实）

- **架构**：SwiftUI 壳 + AppKit 落点。页面不是 SwiftUI 视图，而是 `PageView: WKWebView`，通过 `Stage.swift` 的 `WebStage/StageView`（一个普通 `NSView`，`show(_ page: NSView?)`）停靠进层级；Split View 的 `PaneStage.swift` 同样只收 `NSView`。**这正好是终端视图的接入点**：一个用 `CAMetalLayer` 画字的 `NSView`，走同一条 `StageView.show` 的路。
- **Tab 模型**：`Tab`（`Tab.swift`）是纯 Web 页模型 —— `web: PageView` 惰性构建、navigation delegate、密码/阅读模式/隐藏元素等全部围绕 WKWebView。浏览器侧（`Browser.swift`）大量按 `tab(for: webView)` 反查。
- **会话恢复**：`Session.swift` 以 `Entry: Codable`（url/title/pin/name…）保存，标签的活身份（UUID、进程）不保存，恢复即重建 —— 对终端意味着**恢复的是“再开一个 shell”**，而不是进程本身。
- **睡眠**：`Sleep.swift` 半小时闲置即释放页面进程，留封面截图。终端标签页背后是一个**活着的 shell 进程**，睡眠语义必须改写。
- **发布形态**：hardened runtime、非沙盒（`Search.entitlements` 无 sandbox），PTY 不需要额外 entitlement。SwiftPM、`swiftLanguageMode(.v5)`、macOS 14 起步 —— Metal 3 特性（macOS 13 起可用）覆盖没问题。

## 二、从 Metalterm 学什么（技术要点）

Metalterm 公开资料给出的可迁移设计，按对 Search 的价值排序：

1. **常驻 GPU 的字形图集**：字形光栅化后放一张常驻纹理，200 MB 滚动缓冲区和一个空提示符同价 —— 网格数据每帧以实例化绘制（instanced draw）采样图集，CPU 每帧只传变化过的 cell。
2. **两个 pass、0.22 ms/帧**：一个 pass 画背景方块（含选中高亮、命令块边线），一个 pass 画字形；光标、下划线进背景 pass。帧预算 120 Hz = 8.33 ms，目标 GPU ≤ 0.5 ms。
3. **没有变化就不出帧**：renderer 完全由损伤驱动 —— 无输出、无滚动、无光标闪烁时 `CAMetalLayer` 不排队任何帧，电池还给用户。这与 Search 现有的睡眠哲学同源，必须保留。
4. **OSC 133 命令块**：读 shell 自己输出的标记，知道命令从哪开始、输出到哪结束、跑了多久、退出码非零则行间槽线标红。**不改用户 rc 文件** —— 集成脚本由 app 写入自己的 Application Support 目录，用 shell 既有加载路径注入。
5. **OSC 9 / OSC 777 → 系统通知**：长任务在不被看的标签页里完成时由 macOS 提醒。
6. **基准数字当作验收线**（M 系列、120 Hz）：满缓冲连续滚动 120 fps 零掉帧；PTY 吞吐目标 < 80 ms / 10 万行级输出；闲置内存增量（10k 行后）目标 < 25 MB。

不学/暂缓的：Metalterm 的 Rust 核心、Vulkan 后端计划、命令面板（Search 已有自己的 ⌘K 习惯，不另起一套）。

## 三、总体设计

### 3.1 新的内容类型，而不是新的一切

给 `Tab` 引入内容二态，而不是并行造一套 `TerminalTab` 类。理由：TabBar、Space、TabGroup、Split、⌘K 切换器、会话、AppleScript 全部围绕 `Tab` 的统一接口（id/title/address/pin/groupID）运转，另起类会把每个系统都改两遍。

```
// Tab.swift 中（概念）
enum Content { case web; case terminal }
```

- `Tab` 增加 `let content: Content`，`web` 仅在 web 态构建；终端态持有 `terminal: TerminalController`（同样惰性：会话恢复回来的终端标签页在点击前不 fork 进程、不建 layer —— 和 web 标签“回来即免费”一致）。
- 每个入口（`newTab()`、`open(url:)`、恢复、`TabBar` 标题/图标、右键菜单）按 `content` 分派。终端标签页没有 `web`，`tab(for: webView)` 自然查不到它，Browser 的 WebKit 委托链零改动。
- `Stage.swift` 的 `Page` 视图按 content 换落点：web → `WebStage`，terminal → `TerminalStage`（同构的 `NSViewRepresentable`，把 `TerminalView` 交给 `StageView.show` —— `StageView` 收的是 `NSView`，本就不管里面是 WebKit 还是 Metal）。

### 3.2 文件规划（沿用一文件一关注点）

| 文件 | 职责 |
|---|---|
| `Terminal.swift` | `TerminalController`：PTY 生命周期（`openpty` + `posix_spawn` 用户 `$SHELL`）、读写调度、尺寸变更（`TIOCSWINSZ`）、标题/cwd（OSC 0/2/7）、对外接口（title、address=cwd、hasOutput、exit） |
| `TerminalGrid.swift` | 屏幕模型：行/列 cell 数组（字形索引、fg/bg、旗标）、滚动缓冲区（环形）、alt-screen 切换、命令块区间表（OSC 133） |
| `TerminalParse.swift` | VT 解析器：CSI/SGR（含 256/真彩）、OSC（0/2/7/9/777/133）、DECSET（换行、光标隐藏、鼠标 1000/1002/1006、bracketed paste、焦点报告）、alt screen、滚区域、DSR 应答。**纯逻辑，可单测** |
| `TerminalView.swift` | `NSView` + `CAMetalLayer`：损伤驱动渲染调度、`drawsBackground`、键盘（含 IME 提交路径）、鼠标选择/滚轮、尺寸→行列换算 |
| `TerminalDraw.swift` | Metal 渲染器：设备/队列/管线、字形图集（`CoreText` 光栅化 + shelf 打包上传）、两个 render pass、uniform/实例 buffer |
| `TerminalShaders.metal` | 两个着色函数：背景方块 pass、字形采样 pass |
| `TerminalShell.swift` | shell 集成片段（zsh/bash/fish 的 OSC 133 包装）生成与注入 |
| `TerminalFind.swift`（后置） | ⌘F 在滚动缓冲区查找，正则/字面量，GPU 高亮 |

### 3.3 Metal 渲染器细节

- **图层**：`CAMetalLayer`（不用 `MTKView`，控制帧节奏自由度更高），`displaySyncEnabled` 跟随 `FrameRate.swift` 的 ProMotion 设定。
- **字形图集**：一张 2048²（不足则 4096²）`R8` 纹理，等宽字形按 cell 尺寸的整数倍排布；普通/粗体/斜体各一区。首次构建在后台队列光栅化（`CTFont` + `CTLine`），缓存命中则只做一次纹理上传。ASCII 立即光栅化，非拉丁按需补格（后台补、下一帧可见）。
- **数据流**：网格 cell（16 字节：字形索引、fg、bg、旗标）放一个 `MTLBuffer`（`storageModeShared`）；解析器改了哪些行/区间记入损伤集，渲染前只把损伤段 `memcpy` 进 buffer。渲染两个实例化 draw：背景 pass 每格一个 quad（实例属性含色与旗标：选中、光标、命令块标记线），字形 pass 每格一个 quad 采样图集。命令块的时长/失败标记画在背景 pass 里（槽线色随 SGR 红色系）。
- **帧调度**：完全 `setNeedsDisplay` 语义 —— 输出到达、滚动、选择、光标闪烁（600 ms 定时仅在 caret-on 且焦点在本标签时启用）才请求帧。`CAMetalLayer` 的 `minimumDrawsBufferLen = 1`，不排队备用帧。
- **外观**：配色跟随 `Lights.swift`（明/暗/系统），ANSI 16 色两种模式各一套常量；背景用 `Palette.ground` 同色系，保持 Search 的“一行 ink 一行 hairline”语言。字体默认 SF Mono/Menlo，字号随系统。
- **macOS 14 兼容**：不用 `MetalFX`、mesh shader 等“Metal 3 名片”特性 —— 终端用不上；所说的“Metal 3”即 MSL 3.0 + 实例化 + 常驻纹理，macOS 14 全覆盖。

### 3.4 PTY 与 shell 集成

- `openpty` 得主/从端；`posix_spawn` 起 `$SHELL`（无则 `/bin/zsh`），`login_tty` 到从端，环境注入集成路径：zsh 用 `ZDOTDIR` 指向 app 自带目录（内含一个 `.zshrc`，先 source 用户原 rc 再装 OSC 133 钩子）；bash 用 `BASH_ENV`；fish 用 `-i` + `fish_command_not_found`… 同类既有加载路径。**绝不改写用户任何 rc 文件**（Metalterm 同款承诺）。
- 主端 fd 挂 `DispatchSourceRead`（全局队列读、防大输出的背压用一次性读 64 KB 循环）；写直接在主线程。进程退出 → 标签页显示结束语 + ⌘W 或“再开一个”。
- 每帧渲染不阻塞解析：解析在读取线程攒批，主线程定时（或空闲即合批）把字节流喂 parser。
- 尺寸变化：`TerminalView` 布局变化 → 换算行列 → `TIOCSWINSZ` + 通知重绘。

### 3.5 与现有系统的集成矩阵

| 系统 | 处理 |
|---|---|
| **TabBar** | 标题 = OSC 0/2（默认 `zsh`/当前命令名）；图标用 `terminal` 字形；pin 逻辑照常（pin 一个常驻终端是合理用法） |
| **地址栏** | 显示 OSC 7 的 `file://…/cwd`；⌘L 聚焦后输入路径回车 → 终端执行 `cd`；`!` 前缀直接跑命令（`⇧⌘V` 粘贴执行的 web 习惯不动） |
| **Session** | `Entry` 加 `terminal: Bool?`（Codable 默认 nil，旧会话文件零迁移成本）；恢复=重建 shell，cwd 不还原（进程本就没了） |
| **Sleep** | 终端标签页**不睡**（活进程不可恢复），但加入 `Sleep` 的豁免名单（同 pinned/播放中）；内存压力下可将滚动缓冲区截到可视高度、扔掉 Metal buffer、留封面截图 —— 进程与 PTY 保留 |
| **Split View** | 直接可用（`PaneStage` 收 `NSView`）；终端↔网页同窗对比是这个功能最自然的用法之一 |
| **⌘K 切换器 / TabGroup / Spaces** | 全部走 `Tab` 统一接口，零改动 |
| **通知** | OSC 9/777 → 复用 `Notifications.swift` 的通道；仅当终端标签页不在前台时发 |
| **菜单** | 文件 ▸ 新建终端标签页（`⌘⇧T` 与“重开已关标签”冲突 —— 建议 `⌥⌘T`）；页面类命令（⌘R/⇧⌘R/⇧⌘H/阅读模式/⇧⌘P）在终端标签页禁用置灰 |
| **AppleScript** | `address` 报 cwd，`title` 照报；private 终端标签同 private 页不报 |
| **Private tab** | `⇧⌘N` 私有终端：`SHELL_HISTORY` 指向空文件、`HISTFILE` 清空，关闭即焚；滚动缓冲随标签页释放 |
| **Shield/扩展** | 不适用，天然隔离 |

### 3.6 关键验收基准（bench 沿用 `Bench.swift` 传统）

- `cat` 200 MB 日志，118 列 ×34 行可视、连续滚动：120 Hz 显示器上 ≥ 119 fps，0 掉帧。
- GPU 帧时间 ≤ 0.5 ms（Metalterm 实测 0.22 ms，留一倍余量）。
- 10 万行输出 PTY 吞吐 < 80 ms；10k 行后内存增量 < 25 MB。
- 闲置（无输出、无焦点）CPU/GPU 占用 0%，不排帧。
- vim/htop/ssh/tmux 全功能正确（alt screen、鼠标、键序）。

## 四、分阶段实施

1. **核心（纯逻辑 + 单测）**：`TerminalGrid` + `TerminalParse` + `Terminal.swift` 的 PTY，先配 `vte` 式回放测试 —— 录制几个真实会话字节流（vim 启动、htop、大型 `git log --color`）断言网格终态。**此阶段无 UI，`swift test` 即可跑。**
2. **渲染器**：`TerminalView` + `TerminalDraw` + `TerminalShaders.metal`，独立窗口宿主先行（不接 Tab），跑基准。
3. **接入 Tab**：`Content` 分派、`TerminalStage` 落点、TabBar/Session/菜单/睡眠豁免。
4. **打磨**：OSC 133 命令块可视化、⌘F 滚动查找、OSC 9 通知、主题、private 终端。

## 五、风险与开放决策

- **解析器范围失控**是最大风险 —— alt screen、鼠标、IM E 之外的 CSI 一共约 60 个序列就够 95% 用例；先做“正确报错”（不认识的序列吞掉、计数打点），用真实会话回放测试圈住范围。
- **IME/非拉丁输入**：终端走 `interpretKeyEvents` 提交路径，标记符（marked text）先以光标态显示，提交后按网格换算 —— Metalterm 资料未覆盖，需实测中文输入法。
- **120 Hz + ProMotion**：与 `FrameRate.swift` 的“页面 120 Hz”偏好打通，但终端静止时零帧的语义优先于刷新率设定。
- **开放决策**（默认取括号内推荐，可改）：
  - 新建终端的入口：`⌥⌘T` + 地址栏输入 `term` / `> `（推荐：两者都要）
  - 终端标签页是否可 pin（推荐：可以）
  - 主题是否独立于网页明暗（推荐：跟随系统，与 `Lights.swift` 同源）
