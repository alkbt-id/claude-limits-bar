import AppKit

/// Brings the window that hosts a session to the front: the VS Code window with the session's tab,
/// the terminal tab running `claude`, or Claude Desktop.
enum Navigator {
    /// VS Code and its forks: bundle id → URL scheme the Claude Code extension listens on.
    static let vscodeSchemes = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.vscodium": "vscodium",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
    ]
    /// VS Code's application support folder per bundle id: its logs map extension hosts to windows.
    static let vscodeDataDirs = [
        "com.microsoft.VSCode": "Code",
        "com.microsoft.VSCodeInsiders": "Code - Insiders",
        "com.vscodium": "VSCodium",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
    ]
    static let desktopBundleID = "com.anthropic.claudefordesktop"
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.github.wez.wezterm",
    ]
}

@MainActor
extension Navigator {
    static func open(_ s: LiveSession) {
        Log.write("open session \(s.id.prefix(8)) host \(s.host)")
        switch s.host {
        case .vscode(let id):
            openVSCode(s, bundleID: id)
        case .terminal(let id):
            if let tty = s.tty, let script = tabScript(bundleID: id, tty: tty), run(script) { return }
            activate(pid: s.hostPID, bundleID: id)
        case .desktop:
            activate(pid: s.hostPID, bundleID: desktopBundleID)
        case .other(let id):
            activate(pid: s.hostPID, bundleID: id)
        }
    }

    // MARK: VS Code

    /// Sends the extension's own link with `windowId`: VS Code routes it to exactly that window,
    /// the extension reveals the session's tab (or the sidebar holding it), and VS Code focuses the window.
    /// Opening the project folder instead is unsafe: a window opened from a .code-workspace file
    /// doesn't count as that folder, so VS Code opens a second window and resumes a copy of the session.
    private static func openVSCode(_ s: LiveSession, bundleID: String) {
        guard s.entrypoint == "claude-vscode", let scheme = vscodeSchemes[bundleID],
              let window = vscodeWindowID(claudePID: s.pid, appPID: s.hostPID, bundleID: bundleID) else {
            // A CLI in the integrated terminal, or the window is unknown: a link routed to the wrong
            // window would open a copy of the session there, so only bring VS Code forward.
            activate(pid: s.hostPID, bundleID: bundleID)
            return
        }
        var c = URLComponents()
        c.scheme = scheme
        c.host = "anthropic.claude-code"
        c.path = "/open"
        c.queryItems = [URLQueryItem(name: "session", value: s.id), URLQueryItem(name: "windowId", value: "\(window)")]
        guard let url = c.url else { return }
        Log.write("open \(url.absoluteString)")
        NSWorkspace.shared.open(url)
    }

    /// VS Code window id hosting the session. The extension starts `claude` from the window's extension
    /// host, and each window logs "Started local extension host with pid N." to
    /// `logs/<launch>/window<id>/renderer.log`, where `<launch>` is the app's start time.
    static func vscodeWindowID(claudePID: Int32, appPID: Int32?, bundleID: String) -> Int? {
        guard let exthost = Proc.info(claudePID)?.kp_eproc.e_ppid, let dataDir = vscodeDataDirs[bundleID] else { return nil }
        let fm = FileManager.default
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/\(dataDir)/logs")
        let needle = "Started local extension host with pid \(exthost)."
        // The running app's launch first (other folders there come from `code` CLI runs and old launches,
        // and pids repeat across launches), then the rest, newest first.
        var launches = ((try? fm.contentsOfDirectory(atPath: logs.path)) ?? []).sorted(by: >)
        if let appPID, let info = Proc.info(appPID) {
            let start = Proc.startTime(info)
            let own = (-2...2).map { launchName.string(from: start.addingTimeInterval(Double($0))) }
            launches = launches.filter(own.contains) + launches.filter { !own.contains($0) }
        }
        for launch in launches {
            let dir = logs.appendingPathComponent(launch)
            let windows = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            var best: (id: Int, at: Date)?
            for w in windows where w.hasPrefix("window") {
                guard let id = Int(w.dropFirst("window".count)) else { continue }
                let log = dir.appendingPathComponent(w).appendingPathComponent("renderer.log")
                guard let text = try? String(contentsOf: log, encoding: .utf8), text.contains(needle) else { continue }
                let at = (try? fm.attributesOfItem(atPath: log.path)[.modificationDate] as? Date) ?? .distantPast
                if at > (best?.at ?? .distantPast) { best = (id, at) }
            }
            if let best { return best.id }
        }
        Log.write("vscode window for extension host \(exthost) not found")
        return nil
    }

    private static let launchName: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f
    }()

    // MARK: Terminals

    private static func tabScript(bundleID: String, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch bundleID {
        case "com.apple.Terminal":
            return """
            tell application "Terminal"
                repeat with w in windows
                    repeat with t in tabs of w
                        if tty of t is "\(tty)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case "com.googlecode.iterm2":
            return """
            tell application "iTerm2"
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            if tty of s is "\(tty)" then
                                select w
                                select t
                                select s
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        default:
            return nil
        }
    }

    /// Runs AppleScript; true when it found the tab. The first run asks for Automation permission.
    private static func run(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { Log.write("applescript: \(error[NSAppleScript.errorMessage] ?? error)") }
        return result?.booleanValue == true
    }

    // MARK: Fallback

    /// Through Launch Services: NSRunningApplication.activate() from a menu bar app is often declined.
    private static func activate(pid: Int32?, bundleID: String?) {
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
        if let url = app?.bundleURL ?? bundleID.flatMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
        } else {
            app?.activate()
        }
    }
}
