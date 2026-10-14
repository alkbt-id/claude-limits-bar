import AppKit
import SwiftUI
import Combine

/// Menu bar item: "5ч 42% 2ч13м" over "7д 8% 2д19ч" in two small lines, percent colored by how much of the limit is spent.
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
        popover.contentViewController = NSHostingController(rootView: PopoverView().environmentObject(model))

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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func render() {
        guard let button = item.button else { return }
        button.image = Self.image(for: model)
        button.toolTip = model.error ?? "Лимиты Claude — нажмите, чтобы открыть график"
    }

    static func image(for model: AppModel) -> NSImage {
        let s = model.snapshot
        let stale = model.error != nil
        let labelFont = NSFont.systemFont(ofSize: 8, weight: .semibold)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        let gray = NSColor.secondaryLabelColor

        // Columns: label | percent (right-aligned, fixed width) | time to reset.
        let rows = [("5ч", s?.fiveHour, CGFloat(12)), ("7д", s?.sevenDay, CGFloat(2))].map { label, w, baseline in
            let color: NSColor = w.map { stale ? gray : Palette.nsColor($0.utilization / 100) } ?? gray
            let time = w?.resetsAt != nil ? Fmt.countdown(to: w?.resetsAt, now: model.now) : ""
            return (NSAttributedString(string: label, attributes: [.font: labelFont, .foregroundColor: gray]),
                    NSAttributedString(string: Fmt.percent(w?.utilization), attributes: [.font: valueFont, .foregroundColor: color]),
                    NSAttributedString(string: time, attributes: [.font: timeFont, .foregroundColor: gray]),
                    baseline)
        }
        let warn = NSAttributedString(string: "⚠︎", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange])

        let labelWidth = ceil(rows.map { $0.0.size().width }.max() ?? 0)
        let valueWidth = ceil(("100%" as NSString).size(withAttributes: [.font: valueFont]).width)
        let timeWidth = ceil(rows.map { $0.2.size().width }.max() ?? 0)
        let valueRight = labelWidth + 3 + valueWidth
        var width = valueRight + (timeWidth > 0 ? 3 + timeWidth : 0)
        let warnX = width + 3
        if stale { width = warnX + ceil(warn.size().width) }

        // draw(at:) takes the line's bottom-left corner; the baseline sits `descender` above it.
        let img = NSImage(size: NSSize(width: width, height: 22), flipped: false) { _ in
            for (label, value, time, baseline) in rows {
                label.draw(at: NSPoint(x: 0, y: baseline + labelFont.descender))
                value.draw(at: NSPoint(x: valueRight - value.size().width, y: baseline + valueFont.descender))
                time.draw(at: NSPoint(x: valueRight + 3, y: baseline + timeFont.descender))
            }
            if stale { warn.draw(at: NSPoint(x: warnX, y: (22 - warn.size().height) / 2)) }
            return true
        }
        img.isTemplate = false
        return img
    }
}
