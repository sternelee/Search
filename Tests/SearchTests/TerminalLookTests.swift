import XCTest
@testable import Search

/// The terminal's settings, and the small decisions they carry: which face
/// answers, which shell is run, which folder a terminal starts in, and the
/// words the renderer reads the cursor and the colours as.
@MainActor
final class TerminalLookTests: XCTestCase {
    /// Nothing chosen is the Mac's own face, at the size asked for.
    func testNoFamilyIsTheMacsOwnFace() {
        let previous = TerminalLook.family
        defer { TerminalLook.family = previous }

        TerminalLook.family = ""
        let face = TerminalLook.face(size: 15)
        XCTAssertEqual(face.pointSize, 15)
        XCTAssertEqual(face.fontName, NSFont.monospacedSystemFont(ofSize: 15, weight: .regular).fontName)
    }

    /// A family that is not on this Mac costs no one a terminal: the Mac's
    /// own face answers instead.
    func testAMissingFamilyFallsBackToTheMacsOwnFace() {
        let previous = TerminalLook.family
        defer { TerminalLook.family = previous }

        TerminalLook.family = "No Such Face On This Mac"
        XCTAssertEqual(
            TerminalLook.face(size: 11).fontName,
            NSFont.monospacedSystemFont(ofSize: 11, weight: .regular).fontName
        )
    }

    /// A fixed-pitch face this Mac really has is the one it is set in.
    func testAFamilyThisMacHasIsTheOneUsed() throws {
        try XCTSkipIf(TerminalLook.faces.isEmpty, "this Mac has no fixed-pitch faces to choose from")
        let previous = TerminalLook.family
        defer { TerminalLook.family = previous }

        let chosen = TerminalLook.faces[0].name
        TerminalLook.family = chosen
        XCTAssertEqual(TerminalLook.face(size: 13).familyName, NSFont(name: chosen, size: 13)?.familyName)
    }

    /// The shell is the Mac's own until one is chosen, and a chosen one that
    /// cannot be run is not chosen at all.
    func testTheShellIsTheMacsOwnUntilARealOneIsChosen() {
        let previous = TerminalLook.shell
        defer { TerminalLook.shell = previous }

        let macs = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        TerminalLook.shell = ""
        XCTAssertEqual(TerminalLook.shellPath(), macs)

        TerminalLook.shell = "/bin/sh"
        XCTAssertEqual(TerminalLook.shellPath(), "/bin/sh")

        TerminalLook.shell = "/no/such/shell"
        XCTAssertEqual(TerminalLook.shellPath(), macs)
    }

    /// The folder is nothing until one is chosen, and a chosen one that has
    /// gone is nothing again — a terminal with nowhere to go starts here.
    func testTheFolderIsOnlyTheFolderWhileItIsThere() {
        let previous = TerminalLook.directory
        defer { TerminalLook.directory = previous }

        TerminalLook.directory = ""
        XCTAssertNil(TerminalLook.startDirectory())

        TerminalLook.directory = NSTemporaryDirectory()
        XCTAssertEqual(TerminalLook.startDirectory(), (NSTemporaryDirectory() as NSString).expandingTildeInPath)

        TerminalLook.directory = "~/no/such/folder/at/all"
        XCTAssertNil(TerminalLook.startDirectory())

        TerminalLook.directory = "/etc/hosts"
        XCTAssertNil(TerminalLook.startDirectory(), "a file is not a folder to start in")
    }

    /// A change is said on `changed`, which is how a terminal already on
    /// screen hears about it.
    func testAChangeIsSaidOnChanged() {
        let heard = expectation(description: "the terminal's settings changed")
        let watching = NotificationCenter.default.addObserver(
            forName: TerminalLook.changed, object: nil, queue: .main
        ) { _ in heard.fulfill() }
        defer { NotificationCenter.default.removeObserver(watching) }

        TerminalLook.announce()
        wait(for: [heard], timeout: 1)
    }

    /// Every cursor has a word of its own: the shader tells them apart by it,
    /// and the block's word is the one the background pass draws.
    func testEveryCursorHasItsOwnWord() {
        XCTAssertEqual(TerminalCursor.block.word, 0)
        XCTAssertEqual(TerminalCursor.bar.word, 1)
        XCTAssertEqual(TerminalCursor.underline.word, 2)
        XCTAssertEqual(Set(TerminalCursor.allCases.map(\.word)).count, TerminalCursor.allCases.count)
    }

    /// The lists the panel offers are sorted and unique, and each holds the
    /// value the terminal is set to out of the box.
    func testThePanelsListsHoldTheirDefaults() {
        XCTAssertEqual(TerminalLook.sizes, TerminalLook.sizes.sorted())
        XCTAssertEqual(Set(TerminalLook.sizes).count, TerminalLook.sizes.count)
        XCTAssertTrue(TerminalLook.sizes.contains(TerminalLook.size))

        XCTAssertEqual(TerminalLook.paddings, TerminalLook.paddings.sorted())
        XCTAssertTrue(TerminalLook.paddings.contains(TerminalLook.padding))

        XCTAssertEqual(TerminalLook.scrollbacks, TerminalLook.scrollbacks.sorted())
        XCTAssertEqual(Set(TerminalLook.scrollbacks).count, TerminalLook.scrollbacks.count)
        XCTAssertTrue(TerminalLook.scrollbacks.contains(TerminalLook.scrollback))
    }

    /// The faces are sorted by the name they are shown under, which is the
    /// order the panel walks them in.
    func testTheFacesAreSortedByTheNameTheyShow() {
        let titles = TerminalLook.faces.map(\.title)
        XCTAssertEqual(titles, titles.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertEqual(Set(TerminalLook.faces.map(\.name)).count, TerminalLook.faces.count)
    }

    /// A named theme is the same palette whichever way the Mac is set, and
    /// no two of them are the same palette.
    func testANamedThemeDoesNotFollowTheMac() {
        XCTAssertEqual(TerminalDraw.Theme.current(.light).ground, TerminalDraw.Theme.light.ground)
        XCTAssertEqual(TerminalDraw.Theme.current(.dark).ground, TerminalDraw.Theme.dark.ground)
        XCTAssertEqual(TerminalDraw.Theme.current(.solarizedLight).ground, TerminalDraw.Theme.solarizedLight.ground)
        XCTAssertEqual(TerminalDraw.Theme.current(.solarizedDark).ground, TerminalDraw.Theme.solarizedDark.ground)

        XCTAssertNotEqual(TerminalDraw.Theme.light.ground, TerminalDraw.Theme.dark.ground)
        XCTAssertNotEqual(TerminalDraw.Theme.solarizedLight.ground, TerminalDraw.Theme.solarizedDark.ground)
        XCTAssertNotEqual(TerminalDraw.Theme.light.ink, TerminalDraw.Theme.dark.ink)
    }

    /// Every palette is sixteen colours, as a terminal's is.
    func testEveryThemeHasSixteenColours() {
        let themes = [
            TerminalDraw.Theme.light, TerminalDraw.Theme.dark,
            TerminalDraw.Theme.solarizedLight, TerminalDraw.Theme.solarizedDark,
        ]
        for theme in themes {
            XCTAssertEqual(theme.ansi.count, 16)
        }
    }
}
