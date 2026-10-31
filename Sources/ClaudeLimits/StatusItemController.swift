import AppKit
import SwiftUI
import Combine

/// Menu bar item: "5ч 42% 11:49" over "7д 8% Пн 20:59" in two small lines, percent colored by how much of the limit is spent.
/// While Claude Code sessions run, a column on the left shows ▶2 (working) over 🔔1 (waiting for you),
/// or over the number of the rest (idle, already seen) in gray when none waits.
@MainActor
final class StatusItemController: NSObject {
    private let model: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        super.init()

        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: PopoverView().environmentObject(model))
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
            if let screen { model.panelHeight = min(PopoverView.height, screen.visibleFrame.height - 30) }
            popover.contentSize = NSSize(width: PopoverView.width + ScrollerInset.current(), height: model.panelHeight)
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
        button.image = Self.image(for: model)
        // Errors are shown only inside the panel; the menu bar stays quiet.
        var tip = "Лимиты Claude — нажмите, чтобы открыть панель"
        if !model.live.isEmpty {
            tip += "\nСессий Claude Code: \(model.live.count) · работают: \(model.workingCount) · ждут вас: \(model.attentionCount)"
        }
        button.toolTip = tip
    }

    static func image(for model: AppModel) -> NSImage {
        let s = model.snapshot
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let gray = NSColor.secondaryLabelColor

        // Columns: label | percent (right-aligned, fixed width) | reset time.
        // Two rows fit: without a 5-hour limit its place goes to Fable, or the weekly row sits alone in the middle.
        typealias Row = (String, LimitWindow?, TimeInterval, Bool, CGFloat)
        let fable: Row? = s?.fable.map { ("Fable", $0, LimitWindow.sevenDayLength, model.skipWeekends, 12) }
        let top: Row? = model.noFiveHourLimit ? fable : ("5ч", s?.fiveHour, LimitWindow.fiveHourLength, false, 12)
        let week: Row = ("7д", s?.sevenDay, LimitWindow.sevenDayLength, model.skipWeekends, top == nil ? 7 : 2)
        let rows = [top, week].compactMap { $0 }
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
