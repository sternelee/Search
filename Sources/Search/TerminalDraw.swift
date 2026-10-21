import AppKit
import Metal
import simd

// The renderer: everything between the grid and the screen. A square of
// glyph coverage kept resident on the GPU — one R8 slot per character and
// style, cut with CoreText away from the frame that first asked for it (see
// TerminalAtlas) — and a small ring of
// resident cell buffers that the shaders walk by instance id, so a frame
// costs three instanced draws and nothing else. The ring is what lets a
// frame convert only the rows it does not already have in the slot it is
// drawing into — a row the slot was written from is a row nobody can have
// written since, and a scroll is the same rows at other indices (see
// `update` and TerminalCells); what a frame says is drawn from a scene taken
// as a moment of the screen, so nothing is ever read while it is being
// written. No frame is asked for until something changed; what asks for
// frames is TerminalView (see TerminalView.swift).
//
// The shaders live here as a string, which the device compiles on the first
// terminal of a run — the Metal toolchain that SwiftPM would need to build
// a .metallib at build time is a separate download that this Mac did not
// have. The same source is picked up as a .metal file when a build has one
// (the library lookup tries the bundle first), and the string is the one
// truth until then.

/// How many slots the ring of cell buffers has, and with it how many frames
/// may be reading the cells at once. One per drawable, which is what the
/// layer is asked for below; the assertion in the initializer is what keeps
/// the two from coming apart.
private let cellRing = 3

@MainActor
final class TerminalDraw {
    /// A cell as the GPU reads it, mirrored in the shader's CellRecord.
    /// `glyph` is a slot in the atlas plus one; zero says nothing.
    /// `fore`/`back` are packed RGBA; zero means the theme's own colour.
    /// `decoration` is the line a cell wears — under it, through it, both,
    /// straight or curly — and the colour the program asked the line to
    /// wear itself (SGR 58): a different word than `fore`, because a line
    /// without a colour of its own is the ink of the words it runs under,
    /// not whatever the theme says of a blank square.
    struct Record {
        var glyph: UInt16 = 0
        var flags: UInt16 = 0    // 1 wide, 2 underline, 4 strike, 8 curly, 16 blink, 32 colour
        var fore: UInt32 = 0
        var back: UInt32 = 0
        var decoration: UInt32 = 0   // packed RGBA of the line (SGR 58), 0 for the fore's own
    }

    /// What one frame is drawn with, mirrored in the shader's Frame. The
    /// layouts are ordered to pack the same way in both languages — the
    /// assertion in the initializer is the tripwire if they ever don't.
    struct Frame {
        var drawable = simd_float2()      // drawable size, pixels
        var cell = simd_float2()          // one cell, pixels
        var origin = simd_float2()        // first cell's top-left, pixels
        var atlas = simd_float2()         // atlas size, pixels
        var grid = SIMD2<UInt32>()         // columns, rows
        var slot = SIMD2<UInt32>()          // one atlas slot, pixels
        var slots: UInt32 = 0              // slots per atlas row
        var cursorStyle: UInt32 = 0         // TerminalCursor: 0 block, 1 bar, 2 underline
        var cursorInk: UInt32 = 0           // packed RGBA of the caret, 0 for the theme's own
        var blink = simd_float2()          // blink period, seconds; 0 = never
        var blinking: UInt32 = 0           // 1 = words wearing SGR 5 draw on this frame
        var reversed: UInt32 = 0            // DECSCNM: the whole screen is inverted
        var cursor = simd_float4()         // col, row, on, strong
        var selection = simd_float4()      // col0, row0, col1, row1; -1 = none
        var ground = simd_float4()
        var ink = simd_float4()
        var select = simd_float4()         // the selection tint
    }

    // MARK: - what it draws with

    let layer = CAMetalLayer()
    /// One rect over the grid, in the mark pass: the highlight of a find,
    /// or the cursor when it is not a block. The place is in cells —
    /// column, row, cells wide, cells tall. Mirrored in the shaders.
    struct Rect {
        var place: simd_float4
        var tint: simd_float4
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let background: MTLRenderPipelineState
    private let decoration: MTLRenderPipelineState
    private let glyph: MTLRenderPipelineState
    private let mark: MTLRenderPipelineState

    /// The font the atlas is cut from, and the cell it sets in points. Both
    /// move when the face is changed under a live terminal (see `refont`),
    /// which is why neither is a constant.
    private(set) var font: NSFont
    private(set) var cell: CGSize          // measured from the font, in the initializer
    /// The room a terminal leaves at its edges, in points, so a cell's
    /// glyphs never touch the chrome around them. From Settings, and asked
    /// for afresh every time: a terminal is never made to remember it.
    static var inset: CGFloat { CGFloat(TerminalLook.padding) }

    /// The ground as a colour the chrome around a terminal can be painted
    /// with: the gutter between panes is the terminal's own background, so
    /// a dark theme's panes are not divided by a bright strip. Asked for
    /// afresh, as the inset is — a theme can change under a live gutter.
    static var groundColor: NSColor {
        let ground = Theme.current(TerminalLook.theme).ground
        return NSColor(
            srgbRed: CGFloat(ground.x), green: CGFloat(ground.y),
            blue: CGFloat(ground.z), alpha: CGFloat(ground.w)
        )
    }

    /// The glyphs, and the slots in it that cells name: cut away from the
    /// frame that asks for one, so that no frame waits on CoreText (see
    /// TerminalAtlas). The renderer asks it what a character's slot is and
    /// blits in whatever has landed since the last frame; everything else
    /// about it is the atlas's own.
    private let atlas: GlyphAtlas

    /// The colours the frame is painted with. Resolved when they change
    /// rather than once a frame: working a theme out reads the Mac's
    /// appearance, and a terminal that is being scrolled does that a
    /// hundred and twenty times a second for an answer that has not
    /// moved. `repaint` is what re-asks, and it is what both of the ways a
    /// theme can change go through — and what a cleared screen says
    /// everything afresh with (see TerminalView.clearBuffer).
    private var theme = Theme.current(TerminalLook.theme)

