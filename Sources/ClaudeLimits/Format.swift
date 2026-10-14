import AppKit
import SwiftUI

enum Palette {
    // Gradient stops: green → yellow → red.
    private static let stops: [(Double, (Double, Double, Double))] = [
        (0.0, (0.20, 0.72, 0.33)),
        (0.5, (0.96, 0.74, 0.10)),
        (1.0, (0.90, 0.22, 0.20)),
    ]

    /// Color for a fraction 0...1 of the limit spent.
    static func rgb(_ fraction: Double) -> (Double, Double, Double) {
        let f = min(max(fraction, 0), 1)
        for i in 1..<stops.count where f <= stops[i].0 {
            let (f0, a) = stops[i - 1], (f1, b) = stops[i]
            let t = (f - f0) / (f1 - f0)
            return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
        }
        return stops.last!.1
    }

    static func nsColor(_ fraction: Double) -> NSColor {
        let c = rgb(fraction)
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }

    static func color(_ fraction: Double) -> Color {
        let c = rgb(fraction)
        return Color(.sRGB, red: c.0, green: c.1, blue: c.2)
    }
}

enum Fmt {
    /// Compact countdown: "37м", "2ч13м", "2д19ч".
    static func countdown(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)д\(h)ч" }
        if h > 0 { return "\(h)ч\(String(format: "%02d", m))м" }
        return "\(m)м"
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f
    }()

    static let dayTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d MMM, HH:mm"
        return f
    }()

    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EE d"
        return f
    }()

    static func resetAt(_ d: Date?, now: Date) -> String {
        guard let d else { return "" }
        return Calendar.current.isDate(d, inSameDayAs: now) ? "в \(time.string(from: d))" : dayTime.string(from: d)
    }
}
