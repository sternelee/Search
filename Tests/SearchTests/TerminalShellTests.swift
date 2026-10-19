import XCTest
@testable import Search

// The shell integration is written into the app's own folder — never a
// line of the user's (see TerminalShell). What is written, and what the
// shell is asked to load, is everything to check here: the files exist,
// they source the user's own first, and they mark the commands with OSC
// 133. A shell that has no place to be asked from runs as itself.
final class TerminalShellTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "terminal-shell-\(getpid())", 1)
        super.setUp()
    }

    private let folder = FileManager.default

    /// zsh is pointed at the app's own folder, which holds an integration
    /// that sources the user's own files and marks the commands.
    func testZshIsPointedAtTheIntegration() throws {
        let wrapped = TerminalShell.wrap(argv: ["/bin/zsh", "-l"], environment: ["HOME=/Users/who"])
        XCTAssertEqual(wrapped.argv, ["/bin/zsh", "-l"], "zsh runs as it was asked")

        let home = try XCTUnwrap(wrapped.environment.first { $0.hasPrefix("ZDOTDIR=") })
        let dir = URL(fileURLWithPath: String(home.dropFirst("ZDOTDIR=".count)))

        for name in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let file = dir.appendingPathComponent(name)
            XCTAssertTrue(folder.fileExists(atPath: file.path), "\(name) must be written")
        }
        let rc = try String(contentsOf: dir.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertTrue(rc.contains("source \"$HOME/.zshrc\""), "the user's own is sourced first")
        XCTAssertTrue(rc.contains("133;C"), "the commands are marked")
        XCTAssertTrue(rc.contains("precmd_functions"), "the marks are hooked")
        let env = try String(contentsOf: dir.appendingPathComponent(".zshenv"), encoding: .utf8)
        XCTAssertTrue(env.contains("source \"$HOME/.zshenv\""), "the user's own env is sourced first")
        XCTAssertTrue(env.contains("ZDOTDIR="), "the pointing holds even if theirs said otherwise")
    }

    /// bash takes its rc as an argument; the user's own is sourced within.
    func testBashTakesTheIntegrationAsItsRc() throws {
        let wrapped = TerminalShell.wrap(argv: ["/bin/bash", "-l"], environment: ["HOME=/Users/who"])
        XCTAssertEqual(wrapped.argv.first, "/bin/bash")
        XCTAssertFalse(wrapped.argv.contains("-l"), "a login shell never reads the rc file")
        let rc = try XCTUnwrap(wrapped.argv.first { $0.hasSuffix("search.bashrc") })
        XCTAssertTrue(folder.fileExists(atPath: rc), "the rc file must be written")

        let text = try String(contentsOf: URL(fileURLWithPath: rc), encoding: .utf8)
        XCTAssertTrue(text.contains("source \"$HOME/.bashrc\""), "the user's own is sourced first")
        XCTAssertTrue(text.contains("133;D"), "the ends are marked")
        XCTAssertTrue(text.contains("PROMPT_COMMAND"), "the marks are hooked")
    }

    /// A shell with no place to be asked from runs as itself, untouched.
    func testAShellThatCannotBeAskedRunsAsItself() {
        for argv in [["/bin/sh", "-l"], ["/usr/local/bin/fish", "-i"], []] {
            let wrapped = TerminalShell.wrap(argv: argv, environment: ["HOME=/Users/who"])
            XCTAssertEqual(wrapped.argv, argv)
            XCTAssertEqual(wrapped.environment, ["HOME=/Users/who"])
        }
    }
}
