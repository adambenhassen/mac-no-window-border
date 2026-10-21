import Darwin
import Foundation

/// A fault the target raised while our call script was running, as read from the exception
/// message. `thread` and `task` are send rights the message gave us: use them, then deallocate.
struct DecodedFault {
    var header: mach_msg_header_t
    var exception: exception_type_t
    var codes: [Int32]
    var thread: mach_port_t
    var task: mach_port_t
}

/// Catches a fault raised by the call script so the target survives it: for the duration of one
/// run the engine is the target task's exception handler for the three faults a bad call can
/// raise, and it puts the app's own handlers back afterwards whatever happened.
///
/// The message is `exception_raise`, whose request and reply layouts the SDK declares in
/// `<mach/exc.h>` — no hand-written offsets. The engine module reads them through the imported
/// structs; `FaultGuardTests` checks the decode against the bytes a real fault produced
/// (tests/hostapp, forced to branch to address 1), and tests/engine.sh checks the whole path
/// against a live app: a fault whose thread cannot be identified is answered KERN_FAILURE, the app
/// dies, and the test says so.
final class FaultGuard {
    /// Only these: a breakpoint, an arithmetic trap or a software exception stays the app's own
    /// business — a debugger, or the app's crash reporter, is the handler for those.
    static let masks: exception_mask_t = [EXC_MASK_BAD_ACCESS, EXC_MASK_BAD_INSTRUCTION, EXC_MASK_GUARD]
        .reduce(0) { $0 | exception_mask_t($1) }

    /// What this guard instance is installed for.
    private(set) var installedMasks: exception_mask_t = 0

    /// Tests only: `NOBORDER_GUARD_BREAKPOINT=1` adds `EXC_BREAKPOINT` — the CF run-loop port trap
    /// is a breakpoint, and ReportCrash stops writing reports after the first of a run, so the
    /// probe's `watch` mode catches the state the app dies in (`drainAndLog`).
    static var diagnosticMasks: exception_mask_t {
        ProcessInfo.processInfo.environment["NOBORDER_GUARD_BREAKPOINT"] == "1"
            ? masks | exception_mask_t(EXC_MASK_BREAKPOINT) : masks
    }

    /// `exception_raise` in the routine table at the end of `<mach/exc.h>`.
    static let exceptionRaiseID: mach_msg_id_t = 2401

    /// `EXC_TYPES_COUNT` in <mach/arm/exception.h>: the size of the arrays
    /// `task_get_exception_ports` fills.
    private static let arrayCount = 14

    /// Big enough for `exception_raise`, with room to spare. We install with EXCEPTION_DEFAULT, so
    /// that is the only message the kernel can send us; a larger one would be a message shaped for
    /// a behaviour we never asked for, and is answered KERN_FAILURE rather than acted on.
    private static let receiveBytes = 256

    private let task: TargetTask
    private var receive: mach_port_t = 0
    /// The masks our port is installed for; zero when it is not installed.
    private var taken: exception_mask_t = 0
    /// Per mask we took, what the task had before, with its behaviour and flavour, so `remove`
    /// can put it back. A null handler means the task had none — setting a null handler back
    /// removes ours.
    private var saved: [(mask: exception_mask_t, handler: mach_port_t, behavior: exception_behavior_t,
                         flavor: thread_state_flavor_t)] = []

    init(task: TargetTask) { self.task = task }

    deinit { remove() }

    /// Install our port as the target's handler. Nothing is changed in the target if this fails.
    @discardableResult
    func install(masks: exception_mask_t = FaultGuard.masks) -> Bool {
        precondition(receive == 0, "the fault guard is already installed")
        guard mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &receive) == KERN_SUCCESS
        else { return false }
        guard mach_port_insert_right(mach_task_self_, receive, receive,
                                     mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS
        else { return false }
        guard readAppHandlers(masks) else { remove(); return false }
        let kr = task_set_exception_ports(task.port, masks, receive,
                                          EXCEPTION_DEFAULT, thread_state_flavor_t(ARM_THREAD_STATE64))
        guard kr == KERN_SUCCESS else { remove(); return false }
        taken = masks
        installedMasks = masks
        return true
    }

