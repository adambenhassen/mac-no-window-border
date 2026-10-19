import Darwin
import XCTest
@testable import NoBorderEngine

/// The fault guard's two pieces of pure logic: reading a real `exception_raise` request, and
/// building the reply that answers it. What cannot be tested here is the Mach round trip itself —
/// the debugger entitlement does not reach SwiftPM's test bundle — so tests/engine.sh runs the same
/// decode against a live app, where a wrong field means the app dies and the test says so.
final class FaultGuardTests: XCTestCase {
    /// A real request, captured from the engine's exception port: tests/hostapp forced to branch to
    /// address 1 (2026-10-19, macOS 15.7.7, arm64). 19 words = 76 bytes = the request's own size.
    private static let capturedRequest: [UInt32] = [
        0x8000_1112, 0x0000_004C, 0x0000_1803, 0x0000_1703,   // bits, size 76, remote, local
        0x0000_0000, 0x0000_0961,                             // reserved, id 2401 = exception_raise
        0x0000_0002,                                          // two port descriptors
        0x0000_1303, 0x0000_0000, 0x0011_0000,               // thread: name, pad, type+MOVE_SEND
        0x0000_1107, 0x0000_0000, 0x0011_0000,               // task:   same shape
        0x0000_0000, 0x0000_0001,                            // the record the kernel sends with it
        0x0000_0001,                                          // exception = EXC_BAD_ACCESS
        0x0000_0002,                                          // two codes
        0x0000_0101, 0x0000_0001,                            // the fault, and address 0x1 — the one we asked for
    ]

    private static let threadPort: mach_port_t = 0x1303
    private static let taskPort: mach_port_t = 0x1107

    private func fault(_ words: [UInt32]) -> DecodedFault? {
        let buffer = words
        return buffer.withUnsafeBytes { FaultGuard.decode($0) }
    }

    private var request: mach_msg_header_t {
        fault(Self.capturedRequest)!.header
    }

    func testARealFaultRequestIsRead() {
        let fault = self.fault(Self.capturedRequest)
        XCTAssertNotNil(fault)
        XCTAssertEqual(fault!.header.msgh_id, FaultGuard.exceptionRaiseID)
        XCTAssertEqual(fault!.header.msgh_size, UInt32(MemoryLayout<__Request__exception_raise_t>.size))
        XCTAssertEqual(fault!.thread, Self.threadPort)
        XCTAssertEqual(fault!.task, Self.taskPort)
        XCTAssertEqual(fault!.exception, Int32(EXC_BAD_ACCESS))
        // The second code is the address that faulted. Getting it right means the whole message was
        // read at the right offsets, not just the ports.
        XCTAssertEqual(fault!.codes, [0x101, 0x1])
    }

    func testTheReplyGoesBackOnTheChannelTheRequestCarried() {
        let reply = FaultGuard.reply(for: request, .success)
        XCTAssertEqual(reply.Head.msgh_id, request.msgh_id + 100, "MIG's rule: request id plus 100")
        XCTAssertEqual(reply.Head.msgh_remote_port, request.msgh_remote_port,
                       "the request's remote field is the reply channel")
        XCTAssertEqual(reply.Head.msgh_bits, request.msgh_bits & UInt32(MACH_MSGH_BITS_REMOTE_MASK))
        XCTAssertEqual(reply.Head.msgh_bits, UInt32(MACH_MSG_TYPE_MOVE_SEND_ONCE),
                       "the kernel sent this fault with a send-once right; answering it is the reply")
        XCTAssertEqual(reply.Head.msgh_local_port, 0)
        XCTAssertEqual(reply.RetCode, KERN_SUCCESS)
    }

    /// The reply channel is not the port the request named for itself: that right names this
    /// task's own receive right, so a reply sent there is accepted, queued, and read back by us.
    /// tests/engine.sh is the test for that (the app dies when it happens); this says why in code.
    func testTheReplyDoesNotGoToThePortTheRequestNamedForItself() {
        let reply = FaultGuard.reply(for: request, .success)
        XCTAssertNotEqual(reply.Head.msgh_remote_port, request.msgh_local_port)
    }

    func testRefusingTheFaultIsWhatLetsTheKernelAct() {
        let reply = FaultGuard.reply(for: request, .failure)
        XCTAssertEqual(reply.RetCode, KERN_FAILURE)
        XCTAssertEqual(reply.Head.msgh_id, request.msgh_id + 100)
    }

    // The checks above pass only because the message is read where the SDK's own layout puts it.
    // These four say the reading can fail: each one breaks one field of the same real message.

    func testARequestForAnotherRoutineIsNotReadAsOurs() {
        var words = Self.capturedRequest
        words[5] = UInt32(FaultGuard.exceptionRaiseID + 1)
        XCTAssertNil(fault(words))
    }

    func testAMessageWithoutBothPortsIsNotReadAsOurs() {
        var words = Self.capturedRequest
        words[6] = 1
        XCTAssertNil(fault(words))
    }

    func testAThreadWeCannotNameIsNotReadAsOurs() {
        var words = Self.capturedRequest
        words[7] = 0
        XCTAssertNil(fault(words))
    }

    func testATruncatedMessageIsNotReadAsOurs() {
        var words = Self.capturedRequest
        words[1] = 40
        XCTAssertNil(fault(words))
    }
}
