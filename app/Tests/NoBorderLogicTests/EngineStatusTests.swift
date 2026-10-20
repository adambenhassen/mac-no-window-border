import XCTest
@testable import NoBorderLogic

/// What the menu says about the scan loop. Small on purpose: the loop runs in this process, so the
/// states are the ones a loop has — not running and running; the stop's restore blocks the main
/// thread, so there is no rendered state between them. There is no
/// child process to supervise, so the old daemon's starting / crashed / restart states have no
/// meaning, and neither does a fatal one: with no daemon, no Python, no Xcode and no task to
/// request, the loop has nothing left to fail at startup.
final class EngineStatusTests: XCTestCase {
    func testOffIsPlain() {
        XCTAssertEqual(EngineStatus.off.menuText, "Off")
    }

    func testRunningSaysHowManyWindowsWeChanged() {
        XCTAssertEqual(EngineStatus.running(windows: 0).menuText, "Running: no windows changed")
        XCTAssertEqual(EngineStatus.running(windows: 1).menuText, "Running: 1 window changed")
        XCTAssertEqual(EngineStatus.running(windows: 7).menuText, "Running: 7 windows changed")
    }
}
