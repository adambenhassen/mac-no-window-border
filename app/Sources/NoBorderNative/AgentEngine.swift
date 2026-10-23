import Foundation
import NoBorderEngine

/// The engine that runs on the resident agent: apply/restore are 24–64-byte messages to a
/// CFMachPort source already in the app's run loop — no thread entry, no park, ~ms round
/// trips. Deferrals are the agent's own (P1c: the mode gate answers `deferred`, the wake
/// timer drains), which is the contract ScanLoop already honors: a deferred window is
/// handed back and asked for on a later scan.
///
/// The key reads stay on the shipped path (NativeEngine): the in-app key observers are the
/// next step, and a key read is one floored (2 s) remote-exec per app, not per change.
public final class AgentEngine: ChangeEngine {
    private final class Holder {
        let client: BlobClient
        /// The target process's start time: a holder is bound to the process, not to the
        /// pid it once named (codex review 2026-10-21 — pids are reused).
        let start: UInt64?
        var base: UInt64?
        /// When the last FAILED install was attempted (nanotime). A failed install is a fact
        /// about a moment — a busy app answers `entry-not-parked`/`entry-timed-out` (measured
        /// live 2026-10-21: iTerm and a web-app wrapper, both busy at first scan) — caching it
        /// forever locks the app out for the process's life. Retries are floored so a busy
        /// target costs one dispatched entry per floor, not one per scan.
        var failedInstallAt: TimeInterval?
        /// Install attempts so far: the stop budget ramps (2 s, then 8 s) so a hot-mained
        /// app gets a real chance to drain its queue without the first attempt ever
        /// stalling the scan loop for eight seconds.
        var attempts = 0
        /// The install refusal is the process's nature, not a moment (`isPermanentRefusal`):
        /// never retried for this process.
        var permanentlyRefused = false
        init(_ client: BlobClient, start: UInt64?) { self.client = client; self.start = start }
    }

    /// The floor on install retries against a target that refused (seconds).
    private static let installRetryFloor: TimeInterval = 2.0

    /// Whether the blob's `err` from an entry that ran without publishing ready rules the process
    /// out for its whole life. BOOTSTRAP_NOT_PRIVILEGED (1100): an App-Sandboxed process may not
    /// `bootstrap_register` (measured 2026-10-21 on new Outlook). Every retry runs the entry again
    /// and leaves its pages mapped (a run entry is not freed — publication is not transactional),
    /// so retrying it every floor grew Outlook by ~110 MB in a day (measured 2026-10-22).
    static func isPermanentRefusal(installErr: UInt64?) -> Bool {
        installErr == 1100
    }

