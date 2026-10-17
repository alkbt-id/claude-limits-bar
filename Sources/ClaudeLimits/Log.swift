import Foundation

/// Plain-text app log at ~/Library/Logs/ClaudeLimits.log, readable with `tail -f`.
/// Rotates to ClaudeLimits.old.log at 1 MB. Never write tokens here.
enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeLimits.log")
    private static let maxSize = 1_000_000
    private static let queue = DispatchQueue(label: "claude-limits.log", qos: .utility)
    /// Off for `--snapshot` renders so they don't pollute the log.
    nonisolated(unsafe) static var enabled = true

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        guard enabled else { return }
        let line = "\(stamp.string(from: Date())) \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxSize {
                let old = url.deletingLastPathComponent().appendingPathComponent("ClaudeLimits.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            guard let h = try? FileHandle(forWritingTo: url) else { return }
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        }
    }
}
