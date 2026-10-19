import AppKit
import XCTest
@testable import NoBorderLogic

/// The geometry the scan loop decides with: does this window fill its screen's usable area?
///
/// Only the pure half is here: the maximized test, the AppKit→CG conversion, and the two composed.
/// `normalWindows()` reads live window state and `visibleFramesAsCG()` live screen state, so they are
/// checked against a real app in tests/e2e.sh; nothing in this file touches the window server.
///
/// The numbers are a pair of 1920×1200 screens with a 25 pt menu bar on each, in the arrangement
/// macOS makes for the second screen placed below the first. All coordinates are in points at 1x.
final class WindowScanTests: XCTestCase {
    // Usable areas in CG window coordinates: origin at the primary screen's top-left, y down.
    private let primaryVisible = CGRect(x: 0, y: 25, width: 1920, height: 1175)
    private let secondaryVisible = CGRect(x: 0, y: 1200, width: 1920, height: 1175)

    private var screens: [CGRect] { [primaryVisible, secondaryVisible] }

    // MARK: - the maximized test

    func testAWindowExactlyFillingTheUsableAreaIsMaximized() {
        XCTAssertTrue(WindowScan.isMaximized(primaryVisible, in: screens))
    }

    /// The rule compares four numbers — origin.x, origin.y, width, height — and allows 2 pt on each.
    /// A window 2 pt off in one of them is the boundary case, inclusive on all four.
    func testTwoPointsOffInAnyOneMeasureIsStillMaximized() {
        let v = primaryVisible
        let cases = [
            "origin x": CGRect(x: v.minX + 2, y: v.minY, width: v.width, height: v.height),
            "origin y": CGRect(x: v.minX, y: v.minY + 2, width: v.width, height: v.height),
            "width": CGRect(x: v.minX, y: v.minY, width: v.width - 2, height: v.height),
            "height": CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height - 2),
        ]
        for (name, frame) in cases {
            XCTAssertTrue(WindowScan.isMaximized(frame, in: screens),
                          "2 pt off in \(name) should still be maximized")
        }
    }

    func testThreePointsOffInAnyOneMeasureIsNotMaximized() {
        let v = primaryVisible
        let cases = [
            "origin x": CGRect(x: v.minX + 3, y: v.minY, width: v.width, height: v.height),
            "origin y": CGRect(x: v.minX, y: v.minY + 3, width: v.width, height: v.height),
            "width": CGRect(x: v.minX, y: v.minY, width: v.width - 3, height: v.height),
            "height": CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height - 3),
        ]
        for (name, frame) in cases {
            XCTAssertFalse(WindowScan.isMaximized(frame, in: screens),
                           "3 pt off in \(name) should not be maximized")
        }
    }

    /// A window inset on every side is 4 pt off in width and height even though each edge moved by
    /// only 2 pt. It is a user-resized window with a margin, not a maximized one.
    func testAWindowInsetOnEverySideIsNotMaximized() {
        let v = primaryVisible
        let inset = v.insetBy(dx: 2, dy: 2)
        XCTAssertFalse(WindowScan.isMaximized(inset, in: screens))
    }

    func testTheToleranceCanBeWidened() {
        let v = primaryVisible
        let threeOff = CGRect(x: v.minX, y: v.minY, width: v.width - 3, height: v.height)
        XCTAssertFalse(WindowScan.isMaximized(threeOff, in: screens))
        XCTAssertTrue(WindowScan.isMaximized(threeOff, in: screens, tolerance: 3))
    }

    func testNoVisibleFramesIsNotMaximized() {
        XCTAssertFalse(WindowScan.isMaximized(primaryVisible, in: []))
    }

    /// Two screens: a window that fills the second one is maximized, because its own screen's usable
    /// area is in the list. The same window against the primary's area alone is not: a maximized
    /// window on the second screen is not a window that fills the wrong screen.
    func testAWindowFillingTheSecondScreenIsMaximizedAgainstBoth() {
        XCTAssertTrue(WindowScan.isMaximized(secondaryVisible, in: screens))
        XCTAssertFalse(WindowScan.isMaximized(secondaryVisible, in: [primaryVisible]))
    }

    /// The whole screen frame — menu bar and Dock included — is not the usable area. This is the
    /// window a user gets from a green-button zoom on a screen with no menu-bar inset: it must not
    /// be treated as one of ours.
    func testAWindowFillingTheWholeScreenIsNotMaximized() {
        let wholeScreen = CGRect(x: 0, y: 0, width: 1920, height: 1200)
        XCTAssertFalse(WindowScan.isMaximized(wholeScreen, in: screens))
    }

    // MARK: - the AppKit → CG conversion

    /// AppKit's visibleFrame is in a coordinate space with the origin at the primary screen's
    /// bottom-left and y up; the window list uses the primary's top-left and y down. The primary is
    /// 1920×1200 with a 25 pt menu bar, its usable area therefore starts 25 pt below the top.
    func testThePrimarysVisibleFrameIsConvertedToCGCoordinates() {
        let appKitVisible = CGRect(x: 0, y: 0, width: 1920, height: 1175)
        let cg = WindowScan.cgFrame(fromAppKitVisibleFrame: appKitVisible, primaryHeight: 1200)
        XCTAssertEqual(cg, primaryVisible)
    }

    /// The second screen, 1920×1200 with a 25 pt menu bar, placed below the primary: its AppKit
    /// origin is y = -1175, so its usable area runs from CG y = 1200 — exactly below the primary's.
    func testTheSecondScreensVisibleFrameIsConvertedToCGCoordinates() {
        let appKitVisible = CGRect(x: 0, y: -1175, width: 1920, height: 1175)
        let cg = WindowScan.cgFrame(fromAppKitVisibleFrame: appKitVisible, primaryHeight: 1200)
        XCTAssertEqual(cg, secondaryVisible)
    }

    /// A second screen to the left, 1600×1100, its top edge 100 pt below the primary's top: AppKit
    /// puts its origin at y = 0 (the primary's bottom is y = 0). The x of a screen in the same row is
    /// already in the shared space and is kept; only y is flipped.
    func testAScreenBesideThePrimaryKeepsItsX() {
        let appKitVisible = CGRect(x: -1600, y: 0, width: 1600, height: 1100)
        let cg = WindowScan.cgFrame(fromAppKitVisibleFrame: appKitVisible, primaryHeight: 1200)
        XCTAssertEqual(cg, CGRect(x: -1600, y: 100, width: 1600, height: 1100))
    }

    /// The two halves composed: convert the screens, then judge a window on the second screen.
    func testAWindowOnTheSecondScreenIsMaximizedAfterTheConversion() {
        let appKitScreens = [CGRect(x: 0, y: 0, width: 1920, height: 1175),
                             CGRect(x: 0, y: -1175, width: 1920, height: 1175)]
        let cg = appKitScreens.map { WindowScan.cgFrame(fromAppKitVisibleFrame: $0, primaryHeight: 1200) }
        let windowOnSecondScreen = CGRect(x: 0, y: 1200, width: 1920, height: 1175)
        XCTAssertTrue(WindowScan.isMaximized(windowOnSecondScreen, in: cg))
    }

    // MARK: - the live screen list

    /// The screen list the scanner returns has to be the one an application sees, and in a process
    /// with no application object AppKit does not give that for free: on a machine with a second
    /// display, `NSScreen.visibleFrame` for it comes back as the whole screen frame — no menu-bar
    /// inset — so every window maximized on that display is 25 pt short of the area the scanner
    /// measured and never reads as maximized. The shipped scanner sets up an NSApplication for this
    /// same reason (see the comment in winscan.m).
    ///
    /// The call is taken before this test touches `NSApplication.shared`, so it measures what a
    /// caller gets in a cold process. Where no attached display has a menu-bar inset there is nothing
    /// to distinguish: AppKit knows the primary's own inset without an app, and the test says so.
    func testVisibleFramesAreTheUsableAreasAnApplicationSees() throws {
        let scanned = WindowScan.visibleFramesAsCG()
        _ = NSApplication.shared
        let screens = NSScreen.screens
        let primaryHeight = screens[0].frame.height
        let seen = screens.map { WindowScan.cgFrame(fromAppKitVisibleFrame: $0.visibleFrame,
                                                   primaryHeight: primaryHeight) }
        XCTAssertEqual(scanned, seen)
        try XCTSkipIf(screens.allSatisfy { $0.frame.height == $0.visibleFrame.height },
                      "no display here has a menu-bar inset, so this run cannot show the difference")
    }
}