    /// Watch mode (tests): take the next exception, print the dying thread's state, and answer
    /// KERN_FAILURE so the app dies as it would anyway. The point is the state: pc, the trap's
    /// codes, and every register — `__CFRunLoopServiceMachPort`'s dying frame carries the
    /// `mach_msg2` arguments (x0 = message, x1 = options, x2 = send size, x3 = receive size,
    /// x4 = receive name, x5 = timeout, x6 = overmach) and its kr; the message header at x0 is
    /// read through the task (`msgh_bits`, `msgh_size`, `msgh_id`, reserved) to see which
    /// argument the kernel rejected (`MACH_RCV_INVALID_ARGUMENTS` = 0x10004013, measured
    /// 2026-10-20; the kr is not an interrupt echo).
    func drainAndLog() -> Bool {
        guard let fault = receiveFault() else { return false }
        let thread = MainThread(port: fault.thread, id: kernelThreadID(of: fault.thread) ?? 0)
        if let state = thread.state() {
            var line = "noborder watch: exception=\(fault.exception) codes=\(fault.codes.map { String(format: "0x%x", $0) })"
                + " pc=0x\(String(state.__pc, radix: 16)) lr=0x\(String(state.__lr, radix: 16))"
                + " sp=0x\(String(state.__sp, radix: 16))"
            withUnsafeBytes(of: state.__x) { raw in
                for index in 0...28 {
                    line += " x\(index)=0x\(String(raw.load(fromByteOffset: index * 8, as: UInt64.self), radix: 16))"
                }
            }
            // The mach_msg2 arguments, per the arm64 call-convention of the run-loop-port call.
            for (name, register) in [("msg", 0), ("options", 1), ("sendsize", 2), ("rcvsize", 3),
                                     ("rcvname", 4), ("timeout", 5), ("overmach", 6)] {
                let value: UInt64 = withUnsafeBytes(of: state.__x) { raw in
                    raw.load(fromByteOffset: register * 8, as: UInt64.self)
                }
                line += " \(name)=0x\(String(value, radix: 16))"
            }
            NSLog(line)
            // In `__CFRunLoopServiceMachPort` (this OS): x25 = the message buffer, [sp, #8] = the
            // result-pointer argument; the call is `mach_msg(x25, w27 | +0x100 when timed, 0,
            // [x25,#4] as receive size, x24 = receive port, x23 = timeout, 0)`, and its kr (x26)
            // tolerates {0, 0x10004004 TOO_LARGE, 0x10004003 TIMED_OUT} before the trap. So the
            // dying call's rejected arguments = the buffer words: msgh_bits/size/id/dest,
            // msgh_type/msgh_descriptor_count, and the slot.
            if state.__x.25 != 0, let buffer = messageBuffer(at: state.__x.25) {
                NSLog("noborder watch: msg buffer at x25=0x\(String(state.__x.25, radix: 16)):"
                      + buffer.map { "0x" + String($0, radix: 16) }.joined(separator: " "))
            }
            if let slot = readWord32(at: state.__sp &+ 8) {
                NSLog("noborder watch: [sp+8] = 0x\(String(slot, radix: 16))")
            }
        } else {
            NSLog("noborder watch: exception=\(fault.exception) codes=\(fault.codes) (no thread state)")
        }
        reply(.failure, to: fault.header)
        release(fault)
        return true
    }

    /// The words of a received `mach_msg_header_t` + `mach_msg_body_t`, read from the target:
    /// bits, size, id, destination, then type and descriptor count.
    private func messageBuffer(at address: UInt64) -> [UInt32]? {
        var words: [UInt32] = []
        for offset in stride(from: 0, to: 20, by: 4) {
            guard let word = readWord32(at: address &+ UInt64(offset)) else { return nil }
            words.append(word)
        }
        return words
    }

