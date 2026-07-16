import AppKit
import Foundation

/// Finds the user's Obsidian vault without any configuration, by reading
/// Obsidian's own registry at ~/Library/Application Support/obsidian/obsidian.json
/// (a map of vault-id → { path, ts, open }). Prefers the vault currently open,
/// falling back to the most recently used one. `config.obsidianVaultPath`
/// overrides detection entirely.
enum ObsidianVault {
    static func resolve(configuredPath: String) -> URL? {
        let explicit = configuredPath.trimmingCharacters(in: .whitespaces)
        if !explicit.isEmpty {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return detect()
    }

    private static func detect() -> URL? {
        let registry = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: registry),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = json["vaults"] as? [String: [String: Any]], !vaults.isEmpty else {
            return nil
        }
        // Deterministic pick: the most recently used vault, preferring ones
        // Obsidian currently has open (several can be open at once).
        let entries = Array(vaults.values)
        let byRecency: ([String: Any], [String: Any]) -> Bool = {
            (($0["ts"] as? Double) ?? 0) < (($1["ts"] as? Double) ?? 0)
        }
        let open = entries.filter { ($0["open"] as? Bool) == true }
        let chosen = (open.isEmpty ? entries : open).max(by: byRecency)
        guard let path = chosen?["path"] as? String else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension ObsidianVault {
    /// Writes one finalized dictation as its own Markdown note inside the vault.
    /// The filename comes from `nameFormat` — a `DateFormatter` pattern with an
    /// optional `{title}` placeholder that the caller fills with an AI summary
    /// (e.g. "yyMMddHHmm - {title}"). `appName` is the app the text was delivered
    /// into, recorded for backlinking. Returns the note's URL.
    static func writeDictationNote(text: String, title: String, appName: String,
                                   vaultPath: String, folder: String,
                                   nameFormat: String) throws -> URL {
        guard let vault = resolve(configuredPath: vaultPath) else {
            throw NSError(domain: "WhisperKey", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "No Obsidian vault found. Set \"obsidianVaultPath\" in the config."
            ])
        }
        let dir = folder.isEmpty ? vault : vault.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let now = Date()
        let base = renderFilename(nameFormat, title: title, date: now)
        var url = dir.appendingPathComponent(base + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).md")
            n += 1
        }

        try Data(noteBody(text: text, title: title, appName: appName, date: now).utf8)
            .write(to: url)
        NSLog("WhisperKey: archived dictation to %@", url.path)
        return url
    }

    /// Compose the note's Markdown: YAML frontmatter (creation time, source,
    /// originating app, a `dictation` tag), an H1 of the AI title, the transcript,
    /// and a footer wikilink to the day's daily note so the archive is browsable
    /// via Obsidian's backlinks and graph.
    static func noteBody(text: String, title: String, appName: String, date: Date) -> String {
        let created = ISO8601DateFormatter().string(from: date)
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let dayStamp = day.string(from: date)
        let app = appName.trimmingCharacters(in: .whitespacesAndNewlines)

        var front = "---\ncreated: \(created)\nsource: WhisperKey\n"
        if !app.isEmpty {
            // Quote + escape so an app name with a colon can't break the YAML.
            front += "app: \"\(app.replacingOccurrences(of: "\"", with: "\\\""))\"\n"
        }
        front += "tags:\n  - dictation\n---\n"

        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = front + "\n"
        if !heading.isEmpty { body += "# \(heading)\n\n" }
        body += text + "\n\n"
        let origin = app.isEmpty ? "" : "Dictated in **\(app)** · "
        body += "\(origin)[[\(dayStamp)]]\n"
        return body
    }

    /// Render `template` into a filesystem-safe base filename (no extension).
    /// `{title}` is substituted *after* date formatting so the title's letters
    /// aren't misread as `DateFormatter` pattern characters.
    static func renderFilename(_ template: String, title: String, date: Date) -> String {
        let tpl = template.isEmpty ? "yyMMddHHmm - {title}" : template
        let safeTitle = sanitizeFilename(title)
        let df = DateFormatter()
        let segments = tpl.components(separatedBy: "{title}").map { seg -> String in
            guard !seg.isEmpty else { return "" }
            df.dateFormat = seg
            return df.string(from: date)
        }
        var name = segments.joined(separator: safeTitle)
        // Template without the placeholder: still append the title so notes
        // aren't all named identically.
        if !tpl.contains("{title}"), !safeTitle.isEmpty {
            name += " - \(safeTitle)"
        }
        name = sanitizeFilename(name)
        return name.isEmpty ? "Dictation" : name
    }

    /// Strip characters that are illegal or awkward in macOS filenames, collapse
    /// runs of whitespace, and cap the length.
    static func sanitizeFilename(_ s: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        var t = s.components(separatedBy: illegal).joined(separator: " ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        if t.count > 120 { t = String(t.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return t
    }
}

/// Appends live-transcription text to a fresh Markdown note inside the vault.
/// Obsidian watches its vault files, so the open note grows on screen as the
/// user speaks. Each committed segment is written + fsync'd immediately, so a
/// crash mid-session loses at most the current in-flight sentence.
final class LiveNoteWriter {
    let fileURL: URL
    var displayName: String { fileURL.deletingPathExtension().lastPathComponent }

    private let handle: FileHandle

    /// Creates `<vault>/<folder>/Live Transcript YYYY-MM-DD HH.mm.md` with a
    /// small header, ready for appending.
    init(vaultPath: String, folder: String) throws {
        guard let vault = ObsidianVault.resolve(configuredPath: vaultPath) else {
            throw NSError(domain: "WhisperKey", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "No Obsidian vault found. Set \"obsidianVaultPath\" in the config."
            ])
        }
        let dir = folder.isEmpty
            ? vault
            : vault.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm"
        var url = dir.appendingPathComponent("Live Transcript \(stamp.string(from: Date())).md")
        // Two sessions in the same minute: suffix rather than clobber.
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Live Transcript \(stamp.string(from: Date())) (\(n)).md")
            n += 1
        }
        fileURL = url

        let pretty = DateFormatter()
        pretty.dateStyle = .full
        pretty.timeStyle = .short
        let header = "# Live Transcript\n\n_\(pretty.string(from: Date())) — dictated with WhisperKey_\n\n"
        try Data(header.utf8).write(to: fileURL)
        handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        NSLog("WhisperKey: live note started at %@", fileURL.path)
    }

    /// Ask Obsidian to open the note so the user watches it fill in live.
    func openInObsidian() {
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: fileURL.path)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    func append(_ text: String) {
        guard !text.isEmpty else { return }
        handle.write(Data(text.utf8))
        try? handle.synchronize()
    }

    func close() {
        handle.write(Data("\n".utf8))
        try? handle.close()
    }
}
