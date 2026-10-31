import BtonCore
import SwiftUI

/// The repo's flow chip: its state as read, and the summary behind it when the flow is there.
struct FlowChip: View {
    let repo: WatchedRepo
    let status: FlowStatus?
    @State private var showing = false

    var body: some View {
        if let status {
            Button { showing.toggle() } label: {
                Chip(text: Self.label(status), symbol: "chevron.down", color: Theme.color(for: status))
            }
            .buttonStyle(PressStyle())
            .help("How this repo's PRs and issues move: the flow Bton reads from the repo")
            .popover(isPresented: $showing, arrowEdge: .bottom) { FlowSummary(repo: repo, status: status) }
        } else {
            Chip(text: Self.label(nil), color: Theme.color(for: nil))
        }
    }

    static func label(_ flow: FlowStatus?) -> String {
        switch flow {
        case nil: "flow not read yet"
        case .some(.none): "no flow"
        case let .unsupported(version)?: "flow v\(version.map(String.init) ?? "?") not supported"
        case .invalid?: "flow invalid"
        case .ready?: "flow v1"
        }
    }
}

/// The repo's flow as Bton reads it, behind the `flow v1` chip on the repo card: the moves in the
/// order they are tried, whose each is per tier and what runs it; the reviews that count; the
/// reviewers' rotation; the intake of ready issues; the caps. Read-only: the flow lives in the
/// repo's `.bton/flow.json` on the branch PRs merge into, and the link opens it there.
struct FlowSummary: View {
    let repo: WatchedRepo
    let status: FlowStatus

