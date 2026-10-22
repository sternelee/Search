import XCTest
@testable import Search

/// The status bar's two readers: the path the shell reported and the
/// words git printed — both pure, both walked alone before the view ever
/// sees them.
final class TerminalStatusTests: XCTestCase {

    // MARK: - the path

    /// `~` for home is the shell's own shorthand, kept as the shell wrote
    /// it: the bar is not a file browser, it is the folder the shell is
    /// in, in the shell's own terms. A path grown past what a bar can
    /// hold is kept from the right end — the leaf is what tells you where
    /// you are.
    func testThePathWritesHomeAsTheShellSaysIt() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(StatusBarPath.write(URL(fileURLWithPath: home)), "~")
        XCTAssertEqual(
            StatusBarPath.write(URL(fileURLWithPath: home + "/www/github")),
            "~/www/github"
        )
        // Somewhere else entirely: the whole path, plainly.
        XCTAssertEqual(StatusBarPath.write(URL(fileURLWithPath: "/etc")), "/etc")
        // Grown past the bar: the leaf and its parent, with a marker.
        XCTAssertEqual(
            StatusBarPath.write(
                URL(fileURLWithPath: home + "/aaaaaaaaaa/bbbbbbbbbb/cccccccccc/dddddddddd/leaf")
            ),
            "/…/dddddddddd/leaf"
        )
    }

    // MARK: - git

    /// `git status --porcelain=v2 --branch`, read the way the bar reads
    /// it: the branch, ahead and behind, and the four counts. Nil when
    /// the folder is outside any repository — the bar's cue to show the
    /// folder alone.
    func testTheReportIsParsed() {
        var git = GitStatus.parse(
            """
            # branch.oid 3a4f9c2f5f2e9d8c7b6a5f4e3d2c1b0a9f8e7d6c
            # branch.head main
            # branch.upstream origin/main
            # branch.ab +2 -1
            1 .M N... 100644 100644 100644 hash hash edit
            1 M. N... 100644 100644 100644 hash hash stage
            ? untracked
            """
        )
        XCTAssertEqual(git?.branch, "main")
        XCTAssertEqual(git?.ahead, 2)
        XCTAssertEqual(git?.behind, 1)
        XCTAssertEqual(git?.staged, 1)
        XCTAssertEqual(git?.unstaged, 1)
        XCTAssertEqual(git?.untracked, 1)
        XCTAssertEqual(git?.worthSaying, true)

        // A clean tree: a branch alone is still worth saying.
        git = GitStatus.parse("# branch.head main")
        XCTAssertEqual(git?.branch, "main")
        XCTAssertEqual(git?.staged, 0)
        XCTAssertEqual(git?.unstaged, 0)
        XCTAssertEqual(git?.untracked, 0)
        XCTAssertEqual(git?.worthSaying, true)

        // A detached head has no name: the commit it stands on is the
        // honest thing to call it, the way every status line does.
        git = GitStatus.parse(
            """
            # branch.oid 3a4f9c2f5f2e9d8c7b6a5f4e3d2c1b0a9f8e7d6c
            # branch.head (detached)
            """
        )
        XCTAssertEqual(git?.branch, "3a4f9c2")

        // An unmerged pair says both — a conflict is staged and unstaged
        // at once.
        git = GitStatus.parse("# branch.head main\nu UU merge")
        XCTAssertEqual(git?.staged, 1)
        XCTAssertEqual(git?.unstaged, 1)

        // Outside any repository: nothing to say but the folder.
        XCTAssertNil(GitStatus.parse("?\nnothing here"))
    }

    // MARK: - the bar

    /// The bar holds what it was told until something actually changed —
    /// a git that says the same thing twice is not a redraw.
    @MainActor
    func testTheBarRedrawsOnlyOnNews() {
        let bar = TerminalStatusBar()
        XCTAssertTrue(bar.set(path: "~/www/git", git: nil), "the first word is news")
        XCTAssertFalse(bar.set(path: "~/www/git", git: nil), "the same word is not")
        let git = GitStatus(branch: "main", ahead: 0, behind: 0, staged: 0, unstaged: 1, untracked: 0)
        XCTAssertTrue(bar.set(path: "~/www/git", git: git), "git's first word is news")
        XCTAssertFalse(bar.set(path: "~/www/git", git: git), "and its repeat is not")
        XCTAssertTrue(bar.set(path: "~/www/search", git: git), "a new folder is news")
        XCTAssertFalse(bar.set(path: "~/www/search", git: git))
    }
}
