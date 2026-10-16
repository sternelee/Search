# 集成终端标签页

> 目标：在 Search 里加一个终端标签页，文字由 Metal 直接绘制。做法参考 [metalterm.dev](https://metalterm.dev/) —— 它的源码闭源，但本机装着 0.2.1，二进制、`default.metallib`、termcap 与作者的公开表述能互相印证，所以**学的是查实的机制，不是宣传数字**。代码全部自写，除 Apple 自带框架外零依赖。
>
> **状态：已落地。** 十二个源文件、十四个测试文件（216 个测试全绿），`./build.sh` release 通过。下面写的是**它现在的样子**，不是打算做成什么样。还没做的集中在第七节。

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
| **常驻 GPU 的字形图集**："a 200 MB log costs what an empty prompt costs" | 一张 2048² `r8Unorm`，`.storageModePrivate`，blit 写入，ASCII 预切。见 3.2 |
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
| `Terminal.swift` (574) | PTY 生命周期（`openpty` + `posix_spawn`）、读写调度、`TIOCSWINSZ`、lane（单条串行队列，解析与取景同序）、`Scene`/`look` 两个取景口、`Modes` 快照 |
| `TerminalGrid.swift` (765) | 屏幕模型：`Cell`/`Row`、滚动缓冲（`trim()` 裁到 `scrollback`）、alt screen、滚区域、命令块区间表、超链接内联表、光标色、`Damage` |
| `TerminalParse.swift` (681) | VT 解析器。纯逻辑，可单测 |
| `TerminalCells.swift` (168) | **3 槽的格子环**：以 `Screen.place(row)` 为键的逐行缓存，`owed` 集合，滚动走 memmove |
| `TerminalAtlas.swift` (509) | **异步字形图集**：整数 `GlyphKey`、reserve-then-fill、后台串行切割、`generation` 换代 |
| `TerminalDraw.swift` (1006) | Metal 渲染器：设备/队列/四个管线、一个 pass 的编码、MSL 内联、`Frame`/`Record` |
| `TerminalPacer.swift` (184) | 帧节奏：`NSView.displayLink`、理由集（damage/caret/once/hold）、闪烁与 hold 的相位 |
| `TerminalView.swift` (908) | `NSView` + `CAMetalLayer`：键盘（含 IME 提交路径、DECCKM/DECKPAM）、鼠标上报与选区、滚轮、尺寸换算、焦点上报、⌘-click、命令块跳转 |
| `TerminalMouse.swift` (162) | 四种鼠标编码的字节与坐标换算。纯逻辑，可单测 |
| `TerminalLook.swift` (161) | 设置项的运行时镜像（`TerminalLook.font/size/theme/…`），`changed` 通知 |
| `TerminalShell.swift` (131) | shell 集成片段的生成与注入（zsh/bash） |
| `TerminalFind.swift` (177) | ⌘F 滚动缓冲查找、覆盖层输入框、上下一个 |

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

### 3.4 PTY 与 shell 集成

- `openpty` + `posix_spawn` 起 `$SHELL`（无则 `/bin/zsh`），`login_tty` 到从端。主端 fd 挂 `DispatchSourceRead`，一次读 64 KB 循环，天然背压。
- **一个 lane**：解析与取景在同一条串行队列上同序执行。`scene(scroll:)` 会拷贝网格（给测试和 `TerminalFind` 用），`look(scroll:_:)` 不拷贝（在 lane 体内、在活行上跑闭包）—— 热路径走 `look`。
- **shell 集成不碰用户 rc**：zsh 走 `ZDOTDIR` 指向 `Store.file("Terminal")` 下的目录，里面 `.zshenv/.zprofile/.zshrc/.zlogin` **每个都先 source 用户自己那份**，再装 OSC 133 钩子；bash 走 `--rcfile search.bashrc -i`。fish/sh 不包装（没有等价的、不改用户文件的注入路径，宁可没有命令块也不要动用户的配置）。
- 尺寸变化：视图布局 → 换算行列 → `TIOCSWINSZ` → 申请一帧。

### 3.5 与现有系统的集成矩阵

| 系统 | 处理 |
|---|---|
| **TabBar** | 标题 = OSC 0/2；终端标签页按 `isTerminal` 走自己的图标；pin 照常 |
| **地址栏** | 显示 OSC 7 的 cwd（写进 `Tab.address`） |
| **Session** | `Entry.terminal: Bool?`，nil 即网页；恢复 = 重建 shell |
| **Sleep** | 不睡。`awake(because:)` 报 `"a live shell"` |
| **Split View** | 直接可用（`PaneStage` 收 `NSView`） |
| **⌘K 切换器 / TabGroup / Spaces** | 走 `Tab` 统一接口，零改动 |
| **通知** | OSC 9 / 777 → `Notifications.swift` |
| **菜单** | 文件 ▸ New Terminal（`⌥⌘T`，`file.newTerminal`）；标签 ▸ Next/Previous Command（`⌘↑`/`⌘↓`，仅在 `browser.active?.isTerminal == true` 时可用） |
| **AppleScript** | `address` 报 cwd，`title` 照报 |

### 3.6 验收基准（原定目标，实际见下）

- `cat` 大日志、118×34、连续滚动：120 Hz ≥ 119 fps、0 掉帧。GPU ≤ 0.5 ms（Metalterm 实测 0.22 ms）。
- 10 万行 PTY 吞吐 < 80 ms；10k 行后内存增量 < 25 MB。
- **闲置（无输出、无焦点）CPU/GPU 占用 0%，不排帧** —— 这条由 `TerminalPacerTests` 的"空集则停表"直接钉住。
- vim/htop/ssh/tmux 功能正确（alt screen、鼠标、键序）。

性能数字以 Instruments 实测为准，本节保留为回归线，不当作已量到的结论。

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

## 七、还没做的

- **视觉细节**：SGR 5 闪烁真正绘制（`ink.blink` 解析了但渲染器不读）、下划线/删除线的样式与颜色（SGR 4:x / 58）、DECSCNM 反显（`reverseVideo` 解析进 `Modes` 了但渲染器不用）、SGR 21 的正确含义（现在是"关粗体"，实为双下划线 —— 这是个真 bug，`TerminalParse.swift:381`）、隐藏格子仍画下划线。
- **Kitty 键盘协议**（CSI u）：一整套编码 + 旗标状态机，单独一轮更稳。目前查询如实回答"不支持"。
- **协议级**：sixel、kitty 图形协议、内联图片、连字、bidi、彩色 emoji 图集、平滑滚动动画。
- **Metalterm 的标志性 UX**：底部输入坞、命令块折叠、状态栏 + git、光标动效。
- **多显示器拖拽**会引起 `contentsScale` 变化 → 整个图集换代 → 闪一下。缓解是按缩放双图集缓存，先记着不建。
- **架构**：不引入 Rust 核心，不引入 libghostty。
