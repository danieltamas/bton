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
    @State private var problem: String?

    var body: some View {
        let report = store.features[slug]
        if let detail {
            FeatureDetail(slug: slug, row: detail) { withAnimation(Motion.spring) { self.detail = nil } }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            VStack(spacing: 8) {
                header(report)
                // Nothing to search or filter before the registry is there.
                if let report, case .ready = report.registry {
                    SearchField(text: $query, prompt: "Search features: #433, a name, a word")
                        .padding(.horizontal, 14)
                    scopes(report)
                }
                if let problem = report?.problem { ProblemText(text: problem).padding(.horizontal, 14) }
                content(report).releaseAction(slug: slug, report: report).registryPreviewAction(store: store, slug: slug, report: report)
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
                if let line = report?.release.flatMap(FeaturePage.releaseLine) {
                    Text(line.text).font(.meta).foregroundStyle(line.amber ? Theme.unassigned : Theme.textSecondary).lineLimit(2)
                }
                if let number = report?.previewPullRequest {
                    Text("From PR #\(number), not merged yet").font(.meta).foregroundStyle(Theme.unassigned).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            IconButton(symbol: "arrow.up.right", help: "Open the repo on GitHub", size: 24) {
                NSWorkspace.shared.open(URL(string: "https://github.com/\(slug)")!)
            }
        }
        .padding(.horizontal, 14)
    }

    /// The search's scope line, as under a Finder search: each status with its count, the chosen
    /// one underlined in mint.
    private func scopes(_ report: FeatureReport) -> some View {
        HStack(spacing: 14) {
            ForEach(FeatureFilter.allCases, id: \.self) { item in
                let selected = filter == item
                Button {
                    withAnimation(Motion.snappy) { filter = selected ? nil : item }
                } label: {
                    VStack(spacing: 3) {
                        HStack(spacing: 4) {
                            Text(item.rawValue)
                            Text("\(FeaturePage.count(item, report: report))")
                                .foregroundStyle(selected ? Theme.mint : Theme.textTertiary)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Capsule().fill(selected ? Theme.mint : .clear).frame(height: 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help(selected ? "Show every feature" : "Only the features \(item.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private func content(_ report: FeatureReport?) -> some View {
        switch report?.registry {
        case nil:
            EmptyState(symbol: "square.grid.3x3", title: "Not read yet",
                       detail: "The repo's registry shows after the next sync.")
        case .none?:
            VStack(spacing: 0) {
                VStack(spacing: 14) {
                    EmptyState(symbol: "square.grid.3x3", title: "No feature registry yet",
                               detail: "The registry job builds .bton/features.json from the code graph, the issues and the merged PRs.")
                        .fixedSize(horizontal: false, vertical: true)
                    graphRow
                }
                .frame(maxHeight: .infinity)
                registryAction.padding(.bottom, 28)
            }
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

extension RepoPage {
    /// The code graph the job draws the areas from: its switch, right here, and what graphify is,
    /// until the graph is built.
    @ViewBuilder fileprivate var graphRow: some View {
        if let readiness = store.graphReadiness(slug), readiness != .ready {
            VStack(spacing: 6) {
                RepoSwitch(symbol: "point.3.connected.trianglepath.dotted", title: "Build a code graph for agents",
                           help: "After a sync, Bton keeps a graphify graph of the branch PRs merge into under ~/.bton/graphs and links it into every checkout it makes.",
                           isOn: readiness != .off, problem: $problem) { try store.setCodeGraph($0, for: slug) }
                if let note = Self.graphNote(readiness) {
                    Text(note).font(.meta).foregroundStyle(readiness == .missingPython ? Theme.danger : Theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                if readiness == .building { GraphBuildProgress(slug: slug) }
                if let problem { ProblemText(text: problem) }
            }
            .padding(.horizontal, 32)
        }
    }

    /// One line under the switch: what graphify does, and where the graph stands.
    static func graphNote(_ readiness: CodeGraph.Readiness) -> String? {
        switch readiness {
        case .off: "graphify maps the code into modules and their links; the job needs it for the areas."
        case .missingPython: "graphify's Python not found: set it in Settings > Agents."
        case .building: "graphify is mapping the code; the job starts when the graph is built."
        case .ready: nil
        }
    }

    /// The empty state's action, in order: the run in progress, the last run's PR, the graph
    /// the job waits for, a press not started yet, or the first registry job.
    @ViewBuilder fileprivate var registryAction: some View {
        if let job = store.jobs.first(where: { $0.status == .running && $0.key.move == FeatureJob.move
                                                && $0.key.repo.caseInsensitiveCompare(slug) == .orderedSame }) {
            PillButton(title: "Building the registry", symbol: "rectangle.and.text.magnifyingglass", prominent: false) {
                // The job's session shows in place of the page, which the lists come back to.
                withAnimation(Motion.spring) { store.viewingRepo = nil; store.watchingJob = job.id }
            }
            .help("The registry job runs: see its session")
        } else if let pr = store.registryPullRequest(slug) {
            PillButton(title: "Registry PR #\(pr.number) open", symbol: "arrow.up.right", prominent: false) {
                NSWorkspace.shared.open(pr.url)
            }
            .help("The registry is in \(pr.title): the page fills once it is merged")
        } else if let readiness = store.graphReadiness(slug), readiness != .ready {
            PillButton(title: "Build the registry", symbol: "sparkles", disabled: true) {}
                .help("Needs the code graph: \(readiness.hold ?? "")")
        } else if store.isNext(repo: slug, item: FeatureJob.item) {
            StartingLabel(repo: slug, reason: store.waitingReason(repo: slug, item: FeatureJob.item))
        } else {
            PillButton(title: "Build the registry", symbol: "sparkles") { Task { await store.buildRegistry(slug) } }
                .help("An agent reads the issues, the merged PRs and the code graph, writes the registry and opens a PR")
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

/// The build's step and, while graphify reads the files, how far: read from its log every two seconds.
private struct GraphBuildProgress: View {
    @Environment(AppStore.self) private var store
    let slug: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            let progress = store.graphProgress(slug)
            HStack(spacing: 8) {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction).tint(Theme.mint).frame(width: 160)
                    Text("\(Int(fraction * 100))%").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.mint)
                } else {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 10, height: 10)
                }
                Text(progress?.step ?? "Waiting for the next sync to start the build")
                    .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            .id(context.date)
        }
    }
}

extension View {
    /// Over a registry read from the job's open PR: the way to that PR, where the release pill
    /// would be (a release needs a merged registry, so the two never meet).
    @ViewBuilder func registryPreviewAction(store: AppStore, slug: String, report: FeatureReport?) -> some View {
        if report?.previewPullRequest != nil, let pr = store.registryPullRequest(slug) {
            contentMargins(.bottom, 64, for: .scrollContent)
                .overlay(alignment: .bottomTrailing) {
                    PillButton(title: "Registry PR #\(pr.number) open", symbol: "arrow.up.right", prominent: false) {
                        NSWorkspace.shared.open(pr.url)
                    }
                    .help("The registry is in \(pr.title): the page shows it before the merge")
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 4).padding(.trailing, 14).padding(.bottom, 12)
                }
        } else {
            self
        }
    }
}
