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
        // A reply being drafted shows on the Issues tab.
        let running = jobs.filter { $0.status == .running && !$0.isIssueDraft }
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
            if let me, move.isMine(me), !move.ownerWroteIt { return 0 }
            return move.owner == nil || move.ownerWroteIt ? 1 : 2
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
        // Any agent on it, here, on another Mac or a schedule's: no second start while it works.
        let busy = job != nil || pr.isWorking || store.schedule(workingOn: pr) != nil
        let starting = pr.move != nil && job == nil && store.isNext(repo: pr.repo, item: "pr-\(pr.number)")
        let starts = starting || busy ? [] : pr.move.map(startable) ?? []
        // The flow's move starts from its pill, Merge or Fix conflicts from a button beside it:
        // a PR of mine GitHub can merge still offers the review it waits on.
        let pillStart = pr.move.flatMap { starts.contains($0.name) && !RunNowButton.starts($0.name) ? $0.name : nil }
        let buttonStart = starts.first(where: RunNowButton.starts)
        let failed = starts.lazy.compactMap { move in store.failedOnHead(pr, move: move).map { (move: move, job: $0) } }.first
        HoverCard(accent: mine ? moveColor : nil, action: { NSWorkspace.shared.open(pr.url) }) {
            VStack(alignment: .leading, spacing: 8) {
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
                        }
                        Text(pr.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        // One line: a long login truncates, the time never wraps.
                        HStack(spacing: 6) {
                            Avatar(login: pr.author)
                            Text(pr.author).foregroundStyle(Theme.textSecondary).truncationMode(.tail)
                            Text("·").foregroundStyle(Theme.textTertiary)
                            RelativeTime(date: pr.updatedAt).foregroundStyle(Theme.textTertiary).fixedSize()
                        }
                        .font(.meta).lineLimit(1)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 6) {
                        if let move = pr.move {
                            if !move.hasDispatch, !move.ownerWroteIt, let me, move.isMine(me) {
                                HumanMoveButton(pr: pr, move: move, me: me)
                            } else if let pillStart, let me {
                                // The agent's move runs here, in Bton: the pill starts it.
                                StartMoveButton(move: move, me: me, failed: store.failedOnHead(pr, move: pillStart) != nil) {
                                    Task { await store.runNow(pr, move: pillStart) }
                                }
                            } else {
                                MoveChip(move: move, me: me, working: busy)
                            }
                            // A start already asked for still shows while another agent works it.
                            if starting {
                                StartingLabel(repo: pr.repo)
                            } else if let buttonStart {
                                RunNowButton(title: RunNowButton.title(for: buttonStart, failed: store.failedOnHead(pr, move: buttonStart) != nil),
                                             symbol: Theme.symbol(forMove: buttonStart),
                                             color: buttonStart == move.name ? moveColor ?? Theme.neutral : Theme.color(forMove: buttonStart)) {
                                    Task { await store.runNow(pr, move: buttonStart) }
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
                // The card's full width, so the reason never squeezes the title into a sliver.
                if let failed, let detail = failed.job.detail {
                    Button { withAnimation(Motion.spring) { store.watchingJob = failed.job.id } } label: {
                        Label("Last \(failed.move) on this head stopped: \(detail)", systemImage: "exclamationmark.triangle")
                            .font(.meta).foregroundStyle(Theme.danger).lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Theme.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help("Open the job and the agent's report")
                }
            }
        }
        .contextMenu {
            // Only a move this Mac's agent takes can start; the rest are people's.
            if !busy, let move = pr.move, move.hasDispatch, !move.ownerWroteIt, let me, move.isMine(me) {
                Button("Run Next") { Task { await store.runNext(repo: pr.repo, item: "pr-\(pr.number)") } }
            }
            Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        }
    }

    /// The moves a press starts now, if the row offers any: see `DispatchPlanner.offersStart`.
    private func startable(_ move: Move) -> [String] {
        guard let me, let flow = store.flows[pr.repo]?.flow else { return [] }
        let startsMoves = store.repos.first { $0.slug.caseInsensitiveCompare(pr.repo) == .orderedSame }?.startsMoves ?? false
        return RunNowButton.moves(for: pr, current: move, flow: flow, me: me).filter { now in
            let key = JobKey(repo: pr.repo, item: "pr-\(pr.number)", move: now, head: pr.headSha)
            return DispatchPlanner.offersStart(now, current: move.name, startsMoves: startsMoves,
                                               ranOnHead: store.jobs.contains { $0.key == key },
                                               failedOnHead: store.failedOnHead(pr, move: now) != nil)
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

    /// The moves a row can start: Merge on a PR of mine GitHub can merge, at any move, or resolve
    /// on one that conflicts; and the flow's own move when Bton would dispatch it.
    static func moves(for pr: PullRequest, current: Move, flow: Flow, me: String) -> [String] {
        var moves: [String] = []
        if DispatchPlanner.mergeCandidate(pr, flow: flow, me: me, repo: pr.repo) != nil {
            moves.append("merge")
        } else if DispatchPlanner.resolveCandidate(pr, flow: flow, me: me, repo: pr.repo) != nil {
            moves.append("resolve")
        }
        if FlowEngine.isDispatchable(current, pr: pr, flow: flow, me: me), !moves.contains(current.name) { moves.append(current.name) }
        return moves
    }

    /// Merge and resolve get a button of their own; the PR's flow move starts from its pill.
    static func starts(_ move: String) -> Bool { move == "merge" || move == "resolve" }

    static func title(for move: String, failed: Bool) -> String {
        move == "merge" ? (failed ? "Retry merge" : "Merge") : (failed ? "Retry fix conflicts" : "Fix conflicts")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10.5, weight: .semibold))
            }
            // The title column takes layout priority, so an unfixed label wraps "Retry merge" in two.
            .lineLimit(1)
            .fixedSize()
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

    /// What the tab's badge counts: merged in the last 24 hours, not since midnight.
    static func recent(_ items: [MergedPullRequest]) -> Int {
        items.filter { $0.mergedAt > Date.now.addingTimeInterval(-86_400) }.count
    }

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "arrow.triangle.merge", title: "Nothing merged yet", detail: "Merged PRs show with what their agents cost.")
        } else {
            RowStack(items: items.sorted { $0.number > $1.number }, row: row) {
                Eyebrow(text: "\(Self.recent(items)) in the last 24 hours")
            }
        }
    }

    private func row(_ pr: MergedPullRequest) -> some View {
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
                        RelativeTime(date: pr.mergedAt)
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
    /// In place of the move's own glyph: what pressing it does.
    var symbol: String?
    /// An agent works the move now: a filled pill read as one to press again.
    var working = false

    var body: some View {
        let color = Theme.color(forMove: move.name)
        if move.ownerWroteIt, let owner = move.owner {
            Chip(text: "\(move.name) · needs another reviewer", symbol: Theme.symbol(forMove: move.name),
                 color: Theme.unassigned, style: .dashed)
                .help("\(owner) wrote this PR, and a \(move.tier) PR counts no review from its author: assign someone else to review it")
        } else if let owner = move.owner {
            let mine = me.map(move.isMine) ?? false
            Chip(text: mine ? "\(move.name) · you" : "\(move.name) · \(owner)", symbol: symbol ?? Theme.symbol(forMove: move.name),
                 color: mine ? color : color.opacity(0.85), style: mine && !working ? .filled : .tinted)
        } else {
            Chip(text: "\(move.name) · unassigned", symbol: Theme.symbol(forMove: move.name), color: Theme.unassigned, style: .dashed)
        }
    }
}

/// A move of mine that this Mac's agent does: the pill starts it now, again if it failed on this head.
private struct StartMoveButton: View {
    let move: Move
    let me: String
    let failed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            MoveChip(move: move, me: me, symbol: failed ? "arrow.clockwise" : "play.fill")
                .brightness(hovering ? 0.08 : 0)
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(failed ? "Run \(move.name) again on this head" : "Start the \(move.name) agent now")
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
        // A light pane would show through a see-through disc and wash the initial out.
        let light = Theme.scheme == .light
        Text(login.prefix(1).uppercased())
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(Color(hue: hue, saturation: light ? 0.75 : 0.55, brightness: light ? 0.45 : 1))
            .frame(width: 15, height: 15)
            .background(light ? Color(hue: hue, saturation: 0.2, brightness: 0.96)
                              : Color(hue: hue, saturation: 0.6, brightness: 0.45).opacity(0.55), in: Circle())
    }
}
