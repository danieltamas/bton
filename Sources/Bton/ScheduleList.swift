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
                        ScheduleEditor(entry: editing.entry, compact: true) {
                            withAnimation(Motion.spring) { self.editing = nil }
                        }
                        .padding(14)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                list.transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(Motion.spring, value: editing?.id)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                syncRow.riseIn(0)
                ForEach(Array(store.schedules.enumerated()), id: \.element.id) { index, entry in
                    ScheduleRow(entry: entry, last: store.lastJob(of: entry)) { editing = .existing(entry) }
                        .riseIn(index + 1)
                }
                HStack {
                    if store.schedules.isEmpty {
                        Text("Run an agent on a timer: drain the PR queue every hour, triage weekly.")
                            .font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    PillButton(title: "New schedule", symbol: "plus") { editing = .new }
                }
                .padding(.top, 8)
                .riseIn(store.schedules.count + 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.never)
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
                        Text(last.addingTimeInterval(TimeInterval(store.pollSeconds)), style: .relative)
                            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
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
                        if let repo = entry.repo, let item = entry.item, store.isNext(repo: repo, item: item) {
                            Chip(text: "next", color: color)
                        }
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
                    if entry.enabled {
                        nextRun.font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let repo = entry.repo, let item = entry.item, last?.status != .running {
                    IconButton(symbol: "play.fill", help: "Run now, or as soon as \(repo) is free", tint: color, size: 26) {
                        Task { await store.runNext(repo: repo, item: item) }
                    }
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
        if next <= .now.addingTimeInterval(1) { Text("next sync") } else { Text(next, style: .relative) }
    }
}
