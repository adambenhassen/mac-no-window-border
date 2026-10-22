import Foundation

/// The client side of the resident agent, in-process: HELLO, handshake, op, ACK — the
/// noborder-tool protocol, no separate process. The receive rights are allocated HERE and
/// registered in bootstrap; `bootstrap_register` is a MIG call that transfers the right, so
/// the name the agent's `bootstrap_look_up` answers is a target-space send right pointing at
/// our receive port — the agent's ACKs land on it, and the client never touches the target's
/// port namespace (the P1a rendezvous shape, proven by the tool).
///
/// The sender thread is transplanted from the tool verbatim (the loopback warm-up, the
/// `thread_swap_mach_voucher` round trip, and the literal-size message rebuild in the C
/// closure are measured shape factors for the send's kr on macOS 15.6 — the tool's header
/// comment is the record; do not "clean up" without re-measuring).
public final class BlobClient: @unchecked Sendable {
    public enum Status: UInt64 {
        case applied = 1, restored, notFound, deferred, superseded, unsupported, tableFull, noOriginal
    }

    public let pid: pid_t
    private let task: TargetTask
    private var rzSend: mach_port_name_t = 0
    private let toolRcv: mach_port_name_t
    private let helloToken: UInt64 = 0x0123_4567_89ab_cdef &+ UInt64(getpid())

    // The shape-magic sender: one raw thread created before any target work, sending bytes we
    // build with literal sizes and handing back the kr (the tool's pattern verbatim).
    private let go = DispatchSemaphore(value: 0)
    private let done = DispatchSemaphore(value: 0)
    fileprivate var krOut: Int32 = -1
    fileprivate var sendBytes: [UInt8] = []
    fileprivate var isOp = false
    /// The op's msgh_id: 3001 apply, 3002 restore (the blob branches the op's verb on the id).
    fileprivate var opId: UInt32 = 3001
    fileprivate var opMode: UInt32 = 0
    fileprivate var opGen: UInt64 = 0
    fileprivate var opWid: UInt64 = 0
    fileprivate var opButtons: UInt64 = 0
    /// Planted (sandbox) op: carry a reply port and session 0; the bootstrap op carries no reply
    /// port (the agent keeps its HELLO-registered port) and the HELLO token as the session.
    fileprivate var opPlanted = false
    fileprivate var opReply: mach_port_name_t = 0
    fileprivate var opSession: UInt64 = 0
    fileprivate var sendRemote: mach_port_name_t = 0   // warm-up: loopback; sends: the agent
    fileprivate var agentRemote: mach_port_name_t = 0
    fileprivate let toolService: String
    private var targetBs: mach_port_name_t = 0

    /// Open the target and the tool side of the rendezvous: task port, tool receive port
    /// registered where the agent looks it up. The agent's service is looked up later
    /// (`connectAgent`) — it exists only once the agent is installed, and the installer
    /// (not this client) installs it: `ensureAgent` follows this init.
    public init?(pid: pid_t) {
        self.pid = pid
        guard let task = try? TargetTask(pid: pid) else { return nil }
        self.task = task
        var bs: mach_port_name_t = 0
        guard task_get_special_port(mach_task_self_, 4, &bs) == KERN_SUCCESS,
              task_get_special_port(task.port, 4, &targetBs) == KERN_SUCCESS else { return nil }
        var toolRcv: mach_port_name_t = 0
        guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &toolRcv) == KERN_SUCCESS,
              mach_port_insert_right(mach_task_self_, toolRcv, toolRcv, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS
        else { return nil }
        self.toolRcv = toolRcv
        // HELLO v2: the agent reads the service name from the HELLO, not from a pid convention,
        // so the name is unique per client (the ns suffix) — a client made after a shutdown
        // never meets its own old registration. (bootstrap_delete is not an exported symbol on
        // this OS; dlsym of it answers NULL — measured 2026-10-21 — so there is nothing to
        // unregister and nothing to collide with.)
        self.toolService = "com.noborder.tool.\(getpid()).\(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))"
        // Registration is deferred to connectAgent: the agent looks the name up in ITS OWN
        // namespace, so the service goes in the namespace the agent's rz name lives in —
        // the target's private bootstrap for installed agents (the tool's pattern; the
        // agent answered no handshake when the name sat in ours, measured 2026-10-21).
        startSender()
    }

