import AppKit
import SwiftUI
import Combine

/// Menu bar item: "5ч 42% 11:49" over "7д 8% Пн 20:59" in two small lines, percent colored by how much of the limit is spent.
/// While Claude Code sessions run, a column on the left shows ▶2 (working) over 🔔1 (waiting for you),
/// or over the number of the rest (idle, already seen) in gray when none waits.
/// A closed agent, or one with nothing working, nobody waiting and no state change for the time set in the panel
/// (30 minutes by default), sleeps: only its dimmed icon with "zᶻ" stays.
@MainActor
final class StatusItemController: NSObject {
    private let model: AgentsModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AgentsModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView(agents: model))
        // The size is set before each show instead: a size SwiftUI reports later, after the popover
        // is placed, can leave it pushed up past the top of the screen.
        host.sizingOptions = []
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(toggle)
            button.imagePosition = .imageOnly
        }

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in DispatchQueue.main.async { self?.render() } }
            .store(in: &bag)
        render()
    }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.rescanLogs()
            // A panel taller than the screen below the menu bar would be pushed up over it, its top cut off.
            let screen = button.window?.screen ?? NSScreen.main
            if let screen { model.setPanelHeight(min(PopoverView.height, screen.visibleFrame.height - 30)) }
            popover.contentSize = NSSize(width: PopoverView.width + ScrollerInset.current(), height: model.current.panelHeight)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            let frame = popover.contentViewController?.view.window?.frame
            if let frame, let screen, frame.maxY > screen.visibleFrame.maxY + 1 {
                Log.write("panel off screen: panel \(frame), button \(button.window?.frame ?? .zero), screen \(screen.frame), visible \(screen.visibleFrame), screens \(NSScreen.screens.map(\.frame))")
            }
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func render() {
        guard let button = item.button else { return }
        // Always shown: a closed agent sleeps too, so the panel with the limits stays one click away.
        item.isVisible = true
        button.image = Self.image(for: model)
        // Errors are shown only inside the panel; the menu bar stays quiet.
        var tip = "Лимиты агентов — нажмите, чтобы открыть панель"
        for agent in model.all {
            let title = agent.agent.sessionTitle
            tip += !agent.isRunning ? "\n\(title): не запущен"
                : model.isAsleep(agent) ? "\n\(title): спит · сессий: \(agent.live.count)"
                : "\n\(title): \(agent.live.count) · работают: \(agent.workingCount) · ждут вас: \(agent.attentionCount)"
        }
        button.toolTip = tip
    }

    /// One block per agent: its icon, then counters and limits. A sleeping agent (closed, or nothing
    /// works, nobody waits and nothing changed for the set time) shows only its dimmed icon with "zᶻ".
    static func image(for model: AgentsModel) -> NSImage {
        let parts = model.all.map { agent -> NSImage in
            model.isAsleep(agent) ? AgentIcons.sleeping(agent.agent) : awake(agent)
        }
        let width = parts.reduce(CGFloat(0)) { $0 + $1.size.width + 5 }
        return NSImage(size: NSSize(width: max(1, width), height: 22), flipped: false) { _ in
            var x: CGFloat = 0
            for part in parts {
                part.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
                x += part.size.width + 5
            }
            return true
        }
    }

    /// The agent's icon followed by its counters and limits.
    private static func awake(_ agent: AppModel) -> NSImage {
        let icon = AgentIcons.image(for: agent.agent)
        let block = image(for: agent)
        return NSImage(size: NSSize(width: 19 + block.size.width, height: 22), flipped: false) { _ in
            icon.draw(at: NSPoint(x: 0, y: 3), from: .zero, operation: .sourceOver, fraction: 1)
            block.draw(at: NSPoint(x: 19, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    static func image(for model: AppModel) -> NSImage {
        let s = model.snapshot
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let gray = NSColor.secondaryLabelColor

        // Columns: label | percent (right-aligned, fixed width) | reset time.
        // Two rows fit, in the panel's order: without a 5-hour limit the weekly row moves up with Fable under it,
        // or sits alone in the middle.
        typealias Row = (String, LimitWindow?, TimeInterval, Bool, CGFloat)
        let five: Row? = model.noFiveHourLimit ? nil : ("5ч", s?.fiveHour, LimitWindow.fiveHourLength, false, 12)
        let fable: Row? = model.noFiveHourLimit ? s?.fable.map { ("Fable", $0, LimitWindow.sevenDayLength, model.skipWeekends, 2) } : nil
        let week: Row = ("7д", s?.sevenDay, LimitWindow.sevenDayLength, model.skipWeekends, five != nil ? 2 : fable != nil ? 12 : 7)
        let rows = [five, week, fable].compactMap { $0 }
            .map { ($0.0, $0.1?.current(at: model.now), $0.2, $0.3, $0.4) }.map { label, w, length, skip, baseline in
            let color: NSColor = w.map { Palette.nsColor($0.strain(at: model.now, length: length, skipWeekends: skip)) } ?? gray
            let time = w?.resetsAt.map { Fmt.resetClock($0, now: model.now) } ?? ""
            return (NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: gray]),
                    NSAttributedString(string: Fmt.percent(w?.utilization), attributes: [.font: valueFont, .foregroundColor: color]),
                    NSAttributedString(string: time, attributes: [.font: timeFont, .foregroundColor: gray]),
                    baseline)
        }

        let labelWidth = ceil(rows.map { $0.0.size().width }.max() ?? 0)
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)
        let timeWidth = ceil(rows.map { $0.2.size().width }.max() ?? 0)
        // Sessions column, only while sessions run: working over waiting for you,
        // or over the rest (idle, already seen) in gray when none waits.
        let sessions: [(NSAttributedString, CGFloat)] = model.live.isEmpty ? [] : {
            let n = model.attentionCount
            let w = model.workingCount
            return [(Self.counter("play.fill", w, color: w > 0 ? .systemGreen : .tertiaryLabelColor, font: valueFont), 12),
                    (n > 0 ? Self.counter("bell.fill", n, color: .systemOrange, font: valueFont)
                           : Self.counter("checkmark", model.live.count - w, color: gray, font: valueFont), 2)]
        }()
        let sessionsWidth = ceil(sessions.map { $0.0.size().width }.max() ?? 0)
        let x0 = sessionsWidth > 0 ? sessionsWidth + 6 : 0

        let valueRight = x0 + labelWidth + 3 + valueWidth
        let width = valueRight + (timeWidth > 0 ? 3 + timeWidth : 0)

        // draw(at:) takes the line's bottom-left corner; the baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            for (text, baseline) in sessions {
                text.draw(at: NSPoint(x: 0, y: baseline + valueFont.descender))
            }
            for (label, value, time, baseline) in rows {
                label.draw(at: NSPoint(x: x0, y: baseline + labelFont.descender))
                value.draw(at: NSPoint(x: valueRight - value.size().width, y: baseline + valueFont.descender))
                time.draw(at: NSPoint(x: valueRight + 3, y: baseline + timeFont.descender))
            }
            return true
        }
        img.isTemplate = false
        return img
    }

    /// SF Symbol + count, both in `color`.
    private static func counter(_ symbol: String, _ n: Int, color: NSColor, font: NSFont) -> NSAttributedString {
        let s = NSMutableAttributedString()
        let config = NSImage.SymbolConfiguration(pointSize: 7, weight: .bold).applying(.init(paletteColors: [color]))
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let a = NSTextAttachment()
            a.image = img
            a.bounds = NSRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
            s.append(NSAttributedString(attachment: a))
            s.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 2)]))
        }
        s.append(NSAttributedString(string: "\(n)", attributes: [.font: font, .foregroundColor: color]))
        return s
    }
}
