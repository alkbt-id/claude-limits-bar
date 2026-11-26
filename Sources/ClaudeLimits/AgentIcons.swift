import AppKit

/// Brand assets from the providers' installed VS Code extensions.
/// Bundle resources are used by the app; the source path also supports `swift run` and snapshots.
@MainActor
enum AgentIcons {
    private static let images: [AgentKind: NSImage] = {
        var out: [AgentKind: NSImage] = [:]
        for agent in AgentKind.allCases {
            let ext = agent == .codex ? "svg" : "png"
            let source = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/\(agent.rawValue).\(ext)")
            let url = Bundle.main.url(forResource: agent.rawValue, withExtension: ext) ?? source
            out[agent] = NSImage(contentsOf: url)
        }
        return out
    }()

    static func image(for agent: AgentKind) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        return NSImage(size: size, flipped: false) { _ in
            let rect = NSRect(origin: .zero, size: size)
            if agent == .codex,
               let image = images[agent]?.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.clip(to: rect, mask: image)
                context.setFillColor(NSColor.labelColor.cgColor)
                context.fill(rect)
                context.restoreGState()
            } else {
                images[agent]?.draw(in: rect)
            }
            return true
        }
    }
}
