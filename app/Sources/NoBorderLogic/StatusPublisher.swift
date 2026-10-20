import Foundation

/// The status the menu is shown, passed on only when it changes.
///
/// The scan loop reports what it has changed on every cycle — four a second, most of them saying the
/// same as the last. The menu is a SwiftUI view, and telling it that it changed makes it redraw the
/// menu bar item; that redraw, not the scan, is what the app spends its CPU on while it is idle. A
/// status that has not moved is therefore not a report.
///
/// The loop's reports arrive on the main queue, so the report a loop makes as it is being stopped
/// lands after the stop is over. `report` passes a status on only while a loop is live; the status
/// the manager decides for itself — off — goes through `set` and is never dropped.
public final class StatusPublisher {
    public private(set) var status: EngineStatus

    private let publish: (EngineStatus) -> Void
    /// A report is news about a run. Once that run is over, nothing it queued is.
    private var live = false

    public init(_ initial: EngineStatus, publish: @escaping (EngineStatus) -> Void) {
        status = initial
        self.publish = publish
    }

    /// A loop is running: its reports are news.
    public func started() { live = true }

    /// The run is over: the reports it queued while dying are not.
    public func stopped() { live = false }

    /// What the running loop reports. Dropped when no loop is running.
    public func report(_ next: EngineStatus) {
        guard live else { return }
        set(next)
    }

    /// Stores and publishes `next`, unless it is the status it already has.
    public func set(_ next: EngineStatus) {
        guard next != status else { return }
        status = next
        publish(next)
    }
}
