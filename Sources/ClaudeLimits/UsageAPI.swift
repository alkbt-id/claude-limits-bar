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

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Не найден токен Claude Code в связке ключей. Войдите в Claude Code (claude → /login)."
        case .unauthorized: return "Токен истёк. Запустите Claude Code — он обновит токен, и данные вернутся."
        case .rateLimited: return "API временно ограничил частоту запросов (HTTP 429)."
        case .http(let code): return "Ошибка API: HTTP \(code)"
        case .badResponse: return "Не удалось разобрать ответ API"
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
        var found = serviceNames().compactMap { name in readKeychain(name).flatMap { parse($0, service: name) } }
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

    /// Names of the Claude Code keychain items. Reads attributes only, so no access prompt.
    private static func serviceNames() -> [String] {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [servicePrefix] }
        let names = Set(items.compactMap { $0[kSecAttrService as String] as? String }.filter { $0.hasPrefix(servicePrefix) })
        return names.isEmpty ? [servicePrefix] : names.sorted()
    }

    /// Uses /usr/bin/security so the keychain item ACL stays the same as for the CLI.
    private static func readKeychain(_ service: String) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", service, "-w"]
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

    /// Tries each login in turn until the endpoint accepts one; 401/403 moves on to the next.
    static func fetch() async throws -> UsageSnapshot {
        let all = allCredentials()
        guard !all.isEmpty else {
            Log.write("no credentials in keychain or ~/.claude/.credentials.json")
            throw UsageError.noCredentials
        }
        for creds in all {
            do {
                let snap = try await fetch(with: creds)
                if creds.service != lastService {
                    Log.write("using \(creds.summary)")
                    lastService = creds.service
                }
                return snap
            } catch UsageError.unauthorized {
                Log.write("rejected: \(creds.summary)")
            }
        }
        throw UsageError.unauthorized(token: tokens(all))
    }

    /// All tokens in one string: when none is accepted, the next poll waits until any of them changes.
    static func tokens(_ all: [Credentials]) -> String { all.map(\.token).joined(separator: ",") }

    /// Status and body of the last non-200 answer, for the diagnostics report.
    nonisolated(unsafe) static var lastFailure: String?

    /// Item the last successful poll used, so the log names it once instead of on every poll.
    nonisolated(unsafe) private static var lastService: String?

    static func fetch(with creds: Credentials) async throws -> UsageSnapshot {
        let token = creds.token
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode != 200 {
            let body = String(decoding: data.prefix(300), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
            lastFailure = "HTTP \(http.statusCode): \(body)"
            Log.write("HTTP \(http.statusCode), Retry-After \(http.value(forHTTPHeaderField: "Retry-After") ?? "none"), body: \(body)")
        }
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
