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
        _ = NSApplication.shared
        Task {
            await Snapshot.run(to: URL(fileURLWithPath: args[i + 1]), demo: args.contains("--demo"))
            exit(0)
        }
        RunLoop.main.run()
    }
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
    app.run()
}
