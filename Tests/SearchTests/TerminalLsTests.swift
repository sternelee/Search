// Temporary diagnostic: real zsh PTY + snapshot under any optimization level.
import XCTest
@testable import Search

final class TerminalLsTests: XCTestCase {
    @MainActor func testLsLaSnapshot() async throws {
        let term = Terminal(command: TerminalCommand(argv: ["/bin/zsh", "-l"]), width: 118, height: 41)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        term.send("echo HELLO-WORLD-XY\n")
        try await Task.sleep(nanoseconds: 1_000_000_000)
        guard let scene = term.scene(scroll: 0) else { XCTFail("no scene"); return }
        print("DIAG scene lines:", scene.lines.prefix(6).map { $0.text })
        let paint = TerminalDraw(font: .monospacedSystemFont(ofSize: 13, weight: .regular))!
        paint.size(CGRect(x: 0, y: 0, width: 1180, height: 780), scale: 2)
        paint.refresh(scene: scene, selection: nil, strong: false, finds: [], found: nil)
        let tex = try XCTUnwrap(paint.snapshot())
        let W = tex.width, H = tex.height
        var px = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&px, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if let cg = ctx.makeImage(), let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: "/tmp/ls-o.png"))
        }
        print("DIAG saved")
        term.stop()
    }
}