    // The ring of cell buffers. A frame reads its cells by instance id
    // while the next frame is being built, so there is one buffer per
    // drawable and a slot is only written again once the frame that read
    // it has completed — writing where the GPU is reading is not a late
    // frame but a torn one. `book` is what each slot already says (see
    // TerminalCells), which is what makes a frame that follows one with
    // nothing changed cost nothing.
    private var buffers: [MTLBuffer?] = Array(repeating: nil, count: cellRing)
    /// The frame that was encoded from each slot, still reading it until
    /// it completes.
    private var flight: [MTLCommandBuffer?] = Array(repeating: nil, count: cellRing)
    /// The slot the next write goes into.
    private var place = -1
    private var book = TerminalCells(ring: cellRing)

    private var rects: MTLBuffer?
    private var rectCount = 0
    private var frame = Frame()

    // MARK: - born

    init?(font given: NSFont) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        font = given
        cell = TerminalDraw.measure(font)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.isOpaque = true
        // Three drawables: what lets a frame be encoded while the one
        // before it is still on the GPU, and what a damage-driven cell
        // cache sizes its ring by, since a slot in the ring is only free
        // once the frame that read it is done. The rest is the default,
        // said out loud because the frame schedule depends on it: the
        // clock is the pacer's (see TerminalPacer), not the layer's own.
        layer.maximumDrawableCount = 3
        layer.displaySyncEnabled = true
        layer.presentsWithTransaction = false
        assert(cellRing == layer.maximumDrawableCount, "the cell ring and the drawable count have come apart")

        guard let library = TerminalDraw.library(device),
              let glyphs = GlyphAtlas(device: device),
              let back = TerminalDraw.pipeline("backgroundVertex", flat: true, library: library, device: device, blend: false),
              let line = TerminalDraw.pipeline("decorationVertex", flat: true, library: library, device: device, blend: false),
              let face = TerminalDraw.pipeline("glyphVertex", flat: false, library: library, device: device, blend: true),
              let stripe = TerminalDraw.pipeline("markVertex", flat: true, library: library, device: device, blend: true)
        else { return nil }
        atlas = glyphs
        background = back
        decoration = line
        glyph = face
        mark = stripe

        assert(MemoryLayout<Frame>.stride == 160, "the shader's Frame and this one have come apart")
    }

    /// The cell a font sets: the advance of its widest character across,
    /// its full line height down. Both integral, so the same glyphs sit
    /// on the same pixels from one frame to the next. Asked of by whoever
    /// divides a room of terminals, to keep a pane from being made too
    /// narrow for a cell of its own.
    static func measure(_ font: NSFont) -> CGSize {
        let wide = ("MM" as NSString).size(withAttributes: [.font: font]).width / 2
        let tall = font.ascender - font.descender + font.leading
        return CGSize(width: max(1, wide.rounded(.up)), height: max(1, tall.rounded(.up)))
    }

    // MARK: - the library

    /// The shaders, as a .metallib from a build that had one (the app's own
    /// bundle first, then SwiftPM's), and otherwise as a string the device
    /// compiles the first time it is asked for.
    private static func library(_ device: MTLDevice) -> MTLLibrary? {
        // A default library may be found that is not ours — the app bundle's
        // is, but a test host's may be some framework's — so one that says
        // nothing of ours is not kept, and the source below is the truth.
        if let made = device.makeDefaultLibrary(), made.makeFunction(name: "markVertex") != nil {
            return made
        }
        for bundle in Bundle.allBundles {
            if let url = bundle.url(forResource: "default", withExtension: "metallib"),
               let made = try? device.makeLibrary(URL: url),
               made.makeFunction(name: "markVertex") != nil {
                return made
            }
        }
        return try? device.makeLibrary(source: TerminalDraw.shaders, options: nil)
    }

