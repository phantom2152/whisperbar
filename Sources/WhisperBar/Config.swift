import Foundation

/// Fixed paths and defaults. User-changeable options (model, language, …) live in Settings.swift.
enum Config {
    static let whisperRoot = "/Users/anishgowda/playground/ThirdParty/whisper.cpp"
    static let serverBinary = whisperRoot + "/build/bin/whisper-server"
    static let modelsDirectory = whisperRoot + "/models"
    static let defaultModelPath = modelsDirectory + "/ggml-base.en.bin"
    static let extraServerArguments: [String] = []      // e.g. ["--convert"] if you ever send non-WAV audio
    static let port = 9458
    static let logPath = "/tmp/whisperbar.log"
    static let historyLimit = 100
}
