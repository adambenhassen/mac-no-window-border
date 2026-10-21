// Test app for tests/e2e.sh: one window filling the primary screen's usable area ("max") and
// one floating window, both dark. Prints "<name> <wid>" per window, then idles.
// SIGUSR1 shrinks "max" to 600x400; SIGUSR2 makes it fill the usable area again.
// SIGCONT focuses "max" (the app activates, the window becomes key); SIGWINCH defocuses it
// (the window goes back, the app deactivates). A focus cycle is the window's key state changing.
// With the "busy" argument (tests/idle.sh), the main thread keeps running ~50 ms blocks and
// almost never waits in its run loop; SIGHUP stops that, so the app becomes idle.
// With the "spin" argument (tests/engine.sh), the main thread never comes back to its run loop at
// all: there is no moment when it is parked. SIGTERM stops it.
// With the "small" argument, "max" starts at the 600x400 size, so it is never maximized.
// With the "tick" argument (tests/pausebench.sh), a 1 ms main-queue timer reports every 5 s the
// longest gap between its fires: that gap is how long the main thread was not running its own
// queue, which is what an engine's stop costs an app.
// With the "outline" argument (tests/flash.sh), "max" draws its OWN 2 px focus outline in its
// content view, redrawn synchronously on key changes — the iTerm class: client pixels no
// server-side shape/shadow call can touch. NOBORDER_HOST_DELAY=1 repaints 0.5 s late instead
// (the delayed-redraw path).
// With the "restoreobs" argument (tests/flash.sh), "max" re-enables its shadow synchronously on
// didBecomeKey — a rim-restoring observer: any out-of-process apply lands a frame late.
// With the "tracking" argument (the resident agent's P1a), the app runs a menu-tracking-like
// session every 3 s: the main loop pumps events in NSMenuTrackingMode for ~2 s. A run-loop
// source registered only in commonModes does not fire there; a source in this mode does. That
// is the measurement mode's whole purpose.
// With the "agent" argument (P1a-0, codex verdict 5 build order), "max"'s process runs the
// resident transport in ORDINARY LINKED CODE: a target-allocated receive right wrapped in a
// CFMachPort, a run-loop source in commonModes, and a callback that books the ping (counter)
// and ACKs it on the ping's send-once reply right — no draining, no receives, no task-port ops
// by the tool after the send right is extracted. "agent port <n>" on stdout is the handle.
// Verdict-5 rules honored: version-0 context with NULL callbacks, everything retained until
// exit, the callback validates {id, seq} and returns, ACK is a fixed-size {id, seq, counter}.
import AppKit
import Darwin   // task_get_bootstrap_port (mach/task_special_ports.h), bootstrap_register (bootstrap.h)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let usable = NSScreen.screens[0].visibleFrame

func makeWindow(_ name: String, _ frame: NSRect) -> NSWindow {
    let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable],
                     backing: .buffered, defer: false)
    w.title = name
    w.appearance = NSAppearance(named: .darkAqua)
    w.backgroundColor = NSColor(white: 0.05, alpha: 1)
    w.setFrame(frame, display: false)
    w.orderBack(nil)  // stay behind the user's windows; still on screen for the scanner
    print(name, w.windowNumber)
    return w
}

let small = NSRect(x: usable.minX + 200, y: usable.minY + 150, width: 600, height: 400)
let maxWindow = makeWindow("max", CommandLine.arguments.contains("small") ? small : usable)
let floating = makeWindow("floating", NSRect(x: usable.minX + 100, y: usable.minY + 100, width: 400, height: 300))
var idInfo = thread_identifier_info()
var idCount = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
withUnsafeMutablePointer(to: &idInfo) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(idCount)) {
    thread_info(pthread_mach_thread_np(pthread_self()), thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &idCount) } }
print("mainthreadid", idInfo.thread_id)
fflush(stdout)

