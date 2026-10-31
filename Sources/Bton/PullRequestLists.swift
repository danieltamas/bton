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
            // Every job on a PR of the list is that PR's row, working: the PR's own move and any
            // schedule on it at the moment (the registry job merging the PR it opened). Only a
            // job with no row, a schedule between PRs, gets a card of its own above the list.
            let rowJobs = { (pr: PullRequest) -> [Job] in
                running.filter { $0.key.repo == pr.repo && $0.key.item == "pr-\(pr.number)" } + store.schedules(workingOn: pr)
            }
            let loose = running.filter { job in !items.contains { rowJobs($0).contains { $0.id == job.id } } }
            RowStack(items: ordered) { pr in
                PullRequestRow(pr: pr, showRepo: showRepo, me: me, jobs: rowJobs(pr))
            } header: {
                if !loose.isEmpty { ActiveStrip(jobs: loose, schedules: schedules).padding(.bottom, 8) }
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
    /// This Mac's agents working the PR now, the PR's own move first: the row opens the first
    /// one's session, each working line its own.
    let jobs: [Job]
    private var job: Job? { jobs.first }

    var body: some View {
        let moveColor = pr.move.map { Theme.color(forMove: $0.name) }
        let mine = pr.move.flatMap { move in me.map(move.isMine) } ?? false
        // Any agent on it, here, on another Mac or a schedule's: no second start while it works.
        let busy = job != nil || pr.isWorking || store.schedule(workingOn: pr) != nil
        let starting = pr.move != nil && job == nil && store.isNext(repo: pr.repo, item: "pr-\(pr.number)")
        let starts = starting || busy ? [] : pr.move.map(startable) ?? []
        // One pill, one action: the PR's move is its pill, which is the button when it is mine to
        // start (Merge included); Fix conflicts is the one action beside it, since a conflict holds
        // every move.
        let pillStart = pr.move.flatMap { starts.contains($0.name) && !RunNowButton.starts($0.name) ? $0.name : nil }
        let buttonStart = starts.first(where: RunNowButton.starts)
        let failed = starts.lazy.compactMap { move in store.failedOnHead(pr, move: move).map { (move: move, job: $0) } }.first
        // The move ran here on this head and is still the PR's move: the agent changed nothing.
        let unchanged = failed == nil && !busy ? pr.move.flatMap { store.succeededOnHead(pr, move: $0.name) } : nil
        // One click per row: the session while an agent works it here (the working line says so),
        // the PR on GitHub otherwise.
        HoverCard(accent: mine ? moveColor : nil, glow: job.map { _ in Theme.color(for: .running) }, action: {
            if let job { withAnimation(Motion.spring) { store.watchingJob = job.id } } else { NSWorkspace.shared.open(pr.url) }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("#\(pr.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                            if showRepo { RepoName(repo: pr.repo) }
                            if let tier = pr.move?.tier, !tier.isEmpty {
                                Chip(text: tier, color: Theme.color(forTier: tier), style: .outline)
                                    .help(pr.move?.tierReason.map { "\(tier): \($0)" } ?? tier)
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
                                AsyncPress(id: "run:\(pr.repo)#\(pr.number):\(pillStart)", action: { await store.runNow(pr, move: pillStart) }) { running, press in
                                    StartMoveButton(move: move, me: me, failed: store.failedOnHead(pr, move: pillStart) != nil,
                                                    again: unchanged != nil, action: press)
                                        .disabled(running)
                                        .opacity(running ? 0.6 : 1)
                                }
                            } else {
                                MoveChip(move: move, me: me, working: busy)
                            }
                            // A start already asked for still shows while another agent works it.
                            if starting {
                                StartingLabel(repo: pr.repo, reason: store.waitingReason(repo: pr.repo, item: "pr-\(pr.number)"))
                            } else if let buttonStart {
                                AsyncRunNowButton(title: RunNowButton.title(for: buttonStart, failed: store.failedOnHead(pr, move: buttonStart) != nil),
                                                  runningTitle: "Starting...", symbol: Theme.symbol(forMove: buttonStart),
                                                  color: buttonStart == move.name ? moveColor ?? Theme.neutral : Theme.color(forMove: buttonStart),
                                                  id: "run:\(pr.repo)#\(pr.number):\(buttonStart)") { await store.runNow(pr, move: buttonStart) }
                            } else if !busy, let me, let flow = store.flows[pr.repo]?.flow,
                                      FlowEngine.takeover(of: pr, flow: flow, me: me) != nil {
                                TakeButton(pr: pr, move: move)
                            }
                        }
                        if let job {
                            ModelBadges(job: job, compact: true)
                        } else if pr.isWorking {
                            HStack(spacing: 5) {
                                PulseDot(color: Theme.color(for: .running))
                                Text("working on another Mac").font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.color(for: .running))
                            }
                            .help("A teammate's Bton runs the move; its session is on their Mac")
                        }
                        if let cost = pr.cost { Cost(value: cost) }
                    }
                    // Its own width, like an issue row's action: a two-line title wraps around it
                    // instead of squeezing the cost into one character per line.
                    .fixedSize()
                    .layoutPriority(2)
                }
                ForEach(jobs) { job in
                    WorkingLine(job: job) { withAnimation(Motion.spring) { store.watchingJob = job.id } }
                }
                // The card's full width, so the reason never squeezes the title into a sliver.
                if let failed, let detail = failed.job.detail {
                    ReportLine(text: "Last \(failed.move) on this head stopped: \(detail)", symbol: "exclamationmark.triangle",
                               color: Theme.danger) { withAnimation(Motion.spring) { store.watchingJob = failed.job.id } }
                }
                if let unchanged {
                    ReportLine(text: "Last \(unchanged.key.move) on this head ran and changed nothing: read why", symbol: "info.circle",
                               color: Theme.textSecondary, fill: Theme.canvasLift, help: "Open the agent's report") {
                        withAnimation(Motion.spring) { store.watchingJob = unchanged.id }
                    }
                }
                if let problem = store.takeProblems[pr.id] {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.meta).foregroundStyle(Theme.danger)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .contextMenu {
            // Only a move this Mac's agent takes can start; the rest are people's.
            if !busy, let move = pr.move, move.hasDispatch, !move.ownerWroteIt, let me, move.isMine(me) {
                AsyncPress(id: "next:\(pr.repo)#pr-\(pr.number)", action: { await store.runNext(repo: pr.repo, item: "pr-\(pr.number)") }) { running, press in
                    Button("Run Next", action: press).disabled(running)
                }
            }
            Button("Open on GitHub") { NSWorkspace.shared.open(pr.url) }
        }
    }

    /// The moves a press starts now, if the row offers any: see `DispatchPlanner.offersStart`.
    private func startable(_ move: Move) -> [String] {
        guard let me, let flow = store.flows[pr.repo]?.flow else { return [] }
        let startsMoves = store.repos.first { $0.slug.caseInsensitiveCompare(pr.repo) == .orderedSame }?.startsMoves ?? false
        return RunNowButton.moves(for: pr, current: move, flow: flow, me: me).filter { now in
            let key = store.key(for: pr, move: now)
            return DispatchPlanner.offersStart(now, current: move.name, startsMoves: startsMoves,
                                               ranOnHead: store.jobs.contains { $0.key == key },
                                               failedOnHead: store.failedOnHead(pr, move: now) != nil,
                                               succeededOnHead: store.succeededOnHead(pr, move: now) != nil)
        }
    }
}

