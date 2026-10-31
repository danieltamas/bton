import BtonCore
import SwiftUI

/// What runs on a timer: the GitHub sync itself, then this Mac's own schedules, each with its
/// last result and next run. A schedule opens for editing in place, over the list.
struct ScheduleList: View {
    @Environment(AppStore.self) private var store
    let open: (SettingsPane) -> Void
    @State private var editing: ScheduleDraft?

    var body: some View {
        ZStack {
            if let editing {
                ScrollView {
                    Bezel(glow: Theme.color(forMove: "schedule")) {
                        ScheduleEditor(entry: editing.entry, repo: editing.repo, compact: true) {
                            withAnimation(Motion.spring) { self.editing = nil }
                        }
                        .padding(14)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .transition(.push)
            } else {
                list.transition(.pushed)
            }
        }
        .animation(Motion.spring, value: editing?.id)
    }

    /// The sync, then one card per watched repo: its flow when it has one, else its schedule, else
    /// the card that makes one. A repo is run by its flow or by one schedule, never both, so a
    /// schedule left on a repo with a flow shows under the flow as ignored, with its delete.
    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                syncRow.riseIn(0)
                ForEach(Array(store.repos.enumerated()), id: \.element.slug) { index, repo in
                    let flow = store.flows[repo.slug]
                    let schedules = schedules(of: repo.slug)
                    Group {
                        if case .ready? = flow {
                            FlowRepoRow(repo: repo, flow: flow) { open(.repos) }
                            ForEach(schedules) { entry in
                                IgnoredScheduleRow(entry: entry, repo: repo.slug).padding(.leading, 22)
                            }
                        } else if let entry = schedules.first {
                            ScheduleRow(entry: entry, last: store.lastJob(of: entry)) { editing = .existing(entry) }
                            ForEach(schedules.dropFirst()) { extra in
                                IgnoredScheduleRow(entry: extra, repo: repo.slug, by: entry.name).padding(.leading, 22)
                            }
                        } else {
                            NoRunnerRow(repo: repo, flow: flow) { editing = .new(repo: repo.slug) }
                        }
                    }
                    .riseIn(index + 1)
                }
                let orphans = store.schedules.filter { entry in !store.repos.contains { $0.slug.caseInsensitiveCompare(entry.repo ?? "") == .orderedSame } }
                if !orphans.isEmpty {
                    Eyebrow(text: "No watched repo").padding(.top, 10)
                    ForEach(orphans) { entry in
                        ScheduleRow(entry: entry, last: store.lastJob(of: entry)) { editing = .existing(entry) }
                    }
                }
                if store.repos.isEmpty {
                    Text("Add a repo under Settings > Repos. Its flow runs it; a repo without a flow gets one schedule.")
                        .font(.meta).foregroundStyle(Theme.textTertiary).padding(.top, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
        .floatingAction(title: "New schedule", symbol: "plus") { editing = .new() }
    }

    private func schedules(of slug: String) -> [ScheduleEntry] {
        store.schedules.filter { $0.repo?.caseInsensitiveCompare(slug) == .orderedSame }
    }

    private var syncRow: some View {
        HoverCard(accent: nil, action: { open(.general) }) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: "arrow.triangle.2.circlepath", color: Theme.mint, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("GitHub sync").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                        Chip(text: "always on", color: Theme.mint)
                    }
                    Text("Reads every repo, starts your moves, pings stale ones")
                        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text("every \(store.pollSeconds)s").font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textSecondary)
                    if let last = store.lastRefresh {
                        RelativeTime(date: last.addingTimeInterval(TimeInterval(store.pollSeconds)))
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }
}

/// A repo run by its flow: the flow chip opens the summary, the switch starts the moves on every
/// sync or leaves them to Run now, Merge and Retry. The card opens the repo's settings.
struct FlowRepoRow: View {
    @Environment(AppStore.self) private var store
    let repo: WatchedRepo
    let flow: FlowStatus?
    let open: () -> Void

    var body: some View {
        HoverCard(accent: nil, action: open) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: "play.circle", color: repo.startsMoves ? Theme.mint : Theme.neutral, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(repo.slug).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        FlowChip(repo: repo, status: flow)
                    }
                    Text(repo.path == nil ? "No folder yet: nothing starts here until it has one."
                         : repo.startsMoves ? "Every sync starts the flow's moves that are yours."
                         : "Syncs only read the repo; Run now, Merge and Retry start a move.")
                        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 4)
                if repo.path != nil {
                    Toggle("", isOn: Binding(get: { repo.startsMoves }, set: { try? store.setStartMoves($0, for: repo.slug) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.mint)
                        .pointingHandCursor()
                        .help("On: every sync starts the flow's moves that are yours. Off: syncs only read; Run now, Merge and Retry start a move.")
                }
            }
        }
    }
}

