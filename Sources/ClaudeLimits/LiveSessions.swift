import AppKit
import Darwin

/// A running Claude Code session: VS Code extension, terminal CLI or Claude Desktop.
struct LiveSession: Identifiable, Equatable {
    enum State: Equatable {
        case working(tool: String?)
        /// The turn is over, but subagents or background commands still run.
        case background
        /// A permission prompt or another dialog waits for an answer. `sure` is false when it is
        /// only inferred from a tool call that hangs without progress (VS Code and Desktop don't report prompts).
        case permission(detail: String?, sure: Bool)
        /// AskUserQuestion or a plan waiting for approval.
        case question(plan: Bool)
        /// Claude finished the turn and waits for a new prompt.
        case idle
        /// The user interrupted the turn.
        case stopped

        /// States that ask the user to come back.
        var wantsUser: Bool {
            switch self {
            case .permission, .question, .idle: return true
            case .working, .background, .stopped: return false
            }
        }
    }

    enum Host: Equatable {
        case vscode(bundleID: String)
        case terminal(bundleID: String)
        case desktop
        case other(bundleID: String?)
    }

    var id: String               // session id
    var pid: Int32
    var title: String
    var cwd: String
    var entrypoint: String?
    var state: State
    var since: Date              // when the current state began
    var agentNames: [String]     // running subagents: their task descriptions
    var commandLines: [String]   // running shell commands, background ones included
    var host: Host
    var hostPID: Int32?
    var tty: String?

    var agents: Int { agentNames.count }
    var commands: Int { commandLines.count }
    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var isWorking: Bool {
        if case .working = state { return true }
        return state == .background
    }
}

/// Reads ~/.claude/sessions/<pid>.json (one file per live Claude Code process), follows each session's
/// transcript incrementally and inspects the process tree. Call `scan` from one background queue:
/// the state it keeps between scans is unguarded, hence unchecked Sendable.
final class LiveSessionScanner: @unchecked Sendable {
    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var tails: [String: TranscriptTail] = [:]
    private var transcriptPaths: [String: URL] = [:]
    private var hosts: [Int32: (LiveSession.Host, Int32?)] = [:]
    private let extensionLogs = ExtensionLogs()

    /// A tool call that hangs this long without transcript writes, commands or subagents is taken for a permission prompt.
    static let promptGuess: TimeInterval = 10

