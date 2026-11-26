import AppKit
import Foundation

struct CodexShellRequest {
    var threadID: String
    var command: String
    var startedAt: Date
    var endedAt: Date?
    var callID: String = ""
}

/// Local Codex history and live writers. Use a separate instance on each serial scan queue.
/// Tokens weight hours/sessions; they are not API dollars or a measured subscription charge.
final class CodexScanner: @unchecked Sendable {
    static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    private let root: URL
    private var tails: [String: CodexTranscriptTail] = [:]
    private var paths: [String: URL] = [:]
    private var processOwners: [Int32: (start: Date, thread: String, call: String?)] = [:]
    private let viewActivity = CodexViewActivity()
    private(set) var isRunning = false

    init(root: URL = CodexScanner.defaultRoot) { self.root = root }

    func scan() -> [SessionUsage] {
        let cutoff = Date().addingTimeInterval(-8 * 86400)
        let files = Self.transcripts(in: root, after: cutoff)
        var seen = Set<String>()
        for url in files {
            guard let id = Self.sessionID(url) else { continue }
            seen.insert(id)
            paths[id] = url
            tail(id: id, url: url).update()
        }
        tails = tails.filter { seen.contains($0.key) }
        paths = paths.filter { seen.contains($0.key) }

        var merged: [String: SessionUsage] = [:]
        for t in tails.values {
            let id = rootSession(of: t)
            let owner = tails[id] ?? t
            var s = merged[id] ?? SessionUsage(
                id: id, title: owner.title, cwd: owner.cwd,
                lastActive: owner.modified, hourly: [:]
            )
            for (hour, tokens) in t.hourly { s.hourly[hour, default: 0] += tokens }
            s.lastActive = max(s.lastActive, t.modified)
            merged[id] = s
        }
        return merged.values.filter { !$0.hourly.isEmpty }.sorted { $0.lastActive > $1.lastActive }
    }

    func live(titles: [String: String] = [:]) -> [LiveSession] {
        let writers = Self.openFiles(root: root)
        isRunning = !writers.isEmpty
        let ids = Set(writers.flatMap { $0.sessions.keys })
        if ids.contains(where: { paths[$0] == nil }) {
            for url in Self.transcripts(in: root) {
                if let id = Self.sessionID(url), ids.contains(id) { paths[id] = url }
            }
        }
        var owners: [String: Int32] = [:]
        for writer in writers {
            for (id, openPath) in writer.sessions {
                if let openPath { paths[id] = openPath }
                guard let url = paths[id] else { continue }
                tail(id: id, url: url).update()
                owners[id] = writer.pid
            }
        }
        tails = tails.filter { ids.contains($0.key) }
        paths = paths.filter { ids.contains($0.key) }
        let processes = runningCommands(writers: writers.map(\.pid), owners: owners)
        var commands: [String: [String]] = [:]
        var commandThreads = Set<String>()
        for process in processes {
            guard let t = tails[process.threadID] else { continue }
            commandThreads.insert(t.id)
            commands[rootSession(of: t), default: []].append(process.command)
        }
        return owners.compactMap { id, pid in
            guard let t = tails[id], !t.isSubagent, let proc = Proc.info(pid) else { return nil }
            let children = tails.values.filter {
                $0.isSubagent && rootSession(of: $0) == id
                    && ($0.isWorking || commandThreads.contains($0.id))
            }
            let names = children.map { $0.agentLabel ?? $0.title }.sorted()
            let activeCommands = commands[id] ?? []
            let state = Self.liveState(base: t.state, agents: names.count, commands: activeCommands.count)
            let host = Self.host(of: pid)
            let active: Bool?
            if case .vscode(let bundleID) = host.0 {
                active = viewActivity.active(sessionID: id, serverPID: pid,
                                             hostPID: host.1, bundleID: bundleID)
            } else { active = nil }
            guard CodexViewActivity.shouldShow(state: state, active: active) else { return nil }
            return LiveSession(
                id: id, pid: pid, title: titles[id] ?? t.title, cwd: t.cwd ?? "?",
                entrypoint: "codex", state: state, since: t.since ?? Proc.startTime(proc),
                agentNames: names, commandLines: activeCommands.isEmpty ? t.commandLines : activeCommands,
                host: host.0,
                hostPID: host.1, tty: Proc.tty(proc),
                openURL: Self.openURL(session: id, host: host.0)
            )
        }.sorted { $0.since > $1.since }
    }

