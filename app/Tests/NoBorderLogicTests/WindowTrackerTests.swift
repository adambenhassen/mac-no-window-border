import Darwin
import XCTest
@testable import NoBorderLogic

/// Which windows the tracker changes: the cases about those decisions, and none about the shadow tag,
/// its backoff, or a launch grace — this path has no tag.
///
/// The settle is 0.5 s both ways here. Every case drives `update` at explicit
/// times, so a settle is shown to be waited for, not assumed.
final class WindowTrackerTests: XCTestCase {
    private let pid: pid_t = 500

    private func window(_ wid: UInt32 = 1, maximized: Bool = true, of pid: pid_t = 500) -> ScannedWindow {
        ScannedWindow(wid: wid, pid: pid, maximized: maximized)
    }

    /// Scan the same windows at `from` and one second later (past both settles); return the second
    /// scan's decision. The port of `settle` in the Python tests.
    @discardableResult
    private func settle(_ tracker: WindowTracker, _ windows: [ScannedWindow], from: TimeInterval = 0,
                        buttonsHidden: Bool = false) -> TrackerDecision {
        _ = tracker.update(windows: windows, at: from, buttonsHidden: buttonsHidden)
        return tracker.update(windows: windows, at: from + 1.0, buttonsHidden: buttonsHidden)
    }

    private func assertNothing(_ decision: TrackerDecision, _ message: String = "no window should be chosen") {
        XCTAssertEqual(decision.apply, [:], message)
        XCTAssertEqual(decision.restore, [:], message)
    }

    // MARK: - applying

    func testApplyWaitsForTheSettle() {
        let tracker = WindowTracker()
        assertNothing(tracker.update(windows: [window()], at: 0), "a window seen once is not applied")
        assertNothing(tracker.update(windows: [window()], at: 0.25), "a window 0.25 s into the settle is not applied")
        XCTAssertEqual(tracker.update(windows: [window()], at: 0.5).apply, [pid: [1]],
                       "a window that has filled the usable area for 0.5 s is applied")
        XCTAssertEqual(tracker.appliedCount, 1, "the window is remembered as applied")
    }

    /// A window that stops filling the area before the settle ends starts the settle again: what the
    /// user gets is a drag, and a half-dragged window must not be changed.
    func testFlickerRestartsTheSettle() {
        let tracker = WindowTracker()
        _ = tracker.update(windows: [window()], at: 0)
        _ = tracker.update(windows: [window(maximized: false)], at: 1.0)
        assertNothing(tracker.update(windows: [window()], at: 2.0), "the settle restarts")
        XCTAssertEqual(tracker.update(windows: [window()], at: 4.0).apply, [pid: [1]])
    }

    func testAWindowThatNeverFillsTheUsableAreaIsNeverTouched() {
        let tracker = WindowTracker()
        for now: TimeInterval in [0, 0.5, 1.0, 5.0] {
            assertNothing(tracker.update(windows: [window(maximized: false)], at: now))
        }
        XCTAssertEqual(tracker.appliedCount, 0)
    }

    func testWindowsAreGroupedByProcess() {
        let tracker = WindowTracker()
        let decision = settle(tracker, [window(1), window(2), window(3, of: 600)])
        XCTAssertEqual(decision.apply, [pid: [1, 2], 600: [3]], "one batch per process")
    }

    func testAnAlreadyAppliedWindowIsNotAppliedAgain() {
        let tracker = WindowTracker()
        settle(tracker, [window()])
        assertNothing(tracker.update(windows: [window()], at: 5.0), "an applied window stays applied")
    }

    // MARK: - restoring

