import Foundation

/// Loads config.json, creates it with defaults if missing, and hot-reloads on
/// edit by watching the containing directory. `onChange` fires on the main
/// queue whenever a valid config is (re)loaded.
final class ConfigStore {
    private(set) var config = Config()
    var onChange: ((Config) -> Void)?

    private let dirURL: URL
    private let fileURL: URL
    private var source: DispatchSourceFileSystemObject?
    private var dirFD: CInt = -1

    init() {
        dirURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/whisperkey", isDirectory: true)
        fileURL = dirURL.appendingPathComponent("config.json")
    }

    func start() {
        ensureFileExists()
        reload()
        watch()
        NSLog("WhisperKey: config at %@", fileURL.path)
    }

    private func ensureFileExists() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: dirURL.path) {
            try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        }
        guard !fm.fileExists(atPath: fileURL.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Config()) {
            try? data.write(to: fileURL)
        }
    }

    private func reload() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let cfg = try? JSONDecoder().decode(Config.self, from: data) else {
            NSLog("WhisperKey: config.json is invalid JSON — keeping previous settings.")
            return
        }
        let changed = cfg != config
        config = cfg
        if changed {
            DispatchQueue.main.async { self.onChange?(cfg) }
        }
    }

    private func watch() {
        dirFD = open(dirURL.path, O_EVTONLY)
        guard dirFD >= 0 else {
            NSLog("WhisperKey: could not watch config directory for changes.")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .delete],
            queue: .global()
        )
        src.setEventHandler { [weak self] in
            // Editors often save atomically (write temp + rename), so debounce.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.12) {
                self?.ensureFileExists()
                self?.reload()
            }
        }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
        }
        source = src
        src.resume()
    }
}
