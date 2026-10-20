import AppKit
import BtonCore
import SwiftUI

/// Open PRs, mine first: a move I own, then unassigned ones, then everyone else's.
struct PullRequestList: View {
    @Environment(AppStore.self) private var store
    let items: [PullRequest]
    let showRepo: Bool
    let me: String?
    let jobs: [Job]
    let schedules: [ScheduleEntry]

    var body: some View {
        let running = jobs.filter { $0.status == .running }
        if items.isEmpty && running.isEmpty && store.lastRefresh == nil {
            EmptyState(symbol: "arrow.triangle.2.circlepath", title: "Reading GitHub", detail: "Open pull requests show here in a moment.")
        } else if items.isEmpty && running.isEmpty {
            EmptyState(symbol: "checkmark.seal", title: "No open pull requests", detail: "New ones show here within a sync.")
        } else {
            RowStack(items: ordered) { pr in
                PullRequestRow(pr: pr, showRepo: showRepo, me: me,
                               job: running.first { $0.key.repo == pr.repo && $0.key.item == "pr-\(pr.number)" })
            } header: {
                if !running.isEmpty { ActiveStrip(jobs: running, schedules: schedules).padding(.bottom, 8) }
            }
        }
    }

    private var ordered: [PullRequest] {
        let rank = { (pr: PullRequest) -> Int in
            guard let move = pr.move else { return 3 }
            if let me, move.isMine(me) { return 0 }
            return move.owner == nil ? 1 : 2
        }
        return items.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }
}

private struct PullRequestRow: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let showRepo: Bool
    let me: String?
    /// This Mac's agent working the PR now.
    let job: Job?

    var body: some View {
        let moveColor = pr.move.map { Theme.color(forMove: $0.name) }
        let mine = pr.move.flatMap { move in me.map(move.isMine) } ?? false
        HoverCard(accent: mine ? moveColor : nil, action: { NSWorkspace.shared.open(pr.url) }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("#\(pr.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        if showRepo { RepoName(repo: pr.repo) }
                        if let tier = pr.move?.tier, !tier.isEmpty {
                            Chip(text: tier, color: Theme.color(forTier: tier), style: .outline)
                        }
                        if pr.isDraft { Chip(text: "draft", color: Theme.neutral, style: .outline) }
                        if pr.conflicting { Chip(text: "conflicts", color: Theme.danger, style: .outline) }
                        if store.isNext(repo: pr.repo, item: "pr-\(pr.number)") {
                            Chip(text: "next", color: Theme.color(forMove: "schedule"))
                        }
                    }
                    Text(pr.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Avatar(login: pr.author)
                        Text(pr.author).foregroundStyle(Theme.textSecondary)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        Text(pr.updatedAt, style: .relative).foregroundStyle(Theme.textTertiary)
                    }
                    .font(.meta)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 6) {
                    if let move = pr.move {
                        if !move.hasDispatch, let me, move.isMine(me) { HumanMoveButton(pr: pr, move: move, me: me) } else { MoveChip(move: move, me: me) }
                        if job == nil, let me, let flow = store.flows[pr.repo]?.flow,
                           FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: me), let title = RunNowButton.title(for: move) {
                            RunNowButton(title: title, symbol: Theme.symbol(forMove: move.name), color: moveColor ?? Theme.neutral) {
                                Task { await store.runNow(pr) }
                            }
                        }
                    }
                    if let job {
                        ModelBadges(job: job, compact: true)
                    } else if pr.isWorking || store.schedule(workingOn: pr) != nil {
                        HStack(spacing: 5) {
                            PulseDot(color: Theme.color(for: .running))
                            Text("agent working").font(.system(size: 10, weight: .medium))
                                .foregroundStyle(Theme.color(for: .running))
                        }
                    }
                    if let cost = pr.cost { Cost(value: cost) }
                }
            }
        }
        .contextMenu {
            // Only a move this Mac's agent takes can start; the rest are people's.
            if job == nil, let move = pr.move, move.hasDispatch, let me, move.isMine(me) {
                Button("Run Next") { Task { await store.runNext(repo: pr.repo, item: "pr-\(pr.number)") } }
            }
            Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        }
    }
}