    static func lastActivity() -> Date? {
        transcripts(in: defaultRoot, after: Date().addingTimeInterval(-8 * 86400))
            .compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date
            }.max()
    }

    /// A server can be running before it has a thread; helpers with "codex" in their name do not count.
    static func isRunning() -> Bool { !openFiles(root: defaultRoot).isEmpty }

    /// Live processes are authoritative after a tool yields its session ID or the turn ends.
    /// An explicit question or permission request still takes priority over background work.
    static func liveState(base: LiveSession.State, agents: Int, commands: Int) -> LiveSession.State {
        if (base == .idle || base == .stopped) && agents + commands > 0 { return .background }
        return base
    }

    struct RunningCommand {
        var threadID: String
        var command: String
    }

    /// Shells normally expose CODEX_THREAD_ID, but native executables can hide their environment.
    /// Keep exact PID/start-time attribution through exec; otherwise require a unique causal request.
    private func runningCommands(writers: [Int32], owners: [String: Int32]) -> [RunningCommand] {
        var queue = writers.map { (pid: $0, writer: $0) }
        var visited = Set<Int32>()
        var alive = Set<Int32>()
        var calls = Set<String>()
        var result: [RunningCommand] = []
        let requests = tails.values.flatMap(\.shellRequests)
        var index = 0
        while index < queue.count && visited.count < 4096 {
            let (pid, writer) = queue[index]
            index += 1
            guard pid > 1, visited.insert(pid).inserted else { continue }
            queue.append(contentsOf: Proc.children(pid).map { (pid: $0, writer: writer) })
            guard Proc.isCommand(pid), let info = Proc.info(pid) else { continue }
            let start = Proc.startTime(info)
            let env = Proc.environment(pid) ?? [:]
            let cached = processOwners[pid].flatMap { $0.start == start ? $0 : nil }
            let direct = env["CODEX_THREAD_ID"].flatMap { owners[$0] == writer ? $0 : nil }
            let saved = cached.flatMap { owners[$0.thread] == writer ? $0.thread : nil }
            let matched = direct ?? saved ?? Self.matchNativeCommand(
                commandLine: Proc.commandLine(pid), startedAt: start,
                requests: requests.filter { owners[$0.threadID] == writer }
            )
            guard let thread = matched else { continue }
            alive.insert(pid)
            let call = env["CODEX_TOOL_CALL_ID"] ?? cached?.call
            processOwners[pid] = (start, thread, call)
            // Nested shells can retain a tool call's environment; show that command once.
            let key = thread + ":" + (call ?? String(pid))
            guard calls.insert(key).inserted else { continue }
            result.append(RunningCommand(threadID: thread, command: Proc.commandLine(pid)))
        }
        processOwners = processOwners.filter { alive.contains($0.key) }
        return result
    }

    /// Matches complete simple shell commands, never substrings. Requests from different threads
    /// with the same command and overlapping causal intervals are deliberately left unattributed.
    static func matchNativeCommand(
        commandLine: String, startedAt: Date, requests: [CodexShellRequest]
    ) -> String? {
        let actual = simpleCommands(commandLine)
        guard actual.count == 1 else { return nil }
        let candidates = Set(requests.compactMap { request -> String? in
            guard startedAt >= request.startedAt.addingTimeInterval(-2),
                  startedAt <= (request.endedAt ?? Date()).addingTimeInterval(2),
                  simpleCommands(request.command).contains(actual[0]) else { return nil }
            return request.threadID
        })
        return candidates.count == 1 ? candidates.first : nil
    }

    /// A small lexer for literal argv and shell command separators; expansions are not guessed.
    private static func simpleCommands(_ text: String) -> [[String]] {
        var commands: [[String]] = [], words: [String] = [], word = ""
        var quote: Character?, escaped = false, unsafe = false
        func finishWord() { if !word.isEmpty { words.append(word); word = "" } }
        func finishCommand() {
            finishWord()
            while words.first.map({ $0.contains("=") && !$0.hasPrefix("/") }) == true {
                words.removeFirst()
            }
            if !unsafe, !words.isEmpty {
                words[0] = URL(fileURLWithPath: words[0]).lastPathComponent
                commands.append(words)
            }
            words = []; unsafe = false
        }
        for c in text {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\", quote != "'" { escaped = true; continue }
            if let q = quote {
                if c == q { quote = nil }
                else {
                    if q == "\"", c == "$" || c == "`" { unsafe = true }
                    word.append(c)
                }
            } else if c == "'" || c == "\"" { quote = c }
            else if c == ";" || c == "&" || c == "|" || c == "\n" { finishCommand() }
            else if c.isWhitespace { finishWord() }
            else {
                if "$`*?<>()[{}".contains(c) { unsafe = true }
                word.append(c)
            }
        }
        if quote == nil && !escaped { finishCommand() }
        return commands
    }

    private func tail(id: String, url: URL) -> CodexTranscriptTail {
        if let t = tails[id], t.url == url { return t }
        let t = CodexTranscriptTail(url: url, id: id)
        tails[id] = t
        return t
    }

    private func rootSession(of tail: CodexTranscriptTail) -> String {
        var id = tail.id
        var seen = Set<String>()
        while seen.insert(id).inserted, let parent = tails[id]?.parentID { id = parent }
        return id
    }

    static func sessionID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let id = String(name.suffix(36))
        return UUID(uuidString: id) == nil ? nil : id
    }

    /// The desktop's registered deep-link handler accepts codex://threads/<UUID>.
    static func openURL(session: String, host: LiveSession.Host) -> URL? {
        guard UUID(uuidString: session) != nil,
              case .other(let bundleID) = host, bundleID == "com.openai.codex" else { return nil }
        return URL(string: "codex://threads/\(session)")
    }

    private static func transcripts(in root: URL, after cutoff: Date? = nil) -> [URL] {
        var out: [URL] = []
        for name in ["sessions", "archived_sessions"] {
            let directory = root.appendingPathComponent(name)
            guard let en = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let cutoff {
                    guard let at = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate, at >= cutoff else { continue }
                }
                out.append(url)
            }
        }
        return out
    }

    struct Writer {
        var pid: Int32
        /// nil path means a writer lock exists but its transcript is not currently open.
        var sessions: [String: URL?] = [:]
    }

    /// `lsof` reports actual open descriptors, so old lock files on disk never imply a live session.
    /// No shell is involved; output is restricted to PID and file paths, without process environments.
    private static func openFiles(root: URL) -> [Writer] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-n", "-P", "-c", "codex", "-Fpn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        return parseOpenFiles(String(decoding: data, as: UTF8.self), root: root).filter {
            guard let executable = Proc.args($0.pid)?.first else { return false }
            return URL(fileURLWithPath: executable).lastPathComponent == "codex"
                && !isOwnDescendant($0.pid)
        }
    }

    private static func isOwnDescendant(_ pid: Int32) -> Bool {
        var current = pid
        for _ in 0..<40 {
            if current == getpid() { return true }
            guard let parent = Proc.info(current)?.kp_eproc.e_ppid, parent > 1 else { return false }
            current = parent
        }
        return false
    }

    static func parseOpenFiles(_ text: String, root: URL) -> [Writer] {
        var out: [Writer] = []
        let prefix = root.standardizedFileURL.path + "/"
        for line in text.split(separator: "\n") {
            if line.first == "p", let pid = Int32(line.dropFirst()) {
                out.append(Writer(pid: pid))
            } else if line.first == "n", !out.isEmpty {
                let path = String(line.dropFirst())
                guard path.hasPrefix(prefix) else { continue }
                let url = URL(fileURLWithPath: path)
                if path.contains("/thread-writer-locks/"), url.pathExtension == "lock",
                   let id = sessionID(url) {
                    if out[out.count - 1].sessions[id] == nil {
                        out[out.count - 1].sessions.updateValue(nil, forKey: id)
                    }
                } else if path.contains("/sessions/"), url.pathExtension == "jsonl",
                          let id = sessionID(url) {
                    out[out.count - 1].sessions.updateValue(url, forKey: id)
                }
            }
        }
        return out
    }

    private static func host(of pid: Int32) -> (LiveSession.Host, Int32?) {
        var p = pid
        for _ in 0..<20 {
            guard let parent = Proc.info(p)?.kp_eproc.e_ppid, parent > 1 else { break }
            p = parent
            guard let app = NSRunningApplication(processIdentifier: p),
                  let id = app.bundleIdentifier else { continue }
            if Navigator.vscodeSchemes[id] != nil { return (.vscode(bundleID: id), p) }
            if Navigator.terminalBundleIDs.contains(id) { return (.terminal(bundleID: id), p) }
            return (.other(bundleID: id), p)
        }
        return (.other(bundleID: nil), nil)
    }
}