/// A repo with no flow Bton can run and no schedule: nothing starts here. The card makes the schedule.
struct NoRunnerRow: View {
    let repo: WatchedRepo
    let flow: FlowStatus?
    let add: () -> Void

    var body: some View {
        HoverCard(accent: nil, action: repo.path == nil ? nil : add) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: "clock.badge.questionmark", color: Theme.neutral, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(repo.slug).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        FlowChip(repo: repo, status: flow)
                    }
                    Text(detail).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(2)
                }
                Spacer(minLength: 4)
                if repo.path != nil {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
    }

    private var detail: String {
        if repo.path == nil { return "No folder yet: nothing starts here until it has one." }
        switch flow {
        case nil: return "Not read yet: the first sync says whether the repo has a flow."
        case .some(.none): return "No flow in the repo: nothing starts here. Click to give it a schedule."
        default: return "The repo's flow does not read, so nothing starts here. Fix the flow, or click to give it a schedule."
        }
    }
}

/// A schedule the sync ignores: on a repo its flow runs, or a second one on a repo another
/// schedule already runs. It stays visible until deleted, so nobody wonders where it went.
struct IgnoredScheduleRow: View {
    @Environment(AppStore.self) private var store
    let entry: ScheduleEntry
    let repo: String
    var by: String?
    @State private var problem: String?

    var body: some View {
        HoverCard(accent: nil, action: nil) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: "clock.arrow.circlepath", color: Theme.neutral, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.rowTitle).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Chip(text: "ignored", color: Theme.neutral, style: .outline)
                    }
                    Text(by.map { "\($0) already runs \(repo): one schedule per repo. Delete this one." }
                         ?? "\(repo) has a flow, and the flow runs it. Delete the schedule; its prompt stays in the job history.")
                        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(2)
                    if let problem { ProblemText(text: problem) }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "trash", help: "Delete \(entry.name)", tint: Theme.danger, size: 26) {
                    do { try store.removeSchedule(entry.number) } catch { problem = error.localizedDescription }
                }
            }
        }
    }
}

/// A schedule with its switch, its interval, repo and agent, and its next run.
struct ScheduleRow: View {
    @Environment(AppStore.self) private var store
    let entry: ScheduleEntry
    let last: Job?
    let edit: () -> Void

    var body: some View {
        let color = Theme.color(forMove: "schedule")
        HoverCard(accent: entry.enabled ? color : nil, action: edit) {
            HStack(spacing: 10) {
                GlyphDisc(symbol: "clock.arrow.circlepath", color: entry.enabled ? color : Theme.neutral, size: 30)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(entry.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let last { Chip(text: last.status.rawValue, color: Theme.color(for: last.status)) }
                    }
                    Text([interval, entry.repo?.split(separator: "/").last.map(String.init), entry.agent,
                          entry.model.map(ClaudeModel.label(for:)),
                          entry.helpers.flatMap { $0.isEmpty ? nil : "asks " + $0.joined(separator: ", ") }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 5) {
                    Toggle("", isOn: Binding(get: { entry.enabled },
                                             set: { try? store.setSchedule(entry.number, enabled: $0) }))
                        .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(color)
                        .pointingHandCursor()
                    if entry.enabled {
                        nextRun.font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let repo = entry.repo, let item = entry.item, last?.status != .running, store.isNext(repo: repo, item: item) {
                    StartingLabel(repo: repo, reason: store.waitingReason(repo: repo, item: item))
                } else if let repo = entry.repo, let item = entry.item, last?.status != .running {
                    AsyncIconButton(symbol: "play.fill", help: "Run now, or as soon as \(repo) is free", tint: color, size: 26,
                                    id: "next:\(repo)#\(item)") { await store.runNext(repo: repo, item: item) }
                }
            }
        }
    }

    private var interval: String {
        "every " + Duration.seconds(entry.everyMinutes * 60)
            .formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated, maximumUnitCount: 2))
            + (entry.onlyOnChange == true ? ", when a PR changed" : "")
    }

    /// Due now means at the next sync, which is when the engine starts it.
    @ViewBuilder private var nextRun: some View {
        let next = { var timed = entry; timed.lastRun = last?.startedAt; return timed.nextRun(after: .now) }()
        if next <= .now.addingTimeInterval(1) { Text("next sync") } else { RelativeTime(date: next) }
    }
}