var sources: [DispatchSourceSignal] = []
var tickTimer: DispatchSourceTimer?   // kept here: a source that goes out of scope is released and stops firing
var churnTimer: DispatchSourceTimer?
var spinCount = 0   // written by the "spin" mode below, so the loop around it cannot be optimized out
for (sig, frame) in [(SIGUSR1, small), (SIGUSR2, usable)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { maxWindow.setFrame(frame, display: true) }
    source.resume()
    sources.append(source)
}
for (sig, focus) in [(SIGCONT, true), (SIGWINCH, false)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            maxWindow.makeKeyAndOrderFront(nil)
        } else {
            maxWindow.orderBack(nil)
            NSApp.deactivate()
        }
    }
    source.resume()
    sources.append(source)
}

var busy = CommandLine.arguments.contains("busy")
func spin() {
    guard busy else { return }
    let end = Date().addingTimeInterval(0.05)
    while Date() < end {}
    DispatchQueue.main.async(execute: spin)
}
signal(SIGHUP, SIG_IGN)
let hup = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
hup.setEventHandler { busy = false }
hup.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: spin)  // after the first draw
if CommandLine.arguments.contains("spin") {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {   // after the first draw
        while true { spinCount &+= 1 }    // a hard spin; the counter keeps the optimiser away
    }
}
if CommandLine.arguments.contains("churn") {
    // WindowServer churn (tests/poison.sh): flip the window's shadow at 60 Hz — a setHasShadow:
    // MIG round-trip, the same port the engine's selector calls churn — and redraw the content
    // each frame (CoreAnimation commits). The poison's landing window scales with this load;
    // plain idling apps give it almost none.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.001, repeating: 1.0 / 60.0, leeway: .never)
    var tick = 0
    timer.setEventHandler {
        tick += 1
        maxWindow.hasShadow = (tick % 2 == 0)
        maxWindow.contentView?.needsDisplay = true
    }
    timer.resume()
    churnTimer = timer
}
if CommandLine.arguments.contains("tick") {
    // Zero leeway: the timer is asked for every 1 ms and the gap between two fires is measured, so
    // nothing but the main thread being busy (or stopped) can widen it. The 1 ms period is
    // subtracted, so an app that is left alone reports 0.
    // The source is kept in a top-level array: a dispatch source that goes out of scope is released,
    // and a released source stops firing.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 0.001, repeating: 0.001, leeway: .never)
    var last = DispatchTime.now().uptimeNanoseconds
    var worst: UInt64 = 0
    var windowEnd = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    timer.setEventHandler {
        let now = DispatchTime.now().uptimeNanoseconds
        worst = max(worst, now - last)
        last = now
        guard now >= windowEnd else { return }
        print("maxgap_ms=\(max(0, Int(worst) - 1_000_000) / 1_000_000)")
        fflush(stdout)
        worst = 0
        windowEnd = now + 5_000_000_000
    }
    timer.resume()
    tickTimer = timer
}
// Self-drawn focus rim (the "outline" mode): the content view paints its own 2 px outline in
// its key state, so the rim is client pixels — drawn in the view, not by the server.
final class RimView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 0.05, alpha: 1).setFill()
        dirtyRect.fill()
        (window?.isKeyWindow ?? false ? NSColor.controlAccentColor : NSColor(white: 0.25, alpha: 1)).setStroke()
        let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        p.lineWidth = 2
        p.stroke()
    }
}

