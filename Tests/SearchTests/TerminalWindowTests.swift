import XCTest
@testable import Search

/// The whole path the app takes — a real shell in a real window, drawn by
/// the view — to say where a tab that shows nothing goes wrong.
@MainActor
final class TerminalWindowTests: XCTestCase {
    /// A live shell in a window paints its prompt: the scene the view draws
    /// says so, and the frame the renderer was last handed says so too.
    func testLiveShellSceneCarriesThePrompt() async throws {
        let terminal = Terminal(command: TerminalCommand(
            argv: ["/bin/zsh", "-f", "-c", "echo PROMPT-HERE; sleep 5"]
        ))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = TerminalView(terminal: terminal)
        window.contentView = view
        window.orderFrontRegardless()

        // The shell's words may land before anything is listening for them,
        // so the scene itself is polled — the words are what matter, and
        // they stay on the screen once they are there.
        var scene: Terminal.Scene?
        for _ in 0..<100 {
            scene = terminal.scene(scroll: 0)
            if scene?.lines.contains(where: { (row: Row) in row.text.contains("PROMPT-HERE") }) == true { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let found = try XCTUnwrap(scene, "the shell's scene exists")
        let texts: [String] = found.lines.map { (row: Row) in row.text }
        XCTAssertEqual(texts.filter { $0.contains("PROMPT-HERE") }.count, 1, "the prompt line reached the scene: \(texts)")

        // The view's own drawing of that scene: the cells the renderer was
        // handed carry the letters, not spaces.
        let paint = try XCTUnwrap(TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular)))
        paint.size(view.bounds, scale: view.window?.backingScaleFactor ?? 1)
        paint.refresh(scene: found, selection: nil, strong: false)
        let texture = try XCTUnwrap(paint.snapshot())
        let width = texture.width, height = texture.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let theme = TerminalDraw.Theme.current()
        var painted = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let gap = abs(Double(pixels[offset]) / 255 - Double(theme.ground.x))
                + abs(Double(pixels[offset + 1]) / 255 - Double(theme.ground.y))
                + abs(Double(pixels[offset + 2]) / 255 - Double(theme.ground.z))
            if gap > 0.3 { painted += 1 }
        }
        XCTAssertGreaterThan(painted, 200, "the words of the prompt painted; painted \(painted)")

        terminal.stop()
    }
}
