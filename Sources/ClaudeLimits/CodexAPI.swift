import Foundation
import Darwin

enum CodexUsageError: LocalizedError {
    case notInstalled, timeout, unavailable, invalidResponse
    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Codex не найден. Установите Codex CLI или приложение Codex."
        case .timeout: return "Codex не ответил за 20 секунд. Попробуйте обновить лимиты."
        case .unavailable: return "Лимиты Codex недоступны. Проверьте вход в аккаунт в Codex."
        case .invalidResponse: return "Codex вернул неизвестный формат лимитов."
        }
    }
}

/// Uses Codex's read-only account RPC; Codex itself handles credentials and token refresh.
/// No agent turn or thread is started by this connection.
enum CodexAPI {
    static func executable() -> URL? {
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            .map { String($0) + "/codex" }
        let candidates = paths + [
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    static func fetch() throws -> UsageSnapshot {
        guard let executable = executable() else { throw CodexUsageError.notInstalled }
        let rpc = CodexAccountRPC(executable: executable)
        return try parse(rpc.readLimits())
    }

    static func parse(_ result: [String: Any], at now: Date = Date()) throws -> UsageSnapshot {
        let buckets = result["rateLimitsByLimitId"] as? [String: Any]
        guard let limits = (buckets?["codex"] ?? result["rateLimits"]) as? [String: Any] else {
            throw CodexUsageError.invalidResponse
        }
        var five: LimitWindow?, week: LimitWindow?
        for key in ["primary", "secondary"] {
            guard let value = limits[key] as? [String: Any],
                  let percent = value["usedPercent"] as? NSNumber,
                  let minutes = value["windowDurationMins"] as? NSNumber else { continue }
            let window = LimitWindow(utilization: max(0, percent.doubleValue),
                                     resetsAt: (value["resetsAt"] as? NSNumber)
                                        .map { Date(timeIntervalSince1970: $0.doubleValue) })
            switch minutes.intValue {
            case 300: five = window
            case 10080: week = window
            default: break
            }
        }
        return UsageSnapshot(fetchedAt: now, fiveHour: five, sevenDay: week,
                             codexPlan: limits["planType"] as? String,
                             ordinaryUsageAllowed: result["ordinaryUsageAllowed"] as? Bool)
    }
}

private final class CodexAccountRPC {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()
    private var deadline = Date.distantPast

    init(executable: URL) {
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
    }

    func readLimits() throws -> [String: Any] {
        deadline = Date().addingTimeInterval(20)
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            try? output.fileHandleForReading.close()
        }
        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "claude_limits", "version": "1.0.0"],
        ]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        return try response(id: 2)
    }

    private func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    private func response(id: Int) throws -> [String: Any] {
        while Date() < deadline {
            if let end = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<end]
                let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                buffer.removeSubrange(...end)
                guard let object, (object["id"] as? NSNumber)?.intValue == id else { continue }
                guard object["error"] == nil, let result = object["result"] as? [String: Any] else {
                    throw CodexUsageError.unavailable
                }
                return result
            }
            var fd = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
            let ready = poll(&fd, 1, remaining)
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { throw CodexUsageError.timeout }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty, buffer.count + data.count <= 4 * 1024 * 1024 else {
                throw CodexUsageError.invalidResponse
            }
            buffer.append(data)
        }
        throw CodexUsageError.timeout
    }
}
