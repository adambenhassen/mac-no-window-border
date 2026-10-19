import Darwin
import XCTest
@testable import NoBorderEngine

/// The engine's decisions, with a fake runner in place of the Mach side: which call script a batch
/// of windows turns into, what is logged for each outcome, and what is refused. Running the script
/// in a real process is tests/e2e.sh's native path, which checks the same log lines against pixels.
final class NativeEngineTests: XCTestCase {
    private final class FakeRunner: NativeEngine.Runner {
        struct Call: Equatable { let pid: pid_t; let script: RemoteScript }
        var calls: [Call] = []
        var probes: [pid_t] = []
        var shutdowns = 0
        /// What a call script returns, and the word the AppKit probe reports.
        var outcome = CallOutcome(result: .ok, word: nil)
        var appKitWord: UInt64? = 0x0000_7FA0_0000_1234
        /// Set to make the AppKit probe itself fail to run.
        var probeOutcome: CallOutcome?

        func run(_ script: RemoteScript, in pid: pid_t) -> CallOutcome {
            if script.appKitProbe {
                probes.append(pid)
                return probeOutcome ?? CallOutcome(result: .ok, word: appKitWord)
            }
            calls.append(Call(pid: pid, script: script))
            return outcome
        }

        func shutdown() { shutdowns += 1 }
    }

    private var runner: FakeRunner!
    private var logs: [String]!
    private var engine: NativeEngine!

    override func setUp() {
        runner = FakeRunner()
        logs = []
        engine = NativeEngine(runner: runner) { self.logs.append($0) }
    }

    func testApplyRunsOneCallScriptForTheWholeBatch() {
        engine.apply(pid: 42, windows: [3, 5])
        XCTAssertEqual(runner.calls, [FakeRunner.Call(pid: 42, script: RemoteScript.applied(windowNumbers: [3, 5]))])
    }

    func testRestoreRunsOneCallScriptForTheWholeBatch() {
        engine.restore(pid: 42, windows: [3, 5])
        XCTAssertEqual(runner.calls, [FakeRunner.Call(pid: 42, script: RemoteScript.restored(windowNumbers: [3, 5]))])
    }

    func testAnEmptyBatchIsNotACall() {
        engine.apply(pid: 42, windows: [])
        engine.restore(pid: 42, windows: [])
        XCTAssertEqual(runner.calls, [])
        XCTAssertEqual(logs, [])
    }

    func testApplyingIsLoggedOncePerBatchWithItsWindows() {
        engine.apply(pid: 42, windows: [3, 5])
        XCTAssertEqual(logs, ["applying 3 5"])
        engine.apply(pid: 42, windows: [7])
        XCTAssertEqual(logs, ["applying 3 5", "applying 7"])
    }

    func testRestoringIsLoggedOncePerBatchWithItsWindows() {
        engine.restore(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["restoring 3"])
    }

    func testAnAppThatIsNotParkedIsDeferredAndNotClaimedAsChanged() {
        runner.outcome = CallOutcome(result: .notParked, word: nil)
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["skipped (not parked) 42 3"])
        XCTAssertFalse(logs.contains { $0.hasPrefix("applying") }, "the call never ran")
    }

    func testAFaultIsReportedAsAFailedEngineNotAsAChange() {
        runner.outcome = CallOutcome(result: .faulted, word: nil)
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["engine failed 42 3"])
    }

    func testAReasonFromTheRunnerIsCarriedIntoTheLog() {
        runner.outcome = CallOutcome(result: .failed("task port denied"), word: nil)
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["engine failed 42 3: task port denied"])
    }

    func testATargetWithoutAppKitIsRefusedAndItsWindowsNeverTouched() {
        runner.appKitWord = 0
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["skipped (not AppKit) 42 3"])
        XCTAssertEqual(runner.calls, [])
    }

    func testTheAppKitCheckRunsOncePerTargetAndIsForgottenOnShutdown() {
        engine.apply(pid: 42, windows: [3])
        engine.apply(pid: 42, windows: [4])
        engine.apply(pid: 99, windows: [5])
        XCTAssertEqual(runner.probes, [42, 99])
        engine.shutdown()
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(runner.probes, [42, 99, 42], "shutdown releases what the engine knew about a pid")
    }

    func testShutdownIsForwardedToTheRunnerThatHoldsTheTaskPorts() {
        engine.apply(pid: 42, windows: [3])
        engine.shutdown()
        XCTAssertEqual(runner.shutdowns, 1)
    }

    func testATargetWhoseProbeCannotRunIsNotJudged() {
        // A probe that could not run says nothing about AppKit: the batch is reported for the reason
        // the runner gave, and the next scan asks again.
        runner.probeOutcome = CallOutcome(result: .notParked, word: nil)
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(logs, ["skipped (not parked) 42 3"])
        engine.apply(pid: 42, windows: [3])
        XCTAssertEqual(runner.probes, [42, 42], "the judgement is not made from a run that did not happen")
        XCTAssertEqual(runner.calls, [], "and the windows were not touched on the way")
    }

    func testARefusedTargetIsRememberedAcrossBatches() {
        runner.appKitWord = 0
        engine.apply(pid: 42, windows: [3])
        engine.apply(pid: 42, windows: [4])
        XCTAssertEqual(runner.probes, [42], "the answer does not change between scans")
        // Every refusal is reported: the engine has no policy of its own about how often to say it,
        // and deduplicating a permanent one in the app's log is the scan loop's job (Task 10).
        XCTAssertEqual(logs, ["skipped (not AppKit) 42 3", "skipped (not AppKit) 42 4"])
    }
}
