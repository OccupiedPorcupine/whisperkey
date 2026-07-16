import Foundation

/// Recent dictations, newest first, persisted next to the config so they
/// survive restarts. Everything stays on disk in the user's home — history is
/// as local as the transcription itself. Surfaced as a menu-bar submenu where a
/// click re-copies the transcript.
final class HistoryStore {
    struct Entry: Codable {
        let text: String
        let date: Date
    }

    private(set) var entries: [Entry] = []
    var limit = 25 {
        didSet { if entries.count > max(limit, 0) { trimAndSave() } }
    }

    private let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/whisperkey/history.json")

    init() {
        load()
    }

    func add(_ text: String) {
        guard limit > 0 else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.insert(Entry(text: trimmed, date: Date()), at: 0)
        trimAndSave()
    }

    func clear() {
        entries = []
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func trimAndSave() {
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        entries = (try? decoder.decode([Entry].self, from: data)) ?? []
    }
}