    /// The kernel's start time for a live pid; nil when the pid is gone.
    private static func procStart(_ pid: pid_t) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = proc_bsdinfo()
        var size = MemoryLayout<proc_bsdinfo>.size
        let len = u_int(mib.count)
        let kr = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress!, len, &info, &size, nil, 0)
        }
        guard kr == 0, size > 0 else { return nil }
        return UInt64(info.pbi_start_tvsec)
    }

    private let lock = NSLock()
    private var holders: [pid_t: Holder] = [:]
    /// Op-result diagnostics said once per (pid, kind): the engine's deferral line says a
    /// window came back, not WHY it came back — `nil` (the transport), `deferred` (the agent's
    /// mode gate), `notFound` (the window lookup) are different failures with different fixes.
    private var saidOp: Set<String> = []
    /// Failed install attempts per pid: drives the ramped stop budget (see `holderFor`).
    private var installAttempts: [pid_t: Int] = [:]
    private let keyReader = NativeEngine(log: { _ in })
    /// Refusals go here once per fact. The scan loop's own dedup (`ScanLoop.say`) collapses the
    /// per-cycle repeats of the same line; this is the engine speaking, as every engine does.
    private let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    @discardableResult
    public func apply(pid: pid_t, windows: [UInt32], buttonsHidden: Bool) -> [UInt32] {
        guard let holder = holderFor(pid) else { return windows }
        var again = [UInt32]()
        for wid in windows {
            let status = holder.client.op(apply: true, wid: wid, buttons: buttonsHidden ? 7 : 0)
            // The agent's op-table rows say nothing arrived; the client knows what came back.
            // Every kind is named once per (pid, kind): `nil` carries the client's stage, the
            // rest are the agent's own answers.
            let kind = status.map { String(describing: $0) }
                ?? "nil(\(holder.client.lastOpStage ?? "?"))"
            if saidOp.insert("\(pid) \(kind)").inserted {
                log("op result \(pid) \(wid) \(kind)")
            }
            switch status {
            case .applied:
                // The change line, in the shipped engine's shape: said when the agent reports
                // the window changed, once per (pid, wid).
                if saidOp.insert("a \(pid) \(wid)").inserted { log("applying \(pid) \(wid)") }
            case .unsupported, .tableFull, .noOriginal, .restored:
                break   // a final answer: asking again asks for the same thing
            case .deferred, .notFound, .superseded, .none:
                again.append(wid)
            }
        }
        // The deferral line, in the shape ScanLoop's per-batch dedup knows: the agent answered
        // `deferred` (busy target, wake timer drains) or nothing at all (the transport is not
        // talking) — said once per set, like NativeEngine says `not-parked`.
        if !again.isEmpty {
            log("skipped (not parked) \(pid) " + again.map(String.init).joined(separator: " "))
        }
        return again
    }

    @discardableResult
    public func restore(pid: pid_t, windows: [UInt32]) -> [UInt32] {
        guard let holder = holderFor(pid) else { return windows }
        var again = [UInt32]()
        for wid in windows {
            let status = holder.client.op(apply: false, wid: wid)
            let kind = status.map { String(describing: $0) }
                ?? "nil(\(holder.client.lastOpStage ?? "?"))"
            if saidOp.insert("r \(pid) \(kind)").inserted {
                log("restore result \(pid) \(wid) \(kind)")
            }
            switch status {
            case .restored, .noOriginal, .applied, .unsupported, .tableFull:
                break
            case .deferred, .notFound, .superseded, .none:
                again.append(wid)
            }
        }
        if !again.isEmpty {
            log("skipped (not parked) \(pid) " + again.map(String.init).joined(separator: " "))
        }
        return again
    }

    public func keyWindows(pid: pid_t, windows: [UInt32]) -> [UInt32: Bool] {
        keyReader.keyWindows(pid: pid, windows: windows)
    }

    /// Release everything: remove every installed agent (P1d removal: the run loop loses
    /// the source, the pages go). Windows the tracker said were applied should be restored
    /// by the caller (the quit path restores) before this runs.
    public func shutdown() {
        lock.lock()
        let all = Array(holders.values)
        holders.removeAll()
        lock.unlock()
        for holder in all {
            if let base = holder.base {
                holder.client.removeAgent(base: base)
            }
        }
    }

    /// One client per pid; the agent installs on first use (a target that refuses the
    /// install hands its windows back — deferred, never dropped).
    /// Boot seconds, for the retry floor.
    private static func now() -> TimeInterval {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    private func holderFor(_ pid: pid_t) -> Holder? {
        let start = Self.procStart(pid)
        lock.lock()
        if let holder = holders[pid] {
            // Pid reuse (both starts known and different): the old process is gone and its
            // agent went with it. A start we cannot read is not evidence the process died —
            // killing a working holder over a sysctl hiccup would reinstall an agent whose
            // name is already registered.
            let reused = start != nil && holder.start != start
            if !reused && (holder.base != nil || holder.permanentlyRefused) {
                lock.unlock()
                return holder    // one client and one agent (or one final refusal) per process
            }
            // An install that timed out is ENQUEUED on the target's backlogged main queue and runs
            // when it drains. Keep this client (its pages persist) and poll `ready` each scan — never
            // recreate it (that would strand the enqueued entry and stack a second one). ensureAgent
            // here only reads the flag; it does not re-install. On give-up it floors the next fresh
            // attempt. (A busy app that parks also drains, so the poll usually adopts within seconds.)
            if !reused && holder.client.isPendingInstall {
                lock.unlock()
                holder.base = holder.client.ensureAgent()
                if holder.base == nil && !holder.client.isPendingInstall {
                    holder.failedInstallAt = Self.now()
                }
                return holder
            }
            // A refused install is a fact about a moment, not the process: a busy target
            // answers `entry-not-parked`/`entry-timed-out` and parks later (measured live
            // 2026-10-21 on iTerm and a web-app wrapper). Retries — a fresh client, a fresh
            // dispatched entry — are floored; inside the floor the windows go back deferred,
            // as every deferral does.
            if !reused, let at = holder.failedInstallAt, Self.now() - at < Self.installRetryFloor {
                lock.unlock()
                return holder
            }
            holders.removeValue(forKey: pid)
        }
        lock.unlock()
        guard let client = BlobClient(pid: pid) else {
            log("engine refused \(pid): no task port")
            return nil
        }
        let holder = Holder(client, start: start)
        // The stop budget ramps with the pid's failed attempts (2 s, then 8 s): Chromium's
        // main queue drains the dispatched entry in bursts, and the first attempt for a
        // fresh process should never hold the serial scan loop for eight seconds.
        let attempt = installAttempts[pid] ?? 0
        holder.base = client.ensureAgent(stopLimit: attempt == 0 ? 2.0 : 8.0)
        if holder.base == nil && client.isPendingInstall {
            // Not a refusal: a timed-out install or an adopt of a busy resident agent is still in
            // flight. The pending-poll branch above keeps this client and retries; no refusal, no ramp.
        } else if holder.base == nil {
            installAttempts[pid] = attempt + 1
            holder.failedInstallAt = Self.now()
            holder.permanentlyRefused = Self.isPermanentRefusal(installErr: client.lastInstallErr)
            log("engine refused \(pid): agent install refused: \(client.lastInstallFailure ?? "no report")"
                + (client.lastInstallErr.map { " err=\($0)" } ?? "")
                + (holder.permanentlyRefused ? " (sandboxed: not retried)" : ""))
        } else {
            installAttempts.removeValue(forKey: pid)
        }
        lock.lock()
        holders[pid] = holder
        lock.unlock()
        return holder
    }
}
