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

不学的：Metalterm 的 **Rust 核心**（它自述 "terminal state, parsing and application logic live primarily in Rust"）—— 那是**实现语言**，不是技术；常驻图集 + 损伤驱动 + display clock + 零闲置帧这套机制才是要移植的东西。也不学它的命令面板（Search 已有自己的 ⌘K 习惯）、命令块折叠、状态栏 + git。底部输入坞**原本在这份不学清单上**（3.1 的旧版明确划了界），后来用户点名要"跟 Metalterm 终端一致的体验"，第 3.9 节记录了这次反转与它的落法 —— 学的是**体验**（底部输入、每次键击的上报式动效），不是它的 Rust 实现。

## 三、总体设计（已落地）

### 3.1 文件规划

一文件一关注点。括号里是行数。

| 文件 | 职责 |
|---|---|
| `Terminal.swift` (679) | PTY 生命周期（`openpty` + `posix_spawn`）、读写调度、`TIOCSWINSZ`、lane（单条串行队列，解析与取景同序）、`Scene`/`look` 两个取景口、`Modes` 快照 |
| `TerminalGrid.swift` (882) | 屏幕模型：`Cell`/`Row`、滚动缓冲（`trim()` 裁到 `scrollback`）、alt screen、滚区域、命令块区间表、超链接内联表、光标色、`Damage` |
| `TerminalParse.swift` (806) | VT 解析器。纯逻辑，可单测 |
| `TerminalCells.swift` (168) | **3 槽的格子环**：以 `Screen.place(row)` 为键的逐行缓存，`owed` 集合，滚动走 memmove |
| `TerminalAtlas.swift` (621) | **异步字形图集**：整数 `GlyphKey`、reserve-then-fill、后台串行切割、`generation` 换代 |
| `TerminalDraw.swift` (1143) | Metal 渲染器：设备/队列/四个管线、一个 pass 的编码、MSL 内联、`Frame`/`Record`、`groundColor`（窗格沟的底色） |
| `TerminalPacer.swift` (206) | 帧节奏：`NSView.displayLink`、理由集（damage/caret/once/hold）、闪烁与 hold 的相位 |
| `TerminalView.swift` (1196) | `NSView` + `CAMetalLayer`：键盘（含 IME 提交路径、DECCKM/DECKPAM）、鼠标上报与选区、滚轮、尺寸换算、焦点上报（`onFocused` 缝，窗格容器挂它）、⌘-click、命令块跳转、输入坞的接线（而纱、首帧、点击命中、IME 首矩形、条带纱）、状态栏与 git 轮询 |
| `TerminalMouse.swift` (183) | 四种鼠标编码的字节与坐标换算。纯逻辑，可单测 |
| `TerminalLook.swift` (171) | 设置项的运行时镜像（`TerminalLook.font/size/theme/…`），`changed` 通知 |
| `TerminalShell.swift` (876) | shell 集成片段的生成与注入（zsh/bash）：zsh 走 `ZDOTDIR` 包裹，脚本内置命令块标记（OSC 133）与输入坞上报（OSC 7784）、点击移光标/删选区小件 |
| `TerminalFind.swift` (177) | ⌘F 滚动缓冲查找、覆盖层输入框、上下一个 |
| `TerminalField.swift` (531) | 查找面板的动效引擎：Metalterm 的 `Cursor` 四条曲线（quartic 头、cubic 尾的 smear、三角 bleed、`1/(1+kv)` squash）+ 面板、亮条、smear 光带 |
| `TerminalDock.swift` (765) | 底部输入坞引擎：`TerminalDock`（面板/行/每字形到达的到达台账、光标闪烁规则、alt screen 挂起）、`DockLedger`、`TerminalDockPlate`（画板，几何随终端字号）。只有状态与曲线，不持时钟 —— 与 `TerminalField` 同一个分工。见 3.9 |
| `TerminalStatus.swift` (276) | 底部状态栏：`StatusBarPath`（`~` 简写与超长路径留尾）、`GitStatus`（porcelain v2 解析：分支/detached、ahead/behind、四计数）、`TerminalGit`（串行队列 + 限时跑 `git status --porcelain=v2 --branch`）、`TerminalStatusBar`（AppKit 画的一行，主题自己的 ink）。见 3.9 |
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

### 3.8 查找面板的动效（Metalterm 的 `mt_gpu::motion::Cursor`）

Metalterm 的输入坞（底部 dock）当时按 3.1 的旧边界**不学**，但它的**动效引擎**是数字而不是家具：`crates/mt-gpu/src/motion.rs` 的 `Cursor` 把"一个光标从一格挪到另一格"拆成四条闭式曲线，`variants.rs` 的 `CursorMotion`/`Decay`/`Keypress` 只是给它们起名字。这一轮用 `rea` 打开 Metalterm.app，靠 `nm`/`objdump`/`strings` 把 ARM64 反汇编读出来（`Cursor::update` @0x1000aa6b8、`warp_span` @0x1000ab2fc、`caret_alpha` @0x1000aa45c、`squash` @0x1000aa61c、`overlay::find::FindUi::panel_rect` @0x1000c2750），四条曲线逐个常数核对后移植到 `TerminalField.swift`，落在 **⌘F 查找面板**上（当时是 terminal 模块里唯一真正的"输入框"）。后来 3.9 的输入坞落地，光标那套曲线也回到了它原本的岗位上 —— 详见下一节。

| 曲线 | Metalterm 原式（反汇编逐常数核准） | 移植后落在 |
|---|---|---|
| **smear 的头** | `p = clamp(t / 0.17)`，`1 − (1 − p)⁴` | 面板左缘那根 2 pt 亮条的位置。17% 的行程里走完全程 → 读起来是"被扔过来"而不是"被拖过来" |
| **smear 的尾** | `q = clamp((t − 0.05) / 0.2)`，`q < 0.5 ? 4q³ : 1 − ½(2 − 2q)³` | 面板自己的左缘。头和尾之间的**距离就是 smear**，用一条更便宜的光带填（越拉越淡，不是固定宽度） |

注意除数是 **0.17 与 0.2**（不是 1.0/0.65，那是早先的误读）。
| **bleed** | `t = clamp(e / (d · 0.2))`，`t < 0.35 ? 1 − t/0.35 : (t − 0.35)/0.65` | 面板左边缘那根条：每敲一个键**不透明 → 35% 处消失 → 回满**，即"每字形到位"的手感 |
| **squash** | `1 / clamp(1 + v · 0.0093333…, 1, 1.3)` | 面板宽度：越快越薄，最多 23%。速度线性衰减到段末，停下即回满 |

另外两条读出来但这一轮**不用**：`Cursor::update` 里 spring 分支（刚度 512、阻尼 30、≤4 ms 子步、≤16 步）与 8 样本 trail（`sin(i·0.65)·0.7`），以及 `smooth`/`smear` 的环缓冲历史。它们是**光标**跨格用的，面板跨的是点不是格。

