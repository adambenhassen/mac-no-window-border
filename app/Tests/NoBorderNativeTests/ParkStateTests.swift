import Darwin
import XCTest
@testable import NoBorderNative

/// The request-bits gate in `parkState(from:)`: the entry must refuse a `mach_msg2` whose
/// request carries `MACH_RCV_TIMEOUT` (0x100, this SDK — 0x10 is `MACH_SEND_TIMEOUT`). The entry
/// restarts the parked call from its start; the raw `mach_msg2_trap` rejects a timed receive
/// with `MACH_RCV_INVALID_ARGUMENTS` (0x10004013) — reproduced in-process and by the stub's own
/// absorber, 2026-10-20 — and CoreFoundation's run-loop-port handler tolerates only
/// {success, TOO_LARGE, TIMED_OUT}, so that kr reaches its "unexpected kr" trap and the app
/// dies (five 1 ms-timer hostapps caught by `probe watch` with the identical kr, and live
/// Vivaldi). Servability of real AppKit parks — the other half of the rule — is gated by
/// tests/probe.sh and tests/e2e.sh, which park and drive live hostapps; a synthetic state
/// cannot walk the real run-loop frames.
final class ParkStateTests: XCTestCase {

    private static let task = try! TargetTask(pid: getpid())   // our own task; nothing is injected

    /// A state sitting in the port trap, with the given request in x1 and no walkable frames:
    /// the gate decides at the request bits, before the frame walk can matter.
    private static func state(inTrapWithRequest request: UInt64) -> arm_thread_state64_t {
        var state = arm_thread_state64_t()
        state.__pc = Self.trapAddress
        state.__sp = 0
        state.__fp = 0
        state.__x.1 = request
        return state
    }

    private static let trapAddress: UInt64 = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "mach_msg2_trap") else {
            XCTFail("mach_msg2_trap is not resolvable in this process")
            return 0
        }
        return UInt64(bitPattern: Int64(Int(bitPattern: symbol)))
    }()

    /// `MACH_RCV_MSG` = 0x2, `MACH_RCV_TIMEOUT` = 0x100 (`mach_msg_option_t`, this SDK).
    private func assertRefused(_ request: UInt64, _ message: String, file: StaticString = #filePath,
                               line: UInt = #line) {
        XCTAssertEqual(try Self.task.parkState(from: Self.state(inTrapWithRequest: request)),
                       ParkState.running, message, file: file, line: line)
    }

    func testTimedReceiveRequestIsRefused() throws {
        assertRefused(0x5070_00906, "CF's timed servicing park: the overmach shim's request + MACH_RCV_TIMEOUT")
        assertRefused(0x102, "MACH_RCV_MSG|MACH_RCV_TIMEOUT, the minimal timed form")
    }

    func testRequestWithoutReceiveIsRefused() throws {
        assertRefused(0x1, "a send alone is not a run-loop port wait")
        assertRefused(0, "no request at all")
    }
}
