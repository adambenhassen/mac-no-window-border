import Darwin

/// What one call in one target produced: the outcome of the run, and the word the script handed back
/// (nil for a script that writes none, and for a run that did not finish).
public struct CallOutcome: Equatable {
    public var result: RunResult
    public var word: UInt64?

    public init(result: RunResult, word: UInt64?) {
        self.result = result
        self.word = word
    }
}

/// The three changes, made inside the app's own main thread in one stop: no outline/shadow, square
/// corners, no titlebar rim.
///
/// The engine decides *what* a batch of windows becomes — one call script per batch, so a window is
/// never half-changed — and what is said about each outcome. Running that script in a live process
/// is the runner's job, which keeps the decisions testable without a task port: the debugger
/// entitlement does not reach the test bundle.
public final class NativeEngine: ChangeEngine {
    public typealias Log = (String) -> Void

    /// One call script, in one process.
    public protocol Runner {
        func run(_ script: RemoteScript, in pid: pid_t) -> CallOutcome
        /// Drop everything held on other processes.
        func shutdown()
    }

    private let runner: Runner
    private let log: Log
    /// Whether each process we have asked has an application object. A process without one is refused
    /// for good: it has no AppKit windows, and the generated code would answer it with nothing at
    /// all — a window that looks half-changed and a log line that says it was applied.
    private var appKit: [pid_t: Bool] = [:]

    public init(runner: Runner, log: @escaping Log) {
        self.runner = runner
        self.log = log
    }

    /// The engine that talks to real processes.
    public convenience init(log: @escaping Log) {
        self.init(runner: ProcessRunner(), log: log)
    }

    public func apply(pid: pid_t, windows: [UInt32]) {
        change(.applied(windowNumbers: windows), pid: pid, windows: windows, verb: "applying")
    }

    public func restore(pid: pid_t, windows: [UInt32]) {
        change(.restored(windowNumbers: windows), pid: pid, windows: windows, verb: "restoring")
    }

    public func shutdown() {
        appKit.removeAll()
        runner.shutdown()
    }

    deinit { shutdown() }

    private func change(_ script: RemoteScript, pid: pid_t, windows: [UInt32], verb: String) {
        guard !windows.isEmpty else { return }   // an empty batch is not a stop in someone's thread
        let batch = windows.map(String.init).joined(separator: " ")
        guard let known = appKit[pid] else {
            let probe = runner.run(.appKitProbe(), in: pid)
            guard probe.result == .ok else { report(probe, pid: pid, batch: batch, verb: verb); return }
            let isAppKit = (probe.word ?? 0) != 0
            appKit[pid] = isAppKit
            guard isAppKit else {
                log("skipped (not AppKit) \(pid) \(batch)")
                return
            }
            change(script, pid: pid, windows: windows, verb: verb)   // now known: make the change
            return
        }
        guard known else {
            log("skipped (not AppKit) \(pid) \(batch)")
            return
        }
        report(runner.run(script, in: pid), pid: pid, batch: batch, verb: verb)
    }

    /// The one place that decides what a run means. A change that happened is named by what it is
    /// (`applying`/`restoring`); a target we could not use is named by why, and is left for the
    /// next scan; anything else is the engine's own failure.
    private func report(_ outcome: CallOutcome, pid: pid_t, batch: String, verb: String) {
        switch outcome.result {
        case .ok:
            log("\(verb) \(batch)")
        case .notParked:
            log("skipped (not parked) \(pid) \(batch)")
        case .faulted:
            log("engine failed \(pid) \(batch)")
        case .timedOut:
            log("engine failed \(pid) \(batch): no completion flag")
        case .failed(let reason):
            log("engine failed \(pid) \(batch): \(reason)")
        }
    }
}

/// Runs call scripts in real processes: one task port and one executor per pid, kept between batches,
/// and the target's main thread read fresh for every run — the park check is about right now.
final class ProcessRunner: NativeEngine.Runner {
    private struct Target {
        let task: TargetTask
        let executor: RemoteExecutor
    }

    private var targets: [pid_t: Target] = [:]
    /// Addresses in the shared cache are the same for every process in one boot, so this is resolved
    /// once.
    private var addresses = AddressTable.current()

    func run(_ script: RemoteScript, in pid: pid_t) -> CallOutcome {
        guard let addresses = addresses else { return CallOutcome(result: .failed("no addresses"), word: nil) }
        guard let target = target(for: pid) else {
            return CallOutcome(result: .failed("task port denied for \(pid)"), word: nil)
        }
        guard let main = target.task.mainThread() else {
            return CallOutcome(result: .failed("no main thread"), word: nil)
        }
        let (result, _) = target.executor.run(script, on: main, addresses: addresses)
        return CallOutcome(result: result, word: script.appKitProbe ? target.executor.lastResultWord : nil)
    }

    func shutdown() {
        for target in targets.values {
            target.executor.releaseScratch()
            target.task.close()
        }
        targets.removeAll()
    }

    private func target(for pid: pid_t) -> Target? {
        if let known = targets[pid] { return known }
        guard let task = try? TargetTask(pid: pid) else { return nil }
        let target = Target(task: task, executor: RemoteExecutor(task: task))
        targets[pid] = target
        return target
    }
}
