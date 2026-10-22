# 集成终端标签页

> 目标：在 Search 里加一个终端标签页，文字由 Metal 直接绘制。做法参考 [metalterm.dev](https://metalterm.dev/) —— 它的源码闭源，但本机装着 0.2.1，二进制、`default.metallib`、termcap 与作者的公开表述能互相印证，所以**学的是查实的机制，不是宣传数字**。代码全部自写，除 Apple 自带框架外零依赖。
>
> **状态：已落地。** 十三个源文件、十五个测试文件（197 个终端测试全绿，整套 258 个全绿），`swift build` 与 `./build.sh` release 通过。下面写的是**它现在的样子**，不是打算做成什么样。还没做的集中在第七节。

---

## 一、接入点与边界

- **架构**：SwiftUI 壳 + AppKit 落点。页面不是 SwiftUI 视图，而是 `PageView: WKWebView`，通过 `Stage.swift` 的 `WebStage/StageView`（一个普通 `NSView`，`show(_ page: NSView?)`）停靠进层级；Split View 的 `PaneStage.swift` 同样只收 `NSView`。终端视图是一个用 `CAMetalLayer` 画字的 `NSView`，走同一条 `StageView.show` 的路 —— **接入点一处，没有为终端新开层级**。
- **Tab 模型**：**没有**引入 `enum Content` 那种内容二态。`Tab` 上是一个 `runsShell` 标志，`isTerminal` 就是它，`console` 惰性构建 `Terminal` + `TerminalView`（会话恢复回来的终端标签页在点击前不 fork 进程、不建 layer）。理由和当初设想的一样：TabBar、Space、TabGroup、Split、⌘K 切换器、会话、AppleScript 全绕 `Tab` 的统一接口转，另起一个 `TerminalTab` 类会把每个系统改两遍；而实际需要的分支远比 `enum` 少 —— 只要 `web` 在终端态下**不被构建**，`tab(for: webView)` 自然查不到它，Browser 的 WebKit 委托链零改动。
- **会话恢复**：`Entry` 加了 `terminal: Bool?`（Codable 默认 nil，旧会话文件零迁移成本）。恢复 = 重建一个 shell，cwd 不还原 —— 进程本就没了。
- **睡眠**：终端标签页背后是活着的 shell，**不睡**；`Sleep.awake(because:)` 对终端返回 `"a live shell"`。
- **发布形态**：hardened runtime、非沙盒（`Search.entitlements` 无 sandbox），PTY 不需要额外 entitlement。SwiftPM、`swiftLanguageMode(.v5)`、macOS 14 起步。

## 二、从 Metalterm 学什么，以及学成的形状

| 学到的做法 | 在本仓库落成的形状 |
|---|---|
| **常驻 GPU 的字形图集**："a 200 MB log costs what an empty prompt costs" | 一张 2048² `r8Unorm`，`.storageModePrivate`，blit 写入，ASCII 预切；彩色 emoji 另有同尺寸 RGBA 图集，按需创建。见 3.2 |
| **格子要小**："a cell that stayed 20 bytes" | `Record` **16 字节**（`glyph`/`flags`/`fore`/`back`/`spare`）。稀有特性走旁表，不塞进主结构 |
| **损伤驱动**："avoid treating every refresh as: something changed, redraw everything" | `Damage`（行集合 + `moved`）驱动格子缓存，纯滚动是 `memmove` 不是重建。见 3.2 |
| **每个标签有自己的 display clock，可挂起** | `TerminalPacer` 用 `NSView.displayLink`，理由集为空即停表；标签不在屏上就 `detach()` |
| **闲置零帧**："not fewer, none" | 字面实现：无输出、无闪烁、无一次性请求时 display link 停着，不排任何帧 |
| **一个 pass、几个 draw** | **一个 render pass、四个 pipeline state**（background / mark / decoration / glyph），不是两个 pass。见 3.2 |
| **模式查询（DECRQM）答得准** | `CSI ? Pd $p` 对 1/5/6/7/25/1000/1002/1003/1004/1006/1015/1016/2004/2026 与 ANSI 4 逐个如实回答，不认识的答 0（未知）而不是猜 |
| **SGR 鼠标 + SGR 像素坐标** | 1000/1002/1003 × legacy/SGR/urxvt(1015)/SGR-pixels(1016)，四种编码互斥。见 3.3 |
| **OSC 52 只兑现一半** | 写允许（可关），**读一律拒绝**，并把"选区为空"回给程序，不让它干等 |
| **shell 集成不碰用户 rc** | zsh 走 `ZDOTDIR`、bash 走 `--rcfile`，脚本在 app 自己的 Application Support 目录，每个文件先 source 用户自己的那份 |
| **明说不做**：sixel、kitty 图形协议、连字、bidi | 同样不做（Metalterm 自己也没做 bidi）。见第七节 |

不学的：Metalterm 的 **Rust 核心**（它自述 "terminal state, parsing and application logic live primarily in Rust"）—— 那是**实现语言**，不是技术；常驻图集 + 损伤驱动 + display clock + 零闲置帧这套机制才是要移植的东西。也不学它的命令面板（Search 已有自己的 ⌘K 习惯），以及它的标志性 UX（底部输入坞、命令块折叠、状态栏 + git）。

## 三、总体设计（已落地）

### 3.1 文件规划

一文件一关注点。括号里是行数。

| 文件 | 职责 |
|---|---|
| `Terminal.swift` (649) | PTY 生命周期（`openpty` + `posix_spawn`）、读写调度、`TIOCSWINSZ`、lane（单条串行队列，解析与取景同序）、`Scene`/`look` 两个取景口、`Modes` 快照 |
| `TerminalGrid.swift` (882) | 屏幕模型：`Cell`/`Row`、滚动缓冲（`trim()` 裁到 `scrollback`）、alt screen、滚区域、命令块区间表、超链接内联表、光标色、`Damage` |
| `TerminalParse.swift` (726) | VT 解析器。纯逻辑，可单测 |
| `TerminalCells.swift` (168) | **3 槽的格子环**：以 `Screen.place(row)` 为键的逐行缓存，`owed` 集合，滚动走 memmove |
| `TerminalAtlas.swift` (621) | **异步字形图集**：整数 `GlyphKey`、reserve-then-fill、后台串行切割、`generation` 换代 |
| `TerminalDraw.swift` (1143) | Metal 渲染器：设备/队列/四个管线、一个 pass 的编码、MSL 内联、`Frame`/`Record`、`groundColor`（窗格沟的底色） |
| `TerminalPacer.swift` (206) | 帧节奏：`NSView.displayLink`、理由集（damage/caret/once/hold）、闪烁与 hold 的相位 |
| `TerminalView.swift` (952) | `NSView` + `CAMetalLayer`：键盘（含 IME 提交路径、DECCKM/DECKPAM）、鼠标上报与选区、滚轮、尺寸换算、焦点上报（`onFocused` 缝，窗格容器挂它）、⌘-click、命令块跳转 |
| `TerminalMouse.swift` (183) | 四种鼠标编码的字节与坐标换算。纯逻辑，可单测 |
| `TerminalLook.swift` (171) | 设置项的运行时镜像（`TerminalLook.font/size/theme/…`），`changed` 通知 |
| `TerminalShell.swift` (130) | shell 集成片段的生成与注入（zsh/bash） |
| `TerminalFind.swift` (177) | ⌘F 滚动缓冲查找、覆盖层输入框、上下一个 |
| `TerminalSplits.swift` (1082) | 窗格分割：`TerminalTree`（**索引竞技场**的递归二叉分割树，纯算术可单测）+ `TerminalSplits` 容器（分格/焦点/zoom/均分/轮换、title 镜像、⌘W 的逐格收缩）+ `TerminalDivider`（轴向感知分割线）。见 3.7 |

着色器**不是**单独文件：MSL 以 Swift 字符串内联在 `TerminalDraw.swift` 里，运行时 `device.makeLibrary(source:)` 编译（`default.metallib` 若在 bundle 里则优先用它）。这样免掉一个构建步骤，也让 Swift 侧的 `Frame`/`Record` 和 MSL 侧的定义躺在同一个文件里 —— 它们必须同步改，放在一起才改得动。

### 3.2 Metal 渲染器

- **图层**：`CAMetalLayer`（不用 `MTKView` —— 帧由我们自己排，`MTKView` 会插一脚）。`maximumDrawableCount = 3`、`displaySyncEnabled = true`、`presentsWithTransaction = false`。
- **一个 pass，四个 pipeline state**：`backgroundVertex`（不透明、不混合，画底色方块）、`markVertex`（混合，画命令块槽线 / 查找高亮 / 非方块光标）、`decorationVertex`（不透明，画下划线/删除线）、`glyphVertex`（混合，采样图集）。同一个 render encoder 顺序切换，不是四个 pass —— 每个 pass 都要一次 load/store，终端这种小几何犯不上。
- **四边形的角序只有一种是对的**：四个 pipeline 都画 `triangleStrip`，共用同一张 `corners[4]`。strip 的顶点两两成三角形，所以角必须**之字形**（左上、左下、右上、右下）；绕边一圈的写法会让第二个三角形与第一个共用**一条边**而不是对角线，于是两个三角形在格子一侧重叠、另一侧留一块楔形空白 —— 那块空白会把每个字形都切掉一条（中间行最宽），重叠的那侧则被混合两遍、显得更黑。`TerminalRenderTests.testACellFilledWithABlockHasNoWedgeCutOutOfIt` 是它的回归测试。
- **格子 16 字节**：
  ```swift
  struct Record { var glyph: UInt16; var flags: UInt16; var fore: UInt32; var back: UInt32; var spare: UInt32 }
  ```
  `glyph` 是图集槽位加一（零 = 空）；`flags` 位 1 宽字、位 2 下划线、位 4 删除线；`fore`/`back` 是打包 RGBA，**零表示"用主题自己的颜色"**（省一次主题比较）；粗体/斜体在 `GlyphKey` 里，选的是图集的另一张脸，不占 record。
- **`Frame` stride = 144**，Swift 与 MSL 两侧逐字段对齐，`init` 里 `assert(MemoryLayout<Frame>.stride == 144)` 是跳线：谁改了一侧忘了另一侧，初始化就炸，而不是画出一屏乱码。
- **格子环**：`cellRing = 3` 个 `MTLBuffer`，槽数**必须**等于 `layer.maximumDrawableCount`，`init` 里并排断言（环小于 drawable 数 = CPU 写进 GPU 正在读的槽）。取槽放在 `nextDrawable()` **之后**，`DispatchSemaphore` 在 `addCompletedHandler` 里放行 —— 这样"等一个槽"和 `nextDrawable()` 本来就有的等待记在同一本账上。
- **损伤缓存**：每帧对每个可见行 `r`（绝对位置 `place`），脏 = 缓存 place 变了 **或** `owed` 里还有它 **或** `overturned` **或**宽度变了。`owed` 是必需的：第 *N* 帧吃掉 `Damage.rows = {P}` 把 P 写进 0 号槽，第 *N+1* 帧写 1 号槽，而 1 号槽那行的 place **本来就是 P**（原地改写，place 没变），它不知道 P 已经被吃掉，于是画出旧文字。所以每次收到损伤做 `for slot in slots { slot.owed.formUnion(rows) }`。**纯滚动是 `memmove`**：`slot.top - top` 是同一个 Δ、宽度一致、字体没换，就整槽平移、`lines` 平移、只转换新露出来的那几行。行整行转成连续 `Record`，相邻脏行并成 `Range` 一次 `copyMemory` 写进槽 —— 不做列区间，整行一次拷贝比"表示+解释列区间"的哈希开销便宜。
- **字形图集**：2048² `r8Unorm`。键是**整数** `GlyphKey { word: UInt64, style: UInt8 }` —— 单个 scalar 走 `(1 << 56) | scalar`（精确，含非 BMP），多 scalar（组合符、VS16、ZWJ）走 FNV-1a 且最高字节留零当"这是哈希"，所以簇不会和精确 scalar 撞。**永不建 String**（旧实现每格每帧做一次字符串插值做查表）。
  - **先占位、后落地**：查表未命中就 `reserve()` 并**立刻**返回索引，同时把切割任务丢给后台串行队列 —— 那一两帧那个格子读出 0（空），而不是让整条 GPU 管线干等。
  - **blit 写入同一条 command buffer**：每个字形在 staging buffer 里按 256 字节对齐摆好，帧的 command buffer **先 blit 再 render**，顺序由 Metal 保证 —— 于是 `waitUntilCompleted()` 可以删掉，写图集与在途帧抢读的竞态也一并消掉。图集是 `.storageModePrivate`，注意它**不会自动清零**（实测噪声 4320/5760 像素），所以 `wipe(on:)` 是必要的。
  - **换代**：字体、缩放、字面任一变化 → `generation &+= 1`、新纹理、旧的进 `retired` 并**留到读它的在途帧结束**（在放行 semaphore 的同一个 completion handler 里丢），否则 GPU 读已释放的纹理。切割任务带 `generation`，换代前的落地直接丢。
  - **每帧上限**：`perFrame = 512` 个落地，backlog 4096。ASCII 0x20–0x7E × 4 种样式在 init 与每次换字体时预切（约 6 ms / 376 个字形），所以 ASCII 永不闪。新 CJK 字形会闪一帧空格（~8 ms）——**这是故意的**，为了消灭它去等切割，正是这次要删掉的那个停顿。
  - `NSFontManager.convert(_:toHaveTrait:)` 只在主线程：四种字面每代在主线程解析好再交给切割队列，`CTLineDraw` 才在后台跑。
  - **彩色字形走第二张图集**：emoji 不能是覆盖度（它的颜色是画的一部分），所以另有一张 2048² `rgba8Unorm`，首次出现彩色字形时才创建；`Record.flags` 的 bit 32 说这一格采样哪一张，片元把 CoreText 写的 premultiplied RGBA 反预乘后按同一套 alpha 混合画。宽的彩色字形（🧠 占两格）与宽 CJK 共享同一套槽位；blit 的目标起点按**基础槽宽**算，不是按 2× 宽的裁剪宽度算——旧写法会把宽字形整体右移一格。

### 3.3 帧节奏

`TerminalPacer`，理由是一个 `OptionSet`，**空集就停表**：

| 理由 | 何时持有 |
|---|---|
| `damage` | lane 送来损伤时**累积**（`formUnion`），每个 vsync 合成一帧 |
| `caret` | 仅当 `TerminalLook.blinks && window?.firstResponder === self && caretIsLive`。相位从 `link.timestamp` 读，**不用墙钟**，挂起回来不会错拍 |
| `once` | 一次性请求：布局、滚动、查找跳转、菜单命令 |
| `hold` | 同步输出 2026：程序在屏外拼一帧，损伤照收但不出帧 |

- `preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)`。下限不低于 30 —— 闪烁会被量化得很难看。
- `add(to: .main, forMode: .common)`：**`.common` 是必须的**，选区拖拽跑在 `.eventTracking` 模式里。
- 停表条件：不在 window 里、`isHiddenOrHasHiddenAncestor`、窗口被遮挡 → `detach()`。不在屏上的标签页不出帧，也不重启时钟 —— 后台分屏里跑 `cat` 就是这种情况。
- **`hold` 有耐心**：`patience = 1 s`。程序崩了没关 2026，一秒后强制出帧，不能让屏幕永远停在半成品上。
- `Timer` 全部删掉了。旧实现的 0.5 s 重复定时器只判 `window != nil`，于是**可见但没聚焦**的终端永远每秒出两帧 —— "闲置零帧"的承诺当时是破的。
- **lane → 主线程的损伤投递也合并**：`Terminal` 用一把 `NSLock` 累积 `Damage`，同一时间只排一个 main hop；主线程取走时一次交齐。否则 10 万行就是 10 万次 `onDraw`，主线程光排队就够慢了（实测 debug 181 s，合并后 release 2.9 s）。

### 3.4 PTY 与 shell 集成

- `openpty` + `posix_spawn` 起 `$SHELL`（无则 `/bin/zsh`），`login_tty` 到从端。主端 fd 挂 `DispatchSourceRead`；事件里用 `poll` 排空内核缓冲（复用一个 64 KB buffer，读不阻塞），读完一次投递一次损伤 —— 一行一条的程序不会变成一次事件一行。
- **一个 lane**：解析与取景在同一条串行队列上同序执行。`scene(scroll:)` 会拷贝网格（给测试和 `TerminalFind` 用），`look(scroll:_:)` 不拷贝（在 lane 体内、在活行上跑闭包）—— 热路径走 `look`。
- **shell 集成不碰用户 rc**：zsh 走 `ZDOTDIR` 指向 `Store.file("Terminal")` 下的目录，里面 `.zshenv/.zprofile/.zshrc/.zlogin` **每个都先 source 用户自己那份**，再装 OSC 133 钩子；bash 走 `--rcfile search.bashrc -i`。fish/sh 不包装（没有等价的、不改用户文件的注入路径，宁可没有命令块也不要动用户的配置）。
- 尺寸变化：视图布局 → 换算行列 → `TIOCSWINSZ` → 申请一帧。

### 3.5 与现有系统的集成矩阵

| 系统 | 处理 |
|---|---|
| **TabBar** | 标题 = **焦点格 cwd 的目录名**（末段；home 记作 "~"；多格时后缀 "(N)"）；cwd 未知时退回 shell 自设标题（OSC 0/2）或 argv 名；终端标签页按 `isTerminal` 走自己的图标；pin 照常 |
| **地址栏** | 显示 OSC 7 的 cwd（写进 `Tab.address`） |
| **Session** | `Entry.terminal: Bool?`，nil 即网页；恢复 = 重建 shell |
| **Sleep** | 不睡。`awake(because:)` 报 `"a live shell"` |
| **Split View** | 直接可用（`PaneStage` 收 `NSView`） |
| **⌘K 切换器 / TabGroup / Spaces** | 走 `Tab` 统一接口，零改动 |
| **通知** | OSC 9 / 777 → `Notifications.swift` |
| **菜单** | 文件 ▸ New Terminal（`⌥⌘T`，`file.newTerminal`）；标签 ▸ Next/Previous Command（`⌘↑`/`⌘↓`，仅在 `browser.active?.isTerminal == true` 时可用）；标签 ▸ Split/Focus/Nudge/Zoom/Even Terminal…（见 3.7 键位表，仅终端标签页） |
| **AppleScript** | `address` 报 cwd，`title` 照报 |

### 3.6 验收基准（原定目标与实测）

原定：

- `cat` 大日志、118×34、连续滚动：120 Hz ≥ 119 fps、0 掉帧。GPU ≤ 0.5 ms（Metalterm 实测 0.22 ms）。
- 10 万行 PTY 吞吐 < 80 ms；10k 行后内存增量 < 25 MB。
- **闲置（无输出、无焦点）CPU/GPU 占用 0%，不排帧** —— 这条由 `TerminalPacerTests` 的"空集则停表"直接钉住。
- vim/htop/ssh/tmux 功能正确（alt screen、鼠标、键序）。

**2026-10-21 实测**（macOS 27.0.1 / Apple Silicon；`swift test -c release --filter TerminalBenchTests`，118×34，帧取 200 次平均）：

| 项 | 实测 | 对原定 |
|---|---|---|
| 100k 行经 PTY（`cat` 4.4 MB） | 2.9 s（约 34k 行/s） | **未达** < 80 ms |
| 解析器单独吃同样 100k 行 | 3.0 s | — |
| 一帧 118×34：`refresh`（转 Record） | 0.15 ms | ✅ 远低于 8.3 ms/帧 |
| 一帧 118×34：`snapshot`（编码 + GPU + 等完成，含新纹理） | 1.6 ms | ✅ 保守上界 |
| 100k 行 scrollback 的 Cell 存储 | 484 MB（进程 footprint +508 MB） | **未达** 10k 行 < 25 MB（10k 约 48 MB） |

结论：**帧预算达标；吞吐和内存两条原定线没达到。** 原因在格子模型本身：`Cell` 40 字节 × 118 列 ≈ 4.7 KB/行，10 万行就是 484 MB；屏幕是行数组，每换一行要搬 34 行。滚动缓冲原先用 `Array.removeFirst`，满 10 万行后每行搬一次；等价微基准里 100k 次约 1.6 s，已换成环形 `Scrollback`（O(1)）。要到 80 ms 得把屏幕行也换成环形，并让 `Cell` 的稀有属性走旁表——那是另一轮架构工作，不是调参。

- **闲置（无输出、无焦点）CPU/GPU 占用 0%，不排帧** —— 仍由 `TerminalPacerTests` 的"空集则停表"直接钉住。
- vim/htop/ssh/tmux 功能正确（alt screen、鼠标、键序）—— 手测，不在 XCTest 里。

### 3.7 窗格分割（同一终端标签页内的多个终端）

一个终端标签页是一个"房间"，⌘D / ⇧⌘D 向右、向下分出窗格，递归嵌套（右格再向下分），拖分割线、点格或按方向键换焦点，关格收缩布局。参考 MetalTerm 0.2.1 的做法（⇧⌘D 是它实证的分割键；递归二叉树 + "closed a pane but could not collapse its split" 的收缩路径）。

- **树模型**（`TerminalTree`，纯算术、无视图可单测）：递归二叉分割，但用**索引竞技场**而不是 indirect enum —— `nodes: [Node]` 数组 + `root` 索引，`Node = .pane(Int) | .split(axis, first, second, fraction)`。收缩 = 把幸存子树拷进父槽、原槽立墓碑（`.pane(-1)`），数组里永远搜不到垃圾副本；父节点查找只从根向下走。方向词在枚举处写死：`horizontal` = 左右并排**分宽**，`vertical` = 上下叠放**分高**。邻格与"该方向上的分割线"查找遇并列候选取**读序**（树叶序）第一个，不是字典序 —— 结果可复现。最小窗格用点数（`inset×2 + 8 列 / 3 行`），模型不认识渲染器。
- **容器**（`TerminalSplits: NSView`，flipped、底色 = 主题 ground，暗色主题下格间不亮条）：出生即一格；分格时新格拿键盘与焦点、**继承焦点格的 cwd**（`Terminal(directory:)`）；房间放不下两个最小格就拒绝。关格走 `closeFocusedPane()`（返回 Bool：false 即房间从没有过格，⌘W 该去关标签）：shell 还活着先问（`Ask.sure`，MetalTerm 同款文案），已退出的直接关；⌘W 与分割线右键菜单都汇到这一处。**shell 自己退出**（`exit` 输入、命令跑完）时窗格自行收缩、无需询问 —— 没有进程可结束了；最后一格也退出时 `onEmptied` 上报，Browser 经 `Tab.onGone` 关掉标签页，终端窗口随 shell 关闭的老规矩。容器的 `close()` 先放走 panes 再停 shell，免得关标签页停出的退出被自己听见。焦点换格**同步**重发 title/cwd —— tab 永远说持有键盘那个格的话，不残留已关格的标题。标题的规则：报焦点格所在目录的名字（`~` 即家），这是标签页的本分，目录名**盖过** shell 自设的标题（OSC 0/2，oh-my-zsh 每个 prompt 都设一个，不能让它盖住 "where the keys are"）——OSC 7 到达前退回 shell 自设标题或 argv 名；多于一格时后缀格数 "(N)"（信箱式计数，关回一格即消失）。我们的集成只发 OSC 133 和 OSC 7、从不替用户设标题。zoom = 焦点格独占 bounds、其余 `isHidden = true`，pacer 见隐藏祖先自停（3.3 的停表条件，零新代码）；进出各一次 SIGWINCH，接受。`openFind`/`jumpToPrompt` 等转发成员让 Browser 的三处调用零改动。
- **分割线**（`TerminalDivider`）：借页面分栏 `PaneDivider` 的机制（CALayer 发丝 1→3pt、0.1s 悬停、`acceptsFirstMouse`），但**轴向感知**（光标 `resizeLeftRight`/`resizeUpDown`）且以闭包与容器解耦（`onDrag`/`onEven`/`onZoom`/`onClose`/`onStep`）。拖拽是活布局（`needsLayout; layoutSubtreeIfNeeded()`，窗格跟着手走；每跨一格一次 `TIOCSWINSZ`，与窗口连续 resize 同价），中点 3pt 内吸附 + 对齐触感一次；双击均分。VoiceOver 当 `.splitter`，值是百分比，步进 ±5%。右键菜单 Even Out / Zoom Pane / Close Pane。
- **键位**（标签 ▸ 菜单；⌥⌘/⌃⌘ 组合 take() 让给菜单键等效（App.swift:1299），`TerminalView.keyDown` 吞不掉它们）：

| 键 | 命令 | 冲突与取舍 |
|---|---|---|
| ⌘D | Split Terminal Right | 与 Duplicate Tab 同键、按标签类型分流：菜单两条都标 ⌘D、互斥禁用（Safari 式惯例）；分流的判断只写在 `Browser.duplicate()` 一处，take() 的硬编码 ⌘D 与 Command 闭包都汇到它 |
| ⇧⌘D | Split Terminal Down | 空闲（MetalTerm 实证键） |
| ⌘[ / ⌘] | Focus Previous / Next Pane | 与 Back/Forward 同键、按标签分流，判断只写在 `Browser.back()`/`forward()` 一处；`tabs.focusTerminalPrevious/Next` 命令带同键做菜单双显（⌘D 同款）。沿阅读序（`tree.panes`）环绕 |
| ⌘+ / ⌘− / ⌘0 | Zoom In / Zoom Out / Actual Size | 与页面缩放同键、按标签分流，判断只写在 `Browser.zoom(by:)`/`resetZoom()` 一处：终端标签写 `prefs.terminalSize`（一点一步、9–24 夹住、⌘0 回 `TerminalLook.home`），与设置面板同源持久 |
| ⌥⌘←/→/↑/↓ | Focus Terminal Left/Right/Above/Below | 空闲；⌘↑↓（命令跳转）、⌘[⌘]（前后）都不带 ⌥ |
| ⌃⌘←/→/↑/↓ | Nudge Divider Left/Right/Up/Down（一次一格 cell，钳到最小格） | ⌃←/→（页面分栏焦点）不带 ⌘，不撞 |
| ⇧⌘⏎ | Zoom Terminal Pane | 空闲 |
| ⌥⌘= | Even Terminal Panes | `KeyCombo` 读**无修饰**字符，"=" 归一成 "+"，⌥ 打出的 "≠" 不进门 |
| ⇧⌘K | Clear Buffer | ⌘K 是 Search Tabs 的招牌键，终端的 clear 移一位；清屏 + 回滚一起（ED 3 + ED 2），焦点格的 |

- **⌘W 的分界**：`closeFront()` 问 `Tab.closeFocusedPane()` 的返回值 —— 有格先关格（活 shell 弹确认），最后一格才轮到标签；菜单与键盘同源，分界只此一处（pane 数的判断归容器，Browser 不再镜像）。
- **handBack 顺手修正**：终端标签页的键盘归还走 `Tab.keySeat`（终端 = 焦点格 view，其余 = 页面），不再白建一个没人看的 PageView。
- **字号键（⌘+/⌘−/⌘0）**：终端分支写 `prefs.terminalSize`（±1 点，⌘0 回 `TerminalLook.home`）—— Prefs 的 didSet 落盘并 `terminalLookChanged()` + announce，每格 `lookChanged()` 重切图集、整帧重说、重排 → 重测 cell → TIOCSWINSZ，**与设置面板同一条链路、同一个源**（MetalTerm 的 `font_size` 语义：全局、持久）。View 菜单的 Zoom 三项与 take() 硬编码零改动即活；捏合缩放（`Tab.magnify`）对终端仍拒绝。
- **窗格轮换（⌘[/⌘]）**：`Browser.back()`/`forward()` 的终端分支 → `TerminalSplits.cycleFocus(_:)`：沿 `tree.panes`（阅读序）±1 环绕，复用 `focus(_:)`（换格同步重发 title/cwd）。命令 `tabs.focusTerminalPrevious/Next` 与 `tabs.back/forward` 同键，菜单双显、按标签互斥禁用 —— ⌘D 已验证的机制原样照抄。
- **Clear Buffer（⇧⌘K）**：`Browser.clearTerminal()` → 容器转发成员 → `TerminalView.clearBuffer()` → `Terminal.clear()` 在 lane 上 ED 3（回滚）+ ED 2（屏幕）。lane 侧改动不经 reader 的 damage 记账，视图侧 `lift = 0` + `repaint()` + `present()` 整帧重说是兜底（`lookChanged` 同款）。⌘K 仍是 Search Tabs。

## 四、协议覆盖

**OSC**：`0`/`2` 标题、`7` cwd、`8` 超链接、`9` 通知、`777` 通知、`12` 光标色、`112` 恢复主题光标色、`52` 剪贴板（写）、`133` 命令块（A/B/C/D）。

**CSI final**：``A B C D E F G ` d H f J K L M @ P X S T r s u g b m h l n c``。

**DECSET/DECRST**：`1`（DECCKM）、`3`（DECCOLM）、`5`（DECSCNM）、`6`（DECOM）、`7`（DECAWM）、`25`（DECTCEM）、`1000/1002/1003`（鼠标分级）、`1004`（焦点上报）、`1006/1015/1016`（鼠标编码，互斥）、`1048`（光标存档）、`1049`（alt screen）、`2004`（bracketed paste）、`2026`（同步输出），以及 ANSI `4`（IRM 插入模式）。

**DECRQM**：上列全部逐项如实回答；不认识的模式答 `0`（未知），不猜。`CSI ? u`（kitty 键盘旗标查询）以沉默作答 —— 不谎报支持。

**字符集**：`ESC 7`/`8`（DECSC/DECRC）、`ESC D/E/M/H/c`、`ESC =`/`ESC >`（DECKPAM/DECKPNM）、SO/SI、G0–G3（`(` `)` `*` `+`）、`ESC #8`（对齐测试图案）。

**应答**：DSR（`5n`/`6n`）、DA1（`c`/`0c`/`ESC Z`）、DECRQM。**自己发出去的回答不会被自己当成提问**（`testAnAnswerIsNotAQuestion`）。

**故意不做**：1005（UTF-8 扩展鼠标编码）—— 它把大坐标塞进 UTF-8，是 SGR 出现之前的历史包袱，一个都没有的程序要它；问了就给 plain 编码，也就是这些模式存在之前它拿到的那个。

## 五、实施记录

六步，每步独立可跑、独立可合。

1. **帧节奏**（`TerminalPacer`）：display link、理由集、停表；`Damage` 加 `moved`（光标移动/换行/回车/退格/tab/DECSC/DECRC/DECTCEM/DECSCNM 都置起）；`onDraw` 签名从 `(Screen, Damage)` 改成 `(Damage, Modes)`。**修掉了三个正在生效的 bug**：损伤算了却扔掉、光标移动完全不出帧、闪烁定时器永不停止。
2. **损伤驱动的格子缓存**（`TerminalCells`）：3 槽环 + `owed`、memmove 滚动、`look()` 免拷贝取景。**每帧两遍 `scene()` 拷贝没了**。
3. **异步字形图集**（`TerminalAtlas`）：整数键、reserve-then-fill、blit 同 buffer、`generation` 换代。**`waitUntilCompleted()` 和同步光栅化没了**，`refont` 漏 `next` 的图集泄漏也一并修掉。
4. **输入与交互修正**：鼠标上报（1000/1002/1003 × 四种编码，Option 强制切回选区）、DECCKM/DECKPAM（**方向键在 vim/less 里以前发的是错的形式**）、焦点上报 1004、同步输出 2026、DECRQM、G2/G3。
5. **终端能力扩展**：OSC 8 超链接（惰性旁表，`Cell` 只多一个 `UInt16`）、OSC 52（写允许、读拒绝）、OSC 12/112、OSC 133 命令块跳转（`⌘↑`/`⌘↓`）。
6. **设置项**：`terminal.font/size/theme/cursor/blinks/padding/shell/directory/scrollback/mouse/clipboard/links/sync`，沿用 `Prefs` 的 `didSet` → `terminalLookChanged()` → 镜像到 `TerminalLook` 的老路。

## 六、踩过的坑

- **鼠标与选区的行是上下颠倒的**（真 bug，已修）。渲染器把第 0 行画在**顶**（`toClip` 里 `1 - y*2`），而 `TerminalView` **不是 flipped**，它自己的 y 从**底**往上数 —— 于是点在第一行的报告是第 18 行。修法是在 `square`/`heard` 前面插一个 `inGrid(_:)` 把 y 翻过来，`firstRect(forCharacterRange:)` 里那半个同样的 bug（IME 候选框落在 y=20 而不是 ~264）一起修掉。
  **没有**改成 `override var isFlipped { true }`：那会把查找输入框挪到右下角（它的 frame y 是照非翻转的父视图写的），还可能让 AppKit 在 backing `CAMetalLayer` 上设 `isGeometryFlipped`。外科手术式转换比翻整个视图便宜。
- **像素坐标的 off-by-one 是我自己写测试时错的**：期望 `^[[<0;8;8M`，实际拿到 `^[[<0;9;577M`。视图算出的 `(column: 8, row: 576)` 是对的，`MouseReport.bytes` 对两个字段各加一（协议从 1 数起）。测试改成 `Int(4 * pixels.scale) + 1`。
- **`rtk` 钩子会把 `wc -l` 改写成 `tokei`**（报 "The argument '--languages' cannot be used with 'input'"）。数行数用 `grep -c ''`。
- **`storageModePrivate` 的纹理不保证是零**：换图集时实测 5760 个像素里有 4320 个是噪声，所以 `wipe()` 必须真的写。
- **环大小 ≠ `maximumDrawableCount` 是静默的灾难**（CPU 写进 GPU 正在读的槽），所以那条 `assert` 和 `Frame` stride 的断言并排放着。
- **图集换代时在途帧还在读旧纹理**：退役纹理必须留到读它的帧结束，不能在换代那一刻就丢。
- **PTY master 上的 `FIONREAD` 不报可读字节**：实测内核里明明有 4.4 MB，`ioctl(FIONREAD)` 回 0，而 `read` 拿得到。排空只能靠 `poll(POLLIN)`；并且 `POLLHUP/POLLERR` 必须当"结束"处理，否则读源会对着一个空的 master 反复空转，进程退出源排在 lane 后面永远等不到。
- **滚动缓冲满 10 万行后，`Array.removeFirst(1)` 是每行搬 10 万个元素**：等价微基准 100k 次约 1.6 s。`Scrollback` 改成环形存储，头部移动 O(1)，读出来的顺序不变。

## 七、还没做的

- ~~**视觉细节**~~（已落地）：SGR 5 闪烁真正绘制（Pacer 加 `.blink` 目的，与 caret 共用同一个时钟与相位，半个周期隐藏字形；屏幕上没有闪烁字时该目的自动退场）、下划线/删除线的样式与颜色（SGR 4:3 记入 `Ink.curl`，画成加重线；58/59 记入 `Ink.line`，装饰 pass 用它）、DECSCNM 反显（`Modes.reversed`，background 与 glyph 两个 pass 一起把格子翻面，Record 的 `spare` 改名为 `decoration`）、SGR 21 修正为双下划线（`TerminalParse.swift`：不再关粗体）、隐藏格子不再画下划线。
- **下划线样式的诚实上限**：4:4（dotted）与 4:5（dashed）在格子模型里与直线同权重绘制——一个 quad 装不下一个真正的波浪/点划线，解析层如实记账，绘制层用加重线作为简写。
- **Kitty 键盘协议**（CSI u）：一整套编码 + 旗标状态机，单独一轮更稳。目前查询如实回答"不支持"。
- **协议级**：sixel、kitty 图形协议、内联图片、连字、bidi、平滑滚动动画。
- **Metalterm 的标志性 UX**：底部输入坞、命令块折叠、状态栏 + git、光标动效。
- **多显示器拖拽**会引起 `contentsScale` 变化 → 整个图集换代 → 闪一下。缓解是按缩放双图集缓存，先记着不建。
- **窗格**：pane 树随会话恢复（会话只记终端标签页本身与位置，落点是新 shell，恢复时按单格重建，不还原布局）；`splitLeft`/`splitUp` 命令（从另一侧分右边那格即可做到）；跨窗格共享字形图集（每格约 4–6 MB，隐藏格帧时钟自停，代价是内存不是帧）；MetalTerm 式 `confirm_close` 设置项（关格确认目前无条件开，设置项后加）。
- **终端字号**：捏合手势调字号（键盘与菜单已够，捏合在触控板上与滚动易混）；每标签/每窗格字号（面板与 Prefs 都是全局模型，全局即 MetalTerm 的 `font_size`）。
- **MetalTerm 调研清单余项**：⌘E/⌘J 用选中文本进查找并跳到它（两键都空闲，做的话走 TerminalFind 的 `selection(in:)`）；命令时长显示（`command_duration_threshold`，UI 落点未定）。
- **架构**：不引入 Rust 核心，不引入 libghostty。

## 八、Agent 提醒（Island）

终端里跑着 coding agent（Claude Code、Codex、Pi，以及后来的 Gemini、Cursor、Qwen Code、
Grok、Droid、Copilot CLI、Oh My Pi——共十个），人却切去了别的标签页——agent 在干什么、
在哪一步卡住等人、什么时候跑完，一概看不见。[CodeIsland](https://github.com/wxtsky/CodeIsland)
给了这套问题的完整答案；这里照它的形状做了一套自己的，规模小得多，装在本浏览器里。

**三件东西，两处接线。**

1. **`Island.swift`** —— `IslandServer`（unix socket `/tmp/search-island-$UID.sock`，权限
   0700，id 在路径里所以只有本人能碰；手写极简 HTTP 解析：请求行 + 头 + `Content-Length`
   正文；`Shape` 分 `.http` / `.bare` / `.junk` 三形态）+ `Island`（session 模型：
   `Session.Part` 四态 `working / asking / waiting / done`；事件→状态转移；tty → 窗口→标签→
   窗格匹配；`PermissionRequest` 挂起等横幅上 Approve/Deny/不管它，其余事件即时回 `{}`）。
2. **`IslandHooks.swift`** —— 安装/卸载：桥接脚本 `search-island.sh`（纯 sh + curl
   `--unix-socket`，不编译第二个 target；`[ -S "$SOCK" ] || exit 0` 快退；写到 Application
   Support，0755；除了 `X-Search-Tty` / `X-Search-Source` 还带 `X-Search-Event`——Cursor 和
   Copilot 的话里不说自己是哪个时刻，命令里说了，头里替它们带一句）+ Pi 扩展
   `search-island.ts`（`~/.pi/agent/extensions/` 与 `~/.omp/agent/extensions/` 同一个文件，
   目录不存在则跳过，危险 bash 与 ask 工具映射成挂起的询问，装给哪一家脚本里就写谁的名字）。
   十家分三种形状，形状共享一套内核：

   - **Claude 形状**（settings.json 里 hooks 键，行里嵌 hooks）——Claude Code、Codex
     （hooks.json，少一条 Notification）、Qwen Code（同 Claude 但毫秒计、每个等待都要
     写明：说事 5000，批准 86400000——Qwen 会等一个不说"完了"的 hook）、Droid
     （~/.factory，照抄整份契约，秒）；
   - **嵌套形状**（无 matcher）——Gemini（settings.json，自己的事件名 BeforeTool/
     AfterTool/BeforeAgent/AfterAgent，毫秒，每条 10000；它的 BeforeTool 是每个工具前的
     否决而非审批，所以纯观察，不挂 hold——挂住每个工具就成了狱卒）、Grok
     （~/.grok/hooks/ 下独立自有文件，扫整目录，秒，不挂 hold——它不等 hook 的回答）；
   - **平铺形状**——Cursor（hooks.json，行就是一条 command，命令里带事件名）、Copilot
     CLI（~/.copilot/hooks/ 下独立文件，顶层 `version: 1`，行是 `{type, bash, timeoutSec}`，
     说事 5 秒）。

   全部走**合并不覆盖**：按 command/bash 里含桥接路径认出自家条目，幂等重装、干净卸载，
   用户自己的 hooks 一条不动；只有自家条目的文件清空后连文件一起带走，Grok/Copilot
   文件夹里用户自己的文件永远不碰。`PermissionRequest` 的 timeout 装成 86400（一天，
   毫秒家 ×1000）。事件名在 `Island.swift` 读入时归一到横幅自己的词（BeforeTool→PreToolUse，
   afterAgentResponse→Stop，等等），小写驼峰与 PascalCase 都认。
3. **`IslandBar.swift`** —— notch 式横幅，挂在 `ContentView.window_` 的顶部居中，所有标签
   页可见；列出全部 session；`asking` 的带 Approve/Deny 按钮；点一下跳到它的窗、标签、
   窗格。**抑制规则**：session 的 tty 就是前台窗口当前标签的聚焦窗格（`Island.watched`）
   时不显示——屏幕上正看着它，横幅只会说得比屏幕差。

接线在 `App.swift`：`SearchApp.init` 里 `Island.shared.start()`（测试运行不占真 socket，
`Store.testing` 时各自用各自的路径）；`window_` 尾部 overlay `IslandBar()`。设置面板
`Settings.swift` 的终端段新增 "Coding agents" 一卡，每个 agent 一行、装/卸 Pill、状态自知；
常用的三家（Claude Code、Codex、Pi）先列，其余七家收在 Show more 后面点开才见——
不常用的不该占着设置面板。每行共用一个开关：先写桥接再装，卸载不动桥接（自家的东西
在自家的文件夹里，离下次被装上只隔一次点击）。

**两种形态的协议。** Claude Code 与 Codex 的 hook 走 HTTP（curl 带话，头里
`X-Search-Tty` / `X-Search-Source`）；Pi 的扩展走裸 JSON（POSIX socket，写完半关——EOF
就是它唯一的"说完了"）。裸 JSON **解析成完整事件即算说完，EOF 仍是兜底**——这一条
是被测试环境逼出来的：XCTest 的 runner 沙箱不让测试进程做裸 `connect`（回
`ENOTSOCK`，而 Network.framework 自己的连接能过），且 Network 的连接又不能半关；
"解析即说完"让任何说不完"完了"的客户端都能用，也更快听见。服务器只收一条说一回，`PermissionRequest` 原连接挂住直到人答。

**安全失败。** Search 没在跑（socket 不在）→ 桥接脚本直接 `exit 0` 不输出 → CLI 落回自己
的批准弹窗；app 退出连接断 → 同样落回。挂起的连接断了（CLI 超时走了）→ hold 放弃，
session 退回 `waiting`，它自己的终端接着问。

**说不出口的就替它说。** `Stop` 事件带着 agent 最后说的话——没在被看的终端上时，走
`SiteNotifications` 发系统通知（`Store.testing` 时照旧只记不发）。终端关了，里面的 agent
hook 永远不会再跑（进程被杀不会执行任何 hook），所以由终端自己的结束替它们退场：
`Island.retired(tty:)` 清掉该 tty 的全部 session，还开着的 hold 回一个空 `{}`，让等着的
CLI 回自己终端去问。

测试在 `Tests/SearchTests/IslandTests.swift`（21 条）：事件读取与裁词、各家事件名归一（Gemini/Cursor/Copilot/
Grok 折到横幅自己的词；请求头带名；无 session 的以 tty 为 session）、各形状 settings 的合并与卸载
（Claude/Codex/Qwen/Droid/Gemini/Cursor/Grok/Copilot/Pi/OMP）、桥接脚本写出且可执行、session 状态转移、
`Shape` 两形态、socket 收 HTTP 事件、挂起→回答全链路、裸 JSON、终端结束带走 agent。
