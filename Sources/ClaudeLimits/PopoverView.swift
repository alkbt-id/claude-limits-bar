import SwiftUI
import AppKit

struct PopoverView: View {
    @EnvironmentObject var model: AppModel
    nonisolated static let width: CGFloat = 540
    nonisolated static let height: CGFloat = 760
    @StateObject private var scroller = ScrollerInset()

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let err = model.error {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    PanelPart(kind: .limits)
                    Divider()
                    PanelPart(kind: .sessions)
                    Divider()
                    PanelPart(kind: .usage)
                    PanelPart(kind: .top)
                    Divider()
                    PanelPart(kind: .plan)
                }
                .padding(16)
            }
            Divider()
            footer.padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: Self.width + scroller.width, height: model.panelHeight)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scroller.width = ScrollerInset.current()
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Запускать при входе", isOn: $model.launchAtLogin)
                .toggleStyle(.checkbox)
            Spacer()
            if model.diagnosticsCopied {
                Text("отчёт скопирован").font(.caption).foregroundStyle(.green)
            } else if let t = model.snapshot?.fetchedAt {
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
            Button {
                Task { await model.runDiagnostics() }
            } label: {
                Image(systemName: "stethoscope")
            }
            .disabled(model.diagnosing)
            .help("Диагностика: проверить логины и прокси, скопировать отчёт без токенов")
            Button("Выход") { NSApp.terminate(nil) }
        }
    }
}

/// Always-visible scroll bars (a mouse is connected, or the system setting says so) take their width
/// from the content; the panel grows by it so the blocks keep their layout. Overlay scroll bars take none.
final class ScrollerInset: ObservableObject {
    @Published var width = ScrollerInset.current()

    static func current() -> CGFloat {
        let style = NSScroller.preferredScrollerStyle
        return style == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: style) : 0
    }
}

/// One block of the panel; `--snapshot` also renders each on its own for the README.
struct PanelPart: View {
    enum Kind: String, CaseIterable { case limits, sessions, usage, top, plan }
    @EnvironmentObject var model: AppModel
    let kind: Kind

    var body: some View {
        switch kind {
        case .limits:
            LimitRows()
        case .sessions:
            Section("Сессии Claude Code") { LiveSessionsView() } trailing: {
                if !model.live.isEmpty {
                    Text("работают \(model.workingCount) · ждут вас \(model.attentionCount)")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        case .usage:
            HeatmapView()
        case .top:
            Section("Топ сессий") { TopSessionsView() }
        case .plan:
            Section("Какой тариф нужен") { PlanFitView() } trailing: { PlanPicker() }
        }
    }
}

/// Titled block; `trailing` sits on the title line (a picker) to save a row.
private struct Section<Content: View, Trailing: View>: View {
    let title: String
    let content: Content
    let trailing: Trailing
    init(_ title: String, @ViewBuilder content: () -> Content, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.content = content()
        self.trailing = trailing()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Spacer()
                trailing
            }
            content
        }
    }
}

extension Section where Trailing == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, trailing: { EmptyView() })
    }
}

// MARK: - Limits: one row per window

private struct LimitRows: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                row("Сессия · 5 часов", model.snapshot?.fiveHour, length: LimitWindow.fiveHourLength, skipWeekends: false)
                row("Неделя", model.snapshot?.sevenDay, length: LimitWindow.sevenDayLength, skipWeekends: model.skipWeekends)
            }
            Toggle("Недельный темп без выходных", isOn: $model.skipWeekends)
                .toggleStyle(.checkbox).font(.callout).foregroundStyle(.secondary)
                .help("Цвет недельного лимита считается так, будто тратить его можно только в будни")
        }
    }

    private func row(_ title: String, _ window: LimitWindow?, length: TimeInterval, skipWeekends: Bool) -> some View {
        let shown = window?.current(at: model.now)
        let frac = (shown?.utilization ?? 0) / 100
        // Colored by pace: how much is left for the time left, not by the share spent.
        let strain = shown?.strain(at: model.now, length: length, skipWeekends: skipWeekends) ?? 0
        return GridRow(alignment: .center) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Fmt.percent(shown?.utilization))
                .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(window == nil ? Color.secondary : Palette.color(strain))
                .gridColumnAlignment(.trailing)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule().fill(Palette.color(strain)).frame(width: max(6, g.size.width * min(frac, 1)))
                }
            }
            .frame(width: 130, height: 6)
            Text(resetText(window)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func resetText(_ w: LimitWindow?) -> String {
        guard let r = w?.resetsAt else { return "" }
        if r <= model.now { return "сброшен \(Fmt.resetClock(r, now: model.now))" }
        return "сброс через \(Fmt.duration(to: r, now: model.now)), \(Fmt.resetClock(r, now: model.now))"
    }
}

