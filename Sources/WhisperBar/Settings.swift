import Foundation

/// Persisted user choices (UserDefaults).
enum Settings {
    static var modelPath: String {
        get { UserDefaults.standard.string(forKey: "modelPath") ?? Config.defaultModelPath }
        set { UserDefaults.standard.set(newValue, forKey: "modelPath") }
    }

    /// whisper language code, or "auto"
    static var language: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "language") }
    }

    static var startServerOnLaunch: Bool {
        get { UserDefaults.standard.bool(forKey: "startServerOnLaunch") }
        set { UserDefaults.standard.set(newValue, forKey: "startServerOnLaunch") }
    }

    static var autoCopy: Bool {
        get { UserDefaults.standard.object(forKey: "autoCopy") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "autoCopy") }
    }
}

struct Language: Sendable {
    let name: String
    let code: String
}

enum Languages {
    static let all: [Language] = [
        Language(name: "Auto-detect", code: "auto"),
        Language(name: "English", code: "en"),
        Language(name: "Hindi", code: "hi"),
        Language(name: "Kannada", code: "kn"),
        Language(name: "Tamil", code: "ta"),
        Language(name: "Telugu", code: "te"),
        Language(name: "Spanish", code: "es"),
        Language(name: "French", code: "fr"),
        Language(name: "German", code: "de"),
        Language(name: "Japanese", code: "ja"),
        Language(name: "Chinese", code: "zh"),
    ]
}

struct ModelInfo: Sendable {
    let path: String
    let name: String
    let size: String
}

/// Finds the ggml-*.bin models in whisper.cpp/models.
enum ModelCatalog {
    static func scan() -> [ModelInfo] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: Config.modelsDirectory)) ?? []
        let found: [(info: ModelInfo, bytes: Int64)] = files
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin")
                      && !$0.contains("silero") && !$0.contains("for-tests") }
            .map { file in
                let path = Config.modelsDirectory + "/" + file
                let attrs = try? fm.attributesOfItem(atPath: path)
                let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                let size = bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : ""
                return (ModelInfo(path: path, name: displayName(for: path), size: size), bytes)
            }
        return found.sorted { $0.bytes != $1.bytes ? $0.bytes < $1.bytes : $0.info.name < $1.info.name }
            .map { $0.info }
    }

    /// "/…/ggml-base.en.bin" → "base.en"
    static func displayName(for path: String) -> String {
        var name = URL(fileURLWithPath: path).lastPathComponent
        if name.hasPrefix("ggml-") { name.removeFirst(5) }
        if name.hasSuffix(".bin") { name.removeLast(4) }
        return name
    }

    /// The “.en” models only understand English.
    static func isEnglishOnly(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.contains(".en.") || name.contains(".en-")
    }
}
