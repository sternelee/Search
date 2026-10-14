import AppKit
import CoreText
import Metal
import simd

// The renderer: everything between the grid and the screen. A 2048-square
// atlas of glyph coverage — one R8 slot per character and style, rasterised
// with CoreText the first time one is asked for — and one resident buffer of
// cell records that the shaders walk by instance id, so a frame costs three
// instanced draws and nothing else. No frame is asked for until something
// changed; what asks for frames is TerminalView (see TerminalView.swift).
//
// The shaders live here as a string, which the device compiles on the first
// terminal of a run — the Metal toolchain that SwiftPM would need to build
// a .metallib at build time is a separate download that this Mac did not
// have. The same source is picked up as a .metal file when a build has one
// (the library lookup tries the bundle first), and the string is the one
// truth until then.

@MainActor
final class TerminalDraw {
    /// A cell as the GPU reads it, mirrored in the shader's CellRecord.
    /// `glyph` is a slot in the atlas plus one; zero says nothing.
    /// `fore`/`back` are packed RGBA; zero means the theme's own colour.
    struct Record {
        var glyph: UInt16 = 0
        var flags: UInt16 = 0    // 1 wide, 2 underline, 4 strike
        var fore: UInt32 = 0
        var back: UInt32 = 0
        var spare: UInt32 = 0    // reserved for command-block marks
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
        var fill: UInt32 = 0                // keeps the tail aligned
        var cursor = simd_float4()         // col, row, on, strong
        var selection = simd_float4()      // col0, row0, col1, row1; -1 = none
        var ground = simd_float4()
        var ink = simd_float4()
        var select = simd_float4()         // the selection tint
    }

    // MARK: - what it draws with

    let layer = CAMetalLayer()
    /// One rect over the grid, in the mark pass: a gutter mark of a
    /// command block, or the highlight of a find. The place is in cells —
    /// column, row, cells wide, cells tall — and can reach outside them,
    /// into the inset, for the gutter. Mirrored in the shaders.
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

    /// The font the atlas is cut from, and the cell it sets in points.
    let font: NSFont
    let cell: CGSize                       // set below, once, from the font
    /// The room a terminal leaves at its edges, in points, so a cell's
    /// glyphs never touch the chrome around them.
    static let inset: CGFloat = 4

    private let atlas: MTLTexture
    private var next = 0                    // first free slot in the atlas
    private var given: [String: UInt16] = [:]
    private var faces: [String: NSFont] = [:]   // "style@scale" → the face rasterised with

    private var cells: MTLBuffer?
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

        let square = 2048
        let shape = MTLTextureDescriptor()
        shape.textureType = .type2D
        shape.pixelFormat = .r8Unorm
        shape.width = square
        shape.height = square
        shape.storageMode = .managed
        guard let atlas = device.makeTexture(descriptor: shape),
              let library = TerminalDraw.library(device),
              let back = TerminalDraw.pipeline("backgroundVertex", flat: true, library: library, device: device, blend: false),
              let line = TerminalDraw.pipeline("decorationVertex", flat: true, library: library, device: device, blend: false),
              let face = TerminalDraw.pipeline("glyphVertex", flat: false, library: library, device: device, blend: true),
              let stripe = TerminalDraw.pipeline("markVertex", flat: true, library: library, device: device, blend: true)
        else { return nil }
        self.atlas = atlas
        background = back
        decoration = line
        glyph = face
        mark = stripe

