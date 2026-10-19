import XCTest
@testable import NoBorderLogic

/// What the menu is told, and only when it is news.
///
/// The scan loop runs four times a second and reports the number of windows it has changed on every
/// cycle, most of them saying the same thing as the last. The app's menu is a SwiftUI view, and
/// telling that view it changed makes it redraw the menu bar item — the measured cost of one such
/// redraw chain (`MenuBarExtraController` → `NSStatusItem _updateReplicants` → `_adjustLength`) is
/// most of the app's CPU while it is doing nothing else. So the same status is not a report.
final class StatusPublisherTests: XCTestCase {
    func testTheSameStatusIsNotPublishedAgain() {
        var published: [EngineStatus] = []
        let subject = StatusPublisher(.off) { published.append($0) }

        subject.set(.running(windows: 3))
        subject.set(.running(windows: 3))
        subject.set(.running(windows: 3))

        XCTAssertEqual(published, [.running(windows: 3)],
                       "the loop asks four times a second; a status that has not moved is news once")
        XCTAssertEqual(subject.status, .running(windows: 3),
                       "the current status is still the one it holds")
    }

    func testAWindowCountThatMovesIsPublished() {
        var published: [EngineStatus] = []
        let subject = StatusPublisher(.running(windows: 0)) { published.append($0) }

        subject.set(.running(windows: 1))
        subject.set(.running(windows: 0))
        subject.set(.stopping)
        subject.set(.off)

        XCTAssertEqual(published, [.running(windows: 1), .running(windows: 0), .stopping, .off],
                       "every window the app changes, and every state the user is told about, is news")
    }
}