if CommandLine.arguments.contains("outline") {
    let delayed = ProcessInfo.processInfo.environment["NOBORDER_HOST_DELAY"] != nil
    maxWindow.contentView = RimView(frame: maxWindow.contentRect(forFrameRect: maxWindow.frame))
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
        NotificationCenter.default.addObserver(forName: name, object: maxWindow, queue: .main) { _ in
            // The redraw lands in the same event pass AppKit uses for its own focus repaint,
            // or NOBORDER_HOST_DELAY seconds late.
            DispatchQueue.main.asyncAfter(deadline: .now() + (delayed ? 0.5 : 0)) {
                maxWindow.contentView?.needsDisplay = true
                maxWindow.display()
            }
        }
    }
}
var trackingTimer: DispatchSourceTimer?
if CommandLine.arguments.contains("tracking") {
    // Every 3 s, pump events in NSMenuTrackingMode for ~2 s: the loop is live (events answered)
    // but its mode is not a commonMode. "mainloopbusy"-style: a source only in commonModes
    // starves; one added to this mode fires. The count of sessions is printed so a test can
    // time source callbacks against them.
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 3.0)
    var sessions = 0
    let trackingMode = RunLoop.Mode(rawValue: "NSMenuTrackingMode")
    timer.setEventHandler {
        sessions += 1
        for _ in 0..<200 {
            _ = NSApp.nextEvent(matching: .leftMouseUp,
                                until: Date().addingTimeInterval(0.01),
                                inMode: trackingMode, dequeue: true)
        }
        print("tracking session \(sessions) done")
        fflush(stdout)
    }
    timer.resume()
    trackingTimer = timer
}
var trackingSigSource: DispatchSourceSignal?
if CommandLine.arguments.contains("trackingsig") {
    // The same NSMenuTrackingMode pump, started per SIGUSR1: a blob test installs the agent
    // BEFORE the pump exists (a startup pump never lets the parked-run-loop executor in).
    let sigsrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    signal(SIGUSR1, SIG_IGN)
    var sessions = 0
    let trackingMode = RunLoop.Mode(rawValue: "NSMenuTrackingMode")
    sigsrc.setEventHandler {
        sessions += 1
        for _ in 0..<200 {
            _ = NSApp.nextEvent(matching: .leftMouseUp,
                                until: Date().addingTimeInterval(0.01),
                                inMode: trackingMode, dequeue: true)
        }
        print("tracking session \(sessions) done")
        fflush(stdout)
    }
    sigsrc.resume()
    trackingSigSource = sigsrc
}
var deferSigSource: DispatchSourceSignal?
if CommandLine.arguments.contains("defersig") {
    // The deterministic modeGate deferral pump, per SIGUSR1: pump events in a custom mode
    // registered as a COMMON mode. A CFMachPort source in commonModes FIRES inside this
    // loop (unlike NSMenuTrackingMode, which starves it), and the run loop's real current
    // mode is not kCFRunLoopDefaultMode — the blob's op path must answer `deferred`, arm
    // its wake timer, and complete the row when control returns to the default mode.
    signal(SIGUSR1, SIG_IGN)
    let sigsrc = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    var sessions = 0
    let deferMode = RunLoop.Mode(rawValue: "DeferTestMode")
    // CFRunLoopMode is a distinct imported type in this SDK; the mode string and the mode
    // are the same CF object (bridged), so the cast is the documented toll-free shape.
    // Required for the deferral: registering DeferTestMode as a common mode puts the agent's
    // CFMachPort source in it, so the op is DELIVERED mid-session and the blob's default-mode
    // gate answers `deferred` (starvation, by contrast, never runs the callback at all).
    CFRunLoopAddCommonMode(CFRunLoopGetMain(),
        unsafeBitCast(deferMode.rawValue as CFString, to: CFRunLoopMode.self))
    sigsrc.setEventHandler {
        sessions += 1
        // Debug: what the run loop sees from inside the session — the real current mode
        // (the blob's gate compares this) and the source array of the mode (the blob's
        // CFMachPort source must be in it for delivery to happen here).
        let rl = CFRunLoopGetMain()
        if let cur = CFRunLoopCopyCurrentMode(rl) {
            // CFRunLoopMode bridges as a distinct type; the underlying object is the mode
            // string (toll-free), so read it as CFString for the log line.
            print("defer session \(sessions): currentMode=\(unsafeBitCast(cur, to: CFString.self) as String)")
        }
        // Real CF-mode pumping (NSApp.nextEvent(inMode:) is AppKit event filtering; the CF
        // run loop stays in kCFRunLoopDefaultMode under it — measured 2026-10-21).
        // CFRunLoopRunInMode puts the loop in DeferTestMode proper: common-mode sources
        // fire and CFRunLoopCopyCurrentMode answers DeferTestMode.
        let cfDefer = unsafeBitCast(deferMode.rawValue as CFString, to: CFRunLoopMode.self)
        print("defer session \(sessions): cfDefer=\(unsafeBitCast(cfDefer, to: CFString.self) as String)")
        let end = Date().addingTimeInterval(2)
        var logged = false
        while Date() < end {
            _ = CFRunLoopRunInMode(cfDefer, 0.01, true)
            if !logged, let cur = CFRunLoopCopyCurrentMode(rl) {
                print("defer loop: in-loop mode=\(unsafeBitCast(cur, to: CFString.self) as String)")
                logged = true
            }
        }
        print("defer session \(sessions) done")
        fflush(stdout)
    }
    sigsrc.resume()
    deferSigSource = sigsrc
}
// The P1a-0 transport, in ordinary linked code (codex verdict 5 build order). One message
// shape both sides share: header {bits,size,remote,local,reserved,id} + seq + counter, 40 B.
// Ping id 2001, ack id 2002. The callback validates {id, seq}, books the counter, and replies
// on the ping's send-once right — it never receives, never drains, never blocks.
struct AgentMsg {
    var msgh: mach_msg_header_t = mach_msg_header_t(msgh_bits: 0, msgh_size: 0,
                                                    msgh_remote_port: 0, msgh_local_port: 0,
                                                    msgh_voucher_port: 0, msgh_id: 0)
    var seq: UInt64 = 0
    var counter: UInt64 = 0
}