// MARK: - Live sessions

private struct LiveSessionsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let list = model.liveSorted
        let attention = list.filter(model.needsAttention)
        let working = list.filter { !model.needsAttention($0) && $0.isWorking }
        let rest = list.filter { !model.needsAttention($0) && !$0.isWorking }
        if list.isEmpty {
            Text("Сейчас нет запущенных сессий.").font(.caption).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                group("Ждут вас", attention) {
                    Button("Всё прочитано") { model.markAllRead() }
                        .buttonStyle(.link).font(.caption)
                        .focusEffectDisabled()
                        .help("Снять отметку «ждут вас» со всех сессий")
                }
                group("Работают", working) { EmptyView() }
                group("Остальные", rest) { EmptyView() }
                if !model.axTrusted, model.store.isPersistent, list.contains(where: { if case .vscode = $0.host { true } else { false } }) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("Чтобы сессия в открытом перед вами окне VS Code не отмечалась, разрешите доступ в «Универсальном доступе».")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Разрешить") { FocusProbe.requestAccess() }
                            .buttonStyle(.link).focusEffectDisabled()
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func group<T: View>(_ title: String, _ items: [LiveSession], @ViewBuilder trailing: () -> T) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    trailing()
                }
                ForEach(items) { s in
                    Button { model.openSession(s) } label: { row(s) }
                        .buttonStyle(.plain)
                        .focusEffectDisabled()
                        .help("Перейти к сессии — \(Self.hostName(s))")
                    nested(s)
                }
            }
        }
    }

    private func row(_ s: LiveSession) -> some View {
        let (icon, color) = Self.icon(s.state, attention: model.needsAttention(s))
        return HStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 22)
            Text(s.title).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            // The project gets its full width first; a long title is cut instead.
            Text(s.project).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                .layoutPriority(2)
            Spacer(minLength: 8)
            Text(Self.stateText(s)).font(.callout).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            Text(Fmt.ago(s.since, now: model.now)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    /// Subagents and background commands of a session, indented under its row.
    @ViewBuilder
    private func nested(_ s: LiveSession) -> some View {
        if s.agents + s.commands > 0 {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(s.agentNames.enumerated()), id: \.offset) { _, name in
                    nestedRow("person.crop.circle.badge.clock", name, font: .caption)
                }
                ForEach(Array(s.commandLines.enumerated()), id: \.offset) { _, line in
                    nestedRow("terminal", line, font: .system(.caption, design: .monospaced))
                }
            }
            .padding(.leading, 30).padding(.bottom, 4)
        }
    }

    private func nestedRow(_ icon: String, _ text: String, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.caption2).frame(width: 14)
            Text(text).font(font).lineLimit(1).truncationMode(.tail)
        }
        .foregroundStyle(.secondary)
        .help(text)
    }

    /// Orange while the session waits for you and hasn't been looked at; gray once read.
    private static func icon(_ state: LiveSession.State, attention: Bool) -> (String, Color) {
        switch state {
        case .working, .background: return ("play.circle.fill", .green)
        case .permission: return ("hand.raised.circle.fill", .orange)
        case .question(let plan): return (plan ? "list.bullet.circle.fill" : "questionmark.circle.fill", .orange)
        case .idle: return attention ? ("bell.circle.fill", .orange) : ("checkmark.circle", .secondary)
        case .stopped: return ("stop.circle", .secondary)
        }
    }

    static func stateText(_ s: LiveSession) -> String {
        switch s.state {
        case .working(let tool):
            var text = tool.map { "работает: \($0)" } ?? "работает"
            if s.agents > 0 { text += " · агентов \(s.agents)" }
            return text
        case .background: return "в фоне: \(s.agents + s.commands)"
        case .permission(let detail, let sure):
            guard sure else { return "ждёт разрешения?" }
            switch detail {
            case "input needed": return "ждёт данных"
            case "sandbox request": return "просит доступ"
            case "worker request": return "разрешение для агента"
            case "goal proposal": return "предлагает цель"
            default: return "ждёт ответа в диалоге"
            }
        case .question(let plan): return plan ? "план на одобрение" : "задал вопрос"
        case .idle: return "ждёт ввода"
        case .stopped: return "остановлена"
        }
    }

    static func hostName(_ s: LiveSession) -> String {
        if let pid = s.hostPID, let name = NSRunningApplication(processIdentifier: pid)?.localizedName {
            return name == "Code" ? "VS Code" : name
        }
        switch s.host {
        case .vscode: return "VS Code"
        case .terminal: return "терминал"
        case .desktop: return "Claude Desktop"
        case .other: return s.entrypoint ?? "?"
        }
    }
}

