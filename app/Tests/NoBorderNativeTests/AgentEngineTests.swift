import XCTest
@testable import NoBorderNative

/// The resident-agent engine's retry policy. A refusal that is a fact about the process (a
/// sandboxed app may never `bootstrap_register`: err 1100) is not retried — each retry runs the
/// entry again and leaves its pages mapped in the target (measured live 2026-10-22: new Outlook
/// was retried every ~2 s, ~3400 times, ~110 MB of agent pages).
final class AgentEngineTests: XCTestCase {
    func testSandboxRefusalIsPermanent() {
        XCTAssertTrue(AgentEngine.isPermanentRefusal(installErr: 1100), "BOOTSTRAP_NOT_PRIVILEGED")
    }

    func testMomentaryRefusalsAreRetried() {
        XCTAssertFalse(AgentEngine.isPermanentRefusal(installErr: nil), "not-parked / timed-out carry no err")
        XCTAssertFalse(AgentEngine.isPermanentRefusal(installErr: 0), "no blob error")
        XCTAssertFalse(AgentEngine.isPermanentRefusal(installErr: 1101), "a name collision: the retry gets a fresh nonce")
    }
}