    private func readWord32(at address: UInt64) -> UInt32? {
        var value: UInt32 = 0
        var sent: vm_size_t = 0
        let kr = withUnsafeMutableBytes(of: &value) { raw in
            vm_read_overwrite(task.port, vm_address_t(address), vm_size_t(MemoryLayout<UInt32>.size),
                              vm_address_t(bitPattern: raw.baseAddress!), &sent)
        }
        return kr == KERN_SUCCESS ? value : nil
    }

    /// Answer anything still waiting for us, put the app's own handlers back, drop our port.
    ///
    /// The drain matters: a fault we received but never answered leaves its thread stopped in the
    /// kernel, waiting for a reply that will never come. A fault left over at this point is not one
    /// the script caused, so it is answered KERN_FAILURE and the app takes its own action for it.
    /// There is a window of microseconds between the drain and the restore in which a new fault
    /// would still come to us; it is far smaller than the run.
    func remove() {
        if receive != 0, ProcessInfo.processInfo.environment["NOBORDER_NODRAIN"] == nil {
            while let fault = receiveFault() {
                reply(.failure, to: fault.header)
                release(fault)
            }
        }
        if taken != 0 {
            for entry in saved {
                _ = task_set_exception_ports(task.port, entry.mask, entry.handler, entry.behavior, entry.flavor)
            }
            let savedMask = saved.reduce(0) { $0 | $1.mask }
            let cleared = taken & ~savedMask      // masks the task had no handler for: drop ours
            if cleared != 0 {
                _ = task_set_exception_ports(task.port, cleared, noPort,
                                             EXCEPTION_DEFAULT, thread_state_flavor_t(ARM_THREAD_STATE64))
            }
        }
        taken = 0
        saved.removeAll()
        if receive != 0 {
            mach_port_deallocate(mach_task_self_, receive)
            receive = 0
        }
    }

    /// One non-blocking read of the exception port.
    ///
    /// Returns true when the fault was the thread we are running: its state is set back to
    /// `state` — the app's own registers, with `pc` at the start of the run-loop call it was
    /// sitting in, the same handback the script uses — and the reply that lets the kernel continue
    /// it has been sent, which is what makes the app survive a fault of ours. The state has to be
    /// set by us: an `EXC_BAD_ACCESS` delivered as `EXCEPTION_DEFAULT` carries the thread's state to
    /// us but takes none back, so the thread would stay pointed at the faulting instruction.
    /// (Measured: the app's thread is back in `mach_msg2_trap` afterwards, and parks there.)
    ///
    /// The dispatched mode's one difference: when the fault is inside the block — the thread's sp
    /// is on its real stack, not the fabricated frame we entered on — the parked restore is
    /// *not* safe: the thread is in the app's own libdispatch/CF machinery, and pulling it out
    /// mid-drain corrupts it (measured 2026-10-20: the app died). The faulted block is resumed at
    /// `resumeAt` (its epilogue) on the frame it built, so it returns to libdispatch normally and
    /// the drain completes; only a fault in the stub gets the parked restore.
    ///
    /// Any other fault is answered KERN_FAILURE and returns false, so the caller keeps waiting for
    /// the script: that fault is the app's, not ours, and we cannot put it right.
    func tookFault(on main: MainThread, restoringTo state: arm_thread_state64_t,
                   resumeAt: UInt64 = 0, frameLo: UInt64 = 1, frameHi: UInt64 = 0) -> Bool {
        guard receive != 0, let fault = receiveFault() else { return false }
        guard kernelThreadID(of: fault.thread) == main.id else {
            reply(.failure, to: fault.header)   // not ours
            release(fault)
            return false
        }
        let thread = MainThread(port: fault.thread, id: main.id)
        if ProcessInfo.processInfo.environment["NOBORDER_GUARD_LOG"] == "1", let now = thread.state() {
            NSLog("noborder fault: exception=\(fault.exception) codes=\(fault.codes.map { String(format: "0x%x", $0) })"
                  + " pc=0x\(String(now.__pc, radix: 16)) sp=0x\(String(now.__sp, radix: 16))"
                  + Self.registerLine(now)
                  + " lr=0x\(String(now.__lr, radix: 16))")
        }
        var resumeState = state
        if resumeAt != 0, let now = thread.state(),
           !(frameLo <= now.__sp && now.__sp <= frameHi) {
            // sp says the block: keep the block's own frame and registers, step it home.
            resumeState = now
            resumeState.__pc = resumeAt
        }
        guard thread.setState(resumeState) else {
            reply(.failure, to: fault.header)   // we cannot put it right
            release(fault)
            return false
        }
        reply(.success, to: fault.header)
        release(fault)
        return true
    }