落地的形状：
- `TerminalField`（`@MainActor final class`）：只有状态与曲线，**不画东西也不持时钟**——和 `TerminalPacer` 的分工一样。`arrive`/`leave`/`place`/`press`/`advance(at:)`/`moving(at:)` 全按传入时刻求值，所以一个 80 ms 的 bleed 能被单测一毫秒一毫秒走完。
- **窗口 ≠ 行程**（`FieldMotion`）：写下的 `arrive = 0.44` / `leave = 0.36` / `settle = 0.40` 是 Metalterm 的 `duration`，即曲线被读的那个窗口；尾在窗口的 25% 就收完了（`FieldCurve.tail` 的 `(t − 0.05) / 0.2`），剩下的 75% 是**驻留**。所以 `moving(at:)` 与 `end(at:)` 都以 `travel = 0.25` 为准，不是 `length`——`length` 只是曲线的自变量范围。一个 0.44 的窗口是 110 ms 的行程，不是 440 ms 的。
- **三样东西，两条曲线**：面板（plate）的左缘跑**尾**，一根 2 pt 的亮条跑**头**，两者之间的地带是**半透明的 smear 光带**——它不是一个固定宽度的条，而是那条缝本身，越拉越淡。这是读 Metalterm 时唯一必须偏离字面的一处：它的 smear 是"光标画两次"——同一个 glyph 在两个位置各画一遍，中间空着的地方自然露出终端。面板是一整块不透明的板，画两遍只会叠成一块，所以这里必须是**两个不同的物体**才能让中间那道缝看得见。
- 面板**右缘钉死在窗口的右边距**，行程把它的**左缘往外拉**——它是从角落里被*拽出来*的，不是从窗外*滑过来*的。这一条是渲染验证逼出来的：滑进来会让板子画到窗口外面去（`TerminalView` 不裁剪子视图），而右缘固定既符合"它属于窗口右侧"，也天然不越界。
- 帧的请求**不新开时钟**：`TerminalView.frame()` 画完 `paint.render()` 之后调 `drawFind()`；`drawFind()` 若还在动就 `DispatchQueue.main.async { present() }` 一跳回到 pacer，`findAsking` 保证一跳只换一帧。**停表纪律照旧**——曲线走完、bleed 完之后没人再要帧。
- Reduce Motion（`Motion.reduced`）：`settle()` 一步到位，`closeFind()` 直接拆视图，不进任何腿。
- 颜色：面板用**终端主题自己的 ground/ink**（`TerminalDraw.Theme.current`），只借 Metalterm `FindUi::draw` 的结构——0.14 ink 的发丝描边、7 pt 圆角。在终端上盖一块 app 的 chrome 会是错窗里的错盒子。`lookChanged()` 时面板、字段、两根条一起换色。
- **几何**（`FieldBox`）取 `FindUi::panel_rect` 的**相对位置**（右缘 14 pt 内、距顶/底 12 pt、高 30 pt），**不取**它的 45·s 宽度与 13/11 pt 字号：那是它自己的字体网格，Search 的字段是 AppKit 的真输入框（IME、粘贴、选择器都要活）。矩形计算是纯函数 `FieldBox.home(wide:in:at:)`，不需要视图就能测。
- **面板挂在窗口的哪一端是设置项**（`TerminalLook.findPlace`，设置面板「Terminal → Find Bar」，Top/Bottom，默认 Top）。这是这一轮唯一可配置的部分：底部正是 Metalterm 输入坞的位置（也是这整套动效的出处），但 3.1 不抄那个坞，而终端最底一行就是提示符和你正在敲的命令——所以放在顶部仍是默认，想放底部的人自己选。设置只改 `home.y`，smear、亮条、bleed 一概不变：它们沿面板自己的**前缘**跑，不沿窗口的纵轴。视图不是 `isFlipped`，所以顶是 `bounds.height − …`、底是 `12`；`lookChanged()` → `needsLayout` → `placeFindField()` 让改设置当场生效。
- **同一项设置也管网页的 ⌘F**：⌘F 在一片网页上的那个胶囊（`Find.swift` 的 `FindBar`）和分栏布局里那个宿主视图（`PaneStage` 的 `findBar`）读同一个 `TerminalLook.findPlace`，所以「Find Bar」指的是「⌘F 出现在哪」，不是「终端里那个框」。分栏那条走的是 `isFlipped` 的 `PaneStage`，因此顶是 `page.minY`、底是 `page.maxY − h`——同一个 `FieldBox` 的两个说法，`FieldBox.top` 就是把 `home` 从下往上量的结果翻成从上往下量（有单测钉住两者是同一个矩形）。
- **网页那个胶囊本身也走 Metalterm 的腿**，不是 SwiftUI 自带的滑入：`FindBar` 常驻在 overlay 里（`App.swift`），一条 `leg` 状态被 `withAnimation(.linear(FieldMotion.arrive))` 线性走完，每一帧在 `OutOfTheCorner` 里读 `FieldCurve.tail/head/fade`——尾定蒙版（胶囊从它靠角的那一端被拉出来）、头是那根亮条、缝是 smear 光带、不透明度是 fade，敲键亮条 bleed 一下。离开反过来收回去（`FieldMotion.leave`）。之所以常驻：SwiftUI 的视图从层级里拿掉是瞬间消失的，腿没走完就被截断；分栏那条同样为此把 `findBar` 的拆宿主推迟到腿走完之后（`PaneStage.showFind`），窗口里再开一次 find 会取消拆除、腿掉头。`Motion.reduced` 时腿直接就位，位置照旧。
- 计数（`1 of 9` / `none`）挂在面板右端，**增长会把左缘推出去**——那是 `place()` 的一条新腿，与进场同形但不淡入。宽度在计数变化时 `remeasure()` 量一次，不在 8.3 ms 的帧里量字符串。
- 关窗不再是**截断**：`closeFind()` 只清 findings 并起一条离场腿，视图由走完腿的那一帧拆掉。

两处**刻意的偏离**，都写在 `TerminalField.swift` 的注释里，因为不说就会被当成抄错：

1. **`squash` 读的是相对斜率，不是绝对速度。** Metalterm 喂给它的是 spring 的 `velocity`，有界；面板的头部解析斜率没有界——260 pt 的板在 0.17 窗口里抛出去，起点约 20000 pt/s，会整段贴在 1.3 的钳位上下不来，末帧再"啪"地弹回 1。所以 `squeezeAt(t)` 用 `headSlope(t) = (1 − t/0.17)³`（本腿自身斜率归一化）× 钳位拐点速度，形状保住——抛出瞬间最薄、落地回满——尺度换成面板自己的。
2. **面板的不透明度用 smoothstep，不是 Metalterm 的 `head`。** 光标一格宽，能在 1/6 的窗口里凭空出现；板有 260 pt，那样就是硬切。smoothstep 压在头部同一个 0.17 窗口里，落地时正好满不透明——滑到位再淡入是两个事件，抛出去是一个。

