import SwiftUI
import Charts
import AppKit

struct PopoverView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        LimitCard(title: "5 часов", window: model.snapshot?.fiveHour, now: model.now)
                        LimitCard(title: "Неделя", window: model.snapshot?.sevenDay, now: model.now)
                    }
                    Section("Какой тариф нужен") { PlanFitView() }
                    Section("Лимиты за 7 дней") { HistoryChart() }
                    Section("Когда расходовался лимит") { HeatmapView() }
                    Section("Топ сессий за текущую неделю") { TopSessionsView() }
                }
                .padding(16)
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 470, height: 720)
    }

    private var footer: some View {
        HStack {
            Toggle("Запускать при входе", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
            Spacer()
            if let t = model.snapshot?.fetchedAt {
                Text("обновлено \(Fmt.time.string(from: t))").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                Task { await model.refresh(force: true) }
                model.rescanLogs()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(model.loading)
            .help("Обновить сейчас")
            Button("Выход") { NSApp.terminate(nil) }
        }
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
    }
}

// MARK: - Limit cards

private struct LimitCard: View {
    let title: String
    let window: LimitWindow?
    let now: Date

    var body: some View {
        let frac = (window?.utilization ?? 0) / 100
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(Fmt.percent(window?.utilization))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(window == nil ? Color.secondary : Palette.color(frac))
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(Palette.color(frac)).frame(width: max(4, g.size.width * min(frac, 1)))
                }
            }
            .frame(height: 6)
            if let r = window?.resetsAt {
                Text("сброс через \(Fmt.countdown(to: r, now: now)) · \(Fmt.resetAt(r, now: now))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}

// MARK: - Plan fit: recorded windows replayed on Pro / Max 5x / Max 20x

private struct PlanFitView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ваш тариф").font(.caption).foregroundStyle(.secondary)
                Picker("", selection: $model.planChoice) {
                    Text("Авто" + (model.detectedPlan.map { " (\($0.title))" } ?? "")).tag(Plan?.none)
                    ForEach(Plan.allCases) { Text($0.title).tag(Plan?.some($0)) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
                Spacer()
            }
            if model.plan == nil {
                Text("Тариф не определился по токену Claude Code — выберите его, чтобы сравнить.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let r = model.planReport {
                Text(verdict(r)).font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
                track(r)
                VStack(spacing: 4) { ForEach(r.fits) { row($0, r) } }
                Text(caption(r)).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Статистика копится: нужен хотя бы один замер с расходом лимита.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Marker position 0...1: segment of the cheapest plan that fits, offset by how full it would be.
    private func position(_ r: PlanReport, upper: Bool) -> Double {
        let n = Double(r.fits.count)
        for (i, f) in r.fits.enumerated() {
            let w = upper ? f.worst.upperBound : f.worst.lowerBound
            if f.fiveOver == 0, w < 100 { return (Double(i) + w / 100) / n }
        }
        return 1
    }

    private func track(_ r: PlanReport) -> some View {
        let lo = position(r, upper: false), hi = position(r, upper: true)
        // Color by how full the marker's own plan would be; past the last plan it is red.
        let seg = hi * Double(r.fits.count)
        let color = Palette.color(hi >= 1 ? 1 : seg - seg.rounded(.down))
        return VStack(spacing: 4) {
            GeometryReader { g in
                let w = g.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 3) {
                        ForEach(Plan.allCases) { p in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(LinearGradient(colors: [0, 0.5, 1].map { Palette.color($0).opacity(0.3) },
                                                     startPoint: .leading, endPoint: .trailing))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .stroke(p == r.current ? Color.primary.opacity(0.6) : .clear, lineWidth: 1.5))
                        }
                    }
                    .frame(height: 10)
                    if hi - lo > 0.005 {
                        Capsule().fill(color.opacity(0.45))
                            .frame(width: (hi - lo) * w, height: 6)
                            .offset(x: lo * w)
                    }
                    Circle().fill(color)
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .offset(x: min(max(hi * w - 8, 0), w - 16))
                }
            }
            .frame(height: 16)
            HStack(spacing: 3) {
                ForEach(Plan.allCases) { p in
                    Text("\(p.title) · $\(p.price)")
                        .font(.caption2.weight(p == r.current ? .bold : .regular))
                        .foregroundStyle(p == r.current ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func row(_ f: PlanReport.Fit, _ r: PlanReport) -> some View {
        HStack(spacing: 6) {
            Image(systemName: f.fits ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(f.fits ? Palette.color(0) : Palette.color(1))
            Text(f.plan.title + (f.plan == r.current ? " · сейчас" : ""))
                .font(.caption.weight(f.plan == r.current ? .bold : .regular))
            Spacer()
            Group {
                if f.fiveOver > 0 {
                    Text("5ч: упор в \(f.fiveOver) из \(r.fiveWindows)").foregroundStyle(Palette.color(1))
                } else {
                    Text("5ч: пик \(pct(f.fiveWorst))").foregroundStyle(Palette.color(f.fiveWorst / 100))
                }
                Text("неделя: \(pct(f.week))").foregroundStyle(Palette.color(f.week.upperBound / 100))
                    .frame(width: 118, alignment: .trailing)
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func verdict(_ r: PlanReport) -> String {
        guard let best = r.cheapest else { return "Не хватает даже Max 20x" }
        let maybe = r.fits.first { $0.fiveOver == 0 && $0.week.lowerBound < 100 }?.plan
        var text: String
        if best.price < r.current.price {
            text = "Хватило бы \(best.title) — экономия $\(r.current.price - best.price) в месяц"
        } else if best == r.current {
            text = "Текущий тариф — самый дешёвый из подходящих"
        } else {
            text = "По замерам нужен \(best.title)"
        }
        if let maybe, maybe.price < best.price {
            text += ". Возможно, хватит и \(maybe.title): зависит от недельного лимита, его Anthropic не публикует"
        }
        return text
    }

    private func caption(_ r: PlanReport) -> String {
        var parts = ["За \(r.days) дн.: окон по 5 ч — \(r.fiveWindows), недель — \(r.weeks)."]
        if r.completedWeeks == 0 { parts.append("Ни одна неделя ещё не закончилась — недельный расход может вырасти.") }
        if r.capped { parts.append("Лимит доходил до 100% — реальная потребность выше, чем видно по замерам.") }
        parts.append("Окно 5 ч у Max ровно ×5 и ×20 от Pro. Недельное соотношение не публикуется: для Max 20x взято 10–20× Pro, отсюда диапазон.")
        return parts.joined(separator: " ")
    }

    private func pct(_ v: Double) -> String { v >= 10 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v) }
    private func pct(_ r: ClosedRange<Double>) -> String {
        r.upperBound - r.lowerBound < 0.5 ? pct(r.upperBound) : "\(pct(r.lowerBound))–\(pct(r.upperBound))"
    }
}

// MARK: - Line chart of recorded polls

private struct HistoryChart: View {
    @EnvironmentObject var model: AppModel

    private struct Point: Identifiable {
        let t: Date, v: Double, series: String
        var id: String { "\(series)\(t.timeIntervalSince1970)" }
    }

    var body: some View {
        let start = model.now.addingTimeInterval(-7 * 86400)
        let samples = model.store.since(start)
        let points = samples.flatMap { s -> [Point] in
            var p: [Point] = []
            if let v = s.five { p.append(Point(t: s.t, v: v, series: "5 часов")) }
            if let v = s.week { p.append(Point(t: s.t, v: v, series: "Неделя")) }
            return p
        }
        if samples.count < 2 {
            Text("История копится: приложение записывает замер каждые \(Int(AppModel.pollInterval / 60)) мин. График появится после нескольких замеров.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        } else {
            Chart(points) { p in
                LineMark(x: .value("Время", p.t), y: .value("%", p.v))
                    .foregroundStyle(by: .value("Лимит", p.series))
                    .interpolationMethod(.stepEnd)
            }
            .chartForegroundStyleScale(["5 часов": Color.blue, "Неделя": Color.purple])
            .chartYScale(domain: 0...100)
            .chartXScale(domain: start...model.now)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Date.self) { Text(Fmt.weekday.string(from: d)) } }
                }
            }
            .chartYAxis { AxisMarks(values: [0, 50, 100]) { v in AxisGridLine(); AxisValueLabel("\(v.as(Int.self) ?? 0)%") } }
            .frame(height: 150)
        }
    }
}

// MARK: - Heatmap 7 days × 24 hours

private struct HeatmapView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("heatmapSource") private var source = Source.claudeCode

    enum Source: String, CaseIterable, Identifiable {
        case claudeCode, fiveHour, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .claudeCode: return "Claude Code"
            case .fiveHour: return "Лимит 5ч"
            case .weekly: return "Лимит недели"
            }
        }
    }

    private let cell: CGFloat = 14
    private let gap: CGFloat = 2

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: model.now)
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let start = days.first!
        let values = data(since: start)
        let maxV = values.values.max() ?? 0

        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: $source) {
                ForEach(Source.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    Text("").frame(width: 44)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 3 == 0 ? "\(h)" : "")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                            .frame(width: cell, alignment: .leading)
                    }
                }
                ForEach(days, id: \.self) { day in
                    HStack(spacing: gap) {
                        Text(Fmt.weekday.string(from: day))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            let date = cal.date(byAdding: .hour, value: h, to: day)!
                            let key = Int(date.timeIntervalSince1970 / 3600)
                            let v = values[key] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(fill(v, max: maxV, future: date > model.now))
                                .frame(width: cell, height: cell)
                                .help("\(Fmt.dayTime.string(from: date)) — \(label(v))")
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Text(caption).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("мало").font(.caption2).foregroundStyle(.secondary)
                LinearGradient(colors: [0, 0.5, 1].map { Palette.color($0) }, startPoint: .leading, endPoint: .trailing)
                    .frame(width: 70, height: 8).clipShape(Capsule())
                Text("много").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func data(since start: Date) -> [Int: Double] {
        switch source {
        case .claudeCode: return model.logHourly(since: start)
        case .fiveHour: return model.store.hourlyConsumption(since: start, weekly: false)
        case .weekly: return model.store.hourlyConsumption(since: start, weekly: true)
        }
    }

    private var caption: String {
        switch source {
        case .claudeCode: return "По логам Claude Code, в $ по ценам API"
        case .fiveHour: return "Прирост 5-часового лимита, % за час"
        case .weekly: return "Прирост недельного лимита, % за час"
        }
    }

    private func label(_ v: Double) -> String {
        if v <= 0 { return "нет расхода" }
        return source == .claudeCode ? String(format: "≈$%.2f", v) : String(format: "+%.1f%%", v)
    }

    private func fill(_ v: Double, max m: Double, future: Bool) -> Color {
        if future { return Color.secondary.opacity(0.04) }
        guard v > 0, m > 0 else { return Color.secondary.opacity(0.12) }
        // sqrt keeps small hours visible next to one huge hour.
        return Palette.color((v / m).squareRoot())
    }
}

// MARK: - Top sessions

private struct TopSessionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let top = model.topSessions()
        let maxCost = top.first?.cost ?? 1
        if top.isEmpty {
            Text("Нет сессий Claude Code в текущем недельном окне.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(spacing: 8) {
                ForEach(Array(top.enumerated()), id: \.element.id) { i, t in
                    Button { copyResume(t.session) } label: { row(i + 1, t, frac: t.cost / maxCost) }
                        .buttonStyle(.plain)
                        .help("Нажмите, чтобы скопировать команду продолжения сессии")
                }
                Text("% — оценка доли недельного лимита по логам Claude Code. Клик копирует команду `claude --resume`.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ rank: Int, _ t: AppModel.TopSession, frac: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(rank).").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 20, alignment: .trailing)
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.session.title).font(.callout).lineLimit(1).truncationMode(.tail)
                    Text(subtitle(t)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(t.weeklyPercent.map { String(format: "≈%.1f%%", $0) } ?? "—")
                        .font(.callout.monospacedDigit().bold())
                        .foregroundStyle(Palette.color(frac))
                    Text(String(format: "$%.2f", t.cost)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            GeometryReader { g in
                Capsule().fill(Palette.color(frac)).frame(width: max(3, g.size.width * frac))
            }
            .frame(height: 3)
            .padding(.leading, 28)
        }
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if model.copiedSession == t.id {
                Text("скопировано").font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(.green.opacity(0.85))).foregroundStyle(.white)
                    .offset(y: -8)
            }
        }
    }

    private func subtitle(_ t: AppModel.TopSession) -> String {
        let project = t.session.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "—"
        return "\(project) · \(Fmt.dayTime.string(from: t.session.lastActive))"
    }

    private func copyResume(_ s: SessionUsage) {
        var cmd = "claude --resume \(s.id)"
        if let cwd = s.cwd { cmd = "cd \(shellQuote(cwd)) && " + cmd }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
        model.copiedSession = s.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [model] in
            if model.copiedSession == s.id { model.copiedSession = nil }
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
