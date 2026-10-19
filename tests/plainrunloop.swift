import Foundation

// A process with a main run loop and no AppKit: the target the engine must refuse (its main thread
// parks in the run loop, so the park check passes, and there is no NSApplication to send anything
// to). tests/e2e.sh's native path runs the engine against this and expects "skipped (not AppKit)".
print("pid \(ProcessInfo.processInfo.processIdentifier)")
RunLoop.main.run()
