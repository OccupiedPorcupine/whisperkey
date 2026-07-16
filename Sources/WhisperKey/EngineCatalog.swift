import Foundation

/// Single source of truth for the selectable transcription engines, so the menu
/// bar, the bubble badge, and the transcriber factory never drift apart.
enum EngineCatalog {
    struct Option {
        let id: String          // persisted in config.engine
        let menuTitle: String   // long label for the menu bar
        let badge: String       // short label for the bubble badge
        let available: Bool     // false → selectable but currently falls back
    }

    static let all: [Option] = [
        Option(id: "apple",      menuTitle: "Apple Speech",         badge: "Apple",    available: true),
        Option(id: "whisperkit", menuTitle: "WhisperKit (Whisper)", badge: "Whisper",  available: true),
        Option(id: "parakeet",   menuTitle: "Parakeet (NVIDIA)",    badge: "Parakeet", available: true),
    ]

    static func option(for id: String) -> Option {
        all.first { $0.id == id } ?? all[0]
    }

    /// The engine id that actually transcribes for a given selection. Every
    /// listed engine is real and available, so a selection always maps to itself
    /// (unknown ids fall back to the first option).
    static func resolved(_ id: String) -> String {
        option(for: id).id
    }

    /// The id after `id` in the list, wrapping around — used by the bubble badge
    /// to cycle engines on click.
    static func next(after id: String) -> String {
        guard let idx = all.firstIndex(where: { $0.id == id }) else { return all[0].id }
        return all[(idx + 1) % all.count].id
    }
}
