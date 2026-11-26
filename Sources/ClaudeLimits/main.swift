import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AgentsModel()
    private var status: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = StatusItemController(model: model)
        model.start()

        // Refresh right after wake: timers drift while the Mac sleeps.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Log.write("wake")
            Task { @MainActor in
                await self?.model.claude.refresh()
                await self?.model.codex.refresh()
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
    if args.contains("--diagnose") {
        // Same report as the panel's stethoscope button, printed instead of copied.
        Task {
            print(await Diagnostics.report())
            exit(0)
        }
        RunLoop.main.run()
    }
    if args.contains("--codex-usage") {
        Task {
            do {
                let snap = try await Task.detached { try CodexAPI.fetch() }.value
                print("Codex: \(snap.codexPlan ?? "unknown"), 5h \(Fmt.percent(snap.fiveHour?.utilization)), week \(Fmt.percent(snap.sevenDay?.utilization))")
                exit(0)
            } catch {
                print(error.localizedDescription)
                exit(1)
            }
        }
        RunLoop.main.run()
    }
    if args.contains("--agents-status") {
        let claude = LiveSessionScanner().scan()
        let scanner = CodexScanner()
        let codex = scanner.live()
        print("Claude: running=\(!claude.isEmpty), sessions=\(claude.count), working=\(claude.filter(\.isWorking).count)")
        print("Codex: running=\(scanner.isRunning), sessions=\(codex.count), working=\(codex.filter(\.isWorking).count)")
        let history = scanner.scan()
        print("Codex history: sessions=\(history.count), tokens=\(Int(history.reduce(0) { $0 + $1.hourly.values.reduce(0, +) }))")
        exit(0)
    }
    if args.contains("--sessions") {
        // Debug: print what the panel's session list would show; `--watch` repeats every 3 s.
        let scanner = LiveSessionScanner()
        let codex = CodexScanner()
        repeat {
        print("— \(Fmt.time.string(from: Date()))")
        let live = args.contains("--codex") ? codex.live() : scanner.scan()
        for s in live {
            var window = ""
            if case .vscode(let id) = s.host { window = " window \(Navigator.vscodeWindowID(claudePID: s.pid, appPID: s.hostPID, bundleID: id).map(String.init) ?? "?")" }
            print("\(s.id.prefix(8)) pid \(s.pid) \(s.entrypoint ?? "?") host \(s.host)\(window) tty \(s.tty ?? "-") — \(s.title)")
            if let url = s.openURL { print("    opens \(url.absoluteString)") }
            print("    \(s.state) since \(Fmt.time.string(from: s.since)), agents \(s.agents), commands \(s.commands), cwd \(s.cwd)")
            for a in s.agentNames { print("      agent: \(a)") }
            for c in s.commandLines { print("      command: \(c)") }
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