    /// The branch the flow was read from: the one chosen for the repo, else the flow's own base.
    private var base: String { repo.branch ?? status.flow?.base ?? "the default branch" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("How \(repo.slug) works").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(Flow.relativePath) on \(base), read every sync. Edit it in the repo.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.right", help: "Open the flow on GitHub", size: 24) { NSWorkspace.shared.open(fileURL) }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch status {
                    case let .ready(flow): sections(flow)
                    case let .invalid(reason): ProblemText(text: "The flow does not read: \(reason)")
                    case let .unsupported(version):
                        ProblemText(text: "The flow is version \(version.map(String.init) ?? "?"); this Bton reads version \(Flow.supportedVersion).")
                    case .none: Text("The repo has no flow: nothing is started here on its own.").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 520)
        }
        .padding(12)
        .frame(width: 480)
    }

    private var fileURL: URL {
        URL(string: "https://github.com/\(repo.slug)/blob/\(base)/\(Flow.relativePath)") ?? URL(string: "https://github.com/\(repo.slug)")!
    }

    @ViewBuilder
    private func sections(_ flow: Flow) -> some View {
        let tiers = flow.tier.values
        Section(title: "Moves", note: "Tried in this order on every open PR; the first whose conditions hold is the PR's move.") {
            ForEach(Array(flow.moves.enumerated()), id: \.offset) { _, rule in
                moveRow(rule, dispatch: flow.dispatch[rule.move], tiers: tiers)
            }
        }
        Section(title: "Tiers", note: "\"\(flow.tier.marker)\" in the PR body; \(flow.tier.defaultTier) when it names none.") {
            Text(tiers.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
            if let paths = flow.tier.paths, !paths.isEmpty {
                ForEach(tiers.filter { paths[$0] != nil }, id: \.self) { tier in
                    Line(key: "at least \(tier)", value: "a PR touching " + (paths[tier] ?? []).joined(separator: ", "))
                }
            }
        }
        Section(title: "Reviews that count", note: "A comment with the heading is the review; \"\(flow.fixed)\" is the author's answer.") {
            ForEach(tiers, id: \.self) { tier in
                if let headings = flow.reviews[tier] {
                    Line(key: tier, value: headings.map { $0.heading + ($0.notByAuthor ? " (not by the author)" : "") }.joined(separator: ", "))
                }
            }
            if let decision = flow.decision {
                Line(key: "decision", value: "\"\(decision.heading)\" by \(decision.by.joined(separator: ", ")), posted by the \(decision.move) move")
            }
        }
        if let reviewers = flow.reviewers, !reviewers.isEmpty {
            Section(title: "Reviewers", note: "The rotation when a PR has no assignee or requested reviewer: PR number modulo the list, without the author.") {
                Text(reviewers.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
            }
        }
        if let intake = flow.intake {
            Section(title: "Ready issues", note: "A free Bton takes the first match and opens its PR; the PR's moves take over.") {
                Line(key: "search", value: intake.search.joined(separator: " "))
                Line(key: "order", value: intake.priority.joined(separator: ", "))
                Line(key: "agent", value: intake.agent + (intake.timeoutMinutes.map { ", \($0) min" } ?? ""))
                Line(key: "worktree", value: intake.worktreePath)
            }
        }
        if let caps = flow.caps {
            Section(title: "Caps", note: "No issue is taken past these.") {
                Line(key: "open PRs", value: "\(caps.openPullRequestsPerDeveloper) per developer, \(caps.openPullRequestsTeam) for the team")
            }
        }
        if let decide = flow.decide {
            Section(title: "Issues' questions to the owner", note: "Decided by the owner's own Bton, in the owner's name.") {
                Line(key: "by", value: decide.by.joined(separator: ", ") + (decide.agent.map { ", \($0)" } ?? ""))
                if let except = decide.except, !except.isEmpty { Line(key: "kept for a person", value: except.joined(separator: ", ")) }
            }
        }
        if let release = flow.release {
            Section(title: "Release", note: "\(release.from) to \(release.to), started by \(release.who)'s Bton.") {
                Line(key: "due when", value: release.when.joined(separator: " or "))
                if let blocked = release.blockedBy, !blocked.isEmpty { Line(key: "blocked by", value: blocked.joined(separator: ", ")) }
            }
        }
    }

    private func moveRow(_ rule: MoveRule, dispatch: DispatchRule?, tiers: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(rule.move).font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                Text(rule.when.joined(separator: ", ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Line(key: "whose", value: perTier(rule.who, tiers: tiers))
            if let dispatch {
                Line(key: "run by", value: runner(dispatch, tiers: tiers))
            } else {
                Line(key: "run by", value: "nobody: shown as waiting on its owner")
            }
        }
        .padding(.vertical, 2)
    }

    private func runner(_ dispatch: DispatchRule, tiers: [String]) -> String {
        var parts: [String] = []
        if let command = dispatch.command { parts.append(command.joined(separator: " ")) }
        if let agent = dispatch.agent { parts.append(perTier(agent, tiers: tiers)) }
        if dispatch.second != nil { parts.append("plus a second reviewer") }
        if dispatch.post == "comment" { parts.append("the final message is the comment") }
        if let minutes = dispatch.timeoutMinutes { parts.append("\(minutes) min") }
        return parts.isEmpty ? "an agent" : parts.joined(separator: "; ")
    }

    /// One value for every tier, or each tier's own: "author" or "quick fix: author · feature: reviewer".
    private func perTier(_ value: PerTier<String>, tiers: [String]) -> String {
        switch value {
        case let .same(one): return one
        case let .byTier(values):
            let named = tiers.compactMap { tier in values[tier].map { "\(tier): \($0)" } }
            let others = values.keys.filter { !tiers.contains($0) }.sorted().map { "\($0): \(values[$0] ?? "")" }
            return (named + others).joined(separator: " · ")
        }
    }
}

/// A titled block of the summary.
private struct Section<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: title)
            Text(note).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            content
        }
    }
}

/// "key  value" with the key dim and the value wrapping.
private struct Line: View {
    let key: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key).font(.meta).foregroundStyle(Theme.textTertiary).frame(width: 84, alignment: .trailing)
            Text(value).font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
