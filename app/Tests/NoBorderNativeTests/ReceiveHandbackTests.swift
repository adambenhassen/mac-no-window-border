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

    func testStalledReceiveUsesOnlyOneMillisecondOfTheEntryBudget() {
        var time: UInt64 = 0
        var reads = 0
        let pending = state(answer: 0x16D58D168)
        let back = ReceiveHandback.settle(from: pending, instructionBeforePC: 0xD4001001,
            entryDeadline: 250_000_000, now: { time }, interrupt: { true },
            readState: { reads += 1; return pending }, pause: { time += 500_000 })
        XCTAssertNil(back)
        XCTAssertEqual(time, 1_000_000, "a slow receive must not hold the target for the 250 ms entry hunt")
        XCTAssertEqual(reads, 2)
    }

    func testPollingHasACallLimitEvenWhenTheClockBarelyMoves() {
        var reads = 0
        let pending = state(answer: 0x16D58D168)
        let back = ReceiveHandback.settle(from: pending, instructionBeforePC: 0xD4001001,
            entryDeadline: 250_000_000, now: { 0 }, interrupt: { true },
            readState: { reads += 1; return reads < 20 ? pending : nil }, pause: {})
        XCTAssertNil(back)
        XCTAssertEqual(reads, 8, "do not repeatedly issue Mach IPCs while holding the target")
    }

    func testAReceiveThatFinishesAfterTheBudgetIsDeferred() {
        var time: UInt64 = 0
        let back = ReceiveHandback.settle(from: state(answer: 0x16D58D168), instructionBeforePC: 0xD4001001,
            entryDeadline: 250_000_000, now: { time }, interrupt: { true },
            readState: { time = 2_000_000; return self.state(answer: 0) }, pause: {})
        XCTAssertNil(back, "a delayed IPC must not be followed by more suspended preparation work")
    }

    func testExpiredEntryBudgetDoesNotInterruptEvenACompletedReceive() {
        let back = ReceiveHandback.settle(from: state(answer: 0), instructionBeforePC: 0xD4001001,
            entryDeadline: 100, now: { 100 }, interrupt: { XCTFail("expired"); return true },
            readState: { XCTFail("expired"); return nil }, pause: { XCTFail("expired") })
        XCTAssertNil(back)
    }

    func testSuccessfulReceiveDuringSettlingKeepsItsMessage() throws {
        var time: UInt64 = 0
        let back = try XCTUnwrap(ReceiveHandback.settle(from: state(answer: 0x16D58D168),
            instructionBeforePC: 0xD4001001, entryDeadline: 250_000_000, now: { time },
            interrupt: { true }, readState: { time = 50_000; return self.state(answer: 0) }, pause: {}))
        XCTAssertEqual(back.__x.0, 0)
        XCTAssertEqual(back.__pc, 0x180001008)
    }

    func testSettlingHonorsAnEarlierEntryDeadline() {
        var time: UInt64 = 0
        var reads = 0
        let pending = state(answer: 0x16D58D168)
        XCTAssertNil(ReceiveHandback.settle(from: pending, instructionBeforePC: 0xD4001001,
            entryDeadline: 100_000, now: { time }, interrupt: { true },
            readState: { reads += 1; return pending }, pause: { time += 50_000 }))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(time, 100_000)
    }

    func testAlreadyCompletedReceiveNeedsNoInterruptOrPolling() throws {
        let back = try XCTUnwrap(ReceiveHandback.settle(from: state(answer: 0),
            instructionBeforePC: 0xD4001001, entryDeadline: 250_000_000, now: { 0 },
            interrupt: { XCTFail("already completed"); return false },
            readState: { XCTFail("already completed"); return nil }, pause: { XCTFail("already completed") }))
        XCTAssertEqual(back.__x.0, 0)
    }
}
