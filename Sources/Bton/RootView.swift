import AppKit
import BtonCore
import SwiftUI

enum Tab: String, CaseIterable, Identifiable {
    case pullRequests = "PRs", issues = "Issues", jobs = "Jobs", schedule = "Schedule", merged = "Merged"
    var id: Self { self }
}

/// The menu bar window: a bento of what needs me, a floating tab island, and the list below.
struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSettings) private var openSettingsWindow
    @Environment(\.stillImage) private var stillImage
    @State private var tab: Tab
    /// The repo the PR, job and merged lists are narrowed to; nil shows every repo.
    @State private var repo: String?
    /// What the PR, job and merged lists are narrowed to while typed; each tab counts its matches.
    @State private var query = ""
    @Namespace private var island
    @State private var visible = true

    init(tab: Tab = .pullRequests) {
        _tab = State(initialValue: tab)
    }

    /// Room for four PR rows, short of the screen under the menu bar on a small display.
    private static var height: CGFloat { min(780, (NSScreen.main?.visibleFrame.height ?? 820) - 40) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let problem = store.problem { notice(problem) }
            ForEach(store.loggedOut, id: \.self) { LoginNotice(agent: $0) }
            bento.padding(.horizontal, 14).padding(.top, 4)
            tabIsland.padding(.top, 14).padding(.bottom, 10)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(Motion.spring, value: tab)
                .animation(Motion.spring, value: store.watchingJob)
                .animation(Motion.spring, value: store.readingDraft)
            footer
        }
        .frame(width: 404, height: Self.height)
        .background(Backdrop())
        .background(WindowVisibility(visible: $visible))
        .environment(\.panelVisible, visible)
        // Each opening asks at most once per 15 minutes; ReleaseWatch keeps the answer between them.
        // The README's screenshots never ask.
        .task(id: visible) { if visible && !stillImage { ReleaseWatch.shared.refresh() } }
        .preferredColorScheme(Theme.scheme)
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
            if let newer = ReleaseWatch.shared.check.newerRelease {
                IconButton(symbol: "arrow.down.circle", help: "\(newer) is out: update it in Settings > About",
                           tint: Theme.unassigned) { openSettings(.about) }
                    .transition(.opacity)
            }
            // No spinner: the sync line's dot pulses while a sync runs, and a sync can last as long as a check.
            IconButton(symbol: "arrow.clockwise", help: "Check GitHub now") { Task { await store.refresh() } }
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
                    RelativeTime(date: last) { "\(repoCount) · synced \($0) ago" }
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
            let asked = !store.issueAsks.isEmpty
            // An issue that asks me needs no flow to count.
            let hasFlow = asked || store.flows.values.contains { $0.flow != nil }
            Bezel(glow: store.waitingOnMe == 0 ? nil : Theme.mint) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Waiting on you", color: store.waitingOnMe == 0 ? Theme.textTertiary : Theme.mint)
                    Text(hasFlow ? "\(store.waitingOnMe)" : "–").font(.statValue).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    HStack(spacing: 4) {
                        if store.lastRefresh == nil {
                            Text("Reading GitHub...").font(.meta).foregroundStyle(Theme.textTertiary)
                        } else if !hasFlow {
                            Text("No team flow yet: add .bton/flow.json to the branch PRs merge into (Settings → Repos).")
                                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        } else if waiting.isEmpty && !asked {
                            Text("No PR needs you to review, fix or merge it").font(.meta).foregroundStyle(Theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            ForEach(Array(Set(waiting.compactMap(\.move?.name))).sorted(), id: \.self) { name in
                                Chip(text: name, symbol: Theme.symbol(forMove: name), color: Theme.color(forMove: name))
                            }
                            if asked {
                                Chip(text: "reply", symbol: "questionmark.bubble", color: Theme.mint)
                                    .onTapGesture { show(.issues) }
                                    .pointingHandCursor()
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            // Questions alone wait on the Issues tab.
            .onTapGesture { show(waiting.isEmpty && asked ? .issues : .pullRequests) }
            .pointingHandCursor()
            .help("PRs whose next step is yours and no agent of yours can take it, and issues that ask you something")

            VStack(spacing: 8) {
                smallTile(eyebrow: "Agents", value: "\(store.runningJobs)", suffix: "of \(store.maxAgents)",
                          dot: store.runningJobs > 0 ? Theme.color(for: .running) : nil)
                    .onTapGesture { show(.jobs) }
                    .pointingHandCursor()
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

    /// Every tab's count while they all fit the panel; otherwise only the open tab's, so a busy day
    /// never pushes a tab off the edge.
    private var tabIsland: some View {
        ViewThatFits(in: .horizontal) {
            tabs(counted: { _ in true })
            tabs(counted: { $0 == tab })
        }
        .padding(.horizontal, 14)
    }

    private func tabs(counted: @escaping (Tab) -> Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases) { item in
                Button { show(item) } label: {
                    HStack(spacing: 5) {
                        Text(item.rawValue).font(.system(size: 12, weight: .semibold))
                        if counted(item), count(for: item) > 0 {
                            Text("\(count(for: item))").font(.system(size: 9.5, weight: .bold)).monospacedDigit()
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background((tab == item ? Theme.mint.opacity(0.22) : Theme.wash.opacity(0.09)), in: Capsule())
                        }
                    }
                    .lineLimit(1)
                    // Never narrower than its label: the spare width is shared out, a short one never wraps.
                    .fixedSize()
                    .foregroundStyle(tab == item ? Theme.mint : Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        // The active tab is lit in the accent, so it reads at a glance.
                        if tab == item {
                            Capsule().fill(Theme.mint.opacity(0.14))
                                .overlay(CapsuleRing(width: 0.75).fill(Theme.mint.opacity(0.5), style: FillStyle(eoFill: true)))
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
        .overlay(Capsule().strokeBorder(Theme.wash.opacity(0.12), lineWidth: 0.5))
    }

    /// Opens a tab's list, closing a job or draft that would otherwise stay over it.
    private func show(_ item: Tab) {
        withAnimation(Motion.spring) {
            tab = item
            store.watchingJob = nil
            store.readingDraft = nil
        }
    }

    private func count(for tab: Tab) -> Int {
        let search = SearchQuery(query)
        if !search.isEmpty, tab != .schedule { return listed(search).count(for: tab) }
        return switch tab {
        case .pullRequests: store.openPullRequests.count
        case .issues: store.issueAsks.count
        case .jobs: store.runningJobs
        case .schedule: store.schedules.filter(\.enabled).count
        // The list is GitHub's latest 30 whatever their age, so its length says nothing.
        case .merged: MergedList.recent(store.merged)
        }
    }

    /// The lists as shown: narrowed to the chosen repo, then to the search.
    private func listed(_ search: SearchQuery) -> Listed {
        let shown = listedRepos.contains(repo ?? "") ? repo : nil
        let keep = { (slug: String) in shown == nil || slug == shown }
        // A job matches its PRs' titles and authors too.
        let known = Dictionary(store.openPullRequests.map { ("\($0.repo)#\($0.number)", [$0.title, $0.author]) }
            + store.merged.map { ("\($0.repo)#\($0.number)", [$0.title, $0.author]) }) { first, _ in first }
        return Listed(
            pullRequests: store.openPullRequests.filter {
                keep($0.repo) && search.matches(numbers: [$0.number], texts: [$0.title, $0.author])
            },
            asks: store.issueAsks.filter { keep($0.repo) && search.matches(numbers: [$0.number], texts: [$0.title, $0.asker]) },
            jobs: store.jobs.filter { job in
                let item = job.key.item
                let numbers = item.hasPrefix("pr-") ? Int(item.dropFirst(3)).map { [$0] } ?? [] : store.work.numbers(of: job)
                let texts = [jobTitle(job, schedules: store.schedules)] + numbers.flatMap { known["\(job.key.repo)#\($0)"] ?? [] }
                return keep(job.key.repo) && search.matches(numbers: numbers, texts: texts)
            },
            merged: store.merged.filter { keep($0.repo) && search.matches(numbers: [$0.number], texts: [$0.title, $0.author]) },
            repoJobs: store.jobs.filter { keep($0.key.repo) })
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        let showRepo = store.repos.count > 1
        if let ask = store.readingDraft {
            DraftView(ask: ask) { withAnimation(Motion.spring) { store.readingDraft = nil } }
                .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let id = store.watchingJob, let job = store.jobs.first(where: { $0.id == id }) {
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
        let search = SearchQuery(query)
        let lists = listed(search)
        VStack(spacing: 0) {
            if tab != .schedule {
                SearchField(text: $query).padding(.bottom, 8)
                if listedRepos.count > 1 { repoFilter(selected: shown).padding(.bottom, 8) }
            }
            if tab != .schedule, !search.isEmpty, lists.count(for: tab) == 0 {
                noMatch(search, lists: lists)
            } else {
                switch tab {
                case .pullRequests: PullRequestList(items: lists.pullRequests, showRepo: showRepo, me: store.me,
                                                    jobs: lists.repoJobs, schedules: store.schedules)
                case .issues: IssueAskList(asks: lists.asks, showRepo: showRepo, jobs: lists.repoJobs, schedules: store.schedules)
                case .jobs: JobList(items: lists.jobs, schedules: store.schedules)
                case .schedule: ScheduleList(open: openSettings)
                case .merged: MergedList(items: lists.merged, showRepo: showRepo)
                }
            }
        }
    }

    /// Where else the search finds something, so a merged PR searched under PRs is one click away.
    private func noMatch(_ search: SearchQuery, lists: Listed) -> some View {
        let elsewhere = [Tab.pullRequests, .issues, .jobs, .merged].filter { lists.count(for: $0) > 0 }
            .map { "\($0.rawValue) (\(lists.count(for: $0)))" }
        return EmptyState(symbol: "magnifyingglass", title: "Nothing here matches \(search.text)",
                          detail: elsewhere.isEmpty
                              ? "Search covers open PRs, questions on issues, this Mac's jobs and GitHub's latest merged PRs."
                              : "Found in " + elsewhere.joined(separator: ", ") + ".")
    }

    struct Listed {
        let pullRequests: [PullRequest]
        let asks: [IssueAsk]
        let jobs: [Job]
        let merged: [MergedPullRequest]
        /// The repo's jobs whatever the search: the PR list's strip shows every running agent.
        let repoJobs: [Job]

        func count(for tab: Tab) -> Int {
            switch tab {
            case .pullRequests: pullRequests.count
            case .issues: asks.count
            case .jobs: jobs.count
            case .schedule: 0
            case .merged: merged.count
            }
        }
    }

    /// Every repo that has a PR, a job or a merge listed, in a stable order.
    private var listedRepos: [String] {
        Array(Set(store.openPullRequests.map(\.repo) + store.issueAsks.map(\.repo) + store.jobs.map(\.key.repo)
            + store.merged.map(\.repo))).sorted()
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
            if store.local.reports.isEmpty {
                Text("Checks GitHub every \(Duration.seconds(store.pollSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
            } else {
                BranchSummary()
            }
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
