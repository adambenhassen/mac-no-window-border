import Darwin
import Foundation
import NoBorderEngine
import XCTest
@testable import NoBorderLogic

/// The 250 ms loop, with a fake scan, a fake clock and a fake engine: what a cycle asks for, what a
/// stop leaves behind, that a deferral is asked again, that cycles never overlap, and what reaches
/// the log. The scanner and the real engine are the app's, and are driven by tests/e2e.sh.
final class ScanLoopTests: XCTestCase {
    private let pid: pid_t = 500

    private final class FakeClock {
        var now: TimeInterval = 0
    }

    private final class FakeScan {
        var windows: [ScannedWindow] = []
        private(set) var calls = 0
        var body: () -> [ScannedWindow] {
            get { { [self] in self.calls += 1; return self.windows } }
        }
    }

    /// Stands in for an engine: records every batch, hands back the windows it will not change, and
    /// logs the lines the real engine logs, through the closure the loop handed it.
    private final class FakeEngine: ChangeEngine {
        struct Call: Equatable {
            let pid: pid_t
            let windows: [UInt32]
            let restoring: Bool
            var buttonsHidden = false
        }

        var calls: [Call] = []
        /// Every key state read, recorded the same way as a change.
        private(set) var reads: [Call] = []
        var shutdowns = 0
        /// Windows this engine refuses to touch, so the loop is told to ask again.
        var deferred: Set<UInt32> = []
        /// The key state this engine answers, per window: a change between reads is a focus
        /// transition, and a transition is what puts the app's drawing back.
        var keyStates: [UInt32: Bool] = [:]
        /// Makes a call take this long, to see whether cycles overlap.
        var slow: TimeInterval = 0
        private(set) var maxConcurrent = 0
        private var running = 0
        private let lock = NSLock()
        private let log: (String) -> Void

        init(log: @escaping (String) -> Void) { self.log = log }

        @discardableResult
        func apply(pid: pid_t, windows: [UInt32], buttonsHidden: Bool) -> [UInt32] {
            change(pid: pid, windows: windows, restoring: false, buttonsHidden: buttonsHidden)
        }

        @discardableResult
        func restore(pid: pid_t, windows: [UInt32]) -> [UInt32] { change(pid: pid, windows: windows, restoring: true) }

        func keyWindows(pid: pid_t, windows: [UInt32]) -> [UInt32: Bool] {
            enter()
            reads.append(Call(pid: pid, windows: windows, restoring: false))
            leave()
            // A read that ran answers every window it was given; the answer defaults to not key.
            return Dictionary(uniqueKeysWithValues: windows.map { ($0, keyStates[$0] ?? false) })
        }

        @discardableResult
        private func change(pid: pid_t, windows: [UInt32], restoring: Bool, buttonsHidden: Bool = false) -> [UInt32] {
            enter()
            calls.append(Call(pid: pid, windows: windows, restoring: restoring, buttonsHidden: buttonsHidden))
            let batch = windows.map(String.init).joined(separator: " ")
            log(restoring ? "restoring \(batch)" : "applying \(batch)")
            if slow > 0 { Thread.sleep(forTimeInterval: slow) }
            leave()
            return windows.filter { deferred.contains($0) }
        }

        func shutdown() { shutdowns += 1 }

        private func enter() {
            lock.lock(); running += 1; maxConcurrent = max(maxConcurrent, running); lock.unlock()
        }

        private func leave() {
            lock.lock(); running -= 1; lock.unlock()
        }
    }

    /// The wiring the app uses: the engine is built before the loop, so its log goes through a
    /// forwarder the loop fills in.
    private final class LogForward {
        var next: ((String) -> Void)?
        func say(_ line: String) { next?(line) }
    }

    private var clock: FakeClock!
    private var scan: FakeScan!
    private var forward: LogForward!
    private var engine: FakeEngine!
    private var logs: [String] = []
    private var statuses: [Int] = []
    private var loop: ScanLoop!
    /// The app's "hide window buttons" option, as the loop sees it.
    private var hideButtons = false

    private func window(_ wid: UInt32 = 1, maximized: Bool = true, of pid: pid_t = 500) -> ScannedWindow {
        ScannedWindow(wid: wid, pid: pid, maximized: maximized)
    }

