import XCTest
import CoreGraphics
@testable import PreviewCore

final class PreviewCoreTests: XCTestCase {
    func testHoverRequiresDwellAndRejectsOldResults() {
        var state = HoverState()
        state.enter("Safari", at: 1)
        let safari = state.generation
        XCTAssertFalse(state.ready(at: 1.24, delay: 0.25))
        XCTAssertTrue(state.ready(at: 1.25, delay: 0.25))
        state.enter("Terminal", at: 1.26)
        XCTAssertFalse(state.accepts(safari))
        XCTAssertFalse(state.ready(at: 1.4, delay: 0.25))
        XCTAssertTrue(state.ready(at: 1.51, delay: 0.25))
    }
    func testLeaveGraceAndReturnToPanel() {
        var state = HoverState()
        state.enter("app", at: 0); state.markPresented(); state.leave(at: 1)
        XCTAssertFalse(state.shouldHide(at: 1.19))
        state.keep()
        XCTAssertFalse(state.shouldHide(at: 2))
        state.leave(at: 3)
        XCTAssertTrue(state.shouldHide(at: 3.21))
        state.reset()
        XCTAssertNil(state.target)
    }
    func testLeaveBeforeDwellPreventsOpen() {
        var state = HoverState()
        state.enter("app", at: 0); state.leave(at: 0.1)
        XCTAssertFalse(state.ready(at: 0.3, delay: 0.25))
        state.keep()
        XCTAssertTrue(state.ready(at: 0.3, delay: 0.25))
    }
    func testResetInvalidatesPendingCapture() {
        var state = HoverState()
        state.enter("app", at: 0)
        let token = state.generation
        state.reset(); state.enter("app", at: 1)
        XCTAssertFalse(state.accepts(token))
    }
    func testDuplicateTitlesNeedUniqueGeometry() {
        let a = WindowDescriptor(pid: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let b = WindowDescriptor(pid: 1, title: "Untitled", frame: CGRect(x: 300, y: 0, width: 800, height: 600))
        XCTAssertEqual(WindowMatcher.uniqueMatch(a, candidates: [b, a]), 1)
        XCTAssertNil(WindowMatcher.uniqueMatch(a, candidates: [a, a]))
        XCTAssertNil(WindowMatcher.uniqueMatch(a, candidates: [b]))
    }
    func testTwoAXWindowsCannotClaimOneScreenshot() {
        let a = WindowDescriptor(pid: 1, title: "Untitled", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertNil(WindowMatcher.mutuallyUniqueMatch(at: 0, windows: [a, a], candidates: [a]))
        XCTAssertNil(WindowMatcher.mutuallyUniqueMatch(at: 1, windows: [a, a], candidates: [a]))
        XCTAssertEqual(WindowMatcher.mutuallyUniqueMatch(at: 0, windows: [a], candidates: [a]), 0)
    }
    func testWrongProcessAndMissingGeometryNeverMatch() {
        let a = WindowDescriptor(pid: 1, title: "Document", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let other = WindowDescriptor(pid: 2, title: "Document", frame: a.frame)
        XCTAssertNil(WindowMatcher.uniqueMatch(a, candidates: [other]))
        XCTAssertNil(WindowMatcher.uniqueMatch(a, candidates: []))
    }
    func testGeometryToleranceAndTitlePreference() {
        let a = WindowDescriptor(pid: 1, title: "A", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let b = WindowDescriptor(pid: 1, title: "B", frame: a.frame)
        let c = WindowDescriptor(pid: 1, title: "A", frame: CGRect(x: 2, y: 1, width: 800, height: 601))
        XCTAssertEqual(WindowMatcher.uniqueMatch(a, candidates: [b, c]), 1)
    }
    func testPanelClampsToOffsetDisplayOnAllDockEdges() {
        let screen = CGRect(x: -1440, y: 100, width: 1440, height: 900)
        for edge in [DockEdge.bottom, .left, .right] {
            let frame = PanelLayout.frame(size: CGSize(width: 720, height: 500),
                anchor: CGRect(x: -10, y: 102, width: 50, height: 50), screen: screen, edge: edge)
            XCTAssertTrue(screen.contains(frame))
        }
        let oversized = PanelLayout.frame(size: CGSize(width: 3000, height: 3000), anchor: .zero, screen: screen, edge: .bottom)
        XCTAssertTrue(screen.contains(oversized))
    }
    func testColumnsFitNarrowDisplays() {
        XCTAssertEqual(PanelLayout.columns(count: 8, screenWidth: 1440, cardWidth: 220), 3)
        XCTAssertEqual(PanelLayout.columns(count: 8, screenWidth: 500, cardWidth: 220), 2)
        XCTAssertEqual(PanelLayout.columns(count: 8, screenWidth: 250, cardWidth: 220), 1)
        XCTAssertEqual(PanelLayout.columns(count: 1, screenWidth: 1440, cardWidth: 220), 1)
    }
    func testMinimizedWindowsSurviveMissingOrCollapsedGeometry() {
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXStandardWindow", minimized: true, frame: nil))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXUnknown", minimized: true, frame: .zero))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: nil, minimized: true, frame: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
    func testWindowEligibilityStillRejectsTransientUI() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertFalse(WindowEligibility.includes(role: "AXMenu", subrole: nil, minimized: true, frame: frame))
        XCTAssertFalse(WindowEligibility.includes(role: "AXWindow", subrole: "AXDialog", minimized: false, frame: frame))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXDialog", minimized: true, frame: frame))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXDialog", minimized: false, frame: frame, minimizable: true))
        XCTAssertFalse(WindowEligibility.includes(role: "AXWindow", subrole: "AXFloatingWindow", minimized: false, frame: frame))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, frame: frame))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, frame: .zero))
    }
    func testOtherSpaceWindowsDoNotRequireGeometry() {
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXStandardWindow", minimized: false, frame: nil))
        XCTAssertTrue(WindowEligibility.includes(role: "AXWindow", subrole: "AXUnknown", minimized: false, frame: nil, minimizable: true))
        XCTAssertFalse(WindowEligibility.includes(role: "AXWindow", subrole: "AXUnknown", minimized: false, frame: nil))
    }
    func testCacheEvictsLeastRecentlyUsedAndEnforcesCost() {
        var cache = CostBoundedCache<String, Int>(costLimit: 10)
        cache.insert(1, for: "a", cost: 4); cache.insert(2, for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), 1)
        cache.insert(3, for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"))
        XCTAssertEqual(cache.totalCost, 8)
        cache.insert(9, for: "huge", cost: 11)
        XCTAssertNil(cache.value(for: "huge"))
        cache.insert(4, for: "a", cost: 2)
        XCTAssertEqual(cache.totalCost, 6)
        cache.removeAll(); XCTAssertEqual(cache.totalCost, 0)
    }
    func testCacheAlsoBoundsZeroCostEntries() {
        var cache = CostBoundedCache<Int, Int>(costLimit: 10, countLimit: 2)
        cache.insert(1, for: 1, cost: 0); cache.insert(2, for: 2, cost: 0); cache.insert(3, for: 3, cost: 0)
        XCTAssertNil(cache.value(for: 1)); XCTAssertEqual(cache.value(for: 3), 3)
    }
    func testTravelCorridorDoesNotCoverWholePanelMargin() {
        let anchor = CGRect(x: 500, y: 0, width: 50, height: 50)
        let panel = CGRect(x: 200, y: 60, width: 650, height: 300)
        let bridge = PanelLayout.bridge(anchor: anchor, panel: panel)
        XCTAssertTrue(bridge.contains(CGPoint(x: 525, y: 55)))
        XCTAssertFalse(bridge.contains(CGPoint(x: 210, y: 55)))
    }
    func testMenuOnlyScreenshotRequiresUniqueTitlesOnBothSides() {
        let menu = WindowDescriptor(pid: 42, title: "Project", frame: .zero)
        let shot = WindowDescriptor(pid: 42, title: "Project", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        XCTAssertEqual(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu], candidates: [shot]), 0)
        XCTAssertNil(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu, menu], candidates: [shot]))
        XCTAssertNil(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu], candidates: [shot, shot]))
        XCTAssertNil(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu], candidates: [.init(pid: 43, title: "Project", frame: shot.frame)]))
        XCTAssertNil(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [.init(pid: 42, title: "", frame: .zero)], candidates: [.init(pid: 42, title: "", frame: shot.frame)]))
    }
    func testMenuTitleFormattingDoesNotChangeIdentity() {
        let menu = WindowDescriptor(pid: 42, title: "\u{2068}Project\u{2069}", frame: .zero)
        let shot = WindowDescriptor(pid: 42, title: "Project", frame: .zero)
        XCTAssertEqual(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu], candidates: [shot]), 0)
        XCTAssertNil(WindowMatcher.mutuallyUniqueTitleMatch(at: 0, windows: [menu, shot], candidates: [shot]))
    }

}
