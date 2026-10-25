import AppKit

/// An image pasted into the chat, made small enough to be worth sending.
///
/// Ported in spirit from orbit-pi's `attachments.rs`, and for the same
/// reason: a screenshot is megabytes as a PNG, and once a prompt carries it
/// those bytes ride every later turn of the session. So the image is
/// bounded **before** it goes anywhere, not after it is already costing
/// something.
///
/// What an agent can do with an image is read a file — that is the whole of
/// its channel, and it is the same channel everything else in this view
/// uses. So a pasted image becomes a file on disk and a path in the line,
/// which the agent's own Read tool already understands. Nothing about the
/// terminal, the pty, or the agent's own rules is special-cased.
///
/// The policy, in the same numbers orbit-pi uses because they are pi's own
/// documented limits:
///
/// - the longest edge is capped at 1400 px, and a smaller image is never
///   upscaled;
/// - an image already inside both bounds is written out untouched, so a
///   JPEG keeps its own quality and its EXIF orientation;
/// - an image with transparency stays lossless (PNG here; orbit-pi picks
///   WebP, which AppKit cannot write — the resize is what bounds it);
/// - an opaque image becomes JPEG, stepping the quality down until it fits.
///
/// A format we cannot rewrite safely — an animated GIF, an SVG, a TIFF —
/// is written out unchanged rather than silently losing frames or
/// fidelity. A failed encode falls back to the source bytes for the same
/// reason: an attachment that cannot be made small is still better than an
/// attachment that vanished.
enum Attach {
    /// Longest edge kept.
    static let maxEdge = 1400
    /// Cap on the encoded payload — the shape a provider is charged for.
    static let maxBytes = 512 * 1024
    /// JPEG starts here and steps down toward `leastQuality` to fit.
    static let quality = 0.75
    static let leastQuality = 0.40
    static let qualityStep = 0.05

    /// What came out the other side.
    struct Prepared: Equatable {
        /// The bytes to write.
        let data: Data
        /// The extension the bytes belong in, without the dot.
        let suffix: String
        /// The size it ended at.
        let size: NSSize
        /// Whether anything was given up for it.
        let resized: Bool
        /// How big the source was, so the view can say what it saved.
        let sourceBytes: Int

        /// "1204×832 · 96 KB" — the one line worth saying about it.
        var saying: String {
            let kb = max(1, data.count / 1024)
            return "\(Int(size.width))×\(Int(size.height)) · \(kb) KB"
        }
    }

