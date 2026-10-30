import Foundation
import Security

/// One rate-limit window as reported by the usage endpoint.
struct LimitWindow: Codable, Equatable {
    var utilization: Double      // 0...100
    var resetsAt: Date?

    /// The window as of `now`: once its reset time has passed, usage starts over.
    func current(at now: Date) -> LimitWindow {
        if let r = resetsAt, r <= now { return LimitWindow(utilization: 0, resetsAt: nil) }
        return self
    }

    static let fiveHourLength: TimeInterval = 5 * 3600
    static let sevenDayLength: TimeInterval = 7 * 86400

    /// How tight the limit is, 0 (relaxed) ... 1 (over): whether usage fits what the even pace
    /// allows through the end of the current step (an hour of the 5-hour window, a day of the week).
    /// Green up to half a step below that allowance, yellow nearing it, red once it is reached.
    func strain(at now: Date, length: TimeInterval, skipWeekends: Bool = false) -> Double {
        let used = utilization / 100
        guard used < 1 else { return 1 }
        guard let a = allowance(at: now, length: length, skipWeekends: skipWeekends) else { return used }
        return min(max((used - a.green) / (a.share - a.green), 0), 1)
    }

    /// What the even pace of 100% over `length` allows, counted in whole steps from the window start,
    /// so a fresh window already has its first hour or day: `share` (0...1) through the end of the
    /// current step at `until`, and `green`, half a step below it.
    /// With `skipWeekends` only weekday time counts, both in the window and in what has passed of it.
    func allowance(at now: Date, length: TimeInterval, skipWeekends: Bool = false) -> (green: Double, share: Double, until: Date)? {
        guard let r = resetsAt else { return nil }
        let step: TimeInterval = length > Self.fiveHourLength ? 86400 : 3600
        let start = r.addingTimeInterval(-length), from = min(max(now, start), r)
        let span = skipWeekends ? Self.weekdayTime(from: start, to: r) : length
        guard span > 0 else { return nil }
        let passed = skipWeekends ? Self.weekdayTime(from: start, to: from) : from.timeIntervalSince(start)
        let allowed = min(((passed / step).rounded(.down) + 1) * step, span)
        let until = skipWeekends ? Self.adding(weekdayTime: allowed - passed, to: from) : start.addingTimeInterval(allowed)
        return ((allowed - step / 2) / span, allowed / span, min(until, r))
    }

    /// The moment `weekdayTime` seconds of weekdays after `d`.
    static func adding(weekdayTime s: TimeInterval, to d: Date, calendar cal: Calendar = .current) -> Date {
        var left = s
        var t = d
        while left > 0 {
            guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t)) else { break }
            if !cal.isDateInWeekend(t) {
                if next.timeIntervalSince(t) >= left { return t.addingTimeInterval(left) }
                left -= next.timeIntervalSince(t)
            }
            t = next
        }
        return t
    }

    /// Seconds between two moments that fall outside the weekend.
    static func weekdayTime(from a: Date, to b: Date, calendar cal: Calendar = .current) -> TimeInterval {
        var total: TimeInterval = 0
        var t = a
        while t < b {
            guard let next = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: t)) else { break }
            let end = min(next, b)
            if !cal.isDateInWeekend(t) { total += end.timeIntervalSince(t) }
            t = end
        }
        return total
    }
}

struct UsageSnapshot: Codable, Equatable {
    var fetchedAt: Date
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    /// Share of the weekly usage that came from Claude Code (0...1), if the API reports it.
    var claudeCodeShare: Double?
    /// Plan from the Claude Code credentials, if they name it.
    var plan: Plan?
}

