import AppKit
import SwiftUI
import Combine

/// Menu bar item: "5ч 42% 2ч13м │ 7д 8% 2д19ч", percent colored by how much of the limit is spent.
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
        button.attributedTitle = Self.title(for: model)
        button.toolTip = model.error ?? "Лимиты Claude — нажмите, чтобы открыть график"
    }

    static func title(for model: AppModel) -> NSAttributedString {
        let s = model.snapshot
        let stale = model.error != nil
        let title = NSMutableAttributedString()
        title.append(segment(label: "5ч", window: s?.fiveHour, stale: stale, now: model.now))
        title.append(NSAttributedString(string: "  │  ", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
        title.append(segment(label: "7д", window: s?.sevenDay, stale: stale, now: model.now))
        if stale {
            title.append(NSAttributedString(string: " ⚠︎", attributes: [
                .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.systemOrange]))
        }
        return title
    }

    private static func segment(label: String, window: LimitWindow?, stale: Bool, now: Date) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let small = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .bold)
        out.append(NSAttributedString(string: label + " ", attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        let color: NSColor = window.map { stale ? .secondaryLabelColor : Palette.nsColor($0.utilization / 100) } ?? .secondaryLabelColor
        out.append(NSAttributedString(string: Fmt.percent(window?.utilization), attributes: [.font: bold, .foregroundColor: color]))
        if let w = window, w.resetsAt != nil {
            out.append(NSAttributedString(string: " " + Fmt.countdown(to: w.resetsAt, now: now),
                                          attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }
}
