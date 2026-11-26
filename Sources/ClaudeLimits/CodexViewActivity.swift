import Foundation

/// A writer lock can outlive its UI view by hours. Read the extension's explicit view interests
/// from the current app launch and the exact extension host that owns this Codex server.
/// Call on one serial background queue, like the live-session scanner.
final class CodexViewActivity: @unchecked Sendable {
    private let logsRoot: URL?
    private var resolved: [String: URL] = [:]
    private var readers: [String: Reader] = [:]

    init(logsRoot: URL? = nil) { self.logsRoot = logsRoot }

    func active(
        sessionID: String, serverPID: Int32, hostPID: Int32?, bundleID: String
    ) -> Bool? {
        guard UUID(uuidString: sessionID) != nil,
              let dataDir = Navigator.vscodeDataDirs[bundleID],
              let server = Proc.info(serverPID), let hostPID, let host = Proc.info(hostPID),
              let extensionHost = Proc.info(server.kp_eproc.e_ppid) else { return nil }
        let started = Proc.startTime(server), launched = Proc.startTime(host)
        let key = "\(serverPID):\(started.timeIntervalSince1970):\(hostPID):\(launched.timeIntervalSince1970)"
        let root = logsRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(dataDir)/logs")
        let log = resolved[key] ?? Self.logURL(
            logsRoot: root, launchedAt: launched,
            extensionHostPID: server.kp_eproc.e_ppid,
            extensionHostStartedAt: Proc.startTime(extensionHost)
        )
        guard let log else { return nil }
        if resolved.count > 32 { resolved.removeAll() }
        resolved[key] = log
        return update(log: log, since: started)[sessionID]
    }

    static func shouldShow(state: LiveSession.State, active: Bool?) -> Bool {
        active != false || (state != .idle && state != .stopped)
    }

    /// Fixture-testable resolver. Never search older launches or guess a window from its project.
    static func logURL(
        logsRoot: URL, launchedAt: Date, extensionHostPID: Int32, extensionHostStartedAt: Date
    ) -> URL? {
        // Log initialization can lag app launch. A folder must belong to this app lifetime;
        // the exact extension-host PID and its birth time below identify the actual window.
        let launches = (try? FileManager.default.contentsOfDirectory(
            at: logsRoot, includingPropertiesForKeys: nil
        )) ?? []
        let needle = "[info] Started local extension host with pid \(extensionHostPID)."
        var matches: [(at: Date, url: URL)] = []
        for launch in launches {
            let name = launch.lastPathComponent
            guard name.count == 15, let at = launchFormat.date(from: name),
                  at >= launchedAt.addingTimeInterval(-2),
                  at <= extensionHostStartedAt.addingTimeInterval(5) else { continue }
            let windows = (try? FileManager.default.contentsOfDirectory(
                at: launch, includingPropertiesForKeys: nil
            )) ?? []
            for window in windows where window.lastPathComponent.hasPrefix("window") {
                guard Int(window.lastPathComponent.dropFirst(6)) != nil,
                      let text = try? String(contentsOf: window.appendingPathComponent("renderer.log"),
                                             encoding: .utf8)
                else { continue }
                for line in text.split(separator: "\n") where line.hasSuffix(needle) {
                    guard let at = timestamp(String(line)),
                          abs(at.timeIntervalSince(extensionHostStartedAt)) < 5 else { continue }
                    matches.append((at, window.appendingPathComponent("exthost/openai.chatgpt/Codex.log")))
                }
            }
        }
        return matches.max { $0.at < $1.at }?.url
    }

    struct Event {
        var sessionID: String
        var active: Bool
        var at: Date
    }

    static func event(_ line: String) -> Event? {
        let marker = "[extension-app-server-manager] thread_stream_view_activity_changed "
        guard let range = line.range(of: marker), let at = timestamp(line),
              line[..<range.lowerBound] == "\(line.prefix(23)) [info] " else { return nil }
        let fields = line[range.upperBound...].split(whereSeparator: \.isWhitespace)
        let active = fields.first { $0.hasPrefix("active=") }.map { String($0.dropFirst(7)) }
        let id = fields.first { $0.hasPrefix("conversationId=") }.map { String($0.dropFirst(15)) }
        guard let id, UUID(uuidString: id) != nil, active == "true" || active == "false" else { return nil }
        return Event(sessionID: id, active: active == "true", at: at)
    }

    /// Incremental whole-line reader, also exposed internally for temporary-file fixtures.
    func update(log: URL, since startedAt: Date) -> [String: Bool] {
        let key = "\(log.path):\(startedAt.timeIntervalSince1970)"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.path) else { return [:] }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value
        var reader = readers[key] ?? Reader()
        if reader.offset > size || reader.inode != inode { reader = Reader() }
        reader.inode = inode
        guard size > reader.offset, let handle = try? FileHandle(forReadingFrom: log) else {
            return reader.states
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: reader.offset)
        guard let data = try? handle.readToEnd(), let last = data.lastIndex(of: 0x0A) else {
            return reader.states
        }
        for line in data[...last].split(separator: 0x0A) {
            guard let event = Self.event(String(decoding: line, as: UTF8.self)),
                  event.at >= startedAt.addingTimeInterval(-2) else { continue }
            reader.states[event.sessionID] = event.active
        }
        reader.offset += UInt64(last - data.startIndex + 1)
        if readers.count > 32 { readers.removeAll() }
        readers[key] = reader
        return reader.states
    }

    private struct Reader {
        var offset: UInt64 = 0
        var inode: UInt64?
        var states: [String: Bool] = [:]
    }

    private static func timestamp(_ line: String) -> Date? {
        guard line.count >= 23 else { return nil }
        return logFormat.date(from: String(line.prefix(23)))
    }

    private static let launchFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    private static let logFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
