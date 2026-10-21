import Foundation

/// Subscription plans and their limits measured in Pro units.
/// Team seats are compared only with each other: a member can't move to a personal plan.
enum Plan: String, CaseIterable, Identifiable, Codable {
    case pro, max5, max20, teamStandard, teamPremium

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pro: return "Pro"
        case .max5: return "Max 5x"
        case .max20: return "Max 20x"
        case .teamStandard: return "Team Standard"
        case .teamPremium: return "Team Premium"
        }
    }

    /// Monthly billing; Team seats are $20 and $100 a month when billed annually.
    var price: Int {
        switch self {
        case .pro: return 20
        case .max5: return 100
        case .max20: return 200
        case .teamStandard: return 25
        case .teamPremium: return 125
        }
    }

    var isTeam: Bool { self == .teamStandard || self == .teamPremium }

    /// Plans to compare with: personal plans, or the Team seats.
    var lineup: [Plan] { Self.allCases.filter { $0.isTeam == isTeam } }

    /// 5-hour window size: Anthropic publishes 5x and 20x of Pro for Max, 1.25x and 6.25x for Team seats.
    var session: Double {
        switch self {
        case .pro: return 1
        case .max5: return 5
        case .max20: return 20
        case .teamStandard: return 1.25
        case .teamPremium: return 6.25
        }
    }

    /// Weekly limit size. Anthropic publishes no ratio; third-party trackers measure Max 20x
    /// at about 10x Pro per week, so the range runs from that measurement to the nominal 20x.
    /// Team Premium is sold as "5x more usage than Standard", taken for the week as well.
    var weekly: ClosedRange<Double> {
        switch self {
        case .pro: return 1...1
        case .max5: return 5...5
        case .max20: return 10...20
        case .teamStandard: return 1.25...1.25
        case .teamPremium: return 6.25...6.25
        }
    }

    /// Plan from the credentials Claude Code stores: `rateLimitTier` like "default_claude_max_20x",
    /// `subscriptionType` like "pro", "max" or "team". A Team Premium seat reports the "max_5x" tier.
    init?(tier: String?, subscription: String?) {
        let t = (tier ?? "").lowercased(), s = (subscription ?? "").lowercased()
        if s == "team" { self = t.contains("max_5x") || t.contains("premium") ? .teamPremium : .teamStandard }
        else if t.contains("20x") { self = .max20 }
        else if t.contains("5x") { self = .max5 }
        else if t.contains("pro") || s == "pro" { self = .pro }
        else { return nil }
    }

    /// Utilization `u` (%) seen on `from` as it would read on `self`.
    func session(_ u: Double, from: Plan) -> Double { u * from.session / session }

    func weekly(_ u: Double, from: Plan) -> ClosedRange<Double> {
        if from == self { return u...u }
        return (u * from.weekly.lowerBound / weekly.upperBound)...(u * from.weekly.upperBound / weekly.lowerBound)
    }
}

/// Peak utilization of one limit window, identified by its reset time.
struct WindowPeak: Codable {
    var reset: Date
    var peak: Double
    var last: Date
    /// Plan at the time of the poll: peaks keep their meaning after a plan change.
    var plan: Plan?
}

struct WindowHistory: Codable {
    var five: [WindowPeak] = []
    var week: [WindowPeak] = []
}

/// How the recorded windows would have looked on each plan.
struct PlanReport {
    struct Fit: Identifiable {
        let plan: Plan
        /// 5-hour windows that would have reached 100%.
        let fiveOver: Int
        /// Busiest 5-hour window on this plan, %.
        let fiveWorst: Double
        /// Busiest week on this plan, % (a range: the weekly ratio between plans is not published).
        let week: ClosedRange<Double>
        var id: Plan { plan }

        /// Worst case across both limits, used to place the plan marker.
        var worst: ClosedRange<Double> { max(fiveWorst, week.lowerBound)...max(fiveWorst, week.upperBound) }
        var fits: Bool { fiveOver == 0 && week.upperBound < 100 }
    }

    let current: Plan
    /// Earliest recorded window in the period: the stats cover `from...now`.
    let from: Date
    let fiveWindows: Int
    let fits: [Fit]
    /// A limit hit 100% on the plan it was recorded on: real need is above what the data shows.
    let capped: Bool

    static let period: TimeInterval = 28 * 86400

    init?(history: WindowHistory, current: Plan, now: Date) {
        let start = now.addingTimeInterval(-Self.period)
        let five = history.five.filter { $0.last >= start && $0.peak > 0 }
        let week = history.week.filter { $0.last >= start && $0.peak > 0 }
        guard !five.isEmpty || !week.isEmpty else { return nil }
        self.current = current
        from = (five + week).map { $0.last }.min() ?? now
        fiveWindows = five.count
        capped = (five + week).contains { $0.peak >= 100 }
        fits = current.lineup.map { plan in
            let f = five.map { plan.session($0.peak, from: $0.plan ?? current) }
            let w = week.map { plan.weekly($0.peak, from: $0.plan ?? current) }
            return Fit(plan: plan,
                       fiveOver: f.filter { $0 >= 100 }.count,
                       fiveWorst: f.max() ?? 0,
                       week: (w.map(\.lowerBound).max() ?? 0)...(w.map(\.upperBound).max() ?? 0))
        }
    }

    /// Cheapest plan that would have covered every recorded window.
    var cheapest: Plan? { fits.first { $0.fits }?.plan }
}
