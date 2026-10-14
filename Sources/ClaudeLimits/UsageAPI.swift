import Foundation

/// One rate-limit window as reported by the usage endpoint.
struct LimitWindow: Codable, Equatable {
    var utilization: Double      // 0...100
    var resetsAt: Date?
}

struct UsageSnapshot: Codable, Equatable {
    var fetchedAt: Date
    var fiveHour: LimitWindow?
    var sevenDay: LimitWindow?
    /// Share of the weekly usage that came from Claude Code (0...1), if the API reports it.
    var claudeCodeShare: Double?
}

enum UsageError: LocalizedError {
    case noCredentials
    case unauthorized
    case http(Int)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noCredentials: return "Не найден токен Claude Code в связке ключей. Войдите в Claude Code (claude → /login)."
        case .unauthorized: return "Токен истёк. Запустите Claude Code — он обновит токен, и данные вернутся."
        case .http(let code): return "Ошибка API: HTTP \(code)"
        case .badResponse: return "Не удалось разобрать ответ API"
        }
    }
}

enum UsageAPI {
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Reads the OAuth access token that Claude Code keeps in the login keychain.
    /// Uses /usr/bin/security so the keychain item ACL stays the same as for the CLI.
    static func readAccessToken() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus == 0, let token = parseToken(data) { return token }

        // Fallback: credentials file used on some setups.
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let d = try? Data(contentsOf: file) { return parseToken(d) }
        return nil
    }

    private static func parseToken(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    static func fetch() async throws -> UsageSnapshot {
        guard let token = readAccessToken() else { throw UsageError.noCredentials }
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw UsageError.badResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw UsageError.unauthorized }
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
                             claudeCodeShare: share)
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
