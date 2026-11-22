import AppKit
import ApplicationServices

/// Finds sessions the user is looking at right now: their window is the frontmost one.
/// VS Code windows are told apart by title (`… — <folder>`), read through the Accessibility API;
/// Terminal and iTerm2 tabs by the tty of the selected tab, read through AppleScript;
/// an app that gave its sessions a link (`CLAUDE_LIMITS_OPEN_URL`) by the same link in the AXDocument
/// of its focused window, which it sets for the chat on screen (`NSWindow.setAccessibilityDocument`).
@MainActor
enum FocusProbe {
    /// Accessibility access, needed to read VS Code window titles.
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds the app to Privacy & Security → Accessibility.
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Seconds since the last keyboard or mouse input.
    static var userIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Ids of the given sessions shown in the frontmost window.
    static func focused(_ sessions: [LiveSession]) -> Set<String> {
        guard let front = NSWorkspace.shared.frontmostApplication else { return [] }
        // Matched by link alone: the link names one session, and the app's server that starts `claude`
        // may run detached from the app, so the session's host process need not be the front app.
        let linked = sessions.filter { $0.openURL != nil }
        if !linked.isEmpty {
            if !trusted {
                note("no Accessibility access: can't read which chat an app shows")
            } else if let doc = windowAttribute(front.processIdentifier, kAXDocumentAttribute) {
                let seen = linked.filter { $0.openURL?.absoluteString == doc }
                if !seen.isEmpty { return Set(seen.map(\.id)) }
            }
        }
        let mine = sessions.filter { $0.hostPID == front.processIdentifier }
        guard let host = mine.first?.host else { return [] }
        switch host {
        case .vscode:
            guard trusted else {
                note("no Accessibility access: can't read VS Code window titles")
                return []
            }
            guard let title = windowAttribute(front.processIdentifier, kAXTitleAttribute) else { return [] }
            let seen = mine.filter { titleShows(title, project: $0.project) }
            if seen.isEmpty { note("front VS Code window \"\(title)\" shows none of: \(mine.map(\.project).joined(separator: ", "))") }
            return Set(seen.map(\.id))
        case .terminal(let id):
            guard let tty = frontTTY(bundleID: id) else { return [] }
            return Set(mine.filter { $0.tty == tty }.map(\.id))
        case .desktop, .other:
            return []
        }
    }

    private static var lastNote: String?

    /// Logs why nothing matched, once per distinct reason.
    private static func note(_ text: String) {
        guard text != lastNote else { return }
        lastNote = text
        Log.write("focus: \(text)")
    }

    /// A text attribute (title, document) of the app's focused window.
    private static func windowAttribute(_ pid: pid_t, _ attribute: String) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// VS Code's default title is "<editor> — <folder>" or "<editor> — <workspace> (Workspace)".
    private static func titleShows(_ title: String, project: String) -> Bool {
        title.components(separatedBy: " — ").contains { part in
            let p = part.trimmingCharacters(in: .whitespaces)
            return p == project || p == "\(project) (Workspace)"
        }
    }

    private static func frontTTY(bundleID: String) -> String? {
        let source: String
        switch bundleID {
        case "com.apple.Terminal": source = "tell application \"Terminal\" to get tty of selected tab of front window"
        case "com.googlecode.iterm2": source = "tell application \"iTerm2\" to get tty of current session of current window"
        default: return nil
        }
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
