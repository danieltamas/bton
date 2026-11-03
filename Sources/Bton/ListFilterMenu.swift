import BtonCore
import SwiftUI

/// The dropdown beside a tab's search box: every row, or one kind or state of row with its
/// count, the way the repo page's status filter works. A button and a popover rather than a
/// native `Menu`, which shows no pointing hand; a chosen filter clears from the cross beside it.
struct ListFilterMenu: View {
    /// The filters the tab offers, each with how many rows it would show now.
    let options: [(filter: ListFilter, count: Int)]
    @Binding var selection: String?
    @State private var open = false

    private var chosen: (filter: ListFilter, count: Int)? { options.first { $0.filter.id == selection } }

    var body: some View {
        HStack(spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .medium))
                    if let chosen {
                        Text("\(chosen.filter.title) \(chosen.count)").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold))
                }
                .foregroundStyle(chosen == nil ? Theme.textTertiary : Theme.mint)
                .fieldCapsule(active: chosen != nil)
            }
            .buttonStyle(PressStyle())
            .pointingHandCursor()
            .help(chosen?.filter.help ?? "Filter the list by kind or state")
            .accessibilityValue(chosen?.filter.title ?? "everything")
            if chosen != nil {
                Button { withAnimation(Motion.snappy) { selection = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Show everything")
                .accessibilityLabel("Show everything")
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                row(nil, title: "Everything", count: nil)
                ForEach(options, id: \.filter.id) { option in
                    row(option.filter.id, title: option.filter.title, count: option.count)
                }
            }
            .padding(6)
            .frame(width: 190)
        }
    }

    private func row(_ id: String?, title: String, count: Int?) -> some View {
        Button {
            withAnimation(Motion.snappy) { selection = id }
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).opacity(selection == id ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 12)
                if let count {
                    Text("\(count)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selection == id ? Theme.mint : Theme.textTertiary)
                }
            }
            .foregroundStyle(selection == id ? Theme.mint : Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
        .accessibilityAddTraits(selection == id ? .isSelected : [])
    }
}

extension AppStore {
    /// The filters a PR row answers to, from its move and this Mac's agents on it.
    func filterIds(_ pr: PullRequest) -> Set<String> {
        let working = jobs.contains { $0.status == .running && $0.key.repo == pr.repo && $0.key.item == "pr-\(pr.number)" }
            || !schedules(workingOn: pr).isEmpty
        return ListFilter.PullRequestFacts(
            moveName: pr.move?.name,
            mine: me.map { me in pr.move.map { $0.isMine(me) && !$0.ownerWroteIt } ?? false } ?? false,
            unassigned: pr.move.map { $0.owner == nil } ?? false,
            working: working, draft: pr.isDraft, conflicting: pr.conflicting).ids
    }

    /// The states of a question for me, as its card shows them.
    func filterIds(_ ask: IssueAsk) -> Set<String> {
        ListFilter.askStates(posted: postedAsks.contains(ask.notice), handoff: ask.handoff,
                             draft: draft(for: ask)?.status, decision: decision(for: ask)?.status)
    }

    /// The states of a ready issue, from its assignees and its newest job on this Mac.
    func filterIds(_ issue: ReadyIssue) -> Set<String> {
        ListFilter.readyStates(isReady: issue.isReady, assignees: issue.assignees,
                               job: IssueIntake.latestJob(for: issue.number, repo: issue.repo, jobs: jobs)?.status)
    }
}