/// Starts a move of mine at once, again if it failed on this head.
/// Under a PR an agent works here: what it does, for how long, and a click that watches it. A
/// second line is a second job on the same PR, a schedule's, with its own session.
private struct WorkingLine: View {
    let job: Job
    let action: () -> Void

    var body: some View {
        let color = Theme.color(for: .running)
        let who = (job.agent ?? "The agent").capitalized
        let doing = switch job.key.move {
        case "review": "\(who) is reviewing it"
        case "fix": "\(who) is fixing it"
        case "merge": "\(who) is merging it"
        case "resolve": "\(who) is resolving its conflicts"
        case "schedule": "\(who)'s scheduled run is on it"
        default: "\(who) is working on it"
        }
        Button(action: action) {
            HStack(spacing: 6) {
                PulseDot(color: color)
                Text("\(doing) · watch").font(.meta).foregroundStyle(color).lineLimit(1)
                Spacer(minLength: 4)
                Text(job.startedAt, style: .timer).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .help("Watch this job's session")
    }
}

struct RunNowButton: View {
    let title: String
    let symbol: String
    let color: Color
    var help: String?
    /// A press in progress: the button stays, dimmed and unpressable.
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    /// The moves a row can start: Merge when it is the PR's move and GitHub can merge the PR of
    /// mine, resolve on one that conflicts, and the flow's own move when Bton would dispatch it.
    /// A PR whose move is review or fix is not offered Merge: GitHub's mergeable says nothing
    /// about the review it waits on.
    static func moves(for pr: PullRequest, current: Move, flow: Flow, me: String) -> [String] {
        var moves: [String] = []
        if current.name == "merge", DispatchPlanner.mergeCandidate(pr, flow: flow, me: me, repo: pr.repo) != nil {
            moves.append("merge")
        } else if DispatchPlanner.resolveCandidate(pr, flow: flow, me: me, repo: pr.repo) != nil {
            moves.append("resolve")
        }
        if FlowEngine.isDispatchable(current, pr: pr, flow: flow, me: me), !moves.contains(current.name) { moves.append(current.name) }
        return moves
    }

    /// Fix conflicts is the one action beside the pill; every flow move, Merge included, starts from its pill.
    static func starts(_ move: String) -> Bool { move == "resolve" }

    static func title(for move: String, failed: Bool) -> String {
        failed ? "Retry fix conflicts" : "Fix conflicts"
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
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help ?? "\(title) now, again if it failed on this head")
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
    init(items: [Item], more: RowStackMore? = nil, footer: AnyView? = nil,
         @ViewBuilder row: @escaping (Item) -> Row) {
        self.init(items: items, more: more, footer: footer, row: row, header: { EmptyView() })
    }
}

/// The scrolling column every tab uses, rows rising in on first show. A page at a time, so a
/// The pill under a list whose remote has more rows: its title, whether the owner of the list is
/// fetching now (state the store keeps, so the pill shows it from the press to the rows), and
/// what a press does.
struct RowStackMore {
    /// The press id, stable per list (`more:<slug>`): see AsyncPress.
    let id: String
    let title: String
    var loading = false
    let action: () async -> Void
}

/// long history (jobs, merged PRs) never builds hundreds of rows nobody scrolls to.
struct RowStack<Item: Identifiable, Row: View, Header: View>: View {
    static var page: Int { 25 }
    let items: [Item]
    let row: (Item) -> Row
    let header: () -> Header
    /// Once every local item is shown: a pill with this title that fetches more (Load more from
    /// GitHub). Nil when the list is complete.
    var more: RowStackMore?
    /// Under the rows and their pills: the search hits GitHub added.
    var footer: AnyView?
    @Environment(\.stillImage) private var stillImage
    @State private var shown = Self.page

    init(items: [Item], more: RowStackMore? = nil, footer: AnyView? = nil,
         @ViewBuilder row: @escaping (Item) -> Row, @ViewBuilder header: @escaping () -> Header) {
        self.items = items
        self.more = more
        self.footer = footer
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
        } else if let more {
            // Dimmed and renamed from the press until the rows are in: a second press does nothing.
            AsyncPillButton(title: more.loading ? "Loading from GitHub..." : more.title, runningTitle: "Loading from GitHub...",
                            symbol: "arrow.down.circle", prominent: false, disabled: more.loading, id: more.id) {
                await more.action()
                // The fetched rows show at once, wherever the sort puts them.
                withAnimation(Motion.spring) { shown = max(shown, items.count) + Self.page * 2 }
            }
            .padding(.top, 4)
        }
        if let footer { footer }
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
    /// In place of "move · who": the pill is the action, and what it does is its whole text.
    var title: String?

    var body: some View {
        let color = Theme.color(forMove: move.name)
        if move.ownerWroteIt, let owner = move.owner {
            Chip(text: "\(move.name) · needs another reviewer", symbol: Theme.symbol(forMove: move.name),
                 color: Theme.unassigned, style: .dashed)
                .help("\(owner) wrote this PR, and a \(move.tier) PR counts no review from its author: hand the review to someone else on GitHub")
        } else if let title {
            Chip(text: title, symbol: symbol ?? Theme.symbol(forMove: move.name), color: color, style: .filled)
        } else if let owner = move.owner {
            let mine = me.map(move.isMine) ?? false
            let held = move.redChecks.isEmpty ? "" : " · \(move.redChecks.joined(separator: ", ")) red"
            Chip(text: "\(move.name)\(held) · \(mine ? "you" : owner)", symbol: symbol ?? Theme.symbol(forMove: move.name),
                 color: mine ? color : color.opacity(0.85), style: mine && !working ? .filled : .tinted)
        } else {
            Chip(text: "\(move.name) · unassigned", symbol: Theme.symbol(forMove: move.name), color: Theme.unassigned, style: .dashed)
        }
    }
}

/// A move of mine that this Mac's agent does: the pill starts it now, again if it failed on this
/// head or ran and changed nothing. Its text is the action ("Merge", "Retry fix"), not "merge · you":
/// the one who must press it is the one reading it.
private struct StartMoveButton: View {
    let move: Move
    let me: String
    let failed: Bool
    var again = false
    let action: () -> Void
    @State private var hovering = false

    static func title(_ move: String, failed: Bool, again: Bool) -> String {
        failed ? "Retry \(move)" : again ? "\(move.prefix(1).uppercased() + move.dropFirst()) again" : move.prefix(1).uppercased() + move.dropFirst()
    }

    var body: some View {
        Button(action: action) {
            MoveChip(move: move, me: me, symbol: failed || again ? "arrow.clockwise" : "play.fill",
                     title: Self.title(move.name, failed: failed, again: again))
                .brightness(hovering ? 0.08 : 0)
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(failed ? "Run \(move.name) again on this head" : again ? "Run \(move.name) again: its last run here changed nothing" : "Start the \(move.name) agent now")
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
    /// The workflows a press of Re-run asked GitHub for, on this popover.
    @State private var rerun: [String]?

    var body: some View {
        Button { open = true } label: { MoveChip(move: move, me: me) }
            .buttonStyle(PressStyle())
            .pointingHandCursor()
            .help("What \(move.name) needs")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(move.name) · #\(pr.number)").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(rerun != nil ? "Asked GitHub to run \(rerun!.joined(separator: ", ")) again on this head. The flow runs \(move.name) once a sync reads it green."
                         : !move.redChecks.isEmpty
                         ? "Held by a red check on this head: \(move.redChecks.joined(separator: ", ")). Re-run it when the failure was not this PR's, or fix what it found and push; the flow runs \(move.name) once it is green."
                         : move.labels.isEmpty
                         ? "Yours to do on GitHub. Bton sees it at the next sync."
                         : "Yours to do on GitHub. When it is done, remove \(move.labels.joined(separator: ", ")) and the flow moves on.")
                        .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 8) {
                        PillButton(title: "Open on GitHub", prominent: false) { NSWorkspace.shared.open(pr.url) }
                        if !move.redChecks.isEmpty, rerun == nil {
                            AsyncPillButton(title: "Re-run \(move.redChecks.joined(separator: ", "))", runningTitle: "Asking GitHub...",
                                            symbol: "arrow.clockwise", id: "rerun:\(pr.repo)#\(pr.number):\(pr.headSha)") {
                                problem = nil
                                do { rerun = try await store.rerunRedChecks(on: pr) } catch { problem = error.localizedDescription }
                            }
                            .help("Runs the failed workflow on this exact commit again; nothing else changes")
                        }
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
