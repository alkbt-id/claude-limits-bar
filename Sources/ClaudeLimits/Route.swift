import Foundation
import CFNetwork

/// A way to reach the API. Claude Desktop and this app follow the system proxy, which may be dead,
/// while Claude Code in VS Code or a terminal gets a working proxy from its environment or settings.
enum Route: Equatable, CustomStringConvertible {
    case proxy(host: String, port: Int, socks: Bool, from: String)
    case system
    case direct

    var description: String {
        switch self {
        case .proxy(let host, let port, let socks, let from): return "\(socks ? "SOCKS" : "прокси") \(host):\(port) (\(from))"
        case .system: return "системный прокси"
        case .direct: return "напрямую"
        }
    }

    /// Same route, ignoring where it was found: one proxy set in several places is tried once.
    private var key: String {
        if case .proxy(let host, let port, let socks, _) = self { return "\(socks) \(host):\(port)" }
        return "\(self)"
    }

    /// One session per route, kept: each URLSession holds its connections until invalidated.
    nonisolated(unsafe) private static var sessions: [String: URLSession] = [:]
    private static let lock = NSLock()

    var session: URLSession {
        if self == .system { return .shared }
        Self.lock.lock()
        defer { Self.lock.unlock() }
        if let s = Self.sessions[key] { return s }
        let s = makeSession()
        Self.sessions[key] = s
        return s
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        switch self {
        case .system: return .shared
        case .direct:
            config.connectionProxyDictionary = [kCFNetworkProxiesHTTPEnable as String: 0,
                                                kCFNetworkProxiesHTTPSEnable as String: 0,
                                                kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
                                                kCFNetworkProxiesSOCKSEnable as String: 0]
        case .proxy(let host, let port, true, _):
            config.connectionProxyDictionary = [kCFNetworkProxiesSOCKSEnable as String: 1,
                                                kCFNetworkProxiesSOCKSProxy as String: host,
                                                kCFNetworkProxiesSOCKSPort as String: port]
        case .proxy(let host, let port, false, _):
            config.connectionProxyDictionary = [kCFNetworkProxiesHTTPSEnable as String: 1,
                                                kCFNetworkProxiesHTTPSProxy as String: host,
                                                kCFNetworkProxiesHTTPSPort as String: port]
        }
        return URLSession(configuration: config)
    }

    /// Proxies Claude Code uses first, then the system proxy, then no proxy at all.
    static func candidates() -> [Route] {
        var out: [Route] = []
        for r in claudeCodeProxies() + [.system, .direct] where !out.contains(where: { $0.key == r.key }) {
            out.append(r)
        }
        return out
    }

    private static let proxyVars = ["HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "HTTP_PROXY", "http_proxy"]

    /// Proxy settings of running Claude Code sessions (their environment, which VS Code fills from its
    /// own proxy setting), of ~/.claude/settings.json, and VS Code's `http.proxy`.
    static func claudeCodeProxies() -> [Route] { scanClaudeCode().routes }

    /// What `claudeCodeProxies()` found, plus one line per running session for the diagnostics report.
    static func scanClaudeCode() -> (routes: [Route], sessions: [String]) {
        var out: [Route] = []
        var seen: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessions = home.appendingPathComponent(".claude/sessions")
        for f in (try? FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value, Proc.info(pid) != nil,
                  let env = Proc.environment(pid) else { continue }
            let entry = env["CLAUDE_CODE_ENTRYPOINT"] ?? "?"
            let vars = proxyVars.filter { env[$0] != nil }
            seen.append("pid \(pid) \(entry): \(vars.isEmpty ? "прокси не задан" : vars.joined(separator: ", "))")
            if entry.hasPrefix("claude-desktop") { continue }
            for v in proxyVars { if let r = env[v].flatMap({ parse($0, from: "сессия \(entry), \(v)") }) { out.append(r) } }
        }
        let own = ProcessInfo.processInfo.environment
        for v in proxyVars { if let r = own[v].flatMap({ parse($0, from: "окружение приложения, \(v)") }) { out.append(r) } }
        if let d = try? Data(contentsOf: home.appendingPathComponent(".claude/settings.json")),
           let env = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["env"] as? [String: Any] {
            for v in proxyVars { if let r = (env[v] as? String).flatMap({ parse($0, from: "~/.claude/settings.json, \(v)") }) { out.append(r) } }
        }
        let vscode = home.appendingPathComponent("Library/Application Support/Code/User/settings.json")
        if let d = try? Data(contentsOf: vscode),
           let o = try? JSONSerialization.jsonObject(with: d, options: .json5Allowed) as? [String: Any],
           let r = (o["http.proxy"] as? String).flatMap({ parse($0, from: "VS Code http.proxy") }) {
            out.append(r)
        }
        return (out, seen)
    }

    /// "http://host:3128", "socks5://host:1080" or a bare "host:port". Login and password are not kept.
    static func parse(_ s: String, from: String) -> Route? {
        let text = s.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let c = URLComponents(string: text.contains("://") ? text : "http://" + text),
              let host = c.host, !host.isEmpty else { return nil }
        let socks = c.scheme?.hasPrefix("socks") == true
        return .proxy(host: host, port: c.port ?? (socks ? 1080 : c.scheme == "https" ? 443 : 80), socks: socks, from: from)
    }
}
