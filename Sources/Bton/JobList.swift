import BtonCore
import SwiftUI

/// Every agent session and command this Mac ran, newest first, with its live status and cost.
struct JobList: View {
    let items: [Job]
    let schedules: [ScheduleEntry]

    var body: some View {
        if items.isEmpty {
            EmptyState(symbol: "bolt.horizontal", title: "No agents yet",
                       detail: "When a move is yours and the flow can start it, its agent shows here.")
        } else {
            RowStack(items: items) { job in
                JobRow(job: job, title: jobTitle(job, schedules: schedules))
            }
        }
    }
}

/// `#343 review` for a PR, the schedule's name for a schedule.
func jobTitle(_ job: Job, schedules: [ScheduleEntry]) -> String {
    if let entry = schedules.first(where: { $0.item == job.key.item }) { return entry.name }
    if job.key.item.hasPrefix("pr-") { return "#\(job.key.item.dropFirst(3)) \(job.key.move)" }
    return "\(job.key.item) \(job.key.move)"
}

private struct JobRow: View {
    @Environment(AppStore.self) private var store
    let job: Job
    let title: String
    @State private var hovering = false

    var body: some View {
        let color = Theme.color(for: job.status)
        HoverCard(accent: job.status == .running ? color : nil, action: { watch() }) {
            HStack(spacing: 10) {
                ZStack {
                    GlyphDisc(symbol: Theme.symbol(forMove: job.key.move), color: Theme.color(forMove: job.key.move), size: 30)
                    Image(systemName: Theme.symbol(for: job.status))
                        .font(.system(size: 6.5, weight: .heavy))
                        .foregroundStyle(Theme.canvas)
                        .frame(width: 13, height: 13)
                        .background(color, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.core, lineWidth: 1.5))
                        .offset(x: 11, y: 11)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Chip(text: job.status.rawValue, color: color)
                        ForEach(job.flags ?? [], id: \.self) { flag in
                            if let label = flag.label { Chip(text: label, color: Theme.danger, style: .outline) }
                        }
                    }
                    if job.agent != nil { ModelBadges(job: job) }
                    Text([job.agent == nil ? "command" : nil, job.key.repo.split(separator: "/").last.map(String.init),
                          store.work.summary(of: job), job.detail, job.verdict.map(\.summary)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.meta).foregroundStyle(job.status == .failed ? Theme.danger.opacity(0.85) : Theme.textTertiary)
                        .lineLimit(2)
                        .help(job.verdict?.note ?? "")
                }
                Spacer(minLength: 4)
                if hovering {
                    actions.transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    figures.transition(.opacity)
                }
            }
        }
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .contextMenu {
            Button("Watch Session") { watch() }
            if store.hasLogs(of: job) {
                Button("Open Output and Log") { store.openLogs(of: job) }
            }
            if job.status != .running, job.worktree != nil, store.isClaude(job) {
                Button("Resume in Terminal") { try? store.resumeInTerminal(job) }
            }
            if job.status == .running {
                Divider()
                Button("Stop") { Task { await store.stop(job) } }
            }
            if store.canRetry(job) {
                Divider()
                Button("Retry") { Task { await store.retry(job) } }
            }
        }
    }

    private var figures: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let cost = job.cost {
                Cost(value: cost)
            } else if !job.usage.isEmpty {
                Text("no price").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.unassigned)
                    .help("Add this model's price in Settings → Prices")
            }
            Group {
                if job.status == .running {
                    Text(job.startedAt, style: .timer)
                } else if let ended = job.endedAt {
                    RelativeTime(date: ended)
                }
            }
            .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
        }
    }

    private func watch() {
        withAnimation(Motion.spring) { store.watchingJob = job.id }
    }

    private var actions: some View {
        HStack(spacing: 5) {
            IconButton(symbol: "text.bubble", help: "Watch what the agent does", size: 24) { watch() }
            if job.status == .running {
                IconButton(symbol: "stop.fill", help: "Stop and release the lease", tint: Theme.danger, size: 24) {
                    Task { await store.stop(job) }
                }
            }
            if store.canRetry(job) {
                IconButton(symbol: "arrow.clockwise", help: "Run this move again on the same head", size: 24) {
                    Task { await store.retry(job) }
                }
            }
        }
    }
}

extension JobFlag {
    /// The chip's text; nil where the status chip already says it.
    var label: String? {
        switch self {
        case .timedOut: "timed out"
        case .leaseLost: "lease lost"
        case .noVerdict: "no verdict"
        case .postFailed: "not posted"
        case .agentFailed: "agent crashed"
        case .loggedOut: "logged out"
        case .failed: nil
        case .repeated: "failed again"
        case .costly: "costly"
        }
    }
}

extension SupervisorVerdict {
    /// `retry: retried`, `escalate: <note>`: what the supervisor said and what came of it.
    var summary: String {
        action.rawValue + ": " + (outcome ?? note)
    }
}
