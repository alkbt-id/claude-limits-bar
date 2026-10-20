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
    var agents: Int              // running subagents
    var commands: Int            // running shell commands, background ones included
    var host: Host
    var hostPID: Int32?
    var tty: String?

    var project: String { URL(fileURLWithPath: cwd).lastPathComponent }
    var isWorking: Bool {
        if case .working = state { return true }
        return state == .background
    }
}

/// Reads ~/.claude/sessions/<pid>.json (one file per live Claude Code process), follows each session's
/// transcript incrementally and inspects the process tree. Call `scan` from one background queue.
final class LiveSessionScanner {
    private let claudeDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    private var tails: [String: TranscriptTail] = [:]
    private var transcriptPaths: [String: URL] = [:]
    private var hosts: [Int32: (LiveSession.Host, Int32?)] = [:]

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
            let agents = tail.map { Self.runningAgents(transcript: $0.url, since: procStart) } ?? 0
            let commands = Proc.children(pid).filter { Proc.isCommand($0) }.count

            let status = o["status"] as? String
            let statusAt = (o["statusUpdatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            let entrypoint = o["entrypoint"] as? String
            let (state, since) = Self.state(status: status, waitingFor: o["waitingFor"] as? String, statusAt: statusAt,
                                            tail: tail, agents: agents, commands: commands, reportsPrompts: entrypoint == "cli")

            if hosts[pid] == nil { hosts[pid] = Self.host(of: pid, entrypoint: entrypoint) }
            let (host, hostPID) = hosts[pid]!
            let name = (o["nameSource"] as? String) == "derived" ? nil : o["name"] as? String
            let title = name ?? tail?.title ?? titles[sid] ?? URL(fileURLWithPath: cwd).lastPathComponent
            out.append(LiveSession(id: sid, pid: pid, title: title, cwd: cwd, entrypoint: entrypoint,
                                   state: state, since: since ?? startedAt ?? Date(), agents: agents, commands: commands,
                                   host: host, hostPID: hostPID, tty: Proc.tty(proc)))
        }
        tails = tails.filter { alive.contains($0.key) }
        hosts = hosts.filter { pid in out.contains { $0.pid == pid.key } }
        return out
    }

    // MARK: State

    private static func state(status: String?, waitingFor: String?, statusAt: Date?, tail: TranscriptTail?,
                              agents: Int, commands: Int, reportsPrompts: Bool) -> (LiveSession.State, Date?) {
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
                return (.permission(detail: tool.name, sure: false), tool.ts)
            }
            return (.working(tool: tool?.name), t.turnStart ?? t.lastAt)
        }
    }

    /// Subagents of this session that have not finished: `<project>/<session>/subagents/agent-*.meta.json`
    /// without `"finished": true`, whose transcript was written by this process recently.
    private static func runningAgents(transcript: URL, since start: Date?) -> Int {
        let dir = transcript.deletingPathExtension().appendingPathComponent("subagents")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let fresh = Date().addingTimeInterval(-10 * 60)
        var n = 0
        for f in files where f.lastPathComponent.hasSuffix(".meta.json") {
            let log = dir.appendingPathComponent(f.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            guard let m = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m > fresh, m > (start ?? .distantPast) else { continue }
            guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            if (o["finished"] as? Bool) != true { n += 1 }
        }
        return n
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

    /// Bash tool commands, background ones included, start detached in a session of their own;
    /// stdio MCP servers stay in Claude's. The process name doesn't tell: the shell may exec the command.
    static func isCommand(_ pid: Int32) -> Bool {
        getsid(pid) == pid
    }
}
