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

    // MARK: - the app undid our change (the focus-transition case, measured 2026-10-20)

    /// The reads, per cycle: the first is the baseline, and each later one flips the state, so each
    /// is a focus transition — the event that repaints the app's drawing over our change (AppKit's
    /// rim on focus-in, iTerm's outline on focus-out).
    private func flip(tracker: WindowTracker, at: TimeInterval, key: Bool, buttonsHidden: Bool = false) -> TrackerDecision {
        tracker.update(windows: [window()], at: at, buttonsHidden: buttonsHidden, keyStates: [1: key])
    }

    func testAWindowAtAKeyStateTransitionIsAppliedAgainOnTheSpot() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        assertNothing(flip(tracker: tracker, at: 5.0, key: false), "the first read is the baseline, not a transition")
        XCTAssertEqual(flip(tracker: tracker, at: 5.25, key: true).apply, [pid: [1]],
                       "focus-in: the transition asks for the change back, no settle")
        assertNothing(flip(tracker: tracker, at: 5.5, key: true), "and it is not asked over and over while the state is steady")
    }

    func testTheUndoBudgetStartsOverWhenTheKeyStateGoesSteady() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        flip(tracker: tracker, at: 5.0, key: false)                     // baseline
        for (at, key) in [(5.25, true), (5.5, false), (5.75, true)] {   // strikes 1, 2, 3
            XCTAssertEqual(flip(tracker: tracker, at: at, key: key).apply, [pid: [1]])
        }
        assertNothing(flip(tracker: tracker, at: 6.0, key: true), "steady: the budget starts over")
        XCTAssertEqual(flip(tracker: tracker, at: 6.25, key: false).apply, [pid: [1]],
                       "a fresh budget: this transition is the first of a new streak, not the fourth")
    }

    func testAWindowFlippingPastItsBudgetIsLeftAloneAndNamedOnce() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        flip(tracker: tracker, at: 5.0, key: false)                     // baseline
        for (at, key) in [(5.25, true), (5.5, false), (5.75, true)] {   // strikes 1, 2, 3
            XCTAssertEqual(flip(tracker: tracker, at: at, key: key).apply, [pid: [1]])
        }
        let fourth = flip(tracker: tracker, at: 6.0, key: false)
        assertNothing(fourth, "the fourth transition is past the budget: no more asking")
        XCTAssertEqual(fourth.gaveUp, [pid: [1]], "and the window is named, once")
        let fifth = flip(tracker: tracker, at: 6.25, key: true)
        assertNothing(fifth, "left alone means left alone")
        XCTAssertEqual(fifth.gaveUp, [:], "naming it again every scan is a line four times a second")
    }

    func testUserTransitionsAreServedEveryTimeAndStrikeNothing() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        flip(tracker: tracker, at: 5.0, key: false)                      // baseline
        for i in 0..<18 {                                                // 18 app switches: every flip a transition
            let at = 5.25 + Double(i) * 0.25
            XCTAssertEqual(tracker.update(windows: [window()], at: at, keyStates: [1: i % 2 == 0],
                                          transitionsAreUser: true).apply, [pid: [1]],
                           "the user's app switching is not a flap war: every flip is served, the budget untouched")
        }
    }

    func testAKickReassertsASteadyWindow() {
        // The live iTerm case (2026-10-21): switch away and back, the focus repaint lands
        // AFTER the transition's answer — the key state reads steady and the outline stands.
        // The kick cycle asks for the change again even when nothing transitioned.
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        flip(tracker: tracker, at: 5.0, key: true)                        // baseline, applied
        XCTAssertEqual(tracker.update(windows: [window()], at: 5.25, keyStates: [1: true],
                                      transitionsAreUser: true).apply, [pid: [1]],
                       "a focus event with a steady key state is a repaint to answer, not silence")
        assertNothing(tracker.update(windows: [window()], at: 5.5, keyStates: [1: true]),
                      "a timer scan with a steady state stays quiet: the re-assert is the event, not 4 Hz")
    }

    func testAKickReassertsEvenWhenNoKeyReadRan() {
        // The real bug (2026-10-21): at focus-in the app is busy repainting, so the native key
        // read times out (~200 ms, measured) and answers nothing. With no key reading the
        // window must STILL be re-asserted on a user kick — the agent op is a queued message
        // that drains without a park — or the repainted outline stands. The loop's fake engine
        // always answers, so only here is the empty read exercised.
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        XCTAssertEqual(tracker.update(windows: [window()], at: 5.0, transitionsAreUser: true).apply, [pid: [1]],
                       "a focus kick with no key read re-asserts the applied window")
    }

    func testAUserTransitionResumesASurrenderedWindow() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        for (at, key) in [(5.0, false), (5.25, true), (5.5, false), (5.75, true), (6.0, false)] {
            _ = flip(tracker: tracker, at: at, key: key)   // baseline, strikes 1-3, surrender
        }
        assertNothing(flip(tracker: tracker, at: 6.25, key: true), "surrendered: timer transitions are left alone")
        XCTAssertEqual(tracker.update(windows: [window()], at: 6.5, keyStates: [1: false],
                                      transitionsAreUser: true).apply, [pid: [1]],
                       "the user's switch is a new event, not the flap war that gave up on: back in service")
    }

    func testAWindowWithNoReadAnswersNothing() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        flip(tracker: tracker, at: 5.0, key: false)                       // baseline
        XCTAssertEqual(flip(tracker: tracker, at: 5.25, key: true).apply, [pid: [1]], "strike 1")
        assertNothing(tracker.update(windows: [window()], at: 5.5), "a read that did not run concludes nothing")
        XCTAssertEqual(flip(tracker: tracker, at: 5.75, key: false).apply, [pid: [1]],
                       "and the missing read neither strikes nor spends the budget: this is strike 2")
    }

    func testASurrenderedWindowIsRestoredWhenItUnMaximizesAndReArmsAfterThat() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        for (at, key) in [(5.0, false), (5.25, true), (5.5, false), (5.75, true), (6.0, false)] {
            _ = flip(tracker: tracker, at: at, key: key)   // baseline, strikes 1-3, surrender
        }
        assertNothing(tracker.update(windows: [window(maximized: false)], at: 6.5), "the restore settle starts")
        XCTAssertEqual(tracker.update(windows: [window(maximized: false)], at: 7.0).restore, [pid: [1]],
                       "the border we left in place goes back like any other applied window's")
        XCTAssertEqual(settle(tracker, [window()], from: 7.5).apply, [pid: [1]], "and a new stay starts clean")
    }

    func testTheButtonsOptionReachesASurrenderedWindow() {
        let tracker = WindowTracker()
        settle(tracker, [window()], from: 0)
        for (at, key) in [(5.0, false), (5.25, true), (5.5, false), (5.75, true), (6.0, false)] {
            _ = flip(tracker: tracker, at: at, key: key)   // baseline, strikes 1-3, surrender
        }
        assertNothing(flip(tracker: tracker, at: 6.25, key: true), "surrendered")
        XCTAssertEqual(tracker.update(windows: [window()], at: 6.5, buttonsHidden: true, keyStates: [1: true]).apply,
                       [pid: [1]], "the user's option is a new ask, and the ask re-arms the window")
        XCTAssertEqual(flip(tracker: tracker, at: 6.75, key: false, buttonsHidden: true).apply, [pid: [1]],
                       "budget spent, budget earned: the re-arm gives it the strikes back")
    }

    func testAppliedWindowsAreGroupedByOwnerAndOnlyTheSeenOnes() {
        let tracker = WindowTracker()
        XCTAssertEqual(settle(tracker, [window(1), window(2), window(3, of: 600)], from: 0).apply,
                       [pid: [1, 2], 600: [3]])
        XCTAssertEqual(tracker.appliedWindows(in: [window(1), window(2), window(3, of: 600), window(4, of: 700)]),
                       [pid: [1, 2], 600: [3]], "a read batch is one stop in one app: grouped by owner")
        XCTAssertEqual(tracker.appliedWindows(in: []), [:], "a window off screen is not read")
        XCTAssertEqual(tracker.appliedWindows(in: [window(9)]), [:], "a window that is not ours is not read")
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