enum UsageError: LocalizedError {
    case noCredentials
    case unauthorized(token: String)
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case badResponse
    /// HTTP 403 "Request not allowed": the API refuses the network, not the token (unsupported region).
    case blocked

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Не найден токен Claude Code в связке ключей. Войдите в Claude Code (claude → /login)."
        case .unauthorized: return "Токен истёк. Запустите Claude Code — он обновит токен, и данные вернутся."
        case .rateLimited: return "API временно ограничил частоту запросов (HTTP 429)."
        case .http(let code): return "Ошибка API: HTTP \(code)"
        case .badResponse: return "Не удалось разобрать ответ API"
        case .blocked: return "Anthropic не принимает запросы из этой сети (HTTP 403 «Request not allowed»), а прокси, через который ходит Claude Code, не найден. Кнопка со стетоскопом внизу покажет, какие пути проверены."
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Keychain items Claude Code keeps its login in: "Claude Code-credentials", plus one with a
    /// hash suffix per config directory. Claude Desktop may write the plain one with a token the usage
    /// endpoint refuses (403), while the terminal CLI keeps a working token under a suffixed name.
    private static let servicePrefix = "Claude Code-credentials"

    /// Every Claude Code login on this Mac, best first: not expired, then the one expiring last.
    static func allCredentials() -> [Credentials] {
        var found = keychainItems().compactMap { item in
            readKeychain(item.service, account: item.account).flatMap {
                parse($0, service: item.account.map { "\(item.service) (\($0))" } ?? item.service)
            }
        }
        // Fallback: credentials file used on some setups.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let d = try? Data(contentsOf: file), let c = parse(d, service: "~/.claude/.credentials.json") { found.append(c) }
        let now = Date()
        return found.sorted { a, b in
            let (ea, eb) = (a.expiresAt ?? .distantFuture, b.expiresAt ?? .distantFuture)
            if (ea > now) != (eb > now) { return ea > now }
            return ea > eb
        }
    }