// MARK: - Plan fit: recorded windows replayed on Pro / Max 5x / Max 20x, or on the Team seats

private struct PlanPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Picker("", selection: $model.planChoice) {
            Text("Авто" + (model.detectedPlan.map { " (\($0.title))" } ?? "")).tag(Plan?.none)
            ForEach(Plan.allCases.filter { !$0.isTeam }) { Text($0.title).tag(Plan?.some($0)) }
            Divider()
            ForEach(Plan.allCases.filter(\.isTeam)) { Text($0.title).tag(Plan?.some($0)) }
        }
        .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
        .help("Ваш тариф")
    }
}

private struct PlanFitView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.plan == nil {
                Text("Тариф не определился по токену Claude Code — выберите его, чтобы сравнить.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let r = model.planReport {
                Text(verdict(r)).font(.callout.bold()).fixedSize(horizontal: false, vertical: true)
                track(r)
                VStack(spacing: 2) { ForEach(r.fits) { row($0, r) } }
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
                        ForEach(r.current.lineup) { p in
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
                ForEach(r.current.lineup) { p in
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
                    .help(r.current.isTeam
                          ? "Недельные лимиты мест Team не публикуются: взято то же соотношение, что для 5 часов, Premium = 5× Standard"
                          : "Недельное соотношение тарифов не публикуется: для Max 20x взято 10–20× Pro, отсюда диапазон")
            }
            .font(.caption.monospacedDigit())
        }
    }

    private func verdict(_ r: PlanReport) -> String {
        guard let best = r.cheapest else { return "Не хватает даже \(r.fits.last!.plan.title)" }
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
        var text = "Период: \(Fmt.day.string(from: r.from)) – \(Fmt.day.string(from: model.now))"
        if r.capped { text += ". Лимит доходил до 100% — реальная потребность выше" }
        return text
    }

    private func pct(_ v: Double) -> String { v >= 10 ? "\(Int(v.rounded()))%" : String(format: "%.1f%%", v) }
    private func pct(_ r: ClosedRange<Double>) -> String {
        r.upperBound - r.lowerBound < 0.5 ? pct(r.upperBound) : "\(pct(r.lowerBound))–\(pct(r.upperBound))"
    }
}


// MARK: - Heatmap 7 days × 24 hours of Claude Code spend, in weekly-limit percent

private struct HeatmapView: View {
    @EnvironmentObject var model: AppModel

