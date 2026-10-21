import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal

// The glyph atlas: one R8 square on the GPU holding the coverage of every
// character this terminal has been asked to draw, and the bookkeeping of
// which square of it holds what.
//
// A glyph the atlas has never held is *reserved* — its slot is chosen and
// its number handed back at once — and cut on a queue of its own. The frame
// that asked for it draws nothing where it will be, and the frames after it
// have it. That is the whole of the arrangement, and it is what a frame no
// longer waits for: cutting a glyph is CoreText work on the CPU, and the
// atlas cannot be written while the GPU is reading it, so doing either in
// the middle of a frame is a stall — a stall a program used to make this
// terminal pay, every time it printed a character that had not been printed
// before. 2048 square is room for every printable ASCII character in four
// styles several times over, so a session that is not full of ideographs
// never comes near filling it.
//
// The atlas is `.storageModePrivate`, which means a blit writes it rather
// than the CPU. The blit goes into the same command buffer as the frame that
// needs the glyph and ahead of that frame's draws, so Metal orders the two —
// again, not a wait. A cut therefore comes back as bytes (see `Cut`) and
// whoever encodes the frame turns them into a buffer and blits them in.
//
// What turns the generation over: a different face, a different scale, or a
// cell that measures differently. Any of them leaves every slot in the atlas
// holding something else, so the atlas is replaced and the slots are handed
// out again as frames ask for them. A cut carries the generation it was cut
// for, and one from a generation that has gone is let go.

/// What a glyph is asked for by: the character and the way it is set, as a
/// number. A number rather than a string because a frame asks for every
/// square it draws — a `cat` of a long file asks tens of thousands of times a
/// second, and building a string for each of them was most of what that cost.
struct GlyphKey: Hashable {
    var word: UInt64
    var style: UInt8          // 1 bold, 2 italic, 4 wide

    /// The key for a character: its one scalar exactly, or the scalars of a
    /// cluster as a hash. The top byte says which — set for a scalar, clear
    /// for a hash — so a cluster can never be read as the scalar whose low
    /// bits it happens to share.
    static func of(_ char: Character, bold: Bool, italic: Bool, wide: Bool) -> GlyphKey {
        let style: UInt8 = (bold ? 1 : 0) | (italic ? 2 : 0) | (wide ? 4 : 0)
        // The overwhelming majority of squares are ASCII, and `asciiValue`
        // answers for them without walking anything.
        if let ascii = char.asciiValue {
            return GlyphKey(word: (1 << 56) | UInt64(ascii), style: style)
        }
        let scalars = char.unicodeScalars
        let start = scalars.startIndex
        if scalars.index(after: start) == scalars.endIndex {
            return GlyphKey(word: (1 << 56) | UInt64(scalars[start].value), style: style)
        }
        // FNV-1a over the scalars of the cluster: a base character with a
        // combining mark, a variation selector, a zero-width joiner and
        // whatever it joins.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in scalars {
            hash = (hash ^ UInt64(scalar.value)) &* 0x0000_0100_0000_01b3
        }
        return GlyphKey(word: hash & 0x00FF_FFFF_FFFF_FFFF, style: style)
    }
}

/// One glyph that has been cut and not yet put in the atlas: its coverage,
/// and the slot it belongs in.
struct GlyphCut {
    /// The slot's own index, not the number a record carries — that is this
    /// plus one, zero meaning nothing to draw.
    var seat: Int
    var across: Int
    var down: Int
    var bytes: [UInt8]
    /// Whether this is a colour glyph — an emoji, drawn with the colours
    /// it comes in rather than as coverage to be tinted — and so belongs
    /// in the colour atlas rather than the coverage one.
    var colour = false
    /// The generation it was cut for. A cut of any other is not this
    /// atlas's and is let go where it is found.
    var generation: UInt64
}

@MainActor
final class GlyphAtlas {
    /// The atlas is a square of squares: one glyph per slot, whole rows of
    /// slots, so that a wide glyph can take the pair it spans.
    static let side = 2048

