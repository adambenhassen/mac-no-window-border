import Foundation
import XCTest

/// Test utility: asks the system assembler for the bytes of hand-written arm64 instructions so
/// generated encodings can be compared against them.
final class AssemblerCheck {
    struct Failed: Error { let reason: String }
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

    var available: Bool { which("clang") != nil && which("otool") != nil }

    private func which(_ tool: String) -> String? {
        let out = run("/usr/bin/xcrun", ["--find", tool])
        return out?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bytes of hand-written assembly. Lines ending in ":" are labels and emit no bytes.
    func bytes(forHand lines: [String]) throws -> [UInt32] { try assemble(lines.joined(separator: "\n"), name: "hand") }

    /// Bytes of the same instructions expressed as the words we generated.
    func bytes(forWords words: [UInt32]) throws -> [UInt32] {
        var lines: [String] = []
        for word in words { lines.append(String(format: ".word 0x%08x", word)) }
        return try assemble(lines.joined(separator: "\n"), name: "words")
    }

    private func assemble(_ source: String, name: String) throws -> [UInt32] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(name).s")
        try (".text\n" + source + "\n").write(to: path, atomically: true, encoding: .utf8)
        let object = dir.appendingPathComponent("\(name).o")
        try? FileManager.default.removeItem(atPath: object.path)   // a stale .o masks a failed clang
        let clang = run("/usr/bin/xcrun", ["clang", "-c", "-arch", "arm64", "-o", object.path, path.path],
                        captureStderr: true)
        guard FileManager.default.fileExists(atPath: object.path) else {
            throw Failed(reason: "assembling \(name).s failed: \(clang ?? "no output")\nsource: \(source)")
        }
        guard let dump = run("/usr/bin/xcrun", ["otool", "-X", "-s", "__TEXT", "__text", object.path]) else {
            throw Failed(reason: "could not read __text of \(name).o")
        }
        return dump.split(whereSeparator: \.isNewline).flatMap { line in
            line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { UInt32($0, radix: 16) }
        }
    }

    @discardableResult
    private func run(_ launch: String, _ arguments: [String], captureStderr: Bool = false) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launch)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        let errPipe = Pipe()
        process.standardError = captureStderr ? errPipe : Pipe()
        do { try process.run() } catch { return nil }
        process.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if captureStderr {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return out + err
        }
        return out
    }
}
