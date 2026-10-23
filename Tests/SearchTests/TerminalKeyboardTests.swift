import AppKit
import XCTest
@testable import Search

@MainActor
final class TerminalKeyboardTests: XCTestCase {
    func testControlCharactersCoverLettersAndPunctuation() {
        for byte in UInt32(1)...26 {
            let lower = String(UnicodeScalar(byte + 96)!)
            let upper = String(UnicodeScalar(byte + 64)!)
            let expected = String(UnicodeScalar(byte)!)
            XCTAssertEqual(TerminalView.controlCharacter(lower), expected)
            XCTAssertEqual(TerminalView.controlCharacter(upper), expected)
            XCTAssertEqual(TerminalView.controlCharacter(expected), expected)
        }
        for (text, byte) in [(" ", UInt32(0)), ("@", 0), ("[", 27), ("\\", 28),
                              ("]", 29), ("^", 30), ("_", 31), ("?", 127),
                              ("2", 0), ("3", 27), ("4", 28), ("5", 29),
                              ("6", 30), ("7", 31), ("8", 127)] {
            XCTAssertEqual(TerminalView.controlCharacter(text), String(UnicodeScalar(byte)!))
        }
        XCTAssertNil(TerminalView.controlCharacter(""))
        XCTAssertNil(TerminalView.controlCharacter("中文"))
        XCTAssertNil(TerminalView.controlCharacter("é"))
    }
    /// Raw-mode programs need the bytes, not AppKit's editing selectors.
    /// Read from a real PTY so two interrupts must arrive twice, and LF
    /// and VT cannot pass just because a view accepted a key event.
    func testControlKeysReachTheProgramOnBothScreens() async throws {
        for (alternate, translated) in [(false, true), (true, true), (false, false), (true, false)] {
            let enter = alternate ? "printf '\\033[?1049h'; " : ""
            let terminal = Terminal(command: TerminalCommand(argv: [
                "/bin/sh", "-c",
                "stty raw -echo; " + enter + "printf 'READY\\r\\n'; /usr/bin/od -An -tu1 -N 5",
            ]))
            defer { terminal.stop() }
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            let view = TerminalView(terminal: terminal)
            window.contentView = view
            window.makeFirstResponder(view)

            for _ in 0..<100 {
                if terminal.scene(scroll: 0)?.text.contains("READY") == true { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(terminal.scene(scroll: 0)?.text.contains("READY") == true)

            for (key, code, byte) in [("c", UInt16(8), UInt32(3)),
                                      ("j", UInt16(38), UInt32(10)),
                                      ("k", UInt16(40), UInt32(11)),
                                      ("c", UInt16(8), UInt32(3)),
                                      ("c", UInt16(8), UInt32(3))] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.control],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil,
                    characters: translated ? String(try XCTUnwrap(UnicodeScalar(byte))) : key,
                    charactersIgnoringModifiers: key, isARepeat: false, keyCode: code
                ))
                view.keyDown(with: event)
            }
            for _ in 0..<100 {
                if terminal.exit != nil { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let output = terminal.scene(scroll: 0)?.text ?? ""
            let numbers = output.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            XCTAssertEqual(numbers, [3, 10, 11, 3, 3],
                           "Control bytes must survive keyDown (alternate=\(alternate), translated=\(translated)): \(output)")
        }
    }
}