    /// Scale `size` down to fit inside `maxEdge`, keeping its shape. Never
    /// up: a small image is already fine, and stretching it would spend
    /// bytes on pixels that were never there.
    static func fit(_ size: NSSize, maxEdge: Int = maxEdge) -> NSSize {
        let longest = max(size.width, size.height)
        guard longest > CGFloat(maxEdge), longest > 0 else { return size }
        let scale = CGFloat(maxEdge) / longest
        return NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Base64 length of a payload — what a provider is actually billed in,
    /// which is a third larger than the file.
    static func base64Length(_ bytes: Int) -> Int { (bytes + 2) / 3 * 4 }

    /// Prepare an image for a prompt. Never fails: an image that cannot be
    /// decoded or re-encoded passes through as the bytes it came as.
    static func prepare(_ image: NSImage, source: Data? = nil) -> Prepared? {
        let sourceBytes = source?.count ?? 0
        let pixels = image.representations.compactMap { rep -> NSSize? in
            guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }.max { $0.width * $0.height < $1.width * $1.height } ?? image.size
        guard pixels.width >= 1, pixels.height >= 1 else { return nil }

        let target = fit(pixels)
        let within = target == pixels && base64Length(sourceBytes) <= maxBytes
        // Already inside both bounds: the exact bytes, at the exact
        // quality, are the best possible answer and cost nothing to give.
        if within, let source, !source.isEmpty {
            return Prepared(data: source, suffix: suffix(of: source) ?? "png", size: pixels,
                            resized: false, sourceBytes: sourceBytes)
        }

        let alpha = hasAlpha(image)
        guard let redrawn = redraw(image, to: target) else {
            if let source, !source.isEmpty {
                return Prepared(data: source, suffix: suffix(of: source) ?? "png", size: pixels,
                                resized: false, sourceBytes: sourceBytes)
            }
            return nil
        }
        let resized = target != pixels

        if alpha {
            // Transparency survives only losslessly, and a resized PNG is
            // already bounded by the edge cap above.
            guard let png = redrawn.representation(using: .png, properties: [:]) else {
                return fallback(image, source, pixels, sourceBytes)
            }
            return Prepared(data: png, suffix: "png", size: target,
                            resized: resized || base64Length(png.count) > maxBytes,
                            sourceBytes: sourceBytes)
        }
        return jpeg(redrawn, target, resized, sourceBytes) ?? fallback(image, source, pixels, sourceBytes)
    }

    /// Opaque pixels, JPEG, quality stepped down until it fits. The edge
    /// cap has already been applied, so this loop is bounded: the worst
    /// case is the least quality, which is still a readable picture.
    private static func jpeg(_ rep: NSBitmapImageRep, _ size: NSSize, _ resized: Bool,
                             _ sourceBytes: Int) -> Prepared? {
        var quality = quality
        var best: Prepared?
        while quality >= leastQuality - 0.001 {
            guard let data = rep.representation(
                using: .jpeg, properties: [.compressionFactor: quality]
            ) else { return nil }
            best = Prepared(data: data, suffix: "jpg", size: size,
                            resized: resized || base64Length(data.count) > maxBytes,
                            sourceBytes: sourceBytes)
            if base64Length(data.count) <= maxBytes { return best }
            quality -= qualityStep
        }
        return best
    }

    private static func fallback(_ image: NSImage, _ source: Data?, _ size: NSSize,
                                 _ sourceBytes: Int) -> Prepared? {
        guard let source, !source.isEmpty else { return nil }
        return Prepared(data: source, suffix: suffix(of: source) ?? "png", size: size,
                        resized: false, sourceBytes: sourceBytes)
    }

    /// Whether the image has any pixel that is not fully opaque. Checked on
    /// one downsampled pass rather than per pixel: a 1400 px image has two
    /// million of them, and this only has to answer yes or no.
    static func hasAlpha(_ image: NSImage) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return false }
        if rep.hasAlpha && rep.bitsPerPixel % 4 != 0 { return true }
        guard rep.hasAlpha else { return false }
        let wide = rep.pixelsWide
        let tall = rep.pixelsHigh
        guard wide > 0, tall > 0 else { return false }
        let stepX = max(1, wide / 60)
        let stepY = max(1, tall / 60)
        for y in stride(from: 0, to: tall, by: stepY) {
            for x in stride(from: 0, to: wide, by: stepX) {
                guard let pixel = rep.colorAt(x: x, y: y) else { continue }
                if pixel.alphaComponent < 0.99 { return true }
            }
        }
        return false
    }

    /// Draw the image into a rep of the target size, so the bytes that come
    /// out are the bytes that were asked for. `NSImage.draw(in:)` is used
    /// rather than asking a rep to `setSize`, which changes how the rep is
    /// *described* and not what it holds — the trap that makes a "resized"
    /// image arrive at the provider at full size.
    private static func redraw(_ image: NSImage, to size: NSSize) -> NSBitmapImageRep? {
        let wide = Int(size.width)
        let tall = Int(size.height)
        guard wide >= 1, tall >= 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: wide, pixelsHigh: tall,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// The suffix the bytes themselves ask for. Read off the file's own
    /// first bytes rather than kept beside it: the extension is what the
    /// agent's Read tool goes by, so it has to describe the bytes that are
    /// actually in the file.
    static func suffix(of data: Data) -> String? {
        let head = [UInt8](data.prefix(12))
        func isAt(_ at: Int, _ bytes: [UInt8]) -> Bool {
            guard head.count >= at + bytes.count else { return false }
            return Array(head[at..<(at + bytes.count)]) == bytes
        }
        if isAt(0, [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if isAt(0, [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if isAt(0, [0x47, 0x49, 0x46, 0x38]) { return "gif" }
        if isAt(0, [0x42, 0x4D]) { return "bmp" }
        if isAt(0, [0x49, 0x49, 0x2A, 0x00]) || isAt(0, [0x4D, 0x4D, 0x00, 0x2A]) { return "tiff" }
        if isAt(4, [0x66, 0x74, 0x79, 0x70]) { return "heic" }
        if isAt(0, [0x3C, 0x3F, 0x78, 0x6D]) || isAt(0, [0x3C, 0x73, 0x76, 0x67]) { return "svg" }
        return nil
    }

    /// Where an attached image lives until somebody deletes it. Beside the
    /// app's other caches, one file per attachment, named for when it
    /// arrived: a person looking in the folder a week later should be able
    /// to tell them apart.
    static var folder: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Search/attachments", isDirectory: true)
    }

    /// Write a prepared image into the cache and answer its path — the
    /// thing the composer puts in the line and the agent's Read tool opens.
    static func write(_ prepared: Prepared, at when: Date = Date()) -> URL? {
        let folder = self.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate,
                               .withColonSeparatorInTime]
        let name = "shot-\(stamp.string(from: when).replacingOccurrences(of: ":", with: ""))"
            + "-\(UInt32.random(in: 0..<UInt32.max)).\(prepared.suffix)"
        let url = folder.appendingPathComponent(name)
        do {
            try prepared.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The whole act: an image off the pasteboard becomes a path a line can
    /// carry. Nil when there was nothing to attach.
    static func attach(_ image: NSImage, source: Data? = nil) -> (url: URL, prepared: Prepared)? {
        guard let prepared = prepare(image, source: source), let url = write(prepared) else {
            return nil
        }
        return (url, prepared)
    }

    /// The image a drag is carrying, if it is carrying one. A drop can
    /// arrive as image bytes or as a file that is an image; both are the
    /// same act here, so both answer the same shape.
    static func dragged(_ board: NSPasteboard) -> (NSImage, Data)? {
        onPasteboard(board)
    }

    /// The image on the pasteboard, if there is one — the three shapes
    /// pasteboards actually carry, in the order they are most likely.
    static func onPasteboard(_ board: NSPasteboard = .general) -> (NSImage, Data)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = board.data(forType: type), let image = NSImage(data: data) else {
                continue
            }
            return (image, data)
        }
        // A file that *is* an image, dragged or copied in as a URL.
        guard let urls = board.readObjects(forClasses: [NSURL.self],
                                           options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return nil }
        for url in urls {
            guard let image = NSImage(contentsOf: url) else { continue }
            return (image, (try? Data(contentsOf: url)) ?? Data())
        }
        return nil
    }
}
