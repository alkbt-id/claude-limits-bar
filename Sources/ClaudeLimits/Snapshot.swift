import AppKit
import SwiftUI

/// `ClaudeLimits --snapshot <dir> [--demo]`: renders the panel and the menu bar title to PNG.
/// With `--demo` all data is made up, so the images are safe to publish.
@MainActor
enum Snapshot {
    static func run(to dir: URL, demo: Bool) async {
        let model: AppModel
        if demo {
            model = demoModel()
        } else {
            model = AppModel()
            await model.refresh()
            model.sessions = LogScanner().scan()
        }

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            await render(PopoverView(), model: model, appearance: appearance, width: PopoverView.width + ScrollerInset.current(),
                         height: PopoverView.height, to: dir.appendingPathComponent("panel-\(suffix).png"))
            // Each block on its own, at its natural height, for the README.
            for part in [PanelPart.Kind.sessions, .usage, .plan] {
                await render(PanelPart(kind: part).padding(16), model: model, appearance: appearance, height: nil,
                             to: dir.appendingPathComponent("part-\(part.rawValue)-\(suffix).png"))
            }
            saveMenuBar(model, appearance: appearance, to: dir.appendingPathComponent("menubar-\(suffix).png"))
        }
        // The calm menu bar: nobody waits, the gray checkmark counts the rest.
        model.markAllRead()
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            saveMenuBar(model, appearance: appearance, to: dir.appendingPathComponent("menubar-quiet-\(suffix).png"))
        }
    }

    /// Renders a view in a borderless window; `height` nil takes the view's own height.
    private static func render<V: View>(_ view: V, model: AppModel, appearance: NSAppearance.Name, width: CGFloat = PopoverView.width,
                                        height: CGFloat?, to url: URL) async {
        let host = NSHostingView(rootView: view.environmentObject(model)
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height ?? host.fittingSize.height)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: appearance)
        win.backgroundColor = appearance == .aqua ? .white : NSColor(white: 0.16, alpha: 1)
        win.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 300_000_000)
        save(host, to: url)
    }

    private static func saveMenuBar(_ model: AppModel, appearance: NSAppearance.Name, to url: URL) {
        let img = StatusItemController.image(for: model)
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: img.size.width + 24, height: 24))
        bar.appearance = NSAppearance(named: appearance)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = (appearance == .aqua ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.12, alpha: 1)).cgColor
        let iv = NSImageView(frame: NSRect(x: 12, y: 1, width: img.size.width, height: img.size.height))
        iv.image = img
        bar.addSubview(iv)
        let win = NSWindow(contentRect: bar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: appearance)
        win.contentView = bar
        save(bar, to: url)
    }

    private static func demoModel() -> AppModel {
        let now = Date()
        let cal = Calendar.current
        let fiveReset = now.addingTimeInterval(2 * 3600 + 13 * 60)
        let weekReset = now.addingTimeInterval(2 * 86400 + 19 * 3600)
        let weekStart = weekReset.addingTimeInterval(-7 * 86400)
        var rng = SystemRandomNumberGenerator()

        // Working hours get load, nights stay empty.
        func load(_ d: Date) -> Double {
            let h = cal.component(.hour, from: d), wd = cal.component(.weekday, from: d)
            guard (9...23).contains(h) else { return 0 }
            let peak = (h >= 14 && h <= 18) ? 1.0 : 0.45
            let weekend = (wd == 1 || wd == 7) ? 0.5 : 1.0
            return Double.random(in: 0...1, using: &rng) < 0.25 ? 0 : peak * weekend * Double.random(in: 0.3...1, using: &rng)
        }

        // Polls every 30 min for 7 days: 5h window climbs and resets, weekly climbs steadily.
        var samples: [Sample] = []
        var five = 0.0, week = 0.0
        var t = now.addingTimeInterval(-7 * 86400)
        var fiveEnd = t.addingTimeInterval(5 * 3600)
        var weekEnd = weekStart
        while t <= now {
            if t >= fiveEnd { five = 0; fiveEnd = t.addingTimeInterval(5 * 3600) }
            if t >= weekEnd { week = 0; weekEnd = weekReset }
            let l = load(t)
            five = min(100, five + l * 14)
            week = min(100, week + l * 1.6)
            samples.append(Sample(t: t, five: five, fiveReset: fiveEnd, week: week, weekReset: weekEnd))
            t.addTimeInterval(1800)
        }

        let model = AppModel(store: SampleStore(samples: samples, plan: .max20))
        model.planChoice = .max20
        model.snapshot = UsageSnapshot(fetchedAt: now,
                                       fiveHour: LimitWindow(utilization: 42, resetsAt: fiveReset),
                                       sevenDay: LimitWindow(utilization: 61, resetsAt: weekReset),
                                       claudeCodeShare: 0.9)

        let titles = [("Рефакторинг API платежей", "payments-api"), ("Миграция на Swift 6", "ios-app"),
                      ("Разбор флаки-тестов CI", "backend"), ("Новый онбординг", "web-app"),
                      ("Оптимизация SQL-запросов", "backend"), ("Документация SDK", "sdk"),
                      ("Ревью PR #482", "web-app"), ("Скрипт выгрузки отчётов", "tools")]
        model.sessions = titles.enumerated().map { i, item in
            var hourly: [Int: Double] = [:]
            var d = now.addingTimeInterval(-7 * 86400)
            while d <= now {
                if Int(d.timeIntervalSince1970 / 3600) % titles.count == i || Double.random(in: 0...1, using: &rng) < 0.04 {
                    hourly[Int(d.timeIntervalSince1970 / 3600)] = load(d) * Double(titles.count - i) * 1.6
                }
                d.addTimeInterval(3600)
            }
            return SessionUsage(id: UUID().uuidString, title: item.0, cwd: "/Users/demo/code/\(item.1)",
                                lastActive: now.addingTimeInterval(-Double(i) * 7 * 3600), hourly: hourly)
        }

        func live(_ title: String, _ project: String, _ host: LiveSession.Host, _ state: LiveSession.State,
                  ago: TimeInterval, agents: [String] = [], commands: [String] = []) -> LiveSession {
            LiveSession(id: UUID().uuidString, pid: 0, title: title, cwd: "/Users/demo/code/\(project)",
                        entrypoint: host == .vscode(bundleID: "com.microsoft.VSCode") ? "claude-vscode" : "cli",
                        state: state, since: now.addingTimeInterval(-ago), agentNames: agents, commandLines: commands,
                        host: host, hostPID: nil, tty: nil)
        }
        let vscode = LiveSession.Host.vscode(bundleID: "com.microsoft.VSCode")
        model.live = [
            live("Рефакторинг API платежей", "payments-api", vscode, .question(plan: false), ago: 120),
            live("Миграция на Swift 6", "ios-app", .terminal(bundleID: "com.googlecode.iterm2"),
                 .permission(detail: "dialog open", sure: true), ago: 50),
            live("Разбор флаки-тестов CI", "backend", vscode, .working(tool: "Bash"), ago: 300,
                 agents: ["Ревью диффа", "Поиск флаки-тестов"], commands: ["npm test -- --watch"]),
            live("Новый онбординг", "web-app", .desktop, .background, ago: 600, agents: ["Сбор метрик онбординга"]),
            live("Документация SDK", "sdk", vscode, .idle, ago: 180),
            live("Ревью PR #482", "web-app", vscode, .idle, ago: 2400),
        ]
        model.markRead([model.live[5].id])
        return model
    }

    private static func save(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
