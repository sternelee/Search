import XCTest
@testable import Search

/// What a frame really painted, read back from the GPU. The layer's own
/// drawables cannot be read after they are presented, so the renderer draws
/// the same frame into a texture of its own and the test reads that —
/// the only honest way to know a glyph landed where a cell said one should.
@MainActor
final class TerminalRenderTests: XCTestCase {
    /// A scene of plain words, drawn at a scale of two, paints words: pixels
    /// well off the ground, enough of them to be letters and not specks.
    func testWordsPaintFarOffTheGround() throws {
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        var line = Row(width: 10)
        for (column, letter) in "Metal!".enumerated() {
            line.cells[column] = Cell(char: letter, wide: false, ink: Ink())
        }
        let scene = Terminal.Scene(
            lines: [line, Row(width: 10)], marks: [], caret: nil,
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let texture = try XCTUnwrap(paint.snapshot())

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        // The theme, as the frame was painted with it.
        let theme = TerminalDraw.Theme.current()
        var words = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[offset]) / 255
            let green = Double(pixels[offset + 1]) / 255
            let blue = Double(pixels[offset + 2]) / 255
            let gap = abs(red - Double(theme.ground.x))
                + abs(green - Double(theme.ground.y))
                + abs(blue - Double(theme.ground.z))
            if gap > 0.3 { words += 1 }
        }
        XCTAssertGreaterThan(words, 300, "a word of six letters at scale two paints more than specks; painted \(words)")
    }

    /// A caret, strong, paints its block: a cell's worth of the ink.
    func testStrongCaretPaintsItsBlock() throws {
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(NSRect(x: 0, y: 0, width: 200, height: 100), scale: 2)

        let scene = Terminal.Scene(
            lines: [Row(width: 10), Row(width: 10)], marks: [], caret: (0, 0),
            width: 10, height: 2, back: 0
        )
        paint.refresh(scene: scene, selection: nil, strong: true)
        let texture = try XCTUnwrap(paint.snapshot())

        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)

        let theme = TerminalDraw.Theme.current()
        // The cursor's cell: the inset over, the first cell square. Any pixel
        // within a letter of the ink is the block.
        let inset = Int(TerminalDraw.inset * 2)
        var block = 0
        for y in inset..<(inset + Int(paint.cell.height * 2) - 2) {
            for x in inset..<(inset + Int(paint.cell.width * 2) - 2) {
                let o = (y * width + x) * 4
                let gap = abs(Double(pixels[o]) / 255 - Double(theme.ink.x))
                    + abs(Double(pixels[o + 1]) / 255 - Double(theme.ink.y))
                    + abs(Double(pixels[o + 2]) / 255 - Double(theme.ink.z))
                if gap < 0.2 { block += 1 }
            }
        }
        XCTAssertGreaterThan(block, 40, "a strong caret paints a solid block of ink; painted \(block)")
    }
}
