import BtonCore
import SwiftUI

/// The footer's line on the owner's own branches: each one against origin, and what develop has
/// that main lacks. A click opens every repo's details.
struct BranchSummary: View {
    @Environment(AppStore.self) private var store
    @State private var open = false

    var body: some View {
        let reports = store.repos.compactMap { repo in store.local.reports[repo.slug].map { (repo: repo.slug, report: $0) } }
        Button {
            // One repo: its page. Several: pick one from the popover.
            if reports.count == 1, let slug = reports.first?.repo { store.openRepoPage(slug) } else { open = true }
        } label: {
            HStack(spacing: 8) {
                if reports.count == 1, let report = reports.first?.report {
                    // With more repos watched, the line says whose branches these are.
                    if store.repos.count > 1, let slug = reports.first?.repo {
                        Text(RepoFilter.short(slug)).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(report.branches) { BranchMark(status: $0) }
                    if let unreleased = report.workingOnly, unreleased > 0 {
                        Text("+\(unreleased) not on \(report.defaultBranch)").foregroundStyle(Theme.textTertiary)
                    }
                    if let slug = reports.first?.repo, let line = store.features[slug]?.release.flatMap(FeaturePage.releaseLine) {
                        Text(line.text).foregroundStyle(line.amber ? Theme.unassigned : Theme.textTertiary)
                    }
                } else {
                    let needing = reports.filter { $0.report.needsAttention }
                    let needs = needing.count
                    Image(systemName: needs == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(needs == 0 ? Theme.success : Theme.unassigned)
                    Text(needs == 0 ? "branches up to date"
                         : needs <= 2 ? needing.map { RepoFilter.short($0.repo) }.joined(separator: ", ") + " need\(needs == 1 ? "s" : "") you"
                         : "\(needs) of \(reports.count) repos need you")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help("Your local branches against origin; the repo's page")
        .popover(isPresented: $open, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(reports, id: \.repo) { item in
                    Button {
                        open = false
                        store.openRepoPage(item.repo)
                    } label: {
                        HStack(spacing: 8) {
                            Text(RepoFilter.short(item.repo)).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                            ForEach(item.report.branches) { BranchMark(status: $0) }
                            Spacer(minLength: 12)
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help("The repo's page: branches and features")
                }
            }
            .padding(6)
        }
    }
}

/// One branch: a tick when it matches origin, an arrow and a count when it does not.
struct BranchMark: View {
    let status: BranchStatus

    var body: some View {
        HStack(spacing: 3) {
            Text(status.name).foregroundStyle(Theme.textSecondary)
            switch (status.ahead, status.behind) {
            case (nil, _), (_, nil):
                Image(systemName: "minus").foregroundStyle(Theme.neutral)
            case (0, 0):
                Image(systemName: "checkmark").foregroundStyle(Theme.success)
            case let (ahead?, behind?):
                if behind > 0 { Label("\(behind)", systemImage: "arrow.down").foregroundStyle(Theme.unassigned) }
                if ahead > 0 { Label("\(ahead)", systemImage: "arrow.up").foregroundStyle(Theme.color(for: .running)) }
            }
        }
        .labelStyle(CompactLabel())
    }
}

private struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 1) { configuration.icon; configuration.title }
    }
}

/// A repo's branches in words, in the page header's popover.
struct BranchDetails: View {
    let reports: [(repo: String, report: LocalBranchReport)]
    let every: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(reports, id: \.repo) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.repo).font(.rowTitle).foregroundStyle(Theme.textPrimary)
                    ForEach(item.report.branches) { status in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            BranchMark(status: status)
                            Text(Self.describe(status)).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let comparison = Self.compare(item.report) {
                        Text(comparison).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if let problem = item.report.problem { ProblemText(text: problem) }
                    Text("Checked \(item.report.at.formatted(date: .omitted, time: .shortened)), with GitHub every \(every)")
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            Text("A branch only behind origin is pulled, fast-forward only: in the folder that has it checked out, unless git refuses to overwrite uncommitted changes there. A branch with commits of its own is never touched.")
                .foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.meta)
        .padding(14)
        .frame(width: 360, alignment: .leading)
    }

    static func describe(_ status: BranchStatus) -> String {
        if let held = status.held, status.ahead == nil || status.behind == nil { return held }
        let pulled = status.pulled > 0 ? "pulled \(status.pulled) just now; " : ""
        switch (status.ahead ?? 0, status.behind ?? 0) {
        case (0, 0): return pulled + "same as origin"
        case let (ahead, 0): return pulled + "\(ahead) local commits not pushed"
        case let (0, behind): return "\(behind) behind origin; " + (status.held ?? "not pulled")
        case let (ahead, behind): return "\(ahead) local and \(behind) origin commits: " + (status.held ?? "diverged")
        }
    }

    static func compare(_ report: LocalBranchReport) -> String? {
        guard let workingOnly = report.workingOnly, let defaultOnly = report.defaultOnly else { return nil }
        let (working, main) = ("origin/\(report.working)", "origin/\(report.defaultBranch)")
        if workingOnly == 0 && defaultOnly == 0 { return "\(working) and \(main) are the same" }
        return [workingOnly > 0 ? "\(working) has \(workingOnly) commits \(main) lacks" : nil,
                defaultOnly > 0 ? "\(main) has \(defaultOnly) commits \(working) lacks" : nil]
            .compactMap { $0 }.joined(separator: "; ")
    }
}

extension LocalBranchReport {
    /// Something only the owner can settle: a branch left behind, diverged or missing, or origin unread.
    var needsAttention: Bool {
        problem != nil || branches.contains { $0.ahead == nil || $0.behind == nil || ($0.behind ?? 0) > 0 }
    }
}
