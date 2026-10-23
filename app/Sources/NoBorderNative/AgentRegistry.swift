import Foundation

/// A durable record of installed agents, so a controller that restarts — including after an UNCLEAN
/// exit (SIGKILL/crash), whose teardown never ran — can find an agent it or a prior instance left
/// resident and ADOPT it, instead of installing a second agent that stacks another run-loop observer
/// in the target (the accumulation that degrades the target over repeated restarts).
///
/// Only BOOTSTRAP agents are recorded. A planted (sandbox) agent's channel is a Mach send right that
/// dies with the controller, so it cannot be looked up or adopted across a restart; its record would
/// be useless, so none is written.
///
/// The record keeps the agent's nonce rendezvous name (installs use a fresh name each time — there is
/// no `bootstrap_delete`, so a fixed name would collide — and a relaunched controller cannot guess it,
/// which is exactly why it must be persisted) and its page base (so the adopting controller can still
/// tear it down cleanly). Keyed by pid plus the process start-time: pids are reused, and a record
/// whose start-time no longer matches the live process is stale and ignored.
struct AgentRecord: Codable {
    let pid: Int32
    let start: UInt64     // kernel process start time in microseconds (sec*1e6+usec); guards pid reuse
    let service: String   // the nonce rendezvous name to look the agent up by
    let base: UInt64      // the agent's page base, for a clean teardown
}

/// The on-disk registry. All access is best-effort: a registry that cannot be read or written must
/// never stop the controller from managing windows — the worst case without it is the old behavior
/// (a second install), not a crash.
enum AgentRegistry {
    /// `NOBORDER_REGISTRY_PATH` overrides the path (tests point it at a temp file so they never touch
    /// the real controller's registry); otherwise it sits beside the app's other state.
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["NOBORDER_REGISTRY_PATH"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/macos-no-window-border/agents.json")
    }

    /// Serialize every read-modify-write across processes AND threads with an exclusive `flock` on a
    /// DEDICATED lock file — never the JSON file itself, whose inode the atomic write swaps out from
    /// under any lock (two controllers can briefly coexist if the user relaunches before the old one
    /// exits; `NSLock` would not protect against that). Best-effort: if the lock can't be taken, the
    /// work still runs — a lost barrier reverts to the old behavior, it never blocks managing windows.
    private static func withLock<T>(_ body: () -> T) -> T {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appendingPathComponent("agents.lock").path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return body() }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN); close(fd) }
        return body()
    }

    private static func load() -> [AgentRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([AgentRecord].self, from: data)) ?? []
    }

    private static func save(_ records: [AgentRecord]) {
        // Atomic: Foundation writes an auxiliary file and renames it in, so a crash mid-write can never
        // leave truncated JSON that the next controller would decode as empty (and lose the barrier).
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: url, options: .atomic) }
    }

    /// The record for a pid, if any (the caller checks the start-time against the live process).
    static func record(for pid: Int32) -> AgentRecord? {
        withLock { load().first { $0.pid == pid } }
    }

    /// Replace any prior record for this pid (a new install supersedes an older one).
    static func put(_ rec: AgentRecord) {
        withLock {
            var records = load()
            records.removeAll { $0.pid == rec.pid }
            records.append(rec)
            save(records)
        }
    }

    /// Drop the record for a pid (clean teardown, or a record proven stale).
    static func remove(pid: Int32) {
        withLock {
            var records = load()
            let before = records.count
            records.removeAll { $0.pid == pid }
            if records.count != before { save(records) }
        }
    }
}