/// Starts a move of mine at once, again if it failed on this head.
private struct RunNowButton: View {
    let title: String
    let symbol: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    /// Only moves a person would otherwise go to GitHub for get a button; the rest run on their own.
    static func title(for move: Move) -> String? {
        switch move.name {
        case "merge": "Merge"
        case "resolve": "Fix conflicts"
        default: nil
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(hovering ? 0.22 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help("\(title) now, again if it failed on this head")
    }
}

struct MergedList: View {
    let items: [MergedPullRequest]
    let showRepo: Bool

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "arrow.triangle.merge", title: "Nothing merged yet", detail: "Merged PRs show with what their agents cost.")
        } else {
            RowStack(items: items) { pr in
                HoverCard(accent: nil, action: { NSWorkspace.shared.open(pr.url) }) {
                    HStack(spacing: 10) {
                        GlyphDisc(symbol: "arrow.triangle.merge", color: Theme.success, size: 26)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pr.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            HStack(spacing: 6) {
                                Text("#\(pr.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                if showRepo { RepoName(repo: pr.repo) }
                                Text(pr.author)
                                Text("·")
                                Text(pr.mergedAt, style: .relative)
                            }
                            .font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 4)
                        if let cost = pr.totalCost {
                            VStack(alignment: .trailing, spacing: 1) {
                                Eyebrow(text: "total")
                                Cost(value: cost)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: shared row parts

extension RowStack where Header == EmptyView {
    init(items: [Item], @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, row: row, header: { EmptyView() })
    }
}

/// The scrolling column every tab uses, rows rising in on first show. A page at a time, so a
/// long history (jobs, merged PRs) never builds hundreds of rows nobody scrolls to.
struct RowStack<Item: Identifiable, Row: View, Header: View>: View {
    static var page: Int { 25 }
    let items: [Item]
    let row: (Item) -> Row
    let header: () -> Header
    @Environment(\.stillImage) private var stillImage
    @State private var shown = Self.page

    init(items: [Item], @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder header: @escaping () -> Header) {
        self.items = items
        self.row = row
        self.header = header
    }

    var body: some View {
        if stillImage {
            VStack(spacing: 6) { rows }.padding(.horizontal, 14)
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView {
                LazyVStack(spacing: 6) { rows }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder private var rows: some View {
        header()
        ForEach(Array(items.prefix(shown).enumerated()), id: \.element.id) { index, item in
            row(item).riseIn(index)
        }
        if items.count > shown {
            PillButton(title: "Show \(min(Self.page, items.count - shown)) more of \(items.count - shown)",
                       symbol: "chevron.down", prominent: false) {
                withAnimation(Motion.spring) { shown += Self.page }
            }
            .padding(.top, 4)
        }
    }
}

/// The move in its own colour; filled when it is mine, dashed orange when nobody has it.
struct MoveChip: View {
    let move: Move
    let me: String?

    var body: some View {
        let color = Theme.color(forMove: move.name)
        if let owner = move.owner {
            let mine = me.map(move.isMine) ?? false
            Chip(text: mine ? "\(move.name) · you" : "\(move.name) · \(owner)", symbol: Theme.symbol(forMove: move.name),
                 color: mine ? color : color.opacity(0.85), style: mine ? .filled : .tinted)
        } else {
            Chip(text: "\(move.name) · unassigned", symbol: Theme.symbol(forMove: move.name), color: Theme.unassigned, style: .dashed)
        }
    }
}

/// A move that is mine to do by hand: what clears it, and a way to say it is done.
private struct HumanMoveButton: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let move: Move
    let me: String
    @State private var open = false
    @State private var clearing: String?
    @State private var problem: String?

    var body: some View {
        Button { open = true } label: { MoveChip(move: move, me: me) }
            .buttonStyle(PressStyle())
            .pointingHandCursor()
            .help("What \(move.name) needs")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(move.name) · #\(pr.number)").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(move.labels.isEmpty
                         ? "Yours to do on GitHub. Bton sees it at the next sync."
                         : "Yours to do on GitHub. When it is done, remove \(move.labels.joined(separator: ", ")) and the flow moves on.")
                        .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        PillButton(title: "Open on GitHub", prominent: false) { NSWorkspace.shared.open(pr.url) }
                        ForEach(move.labels, id: \.self) { label in
                            PillButton(title: clearing == label ? "Removing..." : "Done · remove \(label)", symbol: "checkmark",
                                       disabled: clearing != nil) { remove(label) }
                        }
                    }
                    if let problem { ProblemText(text: problem) }
                }
                .padding(14)
                .frame(width: 340, alignment: .leading)
            }
    }

    private func remove(_ label: String) {
        clearing = label
        problem = nil
        Task {
            do {
                try await store.removeLabel(label, from: pr, move: move)
                open = false
            } catch {
                problem = error.localizedDescription
            }
            clearing = nil
        }
    }
}

/// The repo's name without its owner: the owner is the same for most teams and costs width.
struct RepoName: View {
    let repo: String

    var body: some View {
        Text(repo.split(separator: "/").last.map(String.init) ?? repo)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
    }
}

extension Decimal {
    /// Dollars the short way everywhere, whatever the Mac's region: $0.25, $12.40, $1.2K.
    func usd(cents: Bool = true) -> String {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
        if self >= 1_000 {
            let thousands = (self / 1_000).formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "en_US")))
            return "$\(thousands)K"
        }
        return formatted(cents ? style : style.precision(.fractionLength(0)))
    }
}

struct Cost: View {
    let value: Decimal

    var body: some View {
        Text(value.usd())
            .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
    }
}

/// A login's initial on a hue of its own, so the same person reads the same everywhere.
struct Avatar: View {
    let login: String

    var body: some View {
        let hue = Double(login.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }) / 360
        Text(login.prefix(1).uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Color(hue: hue, saturation: 0.55, brightness: 1))
            .frame(width: 15, height: 15)
            .background(Color(hue: hue, saturation: 0.6, brightness: 0.45).opacity(0.55), in: Circle())
    }
}