/// Incremental, fixture-testable Codex JSONL reader. Incomplete trailing lines remain unread.
final class CodexTranscriptTail {
    let url: URL
    let id: String
    private var offset: UInt64 = 0
    private var ownContext = true
    private var foundMeta = false
    private(set) var parentID: String?
    private(set) var isSubagent = false
    private(set) var agentLabel: String?
    private(set) var cwd: String?
    private(set) var prompt: String?
    private(set) var state = LiveSession.State.idle
    private(set) var since: Date?
    private(set) var modified = Date.distantPast
    private(set) var shellRequests: [CodexShellRequest] = []
    private var pending: [String: (name: String, command: String?)] = [:]
    private var recordedUsage: [String: (hour: Int, tokens: Double)] = [:]
    private var fallbackHourly: [Int: Double] = [:]
    private var totalTokens = 0.0

    var title: String {
        prompt ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? String(id.prefix(8))
    }
    var isWorking: Bool {
        if case .working = state { return true }
        return state == .background
    }
    var commandLines: [String] { pending.values.compactMap(\.command).sorted() }
    var hourly: [Int: Double] {
        guard !recordedUsage.isEmpty else { return fallbackHourly }
        var hours: [Int: Double] = [:]
        for v in recordedUsage.values { hours[v.hour, default: 0] += v.tokens }
        return hours
    }

