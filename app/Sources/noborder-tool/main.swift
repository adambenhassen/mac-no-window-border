// noborder-tool: the P1a rendezvous client. One run: find an agent's service,
// send HELLO, take the handshake, ping it `count` times, print p50/p99/max.
//
// The shape of this file is the shape that measures kr 0 on macOS 15.6:
// Foundation-only (no module imports), a raw-pthread sender created before the
// task port, msgh_bits 0x13 = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, PORT_NONE)
// — send on the right we hold, no reply port — the thread_swap_mach_voucher
// round trip in the sender body (the RPC is a KERN_NOT_SUPPORTED stub on
// macOS 15; its presence is a measured shape factor for kr 0 — why is
// uncharacterized), and message bytes built as plain arrays. The probe's
// structurally similar sends answer 0x10000010 in the same session — the
// difference is the binary's code, not the message (measured family: rr8g 0 /
// probe-copy 16, deterministic; full matrix in
// .superpowers/sdd/2026-10-20-noborder-dispatch-entry/progress.md).
// The delivered msgh_size is the send_size trap argument (XNU mach_msg.c), so
// send_size must equal the real message size: a latched pingMode once sent
// forged 96-byte HELLOs at literal 40 (truncated) and read past 24-byte
// buffers — that, not any kernel "first-send" rule, produced the 40-byte
// arrivals measured 2026-10-20; fixed 2026-10-21.
import Foundation
import MachO

let usage = "usage: noborder-tool <pid> [count] [forge-...] | <pid> op apply|restore <wid> [buttons] [reps]"
let args = CommandLine.arguments
let count = args.count > 2 ? max(1, Int(args[2]) ?? 200) : 200
func fail(_ message: String) -> Never {
    print(message)
    exit(1)
}
guard args.count >= 2, let pidArg = Int32(args[1]) else { print(usage); exit(2) }

typealias LookFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, UnsafeMutablePointer<mach_port_name_t>) -> Int32
typealias RegFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, mach_port_name_t) -> Int32
let lookUp = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_look_up")!, to: LookFn.self)
let register = unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_register")!, to: RegFn.self)
let go = DispatchSemaphore(value: 0)
let done = DispatchSemaphore(value: 0)
var krOut: Int32 = -1
var sendBytes: [UInt8] = []
var rzSend: mach_port_name_t = 0
var pingMode = false
var forgeMode = false   // prebuilt messages (boundary regression), sent at their own size
let helloToken: UInt64 = 0x0123_4567_89ab_cdef &+ UInt64(getpid())
let sender: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { _ in
    // The kernelrpc round trip here (the stub is KERN_NOT_SUPPORTED on macOS 15,
    // the RPC still runs) is part of the shape that measures kr 0 — do not
    // "clean it up" without re-measuring. The message is (re)built from globals
    // with LITERAL sizes; reading a size global in this C closure measurably
    // changes the kernel's answer (the family matrix: builder+literal 0,
    // pass-through+global-size 0x10000010).
    typealias SwapFn = @convention(c) (mach_port_name_t, mach_port_name_t, UnsafeMutablePointer<mach_port_name_t>) -> Int32
    if let sw = dlsym(dlopen(nil, RTLD_LAZY), "thread_swap_mach_voucher").map({ unsafeBitCast($0, to: SwapFn.self) }) {
        var v: mach_port_name_t = 0
        _ = sw(mach_thread_self(), mach_port_name_t(MACH_PORT_NULL), &v)
        var back: mach_port_name_t = 0
        _ = sw(mach_thread_self(), v, &back)
    }
    while true {
        go.wait()
        var m = sendBytes
        func p32(_ at: Int, _ v: UInt32) { for i in 0..<4 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
        func p64(_ at: Int, _ v: UInt64) { for i in 0..<8 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
        if pingMode {
            krOut = m.withUnsafeMutableBytes { b in
                mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!, MACH_SEND_MSG,
                         40, 0, mach_port_name_t(MACH_PORT_NULL), MACH_MSG_TIMEOUT_NONE, 0)
            }
        } else if forgeMode {
            let n = mach_msg_size_t(m.count)
            krOut = m.withUnsafeMutableBytes { b in
                mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!, MACH_SEND_MSG,
                         n, 0, mach_port_name_t(MACH_PORT_NULL), MACH_MSG_TIMEOUT_NONE, 0)
            }
        } else {
            p32(0, 19); p32(4, 96); p32(8, rzSend); p32(20, 2004); p64(24, helloToken)
            krOut = m.withUnsafeMutableBytes { b in
                mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!, MACH_SEND_MSG,
                         96, 0, mach_port_name_t(MACH_PORT_NULL), MACH_MSG_TIMEOUT_NONE, 0)
            }
        }
        done.signal()
    }
}
var tid: pthread_t? = nil
_ = pthread_create(&tid, nil, sender, nil)

