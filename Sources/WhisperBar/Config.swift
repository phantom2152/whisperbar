import Foundation

/// Everything you might want to tweak lives here.
enum Config {
    static let whisperRoot = "/Users/anishgowda/playground/ThirdParty/whisper.cpp"
    static let serverBinary = whisperRoot + "/build/bin/whisper-server"
    static let modelPath = whisperRoot + "/models/ggml-base.en.bin"
    static let extraServerArguments: [String] = []
    static let port = 9458
    static let logPath = "/tmp/whisperbar.log"
    static let historyLimit = 100
}