    init(url: URL, id: String) { self.url = url; self.id = id }

    func update() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return }
        modified = attrs[.modificationDate] as? Date ?? modified
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if size < offset { reset() }
        guard size > offset, let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let last = data.lastIndex(of: 0x0A) else { return }
        for line in data[...last].split(separator: 0x0A) { consume(Data(line)) }
        offset += UInt64(last - data.startIndex + 1)
    }

    private func reset() {
        offset = 0; ownContext = true; foundMeta = false
        parentID = nil; isSubagent = false; agentLabel = nil; cwd = nil; prompt = nil
        state = .idle; since = nil; pending = [:]; recordedUsage = [:]
        fallbackHourly = [:]; totalTokens = 0
        shellRequests = []
    }

    func consume(_ line: Data) {
        guard let o = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = o["type"] as? String, let p = o["payload"] as? [String: Any] else { return }
        let at = (o["timestamp"] as? String).flatMap(UsageAPI.parseDate) ?? modified
        if type == "session_meta" {
            guard p["id"] as? String == id else { ownContext = false; return }
            ownContext = true
            guard !foundMeta else { return }
            foundMeta = true
            cwd = p["cwd"] as? String
            parentID = p["parent_thread_id"] as? String
            agentLabel = p["agent_path"] as? String ?? p["agent_nickname"] as? String
            if let source = p["source"] as? [String: Any], let sub = source["subagent"] {
                isSubagent = true
                if let sub = sub as? [String: Any], let spawn = sub["thread_spawn"] as? [String: Any] {
                    parentID = parentID ?? spawn["parent_thread_id"] as? String
                    agentLabel = agentLabel ?? spawn["agent_path"] as? String
                }
            }
            return
        }
        if type == "token_usage_record" {
            guard p["thread_id"] as? String == id, let key = p["response_id"] as? String,
                  let usage = p["usage"] as? [String: Any] else { return }
            recordedUsage[key] = (Int(at.timeIntervalSince1970 / 3600), Self.tokens(usage))
            return
        }
        if type == "event_msg", p["type"] as? String == "thread_settings_applied" {
            let inherited = !ownContext
            ownContext = p["thread_id"] as? String == id
            if ownContext && inherited { totalTokens = 0 }
            return
        }
        guard ownContext else { return }
        if type == "turn_context" { cwd = p["cwd"] as? String ?? cwd; return }
        if type == "event_msg" { event(p, at: at) }
        if type == "response_item" { item(p, at: at) }
    }

    private func event(_ p: [String: Any], at: Date) {
        switch p["type"] as? String {
        case "task_started":
            state = .working(tool: nil); since = at; pending = [:]
        case "task_complete":
            finishRequests(at: at)
            state = .idle; since = at; pending = [:]
        case "turn_aborted":
            finishRequests(at: at)
            state = .stopped; since = at; pending = [:]
        case "user_message":
            if let text = p["message"] as? String, !text.isEmpty { prompt = Self.label(text) }
        case "token_count":
            guard let info = p["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else { return }
            let total = Self.tokens(usage)
            let delta = total >= totalTokens ? total - totalTokens : total
            totalTokens = total
            if delta > 0 { fallbackHourly[Int(at.timeIntervalSince1970 / 3600), default: 0] += delta }
        case "exec_approval_request", "apply_patch_approval_request":
            state = .permission(detail: nil, sure: true); since = at
        case "request_user_input":
            state = .question(plan: false); since = at
        default: break
        }
    }

    private func item(_ p: [String: Any], at: Date) {
        let type = p["type"] as? String
        if type == "function_call" || type == "custom_tool_call" {
            guard let key = p["call_id"] as? String, let raw = p["name"] as? String else { return }
            let name = raw.split(separator: ".").last.map(String.init) ?? raw
            let arguments = (p["arguments"] as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let command = (["exec_command", "shell", "shell_command"].contains(name))
                ? (arguments?["cmd"] as? String ?? arguments?["command"] as? String) : nil
            var commands = command.map { [$0] } ?? []
            if ["exec", "execute", "code"].contains(name),
               let code = arguments?["code"] as? String ?? p["input"] as? String {
                commands += Self.literalCommands(in: code)
            }
            for command in commands {
                shellRequests.append(CodexShellRequest(
                    threadID: id, command: command, startedAt: at, endedAt: nil, callID: key
                ))
            }
            // A PID/start-time cache retains old live work; rereading a transcript is bounded too.
            if shellRequests.count > 256 { shellRequests.removeFirst(shellRequests.count - 256) }
            pending[key] = (name, command.map(Self.label))
            if name == "request_user_input" {
                state = .question(plan: false); since = at
            } else { state = .working(tool: name) }
        } else if type == "function_call_output" || type == "custom_tool_call_output" {
            guard let key = p["call_id"] as? String else { return }
            finishRequests(callID: key, at: at)
            pending[key] = nil
            if state.wantsUser { since = at }
            state = .working(tool: pending.values.first?.name)
        }
    }

    private func finishRequests(callID: String? = nil, at: Date) {
        for i in shellRequests.indices
        where shellRequests[i].endedAt == nil && (callID == nil || shellRequests[i].callID == callID) {
            shellRequests[i].endedAt = at
        }
    }

    /// Decode only literal cmd arguments of exec_command calls in the code runner. No evaluation,
    /// variable interpolation, arbitrary substring matching, or command execution is performed.
    static func literalCommands(in code: String) -> [String] {
        let pattern = #"\bexec_command\s*\(\s*\{\s*(?:cmd|"cmd"|'cmd')\s*:\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = code as NSString
        let positions = codePositions(code)
        return regex.matches(in: code, range: NSRange(location: 0, length: source.length)).compactMap {
            guard positions.contains($0.range.location) else { return nil }
            return decodeLiteral(source.substring(with: $0.range(at: 1)))
        }
    }

    /// Ignore apparent calls inside JavaScript string literals or comments.
    private static func codePositions(_ code: String) -> Set<Int> {
        let chars = Array(code.utf16)
        var positions = Set<Int>(), index = 0
        var quote: UInt16?, escaped = false, lineComment = false, blockComment = false
        while index < chars.count {
            let c = chars[index], next = index + 1 < chars.count ? chars[index + 1] : 0
            if lineComment {
                if c == 10 { lineComment = false }
            } else if blockComment {
                if c == 42 && next == 47 { blockComment = false; index += 1 }
            } else if let q = quote {
                if escaped { escaped = false }
                else if c == 92 { escaped = true }
                else if c == q { quote = nil }
            } else if c == 47 && next == 47 { lineComment = true; index += 1 }
            else if c == 47 && next == 42 { blockComment = true; index += 1 }
            else if c == 34 || c == 39 || c == 96 { quote = c }
            else { positions.insert(index) }
            index += 1
        }
        return positions
    }

    private static func decodeLiteral(_ literal: String) -> String? {
        if literal.first == "\"", let data = literal.data(using: .utf8) {
            return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? String
        }
        guard literal.first == "'", literal.last == "'" else { return nil }
        var out = "", escaped = false
        for c in literal.dropFirst().dropLast() {
            if escaped {
                switch c {
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "\\", "'", "\"": out.append(c)
                default: return nil
                }
                escaped = false
            } else if c == "\\" { escaped = true }
            else { out.append(c) }
        }
        return escaped ? nil : out
    }

    private static func tokens(_ usage: [String: Any]) -> Double {
        if let value = usage["total_tokens"] as? NSNumber { return max(0, value.doubleValue) }
        let input = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
        let output = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
        // Cached input and reasoning output are already included in the corresponding totals.
        return max(0, input + output)
    }

    private static func label(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first { !$0.isEmpty } ?? ""
        return String(first.prefix(100))
    }
}