    deinit {
        mach_port_deallocate(mach_task_self_, toolRcv)
        if rzSend != 0 { mach_port_deallocate(mach_task_self_, rzSend) }
        if plantedCtrlSend != 0 { mach_port_deallocate(mach_task_self_, plantedCtrlSend) }
    }

    /// Resolve the agent's rendezvous name: installed agents register it in the target's
    /// private bootstrap. The tool's order: own namespace first, then the target's.
    /// The service name from THIS client's install (the installer's per-install nonce prefix).
    /// An agent installed by the tool/probe under the pid convention is not this client's
    /// agent; each install is addressed by the name its own installer generated.
    private var rzService: String?
    private func connectAgent() -> Bool {
        if agentRemote != 0 { return true }
        guard let serviceName = rzService else { lastOpStage = "no-install"; return false }
        var rz: mach_port_name_t = 0
        var bs: mach_port_name_t = 0
        guard task_get_special_port(mach_task_self_, 4, &bs) == KERN_SUCCESS else {
            lastOpStage = "own-bootstrap"; return false
        }
        var ns = bs
        if Self.lookUp(bs, serviceName, &rz) != 0 {
            ns = targetBs
            guard targetBs != 0, Self.lookUp(targetBs, serviceName, &rz) == 0 else {
                lastOpStage = "rz-not-found"; return false
            }
        }
        let regKr = toolService.withCString({ Self.register(ns, $0, toolRcv) })
        guard regKr == 0 else { lastOpStage = "register-kr=\(regKr)"; return false }
        agentRemote = rz
        rzSend = rz
        sendRemote = rz
        return true
    }

