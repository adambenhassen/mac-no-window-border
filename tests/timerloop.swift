import Foundation

// A process whose main run loop does one thing: fire a 1 ms default-mode timer. tests/timerwake.sh
// enters its main thread over and over and then watches the count. A run loop that loses a timer
// wake never re-arms that mode's timer port, so the count stops for good while the process lives
// on — the iTerm freeze of 2026-10-23, where a paste's chunk timer never fired again.
nonisolated(unsafe) var fired = 0
nonisolated(unsafe) var lastFire = DispatchTime.now().uptimeNanoseconds
nonisolated(unsafe) var maxGap: UInt64 = 0
let countLock = NSLock()
Timer.scheduledTimer(withTimeInterval: 0.001, repeats: true) { _ in
    let now = DispatchTime.now().uptimeNanoseconds
    countLock.lock()
    fired += 1
    maxGap = max(maxGap, now - lastFire)
    lastFire = now
    countLock.unlock()
}
Thread {
    while true {
        usleep(100_000)
        countLock.lock()
        let count = fired
        let gap = maxGap
        maxGap = 0
        countLock.unlock()
        print("fired \(count) maxgap_us \(gap / 1000)")
        fflush(stdout)
    }
}.start()
print("pid \(ProcessInfo.processInfo.processIdentifier)")
fflush(stdout)
RunLoop.main.run()
