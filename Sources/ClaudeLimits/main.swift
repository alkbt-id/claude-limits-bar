import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(model: model)
        model.start()

        // Refresh right after wake: timers drift while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("wake")
            Task { @MainActor in
                await self?.model.refresh()
                self?.model.rescanLogs()
            }
        }
    }
}

MainActor.assumeIsolated {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        Log.enabled = false
        _ = NSApplication.shared
        Task {
            await Snapshot.run(to: URL(fileURLWithPath: args[i + 1]), demo: args.contains("--demo"))
            exit(0)
        }
        RunLoop.main.run()
    }
    if args.contains("--sessions") {
        // Debug: print what the panel's session list would show; `--watch` repeats every 3 s.
        let scanner = LiveSessionScanner()
        repeat {
        print("— \(Fmt.time.string(from: Date()))")
        for s in scanner.scan() {
            var window = ""
            if case .vscode(let id) = s.host { window = " window \(Navigator.vscodeWindowID(claudePID: s.pid, appPID: s.hostPID, bundleID: id).map(String.init) ?? "?")" }
            print("\(s.id.prefix(8)) pid \(s.pid) \(s.entrypoint ?? "?") host \(s.host)\(window) tty \(s.tty ?? "-") — \(s.title)")
            print("    \(s.state) since \(Fmt.time.string(from: s.since)), agents \(s.agents), commands \(s.commands), cwd \(s.cwd)")
        }
        fflush(stdout)
        if args.contains("--watch") { Thread.sleep(forTimeInterval: 3) }
        } while args.contains("--watch")
        exit(0)
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