    // bootstrap C functions, dlsym'd (the tool's pattern: bare imports).
    private typealias LookFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, UnsafeMutablePointer<mach_port_name_t>) -> Int32
    private typealias RegFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, mach_port_name_t) -> Int32
    nonisolated(unsafe) private static let lookUp: LookFn =
        unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_look_up")!, to: LookFn.self)
    nonisolated(unsafe) private static let register: RegFn =
        unsafeBitCast(dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_register")!, to: RegFn.self)

    private func startSender() {
        let sender: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { raw in
            typealias SwapFn = @convention(c) (mach_port_name_t, mach_port_name_t, UnsafeMutablePointer<mach_port_name_t>) -> Int32
            if let sw = dlsym(dlopen(nil, RTLD_LAZY), "thread_swap_mach_voucher").map({ unsafeBitCast($0, to: SwapFn.self) }) {
                var v: mach_port_name_t = 0
                _ = sw(mach_thread_self(), mach_port_name_t(MACH_PORT_NULL), &v)
                var back: mach_port_name_t = 0
                _ = sw(mach_thread_self(), v, &back)
            }
            let me = Unmanaged<BlobClient>.fromOpaque(raw).takeUnretainedValue()
            let token = me.helloToken
            while true {
                me.go.wait()
                // Read the request INSIDE the loop: `connectAgent` sets the destination after
                // this thread starts (deferring registration to the agent's namespace), and an
                // op's fields are written per call — a pre-loop capture sends everything to
                // port 0 in HELLO shape (measured 2026-10-21: agent toolPort stayed 0).
                let rz = me.sendRemote
                let isOp = me.isOp
                let opId = me.opId
                let mode = me.opMode
                let gen = me.opGen
                let wid = me.opWid
                let buttons = me.opButtons
                var m = me.sendBytes
                func p32(_ at: Int, _ v: UInt32) { for i in 0..<4 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
                func p64(_ at: Int, _ v: UInt64) { for i in 0..<8 { m[at + i] = UInt8((v >> (8 * i)) & 0xff) } }
                if isOp {
                    // Planted: bits 0x1413 (remote COPY_SEND, local MAKE_SEND) + the reply port at
                    // 12, so the agent ACKs back to us; bootstrap: bits 19, no reply port.
                    let bits: UInt32 = me.opPlanted ? 0x1413 : 19
                    p32(0, bits); p32(4, 64); p32(8, rz); p32(20, opId)
                    if me.opPlanted { p32(12, me.opReply) }
                    p64(24, gen); p64(32, wid); p64(40, UInt64(mode)); p64(48, buttons); p64(56, me.opSession)
                    me.krOut = m.withUnsafeMutableBytes { b in
                        mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                                 MACH_SEND_MSG | MACH_SEND_TIMEOUT, 64, 0,
                                 mach_port_name_t(MACH_PORT_NULL), 2000, 0)
                    }
                } else {
                    p32(0, 19); p32(4, 96); p32(8, rz); p32(20, 2004); p64(24, token)
                    me.krOut = m.withUnsafeMutableBytes { b in
                        mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                                 MACH_SEND_MSG, 96, 0,
                                 mach_port_name_t(MACH_PORT_NULL), MACH_MSG_TIMEOUT_NONE, 0)
                    }
                }
                me.done.signal()
            }
        }
        var tid: pthread_t? = nil
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        pthread_create(&tid, nil, sender, ctx)
        // The loopback warm-up in HELLO shape (the tool's measured sequence, kept verbatim):
        // a local self-allocated port, not the agent.
        var ldst: mach_port_name_t = 0
        guard mach_port_allocate(mach_task_self_, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &ldst) == KERN_SUCCESS,
              mach_port_insert_right(mach_task_self_, ldst, ldst, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)) == KERN_SUCCESS
        else { return }
        sendBytes = [UInt8](repeating: 0, count: 96)
        isOp = false
        sendRemote = ldst
        go.signal(); done.wait()
        sendRemote = agentRemote
        mach_port_destroy(mach_task_self_, ldst)
    }

    /// Install the agent once per process; answers the pages' base for removal (the
    /// installer owns them; `removeAgent` frees them).
    private var agentBase: UInt64?
    /// Sandbox rendezvous: set when the agent was installed with a controller-planted port (a
    /// sandboxed target that could not bootstrap_register). `op()` then drives the planted channel
    /// instead of HELLO + bootstrap lookup.
    private var planted = false
    private var plantedCtrlSend: mach_port_name_t = 0
    /// The installer's refusal reason from the last `ensureAgent` (nil on success), for the
    /// engine's refusal line: which preflight refused is the news.
    public private(set) var lastInstallFailure: String?
    /// The blob's own `err` from the last install whose entry ran but did not publish ready (nil
    /// otherwise): the engine tells a refusal that is the process's nature from a busy moment.
    public private(set) var lastInstallErr: UInt64?
    /// The install's stop budget: the dispatched entry runs as a block on the target's main
    /// QUEUE, and hot-mained apps (Chromium drains it in bursts, measured live 2026-10-21:
    //  `entry-timed-out` at 2 s three for three while a plain parked entry landed in 0.8 ms)
    /// need a longer one. The engine ramps it per retry so the serial scan loop never opens
    /// at the big budget.
    @discardableResult
    public func ensureAgent(stopLimit: TimeInterval = 2.0) -> UInt64? {
        if let base = agentBase { return base }
        // Test hook: force the planted (sandbox) rendezvous against a non-sandboxed target, which
        // would otherwise take the bootstrap path on its first install. Offline proof only.
        if ProcessInfo.processInfo.environment["NOBORDER_FORCE_PLANT"] != nil {
            let planted = AgentInstaller(task: task).install(pid: UInt64(pid), stopLimit: stopLimit, plantPort: true)
            lastInstallFailure = planted.failure
            if planted.failure == nil, let pr = planted.report, pr.ready == 1, pr.ctrlSend != 0 {
                agentBase = pr.base
                self.planted = true
                plantedCtrlSend = pr.ctrlSend
                sendRemote = pr.ctrlSend
                return pr.base
            }
            lastInstallErr = planted.report?.err
            lastInstallFailure = planted.failure ?? "planted-entry-not-ready"
            return nil
        }
        let install = AgentInstaller(task: task).install(pid: UInt64(pid), stopLimit: stopLimit)
        lastInstallFailure = install.failure
        lastInstallErr = nil
        if install.failure == nil, let report = install.report, report.ready == 1 {
            agentBase = report.base
            rzService = report.serviceName
            return report.base
        }
        // Sandboxed target (blob err 1100 = BOOTSTRAP_NOT_PRIVILEGED): the bootstrap rendezvous can
        // never complete. Retry with a controller-planted receive port (CFMachPortCreateWithPort, no
        // bootstrap). iTerm and other non-sandboxed apps never reach this — their first install is
        // ready, so their proven path is untouched.
        if install.failure == nil, install.report?.err == 1100 {
            let planted = AgentInstaller(task: task).install(pid: UInt64(pid), stopLimit: stopLimit, plantPort: true)
            if planted.failure == nil, let pr = planted.report, pr.ready == 1, pr.ctrlSend != 0 {
                agentBase = pr.base
                self.planted = true
                plantedCtrlSend = pr.ctrlSend
                sendRemote = pr.ctrlSend
                return pr.base
            }
            // Couldn't plant either — still a sandboxed give-up: keep err 1100 so the engine marks
            // it permanent (no retry spam / page leak, the reason for the permanent-refusal rule).
            lastInstallErr = 1100
            lastInstallFailure = planted.failure ?? "planted-entry-not-ready"
            return nil
        }
        if let report = install.report { lastInstallErr = report.err }
        // The READY boundary (codex review 2026-10-21): the pages existing is not the
        // agent being live — accept only the entry's published ready=1.
        lastInstallFailure = install.failure ?? "entry-not-ready:\(install.report.map { String(describing: $0.result) + "@0x" + String($0.base, radix: 16) } ?? "no-report")"
        return nil
    }

    /// Register this session with the agent (HELLO + the COMPLEX handshake).
    public func hello() -> Bool {
        guard connectAgent() else { return false }
        sendBytes = [UInt8](repeating: 0, count: 96)
        isOp = false
        withUnsafeBytes(of: helloToken) { sendBytes.replaceSubrange(24..<32, with: $0) }
        // HELLO v2: the service name at 32 (the agent looks it up in its own namespace and
        // answers the COMPLEX handshake there).
        let nameBytes = Array(toolService.utf8)
        sendBytes.replaceSubrange(32..<(32 + nameBytes.count), with: nameBytes)
        go.signal(); done.wait()
        guard krOut == KERN_SUCCESS else { lastOpStage = "hello-send=\(krOut)"; return false }
        var buf = [UInt8](repeating: 0, count: 128)
        let kr = buf.withUnsafeMutableBytes { b in
            mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                     MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 128, toolRcv, 5000, 0)
        }
        guard kr == KERN_SUCCESS else { lastOpStage = "handshake-rcv=\(kr)"; return false }
        // The COMPLEX handshake (the tool's `ToolHandshake` verbatim): header(24), port
        // descriptor at 24–39 (count, name, pads, disposition, type), token at 40.
        let id = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
        let token = buf.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
        guard id == 2003 && token == helloToken else {
            lastOpStage = "handshake-bad id=\(id) token=0x" + String(token, radix: 16); return false
        }
        return true
    }

    /// Where the last failed op stopped: the engine's diagnostic says which link broke —
    /// the HELLO/handshake, the op send (kr), or the ACK wait. nil = the last op answered.
    public private(set) var lastOpStage: String?

    /// One op, answered by its gen-matched ACK. nil = no answer; `.deferred` is a real answer:
    /// the row is pending in the agent and self-completes through the wake timer (P1c).
    public func op(apply: Bool, wid: UInt32, buttons: UInt64 = 0) -> Status? {
        // Planted (sandbox) agents have no HELLO session: send straight over the planted channel
        // with our receive port as the reply (the blob ACKs there), session 0. Bootstrap agents
        // register the session with HELLO first (hello() names its own failure stage).
        if planted {
            sendRemote = plantedCtrlSend
            opPlanted = true
            opReply = toolRcv
            opSession = 0
        } else {
            guard hello() else { return nil }
            opPlanted = false
            opSession = helloToken
        }
        let gen = UInt64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW))
        sendBytes = [UInt8](repeating: 0, count: 64)
        isOp = true
        opId = apply ? 3001 : 3002
        opMode = apply ? 1 : 2
        opGen = gen
        opWid = UInt64(wid)
        opButtons = buttons
        go.signal(); done.wait()
        guard krOut == KERN_SUCCESS else { lastOpStage = "op-send=\(krOut)"; return nil }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        while clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < 5_000_000_000 {
            var ack = [UInt8](repeating: 0, count: 128)
            let rkr = ack.withUnsafeMutableBytes { b in
                mach_msg(b.bindMemory(to: mach_msg_header_t.self).baseAddress!,
                         MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 128, toolRcv, 500, 0)
            }
            guard rkr == KERN_SUCCESS else { continue }
            let id = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: Int32.self) }
            guard id == 3010 else { continue }
            let ackGen = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }
            guard ackGen == gen else { continue }
            let status = ack.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: UInt64.self) }
            lastOpStage = nil
            return Status(rawValue: status)
        }
        lastOpStage = "no-ack"
        return nil
    }

    /// Remove the agent (P1d): invalidate, release, deallocate.
    public func removeAgent(base: UInt64) {
        _ = AgentInstaller(task: task).remove(pid: UInt64(pid), base: base)
    }
}