测试 `Tests/SearchTests/TerminalFieldTests.swift`（15 个）：四条曲线各自的形状（quartic 在 17% 到顶、尾延迟 5% 且 25% 收完、bleed 的三角与 35% 的谷底、squash 的 1/1.3 地板与拐点）、fade 的 smoothstep、`squeezeAt` 的两端，引擎走一遍——未开时零帧、进场两曲线从同一处出发且末帧就位（smear 归零）、离场收尾成 away、原地不动不生成腿、中途改目标不从起点重来、敲键只 bleed 一次并在窗口末停止——以及 `FieldBox.home` 的两端：右缘钉死、两种位置同尺寸、都不越出窗口，窄帧保住两侧边距与 120 pt 下限。

### 3.9 底部输入坞（决策反转后的落法）

3.1 的旧版把输入坞划在不学清单上；用户后来点名要"跟 Metalterm 终端一致的体验"，于是**学体验不学实现**：Metalterm 的坞是自己的 Rust shell 状态机驱动 GPU 画字，Search 的坞是**给现有 zsh 的 zle 挂一套上报钩子**（OSC 7784），动效全部复用 3.8 已核准的曲线。不写用户 rc：zsh 照旧走 `ZDOTDIR` 包裹，脚本常驻 app 的 Application Support 目录，`bash` 走 `--rcfile`（bash 不报坞，只是补命令块标记）。

**协议（shell → 终端）**：

