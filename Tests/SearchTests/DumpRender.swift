import XCTest
@testable import Search
import AppKit

/// The dock's three inks — the ❯, a typed digit, and the caret — put
/// on the plate through the real draw path at 4x, then scanned in the
/// plate's own coordinates, because no font metric says where a glyph's
/// ink lands and the caret has been wrong before: measured through a
/// TIFF whose rows run top-down, the digits read 5pt high of where they
/// draw, and every caret since sat that far off its line. The scan says
/// where the ink really is; the assertion says all three agree.
final class DumpRenderTests: XCTestCase {
    @MainActor func testTheThreeInksOfTheDockAgree() throws {
        TerminalLook.family = "FiraCodeNFM-Ret"
        let plate = TerminalDockPlate()
        plate.frame = NSRect(x: 0, y: 0, width: 360, height: DockBox.height)
        var model = TerminalDock.Model()
        model.owns = true
        model.plate = 1
        model.line = 1
        model.text = "0000"
        model.cursor = 2
        model.caret.head = 2
        model.caret.tail = 2
        model.caret.squeeze = 1
        XCTAssertTrue(plate.take(model, blink: true))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 360 * 4, pixelsHigh: Int(DockBox.height) * 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        rep.size = NSSize(width: 360, height: DockBox.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        plate.draw(NSRect(x: 0, y: 0, width: 360, height: DockBox.height))
        NSGraphicsContext.restoreGraphicsState()
        let png = rep.representation(using: .png, properties: [:])!
        try png.write(to: URL(fileURLWithPath: "/tmp/dock_plate.png"))
        // And a straight scan of the three inks at this resolution.
        // The plate's own ground, sampled off to the right where no glyph
        // draws, so the scan sees ink and not the lifted panel itself.
        // The plate is translucent, and its own ground must not read as
        // ink: every row is measured against that row's own empty ground
        // (x 200pt is past every glyph), and the border rows are skipped.
        let mid = { (x0: Int, x1: Int) -> (low: CGFloat, high: CGFloat) in
            var low = -1, high = -1
            for row in (2 * 4)..<(rep.pixelsHigh - 2 * 4) {
                // colorAt runs from the top; the plate draws from the
                // bottom, so every probe is flipped to mean what the
                // plate means.
                let y = rep.pixelsHigh - 1 - row
                guard let ground = rep.colorAt(x: 200 * 4, y: y) else { continue }
                for col in x0..<x1 {
                    guard let c = rep.colorAt(x: col, y: y) else { continue }
                    let d = abs(c.redComponent - ground.redComponent)
                        + abs(c.greenComponent - ground.greenComponent)
                        + abs(c.blueComponent - ground.blueComponent)
                    if c.alphaComponent > 0.5, d > 0.25 {
                        if low == -1 { low = row }
                        high = row
                        break
                    }
                }
            }
            guard low >= 0 else { return (-1, -1) }
            return (CGFloat(low) / 4, CGFloat(high) / 4)
        }
        let advance = ("0" as NSString).size(withAttributes: [.font: TerminalLook.face(size: 12) as Any]).width.rounded(.up)
        let textX = DockBox.pad + advance + DockBox.gap
        let prompt = mid(Int(DockBox.pad * 4), Int((DockBox.pad + advance) * 4))
        let digit = mid(Int(textX * 4), Int((textX + advance) * 4))
        let caret = mid(Int((textX + 2 * advance - 3) * 4), Int((textX + 2 * advance + 3) * 4))
        for (name, ink) in [("prompt", prompt), ("digit", digit), ("caret", caret)] {
            XCTAssertGreaterThan(ink.high, 0, "the \(name)'s ink is missing from the plate")
        }
        // The three inks' middles: within half a point of each other, so
        // a caret that wanders off its line fails here and not in front
        // of a person. Everything the eye compares is a middle; the
        // extents ride along in the message when they don't.
        let promptMid = (prompt.low + prompt.high) / 2
        let digitMid = (digit.low + digit.high) / 2
        let caretMid = (caret.low + caret.high) / 2
        XCTAssertEqual(promptMid, digitMid, accuracy: 0.6, "the ❯ sits off the line: prompt \(prompt) digit \(digit) caret \(caret)")
        XCTAssertEqual(caretMid, digitMid, accuracy: 0.6, "the caret sits off the line: prompt \(prompt) digit \(digit) caret \(caret)")
        print("dock inks — prompt \(prompt) digit \(digit) caret \(caret); caretMid \(plate.caretMid) promptDy \(plate.promptDy) inkH \(plate.inkH)")
    }
}