    private static func registerLine(_ state: arm_thread_state64_t) -> String {
        var line = ""
        withUnsafeBytes(of: state.__x) { raw in
            for index in 0...28 {
                line += " x\(index)=0x" + String(raw.load(fromByteOffset: index * 8, as: UInt64.self), radix: 16)
            }
        }
        return line
    }

    /// What the task had for the masks we are about to take.
    private func readAppHandlers(_ take: exception_mask_t) -> Bool {
        var masks = [exception_mask_t](repeating: 0, count: Self.arrayCount)
        var handlers = [mach_port_t](repeating: 0, count: Self.arrayCount)
        var behaviors = [exception_behavior_t](repeating: 0, count: Self.arrayCount)
        var flavors = [thread_state_flavor_t](repeating: 0, count: Self.arrayCount)
        var count = mach_msg_type_number_t(0)
        let kr = masks.withUnsafeMutableBufferPointer { masksPtr in
            handlers.withUnsafeMutableBufferPointer { handlersPtr in
                behaviors.withUnsafeMutableBufferPointer { behaviorsPtr in
                    flavors.withUnsafeMutableBufferPointer { flavorsPtr in
                        task_get_exception_ports(task.port, take, masksPtr.baseAddress!, &count,
                                                handlersPtr.baseAddress!, behaviorsPtr.baseAddress!,
                                                flavorsPtr.baseAddress!)
                    }
                }
            }
        }
        guard kr == KERN_SUCCESS else { return false }
        for index in 0..<min(Int(count), Self.arrayCount) {
            let intersection = masks[index] & take
            if intersection != 0 {
                saved.append((intersection, handlers[index], behaviors[index], flavors[index]))
            }
        }
        return true
    }

    /// Read one pending exception message without waiting. nil when there is none.
    private func receiveFault() -> DecodedFault? {
        var buffer = [UInt8](repeating: 0, count: Self.receiveBytes)
        let kr = buffer.withUnsafeMutableBytes { raw in
            let head = UnsafeMutableRawPointer(raw.baseAddress!).assumingMemoryBound(to: mach_msg_header_t.self)
            return mach_msg(head, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, mach_msg_size_t(raw.count),
                            receive, 0, noPort)
        }
        guard kr == KERN_SUCCESS else { return nil }   // MACH_RCV_TIMED_OUT: nothing waiting
        return buffer.withUnsafeBytes { raw in
            Self.decode(UnsafeRawBufferPointer(rebasing: raw[..<MemoryLayout<__Request__exception_raise_t>.size]))
        }
    }

    /// Read an `exception_raise` request. The two ports it carries arrive as descriptors in the
    /// kernel-processed part of the message, which is why `msgh_descriptor_count` is checked: a
    /// message without both of them is not one we can act on.
    static func decode(_ bytes: UnsafeRawBufferPointer) -> DecodedFault? {
        let requestSize = MemoryLayout<__Request__exception_raise_t>.size
        guard bytes.count >= requestSize else { return nil }
        var request = bytes.loadUnaligned(as: __Request__exception_raise_t.self)
        let codeCount = Int(request.codeCnt)
        guard request.Head.msgh_id == exceptionRaiseID,
              request.Head.msgh_size >= UInt32(requestSize),
              request.msgh_body.msgh_descriptor_count == 2,
              request.thread.name != noPort, request.task.name != noPort,
              codeCount >= 0, codeCount <= Self.codeLimit
        else { return nil }
        let codes = withUnsafeBytes(of: &request.code) { raw in
            (0..<codeCount).map { raw.load(fromByteOffset: $0 * MemoryLayout<Int32>.size, as: Int32.self) }
        }
        return DecodedFault(header: request.Head, exception: request.exception, codes: codes,
                            thread: request.thread.name, task: request.task.name)
    }

