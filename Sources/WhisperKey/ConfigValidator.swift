import Foundation

/// Sanity-checks a loaded config and returns human-readable problems. WhisperKey
/// tolerates a bad config (every field falls back to a default), so mistakes are
/// otherwise silent — this surfaces them in the menu bar instead of the log.
enum ConfigValidator {
    /// Pure, filesystem-free checks: unknown enum-ish values and out-of-range
    /// numbers. Split out so it can be unit-tested without touching disk.
    static func structuralWarnings(for c: Config) -> [String] {
        var out: [String] = []

        let engineIDs = Set(EngineCatalog.all.map { $0.id })
        if !engineIDs.contains(c.engine) {
            out.append("Unknown engine \"\(c.engine)\" — using Apple Speech.")
        }
        if !["toggle", "push_to_talk"].contains(c.mode) {
            out.append("Unknown mode \"\(c.mode)\" — using toggle.")
        }
        if !["paste", "type", "clipboard"].contains(c.output) {
            out.append("Unknown output \"\(c.output)\" — using paste.")
        }
        if !["apple", "neural"].contains(c.ttsEngine) {
            out.append("Unknown ttsEngine \"\(c.ttsEngine)\" — using Apple voice.")
        }
        if !["notch", "top-center", "bottom-center"].contains(c.bubblePosition) {
            out.append("Unknown bubblePosition \"\(c.bubblePosition)\" — using bottom-center.")
        }
        if c.historyLimit < 0 {
            out.append("historyLimit is negative — history is disabled.")
        }
        if c.obsidianLogging, !c.obsidianNoteNameFormat.contains("{title}") {
            out.append("obsidianNoteNameFormat has no {title} — archived notes share one name base.")
        }
        return out
    }

    /// All warnings: the structural ones plus checks that hit the filesystem
    /// (does the configured / detected Obsidian vault actually exist).
    static func warnings(for c: Config) -> [String] {
        var out = structuralWarnings(for: c)

        let explicitPath = c.obsidianVaultPath.trimmingCharacters(in: .whitespaces)
        if !explicitPath.isEmpty, ObsidianVault.resolve(configuredPath: explicitPath) == nil {
            out.append("obsidianVaultPath \"\(explicitPath)\" doesn't exist.")
        }
        if c.obsidianLogging, ObsidianVault.resolve(configuredPath: c.obsidianVaultPath) == nil {
            out.append("Obsidian logging is on, but no vault was found.")
        }
        return out
    }
}
