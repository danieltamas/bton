import AppKit
import BtonCore
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case pullRequests = "PRs", jobs = "Jobs", schedule = "Schedule", merged = "Merged"
    var id: Self { self }
}

/// The menu bar window: a bento of what needs me, a floating tab island, and the list below.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettingsWindow
    @State private var tab: Tab
    /// The repo the PR, job and merged lists are narrowed to; nil shows every repo.
    @State private var repo: String?
    @Namespace private var island
    @State private var visible = true

    init(tab: Tab = .pullRequests) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let problem = store.problem { notice(problem) }
            bento.padding(.horizontal, 14).padding(.top, 4)
            tabIsland.padding(.top, 14).padding(.bottom, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.spring, value: tab)
                .animation(Motion.spring, value: store.watchingJob)
            footer
        }
        .frame(width: 404, height: 620)
        .background(Backdrop())
        .background(WindowVisibility(visible: $visible))
        .environment(\.panelVisible, visible)
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: .btonTemplate)
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(Theme.brand)
                .frame(width: 30, height: 30)
                .background(Theme.core, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
            VStack(alignment: .leading, spacing: 1) {
                Text("Bton").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                syncLine
            }
            Spacer()
            Ticker(active: store.isRefreshing) { time in
                IconButton(symbol: "arrow.clockwise", help: "Check GitHub now") { Task { await store.refresh() } }
                    .rotationEffect(.degrees(time.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
            }
            IconButton(symbol: "gearshape", help: "Settings") { openSettings(.general) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var syncLine: some View {
        HStack(spacing: 5) {
            PulseDot(color: store.problem == nil ? Theme.success : Theme.unassigned, pulsing: store.isRefreshing)
            Group {
                if let last = store.lastRefresh {
                    Text("\(repoCount) · synced \(Text(last, style: .relative)) ago")
                } else {
                    Text(repoCount)
                }
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
    }

    private var repoCount: String {
        switch store.repos.count {
        case 0: "no repos"
        case 1: store.repos[0].slug.split(separator: "/").last.map(String.init) ?? store.repos[0].slug
        default: "\(store.repos.count) repos"
        }
    }

    private func notice(_ problem: String) -> some View {
        Bezel(radius: 13, fill: Theme.unassigned.opacity(0.10)) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.unassigned)
                Text(problem).font(.meta).foregroundStyle(Theme.textSecondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if store.repos.isEmpty {
                    PillButton(title: "Add folder", symbol: "plus") { openSettings(.repos) }
                }
            }
            .padding(10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: bento

    /// The big tile: how many PRs wait on me for a step an agent cannot take (a review I owe, a
    /// PR of mine to fix or merge). Without a flow on any repo nobody's move is known, so it says that.
    private var bento: some View {
        HStack(spacing: 8) {
            let waiting = store.humanMovesForMe
            let hasFlow = store.flows.values.contains { $0.flow != nil }
            Bezel(glow: waiting.isEmpty ? nil : Theme.mint) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Waiting on you", color: waiting.isEmpty ? Theme.textTertiary : Theme.mint)
                    Text(hasFlow ? "\(waiting.count)" : "–").font(.statValue).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        if store.lastRefresh == nil {
                            Text("Reading GitHub...").font(.meta).foregroundStyle(Theme.textTertiary)
                        } else if !hasFlow {
                            Text("No team flow yet: add .bton/flow.json to the branch PRs merge into (Settings → Repos).")
                                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        } else if waiting.isEmpty {
                            Text("No PR needs you to review, fix or merge it").font(.meta).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(Array(Set(waiting.compactMap(\.move?.name))).sorted(), id: \.self) { name in
                                Chip(text: name, symbol: Theme.symbol(forMove: name), color: Theme.color(forMove: name))
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .onTapGesture { withAnimation(Motion.spring) { tab = .pullRequests } }
            .help("PRs whose next step is yours and no agent of yours can take it")

            VStack(spacing: 8) {
                smallTile(eyebrow: "Agents", value: "\(store.runningJobs)", suffix: "of \(store.maxAgents)",
                          dot: store.runningJobs > 0 ? Theme.color(for: .running) : nil)
                    .onTapGesture { withAnimation(Motion.spring) { tab = .jobs } }
                // The week sits on its own line, so neither figure is cut as costs grow.
                smallTile(eyebrow: "Today", value: store.costToday.usd(), suffix: "week \(store.costThisWeek.usd(cents: false))", dot: nil)
            }
            .frame(width: 140)
        }
        .frame(height: 140)
    }

    private func smallTile(eyebrow: String, value: String, suffix: String, dot: Color?) -> some View {
        Bezel(radius: 14) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Eyebrow(text: eyebrow)
                    if let dot { PulseDot(color: dot) }
                }
                Text(value).font(.statSmall).foregroundStyle(Theme.textPrimary).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).contentTransition(.numericText())
                Text(suffix).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: tabs

    private var tabIsland: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button {
                    withAnimation(Motion.spring) {
                        tab = item
                        store.watchingJob = nil
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                        if count(for: item) > 0 {
                            Text("\(count(for: item))").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((tab == item ? Theme.mint.opacity(0.22) : Color.white.opacity(0.09)), in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    // Never narrower than its label: the spare width is shared out, a short one never wraps.
                    .fixedSize()
                    .foregroundStyle(tab == item ? Theme.mint : Theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        // The active tab is lit in the accent, so it reads at a glance.
                        if tab == item {
                            Capsule().fill(Theme.mint.opacity(0.14))
                                .overlay(Capsule().strokeBorder(Theme.mint.opacity(0.5), lineWidth: 0.75))
                                .shadow(color: Theme.mint.opacity(0.25), radius: 8)
                                .matchedGeometryEffect(id: "tab", in: island)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(3)
        .background(Theme.core, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .padding(.horizontal, 14)
    }

    private func count(for tab: Tab) -> Int {
        switch tab {
        case .pullRequests: store.openPullRequests.count
        case .jobs: store.runningJobs
        case .schedule: store.schedules.filter(\.enabled).count
        case .merged: store.merged.count
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        let showRepo = store.repos.count > 1
        if let id = store.watchingJob, let job = store.jobs.first(where: { $0.id == id }) {
            SessionView(job: job, title: jobTitle(job, schedules: store.schedules)) {
                withAnimation(Motion.spring) { store.watchingJob = nil }
            }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else {
            tabContent(showRepo: showRepo)
        }
    }

    @ViewBuilder private func tabContent(showRepo: Bool) -> some View {
        let shown = listedRepos.contains(repo ?? "") ? repo : nil
        let keep = { (slug: String) in shown == nil || slug == shown }
        VStack(spacing: 0) {
            if tab != .schedule, listedRepos.count > 1 { repoFilter(selected: shown).padding(.bottom, 8) }
            switch tab {
            case .pullRequests: PullRequestList(items: store.openPullRequests.filter { keep($0.repo) }, showRepo: showRepo,
                                                me: store.me, jobs: store.jobs.filter { keep($0.key.repo) },
                                                schedules: store.schedules)
            case .jobs: JobList(items: store.jobs.filter { keep($0.key.repo) }, schedules: store.schedules)
            case .schedule: ScheduleList(open: openSettings)
            case .merged: MergedList(items: store.merged.filter { keep($0.repo) }, showRepo: showRepo)
            }
        }
    }

    /// Every repo that has a PR, a job or a merge listed, in a stable order.
    private var listedRepos: [String] {
        Array(Set(store.openPullRequests.map(\.repo) + store.jobs.map(\.key.repo) + store.merged.map(\.repo))).sorted()
    }

    private func repoFilter(selected: String?) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach([nil] + listedRepos.map(Optional.some), id: \.self) { slug in
                    Button {
                        withAnimation(Motion.spring) { repo = slug }
                    } label: {
                        Chip(text: slug.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "All repos",
                             color: selected == slug ? Theme.mint : Theme.neutral,
                             style: selected == slug ? .tinted : .outline)
                    }
                    .buttonStyle(PressStyle())
                    .pointingHandCursor()
                    .help(slug ?? "Every watched repo")
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Checks GitHub every \(Duration.seconds(store.pollSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            Spacer()
            AppControls()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.canvas.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// The menu bar window does not own key focus, so the app comes forward first.
    private func openSettings(_ pane: SettingsPane) {
        store.settingsPane = pane
        NSApp.activate()
        openSettingsWindow()
    }
}