    /// The Claude Code keychain items, by service and account. Reads attributes only, so no access prompt.
    /// One service name may hold several items: Claude Code can add a second "Claude Code-credentials"
    /// under account "unknown" with only MCP logins in it, and a lookup by service alone may return that one.
    private static func keychainItems() -> [(service: String, account: String?)] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [(servicePrefix, nil)] }
        var seen = Set<String>()
        let found = items.compactMap { item -> (service: String, account: String?)? in
            guard let service = item[kSecAttrService as String] as? String, service.hasPrefix(servicePrefix) else { return nil }
            let account = item[kSecAttrAccount as String] as? String
            return seen.insert("\(service)\n\(account ?? "")").inserted ? (service, account) : nil
        }
        return found.isEmpty ? [(servicePrefix, nil)] : found.sorted { ($0.service, $0.account ?? "") < ($1.service, $1.account ?? "") }
    }

    /// Uses /usr/bin/security so the keychain item ACL stays the same as for the CLI.
    private static func readKeychain(_ service: String, account: String?) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service] + (account.map { ["-a", $0] } ?? []) + ["-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    struct Credentials {
        var service: String
        var token: String
        var plan: Plan?
        var expiresAt: Date?
        var scopes: [String]

        /// For the log: where the token came from and what it allows, never the token itself.
        var summary: String {
            "\(service) [\(plan?.rawValue ?? "?"), expires \(expiresAt.map { Fmt.dayTime.string(from: $0) } ?? "?"), scopes \(scopes.joined(separator: " "))]"
        }
    }

    private static func parse(_ data: Data, service: String) -> Credentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return Credentials(service: service, token: token,
                           plan: Plan(tier: oauth["rateLimitTier"] as? String,
                                      subscription: oauth["subscriptionType"] as? String),
                           expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                           scopes: oauth["scopes"] as? [String] ?? [])
    }

    /// Tries each route (see `Route.candidates()`) and on it each login, until the endpoint answers.
    /// A network error or a 403 for the network moves on to the next route; 401/403 for a token, to the next login.
    static func fetch() async throws -> UsageSnapshot {
        let all = allCredentials()
        guard !all.isEmpty else {
            Log.write("no credentials in keychain or ~/.claude/.credentials.json")
            throw UsageError.noCredentials
        }
        var routes = Route.candidates()
        if let last = lastRoute, let i = routes.firstIndex(of: last) { routes.insert(routes.remove(at: i), at: 0) }
        var failure: Error?
        for route in routes {
            var rejected = 0
            for creds in all {
                do {
                    let snap = try await fetch(with: creds, via: route)
                    if creds.service != lastService || route != lastRoute {
                        Log.write("using \(creds.summary) via \(route)")
                        lastService = creds.service
                        lastRoute = route
                    }
                    return snap
                } catch UsageError.unauthorized {
                    // The API was reached, so this outranks any network failure on other routes.
                    Log.write("rejected: \(creds.summary)")
                    failure = UsageError.unauthorized(token: tokens(all))
                    rejected += 1
                } catch UsageError.blocked {
                    Log.write("\(route) failed: blocked (HTTP 403 Request not allowed)")
                    if !(failure is UsageError) { failure = UsageError.blocked }
                    break
                } catch let e as URLError {
                    Log.write("\(route) failed: \(describe(e))")
                    if failure == nil { failure = e }
                    break
                }
            }
            // The API refused every login: another route would only resend the same tokens and earn a 429.
            if rejected == all.count { break }
        }
        throw failure ?? UsageError.badResponse
    }

    static func describe(_ e: Error) -> String {
        if let u = e as? URLError { return "\(u.code.rawValue) \(u.localizedDescription)" }
        return (e as? LocalizedError)?.errorDescription ?? "\(e)"
    }

    /// Route the last successful poll used; tried first next time.
    nonisolated(unsafe) private static var lastRoute: Route?

    /// All tokens in one string: when none is accepted, the next poll waits until any of them changes.
    static func tokens(_ all: [Credentials]) -> String { all.map(\.token).joined(separator: ",") }

    /// Status and body of the last non-200 answer, for the diagnostics report.
    nonisolated(unsafe) static var lastFailure: String?

    /// Item the last successful poll used, so the log names it once instead of on every poll.
    nonisolated(unsafe) private static var lastService: String?

    static func fetch(with creds: Credentials, via route: Route = .system) async throws -> UsageSnapshot {
        let token = creds.token
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await route.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode != 200 {
            let body = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            lastFailure = "HTTP \(http.statusCode): \(body)"
            Log.write("HTTP \(http.statusCode), Retry-After \(http.value(forHTTPHeaderField: "Retry-After") ?? "none"), body: \(body)")
        }
        if http.statusCode == 403, String(decoding: data, as: UTF8.self).contains("Request not allowed") { throw UsageError.blocked }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized(token: token) }
        if http.statusCode == 429 {
            throw UsageError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UsageError.badResponse }

        var share: Double?
        if let rows = (obj["seven_day_breakdown"] as? [String: Any])?["rows"] as? [[String: Any]],
           let cc = rows.first(where: { $0["key"] as? String == "claude_code" }),
           let pct = cc["percent"] as? Double {
            share = pct / 100
        }
        return UsageSnapshot(fetchedAt: Date(),
                             fiveHour: window(obj["five_hour"]),
                             sevenDay: window(obj["seven_day"]),
                             claudeCodeShare: share,
                             plan: creds.plan)
    }

    private static func window(_ any: Any?) -> LimitWindow? {
        guard let d = any as? [String: Any], let u = d["utilization"] as? Double else { return nil }
        return LimitWindow(utilization: u, resetsAt: (d["resets_at"] as? String).flatMap(parseDate))
    }

    static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s) ?? parseMicroseconds(s)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// The API returns microseconds ("…:59.939941+00:00"); trim to milliseconds if the formatter refuses.
    private static func parseMicroseconds(_ s: String) -> Date? {
        guard let dot = s.firstIndex(of: "."),
              let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) else { return nil }
        let frac = s[s.index(after: dot)..<tz].prefix(3)
        return isoFrac.date(from: String(s[..<dot]) + "." + frac + String(s[tz...]))
    }
}