    /// The request carries `integer_t code[2]`.
    private static let codeLimit = 2

    /// How we answer a fault: we handled it, or we did not.
    enum ReplyCode { case success, failure }

    /// `exception_raise`'s reply, in the layout the SDK declares for it: the request's id plus 100
    /// (MIG's rule), the reply channel the request carried, and a kern_return_t. KERN_SUCCESS means
    /// we handled the fault and the thread continues with the state it now has; anything else lets
    /// the kernel take its default action for the exception.

    static func reply(for request: mach_msg_header_t, _ code: ReplyCode) -> __Reply__exception_raise_t {
        var reply = __Reply__exception_raise_t()
        // The kernel sends an exception request with a send-once right of its own in the message's
        // remote field, and that right *is* the reply channel: answering it is how the rendezvous
        // ends. Measured against a live fault: sending to the request's local port instead (the send
        // right the kernel moved into our task, which names our own receive right) is accepted,
        // lands in our own queue, and the app's thread stays stopped until the kernel gives up on
        // the exception — the app dies of it. So: the remote disposition, to the remote port.
        reply.Head.msgh_bits = request.msgh_bits & UInt32(MACH_MSGH_BITS_REMOTE_MASK)
        reply.Head.msgh_size = UInt32(MemoryLayout<__Reply__exception_raise_t>.size)
        reply.Head.msgh_remote_port = request.msgh_remote_port
        reply.Head.msgh_local_port = noPort
        reply.Head.msgh_id = request.msgh_id + 100
        reply.RetCode = code == .success ? KERN_SUCCESS : KERN_FAILURE
        return reply
    }

    private func reply(_ code: ReplyCode, to request: mach_msg_header_t) {
        var message = Self.reply(for: request, code)
        let kr = withUnsafeMutableBytes(of: &message) { raw in
            let head = UnsafeMutableRawPointer(raw.baseAddress!).assumingMemoryBound(to: mach_msg_header_t.self)
            return mach_msg(head, MACH_SEND_MSG, mach_msg_size_t(raw.count), 0, noPort,
                            MACH_MSG_TIMEOUT_NONE, noPort)
        }
        // A reply the kernel will not take leaves the faulting thread stopped in the kernel, so a
        // failure here is worth a line even though nothing else in the run says anything broke.
        if kr != KERN_SUCCESS { NSLog("noborder: could not answer the target's fault (kr=\(kr))") }
    }

    /// Both ports in the message are send rights the kernel gave us.
    private func release(_ fault: DecodedFault) {
        for port in [fault.thread, fault.task] where port != noPort {
            mach_port_deallocate(mach_task_self_, port)
        }
    }
}

/// A null port name. Swift imports `MACH_PORT_NULL` as Int32; the ports here are `mach_port_t`.
private let noPort: mach_port_t = mach_port_t(MACH_PORT_NULL)

/// Tests only: a long-lived exception port on a target, for catching the state a crash happens
/// in when ReportCrash has stopped writing reports (`probe watch <pid>`, with
/// `NOBORDER_GUARD_BREAKPOINT=1` in the environment). It is not part of any run; the app's own
/// handlers are restored when it is removed.
public final class ExceptionWatch {
    private let task: TargetTask
    private let faultGuard: FaultGuard

    public init(pid: Int32) throws {
        task = try TargetTask(pid: pid)
        faultGuard = FaultGuard(task: task)
    }

    @discardableResult
    public func install() -> Bool { faultGuard.install(masks: FaultGuard.diagnosticMasks) }

    @discardableResult
    public func drainAndLog() -> Bool { faultGuard.drainAndLog() }

    public func remove() { faultGuard.remove() }
}
