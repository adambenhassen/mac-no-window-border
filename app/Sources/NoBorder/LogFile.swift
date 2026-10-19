import Foundation

/// The app's log file: `~/Library/Logs/macos-no-window-border.log`, opened for appending.
///
/// Both engines write here, in the same format, so a user with a bug report has one file to send
/// whichever engine was running. Opening it is best-effort by design: a log that cannot be opened
/// must not stop the app from changing windows, and a write failure stops the logging and says so
/// once through `NSLog`.
enum LogFile {
    static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/macos-no-window-border.log")
    }

    /// nil means logging is off.
    static func open() -> FileHandle? {
        let path = url.path
        if !FileManager.default.fileExists(atPath: path) {
            guard FileManager.default.createFile(atPath: path, contents: nil) else { return nil }
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        handle.seekToEndOfFile()
        return handle
    }

    /// One line, timestamped the way the daemon's output is, so the two engines' lines line up in one
    /// file. Returns false when the write failed; the caller drops the handle.
    static func write(_ handle: FileHandle, _ line: String) -> Bool {
        let stamped = "\(Date.noborderTimestamp) \(line)\n"
        guard let data = stamped.data(using: .utf8) else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            NSLog("NoBorder: stopped writing the log: %@", error.localizedDescription)
            return false
        }
    }
}

private extension Date {
    /// "2026-10-19 07:41:21", the daemon's format: the same file, the same shape of line.
    static var noborderTimestamp: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }
}