let pid = pid_t(exactly: pidArg)!
var tp: mach_port_t = 0
let tfpKr = task_for_pid(mach_task_self_, pid, &tp)
guard tfpKr == KERN_SUCCESS, tp != 0 else { fail("noborder-tool \(pid) task-for-pid kr=\(tfpKr)") }

// Warm-up send to a local loopback port, in HELLO shape (rr8g's shape: the
// measured-good binary sends twice to a self-allocated port before the
// rendezvous; this is that sequence, kept because the binary's behavior
// depends on it in ways the kernel has not been fully characterized for).
var ldst: mach_port_name_t = 0
guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &ldst) == KERN_SUCCESS,
      mach_port_insert_right(mach_task_self_, ldst, ldst, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
    fail("noborder-tool \(pid) loopback-alloc failed")
}
var pm = [UInt8](repeating: 0, count: 96)
rzSend = ldst
sendBytes = pm
go.signal(); done.wait()
guard krOut == KERN_SUCCESS else { fail("noborder-tool \(pid) warmup kr=\(krOut)") }

var bs: mach_port_name_t = 0
guard task_get_special_port(mach_task_self_, 4, &bs) == KERN_SUCCESS else { fail("noborder-tool \(pid) bootstrap-port failed") }
var targetBs: mach_port_name_t = 0
guard task_get_special_port(tp, 4, &targetBs) == KERN_SUCCESS else { fail("noborder-tool \(pid) target-bootstrap-port failed") }
// The rendezvous name to look up. A linked agent (tests/agent.sh) registers
// `com.noborder.rz.<pid>`; a blob agent registers a per-install nonce name the installer
// reports (AgentInstaller), which tests/blobagent.sh passes in `NOBORDER_RZ_NAME`. The
// default keeps the linked-agent convention.
let serviceName = getenv("NOBORDER_RZ_NAME").map { String(cString: $0) } ?? "com.noborder.rz.\(pid)"
// A linked agent registers at launch in the tool's own bootstrap; a blob installed
// into a running GUI app registers in the app's private namespace, reachable only
// as the target's BOOTSTRAP_PORT (measured 2026-10-20). Look in both; register the
// tool service in the namespace the agent's name lives in — the HELLO carries the
// name and the agent looks it up in its own.
var lr = serviceName.withCString { lookUp(bs, $0, &rzSend) }
if lr != 0 {
    lr = serviceName.withCString { lookUp(targetBs, $0, &rzSend) }
    if lr == 0 { bs = targetBs }
}
guard lr == 0 else { fail("noborder-tool \(pid) look-up \(serviceName) r=\(lr)") }
var toolRcv: mach_port_name_t = 0
guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &toolRcv) == KERN_SUCCESS else {
    fail("noborder-tool \(pid) tool-alloc failed")
}
// FaultGuard self-insert (name == right); an unbound SEND name is refused (kr 18, measured).
guard mach_port_insert_right(mach_task_self_, toolRcv, toolRcv, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS else {
    fail("noborder-tool \(pid) tool-insert failed")
}
let toolService = "com.noborder.tool.\(getpid())"
let rr = toolService.withCString { cstr in register(bs, cstr, toolRcv) }   // consumes our SEND
guard rr == 0 else { fail("noborder-tool \(pid) tool-register r=\(rr)") }
print("noborder-tool \(pid) token \(helloToken)")

// forge-first: send one forged message as the first send to the AGENT (the real
// HELLO's slot; the loopback warm-up precedes it), then exit. Kept as a
// delivery-path variant; the post-ping forge modes at the end of the file are
// the production-shape path now that send_size is sent honestly.
let forgeFirst = args.first(where: { $0.hasPrefix("forge-first-") }).map { String($0.dropFirst(12)) }
if let mode = forgeFirst {
    forgeMode = true
    func f32(_ m: inout [UInt8], _ at: Int, _ v: UInt32) { for i in 0..<4 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    func f64(_ m: inout [UInt8], _ at: Int, _ v: UInt64) { for i in 0..<8 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    var msg: [UInt8]
    switch mode {
    case "hello92":
        msg = [UInt8](repeating: 0, count: 92)
        f32(&msg, 4, 92)
    case "unterm":
        msg = [UInt8](repeating: 0, count: 96)
        f32(&msg, 4, 96)
        f64(&msg, 24, helloToken &+ 1)
        for i in 32..<96 { msg[i] = 0x41 }
    case "ping44":
        // No handshake precedes it: the blob ACKs to the LAST REGISTERED tool's port —
        // a departed tool's. The ACK send kr lands in errAck: the ACK-to-dead-port path.
        msg = [UInt8](repeating: 0, count: 44)
        f32(&msg, 4, 44)
    default:
        fail("noborder-tool \(pid) unknown forge-first mode \(mode)")
    }
    f32(&msg, 0, 19); f32(&msg, 8, rzSend); f32(&msg, 20, mode == "ping44" ? 2001 : 2004)
    sendBytes = msg
    go.signal(); done.wait()
    print("noborder-tool \(pid) forge-first \(mode) kr=\(krOut)")
    exit(krOut == KERN_SUCCESS ? 0 : 1)
}

// HELLO v2: {header(24), token@24, service name[64]@32} = 96 bytes, built as raw
// bytes so the layout is the frozen one, not a struct that can drift. The header
// fields (bits/size/remote/id/token) are written by the sender's builder from the
// rzSend/helloToken globals (the measured-good shape); main writes only the name.
var hello = [UInt8](repeating: 0, count: 96)
let nameBytes = Array(toolService.utf8)
precondition(nameBytes.count < 64, "service name must fit the HELLO")
hello.replaceSubrange(32..<(32 + nameBytes.count), with: nameBytes)
sendBytes = hello
go.signal(); done.wait()
guard krOut == KERN_SUCCESS else { fail("noborder-tool \(pid) hello kr=\(krOut)") }
if !args.contains(where: { $0 == "forge" || $0.hasPrefix("forge-") }) {
    mach_port_deallocate(mach_task_self_, rzSend)   // keep it for the forged sends' destination
}

struct ToolHandshake {
    var msgh: mach_msg_header_t = mach_msg_header_t(msgh_bits: 0, msgh_size: 0,
                                                    msgh_remote_port: 0, msgh_local_port: 0,
                                                    msgh_voucher_port: 0, msgh_id: 0)
    var descCount: UInt32 = 0       // 24
    var descName: UInt32 = 0        // 28
    var descPad1: UInt32 = 0        // 32
    var descPad2: UInt16 = 0        // 36
    var descDisposition: UInt8 = 0  // 38
    var descType: UInt8 = 0         // 39
    var token: UInt64 = 0           // 40
}
var hs = ToolHandshake()
var kr = withUnsafeMutablePointer(to: &hs.msgh) {
    mach_msg($0, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 128,   // body 48 + trailer headroom
             toolRcv, 5000, 0)                              // 48 alone = MACH_RCV_TOO_LARGE
}
if kr == KERN_SUCCESS {
    var spins = 0
    withUnsafeMutableBytes(of: &hs) { buf in
        while buf.loadUnaligned(fromByteOffset: 20, as: Int32.self) != 2003 && spins < 5_000_000 {
            spins += 1
        }
    }
}
// Disposition: the linked agent MOVES its CFMachPort send (17, ARC keeps it alive); the blob
// COPIES its single-reference plain send (19) — both deliver the tool a working send right.
guard kr == KERN_SUCCESS, hs.msgh.msgh_id == 2003, hs.token == helloToken,
      hs.descType == 0, hs.descDisposition == 17 || hs.descDisposition == 19 else {
    mach_port_deallocate(mach_task_self_, toolRcv)
    fail("noborder-tool \(pid) handshake kr=\(kr) id=\(hs.msgh.msgh_id) token=\(hs.token)")
}
print("noborder-tool \(pid) handshake ok agent_port=\(hs.descName)")
let sendRight: mach_port_name_t = hs.descName

// P1b op requests: `op apply <wid> [buttons] [reps]` / `op restore <wid> [reps]`.
// {gen@24, wid@32, op@40, buttons@48, session@56} over the 24-byte header (64 total);
// the ACK (msgh_id 3010) answers {gen, wid, status, session}. Sends go through the raw
// sender at their real size (the forge path's measured-good shape); the receive takes
// 3010 with a 5 s deadline.
if let opIdx = args.firstIndex(of: "op"), args.count > opIdx + 2 {
    func f32(_ m: inout [UInt8], _ at: Int, _ v: UInt32) { for i in 0..<4 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    func f64(_ m: inout [UInt8], _ at: Int, _ v: UInt64) { for i in 0..<8 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    let verb = args[opIdx + 1]
    let wid = UInt64(args[opIdx + 2]) ?? 0
    let isApply = verb == "apply"
    guard isApply || verb == "restore" else { fail("noborder-tool \(pid) op verb \(verb)") }
    var rest = Array(args.dropFirst(opIdx + 3))
    var buttons: UInt64 = 7
    if isApply, let b = rest.first.flatMap({ UInt64($0) }) { buttons = b; rest = Array(rest.dropFirst()) }
    let reps = rest.first.flatMap({ Int($0) }) ?? 1
    let mode: UInt32 = isApply ? 3001 : 3002
    forgeMode = true
    pingMode = false
    for r in 1...max(1, reps) {
        // gen is monotonic across tool runs (boot-time nanoseconds): a row's generation rule
        // compares gens, and a per-run counter restarting at 1 would read as a duplicate.
        let gen = UInt64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        var msg = [UInt8](repeating: 0, count: 64)
        f32(&msg, 0, 19); f32(&msg, 4, 64); f32(&msg, 8, sendRight); f32(&msg, 20, mode)
        f64(&msg, 24, gen); f64(&msg, 32, wid); f64(&msg, 40, isApply ? 1 : 2)
        f64(&msg, 48, buttons); f64(&msg, 56, helloToken)
        sendBytes = msg
        go.signal(); done.wait()
        guard krOut == KERN_SUCCESS else { fail("noborder-tool \(pid) op send kr=\(krOut)") }
        var status: UInt64 = 0
        var ackGen: UInt64 = 0
        var got = false
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while !got && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < 5_000_000_000 {
            var ack = [UInt8](repeating: 0, count: 128)
            let rkr = ack.withUnsafeMutableBytes { b in
                mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                         MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 128, toolRcv, 500, 0)
            }
            guard rkr == KERN_SUCCESS else { continue }
            let id = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
            guard id == 3010 else { continue }
            ackGen = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
            status = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
            got = true
        }
        let names = ["", "applied", "restored", "not-found", "deferred", "superseded",
                     "unsupported", "table-full", "no-original"]
        print("noborder-tool \(pid) op \(verb) wid=\(wid) gen=\(gen) ack_gen=\(ackGen) "
              + "status=\(status) (\(status < UInt64(names.count) ? names[Int(status)] : "?"))")
        guard got, ackGen == gen else { fail("noborder-tool \(pid) op \(verb) gen \(gen): ack \(ackGen) got=\(got)") }
    }
    mach_port_deallocate(mach_task_self_, sendRight)
    mach_port_deallocate(mach_task_self_, toolRcv)
    exit(0)
}

struct PingMsg {
    var msgh: mach_msg_header_t = mach_msg_header_t(msgh_bits: 0, msgh_size: 0,
                                                    msgh_remote_port: 0, msgh_local_port: 0,
                                                    msgh_voucher_port: 0, msgh_id: 0)
    var seq: UInt64 = 0
    var counter: UInt64 = 0
}
var dtsUs: [UInt64] = []
var lastCounter: UInt64 = 0
for n in 0..<UInt64(count) {
    var ping = PingMsg(msgh: mach_msg_header_t(
        msgh_bits: 19,   // same as the HELLO: COPY_SEND dest, PORT_NONE local (no reply right)
        msgh_size: UInt32(MemoryLayout<PingMsg>.stride),
        msgh_remote_port: sendRight, msgh_local_port: 0,
        msgh_voucher_port: 0, msgh_id: 2001), seq: n)
    var ack = PingMsg()
    let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    sendBytes = withUnsafeBytes(of: &ping) { Array($0) }
    pingMode = true
    go.signal(); done.wait()
    kr = krOut
    var ackId: Int32 = 0, ackSeq: UInt64 = 0, ackCounter: UInt64 = 0
    while ackId != 2002 && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < 2_000_000_000 {
        ack = PingMsg()
        kr = withUnsafeMutablePointer(to: &ack.msgh) { recv in
            mach_msg(recv, MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 128, toolRcv, 500, 0)
        }
        if kr != KERN_SUCCESS { continue }
        var spins = 0
        withUnsafeMutableBytes(of: &ack) { buf in
            while buf.loadUnaligned(fromByteOffset: 20, as: Int32.self) != 2002 && spins < 5_000_000 {
                spins += 1
            }
            ackId = buf.loadUnaligned(fromByteOffset: 20, as: Int32.self)
            ackSeq = buf.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
            ackCounter = buf.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
        }
    }
    let dtUs = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000
    guard kr == KERN_SUCCESS, ackId == 2002, ackSeq == n else {
        fail("noborder-tool \(pid) n=\(n) kr=\(kr) id=\(ackId) seq=\(ackSeq) ok=\(dtsUs.count)")
    }
    dtsUs.append(dtUs)
    lastCounter = ackCounter
}
mach_port_deallocate(mach_task_self_, toolRcv)
dtsUs.sort()
print("noborder-tool \(pid) n=\(count) ok=\(dtsUs.count) counter=\(lastCounter) "
      + "p50_us=\(dtsUs[dtsUs.count / 2]) p99_us=\(dtsUs[(dtsUs.count * 99) / 100]) max_us=\(dtsUs.last ?? 0)")

// Boundary regression (tests/blobagent.sh): messages the blob must handle safely — a
// HELLO under the 96-byte gate, a HELLO whose service name has no NUL inside the 64-byte
// field (the scan must fail closed), and pings under the 40-byte gate. They go to the
// bootstrap LOOK-UP name (rzSend), the destination that delivers real HELLOs. The
// delivered msgh_size is the send_size trap argument, so forged sends carry their real
// size: the 2026-10-20 "kernel clamps handshake-right sends to 40" reading was this
// tool's latched pingMode forcing send_size 40 on every send after the ping loop, not
// kernel behaviour (see the header). The cb's b.lo gates (96-byte HELLO, 40-byte ping)
// are the receiver-side defence these messages exercise.
if args.contains(where: { $0 == "forge" || $0.hasPrefix("forge-") }) {
    pingMode = false   // the ping loop latches it; forged sends need their real size
    forgeMode = true
    func f32(_ m: inout [UInt8], _ at: Int, _ v: UInt32) { for i in 0..<4 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    func f64(_ m: inout [UInt8], _ at: Int, _ v: UInt64) { for i in 0..<8 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
    func forge(_ label: String, _ msg: inout [UInt8]) {
        sendBytes = msg
        go.signal(); done.wait()
        print("noborder-tool \(pid) forge \(label) kr=\(krOut)")
    }
    let modes = args.filter { $0.hasPrefix("forge-") }.map { String($0.dropFirst(6)) }
    func want(_ m: String) -> Bool { modes.isEmpty || modes.contains(m) }
    if want("hello92") {
        var helloShort = [UInt8](repeating: 0, count: 92)
        f32(&helloShort, 0, 19); f32(&helloShort, 4, 92); f32(&helloShort, 8, rzSend); f32(&helloShort, 20, 2004)
        forge("hello92", &helloShort)
    }
    if want("unterm") {
        var unterm = [UInt8](repeating: 0, count: 96)
        f32(&unterm, 0, 19); f32(&unterm, 4, 96); f32(&unterm, 8, rzSend); f32(&unterm, 20, 2004)
        f64(&unterm, 24, helloToken &+ 1)
        for i in 32..<96 { unterm[i] = 0x41 }
        forge("unterminated-name", &unterm)
    }
    if want("shortping") {
        var shortPing = [UInt8](repeating: 0, count: 32)
        f32(&shortPing, 0, 19); f32(&shortPing, 4, 32); f32(&shortPing, 8, rzSend); f32(&shortPing, 20, 2001)
        forge("shortping32", &shortPing)
    }
    for size in [36, 44] where want("ping\(size)") {
        var ping = [UInt8](repeating: 0, count: size)
        f32(&ping, 0, 19); f32(&ping, 4, UInt32(size)); f32(&ping, 8, rzSend); f32(&ping, 20, 2001)
        forge("ping\(size)", &ping)
    }
    mach_port_deallocate(mach_task_self_, rzSend)
}
mach_port_deallocate(mach_task_self_, sendRight)