var agentCounter: UInt64 = 0
var agentKeepAlive: (mp: CFMachPort, src: CFRunLoopSource)?
var agentPortName: mach_port_name_t = 0   // for the rendezvous callback (C callbacks cannot capture)
var agentToolSend: mach_port_name_t = 0   // the tool's registered port, kept (COPY_SEND) for ACKs
var agentKeepAlive2: (mp: CFMachPort, src: CFRunLoopSource)?

// The rendezvous message, in the kernel's exact LP64 layout (message.h, pack(4)):
// header(24) + msgh_descriptor_count@24 + mach_msg_port_descriptor_t: name@28(4), pad1@32(4),
// pad2@36(2), disposition@38(1), type@39(1) + token@40(8) = 48 B, msgh COMPLEX.
// The agent hands the tool a SEND right on its CFMachPort by moving it in this message — the
// capability-safe handoff (cross-task mach_port_extract_right is refused on this OS: kr 18
// KERN_INVALID_CAPITAL, measured 2026-10-20; and a disposition byte written in the TYPE slot
// = MACH_SEND_INVALID_TYPE 0x1000000f, measured the same day).
struct AgentHandshake {
    var msgh: mach_msg_header_t = mach_msg_header_t(msgh_bits: 0, msgh_size: 0,
                                                    msgh_remote_port: 0, msgh_local_port: 0,
                                                    msgh_voucher_port: 0, msgh_id: 0)
    var descCount: UInt32 = 1         // 24: mach_msg_body_t.msgh_descriptor_count
    var descName: UInt32 = 0          // 28
    var descPad1: UInt32 = 0          // 32
    var descPad2: UInt16 = 0          // 36
    var descDisposition: UInt8 = 17   // 38: kernel MACH_MSG_TYPE_MOVE_SEND
    var descType: UInt8 = 0           // 39: MACH_MSG_PORT_DESCRIPTOR
    var token: UInt64 = 0             // 40
}

