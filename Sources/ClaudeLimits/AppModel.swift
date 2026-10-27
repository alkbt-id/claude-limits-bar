import Foundation
import Combine
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshot: UsageSnapshot?
    @Published var error: String?
    @Published var sessions: [SessionUsage] = []
    @Published var now = Date()
    @Published var loading = false
    @Published var copiedSession: String?
    /// Panel height: the full design height, or less on a screen too short for it.
    @Published var panelHeight = PopoverView.height
    /// Running Claude Code sessions, rescanned every few seconds.
    @Published var live: [LiveSession] = []
    /// When each session was last looked at (clicked or "all read"); a state entered later wants attention.
    @Published private var readAt: [String: Date] = [:]
    /// Accessibility access: without it a VS Code window in front can't be matched to its sessions.
    @Published private(set) var axTrusted = FocusProbe.trusted
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
    private let liveScanner = LiveSessionScanner()
    private let liveQueue = DispatchQueue(label: "claude-limits.live", qos: .utility)
    private var liveScanning = false
    private let scanQueue = DispatchQueue(label: "claude-limits.scan", qos: .utility)
    private var timers: [Timer] = []

    /// After HTTP 429 no requests go out until this moment.
    private var backoffUntil: Date?
    /// Tokens the API rejected with 401/403: no polls until Claude Code puts a new one in the keychain.
    private var rejectedToken: String?

    init(store: SampleStore = SampleStore()) {
        self.store = store
        snapshot = Self.lastKnown(in: store)
        if store.isPersistent {
            let d = UserDefaults.standard
            // States entered before the feature first ran don't light up: the user has seen them already.
            if d.object(forKey: "sessionsBaseline") == nil { d.set(Date().timeIntervalSince1970, forKey: "sessionsBaseline") }
            baseline = Date(timeIntervalSince1970: d.double(forKey: "sessionsBaseline"))
            readAt = (d.dictionary(forKey: "sessionReadAt") as? [String: Double] ?? [:]).mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    private var baseline = Date.distantPast

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
    static let liveInterval: TimeInterval = 3
    static let scanInterval: TimeInterval = 300

    func start() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        Log.write("start v\(v), plan \(plan?.rawValue ?? "unknown"), last data \(snapshot.map { Fmt.time.string(from: $0.fetchedAt) } ?? "none")")
        Task { await refresh(force: true) }
        rescanLogs()
        rescanLive()
        timers = [
            Timer.scheduledTimer(withTimeInterval: Self.liveInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.rescanLive() }
            },
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
            let current = await Task.detached { UsageAPI.tokens(UsageAPI.allCredentials()) }.value
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

    @Published var diagnosing = false
    @Published var diagnosticsCopied = false

    /// Builds the diagnostics report, copies it and saves it next to the log.
    func runDiagnostics() async {
        diagnosing = true
        defer { diagnosing = false }
        let text = await Diagnostics.report()
        try? text.write(to: Diagnostics.url, atomically: true, encoding: .utf8)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Log.write("diagnostics saved to \(Diagnostics.url.path)")
        diagnosticsCopied = true
        try? await Task.sleep(for: .seconds(4))
        diagnosticsCopied = false
    }

    func rescanLogs() {
        scanQueue.async { [scanner] in
            let result = scanner.scan()
            Log.write("log scan: \(result.count) sessions")
            Task { @MainActor in self.sessions = result }
        }
    }

    // MARK: Live sessions

    func rescanLive() {
        guard !liveScanning else { return }
        liveScanning = true
        let titles = Dictionary(sessions.map { ($0.id, $0.title) }) { a, _ in a }
        liveQueue.async { [liveScanner] in
            let result = liveScanner.scan(titles: titles)
            Task { @MainActor in
                self.liveScanning = false
                self.readFocused(result)
                if result != self.live {
                    for s in result {
                        let was = self.live.first { $0.id == s.id }
                        if was?.state != s.state {
                            Log.write("session \(s.id.prefix(8)) [\(s.entrypoint ?? "?")] \(was.map { "\($0.state)" } ?? "new") → \(s.state)\(self.needsAttention(s) ? ", wants attention" : "")")
                        }
                    }
                    for s in self.live where !result.contains(where: { $0.id == s.id }) {
                        Log.write("session \(s.id.prefix(8)) ended")
                    }
                    self.live = result
                }
            }
        }
    }

    /// A waiting session whose window is in front while the user is at the Mac counts as read, like a click.
    private func readFocused(_ sessions: [LiveSession]) {
        if FocusProbe.trusted != axTrusted { axTrusted.toggle() }
        let waiting = sessions.filter(needsAttention)
        guard !waiting.isEmpty, FocusProbe.userIdle < 60 else { return }
        let seen = FocusProbe.focused(waiting)
        guard !seen.isEmpty else { return }
        Log.write("seen in the front window: \(seen.map { $0.prefix(8) }.sorted().joined(separator: ", "))")
        markRead(Array(seen))
    }

    /// A session wants attention when it waits for the user and has not been looked at since.
    func needsAttention(_ s: LiveSession) -> Bool {
        s.state.wantsUser && s.since > max(readAt[s.id] ?? .distantPast, baseline)
    }

    /// Attention first (newest first), then working, then the rest.
    var liveSorted: [LiveSession] {
        func rank(_ s: LiveSession) -> Int {
            if needsAttention(s) { return 0 }
            switch s.state {
            case .working, .background: return 1
            case .permission, .question: return 2
            case .idle, .stopped: return 3
            }
        }
        return live.sorted { (rank($0), $1.since) < (rank($1), $0.since) }
    }

    var attentionCount: Int { live.filter(needsAttention).count }
    var workingCount: Int { live.filter(\.isWorking).count }

    func markRead(_ ids: [String]) {
        let now = Date()
        for id in ids { readAt[id] = now }
        // Keep only sessions still alive, plus a day of the rest in case they come back.
        readAt = readAt.filter { k, v in live.contains { $0.id == k } || now.timeIntervalSince(v) < 86400 }
        if store.isPersistent {
            UserDefaults.standard.set(readAt.mapValues { $0.timeIntervalSince1970 }, forKey: "sessionReadAt")
        }
    }

    func markAllRead() { markRead(live.map(\.id)) }

    func openSession(_ s: LiveSession) {
        markRead([s.id])
        Navigator.open(s)
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

    /// Weekly-limit percent per API-equivalent dollar of Claude Code spend in the current weekly window.
    /// An estimate: the weekly percent minus the claude.ai share, spread over local spend.
    var percentPerDollar: Double? {
        guard let weekly = snapshot?.sevenDay?.utilization, weekly > 0 else { return nil }
        let start = weekStart
        let cost = sessions.reduce(0) { $0 + $1.cost(since: start) }
        guard cost > 0.01 else { return nil }
        return weekly * (snapshot?.claudeCodeShare ?? 1) / cost
    }

    /// Sessions ranked by API-equivalent cost inside the current weekly window.
    func topSessions(limit: Int = 10) -> [TopSession] {
        let start = weekStart
        let ranked = sessions.map { ($0, $0.cost(since: start)) }.filter { $0.1 > 0.0001 }.sorted { $0.1 > $1.1 }
        let rate = percentPerDollar
        return ranked.prefix(limit).map { s, c in
            TopSession(session: s, cost: c, weeklyPercent: rate.map { c * $0 })
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
