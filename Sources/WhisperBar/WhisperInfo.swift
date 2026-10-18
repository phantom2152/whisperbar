import Foundation

/// Reads the version of your whisper.cpp checkout (git tag + commit, or CMake version).
enum WhisperInfo {
    /// Blocking (runs git): call from a background task.
    static func versionString() -> String {
        if let described = run("/usr/bin/git", ["-C", Config.whisperRoot, "describe", "--tags", "--always"]),
           !described.isEmpty {
            return described
        }
        let cmake = Config.whisperRoot + "/CMakeLists.txt"
        if let text = try? String(contentsOfFile: cmake, encoding: .utf8),
           let re = try? NSRegularExpression(pattern: #"project\s*\([^)]*?VERSION\s+([0-9][0-9.]*)"#),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(m.range(at: 1), in: text) {
            return "v" + text[r]
        }
        return "unknown version"
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
