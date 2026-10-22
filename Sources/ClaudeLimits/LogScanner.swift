import Foundation

/// Per-session usage reconstructed from Claude Code transcripts (~/.claude/projects/**/*.jsonl).
/// Cost is an API-price equivalent in USD — used only to weigh sessions and hours against each other.
struct SessionUsage: Identifiable {
    var id: String
    var title: String
    var cwd: String?
    var lastActive: Date
    var hourly: [Int: Double]          // epoch hour -> cost
    func cost(since start: Date) -> Double {
        let h0 = Int(start.timeIntervalSince1970 / 3600)
        return hourly.reduce(0) { $1.key >= h0 ? $0 + $1.value : $0 }
    }
}

/// Keeps per-file results between scans. Unchecked Sendable: call `scan` from one serial queue only.
final class LogScanner: @unchecked Sendable {
    private struct FileResult {
        var mtime: Date
        var size: Int
        var messages: [String: (session: String, hour: Int, cost: Double, ts: Date)] = [:]
        var cwd: [String: (path: String, ts: Date)] = [:]
        var customTitle: [String: String] = [:]
        var aiTitle: [String: String] = [:]
        var lastPrompt: [String: String] = [:]
    }

    private var cache: [String: FileResult] = [:]
    private let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private let lookback: TimeInterval = 8 * 86400

    /// Latest modification time of any transcript. Changes whenever a session starts or writes an event.
    /// Cheap: reads file metadata only. Call from a background queue.
    static func lastActivity() -> Date? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        var latest: Date?
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
                if latest.map({ m > $0 }) ?? true { latest = m }
            }
        }
        return latest
    }

    /// Rescans changed files only. Call from a background queue.
    func scan() -> [SessionUsage] {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-lookback)
        var seen = Set<String>()
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mtime = v.contentModificationDate, mtime >= cutoff else { continue }
                let size = v.fileSize ?? 0
                seen.insert(url.path)
                if let c = cache[url.path], c.mtime == mtime, c.size == size { continue }
                cache[url.path] = parse(url, mtime: mtime, size: size)
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        return merge()
    }

    private func merge() -> [SessionUsage] {
        var byId: [String: SessionUsage] = [:]
        var custom: [String: String] = [:], ai: [String: String] = [:], prompt: [String: String] = [:]
        var cwd: [String: (path: String, ts: Date)] = [:]
        var dedup = Set<String>()
        for f in cache.values {
            custom.merge(f.customTitle) { a, _ in a }
            ai.merge(f.aiTitle) { a, _ in a }
            prompt.merge(f.lastPrompt) { a, _ in a }
            cwd.merge(f.cwd) { a, b in a.ts >= b.ts ? a : b }   // latest working dir wins
            for (mid, m) in f.messages where dedup.insert(mid).inserted {
                var s = byId[m.session] ?? SessionUsage(id: m.session, title: "", cwd: nil, lastActive: m.ts, hourly: [:])
                s.hourly[m.hour, default: 0] += m.cost
                s.lastActive = max(s.lastActive, m.ts)
                byId[m.session] = s
            }
        }
        return byId.values.map { s in
            var s = s
            s.cwd = cwd[s.id]?.path
            let fallback = s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(s.id.prefix(8))
            s.title = custom[s.id] ?? ai[s.id] ?? prompt[s.id].map { String($0.prefix(80)) } ?? fallback
            return s
        }
    }

    private static let markers: [(String, Data)] = [
        "\"type\":\"assistant\"", "\"type\":\"custom-title\"", "\"type\":\"ai-title\"", "\"type\":\"last-prompt\""
    ].map { ($0, Data($0.utf8)) }

    private func parse(_ url: URL, mtime: Date, size: Int) -> FileResult {
        var r = FileResult(mtime: mtime, size: size)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return r }
        let fileSession = url.deletingPathExtension().lastPathComponent
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            start = end + 1
            guard Self.markers.contains(where: { line.range(of: $0.1) != nil }),
                  let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            let session = obj["sessionId"] as? String ?? fileSession
            switch type {
            case "custom-title": if let t = obj["customTitle"] as? String, !t.isEmpty { r.customTitle[session] = t }
            case "ai-title": if let t = obj["aiTitle"] as? String, !t.isEmpty { r.aiTitle[session] = t }
            case "last-prompt": if let t = obj["lastPrompt"] as? String, !t.isEmpty { r.lastPrompt[session] = t }
            case "assistant":
                guard let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any],
                      let ts = (obj["timestamp"] as? String).flatMap(UsageAPI.parseDate) else { continue }
                let model = msg["model"] as? String ?? ""
                if model == "<synthetic>" { continue }
                if let c = obj["cwd"] as? String, ts >= (r.cwd[session]?.ts ?? .distantPast) { r.cwd[session] = (c, ts) }
                let key = (msg["id"] as? String) ?? (obj["uuid"] as? String) ?? UUID().uuidString
                // Streaming writes several lines per message; the last one carries the final usage.
                r.messages[key] = (session, Int(ts.timeIntervalSince1970 / 3600), Self.cost(usage, model: model), ts)
            default: break
            }
        }
        return r
    }

    /// USD per million tokens: input, output, cache write 5m, cache write 1h, cache read.
    private static func prices(_ model: String) -> (Double, Double, Double, Double, Double) {
        let m = model.lowercased()
        if m.contains("haiku") { return (1, 5, 1.25, 2, 0.1) }
        if m.contains("sonnet") { return (3, 15, 3.75, 6, 0.3) }
        return (5, 25, 6.25, 10, 0.5)   // opus and anything newer/unknown
    }

    private static func cost(_ u: [String: Any], model: String) -> Double {
        func n(_ k: String, _ d: [String: Any] = u) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
        let p = prices(model)
        var w5 = n("cache_creation_input_tokens"), w1h = 0.0
        if let cc = u["cache_creation"] as? [String: Any] {
            w5 = n("ephemeral_5m_input_tokens", cc)
            w1h = n("ephemeral_1h_input_tokens", cc)
        }
        return (n("input_tokens") * p.0 + n("output_tokens") * p.1 + w5 * p.2 + w1h * p.3
                + n("cache_read_input_tokens") * p.4) / 1_000_000
    }
}
