import Foundation

/// The status the menu is shown, passed on only when it changes.
///
/// The scan loop reports what it has changed on every cycle — four a second, most of them saying the
/// same as the last. The menu is a SwiftUI view, and telling it that it changed makes it redraw the
/// menu bar item; that redraw, not the scan, is what the app spends its CPU on while it is idle. A
/// status that has not moved is therefore not a report.
public final class StatusPublisher {
    public private(set) var status: EngineStatus

    private let publish: (EngineStatus) -> Void

    public init(_ initial: EngineStatus, publish: @escaping (EngineStatus) -> Void) {
        status = initial
        self.publish = publish
    }

    /// Stores and publishes `next`, unless it is the status it already has.
    public func set(_ next: EngineStatus) {
        guard next != status else { return }
        status = next
        publish(next)
    }
}