    private static func pipeline(_ vertex: String, flat: Bool, library: MTLLibrary, device: MTLDevice, blend: Bool) -> MTLRenderPipelineState? {
        guard let corner = library.makeFunction(name: vertex),
              let face = library.makeFunction(name: flat ? "flatFragment" : "glyphFragment") else { return nil }
        let shape = MTLRenderPipelineDescriptor()
        shape.vertexFunction = corner
        shape.fragmentFunction = face
        shape.colorAttachments[0].pixelFormat = .bgra8Unorm
        if blend {
            shape.colorAttachments[0].isBlendingEnabled = true
            shape.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            shape.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            shape.colorAttachments[0].sourceAlphaBlendFactor = .one
            shape.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        return try? device.makeRenderPipelineState(descriptor: shape)
    }

    // MARK: - sizing

    /// The layer's drawable is the view's size in device pixels; the view
    /// tells it, whenever it is laid out, what that is now.
    func size(_ bounds: CGRect, scale: CGFloat) {
        // A different scale is a different cut of the atlas, so the slot a
        // record names is not the glyph it meant: the ring is emptied of
        // anything worth keeping, and the first cut of the new scale is
        // what says so to the atlas itself.
        if scale != layer.contentsScale { book.forget() }
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// A new face for a terminal already on screen. The atlas is cut from
    /// the font, so the slots already in it are not this font's: the next
    /// frame's `begin` turns the atlas over — every slot handed out again,
    /// every glyph cut again — and until then nothing drawn from this ring
    /// can be trusted, since its records name slots of an atlas that is
    /// about to be somebody else's. The slots themselves are not written
    /// again until that frame is encoded, and this one waits for the frames
    /// still reading them (see `begin` on the atlas).
    func refont(_ new: NSFont) {
        font = new
        cell = TerminalDraw.measure(new)
        book.forget()
    }

    /// Called on the main thread when the atlas has cut a glyph some frame
    /// had to do without. Whoever draws sets it to ask for a frame: the
    /// square was left blank by the frame that named the slot, and a
    /// terminal with nothing else to say has nothing else to ask with.
    var onLanded: (() -> Void)? {
        get { atlas.onLanded }
        set { atlas.onLanded = newValue }
    }

    /// Columns and rows that fit a width and a height, in points.
    func columns(for width: CGFloat) -> Int {
        max(1, Int((width - TerminalDraw.inset * 2) / cell.width))
    }

    func rows(for height: CGFloat) -> Int {
        max(1, Int((height - TerminalDraw.inset * 2) / cell.height))
    }

    // MARK: - the atlas

    /// Says what this frame is cut at — the scale it is drawn in, the cell
    /// it is drawn in, the face it is drawn with — and lets the atlas turn
    /// over if that is not what the last frame was cut at. Every frame says
    /// it, once, at the top; the atlas is the one that decides whether
    /// anything about it has moved, which is what makes a scale change or a
    /// new face something one call can be right about.
    ///
    /// Turning the atlas over is only safe once nothing is reading it: the
    /// frames that could be are the ones this renderer has encoded and not
    /// yet seen finish, so they are waited for here — once per face, not
    /// once a frame. (`take` waits for the slot it is about to write; that
    /// is a different account, and between them every frame that names an
    /// atlas slot is either finished or in `flight`.)
    private func beginAtlas() {
        atlas.begin(scale: layer.contentsScale, cell: cell, font: font) {
            for frame in flight { frame?.waitUntilCompleted() }
        }
    }

    // MARK: - one frame's cells

    /// Everything a frame says that is not its cells: the uniforms the
    /// shaders read, and the rects the mark pass draws — the finds a search
    /// has left in the frame with `found` the one it is standing on, and
    /// the caret when it is not the block the background pass draws.
    /// `cursor` is whether the caret is showing at all, which is how a
    /// blinking cursor is left out of the frames it blinks off in; `strong`
    /// is whether the window has the keyboard, which halves the ink of a
    /// caret that has lost it.
    private func begin(
        scene: Terminal.Scene, theme: Theme, selection: simd_float4?, strong: Bool, showing: Bool,
        finds: [simd_float4], found: simd_float4?,
        reversed: Bool, blinking: Bool
    ) {
        let columns = scene.width
        let lines = scene.height

        frame = Frame()
        frame.atlas = simd_float2(Swift.Float(GlyphAtlas.side), Swift.Float(GlyphAtlas.side))
        frame.slot = SIMD2(UInt32(atlas.across), UInt32(atlas.down))
        frame.slots = UInt32(atlas.slotsPerRow)
        frame.grid = SIMD2(UInt32(columns), UInt32(lines))
        frame.cell = simd_float2(
            Swift.Float(cell.width * layer.contentsScale),
            Swift.Float(cell.height * layer.contentsScale)
        )
        frame.origin = simd_float2(
            Swift.Float(TerminalDraw.inset * layer.contentsScale),
            Swift.Float(TerminalDraw.inset * layer.contentsScale)
        )
        frame.drawable = simd_float2(Swift.Float(layer.drawableSize.width), Swift.Float(layer.drawableSize.height))
        frame.ground = theme.ground
        frame.ink = theme.ink
        frame.select = theme.select
        frame.selection = selection ?? simd_float4(-1, -1, -1, -1)
        frame.cursorStyle = TerminalLook.cursor.word
        frame.cursorInk = theme.fore(scene.cursorInk)
        // The frame's own two modes: DECSCNM's reversal (see `reversed:`)
        // and the half of the blink this frame draws on (see `blinking:`).
        // Both are uniforms rather than records for the same reason — they
        // are things a frame knows about itself, not things a square knows
        // about its words.
        frame.reversed = reversed ? 1 : 0
        frame.blinking = blinking ? 1 : 0
        frame.blink = simd_float2(0.5, 0)
        if let caret = scene.caret, caret.y < lines, caret.x < columns {
            frame.cursor = simd_float4(
                Swift.Float(caret.x), Swift.Float(caret.y), showing ? 1 : 0, strong ? 1 : 0
            )
        }

        // The rects the mark pass draws: the finds a search left, the one it
        // is standing on over them.
        var stripes: [Rect] = []
        stripes.reserveCapacity(finds.count + 2)
        for hit in finds {
            stripes.append(Rect(place: hit, tint: theme.select))
        }
        if let found {
            stripes.append(Rect(
                place: found,
                tint: simd_float4(theme.select.x, theme.select.y, theme.select.z, min(1, theme.select.w * 1.8))
            ))
        }
        // The cursor, when it is not the block the background pass draws: a
        // bar down the left of its cell, or a line under it. Drawn with the
        // marks, so it sits over the background and under the glyphs.
        if showing, let caret = scene.caret, caret.y < lines, caret.x < columns {
            // The colour a program gave the caret (OSC 12) if it named one,
            // and the theme's ink otherwise — half of it mixed toward the
            // ground in a window that has lost the keyboard, which is what
            // the background pass does to the block.
            let tint = TerminalDraw.tint(scene.cursorInk, theme: theme, strong: strong)
            switch TerminalLook.cursor {
            case .block:
                break                       // the background pass has it
            case .bar:
                stripes.append(Rect(
                    place: SIMD4(Swift.Float(caret.x), Swift.Float(caret.y), Swift.Float(2 / cell.width), 1),
                    tint: tint
                ))
            case .underline:
                let high = Swift.Float(max(2 / cell.height, 0.06))
                stripes.append(Rect(
                    place: SIMD4(Swift.Float(caret.x), Swift.Float(caret.y) + 1 - high, 1, high),
                    tint: tint
                ))
            }
        }
        rectCount = stripes.count
        if !stripes.isEmpty {
            let room = stripes.count * MemoryLayout<Rect>.stride
            if (rects?.length ?? 0) < room {
                rects = device.makeBuffer(length: room, options: .storageModeShared)
            }
            if let rects {
                stripes.withUnsafeBytes { raw in
                    rects.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
            }
        }
    }

    // MARK: - one frame's cells, whole

    /// Writes every visible row into a slot of the ring: the whole frame,
    /// from a scene taken as a moment of the screen (Terminal's
    /// `scene(scroll:)`, read under the lane's own order, so these are rows
    /// nobody is writing). This is the shape for a caller with one frame to
    /// draw and nothing before it, and the same conversion is what `update`
    /// does when a screen has turned over and there is nothing in a slot
    /// worth keeping.
    func refresh(
        scene: Terminal.Scene, selection: simd_float4?, strong: Bool, cursor showing: Bool = true,
        finds: [simd_float4] = [], found: simd_float4? = nil,
        reversed: Bool = false, blinking: Bool = true
    ) {
        let columns = scene.width
        let lines = scene.height
        guard columns > 0, lines > 0 else { return }
        // A frame drawn whole has no need of the ring — every slot says all
        // of itself as soon as it is drawn from again — but the rows the
        // other slots are holding are rows of a screen this frame is not:
        // let them go rather than keep them alive for nothing.
        book.forget()
        let slot = take()
        beginAtlas()
        begin(
            scene: scene, theme: theme, selection: selection, strong: strong, showing: showing,
            finds: finds, found: found, reversed: reversed, blinking: blinking
        )
        guard let buffer = buffer(slot, columns: columns, lines: lines) else { return }
        let words = buffer.contents().assumingMemoryBound(to: Record.self)
        convert(scene.lines, band: 0..<lines, into: words, columns: columns)
        book.written(slot, top: scene.top, columns: columns, held: scene.lines)
    }

    // MARK: - one frame's cells, and only the ones that changed

    /// Writes only what this frame's slot does not already say: a row the
    /// slot was written from is a row nobody can have written since — it is
    /// held, and an Array is copied when it is written to — so its records
    /// are already right; a row a scroll moved is the same row at another
    /// index, so its records move with it; and everything else is converted.
    /// The scene is the same moment of the screen `refresh` takes; what
    /// differs is that a frame which follows one with nothing changed
    /// converts nothing at all, and that a scroll is a move.
    ///
    /// `damage` is what the screen has said changed since the last frame,
    /// drained as it is spent. The cells need only one thing from it: that
    /// the screen was turned over (a resize, the alternate screen, a dropped
    /// scrollback), where nothing a slot holds was written from a frame like
    /// this one. What the screen wrote does not have to be reported at all —
    /// a row written in place is a row whose name has changed, and a report
    /// that never comes costs a conversion, not a stale row.
    func update(
        scene: Terminal.Scene, damage: Damage, selection: simd_float4?, strong: Bool,
        cursor showing: Bool = true,
        finds: [simd_float4] = [], found: simd_float4? = nil,
        reversed: Bool = false, blinking: Bool = true
    ) {
        let columns = scene.width
        let lines = scene.height
        guard columns > 0, lines > 0 else { return }
        let slot = take()
        beginAtlas()
        begin(
            scene: scene, theme: theme, selection: selection, strong: strong, showing: showing,
            finds: finds, found: found, reversed: reversed, blinking: blinking
        )
        guard let buffer = buffer(slot, columns: columns, lines: lines) else { return }
        let plan = book.plan(
            slot, rows: scene.lines, top: scene.top, columns: columns, overturned: damage.overturned
        )
        let words = buffer.contents().assumingMemoryBound(to: Record.self)
        if plan.whole {
            convert(scene.lines, band: 0..<lines, into: words, columns: columns)
        } else {
            if plan.shift != 0 {
                // The rows kept from this slot have moved with the screen.
                // A move, not a copy: the band being moved overlaps where
                // it is going, and memmove is what keeps the rows it has
                // not read yet.
                let kept = lines - abs(plan.shift)
                let bytes = kept * columns * MemoryLayout<Record>.stride
                memmove(
                    UnsafeMutableRawPointer(words + (plan.shift > 0 ? 0 : -plan.shift * columns)),
                    UnsafeMutableRawPointer(words + (plan.shift > 0 ? plan.shift * columns : 0)),
                    bytes
                )
            }
            for band in plan.ranges {
                convert(scene.lines, band: band, into: words, columns: columns)
            }
        }
        book.written(slot, top: scene.top, columns: columns, held: scene.lines)
    }

    /// Nothing in the ring is to be trusted again: every cell is said
    /// afresh by the next frame, and the colours are worked out again
    /// rather than taken from the last frame's. For a change the cells
    /// carry their part of but the screen never saw — the colours of a
    /// theme that has just been changed, or the Mac's appearance changing
    /// under a terminal drawn in "Match the Mac".
    func repaint() {
        theme = Theme.current(TerminalLook.theme)
        book.forget()
    }

    /// The slot the next write goes into. The frame that last read it has
    /// to be done with it first: the shaders walk the cells by instance id,
    /// so a write under a frame still on the GPU is a torn row rather than
    /// a stale one. Waiting for a frame three slots back is waiting for
    /// nothing in practice — it has been presented by then — and it is the
    /// same wait `nextDrawable()` makes, on the same account.
    private func take() -> Int {
        let slot = (place + 1) % cellRing
        flight[slot]?.waitUntilCompleted()
        place = slot
        return slot
    }

    /// The cell buffer of one slot, made or grown to hold a frame of this
    /// shape. A growth only ever happens where the slot has nothing worth
    /// keeping anyway — a shape it was not written at is a shape `plan`
    /// calls whole — so nothing has to be carried over into the new one.
    private func buffer(_ slot: Int, columns: Int, lines: Int) -> MTLBuffer? {
        let room = columns * lines * MemoryLayout<Record>.stride
        if (buffers[slot]?.length ?? 0) < room {
            buffers[slot] = device.makeBuffer(length: room, options: .storageModeShared)
        }
        return buffers[slot]
    }

    /// A run of rows — all of them for a whole frame, a band for one that
    /// kept the rest — converted into the slot's records at their own
    /// places in it.
    private func convert(
        _ lines: [Row], band: Range<Int>, into words: UnsafeMutablePointer<Record>, columns: Int
    ) {
        for row in band {
            convert(lines[row], into: words, at: row * columns, columns: columns, theme: theme)
        }
    }

    /// One row of the frame, as the records the shaders walk by instance
    /// id: what each square says, in the colours and the styles it says it
    /// with. Zero in `glyph` is nothing to draw — a space, or a square the
    /// program hid — and a paint the square does not name is the theme's
    /// own.
    private func convert(
        _ line: Row, into words: UnsafeMutablePointer<Record>, at base: Int, columns: Int, theme: Theme
    ) {
        for column in 0..<columns {
            let square = line.cells[column]
            var record = Record()
            // A hidden word (SGR 8) wears nothing at all — not even the
            // line under it, which every other word wears when it asks to.
            // The colour of a hidden word is the background's, which is
            // what hiding it means: the line is the one thing that would
            // give it away, so it goes too.
            let hid = square.ink.hidden
            if square.char != " " {
                record.glyph = atlas.slot(
                    square.char, bold: square.ink.bold, italic: square.ink.italic, wide: square.wide
                )
                if GlyphAtlas.isColour(square.char) { record.flags |= 32 }
            }
            var fore = theme.fore(square.ink.foreground)
            var back = theme.fore(square.ink.background)
            if square.ink.inverse { swap(&fore, &back) }
            if hid { record.glyph = 0 }
            if square.ink.faint {
                // Zero is the square saying "the theme's ink", not black:
                // half of black on a dark ground is a comment nobody can
                // read, so the shorthand is resolved before it is dimmed.
                let base = fore == 0 ? theme.packedInk : fore
                fore = (base & 0xFFFFFF00) | 0x80
            }
            record.fore = fore
            record.back = back
            if !hid, square.ink.underline { record.flags |= 2 }
            if !hid, square.ink.curl { record.flags |= 8 }
            if !hid, square.ink.strike { record.flags |= 4 }
            if square.ink.blink { record.flags |= 16 }
            if square.wide { record.flags |= 1 }
            record.decoration = hid ? 0 : theme.fore(square.ink.line)
            words[base + column] = record
        }
    }

    // MARK: - one frame

    /// Draws one frame, if there is a frame to draw. Only the view calls
    /// this, when something has changed — an idle terminal never does.
    func render() {
        guard place >= 0, buffers[place] != nil, layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        encode(pass, on: command, landed: true)
        command.present(drawable)
        flight[place] = command
        command.commit()
    }

    /// Renders one frame into a fresh texture of its own instead of the
    /// layer's, and hands it back for reading. A presented drawable cannot
    /// be read after the fact, so a test that wants to know what the frame
    /// really painted goes through here.
    ///
    /// `landed` is whether this frame waits for the glyphs it asks for.
    /// True — the default — settles the cutting queue first, so the glyphs
    /// are in the atlas before the frame is encoded, which makes a snapshot
    /// the frame *after* the glyphs landed rather than the frame that had to
    /// do without them: a test comparing one frame with another would
    /// otherwise be comparing how far ahead the cutting queue happened to
    /// be. False hands the frame the atlas as it stands, which is the frame
    /// a terminal really draws when output arrives faster than glyphs can be
    /// cut — the one where a square whose glyph is still being cut has to
    /// show something, and shows nothing.
    func snapshot(landed: Bool = true) -> MTLTexture? {
        let width = Int(layer.drawableSize.width), height = Int(layer.drawableSize.height)
        guard width > 0, height > 0, place >= 0, buffers[place] != nil,
              let command = queue.makeCommandBuffer() else { return nil }
        if landed { atlas.settle() }
        let shape = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layer.pixelFormat, width: width, height: height, mipmapped: false
        )
        shape.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: shape) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        encode(pass, on: command, landed: landed)
        flight[place] = command
        command.commit()
        command.waitUntilCompleted()
        return target
    }

    /// One frame's three instanced passes — background, marks, glyphs —
    /// written into whichever target the pass was handed, and ahead of them
    /// the blit of whatever glyphs have been cut since the last frame (see
    /// `land`) and the clearing of an atlas that has just been made.
    private func encode(_ pass: MTLRenderPassDescriptor, on command: MTLCommandBuffer, landed: Bool) {
        if landed {
            atlas.land(on: command)
        } else {
            // The atlas as it stands: emptied if it is new, and otherwise
            // holding exactly the glyphs that had been cut by the time this
            // frame was made.
            atlas.wipe(on: command)
        }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(frame.ground.x), green: Double(frame.ground.y),
            blue: Double(frame.ground.z), alpha: Double(frame.ground.w)
        )
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let span = Int(frame.grid.x * frame.grid.y)
        var frame = self.frame
        encoder.setVertexBytes(&frame, length: MemoryLayout<Frame>.stride, index: 1)
        encoder.setVertexBuffer(buffers[place], offset: 0, index: 2)
        encoder.setRenderPipelineState(background)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span)
        if rectCount > 0, let rects {
            encoder.setRenderPipelineState(mark)
            encoder.setVertexBuffer(rects, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: rectCount)
        }
        encoder.setRenderPipelineState(decoration)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span)
        encoder.setRenderPipelineState(glyph)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentTexture(atlas.colourTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span)
        encoder.endEncoding()
    }

    // MARK: - the colours

    /// A colour a program named (OSC 12) as the float4 a rect wants, or the
    /// theme's own ink when it named none. Only a truecolour ever arrives
    /// this way — the escape sequence carries red, green and blue and
    /// nothing else — so the one case is the one case. A window that has
    /// lost the keyboard halves it toward the ground, which is the same
    /// mix the shader makes of the block's ink.
    static func tint(_ paint: Paint, theme: Theme, strong: Bool) -> simd_float4 {
        var ink = theme.ink
        if case .rgb(let red, let green, let blue) = paint {
            ink = simd_float4(Swift.Float(red) / 255, Swift.Float(green) / 255, Swift.Float(blue) / 255, 1)
        }
        guard !strong else { return ink }
        return simd_float4(
            (theme.ground.x + ink.x) / 2, (theme.ground.y + ink.y) / 2,
            (theme.ground.z + ink.z) / 2, 1
        )
    }

    /// The colours a theme paints cells with: the two of its own — ground
    /// and ink — and the sixteen ANSI ones. Everything the parser can say
    /// resolves to one of these; a truecolour is its own.
    @MainActor
    struct Theme {
        let ground: simd_float4
        let ink: simd_float4
        let select: simd_float4
        let ansi: [simd_float4]
        /// The palette packed for the shader, one word an index: a frame
        /// asks for it once per cell it converts — the same sixteen
        /// colours, in the same order, over and over — so it is packed
        /// once here rather than per cell.
        let packed: [UInt32]
        /// The theme's own ink, packed: what a square that names no colour
        /// paints with. Kept because `fore` zero is that square's shorthand,
        /// and a word made faint needs the colour behind the shorthand.
        let packedInk: UInt32

        init(ground: simd_float4, ink: simd_float4, select: simd_float4, ansi: [simd_float4]) {
            self.ground = ground
            self.ink = ink
            self.select = select
            self.ansi = ansi
            self.packed = Theme.table(ansi)
            self.packedInk = Theme.pack(ink)
        }

        /// The theme a look asks for. "Match the Mac" — the default — is
        /// the pair the app has always painted with; a named one is the same
        /// palette whichever way the Mac is set.
        static func current(_ look: TerminalTheme = .system) -> Theme {
            // Outside an app there is no NSApp to ask: light is the honest
            // default, and the app always asks with one in hand.
            let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            switch look {
            case .system: return isDark ? .dark : .light
            case .light: return .light
            case .dark: return .dark
            case .solarizedLight: return .solarizedLight
            case .solarizedDark: return .solarizedDark
            }
        }

        /// The colours the app has always painted a terminal with.
        static let light = Theme(
            ground: simd_float4(1.0, 1.0, 1.0, 1.0),
            ink: simd_float4(0.09, 0.09, 0.09, 1.0),
            select: simd_float4(0.22, 0.46, 0.85, 0.22),
            ansi: lightANSI
        )

        static let dark = Theme(
            ground: simd_float4(0.11, 0.11, 0.113, 1.0),   // the same as Palette.NS.ground's dark
            ink: simd_float4(0.93, 0.93, 0.93, 1.0),
            select: simd_float4(0.30, 0.51, 0.83, 0.35),
            ansi: darkANSI
        )

        /// Solarized, as it was published (Ethan Schoonover, 2011): base3
        /// paper with base00 ink, base03 paper with base1 ink, and the eight
        /// accents for the colours.
        static let solarizedLight = Theme(
            ground: simd_float4(0.992, 0.965, 0.890, 1),    // base3
            ink: simd_float4(0.396, 0.482, 0.514, 1),       // base00
            select: simd_float4(0.576, 0.631, 0.631, 0.45), // base1
            ansi: solarizedANSI
        )

        static let solarizedDark = Theme(
            ground: simd_float4(0.000, 0.169, 0.212, 1),    // base03
            ink: simd_float4(0.576, 0.631, 0.631, 1),       // base1
            select: simd_float4(0.027, 0.212, 0.259, 0.85), // base02
            ansi: solarizedANSI
        )

        /// A paint, packed for the shader. Zero is the theme's own colour —
        /// the ink for words, no background for a cell without one.
        func fore(_ paint: Paint) -> UInt32 {
            switch paint {
            case .plain:
                return 0
            case .ansi(let index):
                return packed[Int(index)]
            case .rgb(let red, let green, let blue):
                return UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16 | 0xFF000000
            }
        }

        /// Every index the parser can name, packed: the sixteen of the
        /// palette, then the colour cube, then the grey ramp.
        private static func table(_ ansi: [simd_float4]) -> [UInt32] {
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            var out = Array(ansi.prefix(16)).map(pack)
            out.reserveCapacity(256)
            for index in 16..<256 {
                if index < 232 {
                    let cube = index - 16
                    out.append(
                        steps[cube / 36] | steps[(cube / 6) % 6] << 8 | steps[cube % 6] << 16 | 0xFF000000
                    )
                } else {
                    let grey = UInt32(8 + 10 * (index - 232))
                    out.append(grey | grey << 8 | grey << 16 | 0xFF000000)
                }
            }
            return out
        }

        private static func pack(_ colour: simd_float4) -> UInt32 {
            let red = UInt32(min(255, max(0, colour.x * 255)).rounded())
            let green = UInt32(min(255, max(0, colour.y * 255)).rounded())
            let blue = UInt32(min(255, max(0, colour.z * 255)).rounded())
            return red | green << 8 | blue << 16 | 0xFF000000
        }
    }

    @MainActor
    private static let lightANSI: [simd_float4] = [
        simd_float4(0.16, 0.16, 0.19, 1), simd_float4(0.73, 0.20, 0.18, 1), simd_float4(0.16, 0.55, 0.24, 1),
        simd_float4(0.63, 0.47, 0.08, 1), simd_float4(0.16, 0.35, 0.70, 1), simd_float4(0.55, 0.24, 0.63, 1),
        simd_float4(0.12, 0.51, 0.59, 1), simd_float4(0.24, 0.25, 0.28, 1),
        simd_float4(0.45, 0.46, 0.49, 1), simd_float4(0.85, 0.31, 0.28, 1), simd_float4(0.25, 0.72, 0.36, 1),
        simd_float4(0.78, 0.61, 0.17, 1), simd_float4(0.28, 0.52, 0.91, 1), simd_float4(0.68, 0.36, 0.78, 1),
        simd_float4(0.21, 0.64, 0.73, 1), simd_float4(0.55, 0.56, 0.59, 1),
    ]

    @MainActor
    private static let darkANSI: [simd_float4] = [
        simd_float4(0.55, 0.57, 0.60, 1), simd_float4(0.92, 0.35, 0.33, 1), simd_float4(0.42, 0.80, 0.47, 1),
        simd_float4(0.90, 0.78, 0.36, 1), simd_float4(0.43, 0.62, 0.93, 1), simd_float4(0.81, 0.48, 0.89, 1),
        simd_float4(0.39, 0.79, 0.85, 1), simd_float4(0.80, 0.81, 0.83, 1),
        simd_float4(0.38, 0.40, 0.43, 1), simd_float4(0.96, 0.46, 0.44, 1), simd_float4(0.31, 0.88, 0.41, 1),
        simd_float4(0.97, 0.87, 0.48, 1), simd_float4(0.47, 0.71, 1.00, 1), simd_float4(0.88, 0.54, 0.96, 1),
        simd_float4(0.43, 0.87, 0.96, 1), simd_float4(0.71, 0.72, 0.74, 1),
    ]

    /// Solarized's sixteen, in the order the scheme assigns them: the base
    /// shades for the neutrals, the accents for the colours, and the bright
    /// half the base shades again from the other end.
    @MainActor
    private static let solarizedANSI: [simd_float4] = [
        simd_float4(0.027, 0.212, 0.259, 1),   // base02  black
        simd_float4(0.863, 0.196, 0.184, 1),   // red
        simd_float4(0.522, 0.600, 0.000, 1),   // green
        simd_float4(0.710, 0.537, 0.000, 1),   // yellow
        simd_float4(0.149, 0.545, 0.824, 1),   // blue
        simd_float4(0.827, 0.212, 0.510, 1),   // magenta
        simd_float4(0.165, 0.631, 0.596, 1),   // cyan
        simd_float4(0.933, 0.910, 0.835, 1),   // base2   white
        simd_float4(0.000, 0.169, 0.212, 1),   // base03  bright black
        simd_float4(0.796, 0.294, 0.086, 1),   // orange  bright red
        simd_float4(0.345, 0.431, 0.459, 1),   // base01  bright green
        simd_float4(0.396, 0.482, 0.514, 1),   // base00  bright yellow
        simd_float4(0.514, 0.580, 0.588, 1),   // base0   bright blue
        simd_float4(0.424, 0.443, 0.769, 1),   // violet  bright magenta
        simd_float4(0.576, 0.631, 0.631, 1),   // base1   bright cyan
        simd_float4(0.992, 0.965, 0.890, 1),   // base3   bright white
    ]

    // MARK: - the shaders

    /// The whole renderer in four instanced draws: one pass for the
    /// background a cell paints over the ground (selection and the cursor
    /// live here), one for the find highlights and the cursor's own bar or
    /// line over them, one for the lines under and through struck words,
    /// and one for the glyphs, each a quad sampling the atlas.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    // One cell of the grid, as the CPU wrote it into the resident buffer.
    struct CellRecord {
        uint16_t glyph;
        uint16_t flags;   // 1 wide, 2 underline, 4 strike, 8 curly, 16 blink, 32 colour
        uint32_t fore;
        uint32_t back;
        uint32_t decoration;  // packed RGBA of the line (SGR 58), 0 for the fore's own
    };

    // One rect of the mark pass, as the CPU wrote it: a place in cells —
    // column, row, cells wide, cells tall — and its colour.
    struct RectRecord {
        float4 place;
        float4 tint;
    };

    // What one frame is drawn with. Mirrored in Swift, field for field.
    struct Frame {
        float2 drawable;
        float2 cell;
        float2 origin;
        float2 atlas;
        uint2 grid;
        uint2 slot;
        uint slots;
        uint cursorStyle;
        uint cursorInk;
        float2 blink;     // blink period, seconds; 0 = never
        uint blinking;    // 1 = words wearing SGR 5 draw on this frame
        uint reversed;    // DECSCNM: the whole screen is inverted
        float4 cursor;
        float4 selection;
        float4 ground;
        float4 ink;
        float4 select;
    };

    struct FlatOut {
        float4 place [[position]];
        float4 tint;
    };

    struct GlyphOut {
        float4 place [[position]];
        float4 tint;
        float2 uv;
        uint colour;
    };

    // A triangle strip takes its vertices two at a time, so these have to
    // zigzag. Going round the quad's edge instead makes the second triangle
    // share an edge with the first rather than the diagonal: the two of them
    // then overlap down one half of the cell and leave a wedge of the other
    // half unpainted, which cuts a slice out of every glyph.
    static constant float2 corners[4] = {
        float2(0, 0), float2(0, 1), float2(1, 0), float2(1, 1)
    };

    static float4 unpack(uint32_t word) {
        return float4(
            float(word & 255u) / 255.0,
            float((word >> 8) & 255u) / 255.0,
            float((word >> 16) & 255u) / 255.0,
            float(word >> 24) / 255.0
        );
    }

    static uint32_t pack(float4 colour) {
        return uint32_t(colour.r * 255.0 + 0.5)
            | (uint32_t(colour.g * 255.0 + 0.5) << 8)
            | (uint32_t(colour.b * 255.0 + 0.5) << 16)
            | (uint32_t(clamp(colour.a, 0.0, 1.0) * 255.0 + 0.5) << 24);
    }

    static float4 toClip(float2 point, float2 drawable) {
        float2 part = point / drawable;
        return float4(part.x * 2.0 - 1.0, 1.0 - part.y * 2.0, 0.0, 1.0);
    }

    static bool underCursor(uint col, uint row, constant Frame& f) {
        return f.cursor.z > 0.0 && col == uint(f.cursor.x) && row == uint(f.cursor.y);
    }

    static bool picked(uint col, uint row, constant Frame& f) {
        return f.selection.x >= 0.0 && col >= f.selection.x && col <= f.selection.z
            && row >= f.selection.y && row <= f.selection.w;
    }

    // The background pass: one quad per cell that paints something over
    // the ground — its own colour, the selection, or the cursor's block.
    vertex FlatOut backgroundVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]],
        constant Frame& f [[buffer(1)]], const device CellRecord* cells [[buffer(2)]]
    ) {
        FlatOut out;
        CellRecord c = cells[iid];
        uint col = iid % f.grid.x;
        uint row = iid / f.grid.x;
        bool under = underCursor(col, row, f);
        bool held = picked(col, row, f);
        // DECSCNM turns the whole screen over: a square that named no
        // background names one now — the ink of its own words — and one
        // that named one names none. Every glyph is inverted to match,
        // below, so the two passes turn a square over together.
        uint back = c.back;
        if (f.reversed != 0u && (c.flags & 16u) == 0u) {
            back = c.back == 0u ? (c.fore == 0u ? pack(f.ink) : c.fore) : 0u;
        }
        if (back == 0u && !under && !held) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            return out;
        }
        float4 colour = back == 0u ? f.ground : unpack(back);
        if (held) {
            colour = float4(mix(colour.rgb, f.select.rgb, f.select.a), colour.a);
        }
        if (under && f.cursorStyle == 0u) {
            // A block cursor is the ink itself — or the colour a program
            // gave it (OSC 12), which is the one thing a program can say
            // about a caret it has otherwise no say in; a window that has
            // lost the keyboard gets half of one, mixed toward the ground.
            // A bar or a line is drawn with the marks instead — see
            // markVertex.
            float4 ink = f.cursorInk == 0u ? f.ink : unpack(f.cursorInk);
            colour = f.cursor.w > 0.5 ? ink : mix(f.ground, ink, 0.5);
        }
        float2 point = f.origin + float2(col, row) * f.cell + corners[vid] * f.cell;
        out.place = toClip(point, f.drawable);
        out.tint = colour;
        return out;
    }

    // The mark pass: one quad per rect — a find's highlight, the cursor
    // when it is not a block — over the background, under the glyphs.
    vertex FlatOut markVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]],
        constant Frame& f [[buffer(1)]], const device RectRecord* rects [[buffer(0)]]
    ) {
        FlatOut out;
        RectRecord r = rects[iid];
        float2 point = f.origin + (r.place.xy + corners[vid] * r.place.zw) * f.cell;
        out.place = toClip(point, f.drawable);
        out.tint = r.tint;
        return out;
    }

    // The lines a cell can wear: under it — straight, or curly as a
    // wave — or through it, in the colour the program named for the
    // line (SGR 58) or the ink of the words it wears it under. A double
    // line (SGR 21) is drawn as the one that carries its weight.
    vertex FlatOut decorationVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]],
        constant Frame& f [[buffer(1)]], const device CellRecord* cells [[buffer(2)]]
    ) {
        FlatOut out;
        CellRecord c = cells[iid];
        bool under = (c.flags & 2u) != 0u;
        bool struck = (c.flags & 4u) != 0u;
        bool curly = (c.flags & 8u) != 0u;
        if (!under && !struck) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            return out;
        }
        uint col = iid % f.grid.x;
        uint row = iid / f.grid.x;
        bool wide = (c.flags & 1u) != 0u;
        float2 point = f.origin + float2(col, row) * f.cell;
        float across = wide ? 2.0 * f.cell.x : f.cell.x;
        float4 tint = c.decoration == 0u ? (c.fore == 0u ? f.ink : unpack(c.fore)) : unpack(c.decoration);
        if (under) {
            // A curly line (4:3) is drawn as the heavier one: the wave it
            // names is a shape a quad cannot hold, and a line that carries
            // more weight is the honest shorthand for it at cell sizes.
            // A double line (SGR 21) is drawn as the one that carries its
            // weight, which is the straight one.
            float high = curly ? max(f.cell.y * 0.18, 2.0) : max(f.cell.y * 0.09, 1.0);
            point.y += f.cell.y - high;
            out.place = toClip(point + corners[vid] * float2(across, high), f.drawable);
            out.tint = tint;
            return out;
        }
        float high = max(f.cell.y * 0.06, 1.0);
        point.y += (f.cell.y - high) * 0.5;
        out.place = toClip(point + corners[vid] * float2(across, high), f.drawable);
        out.tint = tint;
        return out;
    }

    // The glyphs: one quad per cell that says something, sampling its slot
    // out of the atlas. A wide glyph spans the two cells it was given.
    vertex GlyphOut glyphVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]],
        constant Frame& f [[buffer(1)]], const device CellRecord* cells [[buffer(2)]]
    ) {
        GlyphOut out;
        CellRecord c = cells[iid];
        out.colour = (c.flags & 32u) != 0u ? 1u : 0u;
        if (c.glyph == 0u) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            out.uv = float2(0.0);
            return out;
        }
        // A word wearing SGR 5 hides on the frames it blinks off —
        // the glyph alone, and only on a screen not turned over: a
        // blink under DECSCNM is drawn as the reversal, because a
        // reversal says the ink of the square plainly enough.
        if ((c.flags & 16u) != 0u && f.blinking == 0u && f.reversed == 0u) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            out.uv = float2(0.0);
            return out;
        }
        uint col = iid % f.grid.x;
        uint row = iid / f.grid.x;
        bool wide = (c.flags & 1u) != 0u;
        float2 point = f.origin + float2(col, row) * f.cell
            + corners[vid] * float2(wide ? 2.0 : 1.0, 1.0) * f.cell;
        uint held = c.glyph - 1u;
        float2 place = float2((held % f.slots) * f.slot.x, (held / f.slots) * f.slot.y);
        out.uv = (place + corners[vid] * float2(f.slot) * float2(wide ? 2.0 : 1.0, 1.0)) / f.atlas;
        // Only a block cursor inverts the glyph it covers; a bar or a line
        // leaves the glyph alone and is drawn over the background.
        bool covered = underCursor(col, row, f) && f.cursorStyle == 0u;
        if (covered) {
            out.tint = f.ground;
        } else if (f.reversed != 0u) {
            // DECSCNM: a glyph that named no ink names the ground's, and
            // one that named one goes unnamed — the glyph pass and the
            // background pass turn a square over together.
            out.tint = c.fore == 0u ? f.ink : f.ground;
        } else {
            out.tint = c.fore == 0u ? f.ink : unpack(c.fore);
        }
        out.place = toClip(point, f.drawable);
        return out;
    }

    fragment float4 flatFragment(FlatOut in [[stage_in]]) {
        return in.tint;
    }

    fragment float4 glyphFragment(
        GlyphOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        texture2d<float> colourAtlas [[texture(1)]]
    ) {
        constexpr sampler pick(mag_filter::nearest, min_filter::nearest);
        // An emoji brings its own colours: the sample is RGBA, written
        // premultiplied by CoreText, and the frame's tint has no say in
        // them. Un-premultiply for the blend the pipeline was made with.
        if (in.colour != 0u) {
            float4 paint = colourAtlas.sample(pick, in.uv);
            if (paint.a <= 0.004) { discard_fragment(); }
            float3 rgb = paint.a > 0.0 ? paint.rgb / paint.a : float3(0.0);
            return float4(rgb, paint.a * in.tint.a);
        }
        float cover = atlas.sample(pick, in.uv).r;
        if (cover <= 0.004) { discard_fragment(); }
        return float4(in.tint.rgb, in.tint.a * cover);
    }
    """
}