    func scan(titles: [String: String] = [:]) -> [LiveSession] {
        let dir = claudeDir.appendingPathComponent("sessions")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var out: [LiveSession] = []
        var alive = Set<String>()
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let pid = (o["pid"] as? NSNumber)?.int32Value,
                  let sid = o["sessionId"] as? String else { continue }
            let kind = o["kind"] as? String ?? "interactive"
            if kind == "daemon" || kind == "daemon-worker" { continue }
            let startedAt = (o["startedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            guard let proc = Proc.info(pid), Proc.isSame(proc, startedAt: startedAt) else { continue }
            alive.insert(sid)

            let cwd = o["cwd"] as? String ?? "?"
            let tail = transcript(for: sid, cwd: cwd).map { url -> TranscriptTail in
                let t = tails[sid] ?? TranscriptTail(url: url)
                t.update()
                tails[sid] = t
                return t
            }
            let procStart = Proc.startTime(proc)
            let agentNames = tail.map { Self.runningAgents(of: $0, since: procStart) } ?? []
            let commandLines = Proc.children(pid).filter { Proc.isCommand($0) }.map { Proc.commandLine($0) }
            let agents = agentNames.count, commands = commandLines.count

            let status = o["status"] as? String
            let statusAt = (o["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let entrypoint = o["entrypoint"] as? String
            let (state, since) = Self.state(status: status, waitingFor: o["waitingFor"] as? String, statusAt: statusAt,
                                            tail: tail, agents: agents, commands: commands, reportsPrompts: entrypoint == "cli",
                                            startedTools: extensionLogs.update)

            if hosts[pid] == nil { hosts[pid] = Self.host(of: pid, entrypoint: entrypoint) }
            let (host, hostPID) = hosts[pid]!
            let name = (o["nameSource"] as? String) == "derived" ? nil : o["name"] as? String
            let title = name ?? tail?.title ?? titles[sid] ?? URL(fileURLWithPath: cwd).lastPathComponent
            out.append(LiveSession(id: sid, pid: pid, title: title, cwd: cwd, entrypoint: entrypoint,
                                   state: state, since: since ?? startedAt ?? Date(), agentNames: agentNames, commandLines: commandLines,
                                   host: host, hostPID: hostPID, tty: Proc.tty(proc)))
        }
        tails = tails.filter { alive.contains($0.key) }
        hosts = hosts.filter { pid in out.contains { $0.pid == pid.key } }
        return out
    }

    // MARK: State

    private static func state(status: String?, waitingFor: String?, statusAt: Date?, tail: TranscriptTail?,
                              agents: Int, commands: Int, reportsPrompts: Bool,
                              startedTools: () -> Set<String>) -> (LiveSession.State, Date?) {
        // The terminal UI reports its own dialogs, permission prompts included.
        if status == "waiting" { return (.permission(detail: waitingFor, sure: true), statusAt) }
        guard let t = tail else {
            switch status {
            case "idle": return (agents + commands > 0 ? .background : .idle, statusAt)
            default: return (.working(tool: nil), statusAt)
            }
        }
        if let q = t.pending.values.first(where: { $0.name == "AskUserQuestion" || $0.name == "ExitPlanMode" }) {
            return (.question(plan: q.name == "ExitPlanMode"), q.ts)
        }
        switch t.last {
        case .endTurn:
            return (agents + commands > 0 ? .background : .idle, t.lastAt)
        case .interrupted:
            return (agents + commands > 0 ? .background : .stopped, t.lastAt)
        case .none:
            return (status == "busy" ? .working(tool: nil) : .idle, statusAt)
        case .working:
            let tool = t.pending.values.max { $0.ts < $1.ts }
            // VS Code and Desktop answer permission prompts themselves and don't report them.
            // A tool call that hangs without transcript writes, commands or subagents most likely waits for one.
            if !reportsPrompts, let tool, tool.name != "Agent", tool.name != "Task", commands == 0, agents == 0,
               Date().timeIntervalSince(t.modified) > promptGuess {
                // Unless the VS Code extension log shows a call already started: long MCP calls and fetches hang the same way.
                let started = startedTools()
                if !t.pending.keys.contains(where: started.contains) {
                    return (.permission(detail: tool.name, sure: false), tool.ts)
                }
            }
            return (.working(tool: tool?.name), t.turnStart ?? t.lastAt)
        }
    }

    /// Subagents of this session that have not finished: `<project>/<session>/subagents/agent-*.meta.json`
    /// without `"finished": true`, whose transcript was written by this process recently.
    /// Foreground subagents (a skill's, or an Agent call the session waits on) never get `finished`:
    /// they run only while the session waits for the tool call that started them.
    /// Returns their descriptions, oldest first.
    private static func runningAgents(of tail: TranscriptTail, since start: Date?) -> [String] {
        let dir = tail.url.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        let fresh = Date().addingTimeInterval(-10 * 60)
        var found: [(Date, String)] = []
        for f in files where f.lastPathComponent.hasSuffix(".meta.json") {
            let log = dir.appendingPathComponent(f.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            guard let m = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m > fresh, m > (start ?? .distantPast) else { continue }
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  (o["finished"] as? Bool) != true else { continue }
            if o["requestShape"] as? String == "foreground" {
                // A nested subagent's call is in its parent's transcript: then the session waits on its own call.
                let call = o["parentAgentId"] == nil ? o["toolUseId"] as? String : nil
                guard call.map({ tail.pending[$0] != nil }) ?? !tail.pending.isEmpty else { continue }
            }
            let name = (o["description"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? o["agentType"] as? String ?? "агент"
            found.append((m, name))
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    // MARK: Files and processes

    private func transcript(for sid: String, cwd: String) -> URL? {
        if let u = transcriptPaths[sid] { return u }
        let projects = claudeDir.appendingPathComponent("projects")
        let slug = String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        var url = projects.appendingPathComponent(slug).appendingPathComponent("\(sid).jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
            guard let hit = dirs.map({ $0.appendingPathComponent("\(sid).jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
            url = hit
        }
        transcriptPaths[sid] = url
        return url
    }

    /// The app hosting the session: the first ancestor process that is a regular macOS app.
    private static func host(of pid: Int32, entrypoint: String?) -> (LiveSession.Host, Int32?) {
        var p = pid
        for _ in 0..<20 {
            guard let info = Proc.info(p) else { break }
            let parent = info.kp_eproc.e_ppid
            guard parent > 1 else { break }
            p = parent
            guard let app = NSRunningApplication(processIdentifier: p), let id = app.bundleIdentifier else { continue }
            if Navigator.vscodeSchemes[id] != nil { return (.vscode(bundleID: id), p) }
            if id == Navigator.desktopBundleID { return (.desktop, p) }
            if Navigator.terminalBundleIDs.contains(id) { return (.terminal(bundleID: id), p) }
            return (.other(bundleID: id), p)
        }
        if entrypoint?.hasPrefix("claude-desktop") == true { return (.desktop, nil) }
        return (.other(bundleID: nil), nil)
    }
}

/// Incremental reader of one session transcript: remembers the read offset and keeps
/// the tool calls still waiting for results and the last turn event.
final class TranscriptTail {
    enum Last { case none, working, endTurn, interrupted }

    let url: URL
    private var offset: UInt64 = 0
    private(set) var pending: [String: (name: String, ts: Date)] = [:]
    private(set) var last = Last.none
    private(set) var lastAt: Date?
    /// The latest user prompt: when the current turn started.
    private(set) var turnStart: Date?
    private(set) var modified = Date.distantPast
    private var customTitle: String?, aiTitle: String?, lastPrompt: String?
    var title: String? { customTitle ?? aiTitle ?? lastPrompt.map { String($0.prefix(80)) } }

    init(url: URL) { self.url = url }

    func update() {
        // Not URL.resourceValues: it caches per URL object, and this URL lives as long as the session.
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        modified = a[.modificationDate] as? Date ?? modified
        let size = (a[.size] as? NSNumber)?.uint64Value ?? 0
        if size < offset { offset = 0; pending = [:]; last = .none }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), let lastNL = data.lastIndex(of: 0x0A) else { return }
        // Only whole lines: the last one may still be being written.
        offset += UInt64(lastNL - data.startIndex + 1)
        var start = data.startIndex
        while start <= lastNL {
            let end = data[start...].firstIndex(of: 0x0A) ?? lastNL
            handle(data[start..<end])
            start = end + 1
        }
    }

    private static let skip = [Data("{\"type\":\"api-request".utf8), Data("{\"type\":\"queue-operation".utf8)]
    private static let markers = ["\"type\":\"assistant\"", "\"type\":\"user\"", "\"type\":\"custom-title\"",
                                  "\"type\":\"ai-title\"", "\"type\":\"last-prompt\""].map { Data($0.utf8) }

    private func handle(_ line: Data) {
        if Self.skip.contains(where: { line.starts(with: $0) }) { return }
        guard Self.markers.contains(where: { line.range(of: $0) != nil }),
              let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = o["type"] as? String else { return }
        switch type {
        case "custom-title": customTitle = (o["customTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? customTitle
        case "ai-title": aiTitle = (o["aiTitle"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? aiTitle
        case "last-prompt": lastPrompt = (o["lastPrompt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? lastPrompt
        case "assistant", "user":
            if o["isSidechain"] as? Bool == true || o["isMeta"] as? Bool == true { return }
            // A background task notice that came when no turn could take it (after the turn ended, or on resume)
            // is only recorded: no reply follows it.
            if o["queueTranscriptOnly"] as? Bool == true { return }
            guard let msg = o["message"] as? [String: Any] else { return }
            let ts = (o["timestamp"] as? String).flatMap(UsageAPI.parseDate) ?? Date()
            let blocks = msg["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                for b in blocks where b["type"] as? String == "tool_use" {
                    if let id = b["id"] as? String { pending[id] = (b["name"] as? String ?? "?", ts) }
                }
                let stop = msg["stop_reason"] as? String
                let done = ["end_turn", "stop_sequence", "max_tokens", "refusal"].contains(stop ?? "")
                last = done && pending.isEmpty ? .endTurn : .working
            } else {
                var results = false
                for b in blocks where b["type"] as? String == "tool_result" {
                    results = true
                    if let id = b["tool_use_id"] as? String { pending[id] = nil }
                }
                let text = (msg["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined()
                if text.hasPrefix("[Request interrupted by user") {
                    pending = [:]
                    last = .interrupted
                } else {
                    if !results { turnStart = ts }
                    last = .working
                }
            }
            lastAt = ts
        default: break
        }
    }
}

/// Tool calls that VS Code sessions have started. The Claude Code extension runs `claude` with `--debug-to-stderr`
/// and copies its output to `logs/<launch>/window<id>/exthost/Anthropic.claude-code/*.log` in the app's support
/// folder, `[Stall] tool_dispatch_start tool=<name> toolUseId=<id>` included: written once a call got its permission.
/// Logs are read incrementally, only those written in the last day.
final class ExtensionLogs {
    private var offsets: [URL: UInt64] = [:]
    private var started: [String: Date] = [:]   // tool call id → when seen

    private static let marker = Data("tool_dispatch_start ".utf8)
    private static let idKey = Data("toolUseId=".utf8)
    private static let chunk = 4 << 20

    /// Reads what the logs gained since the last call; returns the ids of started tool calls.
    func update() -> Set<String> {
        let fm = FileManager.default
        let support = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dayAgo = Date().addingTimeInterval(-86400)
        var seen = Set<URL>()
        for app in Set(Navigator.vscodeDataDirs.values) {
            let logs = support.appendingPathComponent(app).appendingPathComponent("logs")
            for launch in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? [] {
                let dir = logs.appendingPathComponent(launch)
                for w in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where w.hasPrefix("window") {
                    let ext = dir.appendingPathComponent(w).appendingPathComponent("exthost/Anthropic.claude-code")
                    for f in (try? fm.contentsOfDirectory(atPath: ext.path)) ?? [] where f.hasSuffix(".log") {
                        let url = ext.appendingPathComponent(f)
                        guard let a = try? fm.attributesOfItem(atPath: url.path),
                              let m = a[.modificationDate] as? Date, m > dayAgo else { continue }
                        seen.insert(url)
                        read(url, size: (a[.size] as? NSNumber)?.uint64Value ?? 0)
                    }
                }
            }
        }
        offsets = offsets.filter { seen.contains($0.key) }
        started = started.filter { $0.value > dayAgo }
        return Set(started.keys)
    }

    private func read(_ url: URL, size: UInt64) {
        var offset = offsets[url] ?? 0
        if size < offset { offset = 0 }
        guard size > offset, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close(); offsets[url] = offset }
        let now = Date()
        // In chunks: a busy window logs tens of megabytes a day.
        while (try? h.seek(toOffset: offset)) != nil, let data = try? h.read(upToCount: Self.chunk), !data.isEmpty {
            // Only whole lines: the last one may still be being written. A full chunk without one is a huge line to skip.
            guard let lastNL = data.lastIndex(of: 0x0A) else {
                if data.count < Self.chunk { return }
                offset += UInt64(data.count)
                continue
            }
            var from = data.startIndex
            while let m = data.range(of: Self.marker, in: from..<lastNL) {
                let lineEnd = data[m.upperBound...].firstIndex(of: 0x0A) ?? lastNL
                from = lineEnd
                guard let k = data.range(of: Self.idKey, in: m.upperBound..<lineEnd) else { continue }
                let end = data[k.upperBound..<lineEnd].firstIndex(of: 0x20) ?? lineEnd
                started[String(decoding: data[k.upperBound..<end], as: UTF8.self)] = now
            }
            offset += UInt64(lastNL - data.startIndex + 1)
        }
    }
}

/// Process table helpers (sysctl / libproc).
enum Proc {
    static func info(_ pid: Int32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        return info
    }

    static func startTime(_ p: kinfo_proc) -> Date {
        let t = p.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1e6)
    }

    /// Guards against a recycled pid: the process must have started before the session did.
    static func isSame(_ p: kinfo_proc, startedAt: Date?) -> Bool {
        guard let startedAt else { return true }
        return startTime(p) <= startedAt.addingTimeInterval(5)
    }

    static func tty(_ p: kinfo_proc) -> String? {
        let dev = p.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    static func children(_ pid: Int32) -> [Int32] {
        var buf = [Int32](repeating: 0, count: 256)
        let n = proc_listchildpids(pid, &buf, Int32(buf.count * MemoryLayout<Int32>.size))
        return n > 0 ? Array(buf.prefix(Int(n))) : []
    }

    /// What a Bash tool command runs, its first line only. The tool starts
    /// `zsh -c "<snapshot setup> && eval '<command>' < /dev/null && pwd -P >| <file>"`; when the shell exec'd
    /// the command, argv is the command itself.
    static func commandLine(_ pid: Int32) -> String {
        guard let args = args(pid), !args.isEmpty else { return "?" }
        let name = args[0].isEmpty ? "" : URL(fileURLWithPath: args[0]).lastPathComponent
        var text = ([name] + args.dropFirst()).joined(separator: " ")
        let shell = name.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        if ["sh", "bash", "zsh", "dash"].contains(shell),
           let flag = args.dropFirst().firstIndex(where: { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("c") }),
           flag + 1 < args.count {
            let script = args[flag + 1]
            text = script
            if script.contains("&& pwd -P >| "), let r = script.range(of: "&& eval ") { text = shellWord(script[r.upperBound...]) }
        }
        let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) } ?? ""
        let flat = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.isEmpty ? "?" : flat
    }

    /// The first shell word of `s` with its quoting removed: `'a'"'"'b'` → `a'b`.
    private static func shellWord(_ s: Substring) -> String {
        var out = "", i = s.startIndex
        var quote: Character?
        while i < s.endIndex {
            let c = s[i]
            switch quote {
            case "'":
                if c == "'" { quote = nil } else { out.append(c) }
            case "\"":
                if c == "\"" { quote = nil }
                else if c == "\\", s.index(after: i) < s.endIndex, "\"\\$`".contains(s[s.index(after: i)]) {
                    i = s.index(after: i); out.append(s[i])
                } else { out.append(c) }
            default:
                if c == " " || c == "\t" { return out }
                if c == "'" || c == "\"" { quote = c }
                else if c == "\\", s.index(after: i) < s.endIndex { i = s.index(after: i); out.append(s[i]) }
                else { out.append(c) }
            }
            i = s.index(after: i)
        }
        return out
    }

    /// argv of a process (KERN_PROCARGS2: argc, exec path padded to 8 bytes, then the arguments).
    static func args(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }          // exec path
        // Skipping every NUL would also eat an empty argv[0] and shift the environment into argv.
        i = 4 + (i + 1 - 4 + 7) / 8 * 8
        var out: [String] = []
        while out.count < argc, i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            out.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        return out
    }

    /// Environment of a process: the strings KERN_PROCARGS2 holds after argv.
    static func environment(_ pid: Int32) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size, buf[i] != 0 { i += 1 }
        i = 4 + (i + 1 - 4 + 7) / 8 * 8
        var strings: [String] = []
        while i < size {
            var j = i
            while j < size, buf[j] != 0 { j += 1 }
            if j == i, strings.count >= argc { break }   // the environment ends with an empty string
            strings.append(String(decoding: buf[i..<j], as: UTF8.self))
            i = j + 1
        }
        var env: [String: String] = [:]
        for kv in strings.dropFirst(argc) {
            guard let eq = kv.firstIndex(of: "=") else { continue }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        return env
    }

    /// Bash tool commands, background ones included, start detached in a session of their own;
    /// stdio MCP servers stay in Claude's. The process name doesn't tell: the shell may exec the command.
    static func isCommand(_ pid: Int32) -> Bool {
        getsid(pid) == pid
    }
}
