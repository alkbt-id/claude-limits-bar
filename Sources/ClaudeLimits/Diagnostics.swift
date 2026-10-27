import Foundation
import CFNetwork

/// A plain-text report on why limits may not load: each Claude Code login tried against the API,
/// the system proxy, and the recent log. Holds no tokens, so it can be pasted into a chat as is.
enum Diagnostics {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeLimits-diagnostics.txt")

    static func report() async -> String {
        var out: [String] = []
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        out.append("Claude Limits \(v), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(Fmt.dayTime.string(from: Date()))")

        out.append("\n== Логины Claude Code (лучший первым)")
        let all = UsageAPI.allCredentials()
        if all.isEmpty { out.append("не найдено ни одного") }
        for c in all { out.append("- \(c.summary)") }

        out.append("\n== Запущенные сессии Claude Code")
        let found = Route.scanClaudeCode().sessions
        out.append(contentsOf: found.isEmpty ? ["нет"] : found)

        out.append("\n== Пути к API (по порядку, с первым логином)")
        if let best = all.first {
            for r in Route.candidates() { out.append("- \(r): \(await probe(best, via: r))") }
        }

        out.append("\n== Системный прокси")
        out.append(contentsOf: proxy())

        out.append("\n== Журнал (последние запросы)")
        let log = (try? String(contentsOf: Log.url, encoding: .utf8)) ?? ""
        let skip = ["log scan:", " session ", "seen in the front window"]
        let lines = log.split(separator: "\n").filter { l in !skip.contains { l.contains($0) } }
        out.append(contentsOf: lines.suffix(40).map(String.init))
        return out.joined(separator: "\n")
    }

    private static func probe(_ c: UsageAPI.Credentials, via route: Route) async -> String {
        do {
            let s = try await UsageAPI.fetch(with: c, via: route)
            return "OK — 5 ч \(Fmt.percent(s.fiveHour?.utilization)), неделя \(Fmt.percent(s.sevenDay?.utilization))"
        } catch UsageError.unauthorized {
            return "отказ — \(UsageAPI.lastFailure ?? "401/403")"
        } catch UsageError.blocked {
            return "Anthropic не пускает из этой сети (HTTP 403 Request not allowed)"
        } catch {
            return UsageAPI.describe(error)
        }
    }

    /// System proxy settings and the proxy URLSession picks for the usage endpoint.
    private static func proxy() -> [String] {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() else { return ["настройки не прочитались"] }
        let d = settings as? [String: Any] ?? [:]
        var out: [String] = []
        func on(_ key: CFString) -> Bool { (d[key as String] as? Int) == 1 }
        if on(kCFNetworkProxiesHTTPSEnable) {
            out.append("HTTPS: \(d[kCFNetworkProxiesHTTPSProxy as String] ?? "?"):\(d[kCFNetworkProxiesHTTPSPort as String] ?? "?")")
        }
        if on(kCFNetworkProxiesHTTPEnable) {
            out.append("HTTP: \(d[kCFNetworkProxiesHTTPProxy as String] ?? "?"):\(d[kCFNetworkProxiesHTTPPort as String] ?? "?")")
        }
        if on(kCFNetworkProxiesProxyAutoConfigEnable) {
            out.append("PAC: \(d[kCFNetworkProxiesProxyAutoConfigURLString as String] ?? "?")")
        }
        if let ex = d[kCFNetworkProxiesExceptionsList as String] as? [String], !ex.isEmpty {
            out.append("исключения: \(ex.joined(separator: ", "))")
        }
        if out.isEmpty { out.append("не настроен") }
        let target = URL(string: "https://api.anthropic.com/api/oauth/usage")! as CFURL
        let picked = (CFNetworkCopyProxiesForURL(target, settings).takeRetainedValue() as? [[String: Any]] ?? []).map { p in
            let type = (p[kCFProxyTypeKey as String] as? String).map { $0.replacingOccurrences(of: "kCFProxyType", with: "") } ?? "?"
            guard let host = p[kCFProxyHostNameKey as String] else { return type == "None" ? "напрямую" : type }
            return "\(type) \(host):\(p[kCFProxyPortNumberKey as String] ?? "?")"
        }
        out.append("для api.anthropic.com: \(picked.isEmpty ? "?" : picked.joined(separator: ", "))")
        return out
    }
}