    private let cell: CGFloat = 14
    private let gap: CGFloat = 3
    private let dayWidth: CGFloat = 60

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: model.now)
        let days = (0..<7).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        let rate = model.percentPerDollar
        // Without a weekly reading the scale falls back to dollars.
        let values = model.logHourly(since: days.first!).mapValues { $0 * (rate ?? 1) }
        let maxV = values.values.max() ?? 0
        let unit: (Double) -> String = { rate != nil ? Fmt.share($0) : String(format: "$%.2f", $0) }
        let rows = days.map { day -> (Date, Double) in
            let h0 = Int(day.timeIntervalSince1970 / 3600)
            return (day, (h0..<h0 + 24).reduce(0) { $0 + (values[$1] ?? 0) })
        }

        Section(rate != nil ? "Расход недельного лимита за 7 дней" : "Расход Claude Code за 7 дней") {
            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    Spacer().frame(width: dayWidth)
                    ForEach(0..<24, id: \.self) { h in
                        Text(h % 3 == 0 ? String(format: "%02d", h) : "")
                            .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize()
                            .frame(width: cell, alignment: .leading)
                    }
                }
                ForEach(rows, id: \.0) { day, total in
                    HStack(spacing: gap) {
                        Text(cal.isDate(day, inSameDayAs: today) ? "сегодня" : Fmt.weekday.string(from: day))
                            .font(.system(size: 11, weight: cal.isDate(day, inSameDayAs: today) ? .semibold : .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: dayWidth, alignment: .leading)
                        ForEach(0..<24, id: \.self) { h in
                            let date = cal.date(byAdding: .hour, value: h, to: day)!
                            let v = values[Int(date.timeIntervalSince1970 / 3600)] ?? 0
                            RoundedRectangle(cornerRadius: 3)
                                .fill(fill(v, max: maxV, future: date > model.now))
                                .frame(width: cell, height: cell)
                                .help("\(Fmt.dayTime.string(from: date)) — \(v > 0 ? unit(v) : "нет расхода")")
                        }
                        Text(total > 0 ? unit(total) : "—")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                HStack(spacing: 6) {
                    Spacer().frame(width: dayWidth)
                    Text("мало").font(.caption2).foregroundStyle(.secondary)
                    LinearGradient(colors: [0, 0.5, 1].map { Palette.color($0) }, startPoint: .leading, endPoint: .trailing)
                        .frame(width: 70, height: 6).clipShape(Capsule())
                    Text("много" + (maxV > 0 ? " — до \(unit(maxV)) за час" : "")).font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        } trailing: {
            let total = rows.reduce(0) { $0 + $1.1 }
            if total > 0 { Text("всего \(unit(total))").font(.callout).foregroundStyle(.secondary) }
        }
        .help(rate != nil ? "Доля недельного лимита — оценка по логам Claude Code: расход в $ по ценам API пересчитан по текущему недельному проценту" : "")
    }

    private func fill(_ v: Double, max m: Double, future: Bool) -> Color {
        if future { return Color.secondary.opacity(0.06) }
        guard v > 0, m > 0 else { return Color.secondary.opacity(0.18) }
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
            VStack(spacing: 6) {
                ForEach(top) { t in
                    Button { copyResume(t.session) } label: { row(t, frac: t.cost / maxCost) }
                        .buttonStyle(.plain)
                        .help("Нажмите, чтобы скопировать команду продолжения сессии")
                }
                Text("% — оценка доли недельного лимита по логам Claude Code. Клик копирует команду `claude --resume`.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ t: AppModel.TopSession, frac: Double) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(t.session.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.tail)
                Text(subtitle(t)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(Palette.color(frac)).frame(width: max(6, 120 * frac))
            }
            .frame(width: 120, height: 6)
            Text(t.weeklyPercent.map(Fmt.share) ?? String(format: "$%.2f", t.cost))
                .font(.callout.monospacedDigit().bold())
                .frame(width: 52, alignment: .trailing)
                .help(String(format: "$%.2f по ценам API", t.cost))
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
