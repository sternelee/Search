import AppKit
import SwiftUI
import XCTest
@testable import Search

@MainActor
final class FindStageTests: XCTestCase {
    override class func setUp() {
        setenv("SEARCH_PROBE", "find-stage-\(getpid())", 1)
        super.setUp()
    }

    func testFindBarFollowsFocusedPaneAndStageLayout() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        let left = Tab(bench: true)
        let right = Tab(bench: true)
        let stage = PaneStage(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        var pair = TabSplit(left: left.id, right: right.id)
        stage.show([left, right], split: pair, focused: right.id)
        stage.showFind(browser)
        stage.layoutSubtreeIfNeeded()
        let bar = try XCTUnwrap(stage.subviews.compactMap { $0 as? NSHostingView<FindBar> }.first)
        XCTAssertTrue(bar.superview === stage)
        XCTAssertEqual(bar.frame.maxX, 1000, accuracy: 0.1)
        XCTAssertEqual(bar.frame.minY, 0)

        pair.fraction = 0.35
        stage.show([left, right], split: pair, focused: left.id)
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.frame.maxX, (1000 - PaneStage.gutter) * 0.35, accuracy: 0.1)

        stage.frame.size = CGSize(width: 420, height: 250)
        stage.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.frame.maxX, 420, accuracy: 0.1)
        XCTAssertFalse(bar.isHidden)
        stage.showFind(nil)
        // The pill leaves on a leg of its own, so the host stays mounted
        // while the leg runs — taken out mid-leg the pill would vanish
        // instead of going back into its corner (see PaneStage.showFind).
        XCTAssertNotNil(bar.superview)
        let gone = expectation(description: "find bar removed after its leg")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { gone.fulfill() }
        wait(for: [gone], timeout: 2)
        XCTAssertNil(bar.superview)
    }
}