    /// `reassertInterval` defaults far past any test's clock, so the floored re-assert stays out of
    /// the cases that are about something else (deferral, buttons, key reads). The re-assert cases
    /// set a small one of their own.
    private func makeLoop(interval: TimeInterval = 0.25, realClock: Bool = false,
                          keyReadInterval: TimeInterval = 0,
                          reassertInterval: TimeInterval = 1_000_000) {
        clock = FakeClock()
        scan = FakeScan()
        forward = LogForward()
        engine = FakeEngine(log: forward.say)
        let time: ScanLoop.Clock = realClock ? { Date().timeIntervalSince1970 } : { [clock] in clock!.now }
        loop = ScanLoop(interval: interval,
                       now: time,
                       scan: scan.body,
                       tracker: WindowTracker(),
                       engine: engine,
                       buttonsHidden: { [weak self] in self?.hideButtons ?? false },
                       keyReadInterval: keyReadInterval,
                       reassertInterval: reassertInterval,
                       log: { [weak self] line in self?.logs.append(line) },
                       status: { [weak self] n in self?.statuses.append(n) })
        forward.next = loop.engineLog()
    }

    /// Advance the clock and run one cycle, with no timer involved.
    private func cycle(at now: TimeInterval) {
        clock.now = now
        loop.step()
    }

    /// Cycles at the shipped 250 ms cadence, over a stretch of the fake clock.
    private func cycles(from: TimeInterval, to: TimeInterval) {
        var t = from
        while t <= to + 1e-9 {
            cycle(at: t)
            t += 0.25
        }
    }

    override func tearDown() {
        loop = nil
        super.tearDown()
    }

    // MARK: - one cycle