    /// The glyphs in the atlas, as the shaders read it.
    private(set) var texture: MTLTexture
    /// The colour glyphs — emoji and the like, whose own colours are part
    /// of the drawing rather than a tint over coverage. Made the first
    /// time one is asked for, so a terminal that never prints an emoji
    /// never pays for the room; the same slots, the same side, RGBA
    /// instead of one channel.
    private(set) var colourTexture: MTLTexture?
    /// One slot, in device pixels, and how many of them fit across.
    private(set) var across = 1
    private(set) var down = 1
    private(set) var slotsPerRow = 1

    /// How many glyphs may be waiting to be cut before this atlas declines to
    /// take on more. A program printing a page of a language the terminal has
    /// never seen is the case: the frames that follow ask again for anything
    /// that was declined, so nothing is lost by it.
    private static let backlog = 4096
    /// How many cuts one frame will blit. Bounded so that the same page
    /// cannot spend a frame's whole budget on them; the rest wait for the
    /// frames after, which is a frame or two at worst. Not private: the test
    /// that pins that arrangement counts in the same number.
    static let perFrame = 512
    /// What a slot holds that no glyph has been cut into. A private texture
    /// does not come zeroed — measured, a square nobody had written to read
    /// as noise, and drew as noise — so an atlas that has just been made is
    /// emptied rather than assumed empty, and a slot a frame has named
    /// before its glyph was cut draws nothing at all.
    private static let nothing = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

    private let device: MTLDevice
    /// Where glyphs are cut: serial, and at a priority above the frame's own
    /// — a glyph that is late is a blank square on the screen.
    private let work: DispatchQueue
    private let box = Landed()

    /// Which slot each glyph that has been asked for is in, and where the
    /// next free slot is.
    private var given: [GlyphKey: UInt16] = [:]
    private var next = 0

    /// What the atlas is cut at now, and the four faces that style is set in
    /// — plain, bold, italic, bold italic — resolved on this thread when the
    /// generation turned over. `NSFontManager` is not a thing to call from
    /// the cutting queue; CoreText, which is what cuts, is.
    private var generation: UInt64 = 0
    private var scale: CGFloat = 0
    private var cell = CGSize(width: 1, height: 1)
    private var font: NSFont?
    private var faces: [NSFont] = []
    /// Whether the atlas in `texture` still has to be emptied before a frame
    /// may read it. True of a texture the moment it is made, and of every
    /// one after it.
    private var wiping = true
    /// The same, for the colour atlas, which is made on demand.
    private var colourWiping = true

    /// Called on the main thread when a glyph has landed. Whoever draws sets
    /// it to ask for a frame: a slot this frame named and had no coverage
    /// for is a blank square on the screen, and a terminal that is otherwise
    /// idle has nothing else to ask with.
    var onLanded: (() -> Void)?

