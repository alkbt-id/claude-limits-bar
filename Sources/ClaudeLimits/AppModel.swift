import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var error: String?
    @Published var sessions: [SessionUsage] = []
    @Published var now = Date()
    @Published var loading = false
    @Published var copiedSession: String?
    @Published var launchAtLogin = LoginItem.isEnabled {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    let store: SampleStore
    private let scanner = LogScanner()
    private let scanQueue = DispatchQueue(label: "claude-limits.scan", qos: .utility)
    private var timers: [Timer] = []

    /// After HTTP 429 no requests go out until this moment.
    private var backoffUntil: Date?

    init(store: SampleStore = SampleStore()) {
        self.store = store
        snapshot = Self.lastKnown(in: store)
    }

    /// Last recorded poll, so a restart shows numbers right away instead of dashes.
    private static func lastKnown(in store: SampleStore) -> UsageSnapshot? {
        guard let s = store.samples.last, Date().timeIntervalSince(s.t) < 30 * 60 else { return nil }
        let now = Date()
        func window(_ v: Double?, _ reset: Date?) -> LimitWindow? {
            guard let v else { return nil }
            // The window has already reset since that poll: usage starts over.
            if let reset, reset < now { return LimitWindow(utilization: 0, resetsAt: nil) }
            return LimitWindow(utilization: v, resetsAt: reset)
        }
        return UsageSnapshot(fetchedAt: s.t, fiveHour: window(s.five, s.fiveReset), sevenDay: window(s.week, s.weekReset))
    }

    static let pollInterval: TimeInterval = 120
    static let scanInterval: TimeInterval = 300

    func start() {
        Task { await refresh() }
        rescanLogs()
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            },
            Timer.scheduledTimer(withTimeInterval: Self.scanInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rescanLogs() }
            },
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            },
        ]
    }

    func refresh() async {
        now = Date()
        if let until = backoffUntil, now < until { return }
        loading = true
        defer { loading = false }
        do {
            let snap = try await UsageAPI.fetch()
            snapshot = snap
            error = nil
            backoffUntil = nil
            store.append(snap)
        } catch UsageError.rateLimited(let retryAfter) {
            let until = Date().addingTimeInterval(max(retryAfter ?? 0, Self.pollInterval * 2))
            backoffUntil = until
            // Recent numbers are still good enough: wait quietly instead of alarming.
            if let t = snapshot?.fetchedAt, Date().timeIntervalSince(t) < 15 * 60 {
                error = nil
            } else {
                error = "API временно ограничил частоту запросов (HTTP 429). Повтор в \(Fmt.time.string(from: until))."
            }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        now = Date()
    }

    func rescanLogs() {
        scanQueue.async { [scanner] in
            let result = scanner.scan()
            Task { @MainActor in self.sessions = result }
        }
    }

    // MARK: Derived data

    /// Start of the current weekly window (reset time minus 7 days), or 7 days ago.
    var weekStart: Date {
        if let r = snapshot?.sevenDay?.resetsAt { return r.addingTimeInterval(-7 * 86400) }
        return now.addingTimeInterval(-7 * 86400)
    }

    struct TopSession: Identifiable {
        var session: SessionUsage
        var cost: Double
        var weeklyPercent: Double?    // estimated share of the weekly limit
        var id: String { session.id }
    }

    /// Sessions ranked by API-equivalent cost inside the current weekly window.
    func topSessions(limit: Int = 10) -> [TopSession] {
        let start = weekStart
        let ranked = sessions.map { ($0, $0.cost(since: start)) }.filter { $0.1 > 0.0001 }.sorted { $0.1 > $1.1 }
        let total = ranked.reduce(0) { $0 + $1.1 }
        let weekly = snapshot?.sevenDay?.utilization
        let ccShare = snapshot?.claudeCodeShare ?? 1
        return ranked.prefix(limit).map { s, c in
            TopSession(session: s, cost: c,
                       weeklyPercent: weekly.map { total > 0 ? c / total * $0 * ccShare : 0 })
        }
    }

    /// Claude Code cost per epoch hour across all sessions.
    func logHourly(since start: Date) -> [Int: Double] {
        let h0 = Int(start.timeIntervalSince1970 / 3600)
        var out: [Int: Double] = [:]
        for s in sessions { for (h, c) in s.hourly where h >= h0 { out[h, default: 0] += c } }
        return out
    }
}