| 序列 | 时机 | 含义 |
|---|---|---|
| `OSC 7784;buf;<cursor>;<转义文本>;<转义建议>` | zle `line-pre-redraw`，每次键击/粘贴后 | 坞上整行现况。文本与建议都把 `\`、`\n`、`\r`、`\t`、`\e`、`\a`、`;` 转义成 `\xNN`，所以字段永不截断；上报侧去重（cursor/文本/建议都未变就不发） |
| `OSC 7784;off` | 行长超 1024 或含换行 | 多行编辑归网格，坞退场（面板塌缩）；回到单行时下一个 buf 报告把板带回来 |
| `OSC 7784;buf;0;;` | line-finish（回车那列） | 行已交出 —— 坞上那行**在原地淡出**（`FieldMotion.leave`），不是硬抹 |
| `OSC 133 A/B/C/D` | 照旧 | A（新 prompt）= 当场丢弃坞上行；B = prompt 尾缘（纱的起点）；C（命令起）= 输入权交还网格，纱撤；D = 命令果 |

**协议（终端 → shell）**，点击命中在鼠标上报**之前**：

| 序列 | 语义 |
|---|---|
| `CSI 27;9;71~<len>;<col>~` | 点到某列 → `CURSOR=<col>`，zle 自己重报 buf，光标沿 warp 曲线走过去 |
| `CSI 27;9;68~` / `CSI 27;9;88~<a>;<b>~` | 点左/删选区（选区删除与建议 ghost 的钩子已留，后续轮次接） |

**机制要点**（都在注释里带实测解释）：
- **纱（veil）**：坞接管输入时，从最后一个 `.prompt` 块的首行到屏底写空白格子（遮住 zsh 自己回显的那行 —— 它已逐字形复制在坞上），`paint.update` 传 `cursor:false`，网格光标不画；C/A 撤纱。C 后旧行继续在板上淡出 —— 淡出的是那条 `buf;0;;`，不是命令本身。多行/超长时 `off` 撤坞，输入自然归网格。
- **行数让位（`dockStrip`）+ 贴着网格的板（`home(in:above:under:)`）**：板立在帧底期间，它脚下那几行**从网格里让出来**（和状态栏同一个说法），内容永远结束在输入线上方，而不是把网格还在写的行藏起来 —— 盖住网格仍在写的行等于把用户输出的最后一行藏掉（上一版条带纱被反弹的原因：`ls` 的末几行直接消失）。板到/走（首个上报、`off` 塌缩、进 alt screen 挂起）就是一次 resize，shell 照常被告知；进全屏程序时条带归还网格，多行 `off` 编辑时同样归还。板的纵坐标**贴着网格最后一行的下缘**（`gridFloor`），只留恒定的一层空气（`DockBox.air = 4pt×unit`）——窗口高度除不尽行高的那点余量（最多近一整行）落在板**下面**的铬件区，而不是读作内容与输入线之间的间距（用户点名的"间距偏大"就是这么来的）。帧里的条带纱保留为过渡保险：正常状态下网格行数已在板上方结束，算出的条带为空，只在板刚到、重排行数那一帧兜底。板随字号长高时让出的行数自然跟着长（`dockStrip = edge + 板高 + air`，与 `placeDock` 摆位同一套数）。
- **板随终端字号（`DockBox`）**：输入行的字与整套几何跟终端配置的 Font size（`TerminalLook.size`）走，不再自锁 12 pt —— 用户点名：输入行文字要跟终端主体一致。Metalterm 的坞在它 12 pt 默认下量得的尺寸是比例不是常数（`DockBox.unit = size/12`：高 30、边距 14、内边 10、字间 7、光标条 2、到达升起 2.5、字高房 15），字号翻倍板就翻倍。字体本身 `TerminalLook.face()` 不再另传尺寸，`lookChanged()` → `refont()` 重测墨水、`needsLayout` → `placeDock()` 重摆 —— 设置里改字号当场生效；`DockBox` 标 `@MainActor`（它现在读 `TerminalLook`），所有使用者本来就在主 actor（含测试）。
- **每字形到达**：`DockLedger` 只把**新写下的字形**标为刚到（0.2 s 的上升+淡入，`FieldCurve.fade`）；改写/删改不动旧字形的年龄 —— 不是每次重报整行重播。测试钉住：追加只标追加的那几个、改写零新到、删中间不把尾部当新的。
- **光标**：`TerminalField` 直接复用 —— 列坐标×步进喂成点，跨列移动是一条 `place` 腿（quartic 头 + cubic 尾的 warp 拖影，驻留窗口 `FieldMotion.settle`），键击 `press` 一下三角 bleed；两根 2 pt 亮条之间的缝就是 smear 光带，落位后合一。Reduce Motion 时 `settle` 一步到位。
- **建议 ghost**：history 建议以 0.45 透明度跟在行尾（shell 侧只在光标位行尾时才报它，从不进 `POSTDISPLAY`）。
- **竖直对齐**：❯ 提示符、行文字、光标三者的墨水中心钉在同一高度上，而这个高度是**画出来量的**（`inkCenter(of:in:)`：把字形画进一张和画板同尺寸的离屏图，扫墨水的行）不是拿字体度量推的 —— ❯ 在等宽字体里没有，落到回退字体（fallback），SF Mono 的回退把它的墨水抬高约 1 pt，别的字体漂别处；`CTLine` 的 optical bounds 给回来的也是行盒不是墨水，所以推导必错、实测必对。量得的高度 `caretMid` 归入 `remeasure()`（换字体重测），`promptDy` 把 ❯ 挪到数字的墨水中心上。这里踩过一个实打实的坑：离屏图走 `tiffRepresentation` → `NSBitmapImageRep(data:)`，而这种 rep 的 `colorAt(x:y:)` 行序是**从上往下**的，与 `lockFocus` 的自下而上绘制正好镜像 —— 不翻回来，数字 "0" 的墨水中心量高 5 pt（30 pt 高的画板上量成 16.75，真值 13.25），此后每根光标条都坐在数字头顶上，❯ 也跟着挪错位。`inkRows` 先把行翻成画板坐标再返回。回归测试 `DumpRenderTests` 把 ❯、数字、光标三样用**真实绘制路径**画到 4x 位图再扫墨水，断言三者墨水中心两两差 < 0.6 pt —— 位图同样行序镜像，扫描处处先翻。
- **零闲置帧照旧**：坞事件走 `present()`；`frame()` 画完网格调 `drawDock()`，还在动就 `DispatchQueue.main.async` 一跳回 pacer，`dockAsking` 保证一跳一帧。板的绘制是 AppKit `draw(_:)`，`drawDock()` 每帧置 `needsDisplay`，时钟读 `CACurrentMediaTime()` 各自自洽。键盘在窗、坞接管时，pacer 的 caret 理由照旧跳帧 —— 坞光标跟着它闪。
- **IME**：坞接管时 `firstRect(forCharacterRange:)` 返回坞上光标处的矩形（跟随 warp 落点），输入法候选框钉在板上而不是网格里。
- **Input Bar 设置（`terminal.inputBar`，Bottom / In the Grid）**：设置面板「Terminal → Input Bar」，默认 Bottom（底部坞）。In the Grid = 经典终端，直接在网格里敲字 —— 这是用户一开始就想要的功能点（Find Bar 设置是当时的误读）。它是上报的总开关：shell 启动时带上 `SEARCH_INPUT_DOCK=0`（只在关掉时写 —— 不设置是脚本自己的默认开，用户环境里的显式 `SEARCH_INPUT_DOCK=0` 依然有效），永不报告就没有坞；运行中切到 In the Grid，终端侧在 `docked()` 入口丢掉后续上报，立着的板当场塌缩（`suspend` + 拆掉），行数让位随板归还；切回 Bottom 对已在跑的 shell 要等下一个终端（上报开关在 spawn 时的环境里）。测试钉住：In the Grid 时上报不产板、不关输入权；运行中关掉时立着的板当场让走。

**光标的闪烁规则**（Metalterm `Cursor::update` 的 blink 分支逐常数核准，反汇编里它是正弦不是方波）：
- **键击后 0.5 s 不闪**（`lastInput + 0.5`，你在打字时它常亮）；
- 之后**1.8263637 s 的正弦周期**，`sin(t/1.8263637 · 2π) > -0.35` 才亮 —— 谷底不是黑是半亮，浮现/沉没都柔；
- **7 s 没碰它就永久常亮**（Metalterm 是 10 s；这里是 7 s，因为键击窗口是自己的 0.5 s 不是它的 0.5 s，阈值自家用过它的尺度）；
- 腿在走不闪（warp/bleed 优先），Reduce Motion 不闪，`TerminalLook.blinks` 关了不闪；腿走完或键击窗口过去的那一帧就是停表的那一帧 —— `blinkClock(at:)` 回答"这一帧之后还要不要为闪而要帧"，不要了时钟就停。

**全屏程序（nvim、pi、less）**：进 alt screen（`?1049/47`）→ 坞挂起（面板立刻塌缩归零、纱撤、`owns` 不变但帧照常给网格），shell 的上报照收但被丟；回到主屏后第一个上报把板带回来 —— `keyOff` 这里的语义不是"多行/超长"而是"程序占了屏"。状态栏不动，只停 git 轮询（见下）。

**底部状态栏**（钉在帧底、全宽，高度恒为网格两行 —— 进出全屏程序也不变：在 nvim 跑的时候改终端行数会把它搅乱，而栏是家具；右缘留 4 pt 内边距）：
- 左边是路径，右边是 git。路径用 shell 自己报的 `OSC 7`（每 prompt 一报，zsh 脚本本来就有），`~` 简写是 Metalterm 的写法，超长路径**留尾**（`/…/尾两级`，叶子才告诉你你在哪）；git 是 `git status --porcelain=v2 --branch` 的纯解析：分支名（detached 用前 7 位提交号）、`⇡⇣` ahead/behind、`+` staged、`~` unstaged、`?` untracked，零计数不显示，不在仓里只有路径。
- **git 不在主线程跑**（自己的串行队列，一个进程一次，`process.wait` 限时 —— 人的 git 再慢也不许挂一个队列）：换目录时问、命令结束时问、进出 alt screen 时问、每 2 s 慢跳动一次；**alt screen 里不问**（nvim 在跑就别去碰它的仓库）、窗口不在屏上/终端藏着不问。答案有新闻才重画（`set` 回 false 就一笔都不画）。

测试 `Tests/SearchTests/TerminalDockTests.swift`（18 个）+ `Tests/SearchTests/TerminalStatusTests.swift`（4 个）：上报解析与转义回并（`;` 在字段里不破帧）、首个报告起板并接管、追加只标新到、改写零新到、接受行淡出+C 撤纱+A 丢行、prompt 当场丢、`off` 塌缩与回带、warp 曲线形状、Reduce Motion 直接就位、纱从 prompt 到屏底的边界；光标闪烁的规则（键击后 0.5 s 不闪、7 s 后永久常亮、腿在走不闪、Reduce Motion 不闪、设置关了不闪）、alt screen 挂起与回带、命令/新 prompt 把板带走；❯/文字/光标共高度且修正不反号（量的是板自己那张配置字号的验）；板高/字高随字号同比（12 pt 量出 30/15、24 pt 量出 60/30）；路径简写与超长留尾、porcelain v2 的分支/ahead/behind/计数/detached/冲突/仓外、状态栏只在有新闻时重画。

## 四、协议覆盖

**OSC**：`0`/`2` 标题、`7` cwd、`8` 超链接、`9` 通知、`777` 通知、`7784` 输入坞上报（自有扩展，见 3.9）、`12` 光标色、`112` 恢复主题光标色、`52` 剪贴板（写）、`133` 命令块（A/B/C/D）。

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
7. **查找面板与光标动效**（`TerminalField` + `TerminalFind` + `TerminalLook.findPlace`）：`rea`/`nm`/`objdump` 反汇编 Metalterm v0.2.1，`Cursor` 四条闭式曲线逐常数核准后落在 ⌘F（见 3.8）；网页侧胶囊同腿。
8. **底部输入坞**（`TerminalDock` + `TerminalShell` 的 zsh 脚本 + `TerminalParse` 的 OSC 7784 + `TerminalView` 接线）：决策反转的那一轮（见 3.9）。zsh 上报驱动，动效全复用 3.8 的曲线；`bash` 照旧只有命令块标记。

## 六、踩过的坑

- **鼠标与选区的行是上下颠倒的**（真 bug，已修）。渲染器把第 0 行画在**顶**（`toClip` 里 `1 - y*2`），而 `TerminalView` **不是 flipped**，它自己的 y 从**底**往上数 —— 于是点在第一行的报告是第 18 行。修法是在 `square`/`heard` 前面插一个 `inGrid(_:)` 把 y 翻过来，`firstRect(forCharacterRange:)` 里那半个同样的 bug（IME 候选框落在 y=20 而不是 ~264）一起修掉。
  **没有**改成 `override var isFlipped { true }`：那会把查找输入框挪到右下角（它的 frame y 是照非翻转的父视图写的），还可能让 AppKit 在 backing `CAMetalLayer` 上设 `isGeometryFlipped`。外科手术式转换比翻整个视图便宜。
- **像素坐标的 off-by-one 是我自己写测试时错的**：期望 `^[[<0;8;8M`，实际拿到 `^[[<0;9;577M`。视图算出的 `(column: 8, row: 576)` 是对的，`MouseReport.bytes` 对两个字段各加一（协议从 1 数起）。测试改成 `Int(4 * pixels.scale) + 1`。
- **`rtk` 钩子会把 `wc -l` 改写成 `tokei`**（报 "The argument '--languages' cannot be used with 'input'"）。数行数用 `grep -c ''`。
- **`storageModePrivate` 的纹理不保证是零**：换图集时实测 5760 个像素里有 4320 个是噪声，所以 `wipe()` 必须真的写。
- **环大小 ≠ `maximumDrawableCount` 是静默的灾难**（CPU 写进 GPU 正在读的槽），所以那条 `assert` 和 `Frame` stride 的断言并排放着。
- **图集换代时在途帧还在读旧纹理**：退役纹理必须留到读它的帧结束，不能在换代那一刻就丢。
- **PTY master 上的 `FIONREAD` 不报可读字节**：实测内核里明明有 4.4 MB，`ioctl(FIONREAD)` 回 0，而 `read` 拿得到。排空只能靠 `poll(POLLIN)`；并且 `POLLHUP/POLLERR` 必须当"结束"处理，否则读源会对着一个空的 master 反复空转，进程退出源排在 lane 后面永远等不到。
- **Darwin 的 `URL` 会缓存它读过的 `resourceValues`**（Chat 视图调试时踩到）：同一个 URL 对象第一次取过 size/mtime 后，文件再长、甚至被原子替换，它都回旧值——磁盘上是新文件，URL 嘴里是旧世界。每次轮询都要 `URL(fileURLWithPath:)` 重造一个；官方没有明说，但实测稳定复现（/tmp 下独立最小程序验证）。同尺寸替换还会撞上缓存签名，所以 ChatReader 的 stamp 记 size+mtime+file id（inode 性质）三者。
- **测试里 `orderFrontRegardless()` 之后跟 `close()` 会炸掉同进程里的下一个重测试**（signal 11）：close 释放已上屏的窗口，释放落在下一个测试的跑动里，随后第一个碰 WebKit/CoreData 的测试 SEGV（伴随 `Failed to create NSXPCConnection` 噪声）。`orderOut(nil)` 不炸（窗口留着但不释放）。dock 测试一直靠泄漏窗口活着；只是它们的类名按字母序排在 DownloadLifecycleTests 之后，这颗雷从没被踩过——AgentChatTests 排在 D 前面才引爆。规则：测试里上过屏的窗口用 `orderOut`，别 `close`。
- **滚动缓冲满 10 万行后，`Array.removeFirst(1)` 是每行搬 10 万个元素**：等价微基准 100k 次约 1.6 s。`Scrollback` 改成环形存储，头部移动 O(1)，读出来的顺序不变。

## 七、还没做的

- ~~**视觉细节**~~（已落地）：SGR 5 闪烁真正绘制（Pacer 加 `.blink` 目的，与 caret 共用同一个时钟与相位，半个周期隐藏字形；屏幕上没有闪烁字时该目的自动退场）、下划线/删除线的样式与颜色（SGR 4:3 记入 `Ink.curl`，画成加重线；58/59 记入 `Ink.line`，装饰 pass 用它）、DECSCNM 反显（`Modes.reversed`，background 与 glyph 两个 pass 一起把格子翻面，Record 的 `spare` 改名为 `decoration`）、SGR 21 修正为双下划线（`TerminalParse.swift`：不再关粗体）、隐藏格子不再画下划线。
- **下划线样式的诚实上限**：4:4（dotted）与 4:5（dashed）在格子模型里与直线同权重绘制——一个 quad 装不下一个真正的波浪/点划线，解析层如实记账，绘制层用加重线作为简写。
- **Kitty 键盘协议**（CSI u）：一整套编码 + 旗标状态机，单独一轮更稳。目前查询如实回答"不支持"。
- **协议级**：sixel、kitty 图形协议、内联图片、连字、bidi、平滑滚动动画。
- **Metalterm 的标志性 UX**：~~底部输入坞~~（已落地，见 3.9，含决策反转的缘由）；命令块折叠、状态栏 + git 仍不学。**光标动效已移植**（见 3.8/3.9）。选区删除与建议 ghost 的 shell 钩子已留（`CSI 27;9;88~`、建议字段），绘制侧后续轮次接。
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
3. **`IslandBar.swift`** —— notch 式横幅，挂在 `ContentView.window_` 的顶部（overlay 里的
   `GeometryReader` 量出窗口宽与高传进来），所有标签页可见；列出全部 session，每行标题是
   **agent 名 · 目录名**（"Claude Code · search"，目录取 cwd 最后一段，没说目录就只显名字）；
   `asking` 的带 Approve/Deny 按钮；点一下跳到它的窗、标签、窗格。**拖动**：整条可沿窗口顶部
   横向拖到任意处，也可往下拖（最深到窗口底留 14pt；`island.down` 存点数），两端各有一条 6pt
   的隐形边缘可拖宽窄（近端动、远端不动，窗口边缘同款）——位置存成窗口宽度的份额（窗口
   缩放后横幅仍在里面），宽度存点数，`IslandPlace` 的纯函数把两者夹在窗口内（最窄 220、
   最宽 720 或窗口减两侧 14pt；下不越过窗口底、上不过它出发的 notch 位），`@AppStorage`
   记住（island.center / island.width / island.down）。**每行都有 ×**：点一下把这行收走
   （`Island.putAway`）——跑完的收了就完；跑着的、等人答话的收走后搁起来（`shelved`），
   直到它再说了值得听的话（新开一轮、要人答应、跑完）才回来，中间的干活噪声不叫醒；
   收走时若它正掣着一个审批，审批连同空答交回它自己的终端去问（那里还能答），关掉
   这一行不是把问题关掉。**抑制规则**：session 的 tty 就是前台窗口当前标签的聚焦窗格（`Island.watched`）
   时不显示——屏幕上正看着它，横幅只会说得比屏幕差。同理，agent 在跑的终端自己发的
   OSC 9 / 777（`.note`）不再转成 macOS 系统通知（`Browser` 的 onNotice 检查
   `Island.atWork(tty:)`）：横幅说得更好，桌面不该再重复一遍。

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

**终端关了，agent 随之退场。** 终端关了，里面的 agent
hook 永远不会再跑（进程被杀不会执行任何 hook），所以由终端自己的结束替它们退场：
`Island.retired(tty:)` 清掉该 tty 的全部 session，还开着的 hold 回一个空 `{}`，让等着的
CLI 回自己终端去问。

测试在 `Tests/SearchTests/IslandTests.swift`（23 条）：事件读取与裁词、各家事件名归一（Gemini/Cursor/Copilot/
Grok 折到横幅自己的词；请求头带名；无 session 的以 tty 为 session）、各形状 settings 的合并与卸载
（Claude/Codex/Qwen/Droid/Gemini/Cursor/Grok/Copilot/Pi/OMP）、桥接脚本写出且可执行、session 状态转移、
`Shape` 两形态、socket 收 HTTP 事件、挂起→回答全链路、裸 JSON、终端结束带走 agent、
横幅位置与宽度夹在窗口内，往下拖的深度也夹在窗口内；一行可收走，收走后只等值得
   再听的话（IslandPlace 纯函数、shelving 语义）。

## 九、Chat 视图（agent 的对话面）

终端里跑着 Claude Code / Pi（含 OMP）/ Codex 时，窗格右上角浮出一枚**两段式开关**：
`Terminal | Chat`，当前模式那一半抬起、文字点满，另一半只有 0.45 的墨。点 Chat，整个
窗格盖上一块对话面板——agent 的思考、说话、工具调用按对话的形状排开，底部一行输入；
点 Terminal（或 Esc）收回，终端还是终端。

用两段而不是一枚带圆点的胶囊：胶囊只写 agent 名，得先按一下才知道它做什么；开关把
两个去处都写出来，按之前就说了自己是什么。左半是屏幕、右半是对话，落在缝上的那一击
归较近的一半（`mouseDown` 里按 `box(.talk).minX - gap/2` 分），所以中间没有一条死带。
抬起那一半除 0.20 的亮底之外还有一圈 0.10 的描边——深色地面上纯靠明度差的一格，在
窗格对过看不出来（先只画亮底，扫像素时两侧只差 0.03 亮度）。

**开关就是设置。** 按哪一半就写进 `terminal.agentView`（`TerminalAgentView {screen, talk}`，
Settings 里叫 Agent View），新建的终端照它开——一个把 Claude Code 读成对话的人，不该在
下一个终端里再说一遍。写的时候**开着才写"talk"、关着才写"screen"**（`openChat`/`closeChat`
各自在状态改完之后写），并且值没变就不写：`terminalLookChanged` 会广播 `TerminalLook.changed`，
每个窗格都会应答，重复宣告会让窗格把自己正在开的对话再开一次。反过来 Settings 里改这一项
也会立刻作用到已开的窗格（同一处 `lookChanged()` 里收口）。没有 agent 的窗格不受这条设置
影响——那里没有第二个视图可去。

**"关掉对话"有两种，只有一种算选择。** 人按 Terminal 那一半是选择；agent 退出时对话自己
收起来，不是选择。这两种都走 `closeChat`，所以它带一个 `said: Bool = true`——agent 走了走
`closeChat(said: false)`，**不写偏好**。这条是补测试时才想到的：如果一律写 `screen`，
那么每次 agent 结束都会把记住的 `chat` 悄悄改写成 `screen`，下一次启动 agent 又回到终端，
用户记住的偏好等于无效——一个测试恰好暴露了它（`testEachHalfAsksForItsOwnSideAndTheChoiceIsRemembered`
末尾那条断言）。

**测试里不走 `Shared.prefs`。** `remember` 在 `Store.testing` 下直接写 `Store.settings` 的键。
不是图省事：在这里构造 `Preferences` 会把它建在"第二个终端打开"那一刻，而它读的 store 在
第一次触碰时就钉死了整套测试的 defaults suite——哪个套件先开窗格，整个进程就跟着它走，
后来说"find bar 在顶部"的测试会发现自己从没选过的东西。这个坑真踩过：聊天测试先选了
Chat，找字条的测试就看到 find bar 在底部。

做法举自 [ovis](https://github.com/dragongrove/ovis)（herdr 的浏览器客户端）的 Chat 模式：
**不解析屏幕，读 agent 自己写的原生 transcript JSONL**。ovis 的审计文档
（chat-mode-audit）记着反向路线的学费：没有原生 transcript 时，终端里的菜单/状态行
会被误认成 assistant 消息；transcript 才是结构化的真相，屏幕只是它的投影。终端永远是
真相的另一面也在这里：输入框不另辟通道，写进 PTY 加回车（`speak`）——你在 Chat 里
说的每个字都落在 CLI 自己的输入里，回终端看得见同一句。

**四个文件，一条链。**

1. **`AgentTalk.swift`** —— "这个窗格里跑的是哪场对话"：`Talk {agent, id, file, cwd}`。
   事件里报路径（Claude 的 hook payload 自带 `transcript_path`；Pi 扩展每次说事带
   `_sessionFile`（`ctx.sessionManager.getSessionFile()`）；Codex 的 `rollout_path`），
   路径必须过 `verify`：`.jsonl`、普通文件、且在**该 agent 自己的 store 里**
   （`~/.claude/projects` / `~/.pi/agent/sessions` / `~/.codex/sessions`，各认环境变量覆盖），
   符号链接解析后判包含——伪造的话报不进任意路径。Pi 的特殊处：session 的第一个回答
   写下之前**文件不存在**（ovis 叫 unwrittenSession），所以 Talk 允许 `file == nil`，
   `settle` 每次轮询时在 store 里找以该 id 结尾的 `.jsonl`，找到了才钉住。
2. **`AgentChat.swift`** —— 把三家各自形状的 JSONL 读成同一种 `ChatLog`：
   `Turn {role: person/agent, parts: [word / thought / tool]}`，工具
   `Tool {name, summary, input, output, failed}` 由 call/answer 按 id 配对，孤儿回答丢弃
   （compact 里带出的中断现场）。人声的噪声前缀（`<command-name>`、`<environment_context>`、
   `<system-reminder>` 等）不进对话。连续的 agent 部分合成一口气（thought+tool+word 是
   一次呼吸）；人的两句话永远是两句话。`ChatReader` 追文件：记 offset 与 stamp
   （size、mtime、file id），文件变小或换了 inode（agent 会整文件重写）→ 清 log 重读；
   半行悬在 carry 里等下一班。
3. **`AgentChatView.swift`** —— 面板的两层：`TerminalChatPaper`（排版与绘制：人声加粗
   带 2pt 左条，agent 0.92，思考 0.40，工具行折叠、点击展开看输出，失败的末尾✗；
   滚轮滚离活端即停跟随，回到底部恢复）与 `TerminalChatView`（纸 + 输入行 + 细分割线）。
   重绘靠签名（每条的词/思考/工具名+摘要+输出+成败，用\u{1}分隔）——工具**回答**到了
   时同一行内容变长，签名变了才重排。开关 `TerminalChatSwitch` 是第三个视图。
4. **`AgentChatPane.swift`** —— TerminalView 的接线：Island 的 `$sessions` 一有变化
   就问这一窗格的 tty 有没有 Talk（注意 `@Published` 的 sink 在 willSet 时送来的是旧数组，
   所以 sink 直接把新数组传进来）；有 → 建开关，没 → 拆（记住的偏好是 Chat 时，开关
   一出现就把对话打开——否则这条设置在「第一次开 agent」这件事上等于没写）。打开时 0.5s Timer 轮询
   `reader.update()`，长了才重排；关上即停。`placeChat` 把开关放在右上角（顶部的查找
   面板在场时让位下移）；**alt 屏不藏**——agent 就住在那里。

与 Island 的关系：Island 管的是"提醒"（别的标签页里 agent 在干嘛），Chat 管的是"对话"
（这一窗格里的 agent 说了什么）——同一个 hook 事件流，两种读法。`IslandEvent` 与
`Session` 各加了一个可选 `talk`，谁报了路径谁就带上。

测试在 `Tests/SearchTests/AgentChatTests.swift`（7 条）：三家记录的解析、孤儿回答丢弃、
跟随与半行悬置与重写重读、store 验证与 settle、开关出现/点击读取/收起/SessionEnd
收走（含 Island 状态流转的端到端）、开关两半各要自己那一半且点击落在开关上（`frame`
不是 `bounds`——第一版就是这么错的）、以及按哪一半就翻成偏好。

## 十、Composer 与模型切换（照着 orbit-pi 的作曲家）

Chat 视图原来只有一行输入。参考
[orbit-pi](../../Downloads/orbit-main/crates/orbit-pi) 的 `ComposerInput`（`composer.rs`），
把它做成一块**作曲家**：上面是对话，中间一行写给 agent，下面一条**页脚**——左边一枚
模型胶囊，右边写着 `⏎ send   esc close`。整个盒子是圆角的一次抬升（`DockBox.ground` +
一圈 0.11 的亮边，和输入坞的盘子同一套家具），一行与页脚之间有一条**缩进到两端之外**的
细线——盒子仍然是"一整个东西"，而不是叠了两块。

**模型清单从哪来：不猜，读各家自己已经写好的目录**（`AgentModels.swift`）。

| agent | 目录 | 现在的模型 | `/model` 参数 |
|---|---|---|---|
| Claude Code | `settings.json` 的 `modelPicker.options`（label/description/model） | transcript 里最后一条 assistant 的 `message.model`，没有就 settings 的 `model` | 模型 id |
| Pi / OMP | `models.json` 的 `providers[*].models[]` | 会话文件里最后一条 `model_change` 的 `provider/modelId`，没有就 settings 的 `defaultProvider` + `defaultModel` | `provider/model` |
| Codex | `models_cache.json` 的 `models[]`（slug / display_name） | `config.toml` 第一个 `[table]` **之前**的 `model` | slug |

三家都认自家环境变量改的道（`CLAUDE_CONFIG_DIR` / `PI_CODING_AGENT_DIR` / `CODEX_HOME`），
和 Island 装 hook 时认的是同一批。**没有目录就不给行**——凭空造一张清单会让程序往
agent 嘴里塞一个它没听过的 `/model`，然后终端里冒出一条用户没要求的错误。这条取舍写进了
测试（`testAnAgentWithNoCatalogOffersNoRows`）。

**读尾部，不读整份。** 一天下来一份 transcript 是几 MB，而答案永远在最后几条里：Claude 的
`message.model` 与 Pi 的 `model_change` 都从文件末尾 256 KB 里找，被 seek 切掉的那半行
（除非它就是文件的头）不算记录。写测试时造了 4000 条 90 字节的假话把第一次 `model_change`
挤出窗口，确认读的是尾部的第二次。

**切换就是那条命令。** 选一行 → 往 PTY 写 `/model <value>\r`（`AgentModels.switchCommand`），
和 Chat 里说话走同一条道。理由和 Chat 自己一样：终端是真相，CLI 自己的 `/model` 才会
把变更写进会话历史、让屏幕和胶囊同时改口。我们不假装知道结果——账号没有的模型，agent
会在终端里报错，而那正是用户在看着的地方。胶囊当场先改成新名字（`TerminalChatView.takeModels`
→ `model.say`），所以点完立刻有回应，不必等 agent 回话。

**弹层的几何。** `TerminalModelList` 是 NSView 不是 NSMenu：要画分组标题（provider 名）、
要画每行的说明（context / reasoning / in use）、要在打字的同时让下面的输入行保留文本。
打开时先落在**现在用的那一行**（也标一颗小点），所以"打开 + 回车"什么都不会变。↑↓ 走行、
跳过标题（`step` 里 do-while 到非 head 为止，绕回不算移动过）；⏎ 选中、Esc 收一层（先收
列表再收 Chat）、↓ 在列表没开时**打开**它——胶囊在角落，模型切换不该要求用手指去找。
鼠标点行也直接选。列表开在盒子上方，**超出窗格顶部就贴着顶边往下压**，绝不把前几行开到
窗外。

**一个踩到的真 bug**：列表在 `take` 时就被塞了行，那时它还 zero-size，`scrollHighlightIntoView`
用 `bounds.height == 0` 一算就把 scroll 滚到了末尾——截图上一看模型名全在下面，开头
（provider 标题、第一行）不见了。修法两层：`scrollHighlightIntoView` 在高度不足 1pt 时
直接 return，并在 `layout()` 里补算一次（那时高度才是真的）。

**第二个**：对话比面板短时，`from = total - start - reachable` 是负数，整段话被顶到面板
**最下面**，上面 80% 空白。改成 `from = max(0, total - start - reachable)`：短的对话从
顶上开始读，长的照旧是"窗口对着话的末尾"。同一个错在 `mouseDown` 的命中换算里也修了。

**第三层：行会自己长。** orbit-pi 的 `ComposerInput` 有 `MAX_LINES = 8`——一行装不下
的问题值得读完再发，而一个只顾往上长的盒子会把被问的那段对话吃掉。这里同样：`lineArea`
按文字自身换行后的高度算（`boundingRect(with:options:.usesLineFragmentOrigin)`），
最多 6 行，再多就由 field editor 自己滚动。**页脚不动**——人正在打字的键位不该因为行变高
而挪位置；纸（对话）让位给行，`box.maxY` 上去多少，纸就少多少。

两个坑记在这里。其一，`NSCell.cellSize(forBounds:)` 对还没排过版的换行文本只会回一行的高度，
用它量就永远长不到第三行（截图里那段中文只长出两行）；改成 `NSString.boundingRect` 才对。
其二，`boundingRect` 的 `with:` 参数是 `NSSize` 不是 `NSRect`，写成 `NSRect` 直接编译不过。

**Shift-⏎ 换行，⏎ 发送。** 判据从事件上取（`NSApp.currentEvent?.modifierFlags.contains(.shift)`），
不是从文本上猜——按键走到 `control(_:textView:doCommandBy:)` 时 field editor 已经把修饰键
吃掉了。另外 AppKit 会把 ⇧⏎ 报成 `insertNewlineIgnoringFieldEditor:`，那条也要接住。

测试在 `Tests/SearchTests/AgentComposerTests.swift`（9 条）：三家目录各自的读法（含 provider
分组与 in use 标记）、没目录就是空、Pi 的 `model_change` 压过 settings、Codex 只认第一张
表之前的 `model`、读尾部时被切掉的半行不算、选择写出 `/model <value>`、作曲家各部件
的位置关系（纸在盒子上、行在盒子里、胶囊在页脚、列表开在盒子上方且不出窗格、打开时落在
在用的那行）、以及行会随问题变高但到上限就停。整套 359 条测试 0 失败。

## 十一、对话的形状（把工具活折起来，把话摆成对话）

第九节把 agent 的 transcript 读成了 `ChatLog`，但一开始它是**平铺**的：一次提问下面
跟着思考、三次工具调用、三次回答，然后才是 agent 真正说的那句话。真实的 Claude Code
跑一个问题会写十几条记录，于是"读对话"变成了在噪声里捞句子——这恰恰是终端屏幕本来就
有的毛病，Chat 视图不该把它原样搬进来。

照 orbit-pi 的做法重排：**工具活折成一行**，只有人说的话和 agent 说的话留在外面。
但"折"要有个规矩，不然长对话里每一段都折着，人反而找不到刚才在干嘛。

**折的规矩：短对话不折，长对话才折。** 纸上排完版后数一遍"说出口的话"（人的提问 +
agent 的回答），不超过 4 句就全开——两三个来回的对话，那些工具行本身就是上下文。
超过 4 句，就从**最新往回**留最后 4 句敞开，更早的每一段工具活各自收成一行。所以
屏幕上永远是这样：上面是一句句折好的"Ran a command · Read a file · Thought once"，
最下面是刚发生的、完整的现场。往回翻的时候再点开——折叠不是丢弃。

**折起来的那行说什么。** 不是"5 次调用"——数数不告诉人任何事。工具名按**人会给它
起的名字**归类（`Kin`）：跑命令、读文件、搜索、取网页、改文件、用工具、思考。`grep`
算搜索不算读（`kin` 里先看 grep/glob/search 再看 read/view/open）——把 grep 说成
"Read a file"是撒谎。同一类多于一次才报数（"Ran 3 commands"），单次就说单数。
顺序按 `Kin.allCases` 固定，所以同一段活在两次重绘里读起来一样。

**人说的话在右边，agent 的在左边。** 一句人声画成一个圆角气泡、右对齐；agent 的话
不加气泡，左对齐通栏。这是让一份 transcript 变成一场对话的那一件事——读的时候眼睛
不用去分辨"这句是谁说的"，位置已经说了。气泡里的字仍然按 `inner` 宽换行，所以长问题
不会顶出窗格。

**每句话下面一行页脚。** 什么时候说的（`21:02`）、这一轮 agent 花了多久（`55s`）、
花了多少 token（`12.4k in · 1.9k out`、`96.0k cached`）。这些都是**记录里本来就有的
事实**，不是估的：时间取 `turn.at`，跨度取 `until - at`（`until` 是这一轮最后一个
记录的时间戳，不是"下一句提问的时间"——否则等待人的那几分钟会被算成 agent 在干活），
token 取 agent 自己写的用量。不到一秒的跨度不写数字（`0s` 是噪声），没有用量就整个
不说。数字按人用的单位：`195k` 而不是 `195.0k`（三位数以上把小数点去掉——那是装出来
的精度），`1.0M` 保留一位。

**用量要落在它数的那一轮上。** Claude/Pi 的用量在 assistant 记录里，跟着记录走就行；
Codex 麻烦一点：它在回答**之后**单独写一条 `token_count`（`event_msg`），如果照"读到最后
一条"的写法，这个数字会落到**下一句**回答上——测试
`testCodexTokenCountsLandOnTheTurnTheyCounted` 就是钉这件事的：它记的是**最近一轮**的
增量（`last_token_usage`），所以落在**前一句** agent 回答上才对，代码里用一个
"还没被认领的最后一个 agent 轮次"来接。缓存的那部分单独说，因为它常常比 input 大
一个量级，混在一起看会以为这一轮很贵。

**右边一道轨。** 每一轮在右边缘占一颗短横线，位置按它在整篇里的高度算。这解决的是
长对话里"我在哪"的问题：滚轮往下翻，轨上会有一段亮带标出**现在看见的是哪一段**；
点某颗横线就把那一轮拉到眼前（`scroll` 直接设到它的顶部，`following` 顺手关掉——
人主动跳走了，就不该被拽回末尾）。轨的命中范围比它画的宽（左右各 4pt），因为它只有
12pt 宽，手指不该为它瞄准。

**折起来的行是门。** 点一下开、再点一下关；工具行自己还有第二道门——点开看那次调用的
输出（`opened: Set<Int>` 记着哪些开着）。两道门都靠 `shape` 报出的矩形做命中：`shape`
是"纸上现在真画了哪些行、每行是什么、在哪"，测试和命中都用它，绘制的算法只有一处，
不会出现"能看见但点不到"。

**测试在 `Tests/SearchTests/AgentTalkViewTests.swift`（10 条）**，全都对着**真画出来的
像素**断言，不是对着公式：折/开两种形状、活动行说的是什么、点折叠行会开、点工具行会
长出输出（行数真的变多）、人声在右 agent 在左（扫那一行像素，左边一点墨都没有）、
页脚的三段数字与"不到一秒不写"、单位、轨上每轮一颗横线、点横线会跳走且不再跟随、
Codex 的用量落在正确的轮次上。

两个坑记在这里，都是写测试时踩的。其一，**图片的行是自上而下的**，纸自己的 y 是自下
而上的：拿 `item.midY` 直接当像素行去扫，扫到的是镜像位置的空白，断言"我的字在右边"
就会失败。其二，**"行数变多"这种断言要看整篇都在纸上**：纸只有 620pt 高时，点开一次
工具输出会把新行挤到可见范围外，前后数出来一样多——把纸给到 900pt 才量得到。

整套 372 条测试 0 失败。