    func testAWindowThatHasFilledTheAreaForTheSettleIsAppliedOnThatCycle() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        XCTAssertEqual(engine.calls, [], "a window seen once is not a change to ask for")
        cycle(at: 0.5)
        XCTAssertEqual(engine.calls, [FakeEngine.Call(pid: pid, windows: [1], restoring: false)])
        XCTAssertEqual(logs, ["applying 1"])
    }

    func testAWindowThatJustTurnedMaximizedIsNotApplied() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.25)
        XCTAssertEqual(engine.calls, [])
        XCTAssertEqual(logs, [])
    }

    func testTheBatchOfOneProcessIsOneCall() {
        makeLoop()
        scan.windows = [window(1), window(2), window(3, of: 600)]
        cycle(at: 0)
        cycle(at: 0.5)
        XCTAssertEqual(engine.calls, [
            FakeEngine.Call(pid: pid, windows: [1, 2], restoring: false),
            FakeEngine.Call(pid: 600, windows: [3], restoring: false),
        ])
    }

    func testTheLoopKeepsScanningAfterAProcessItCannotReach() {
        makeLoop()
        // Every call for pid 500 fails: the loop says so once and goes on with everyone else.
        scan.windows = [window(1, of: 500), window(9, of: 600)]
        cycle(at: 0)
        forward.say("engine failed 500 1: task port denied for 500")
        cycle(at: 0.5)
        XCTAssertTrue(engine.calls.contains { $0.pid == 600 }, "the other process is served")
        let scannedBefore = scan.calls
        cycle(at: 1.0)
        cycle(at: 1.5)
        XCTAssertGreaterThan(scan.calls, scannedBefore, "a dead pid does not stop the timer")
        XCTAssertEqual(logs.filter { $0.hasPrefix("engine failed") }.count, 1,
                       "one line per process, not one per scan")
    }

    // MARK: - deferral: an app that is busy is asked again, never dropped

    func testAWindowTheEngineDeferredIsAskedAgainOnLaterCycles() {
        makeLoop()
        scan.windows = [window()]
        engine.deferred = [1]
        cycles(from: 0, to: 10)
        XCTAssertGreaterThanOrEqual(engine.calls.count, 10,
                                   "a busy app is deferred, not dropped: every settle asks again")
        XCTAssertEqual(statuses.last, 0, "none of those asks changed anything")
        engine.deferred = []
        cycles(from: 10.25, to: 15)
        XCTAssertEqual(statuses.last, 1, "one of them lands")
        let asks = engine.calls.count
        cycle(at: 20.0)
        XCTAssertEqual(engine.calls.count, asks, "and an applied window is not asked for again")
    }

    func testADeferredRestoreIsAskedAgainOnLaterCycles() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        XCTAssertEqual(engine.calls.count, 1)
        scan.windows = [window(maximized: false)]
        engine.deferred = [1]
        cycles(from: 1.0, to: 10)
        let restores = engine.calls.filter { $0.restoring }.count
        XCTAssertGreaterThanOrEqual(restores, 2,
                                   "the window is still showing our change, so the record goes back " +
                                       "and every settle asks again")
        XCTAssertEqual(statuses.last, 1, "and it is still counted as changed until the restore lands")
    }

    func testADeferredWindowIsNotReportedAsChanged() {
        makeLoop()
        scan.windows = [window()]
        engine.deferred = [1]
        cycles(from: 0, to: 5)
        XCTAssertEqual(statuses.last, 0, "the app did not change, so the menu does not claim it did")
        engine.deferred = []
        cycles(from: 5.25, to: 10)
        XCTAssertEqual(statuses.last, 1, "and it does claim it once the change lands")
    }

    // MARK: - the window-buttons option

    func testTogglingTheButtonsOptionReasksAppliedWindowsOnTheNextCycle() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        XCTAssertEqual(engine.calls, [FakeEngine.Call(pid: pid, windows: [1], restoring: false)])
        hideButtons = true
        cycle(at: 0.75)
        XCTAssertEqual(engine.calls.last, FakeEngine.Call(pid: pid, windows: [1], restoring: false, buttonsHidden: true),
                       "an applied window that disagrees with the option is applied again at once")
        cycle(at: 1.0)
        XCTAssertEqual(engine.calls.filter { $0.buttonsHidden }.count, 1, "and not asked over and over")
        hideButtons = false
        cycle(at: 1.25)
        XCTAssertEqual(engine.calls.last, FakeEngine.Call(pid: pid, windows: [1], restoring: false, buttonsHidden: false),
                       "turning the option off reaches the window that is staying maximized")
    }

    func testAButtonsChangeTheEngineDeferredIsAskedAgain() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        hideButtons = true
        engine.deferred = [1]
        cycles(from: 0.75, to: 5)
        XCTAssertGreaterThanOrEqual(engine.calls.filter { $0.buttonsHidden }.count, 3,
                                   "the app was busy, so every settle asks for the new buttons state")
        engine.deferred = []
        cycles(from: 5.25, to: 7)
        XCTAssertEqual(engine.calls.last, FakeEngine.Call(pid: pid, windows: [1], restoring: false, buttonsHidden: true),
                       "one of the later asks lands")
        let asks = engine.calls.count
        cycle(at: 10)
        XCTAssertEqual(engine.calls.count, asks, "once it lands, asking stops")
    }

    // MARK: - the app undid our change: read the key state, re-ask, and stop fighting

    func testAppliedWindowsGetTheirKeyStateReadEveryCycle() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)                                   // applied
        cycle(at: 1.0)
        XCTAssertEqual(engine.reads.last, FakeEngine.Call(pid: pid, windows: [1], restoring: false),
                       "an applied, visible window is asked of the engine every cycle")
    }

    func testAWindowTheScanDoesNotSeeIsNeverRead() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        let asked = engine.reads.count
        scan.windows = []
        cycle(at: 1.0)
        XCTAssertEqual(engine.reads.count, asked, "the window is off screen: nothing is asked of the engine")
    }

    func testOnlyAppliedWindowsGetTheirKeyStateRead() {
        makeLoop()
        scan.windows = [window(1), window(2, maximized: false)]
        cycle(at: 0)
        cycle(at: 0.5)
        cycle(at: 1.0)
        XCTAssertEqual(engine.reads.last?.windows, [1],
                       "the un-maximized window the scan sees is not ours to read; the applied one is, from the cycle after the apply lands")
    }

    func testAKeyStateTransitionIsAppliedAgainOnTheSpot() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        cycle(at: 0.75)                                // the first read: the baseline, not a transition
        engine.keyStates[1] = true                     // focus-in: the transition is the undo
        cycle(at: 1.0)
        XCTAssertEqual(engine.calls.last, FakeEngine.Call(pid: pid, windows: [1], restoring: false),
                       "the cycle that reads the transition is the cycle that asks for the change back")
        XCTAssertEqual(logs.filter { $0 == "applying 1" }.count, 2, "each apply is said")
    }

    func testAWindowWhoseFocusKeepsFlippingIsLeftAloneAndSaidOnce() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        var key = false
        var at: TimeInterval = 0.75
        while at <= 5.0 {                              // every read a transition: the budget's reason
            engine.keyStates[1] = key
            key.toggle()
            cycle(at: at)
            at += 0.25
        }
        XCTAssertEqual(engine.calls.filter { !$0.restoring }.count, 4, "the first apply plus three strikes")
        XCTAssertEqual(logs.filter { $0.hasPrefix("left alone (kept undoing) 500 1") }.count, 1,
                       "the window is named once, not every scan")
    }

    func testKeyReadsAreFlooredAtTheKeyReadInterval() {
        makeLoop(keyReadInterval: 2)
        scan.windows = [window()]
        cycle(at: 0)          // seen: not applied yet, so nothing is asked
        cycle(at: 0.5)        // the apply lands this cycle: the ask comes on the cycle after it
        cycle(at: 0.75)       // the first ask
        cycle(at: 2.5)        // 1.75 s later: inside the floor, no ask
        cycle(at: 2.75)       // the floor has passed: asked again
        XCTAssertEqual(engine.reads.count, 2, "one ask at 0.75 and one at 2.75, none in between")
    }

    func testAFocusKickReassertsWithoutAKeyRead() {
        makeLoop(keyReadInterval: 2)
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)                                   // applied
        cycle(at: 0.75)                                  // the first (timer) read
        let readsBefore = engine.reads.count
        let appliesBefore = engine.calls.filter { !$0.restoring }.count
        loop.kick()                                      // a focus change: the repaint event itself
        loop.step()                                      // one serial queue: the kick's cycle runs first
        XCTAssertEqual(engine.reads.count, readsBefore,
                       "a kick does not read: at focus-in the app is busy and the read would time out")
        XCTAssertEqual(engine.calls.filter { !$0.restoring }.count, appliesBefore + 1,
                       "the kick re-asserts the applied window anyway — the repaint has to be answered")
    }

    func testAFlooredReassertReappliesAppliedWindowsWithNoKeyRead() {
        // The tab-open fix (2026-10-21): a change an app silently undid — and a busy app the key
        // read cannot reach — is asked for again on a floored re-assert cycle, which does no read.
        makeLoop(keyReadInterval: 2, reassertInterval: 1.0)
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)                                   // applied
        cycle(at: 0.75)                                  // timer path: the one key read
        let appliesBefore = engine.calls.filter { !$0.restoring }.count
        let readsBefore = engine.reads.count
        XCTAssertEqual(readsBefore, 1, "the timer path read once before the re-assert floor passed")
        cycle(at: 1.6)                                   // past the 1 s re-assert floor
        XCTAssertEqual(engine.calls.filter { !$0.restoring }.count, appliesBefore + 1,
                       "the applied window is re-asserted on the floored cycle")
        XCTAssertEqual(engine.reads.count, readsBefore, "a re-assert cycle does no key read")
    }

    func testKickedFocusFlipsKeepTheWindowInService() {
        makeLoop(keyReadInterval: 2)
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)                                   // applied
        var at: TimeInterval = 0.75
        while at <= 5.0 {                                // 18 app switches, each a focus kick
            clock.now = at
            loop.kick()                                  // a focus change: the user's own switch
            loop.step()                                  // barrier: the kick's cycle ran
            at += 0.25
        }
        XCTAssertEqual(engine.calls.filter { !$0.restoring }.count, 19,
                       "the first apply plus a re-assert on each of the 18 kicks — no key read, no baseline exception")
        XCTAssertEqual(logs.filter { $0.hasPrefix("left alone") }.count, 0,
                       "app switching is not a flap war: the undo budget is not burned on the user's own switching")
    }

    func testASteadyKeyStateAsksNothingOfTheTracker() {
        makeLoop()
        scan.windows = [window()]
        cycle(at: 0)
        cycle(at: 0.5)
        cycles(from: 0.75, to: 2.0)
        XCTAssertEqual(engine.calls.filter { !$0.restoring }.count, 1, "a steady read is not an undo, in either state")
    }

    // MARK: - the log the engine writes

    /// The engine reports every refusal, on every scan. These are the lines that would print four
    /// times a second, forever.
    func testAPermanentRefusalOfOneProcessIsSaidOnce() {
        makeLoop()
        for _ in 1...5 { forward.say("skipped (not AppKit) 500 1") }
        forward.say("skipped (not AppKit) 500 2 3")     // same process, other windows: still known
        forward.say("skipped (not AppKit) 600 1")       // a different process is news
        XCTAssertEqual(logs, ["skipped (not AppKit) 500 1", "skipped (not AppKit) 600 1"])
    }

    func testAnEngineFailureIsSaidOncePerReason() {
        makeLoop()
        for _ in 1...4 { forward.say("engine failed 500 1: task port denied for 500") }
        forward.say("engine failed 500 1: no addresses")   // a different reason is news
        XCTAssertEqual(logs, ["engine failed 500 1: task port denied for 500",
                              "engine failed 500 1: no addresses"])
    }

    func testADeferredBatchIsSaidOnceAndAChangedBatchIsNews() {
        makeLoop()
        for _ in 1...8 { forward.say("skipped (not parked) 500 1") }   // busy app: normal, and boring
        forward.say("skipped (not parked) 500 1 2")                    // another window joined: news
        XCTAssertEqual(logs, ["skipped (not parked) 500 1", "skipped (not parked) 500 1 2"])
    }

    func testAChangeThatHappenedIsAlwaysSaid() {
        makeLoop()
        for _ in 1...3 { forward.say("applying 1") }
        XCTAssertEqual(logs, ["applying 1", "applying 1", "applying 1"])
    }

    // MARK: - starting, stopping, overlapping

    func testStopRestoresWhatWasAppliedAndShutsTheEngineDownOnce() {
        makeLoop()
        scan.windows = [window(1), window(2)]
        cycle(at: 0)
        cycle(at: 0.5)
        XCTAssertEqual(engine.calls.count, 1)
        loop.stop()
        XCTAssertEqual(engine.calls, [
            FakeEngine.Call(pid: pid, windows: [1, 2], restoring: false),
            FakeEngine.Call(pid: pid, windows: [1, 2], restoring: true),
        ], "the windows we changed, in one batch")
        XCTAssertEqual(engine.shutdowns, 1)
        XCTAssertEqual(statuses.last, 0, "the menu says nothing is changed after a stop")
        loop.stop()
        XCTAssertEqual(engine.shutdowns, 1, "shutdown exactly once")
        XCTAssertEqual(engine.calls.filter { $0.restoring }.count, 1)
    }

    func testAKickRunsACycleWithoutWaitingForTheTimer() {
        makeLoop()
        scan.windows = []
        let before = scan.calls
        loop.kick()
        loop.step()   // one serial queue: the kick's cycle runs before this sync one settles
        XCTAssertGreaterThanOrEqual(scan.calls, before + 2, "the kick was a cycle, and the step is the next")
    }

    func testAKickAfterStopRunsNothing() {
        makeLoop()
        scan.windows = []
        loop.stop()
        let before = scan.calls
        loop.kick()
        loop.step()
        XCTAssertEqual(scan.calls, before, "a stop is the end: a focus event after it is ignored")
    }

    func testStoppingANewLoopShutsTheEngineDownOnceAndChangesNothing() {
        makeLoop()
        loop.stop()
        XCTAssertEqual(engine.calls, [])
        XCTAssertEqual(engine.shutdowns, 1)
    }

    func testCyclesNeverOverlapEvenWhenTheEngineIsSlow() {
        makeLoop(interval: 0.02, realClock: true)
        engine.slow = 0.1
        scan.windows = [window()]
        engine.deferred = [1]     // keep asking, so every cycle calls the engine
        loop.start()
        Thread.sleep(forTimeInterval: 3.0)
        loop.stop()
        XCTAssertGreaterThanOrEqual(engine.calls.count, 3, "the timer ran while the engine was slow")
        XCTAssertEqual(engine.maxConcurrent, 1, "one cycle at a time, on one serial queue")
    }

    func testTheTimerRunsCyclesOnItsOwn() {
        makeLoop(interval: 0.05)
        scan.windows = []
        loop.start()
        let before = scan.calls
        Thread.sleep(forTimeInterval: 0.3)
        loop.stop()
        XCTAssertGreaterThan(scan.calls, before + 3, "the timer scans by itself")
    }
}
