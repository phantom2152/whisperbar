import Foundation

struct Transcript: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    let date: Date
    var text: String
    var duration: TimeInterval        // seconds of audio
}

/// Saved takes, newest first. Persisted to ~/Library/Application Support/WhisperBar/history.json
@MainActor
final class TranscriptStore {
    private(set) var items: [Transcript] = []
    var onChange: (@MainActor () -> Void)?

    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("WhisperBar", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        load()
    }

    @discardableResult
    func add(text: String, duration: TimeInterval) -> Transcript {
        let t = Transcript(id: UUID(), date: Date(), text: text, duration: duration)
        items.insert(t, at: 0)
        if items.count > Config.historyLimit { items.removeLast(items.count - Config.historyLimit) }
        save()
        onChange?()
        return t
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
        onChange?()
    }

    func clear() {
        items.removeAll()
        save()
        onChange?()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([Transcript].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