    func testRestoreWaitsForTheSettle() {
        let tracker = WindowTracker()
        settle(tracker, [window()])
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 3.0),
                      "a window 0 s into the settle is not restored")
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 3.25),
                      "a window 0.25 s into the settle is not restored")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 3.5).restore, [pid: [1]]
                       , "a window that stopped filling the area 0.5 s ago is restored")
        XCTAssertEqual(tracker.appliedCount, 0, "the record is dropped with the restore")
    }

    /// The rule the whole design rests on: we only ever undo our own changes.
    func testAWindowWeNeverAppliedIsNeverRestored() {
        let tracker = WindowTracker()
        // wid 1 fills the area and becomes ours; wid 2 is the user's own window, which stops filling
        // it as well. Only one of them has anything of ours in it.
        let both = [window(1), window(2, maximized: false)]
        XCTAssertEqual(settle(tracker, both, from: 0).apply, [pid: [1]])
        let unmaximized = [window(1, maximized: false), window(2, maximized: false)]
        assertNothing(tracker.update(windows: unmaximized, at: 1.0), "the restore settle has just started")
        XCTAssertEqual(tracker.update(windows: unmaximized, at: 1.5).restore, [pid: [1]],
                       "the window we applied is restored; the one we never touched is not")
    }

    func testAWindowIsRestoredOnceAndNotAgain() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 1.5), "settle starts at 1.5")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 2.0).restore, [pid: [1]])
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 5.0),
                      "a window is not restored over and over, once per scan")
    }

    func testAVanishedWindowKeepsItsRecordAndIsRestoredWhenItComesBack() {
        let tracker = WindowTracker()
        settle(tracker, [window()])
        assertNothing(tracker.update(windows: [], at: 3.0), "a scan without the window changes nothing")
        XCTAssertEqual(tracker.appliedCount, 1, "the record survives the window being off screen")
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 4.0), "the settle starts again")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 4.5).restore, [pid: [1]],
                       "back, un-maximized, and ours: restored")
    }

    /// A pending settle is not carried across the window leaving: when it comes back it is a window
    /// we have seen for 0 s, not one that has been filling the area for minutes.
    func testAPendingSettleIsClearedWhenTheWindowIsOffScreen() {
        let tracker = WindowTracker()
        _ = tracker.update(windows: [window()], at: 0)          // pending, since 0
        _ = tracker.update(windows: [], at: 0.25)               // off screen: the settle is dropped
        assertNothing(tracker.update(windows: [window()], at: 0.4), "seen again 0.4 s ago")
        assertNothing(tracker.update(windows: [window()], at: 0.8),
                      "the settle runs from the moment it came back, not from before it left")
        XCTAssertEqual(tracker.update(windows: [window()], at: 0.9).apply, [pid: [1]])
    }

    // MARK: - the window-buttons option

    func testAnAppliedWindowWhoseButtonsStateChangedIsAppliedAgainAtOnce() {
        let tracker = WindowTracker()
        XCTAssertEqual(settle(tracker, [window()], from: 0, buttonsHidden: true).apply, [pid: [1]])
        assertNothing(tracker.update(windows: [window()], at: 1.0, buttonsHidden: true), "nothing to do")
        XCTAssertEqual(tracker.update(windows: [window()], at: 1.1, buttonsHidden: false).apply, [pid: [1]],
                       "the option changed while the window stayed maximized: asked on the spot")
        assertNothing(tracker.update(windows: [window()], at: 1.2, buttonsHidden: false), "the ask is remembered")
    }

    func testTheButtonsStateOfANewApplyIsRemembered() {
        let tracker = WindowTracker()
        XCTAssertEqual(settle(tracker, [window()], from: 0, buttonsHidden: true).apply, [pid: [1]])
        assertNothing(tracker.update(windows: [window()], at: 5.0, buttonsHidden: true),
                      "an applied window asked for hidden buttons needs nothing while the option is on")
    }

    // MARK: - a batch the engine did not run

    /// The loop has already emitted the apply; the app was busy, so nothing changed. The window is
    /// still maximized and still ours to change, so the record goes away and the next scan settles
    /// and asks again. This is the whole of "deferred, never dropped".
    func testAWindowTheEngineDidNotApplyIsAskedAgainOnALaterScan() {
        let tracker = WindowTracker()
        XCTAssertEqual(settle(tracker, [window()], from: 0).apply, [pid: [1]])
        tracker.undoApply([1])
        XCTAssertEqual(tracker.appliedCount, 0, "we did not change it, so we do not claim it")
        assertNothing(tracker.update(windows: [window()], at: 1.25), "the settle starts at the next scan")
        XCTAssertEqual(tracker.update(windows: [window()], at: 1.75).apply, [pid: [1]], "asked again")
    }

    /// A restore that did not run is the other half: the window is still showing our change, so the
    /// record goes back and the next scan asks again. Without this, a busy app's window is left
    /// changed for good, which is the Phase 1 "windows left changed" outcome the spec says must not
    /// exist here.
    func testAWindowTheEngineDidNotRestoreIsAskedAgainOnALaterScan() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 2.0), "first sighting")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 2.5).restore, [pid: [1]])
        tracker.undoRestore([1], of: pid)
        XCTAssertEqual(tracker.appliedCount, 1, "it is still showing our change")
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 2.75), "the settle starts at the next scan")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 3.25).restore, [pid: [1]],
                       "asked again, and every settle after that until it lands")
    }

    func testUndoApplyOfAWindowWeNeverSawChangesNothing() {
        let tracker = WindowTracker()
        tracker.undoApply([7])
        XCTAssertEqual(tracker.appliedCount, 0, "undoing an apply cannot create a record")
    }

    // MARK: - shutdown and the record cap

    func testRestoreAllReturnsEveryAppliedWindow() {
        let tracker = WindowTracker()
        settle(tracker, [window(1), window(2), window(3, of: 600)])
        XCTAssertEqual(tracker.restoreAll(at: 5.0), [pid: [1, 2], 600: [3]],
                       "every window of ours, in its own process")
        XCTAssertEqual(tracker.appliedCount, 0)
        XCTAssertEqual(tracker.restoreAll(at: 6.0), [:], "and nothing the second time")
    }

    /// A window whose app died is never offered to the engine again, and its record is the first
    /// thing the cap gives away: the windows on screen now are what the cap is for.
    func testADeadProcessWindowIsNeverEmittedAndItsRecordIsPrunable() {
        let tracker = WindowTracker(maxRecords: 2)
        settle(tracker, [window(1), window(2)])                 // two records, at the cap
        assertNothing(tracker.update(windows: [], at: 5.0), "the tracker does not hand the dead pids back")
        XCTAssertEqual(tracker.appliedCount, 2, "at the cap, not past it, nothing is pruned")
        XCTAssertEqual(settle(tracker, [window(3)], from: 6.0).apply, [pid: [3]])
        XCTAssertEqual(tracker.appliedCount, 1, "the records of windows not on screen are pruned first")
        XCTAssertEqual(tracker.restoreAll(at: 9.0), [pid: [3]], "only the surviving record is restored")
    }

    func testSettleTimesAreConfigurable() {
        let tracker = WindowTracker(applySettle: 1.0, restoreSettle: 0.25)
        _ = tracker.update(windows: [window()], at: 0)
        assertNothing(tracker.update(windows: [window()], at: 0.75), "the configured apply settle is 1 s")
        XCTAssertEqual(tracker.update(windows: [window()], at: 1.0).apply, [pid: [1]])
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 2.0), "the settle restarts")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 2.25).restore, [pid: [1]],
                       "the configured restore settle is 0.25 s")
    }
}
