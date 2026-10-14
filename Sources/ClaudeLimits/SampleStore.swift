import Foundation

/// A single poll result kept on disk to draw history.
struct Sample: Codable {
    var t: Date
    var five: Double?
    var fiveReset: Date?
    var week: Double?
    var weekReset: Date?
}

/// Append-only history of polls, stored as JSON in Application Support.
final class SampleStore {
    private(set) var samples: [Sample] = []
    private let url: URL?
    private let keep: TimeInterval = 30 * 86400

    /// In-memory store (demo screenshots); nothing is written to disk.
    init(samples: [Sample]) {
        self.samples = samples
        url = nil
    }

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClaudeLimits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("samples.json")
        self.url = url
        if let d = try? Data(contentsOf: url), let s = try? Self.decoder.decode([Sample].self, from: d) {
            samples = s
        }
    }

    func append(_ snap: UsageSnapshot) {
        samples.append(Sample(t: snap.fetchedAt,
                              five: snap.fiveHour?.utilization, fiveReset: snap.fiveHour?.resetsAt,
                              week: snap.sevenDay?.utilization, weekReset: snap.sevenDay?.resetsAt))
        let cutoff = Date().addingTimeInterval(-keep)
        samples.removeAll { $0.t < cutoff }
        if let url, let d = try? Self.encoder.encode(samples) { try? d.write(to: url, options: .atomic) }
    }

    func since(_ date: Date) -> [Sample] { samples.filter { $0.t >= date } }

    /// Limit consumption per hour: sum of positive utilization steps between consecutive polls.
    /// A new reset time means a new window, so the new value counts in full.
    func hourlyConsumption(since start: Date, weekly: Bool) -> [Int: Double] {
        var out: [Int: Double] = [:]
        let s = samples
        guard s.count > 1 else { return out }
        for i in 1..<s.count where s[i].t >= start {
            let a = s[i - 1], b = s[i]
            guard let vb = weekly ? b.week : b.five else { continue }
            let va = weekly ? a.week : a.five
            let sameWindow = Self.sameReset(weekly ? a.weekReset : a.fiveReset, weekly ? b.weekReset : b.fiveReset)
            // Polls more than 6h apart (sleep, app off) can't be attributed to an hour reliably.
            guard b.t.timeIntervalSince(a.t) < 6 * 3600 else { continue }
            let delta = sameWindow ? vb - (va ?? vb) : vb
            if delta > 0 { out[Int(b.t.timeIntervalSince1970 / 3600), default: 0] += delta }
        }
        return out
    }

    private static func sameReset(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return true }
        return abs(a.timeIntervalSince(b)) < 120
    }

    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
