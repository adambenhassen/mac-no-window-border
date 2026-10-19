// Test app for tests/e2e.sh: one window filling the primary screen's usable area ("max") and
// one floating window, both dark. Prints "<name> <wid>" per window, then idles.
// SIGUSR1 shrinks "max" to 600x400; SIGUSR2 makes it fill the usable area again.
// With the "busy" argument (tests/idle.sh), the main thread keeps running ~50 ms blocks and
// almost never waits in its run loop; SIGHUP stops that, so the app becomes idle.
// With the "spin" argument (tests/engine.sh), the main thread never comes back to its run loop at
// all: there is no moment when it is parked. SIGTERM stops it.
// With the "small" argument, "max" starts at the 600x400 size, so it is never maximized.
// With the "tick" argument (tests/pausebench.sh), a 1 ms main-queue timer reports every 5 s the
// longest gap between its fires: that gap is how long the main thread was not running its own
// queue, which is what an engine's stop costs an app.
import AppKit

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
var spinCount = 0   // written by the "spin" mode below, so the loop around it cannot be optimized out
for (sig, frame) in [(SIGUSR1, small), (SIGUSR2, usable)] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler { maxWindow.setFrame(frame, display: true) }
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
app.run()
