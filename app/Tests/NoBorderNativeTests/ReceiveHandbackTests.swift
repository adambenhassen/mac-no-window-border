import Darwin
import XCTest
@testable import NoBorderNative

final class ReceiveHandbackTests: XCTestCase {
    private func state(answer: UInt64) -> arm_thread_state64_t {
        var state = arm_thread_state64_t()
        state.__x.0 = answer
        state.__x.1 = 0x507000806
        state.__x.2 = 0x200000000
        state.__sp = 0x16D580000
        state.__pc = 0x180001008
        return state
    }

    func testCompletedReceiveKeepsItsResultAndReturnAddress() throws {
        // Replacing success with timeout loses a received timer wake. Restarting any completed
        // receive can overwrite its buffer before CoreFoundation has consumed the message.
        for answer: UInt64 in [0, 0x10004003, 0x10004004, 0x10004013] {
            let original = state(answer: answer)
            let back = try XCTUnwrap(ReceiveHandback.state(from: original, instructionBeforePC: 0xD4001001))
            XCTAssertEqual(back.__x.0, answer)
            XCTAssertEqual(back.__pc, 0x180001008)
            XCTAssertEqual(back.__sp, original.__sp)
            XCTAssertEqual(back.__x.1, original.__x.1)
            XCTAssertEqual(back.__x.2, original.__x.2)
        }
    }

    func testOnlyInterruptedReceiveBecomesTimeout() throws {
        let back = try XCTUnwrap(ReceiveHandback.state(from: state(answer: 0x10004005),
                                                       instructionBeforePC: 0xD4001001))
        XCTAssertEqual(back.__x.0, 0x10004003)
        XCTAssertEqual(back.__pc, 0x180001008)
    }

    func testInFlightBufferPointerIsNotAResult() {
        XCTAssertNil(ReceiveHandback.state(from: state(answer: 0x16D58D168),
                                           instructionBeforePC: 0xD4001001))
    }

    func testAResultIsAcceptedOnlyAfterTheTrapInstruction() {
        for instruction: UInt32 in [0x928005D0, 0xD65F03C0, 0] {
            XCTAssertNil(ReceiveHandback.state(from: state(answer: 0), instructionBeforePC: instruction))
        }
    }
}
