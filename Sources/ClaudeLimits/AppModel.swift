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
    /// Plan chosen in the panel; nil follows the plan named in the Claude Code credentials.
    @Published var planChoice = UserDefaults.standard.string(forKey: "plan").flatMap(Plan.init(rawValue:)) {
        didSet { if store.isPersistent { UserDefaults.standard.set(planChoice?.rawValue, forKey: "plan") } }
    }
    @Published private(set) var detectedPlan = UserDefaults.standard.string(forKey: "detectedPlan").flatMap(Plan.init(rawValue:)) {
        didSet { if store.isPersistent { UserDefaults.standard.set(detectedPlan?.rawValue, forKey: "detectedPlan") } }
    }
    var plan: Plan? { planChoice ?? detectedPlan }

    let store: SampleStore
    private let scanner = LogScanner()
    private let scanQueue = DispatchQueue(label: "claude-limits.scan", qos: .utility)
    private var timers: [Timer] = []

    /// After HTTP 429 no requests go out until this moment.
    private var backoffUntil: Date?
    /// Token the API rejected with 401: no polls until Claude Code puts a new one in the keychain.
    private var rejectedToken: String?

    init(store: SampleStore = SampleStore()) {
        self.store = store
        snapshot = Self.lastKnown(in: store)
    }

    /// Last recorded poll, so a restart shows numbers right away instead of dashes.
    private static func lastKnown(in store: SampleStore) -> UsageSnapshot? {
        guard let s = store.samples.last, Date().timeIntervalSince(s.t) < 30 * 60 else { return nil }
        let now = Date()
        func window(_ v: Double?, _ reset: Date?) -> LimitWindow? {
            v.map { LimitWindow(utilization: $0, resetsAt: reset).current(at: now) }
        }
        return UsageSnapshot(fetchedAt: s.t, fiveHour: window(s.five, s.fiveReset), sevenDay: window(s.week, s.weekReset))
    }

    static let pollInterval: TimeInterval = 120
    static let scanInterval: TimeInterval = 300

    func start() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.write("start v\(v), plan \(plan?.rawValue ?? "unknown"), last data \(snapshot.map { Fmt.time.string(from: $0.fetchedAt) } ?? "none")")
        Task { await refresh(force: true) }
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

    /// Claude Code transcript activity as of the last successful poll; nil until one succeeds.
    private var activityAtFetch: Date?
    /// Without local activity the API is still polled this often: claude.ai and other machines spend the same limits.
    static let idlePollInterval: TimeInterval = 30 * 60

    /// `force` polls even when nothing changed locally (start, the refresh button).
    func refresh(force: Bool = false) async {
        now = Date()
        if let until = backoffUntil, now < until { return }
        var tokenChanged = false
        if let rejected = rejectedToken {
            let current = await Task.detached { UsageAPI.readCredentials()?.token }.value
            if current == rejected, !force { return }
            tokenChanged = current != rejected
        }
        let activity = await withCheckedContinuation { c in
            scanQueue.async { c.resume(returning: LogScanner.lastActivity()) }
        }
        let reason = force ? "forced" : tokenChanged ? "new token" : fetchReason(activity: activity)
        guard let reason else { return }
        Log.write("fetch (\(reason))")
        loading = true
        defer { loading = false }
        do {
            var snap = try await UsageAPI.fetch()
            if let p = snap.plan, p != detectedPlan { detectedPlan = p }
            snap.plan = plan
            snapshot = snap
            error = nil
            backoffUntil = nil
            rejectedToken = nil
            activityAtFetch = activity ?? .distantPast
            store.append(snap)
            Log.write("ok: 5h \(Fmt.percent(snap.fiveHour?.utilization)) reset \(Self.stamp(snap.fiveHour?.resetsAt)), week \(Fmt.percent(snap.sevenDay?.utilization)) reset \(Self.stamp(snap.sevenDay?.resetsAt)), cc share \(snap.claudeCodeShare.map { String(format: "%.2f", $0) } ?? "-")")
        } catch UsageError.rateLimited(let retryAfter) {
            let until = Date().addingTimeInterval(max(retryAfter ?? 0, Self.pollInterval * 2))
            backoffUntil = until
            Log.write("429: Retry-After \(retryAfter.map { "\(Int($0))s" } ?? "none"), backoff until \(Fmt.time.string(from: until))")
            // Recent numbers are still good enough: wait quietly instead of alarming.
            if let t = snapshot?.fetchedAt, Date().timeIntervalSince(t) < 15 * 60 {
                error = nil
            } else {
                error = "API временно ограничил частоту запросов (HTTP 429)\(snapshot.map { ", данные от \(Fmt.time.string(from: $0.fetchedAt))" } ?? ""). Повтор в \(Fmt.time.string(from: until))."
            }
        } catch UsageError.unauthorized(let token) {
            rejectedToken = token
            Log.write("unauthorized: token expired or rejected, waiting for a new one in the keychain")
            // The token lives ~8 h; Claude Code refreshes it the next time it runs.
            // Keep showing recent numbers and only complain once they get old.
            if let t = snapshot?.fetchedAt, Date().timeIntervalSince(t) < 15 * 60 {
                error = nil
            } else {
                error = "Токен Claude Code истёк\(snapshot.map { ", данные от \(Fmt.time.string(from: $0.fetchedAt))" } ?? ""). Он обновится, когда Claude Code снова запустится."
            }
        } catch {
            Log.write("error: \(error)")
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        now = Date()
    }

    /// Why a poll is due, or nil when no Claude Code session started or wrote an event since the last
    /// successful poll, no limit window has reset since then, and that poll is not too old.
    private func fetchReason(activity: Date?) -> String? {
        guard let snap = snapshot else { return "no data" }
        guard let seen = activityAtFetch else { return "first poll" }
        if (activity ?? .distantPast) != seen { return "new activity" }
        if now.timeIntervalSince(snap.fetchedAt) >= Self.idlePollInterval { return "idle timeout" }
        let resets = [snap.fiveHour?.resetsAt, snap.sevenDay?.resetsAt].compactMap { $0 }
        return resets.contains { $0 > snap.fetchedAt && $0 <= now } ? "window reset" : nil
    }

    private static func stamp(_ d: Date?) -> String { d.map { Fmt.dayTime.string(from: $0) } ?? "-" }

    func rescanLogs() {
        scanQueue.async { [scanner] in
            let result = scanner.scan()
            Log.write("log scan: \(result.count) sessions")
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

    /// Recorded limit windows replayed on every plan; nil until the plan is known and a window has usage.
    var planReport: PlanReport? {
        guard let plan else { return nil }
        return PlanReport(history: store.windows, current: plan, now: now)
    }

    /// Claude Code cost per epoch hour across all sessions.
    func logHourly(since start: Date) -> [Int: Double] {
        let h0 = Int(start.timeIntervalSince1970 / 3600)
        var out: [Int: Double] = [:]
        for s in sessions { for (h, c) in s.hourly where h >= h0 { out[h, default: 0] += c } }
        return out
    }
}
