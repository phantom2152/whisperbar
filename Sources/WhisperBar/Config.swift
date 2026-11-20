import Foundation

/// Fixed defaults. Folders the user can change in Settings are resolved through Settings.swift.
enum Config {
    /// Used until the user picks a different whisper.cpp folder in Settings.
    static let defaultWhisperRoot = "/Users/anishgowda/playground/ThirdParty/whisper.cpp"

    // Resolved from Settings, so the rest of the app doesn't care where these come from.
    static var whisperRoot: String { Settings.whisperRoot }
    static var serverBinary: String { whisperRoot + "/build/bin/whisper-server" }
    static var modelsDirectory: String { Settings.modelsDirectory }
    static var defaultModelPath: String { modelsDirectory + "/ggml-base.en.bin" }

    static let extraServerArguments: [String] = []  // e.g. ["--convert"] if you ever send non-WAV audio
    static let port = 9458
    static let logPath = "/tmp/whisperbar.log"
    static let historyLimit = 100
    static let idleShutdownSeconds: UInt64 = 600  // auto-stop the server after 10 idle minutes
}
