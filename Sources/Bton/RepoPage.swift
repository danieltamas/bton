import BtonCore
import SwiftUI

/// One repo's page: its branches against origin, what waits for a release, and every feature
/// with its status. Opened from the footer's branch line or the repo filter.
struct RepoPage: View {
    @Environment(AppStore.self) private var store
    let slug: String
    let close: () -> Void
    @State private var filter: FeatureFilter?
    @State private var query = ""
    @State private var detail: FeaturePage.Row?
    @State private var branchesOpen = false

    var body: some View {
        let report = store.features[slug]
        if let detail {
            FeatureDetail(slug: slug, row: detail) { withAnimation(Motion.spring) { self.detail = nil } }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            VStack(spacing: 8) {
                header(report)
                if let report {
                    chips(report)
                    SearchField(text: $query, prompt: "Search features: #433, a name, a word")
                        .padding(.horizontal, 14)
                    if let problem = report.problem { ProblemText(text: problem).padding(.horizontal, 14) }
                }
                content(report)
            }
            .padding(.top, 2)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func header(_ report: FeatureReport?) -> some View {
        let local = store.local.reports[slug]
        let to = store.flows[slug]?.flow?.release?.to ?? local?.defaultBranch ?? "main"
        return HStack(alignment: .top, spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Back to the lists", action: close)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 4) {
                Text(slug).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let local {
                    Button { branchesOpen = true } label: {
                        HStack(spacing: 8) {
                            ForEach(local.branches) { BranchMark(status: $0) }
                            if let ahead = FeaturePage.ahead(commits: local.workingOnly, since: report?.unreleasedSince, now: .now) {
                                Text("+\(ahead) not on \(local.defaultBranch)").foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .help("Your local branches against origin")
                    .popover(isPresented: $branchesOpen, arrowEdge: .bottom) {
                        BranchDetails(reports: [(repo: slug, report: local)], every: store.pollEvery)
                    }
                }
                if let report, let summary = FeaturePage.summary(report: report, to: to, now: .now) {
                    Text(summary).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.up.right", help: "Open the repo on GitHub", size: 24) {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(slug)")!)
            }
        }
        .padding(.horizontal, 14)
    }

    private func chips(_ report: FeatureReport) -> some View {
        HStack(spacing: 6) {
            ForEach(FeatureFilter.allCases, id: \.self) { item in
                let selected = filter == item
                Button {
                    withAnimation(Motion.snappy) { filter = selected ? nil : item }
                } label: {
                    Chip(text: "\(item.rawValue) \(FeaturePage.count(item, report: report))",
                         color: selected ? Theme.mint : Theme.neutral, style: selected ? .filled : .outline)
                }
                .buttonStyle(PressStyle())
                .help(selected ? "Show every feature" : "Only the features \(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private func content(_ report: FeatureReport?) -> some View {
        switch report?.registry {
        case nil:
            EmptyState(symbol: "square.grid.3x3", title: "Not read yet",
                       detail: "The repo's registry shows after the next sync.")
        case .none?:
            EmptyState(symbol: "square.grid.3x3", title: "No feature registry yet",
                       detail: "The registry job builds .bton/features.json from the code graph, the issues and the merged PRs.")
        case let .invalid(reason)?:
            VStack {
                ProblemText(text: "\(FeatureRegistry.relativePath): \(reason)").padding(.horizontal, 14)
                Spacer()
            }
        case let .ready(registry)?:
            let page = FeaturePage.make(registry: registry, report: report!, filter: filter, query: SearchQuery(query))
            if page.areas.isEmpty {
                EmptyState(symbol: "magnifyingglass", title: "No feature matches",
                           detail: filter == nil ? "Nothing matches the search." : "Nothing \(filter!.rawValue) matches.")
            } else {
                FeatureTree(page: page) { row in withAnimation(Motion.spring) { detail = row } }
            }
        }
    }
}

/// A feature's status in its hue: live and in develop are what matters most on the page.
struct FeatureStatusChip: View {
    let status: FeatureStatus
    var style: Chip.Style = .outline

    var body: some View {
        Chip(text: status.rawValue, color: Self.color(status), style: style)
    }

    static func color(_ status: FeatureStatus) -> Color {
        switch status {
        case .live: Theme.success
        case .inDevelop: Theme.color(forStage: "review")
        case .building: Theme.color(forStage: "in-progress")
        case .ready: Theme.color(forStage: "ready")
        case .spec: Theme.color(forStage: "spec")
        case .idea: Theme.neutral
        }
    }
}
