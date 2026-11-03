import BtonCore
import SwiftUI

/// Settings > Costs: what the agents this Mac started have cost, by day, by project, hat, move,
/// agent or model, and by month from the ledgers that outlive the job records. This Mac only:
/// Bton reads the session logs of the jobs it ran, nothing else.
struct CostsPane: View {
    @Environment(AppStore.self) private var store
    @State private var report: CostReport?
    @State private var unreadable: [String] = []
    @State private var selectedDay: Date?
    @State private var hoveredDay: Date?
    @State private var range = Range.month
    @State private var group = CostGroup.project
    @State private var problem: String?

    private static let retentions = [30, 60, 90, 180]
    private static let barDays = 30

    enum Range: String, CaseIterable {
        case today = "Today", week = "7 days", month = "30 days", thisMonth = "This month"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .costs, title: "Costs",
                       detail: "What the agents this Mac started have cost, read from their session logs. Your own sessions and teammates' Macs are not counted.")
            if let report {
                daysCard(report)
                groupsCard(report)
                monthsCard(report)
            }
            retentionCard
            if let problem { ProblemText(text: problem) }
        }
        .onAppear(perform: reload)
        .onChange(of: store.jobs) { reload() }
        .animation(Motion.spring, value: selectedDay)
        .animation(Motion.spring, value: problem)
    }

    /// The ledgers are a few small files; the records are already in the store.
    private func reload() {
        let loaded = CostLedger.load(home: store.home)
        unreadable = loaded.unreadable
        report = CostReport(ledgers: loaded.ledgers, jobs: store.jobs, prices: store.prices)
    }

    // MARK: days

    private func daysCard(_ report: CostReport) -> some View {
        let days = report.days(last: Self.barDays)
        let peak = days.map(\.cost).max() ?? 0
        let shown = hoveredDay ?? selectedDay
        let total = days.reduce(Decimal(0)) { $0 + $1.cost }
        return Bezel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Last 30 days").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(caption(for: shown, in: days) ?? "\(total.usd()) · \(days.reduce(0) { $0 + $1.jobs }) jobs")
                            .font(.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                    Spacer()
                    if selectedDay != nil {
                        PillButton(title: "All days", symbol: "xmark", prominent: false) { selectedDay = nil }
                    }
                }
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(days, id: \.date) { day in bar(day, peak: peak) }
                }
                .frame(height: 72)
                if let selectedDay {
                    Rectangle().fill(Theme.hairline).frame(height: 0.5)
                    dayJobs(report.jobs(on: selectedDay), report: report)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func caption(for date: Date?, in days: [CostReport.Day]) -> String? {
        guard let date, let day = days.first(where: { $0.date == date }) else { return nil }
        let when = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        let unpriced = day.unpriced > 0 ? " · \(day.unpriced) unpriced" : ""
        return "\(when): \(day.cost.usd()) · \(day.jobs) jobs\(unpriced)"
    }

    private func bar(_ day: CostReport.Day, peak: Decimal) -> some View {
        let share = peak > 0 ? CGFloat(truncating: (day.cost / peak) as NSDecimalNumber) : 0
        let today = Calendar.current.isDateInToday(day.date)
        let lit = selectedDay == day.date || hoveredDay == day.date
        return Button {
            selectedDay = selectedDay == day.date ? nil : day.date
        } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(lit ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(today ? Theme.mint : SettingsPane.costs.color.opacity(day.jobs > 0 ? 0.55 : 0.18)))
                    .frame(height: max(3, 64 * share))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .onHover { inside in withAnimation(Motion.snappy) { hoveredDay = inside ? day.date : (hoveredDay == day.date ? nil : hoveredDay) } }
        .help(caption(for: day.date, in: [day]) ?? "")
    }

    private func dayJobs(_ jobs: [Job], report: CostReport) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if jobs.isEmpty {
                Text("No job records kept for this day; its total comes from the month ledger.")
                    .font(.meta).foregroundStyle(Theme.textTertiary).padding(.vertical, 6)
            }
            ForEach(jobs) { job in jobLine(job, report: report) }
        }
    }

    private func jobLine(_ job: Job, report: CostReport) -> some View {
        Button {
            withAnimation(Motion.spring) { store.watchingJob = job.id }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                GlyphDisc(symbol: Theme.symbol(forMove: job.key.move), color: Theme.color(forMove: job.key.move), size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(job.key.move).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("\(job.key.repo.split(separator: "/").last.map(String.init) ?? job.key.repo) · \(job.key.item) · \(job.agent ?? CostLedger.commandAgent)")
                            .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    if let sources = sourceLine(job, report: report) {
                        Text(sources).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    }
                }
                Spacer()
                if let cost = job.cost {
                    Cost(value: cost)
                } else if !job.usage.isEmpty {
                    Text("no price").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.unassigned)
                }
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.995))
    }

    /// "agent $1.20 · helpers $0.40 · codex $0.80" for the buckets the record has.
    private func sourceLine(_ job: Job, report: CostReport) -> String? {
        let costs = job.sourceCosts(prices: report.prices)
        guard !costs.isEmpty else { return nil }
        return ["agent", "second", "helpers", "codex"].compactMap { bucket -> String? in
            guard let priced = costs[bucket] else { return nil }
            return "\(bucket) \(priced.map { $0.usd() } ?? "no price")"
        }.joined(separator: " · ")
    }

    // MARK: groups

    private func groupsCard(_ report: CostReport) -> some View {
        let (from, to) = window(now: report.now, calendar: report.calendar)
        let rows = report.rows(by: group, from: from, to: to)
        let total = rows.reduce(Decimal(0)) { $0 + $1.cost }
        return SettingsCard(title: "By", detail: "Where the money went in the range, dearest first.") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(Range.allCases, id: \.self) { choice in
                        SegmentChip(title: choice.rawValue, selected: range == choice) { withAnimation(Motion.spring) { range = choice } }
                    }
                    Spacer()
                    Text(total.usd()).font(.statSmall).foregroundStyle(Theme.textPrimary).monospacedDigit()
                }
                HStack(spacing: 6) {
                    ForEach(CostGroup.allCases, id: \.self) { choice in
                        SegmentChip(title: choice.rawValue.capitalized, selected: group == choice) { withAnimation(Motion.spring) { group = choice } }
                    }
                }
                if rows.isEmpty {
                    Text("Nothing ran in this range.").font(.meta).foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(rows, id: \.name) { row in groupLine(row, total: total) }
                    }
                }
            }
        }
    }

    private func groupLine(_ row: CostReport.GroupRow, total: Decimal) -> some View {
        let share = total > 0 ? CGFloat(truncating: (row.cost / total) as NSDecimalNumber) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if group == .model { VendorLogo(model: row.name, size: 13) }
                Text(row.name).font(.system(size: 12, weight: .medium, design: group == .model ? .monospaced : .default))
                    .foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                if row.unpriced > 0 {
                    Text("\(row.unpriced) unpriced").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.unassigned)
                }
                Text("\(row.jobs) jobs").font(.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
                Cost(value: row.cost).frame(width: 70, alignment: .trailing)
            }
            GeometryReader { proxy in
                Capsule().fill(Theme.wash.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.brand).frame(width: max(2, proxy.size.width * share))
                    }
            }
            .frame(height: 4)
        }
        .padding(.vertical, 6)
    }

    private func window(now: Date, calendar: Calendar) -> (Date, Date) {
        let today = calendar.startOfDay(for: now)
        let to = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch range {
        case .today: return (today, to)
        case .week: return (calendar.date(byAdding: .day, value: -6, to: today) ?? today, to)
        case .month: return (calendar.date(byAdding: .day, value: -29, to: today) ?? today, to)
        case .thisMonth: return (calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today, to)
        }
    }

    // MARK: months

    private func monthsCard(_ report: CostReport) -> some View {
        let months = report.months()
        return SettingsCard(title: "Months", detail: "Each month's total and its projects, from the ledgers in ~/.bton/costs and the records still kept.") {
            VStack(alignment: .leading, spacing: 0) {
                if months.isEmpty {
                    Text("none yet").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                ForEach(months, id: \.month) { month in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(monthName(month.month)).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            if month.unpriced > 0 {
                                Text("\(month.unpriced) unpriced").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.unassigned)
                            }
                            Cost(value: month.total)
                        }
                        Text(month.projects.map { "\($0.name.split(separator: "/").last.map(String.init) ?? $0.name) \($0.cost.usd())" }
                            .joined(separator: " · "))
                            .font(.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
                    }
                    .padding(.vertical, 7)
                    if month.month != months.last?.month { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                }
                if !unreadable.isEmpty {
                    ProblemText(text: "Could not read \(unreadable.joined(separator: ", ")) in ~/.bton/costs; those months are left out and their records are kept until the file reads.")
                        .padding(.top, 8)
                }
            }
        }
    }

    private func monthName(_ month: String) -> String {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2, let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1])) else { return month }
        return date.formatted(.dateTime.month(.wide).year())
    }

    // MARK: retention

    private var retentionCard: some View {
        let current = store.costSettings?.retentionDays ?? CostSettings.defaultRetentionDays
        return SettingsCard(title: "Job records",
                            detail: "How long a finished job's record stays. Older records are folded into month ledgers in ~/.bton/costs, which stay. Logs go after 30 days either way. A PR's total in its row covers the records still kept.") {
            HStack(spacing: 6) {
                ForEach(Self.retentions, id: \.self) { days in
                    SegmentChip(title: "\(days) days", selected: current == days) {
                        do {
                            try withAnimation(Motion.spring) { try store.setCosts { $0.retentionDays = days == CostSettings.defaultRetentionDays ? nil : days } }
                            problem = nil
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
}

/// The cost settings in `config.json`.
extension AppStore {
    func setCosts(_ change: (inout CostSettings) -> Void) throws {
        try update { config in
            var settings = config.costs ?? CostSettings()
            change(&settings)
            config.costs = settings
        }
    }
}