        assert(MemoryLayout<Frame>.stride == 144, "the shader's Frame and this one have come apart")
    }

    /// The cell a font sets: the advance of its widest character across,
    /// its full line height down. Both integral, so the same glyphs sit
    /// on the same pixels from one frame to the next.
    private static func measure(_ font: NSFont) -> CGSize {
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
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    /// Columns and rows that fit a width and a height, in points.
    func columns(for width: CGFloat) -> Int {
        max(1, Int((width - TerminalDraw.inset * 2) / cell.width))
    }

    func rows(for height: CGFloat) -> Int {
        max(1, Int((height - TerminalDraw.inset * 2) / cell.height))
    }

    // MARK: - the atlas

    /// The slot a character is drawn from — cut fresh, and uploaded, the
    /// first time it is asked for, at whatever scale the layer is set in by
    /// then. Zero when the atlas is full or the character is not one to draw.
    private func slot(for char: Character, wide: Bool, bold: Bool, italic: Bool) -> UInt16 {
        if char == " " { return 0 }
        let style: UInt16 = (bold ? 1 : 0) | (italic ? 2 : 0)
        let key = "\(style)\(wide ? "w" : "")\(char)"
        if cutScale != scale {
            // A scale change retires every slot: the ones already cut were
            // cut at the old one.
            cutScale = scale
            given = [:]
        }
        if let found = given[key] { return found }
        let room = (wide ? 2 : 1) * across
        guard let cut = raster(char, across: room, down: down, style: style) else { return 0 }
        inFlight?.waitUntilCompleted()
        inFlight = nil
        guard let place = reserve(wide: wide) else { return 0 }
        let region = MTLRegionMake2D((place % slotsPerRow) * room, (place / slotsPerRow) * down, room, down)
        atlas.replace(region: region, mipmapLevel: 0, withBytes: cut, bytesPerRow: room)
        let index = UInt16(place + 1)
        given[key] = index
        return index
    }

    /// The scale the atlas was last cut at, retired when it changes.
    private var cutScale: CGFloat = 0

    /// An atlas slot's size, in device pixels: the cell's, rounded up so a
    /// slot always starts on a whole pixel of its own.
    private var scale: CGFloat { layer.contentsScale }
    private var across: Int { Int((cell.width * scale).rounded(.up)) }
    private var down: Int { Int((cell.height * scale).rounded(.up)) }

    /// Where the next slot comes from. A wide character takes the pair of
    /// slots it spans, which is why the atlas keeps whole rows of them.
    private var slotsPerRow: Int { 2048 / across }

    private func reserve(wide: Bool) -> Int? {
        let total = slotsPerRow * (2048 / down)
        if wide {
            if next % slotsPerRow + 1 >= slotsPerRow { next = (next / slotsPerRow + 1) * slotsPerRow }
            guard next + 1 < total else { return nil }
            let place = next
            next += 2
            return place
        }
        guard next < total else { return nil }
        let place = next
        next += 1
        return place
    }

    /// One glyph of coverage, in an R8 square: white on black, drawn by
    /// CoreText at the scale the layer is set in, sitting on the baseline
    /// the cell's height was cut from. A scale change empties the cache —
    /// the slots of a new scale are not the slots of the old one.
    private func raster(_ char: Character, across: Int, down: Int, style: UInt16) -> [UInt8]? {
        let key = "\(style)@\(scale)"
        let face = faces[key] ?? {
            var font = self.font
            var traits: NSFontTraitMask = []
            if style & 1 != 0 { traits.insert(.boldFontMask) }
            if style & 2 != 0 { traits.insert(.italicFontMask) }
            if !traits.isEmpty { font = NSFontManager.shared.convert(self.font, toHaveTrait: traits) }
            font = NSFontManager.shared.convert(font, toSize: font.pointSize * scale)
            faces[key] = font
            return font
        }()
        guard across > 0, down > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: across * down)
        let marked = NSAttributedString(string: String(char), attributes: [
            .font: face, .foregroundColor: NSColor.white,
        ])
        let line = CTLineCreateWithAttributedString(marked)
        let space = CGColorSpaceCreateDeviceGray()
        // The baseline: the descent above the bitmap's floor, plus half the
        // leading — the same room the cell's height was measured from.
        let rise = -face.descender + (CGFloat(down) - face.ascender + face.descender) / 2
        bytes.withUnsafeMutableBytes { raw in
            guard let page = CGContext(
                data: raw.baseAddress, width: across, height: down,
                bitsPerComponent: 8, bytesPerRow: across,
                space: space, bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return }
            page.textPosition = CGPoint(x: 0, y: rise)
            CTLineDraw(line, page)
        }
        return bytes
    }

    // MARK: - one frame's cells

    /// Writes the visible rows into the resident buffer: everything the
    /// frame needs but what only it knows. Called whenever anything the
    /// cells say or look like has changed — never on a clock of its own.
    /// The scene is the renderer's own moment of the screen (Terminal's
    /// `scene(scroll:)`), taken under the lane's order, so this reads
    /// rows nobody is writing. The marks are the command blocks the shell
    /// pointed at (OSC 133), the finds the matches a search left in the
    /// frame — with `found` the one it is standing on, held brighter.
    func refresh(
        scene: Terminal.Scene, selection: simd_float4?, strong: Bool,
        marks: [Terminal.Scene.Mark] = [], finds: [simd_float4] = [], found: simd_float4? = nil
    ) {
        let columns = scene.width
        let lines = scene.height
        guard columns > 0, lines > 0 else { return }
        let count = columns * lines
        if cells == nil || cells!.length < count * MemoryLayout<Record>.stride {
            cells = device.makeBuffer(length: count * MemoryLayout<Record>.stride, options: .storageModeShared)
        }
        guard let cells else { return }
        let theme = Theme.current()

        frame = Frame()
        frame.atlas = simd_float2(2048, 2048)
        frame.slot = SIMD2(UInt32(across), UInt32(down))
        frame.slots = UInt32(slotsPerRow)
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
        if let caret = scene.caret, caret.y < lines, caret.x < columns {
            frame.cursor = simd_float4(Swift.Float(caret.x), Swift.Float(caret.y), 1, strong ? 1 : 0)
        }

        let words = cells.contents().assumingMemoryBound(to: Record.self)
        for row in 0..<lines {
            let line = scene.lines[row]
            let base = row * columns
            for column in 0..<columns {
                let square = line.cells[column]
                var record = Record()
                if square.char != " " {
                    record.glyph = slot(
                        for: square.char, wide: square.wide,
                        bold: square.ink.bold, italic: square.ink.italic
                    )
                }
                var fore = theme.fore(square.ink.foreground)
                var back = theme.fore(square.ink.background)
                if square.ink.inverse { swap(&fore, &back) }
                if square.ink.hidden { record.glyph = 0 }
                if square.ink.faint { fore = (fore & 0xFFFFFF00) | 0x80 }
                record.fore = fore
                record.back = back
                if square.ink.underline { record.flags |= 2 }
                if square.ink.strike { record.flags |= 4 }
                if square.wide { record.flags |= 1 }
                words[base + column] = record
            }
        }

        // The rects the mark pass draws: the gutter marks first, the
        // finds over them. A gutter mark is a sliver of the inset — a
        // failed command in red, a running one a wisp of the ink; a find
        // is the cell itself, the theme's selection, the current one held
        // harder.
        var stripes: [Rect] = []
        stripes.reserveCapacity(marks.count + finds.count + 1)
        let gutter = Swift.Float((TerminalDraw.inset - 1) / cell.width)
        let sliver = Swift.Float(2 / cell.width)
        for gutterMark in marks {
            stripes.append(Rect(
                place: SIMD4(gutter, Swift.Float(gutterMark.row), sliver, Swift.Float(gutterMark.span)),
                tint: gutterMark.failed
                    ? simd_float4(0.85, 0.19, 0.17, 0.9)
                    : simd_float4(theme.ink.x, theme.ink.y, theme.ink.z, 0.35)
            ))
        }
        for hit in finds {
            stripes.append(Rect(place: hit, tint: theme.select))
        }
        if let found {
            stripes.append(Rect(
                place: found,
                tint: simd_float4(theme.select.x, theme.select.y, theme.select.z, min(1, theme.select.w * 1.8))
            ))
        }
        rectCount = stripes.count
        if !stripes.isEmpty {
            if rects == nil || rects!.length < stripes.count * MemoryLayout<Rect>.stride {
                rects = device.makeBuffer(length: stripes.count * MemoryLayout<Rect>.stride, options: .storageModeShared)
            }
            if let rects {
                stripes.withUnsafeBytes { raw in
                    rects.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
                }
            }
        }
    }

    // MARK: - one frame

    /// Draws one frame, if there is a frame to draw. Only the view calls
    /// this, when something has changed — an idle terminal never does.
    func render() {
        guard cells != nil, layer.drawableSize.width > 0, layer.drawableSize.height > 0,
              let drawable = layer.nextDrawable(),
              let command = queue.makeCommandBuffer()
        else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        encode(pass, on: command)
        command.present(drawable)
        inFlight = command
        command.commit()
    }

    /// The previous frame's command buffer, still reading the atlas until
    /// it completes. A glyph cut (`slot`) must not rewrite the atlas while
    /// this is in flight or the GPU can read a half-written slot — the
    /// fragment glyphs that appear when frames are fast.
    private var inFlight: MTLCommandBuffer?

    /// Renders one frame into a fresh texture of its own instead of the
    /// layer's, and hands it back for reading. A presented drawable cannot
    /// be read after the fact, so a test that wants to know what the frame
    /// really painted goes through here.
    func snapshot() -> MTLTexture? {
        let width = Int(layer.drawableSize.width), height = Int(layer.drawableSize.height)
        guard width > 0, height > 0, cells != nil, let command = queue.makeCommandBuffer() else { return nil }
        let shape = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: layer.pixelFormat, width: width, height: height, mipmapped: false
        )
        shape.usage = [.renderTarget]
        guard let target = device.makeTexture(descriptor: shape) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        encode(pass, on: command)
        command.commit()
        command.waitUntilCompleted()
        return target
    }

    /// One frame's three instanced passes — background, marks, glyphs —
    /// written into whichever target the pass was handed.
    private func encode(_ pass: MTLRenderPassDescriptor, on command: MTLCommandBuffer) {
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
        encoder.setVertexBuffer(cells, offset: 0, index: 2)
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
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: span)
        encoder.endEncoding()
    }

    // MARK: - the colours

    /// The colours a theme paints cells with: the two of its own — ground
    /// and ink — and the sixteen ANSI ones. Everything the parser can say
    /// resolves to one of these; a truecolour is its own.
    @MainActor
    struct Theme {
        let ground: simd_float4
        let ink: simd_float4
        let select: simd_float4
        let ansi: [simd_float4]

        static func current() -> Theme {
            // Outside an app there is no NSApp to ask: light is the honest
            // default, and the app always asks with one in hand.
            let dark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let ground = dark
                ? simd_float4(0.11, 0.11, 0.113, 1.0)     // the same as Palette.NS.ground's dark
                : simd_float4(1.0, 1.0, 1.0, 1.0)
            let ink = dark ? simd_float4(0.93, 0.93, 0.93, 1.0) : simd_float4(0.09, 0.09, 0.09, 1.0)
            let select = dark ? simd_float4(0.30, 0.51, 0.83, 0.35) : simd_float4(0.22, 0.46, 0.85, 0.22)
            return Theme(ground: ground, ink: ink, select: select, ansi: dark ? darkANSI : lightANSI)
        }

        /// A paint, packed for the shader. Zero is the theme's own colour —
        /// the ink for words, no background for a cell without one.
        func fore(_ paint: Paint) -> UInt32 {
            switch paint {
            case .plain:
                return 0
            case .ansi(let index):
                guard index < 16, index < ansi.count else { return shade(index) }
                let colour = ansi[Int(index)]
                return pack(colour)
            case .rgb(let red, let green, let blue):
                return UInt32(red) | UInt32(green) << 8 | UInt32(blue) << 16 | 0xFF000000
            }
        }

        /// The ANSI colours past sixteen: the colour cube, then the grey ramp.
        private func shade(_ index: UInt8) -> UInt32 {
            let steps: [UInt32] = [0, 95, 135, 175, 215, 255]
            if index < 232 {
                let cube = Int(index) - 16
                let red = steps[cube / 36], green = steps[(cube / 6) % 6], blue = steps[cube % 6]
                return red | green << 8 | blue << 16 | 0xFF000000
            }
            let grey = UInt32(8 + 10 * (Int(index) - 232))
            return grey | grey << 8 | grey << 16 | 0xFF000000
        }

        private func pack(_ colour: simd_float4) -> UInt32 {
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

    // MARK: - the shaders

    /// The whole renderer in four instanced draws: one pass for the
    /// background a cell paints over the ground (selection and the cursor
    /// live here), one for the gutter marks and find highlights over it, one
    /// for the lines under and through struck words, and one for the glyphs,
    /// each a quad sampling the atlas.
    private static let shaders = """
    #include <metal_stdlib>
    using namespace metal;

    // One cell of the grid, as the CPU wrote it into the resident buffer.
    struct CellRecord {
        uint16_t glyph;
        uint16_t flags;
        uint32_t fore;
        uint32_t back;
        uint32_t spare;
    };

    // One rect of the mark pass, as the CPU wrote it: a place in cells —
    // column, row, cells wide, cells tall, the gutter reaching outside —
    // and its colour.
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
        uint fill;
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
    };

    static constant float2 corners[4] = {
        float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 1)
    };

    static float4 unpack(uint32_t word) {
        return float4(
            float(word & 255u) / 255.0,
            float((word >> 8) & 255u) / 255.0,
            float((word >> 16) & 255u) / 255.0,
            float(word >> 24) / 255.0
        );
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
        if (c.back == 0u && !under && !held) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            return out;
        }
        float4 colour = c.back == 0u ? f.ground : unpack(c.back);
        if (held) {
            colour = float4(mix(colour.rgb, f.select.rgb, f.select.a), colour.a);
        }
        if (under) {
            // A block cursor is the ink itself; a window that has lost the
            // keyboard gets half of one, mixed toward the ground.
            colour = f.cursor.w > 0.5 ? f.ink : mix(f.ground, f.ink, 0.5);
        }
        float2 point = f.origin + float2(col, row) * f.cell + corners[vid] * f.cell;
        out.place = toClip(point, f.drawable);
        out.tint = colour;
        return out;
    }

    // The mark pass: one quad per rect — a command block's gutter mark,
    // a find's highlight — over the background, under the glyphs.
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

    // The lines a cell can wear: under it, or through it.
    vertex FlatOut decorationVertex(
        uint vid [[vertex_id]], uint iid [[instance_id]],
        constant Frame& f [[buffer(1)]], const device CellRecord* cells [[buffer(2)]]
    ) {
        FlatOut out;
        CellRecord c = cells[iid];
        uint col = iid % f.grid.x;
        uint row = iid / f.grid.x;
        float high = (c.flags & 2u) != 0u ? max(f.cell.y * 0.09, 1.0)
                  : (c.flags & 4u) != 0u ? max(f.cell.y * 0.06, 1.0)
                  : 0.0;
        if (high == 0.0) {
            out.place = float4(-2.0, -2.0, 0.0, 1.0);
            out.tint = float4(0.0);
            return out;
        }
        bool wide = (c.flags & 1u) != 0u;
        float2 point = f.origin + float2(col, row) * f.cell;
        point.y += (c.flags & 2u) != 0u ? f.cell.y - high : (f.cell.y - high) * 0.5;
        point += corners[vid] * float2(wide ? 2.0 * f.cell.x : f.cell.x, high);
        out.place = toClip(point, f.drawable);
        out.tint = c.fore == 0u ? f.ink : unpack(c.fore);
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
        if (c.glyph == 0u) {
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
        out.tint = underCursor(col, row, f) ? f.ground : (c.fore == 0u ? f.ink : unpack(c.fore));
        out.place = toClip(point, f.drawable);
        return out;
    }

    fragment float4 flatFragment(FlatOut in [[stage_in]]) {
        return in.tint;
    }

    fragment float4 glyphFragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
        constexpr sampler pick(mag_filter::nearest, min_filter::nearest);
        float cover = atlas.sample(pick, in.uv).r;
        if (cover <= 0.004) { discard_fragment(); }
        return float4(in.tint.rgb, in.tint.a * cover);
    }
    """
}