if let ai = CommandLine.arguments.firstIndex(of: "agent") {
    // "agent": CFMachPortCreate + source, print "agent port <n>", then take the rendezvous
    // "<port-name> <token>" from stdin once the tool has remote-allocated that receive entry
    // in THIS task — argv cannot carry it: it does not exist until after launch.
    // "agent <name> <token>" hands it in at startup instead (tool's port created first).
    let selfName = mach_port_name_t(mach_task_self_)
    let cb: CFMachPortCallBack = { _, msg, size, _ in
        guard let msg, size >= MemoryLayout<AgentMsg>.stride else { return }
        let m = msg.loadUnaligned(fromByteOffset: 0, as: AgentMsg.self)   // borrowed buffer: read, do not free
        if ProcessInfo.processInfo.environment["HOSTAPP_AGENT_DEBUG"] != nil {
            print("agent cb size=\(size) id=\(m.msgh.msgh_id) seq=\(m.seq) local=\(m.msgh.msgh_local_port)"); fflush(stdout)
        }
        guard m.msgh.msgh_id == 2001 else { return }
        agentCounter += 1
        guard agentToolSend != MACH_PORT_NULL else { return }
        // Plain ACK to the tool's registered port (COPY_SEND: the send is kept for every ACK).
        var ack = AgentMsg(msgh: mach_msg_header_t(
            msgh_bits: 0x13,   // MACH_MSGH_BITS(COPY_SEND, PORT_NONE): send on the kept send right, no reply port (this shape shipped green for years)
            msgh_size: UInt32(MemoryLayout<AgentMsg>.stride),
            msgh_remote_port: agentToolSend, msgh_local_port: 0,
            msgh_voucher_port: 0, msgh_id: 2002), seq: m.seq, counter: agentCounter)
        let krAck = withUnsafeMutablePointer(to: &ack.msgh) {
            // TIMEOUT option with timeout 0: the only send spelling that cannot wait on the
            // main thread (verdict 6; TIMEOUT_NONE names the absence of the option, not a zero
            // timeout, and a plain send can block for queue space).
            mach_msg($0, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(MemoryLayout<AgentMsg>.stride),
                     0, mach_port_name_t(MACH_PORT_NULL), 0, 0)
        }
        if ProcessInfo.processInfo.environment["HOSTAPP_AGENT_DEBUG"] != nil {
            print("agent ack kr=\(krAck) seq=\(m.seq) counter=\(agentCounter)"); fflush(stdout)
        }
    }
    var ctx = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    // CFMachPortCreate: CF creates and owns the rights (verdict 5 Q2 — the clean ownership
    // story; no manual allocate, no CreateWithPort adoption questions).
    var available: DarwinBoolean = false
    guard let mp = withUnsafeMutablePointer(to: &ctx, { CFMachPortCreate(kCFAllocatorDefault, cb, $0, &available) }),
          let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mp, 0) else {
        print("agent install failed"); fflush(stdout); exit(1)
    }
    let portName = CFMachPortGetPort(mp)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    agentKeepAlive = (mp, src)   // retained for the process lifetime; teardown is the kernel's
    print("agent port \(portName)")
    fflush(stdout)

    // Rendezvous (P1a-0, the shipped-safe shape): we register a rendezvous port in the
    // bootstrap namespace ("com.noborder.rz.<pid>"); the tool looks it up and sends HELLO
    // {token} with a send-once reply right. The callback replies with the handshake — a
    // COMPLEX message MOVing a SEND on our CFMachPort — on that reply right. Zero task-port
    // ops by the tool, and no mutation of the app's registered ports (mach_ports_register
    // measured inert on macOS 15: kr 0, AppKit's set unchanged, 2026-10-20).
    agentPortName = portName
    let rzService = "com.noborder.rz.\(getpid())"
    var bs: mach_port_name_t = 0
    _ = task_get_special_port(mach_task_self_, 4, &bs)   // BOOTSTRAP_PORT (task_special_ports.h inline
                                                         // wrapper is not imported; the RPC under it is)
    typealias BootstrapRegisterFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, mach_port_name_t) -> Int32
    let bootstrapRegister: BootstrapRegisterFn? = dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_register")
        .map { unsafeBitCast($0, to: BootstrapRegisterFn.self) }
    var rz: mach_port_name_t = 0
    var krRz = mach_port_allocate(selfName, mach_port_right_t(MACH_PORT_RIGHT_RECEIVE), &rz)
    krRz = mach_port_insert_right(selfName, rz, rz, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    let helloCb: CFMachPortCallBack = { _, msg, size, _ in
        // HELLO v2 (verdict 6, frozen before assembly): {header, token@24, service name[64]@32},
        // 96 bytes. The name rides in the message, so there is no counter field to format — and
        // a name at offset 32 would have overlapped the 40-byte ping's counter.
        guard let msg, size >= 96 else { return }
        let id = msg.loadUnaligned(fromByteOffset: 20, as: Int32.self)
        guard id == 2004 else { return }
        let token = msg.loadUnaligned(fromByteOffset: 24, as: UInt64.self)
        // Copy the borrowed name out and require a NUL inside the 64 bytes before any string
        // API sees it.
        var nameBytes = [UInt8](repeating: 0, count: 64)
        nameBytes.withUnsafeMutableBytes { dest in
            memcpy(dest.baseAddress!, msg.advanced(by: 32), 64)
        }
        guard let nul = nameBytes.firstIndex(of: 0), nul > 0 else { return }
        let toolService = String(decoding: nameBytes[0..<nul], as: UTF8.self)
        // Mutual bootstrap rendezvous: the tool registered its handshake port under this name;
        // we look it up and send the COMPLEX handshake (MOVE_SEND on our CFMachPort) straight
        // to it. No reply rights: a send-once reply lands on msgh_local_port and the kernel
        // destroys/overwrites the receiver's right THERE (measured 2026-10-20: CF's port,
        // send kr=0, tool recv starved — CFMachPort callbacks cannot receive reply rights).
        typealias BootstrapLookUpFn = @convention(c) (mach_port_name_t, UnsafePointer<Int8>, UnsafeMutablePointer<mach_port_name_t>) -> Int32
        guard let lookUp = dlsym(dlopen(nil, RTLD_LAZY), "bootstrap_look_up")
                .map({ unsafeBitCast($0, to: BootstrapLookUpFn.self) }) else { return }
        var bs: mach_port_name_t = 0
        _ = task_get_special_port(mach_task_self_, 4, &bs)
        var toolPort: mach_port_name_t = 0
        let lr = toolService.withCString { lookUp(bs, $0, &toolPort) }
        print("agent tool look-up \(toolService) r \(lr)")
        guard lr == 0 else { fflush(stdout); return }
        agentToolSend = toolPort   // kept: the handshake goes COPY_SEND, ACKs reuse it
        let krIns = mach_port_insert_right(mach_port_name_t(mach_task_self_), agentPortName, agentPortName,
                                           mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
        print("agent insert kr \(krIns)")
        var hs = AgentHandshake(msgh: mach_msg_header_t(
            msgh_bits: 0x8000_0013,           // MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(COPY_SEND,
                                              // PORT_NONE): the descriptor carries the port right,
                                              // the header declares no local right (this shape
                                              // shipped green for years)
            msgh_size: UInt32(MemoryLayout<AgentHandshake>.stride),
            msgh_remote_port: toolPort, msgh_local_port: 0,
            msgh_voucher_port: 0, msgh_id: 2003),
            descName: agentPortName, descDisposition: 17, token: token)
        let krSend = withUnsafeMutablePointer(to: &hs.msgh) {
            mach_msg($0, MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(MemoryLayout<AgentHandshake>.stride),
                     0, mach_port_name_t(MACH_PORT_NULL), 0, 0)   // TIMEOUT option + 0: never waits
        }
        print("agent handshake kr \(krSend) token \(token)")
        fflush(stdout)
    }

    var ctx2 = CFMachPortContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
    var available2: DarwinBoolean = false
    guard let mp2 = withUnsafeMutablePointer(to: &ctx2, { CFMachPortCreateWithPort(kCFAllocatorDefault, rz, helloCb, $0, &available2) }),
          let src2 = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, mp2, 0) else {
        print("agent rendezvous install failed"); fflush(stdout); exit(1)
    }
    CFRunLoopAddSource(CFRunLoopGetMain(), src2, .commonModes)
    agentKeepAlive2 = (mp2, src2)
    let krReg = rzService.withCString { cstr in
        bootstrapRegister.map { f in f(bs, cstr, rz) } ?? -1   // -1 = symbol absent
    }
    print("agent service \(rzService) register kr \(krReg) (rz port \(rz), krRz \(krRz))")
    fflush(stdout)
}

if CommandLine.arguments.contains("restoreobs") {
    // Rim-restoring observer: becoming key puts AppKit's shadow back synchronously, so a
    // border-removal applied out-of-process is a frame late — the adversarial apply side.
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                           object: maxWindow, queue: .main) { _ in
        maxWindow.hasShadow = true
    }
}

app.run()