    init?(device: MTLDevice) {
        // The atlas's shape — format, size, storage mode, usage — is stated
        // once, in `make`, which is also what a turnover goes through.
        guard let made = GlyphAtlas.make(device) else { return nil }
        self.device = device
        texture = made
        work = DispatchQueue(label: "terminal.atlas", qos: .userInitiated)
        box.arrived = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.landed() }
            }
        }
    }

    private func landed() {
        onLanded?()
    }

    // MARK: - what the next frame is cut at

    /// Says what the next frame is drawn at, and turns the generation over if
    /// that is not what the last frame was drawn at.
    ///
    /// `beforeRetiring` is called when the atlas in hand is about to be
    /// replaced, and must not return until nothing can still be reading it:
    /// the frames that could be are the renderer's to know, and this happens
    /// once per face rather than once a frame.
    func begin(scale: CGFloat, cell: CGSize, font: NSFont, beforeRetiring: () -> Void) {
        let first = generation == 0
        guard first || scale != self.scale || cell != self.cell || font != self.font else { return }
        if !first { beforeRetiring() }
        self.scale = scale
        self.cell = cell
        self.font = font
        faces = GlyphAtlas.faces(font, scale: scale)
        across = max(1, Int((cell.width * scale).rounded(.up)))
        down = max(1, Int((cell.height * scale).rounded(.up)))
        slotsPerRow = max(1, GlyphAtlas.side / across)
        next = 0
        given.removeAll(keepingCapacity: true)
        generation &+= 1
        if !first {
            guard let fresh = GlyphAtlas.make(device) else { return }
            texture = fresh
            // The colour atlas went with the old generation too; the next
            // emoji asked for makes a fresh one.
            colourTexture = nil
            colourWiping = true
            // Nothing has been cut into it and nothing is in it: the frames
            // that name a slot from here until the prewarm below lands read
            // it as empty because `wipe` writes the emptiness, not because
            // a fresh private texture is empty (it is not — see `nothing`).
            wiping = true
        }
        prewarm()
    }

    /// The atlas's one shape. Written by a blit and by the clear that
    /// empties a new atlas, read by the glyph pass, and by nothing else: no
    /// CPU access to it at all, which is the point — and why a glyph can be
    /// cut on another thread and still arrive in the frame that asked for
    /// it.
    private static func make(_ device: MTLDevice, format: MTLPixelFormat = .r8Unorm) -> MTLTexture? {
        let shape = MTLTextureDescriptor()
        shape.textureType = .type2D
        shape.pixelFormat = format
        shape.width = side
        shape.height = side
        shape.storageMode = .private
        shape.usage = [.shaderRead, .renderTarget]
        return device.makeTexture(descriptor: shape)
    }

    // MARK: - asking for a glyph

    /// Whether a character is drawn in colour: the emoji Apple's colour
    /// face draws, and the sequences that ask for emoji presentation. A
    /// text symbol that has a monochrome form is left as text unless its
    /// variation selector asks otherwise.
    nonisolated static func isColour(_ char: Character) -> Bool {
        let scalars = char.unicodeScalars
        if scalars.contains(where: { $0.value == 0xFE0F }) { return true }
        guard let first = scalars.first else { return false }
        switch first.value {
        case 0x1F000...0x1FAFF, 0x1FC00...0x1FFFF:
            return true
        default:
            return false
        }
    }

    /// The slot a glyph is drawn from — its number in the atlas plus one,
    /// zero for nothing to draw — reserving it and having it cut if this is
    /// the first frame to ask for it. The frames until the cut lands draw
    /// nothing in that square; the frames after it have the glyph.
    func slot(_ char: Character, bold: Bool, italic: Bool, wide: Bool) -> UInt16 {
        let key = GlyphKey.of(char, bold: bold, italic: italic, wide: wide)
        if let had = given[key] { return had }
        guard box.busy < GlyphAtlas.backlog, let seat = reserve(wide: key.style & 4 != 0) else { return 0 }
        given[key] = UInt16(seat + 1)
        let colour = GlyphAtlas.isColour(char)
        if colour, colourTexture == nil {
            colourTexture = GlyphAtlas.make(device, format: .rgba8Unorm)
            colourWiping = true
        }
        let job = Job(
            char: char, face: faces[Int(key.style & 3)],
            seat: seat, across: (key.style & 4 != 0 ? 2 : 1) * across, down: down,
            colour: colour, generation: generation, box: box
        )
        box.start()
        work.async { job.run() }
        return UInt16(seat + 1)
    }

    /// Where the next slot comes from. A wide character takes the pair of
    /// slots it spans, which is why the atlas keeps whole rows of them.
    private func reserve(wide: Bool) -> Int? {
        let total = slotsPerRow * (GlyphAtlas.side / down)
        if wide {
            if next % slotsPerRow + 1 >= slotsPerRow { next = (next / slotsPerRow + 1) * slotsPerRow }
            guard next + 1 < total else { return nil }
            let seat = next
            next += 2
            return seat
        }
        guard next < total else { return nil }
        let seat = next
        next += 1
        return seat
    }

    // MARK: - what has landed

    /// Empties an atlas that has just been made, ahead of the passes of the
    /// frame that will read it. A private texture comes with whatever was in
    /// that memory when it was handed over — measured here, noise — and a
    /// frame names a slot the moment it asks for a glyph, so a square whose
    /// glyph is still being cut is read by the very frame that asked. The
    /// emptiness is therefore written rather than assumed: a render pass
    /// that clears the whole atlas and draws nothing into it, once per
    /// atlas. Without it, the frame between an ask and its answer shows the
    /// noise in that square instead of nothing.
    ///
    /// Does nothing when the atlas in hand has already been emptied, so a
    /// frame may call it whenever.
    func wipe(on command: MTLCommandBuffer) {
        if wiping {
            wiping = false
            clear(texture, on: command)
        }
        if colourWiping, let colourTexture {
            colourWiping = false
            clear(colourTexture, on: command)
        }
    }

    private func clear(_ texture: MTLTexture, on command: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = GlyphAtlas.nothing
        pass.colorAttachments[0].storeAction = .store
        command.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
    }

    /// Empties the atlas if it has just been made, then puts every glyph
    /// that has been cut since the last time this was asked into it, ahead
    /// of the passes of the frame that is being encoded into the same
    /// command buffer. Metal runs a command buffer's encoders in the order
    /// they were made, so the glyphs are in the atlas before the pass that
    /// reads it — which is the whole of why a frame can be drawn while
    /// glyphs are still being cut, and why nothing here ever waits for the
    /// GPU to go quiet.
    ///
    /// Every cut it is handed was cut for this atlas: one from a generation
    /// that has gone is let go where it is taken (see `Landed.take`), which
    /// is what makes the slot arithmetic below the atlas's own.
    func land(on command: MTLCommandBuffer) {
        wipe(on: command)
        let cuts = drain()
        // One buffer for the frame's worth, with each glyph at its own
        // offset in it, rather than one buffer a glyph: a page of a
        // language the atlas has not seen is up to `perFrame` of them, and
        // each would be a driver allocation made and dropped mid-frame.
        let room = cuts.reduce(0) { $0 + $1.bytes.count }
        guard room > 0, let blit = command.makeBlitCommandEncoder(),
              let staging = device.makeBuffer(length: room, options: .storageModeShared)
        else { return }
        var at = 0
        for cut in cuts {
            let start = at
            at += cut.bytes.count
            let stride = cut.across * (cut.colour ? 4 : 1)
            guard let target = cut.colour ? colourTexture : texture else { continue }

            cut.bytes.withUnsafeBytes { bytes in
                staging.contents().advanced(by: start).copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
            blit.copy(
                from: staging, sourceOffset: start,
                sourceBytesPerRow: stride, sourceBytesPerImage: stride * cut.down,
                sourceSize: MTLSize(width: cut.across, height: cut.down, depth: 1),
                to: target, destinationSlice: 0, destinationLevel: 0,
                // The slot's own width, not the cut's: a wide glyph is two
                // slots wide but still starts at the first of them.
                destinationOrigin: MTLOrigin(
                    x: cut.seat % slotsPerRow * across,
                    y: cut.seat / slotsPerRow * down,
                    z: 0
                )
            )
        }
        blit.endEncoding()
    }

    /// Up to a frame's worth of the glyphs cut since the last time it was
    /// asked, oldest first, as bytes to blit into the atlas.
    func drain() -> [GlyphCut] {
        box.take(GlyphAtlas.perFrame, keeping: generation)
    }

    /// Waits until every glyph that has been asked for has been cut, and
    /// leaves them where they are for the frame to pick up. What a test
    /// wants — a frame that has settled rather than one drawn mid-cut — and
    /// not what a frame wants, since a frame that waits is the stall this
    /// whole arrangement exists to remove.
    func settle() {
        work.sync {}
    }

    // MARK: - cutting

    /// Reserves and cuts what every terminal is asked for sooner or later:
    /// the printable ASCII set — a prompt, a line of output, a path — in each
    /// of the four ways a style is set, on this thread rather than on the
    /// cutting queue. This is the one case where arriving late is visible: a
    /// frame drawn a moment after the face changed would have no coverage for
    /// the words already on the screen and would show them blank until the
    /// cuts landed. It measures about 6 ms for the 376 of them at the size a
    /// retina terminal is drawn at, paid once per face and once per scale,
    /// and never again for that face — a frame dropped at the moment a
    /// font is changed, against every letter on the screen blinking out.
    private func prewarm() {
        for value in UInt8(0x21)...UInt8(0x7E) {
            let char = Character(UnicodeScalar(value))
            for style in UInt8(0)..<4 {
                let key = GlyphKey(word: (1 << 56) | UInt64(value), style: style)
                guard given[key] == nil, let seat = reserve(wide: false) else { continue }
                given[key] = UInt16(seat + 1)
                if let cut = GlyphAtlas.cut(
                    char, face: faces[Int(style)], seat: seat, across: across, down: down,
                    colour: false, generation: generation
                ) {
                    box.put(cut)
                }
            }
        }
    }

    /// How much a glyph has to be shrunk to sit whole in its slot: 1 when
    /// it already does, which is every letter of ordinary text, and less
    /// when its ink runs past the advance the cell was cut from — the way
    /// the drawings in a patched icon face do. Kept apart from the drawing
    /// so the arithmetic can be pinned without a font that has one.
    nonisolated static func fit(_ ink: CGRect, in slot: CGSize) -> CGFloat {
        guard ink.width > 0, ink.height > 0, slot.width > 0, slot.height > 0 else { return 1 }
        return min(1, min(slot.width / ink.width, slot.height / ink.height))
    }

    /// One glyph, cut: the coverage of a character in an R8 square, white on
    /// black, drawn by CoreText on the baseline the cell's height was
    /// measured from. Nothing but its arguments is read — which is what lets
    /// it run on the cutting queue, and what the two callers of it share:
    /// the prewarm, here, and `Job`, on the queue.
    fileprivate nonisolated static func cut(
        _ char: Character, face: NSFont, seat: Int, across: Int, down: Int, colour: Bool,
        generation: UInt64
    ) -> GlyphCut? {
        guard across > 0, down > 0 else { return nil }
        // A colour glyph carries its own RGBA; a coverage glyph is one
        // channel, tinted by the frame the way every letter is.
        var bytes = [UInt8](repeating: 0, count: across * down * (colour ? 4 : 1))
        let marked = NSAttributedString(string: String(char), attributes: [
            .font: face,
            // A colour rather than an `NSColor`: this runs off the main
            // thread, and a CGColor is the whole of what CoreText wants.
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(marked)
        let space = colour ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
        let info = colour
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.none.rawValue
        // The baseline: the descent above the bitmap's floor, plus half the
        // leading — the same room the cell's height was measured from.
        let rise = -face.descender + (CGFloat(down) - face.ascender + face.descender) / 2
        // A glyph whose ink is wider or taller than the square it has been
        // given — an icon from a Nerd Font, whose drawings run past the
        // advance the cell was measured from — is shrunk to fit whole. Left
        // at its own size it is cut off at the slot's edge, which for those
        // glyphs is half an icon and a square of nothing where the rest was.
        let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        let fit = GlyphAtlas.fit(ink, in: CGSize(width: across, height: down))
        // A glyph a hair over its square stays where the baseline put it:
        // shrinking and centring for half a pixel would move ordinary
        // letters against the ones beside them, an italic's overhang most
        // of all. An icon that overruns by half is another thing.
        let whole = fit < 0.9
        bytes.withUnsafeMutableBytes { raw in
            guard let page = CGContext(
                data: raw.baseAddress, width: across, height: down,
                bitsPerComponent: 8, bytesPerRow: across * (colour ? 4 : 1),
                space: space, bitmapInfo: info
            ) else { return }
            if whole {
                page.saveGState()
                page.scaleBy(x: fit, y: fit)
                page.textPosition = CGPoint(
                    x: (CGFloat(across) / fit - ink.width) / 2 - ink.minX,
                    y: (CGFloat(down) / fit - ink.height) / 2 - ink.minY
                )
                CTLineDraw(line, page)
                page.restoreGState()
            } else {
                page.textPosition = CGPoint(x: 0, y: rise)
                CTLineDraw(line, page)
            }
        }
        return GlyphCut(
            seat: seat, across: across, down: down, bytes: bytes,
            colour: colour, generation: generation
        )
    }

    /// The four ways a style is set, at the scale the atlas is cut at. On
    /// this thread, because `NSFontManager` is not a thing to call from
    /// anywhere else — which is why the faces are resolved once per
    /// generation and the cutting queue is handed the answer.
    private static func faces(_ font: NSFont, scale: CGFloat) -> [NSFont] {
        (0..<4).map { style in
            var face = font
            var traits: NSFontTraitMask = []
            if style & 1 != 0 { traits.insert(.boldFontMask) }
            if style & 2 != 0 { traits.insert(.italicFontMask) }
            if !traits.isEmpty { face = NSFontManager.shared.convert(font, toHaveTrait: traits) }
            return NSFontManager.shared.convert(face, toSize: face.pointSize * scale)
        }
    }
}

/// One glyph to cut on the queue, and where to leave it when it is cut. A
/// class, and `@unchecked`, because it is handed to another thread: the face
/// in it is immutable and was resolved on this one, the job is read once and
/// never looked at again, and nothing else in the atlas refers to any of it.
private final class Job: @unchecked Sendable {
    private let char: Character
    private let face: NSFont
    private let seat: Int
    private let across: Int
    private let down: Int
    private let colour: Bool
    private let generation: UInt64
    private let box: Landed

    init(
        char: Character, face: NSFont, seat: Int, across: Int, down: Int,
        colour: Bool, generation: UInt64, box: Landed
    ) {
        self.char = char
        self.face = face
        self.seat = seat
        self.across = across
        self.down = down
        self.colour = colour
        self.generation = generation
        self.box = box
    }

    func run() {
        box.finish(GlyphAtlas.cut(
            char, face: face, seat: seat, across: across, down: down,
            colour: colour, generation: generation
        ))
    }
}

/// What the cutting queue leaves for whoever draws, and what it says about
/// how much is still being cut. The two threads that touch it are not the
/// same thread, so there is a lock; nothing else about the atlas is shared.
private final class Landed: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [GlyphCut] = []
    private var working = 0
    /// Whether whoever draws has already been told there is something here.
    /// Cleared by `take` once it has collected everything, so that the next
    /// cut is news again.
    private var told = false

    /// Called, on whichever thread cut the glyph, when one arrives.
    var arrived: (@Sendable () -> Void)?

    /// How many glyphs are being cut right now.
    var busy: Int {
        lock.lock()
        defer { lock.unlock() }
        return working
    }

    /// A glyph has been handed to the cutting queue, so that what is in
    /// there can be counted before the answer is.
    func start() {
        lock.lock()
        working += 1
        lock.unlock()
    }

    /// A cut is in — or came to nothing, which is also an answer and also
    /// has to be counted. Whoever draws hears about it once a frame's worth
    /// rather than once a glyph: a page of a language the atlas has not
    /// seen arrives as hundreds of cuts, and the frame that is asked for
    /// picks up everything waiting when it is drawn (see `take`).
    func finish(_ cut: GlyphCut?) {
        lock.lock()
        working -= 1
        if let cut { ready.append(cut) }
        // A cut that came to nothing is not news, and does not make what is
        // already here news again either — the frame that was told about
        // those cuts still has them to collect.
        let tell = cut != nil && !told
        if tell { told = true }
        lock.unlock()
        if tell { arrived?() }
    }

    /// A cut that was made on the drawing thread itself, so that there is
    /// nothing to hand across and nothing to count.
    func put(_ cut: GlyphCut) {
        lock.lock()
        ready.append(cut)
        lock.unlock()
    }

    /// Up to `limit` of the cuts of one generation, oldest first. A cut of
    /// any other generation is let go here: the atlas it was cut for has
    /// been replaced, and its slot means something else now.
    func take(_ limit: Int, keeping generation: UInt64) -> [GlyphCut] {
        lock.lock()
        var out: [GlyphCut] = []
        var kept: [GlyphCut] = []
        for cut in ready where cut.generation == generation {
            if out.count < limit { out.append(cut) } else { kept.append(cut) }
        }
        ready = kept
        // What the frame's limit left behind is still news, and this is what
        // says so: a burst larger than one frame's blit is asked for again,
        // so it arrives over two frames rather than waiting for some third
        // reason to draw. Anything else is quiet until the next cut.
        let more = !kept.isEmpty
        told = more
        lock.unlock()
        if more { arrived?() }
        return out
    }
}
