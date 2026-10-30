import AppKit
import BtonCore
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppStore {
    private(set) var openPullRequests: [PullRequest] = []
    private(set) var merged: [MergedPullRequest] = []
    /// Newest first.
    private(set) var jobs: [Job] = []
    private(set) var lastRefresh: Date?
    private(set) var problem: String?
    /// Agents whose CLI login expired: their jobs wait until I log in again.
    private(set) var loggedOut: [String] = []
    private(set) var isRefreshing = false
    /// A refresh asked for while one runs: it runs right after, never dropped.
    private var refreshAgain = false
    /// Run-next picks waiting for their repo, `owner/name#item` with the repo lowercased.
    private(set) var next: [String] = []
    /// Why a pick has not started at the last sync, by pick.
    private(set) var waiting: [String: String] = [:]
    /// Repos whose jobs wait because a service of theirs does not answer, slugs lowercased, with the reason.
    private(set) var outages: [String: String] = [:]
    /// The PRs each schedule's agent works on, read from its session every few seconds.
    let work = ScheduleWork()
    let local = LocalSync()
    /// The presses running now: every async button goes through it (AsyncPress).
    let inFlight = InFlightActions()
    /// The footer's "Star on GitHub": shown once GitHub said the owner's gh has not starred Bton.
    private(set) var starOffer = false
    /// The README's starring state: the press is drawn in flight without a press.
    private(set) var demoStarring = false
    /// The job whose session the window shows in place of its list.
    var watchingJob: UUID?
    /// The issue ask whose drafted reply the window shows in place of its list.
    var readingDraft: IssueAsk?
    /// The issue read in full from its draft (View issue); nil shows the draft again.
    var viewingIssue: IssueAsk?
    /// Questions put to me on open issues, newest first.
    private(set) var issueAsks: [IssueAsk] = []
    private(set) var triage: [TriageIssue] = []
    /// Repos (slugs lowercased) with open issues beyond the pages read: the Triage list's Load more.
    private(set) var issuesMore: Set<String> = []
    /// Repos (slugs lowercased) whose extra page of issues is being read now: the Load more pill
    /// shows it from the press until the rows are in.
    private(set) var issuesLoading: Set<String> = []
    /// The issue read each repo's triage rows come from: a sync's snapshot from an earlier read
    /// keeps them, so Load more's rows never give way to older ones.
    private var issueRevisions: [String: Int] = [:]
    /// What GitHub's search found for the lists' search text, beyond the synced issues. Display only.
    var searchHits: [OpenIssue] = []
    /// Open issues at stage:ready, taken or free.
    private(set) var ready: [ReadyIssue] = []
    /// The issue open in the triage tab.
    var triaging: TriageIssue?
    /// The repo whose page (branches, features) the window shows in place of its lists.
    var viewingRepo: String?
    /// Each watched repo's feature registry with its statuses, as last read.
    private(set) var features: [String: FeatureReport] = [:]
    /// The new issue on screen, if any.
    var composing: NewIssueSession?
    /// Every new issue in the making, each its own conversation: they outlive a tab switch and
    /// are listed in Triage until created or discarded.
    var newIssues: [NewIssueSession] = []
    /// The README's screenshots show agent replies no job produced.
    var demoReplies: [Int: NewIssues.Reply] = [:]
    /// Every ask notified this run (`IssueAsk.notice`), so a mention edited out and back is not new.
    @ObservationIgnored var notifiedAsks: Set<String> = []
    /// Asks I replied to from Bton (`IssueAsk.notice`), shown as posted until a sync reads the reply.
    var postedAsks: Set<String> = []
    /// Replies being posted now: one at a time per ask, whichever view pressed it.
    var postingAsks: Set<String> = []
    /// My edits to each draft (`IssueAsk.notice`), kept while Bton runs so leaving the draft loses nothing.
    @ObservationIgnored var draftEdits: [String: String] = [:]
    let icon = MenuBarIcon()
    /// Each watched repo's flow as last read from its default branch.
    private(set) var flows: [String: FlowStatus] = [:]
    /// This Mac's `gh` login; moves owned by it are "mine".
    private(set) var me: String?
    /// Take it, by PR id: the presses still running, and why the last one wrote nothing.
    var taking: Set<String> = []
    var takeProblems: [String: String] = [:]

    var repos: [WatchedRepo] { config.repos }
    var schedules: [ScheduleEntry] { config.schedules }
    var agents: [String: AgentTemplate] { config.agents }
    var supervisor: SupervisorSettings? { config.supervisor }
    /// Set by `showDemo`: the screenshots never read this Mac's voice models.
    private(set) var isDemo = false
    var voiceSettings: VoiceSettings? { config.voice }
    var draftModel: String { config.draftModel ?? BtonConfig.defaultDraftModel }
    var graphifyPython: String? { config.graphifyPython }
    var codeGraphs: Bool { config.codeGraphs }
    var graphInstruction: String? { config.graphInstruction }
    var pollSeconds: Int { config.pollSeconds }
    /// The poll interval as the footer and the repo page word it: "2m" or "45s".
    var pollEvery: String { Duration.seconds(pollSeconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)) }
    var maxAgents: Int { config.maxAgents }
    private(set) var prices = PriceList(models: [:])
    /// Which Settings pane opens next, and the schedule it shows.
    var settingsPane: SettingsPane = .general
    let home = BtonHome()
    @ObservationIgnored private(set) lazy var voice = VoiceController(home: home)
    /// Made once: making one prepares the home on disk, too much for every render that asks for
    /// a job's files.
    @ObservationIgnored private lazy var jobStore = try? JobStore(home: home)

    /// Moves that wait for me as a person: mine without a dispatch entry, or an unassigned move
    /// on a PR I opened, or a review only someone else can give on a PR I opened.
    var humanMovesForMe: [PullRequest] {
        guard let me else { return [] }
        return openPullRequests.filter { pr in
            guard let move = pr.move else { return false }
            if let owner = move.owner, !move.ownerWroteIt { return owner.caseInsensitiveCompare(me) == .orderedSame && !move.hasDispatch }
            return pr.author.caseInsensitiveCompare(me) == .orderedSame
        }
    }

    /// What the menu bar and the bento count: my human moves and the issue asks.
    var waitingOnMe: Int { humanMovesForMe.count + issueAsks.count }

    var costToday: Decimal {
        jobs.filter { Calendar.current.isDateInToday($0.startedAt) }.reduce(0) { $0 + ($1.cost ?? 0) }
    }

    var costThisWeek: Decimal {
        jobs.filter { Calendar.current.isDate($0.startedAt, equalTo: .now, toGranularity: .weekOfYear) }
            .reduce(0) { $0 + ($1.cost ?? 0) }
    }

    var runningJobs: Int { jobs.filter { $0.status == .running }.count }

    /// Models jobs used that no price covers: each one keeps a job's cost unknown.
    var unpricedModels: [String] {
        Set(jobs.flatMap { $0.usage.filter { $0.value != TokenUsage() }.map(\.key) })
            .filter { prices.price(for: $0) == nil }.sorted()
    }

    private var config = BtonConfig.initial
    private(set) var github: GitHubClient?
    private(set) var engine: Engine?
    private var loop: Task<Void, Never>?
    private var focusLoop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        loadNewIssues()
        do {
            config = try BtonConfig.loadOrCreate(home: home)
            // The skeleton's "Poll GitHub" ran nothing; the sync interval is under General now.
            if config.schedules.contains(where: Self.isInert) { try update { $0.schedules.removeAll(where: Self.isInert) } }
            prices = PriceList.load(home: home)
            github = try GitHubClient()
            let engine = try Engine(home: home, log: EngineLog.sink(home: home))
            self.engine = engine
            // A job that ends frees an agent: the next one starts now, not at the next sync.
            Task { await engine.onJobEnded { Task { @MainActor [weak self] in await self?.refresh() } } }
            Notifier.requestPermission()
        } catch {
            problem = error.localizedDescription
            return
        }
        focusLoop = Task { [weak self] in
            while !Task.isCancelled {
                if let self { await work.read(jobs) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        loop = Task { [weak self] in
            var resumed = false
            while !Task.isCancelled {
                let started = Date.now
                await self?.refresh()
                if !resumed { resumed = true; await self?.resumeNewIssues() }
                // Fixed rate: a tick starts every pollSeconds, however long the last one took.
                let seconds = Double(self?.config.pollSeconds ?? 60)
                try? await Task.sleep(for: .seconds(max(0, seconds - Date.now.timeIntervalSince(started))))
            }
        }
    }

    /// Validates the repo through `gh` and the clone through its `origin` before either is saved,
    /// so a typo or the wrong folder never reaches the config.
    func addRepo(_ input: String, clone: URL) async throws {
        let slug = input.trimmingCharacters(in: .whitespaces)
        guard BtonConfig.isRepoSlug(slug) else { throw RepoInputError.notASlug }
        guard let github else { throw GitHubClient.Failure.ghNotFound }
        let name = try await github.canonicalName(of: slug)
        let root = try await RepoOrigin.verify(clone: clone, matches: name)
        // Checked after the last await: another add may have finished meanwhile.
        guard !config.repos.contains(where: { $0.slug.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        try update { $0.repos.append(WatchedRepo(slug: name, path: root.path)) }
        await refresh()
    }

    /// The repo is whatever GitHub repo the folder is a clone of.
    func addFolder(_ folder: URL) async throws {
        guard let github else { throw GitHubClient.Failure.ghNotFound }
        let found = try await RepoOrigin.inspect(clone: folder)
        let name = try await github.canonicalName(of: found.slug)
        guard !config.repos.contains(where: { $0.slug.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw RepoInputError.alreadyWatched(name)
        }
        try update { $0.repos.append(WatchedRepo(slug: name, path: found.top.path)) }
        await refresh()
    }

    /// For a repo watched before clones were recorded.
    func chooseClone(_ clone: URL, for slug: String) async throws {
        let root = try await RepoOrigin.verify(clone: clone, matches: slug)
        try update { config in
            for index in config.repos.indices where config.repos[index].slug == slug { config.repos[index].path = root.path }
        }
    }

    func removeRepo(_ slug: String) throws {
        if let schedule = config.schedules.first(where: { $0.repo == slug }) {
            throw SettingsError.inUse("\(slug) is used by the schedule \(schedule.name).")
        }
        try update { $0.repos.removeAll { $0.slug == slug } }
        openPullRequests.removeAll { $0.repo == slug }
        merged.removeAll { $0.repo == slug }
    }

    /// Asks GitHub once per panel open whether to offer the star; a yes on disk skips the
    /// question for good. Never in the demo: it would run gh.
    func refreshStarOffer() async {
        guard !isDemo else { return }
        let repoStar = RepoStar(home: home)
        guard repoStar.shouldOffer() else { return }
        starOffer = await repoStar.refresh() == .notStarred
    }

    /// Stars Bton through the owner's gh. A yes takes the offer away for good; a no says so.
    func starRepo() async {
        if await RepoStar(home: home).star() {
            starOffer = false
            config.starredRepo = true
        } else {
            Notifier.post(title: "Bton", body: "Could not star it: is gh logged in?", id: "star")
        }
    }

    /// The README's footer in its offering state; nothing is asked of GitHub.
    func showStarOffer(_ on: Bool = true, starring: Bool = false) {
        starOffer = on
        demoStarring = on && starring
    }

    /// Saves first, so a change that could not be written never shows as made. Starts from the
    /// file, so an edit made outside the app (by hand, by an agent) is not saved over; a file that
    /// cannot be read stops the change rather than being replaced by the window's copy.
    func update(_ change: (inout BtonConfig) throws -> Void) throws {
        var next = try BtonConfig.loadOrCreate(home: home)
        try change(&next)
        try next.save(to: home.configURL)
        config = next
    }

    func setPollSeconds(_ seconds: Int) throws {
        try update { $0.pollSeconds = seconds.clamped(to: BtonConfig.pollSecondsRange) }
    }

    func setMaxAgents(_ count: Int) throws {
        try update { $0.maxAgents = count.clamped(to: BtonConfig.maxAgentsRange) }
    }

    /// Saves an agent under `name`, renaming it from `previous` and the schedules that use it.
    func saveAgent(_ name: String, argv: [String], replacing previous: String?) throws {
        guard BtonConfig.isAgentName(name) else { throw SettingsError.invalid("Name the agent in lowercase letters, digits and dashes.") }
        if let previous, previous != name, let repo = flowUsing(previous) {
            throw SettingsError.inUse("\(repo)'s flow starts \(previous) by that name, so it keeps it.")
        }
        let template = AgentTemplate(argv: argv)
        if let problem = template.problem { throw SettingsError.invalid(problem) }
        if name != previous, config.agents[name] != nil { throw SettingsError.invalid("An agent is already called \(name).") }
        try update { config in
            if let previous, previous != name {
                config.agents[previous] = nil
                for index in config.schedules.indices where config.schedules[index].agent == previous {
                    config.schedules[index].agent = name
                }
            }
            config.agents[name] = template
        }
    }

    func removeAgent(_ name: String) throws {
        if let schedule = config.schedules.first(where: { $0.agent == name }) {
            throw SettingsError.inUse("\(name) runs the schedule \(schedule.name).")
        }
        if let repo = flowUsing(name) { throw SettingsError.inUse("\(repo)'s flow starts \(name).") }
        try update { $0.agents[name] = nil }
    }

    /// Adds the schedule, or replaces the one with its number.
    func saveSchedule(_ entry: ScheduleEntry) throws {
        var entry = entry
        entry.name = entry.name.trimmingCharacters(in: .whitespaces)
        // Checked and numbered against the file as it is now, so a schedule added elsewhere since
        // the last sync is neither reused nor replaced.
        try update { config in
            if entry.number == nil { entry.number = ScheduleEntry.newNumber(avoiding: config.schedules) }
            if let problem = entry.problem(among: config.schedules, agents: config.agents) { throw SettingsError.invalid(problem) }
            // The engine dispatches nothing in a repo without a clone, so such a schedule would never run.
            guard config.repos.contains(where: { $0.slug == entry.repo && $0.path != nil }) else {
                throw SettingsError.invalid("Choose the folder of \(entry.repo ?? "the repo") under Repos first.")
            }
            if let index = config.schedules.firstIndex(where: { $0.number == entry.number }) {
                config.schedules[index] = entry
            } else {
                config.schedules.append(entry)
            }
        }
    }

    func removeSchedule(_ number: Int?) throws {
        try update { $0.schedules.removeAll { $0.number == number } }
    }

    func setSchedule(_ number: Int?, enabled: Bool) throws {
        try update { config in
            for index in config.schedules.indices where config.schedules[index].number == number {
                config.schedules[index].enabled = enabled
            }
        }
    }

    /// Only the owner's own rows; the feed's are replaced at each refresh.
    func saveCustomPrices(_ custom: [String: ModelPrice]) throws {
        prices = try PriceList.update(home: home) { $0.custom = custom.isEmpty ? nil : custom }
    }

    func refreshPrices() async throws {
        prices = try await PriceFeed.refresh(home: home)
        await refresh()
    }

    /// The newest job a schedule started.
    func lastJob(of entry: ScheduleEntry) -> Job? {
        guard let item = entry.item, let repo = entry.repo else { return nil }
        return jobs.first { $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame && $0.key.item == item }
    }

    /// A watched repo whose flow names the agent: a flow cannot be edited here, so its agents stay.
    private func flowUsing(_ agent: String) -> String? {
        config.repos.first { repo in
            rules(of: flows[repo.slug]).contains { $0.agent?.allValues.contains(agent) == true }
        }?.slug
    }

    private func rules(of status: FlowStatus?) -> [DispatchRule] {
        status?.flow.map { Array($0.dispatch.values) } ?? []
    }

    private static func isInert(_ entry: ScheduleEntry) -> Bool {
        entry.repo == nil && entry.agent == nil && entry.prompt == nil
    }

    func stop(_ job: Job) async {
        await engine?.stop(job.id)
        await refresh()
    }

    func canRetry(_ job: Job) -> Bool { job.canRetry(among: jobs) }

    /// The move runs again on the same head, once the cause of the failure is fixed.
    /// Starts a ready issue's work now: the next sync claims it and runs the agent, first in line.
    func take(_ issue: ReadyIssue) async {
        markStarting(repo: issue.repo, item: "issue-\(issue.number)")
        await engine?.takeIssue(repo: issue.repo, number: issue.number)
        await refresh()
    }

    func retry(_ job: Job) async {
        guard (try? await engine?.retry(job.id)) == true else { return }
        markStarting(repo: job.key.repo, item: job.key.item)
        await refresh()
    }

    /// The job's output and error log, in TextEdit: nothing opens a `.out` file by default.
    /// Shows the repo's page over the lists, closing whatever else was over them.
    func openRepoPage(_ slug: String) {
        withAnimation(Motion.spring) {
            watchingJob = nil
            readingDraft = nil
            viewingIssue = nil
            triaging = nil
            composing = nil
            viewingRepo = slug
        }
    }

    func openLogs(of job: Job) {
        let files = outputFiles(of: job).filter(Self.hasContent)
        guard !files.isEmpty, let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit")
        else { return }
        NSWorkspace.shared.open(files, withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
    }

    /// A job that failed before its agent started wrote neither file; an empty one isn't shown.
    func hasLogs(of job: Job) -> Bool {
        outputFiles(of: job).contains(where: Self.hasContent)
    }

    private static func hasContent(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int ?? 0) > 0
    }

    /// The transcript Claude Code writes while the job's agent works; nil for other agents.
    func sessionFile(of job: Job) -> URL? {
        ClaudeSessions.sessionFile(id: job.id)
    }

    /// Whether the job's agent is Claude Code, which can reopen a session by its id.
    func isClaude(_ job: Job) -> Bool {
        job.agent.flatMap { config.agents[$0]?.argv.first }.map(AgentHardening.isClaude) ?? false
    }

    /// The finished session, reopened in Terminal where it ran, to read all of it or carry on.
    /// A `.command` file, so Terminal runs it without asking for control of another app.
    func resumeInTerminal(_ job: Job) throws {
        guard let worktree = job.worktree else { return }
        let quoted = "'" + worktree.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\ncd \(quoted) || exit 1\nexec claude --resume \(job.id.uuidString.lowercased())\n"
        guard let jobStore else { throw CocoaError(.fileNoSuchFile) }
        let url = jobStore.logURL(job.id).deletingPathExtension().appendingPathExtension("command")
        try Data(script.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }

    /// The job's output (the agent's final message) and its log (Bton's account and the agent's errors).
    func outputFiles(of job: Job) -> [URL] {
        guard let jobStore else { return [] }
        return [jobStore.outputURL(job.id), jobStore.logURL(job.id)]
    }

    /// One engine tick: read every repo, dispatch this Mac's moves, publish the result.
    /// The repo's labels for the Triage tab's picker: today's from `labels.json`, else GitHub's,
    /// remembered for a day.
    func repoLabels(_ repo: String) async throws -> [RepoLabel] {
        let now = Date()
        if let fresh = RepoLabels.load(home: home).fresh(repo, now: now) { return fresh }
        guard let github else { throw CocoaError(.fileNoSuchFile) }
        let labels = try await github.repoLabels(repo: repo)
        try? RepoLabels.remember(labels, repo: repo, now: now, home: home)
        return labels
    }

    /// The label edit on its way to GitHub for an issue of the Triage tab, by issue id: its chips
    /// spin on the issue's page, and a second edit or Apply on the same issue waits for it. Owned
    /// here, not by the page, so an edit outlives a page closed and reopened under it.
    private(set) var labelEdits: [String: PendingLabels] = [:]

    struct PendingLabels: Hashable {
        let add: [String]
        let remove: [String]
    }

    /// One label edit on an issue of the Triage tab, posted to GitHub and then shown on its row
    /// and its open page. An issue the edit settles (stage:ready) leaves the tab at once, its
    /// page closes, and a sync follows. Nothing is sent while another edit of the issue is out.
    func editLabels(_ edit: (add: [String], remove: [String]), on issue: TriageIssue) async throws {
        guard labelEdits[issue.id] == nil else { return }
        labelEdits[issue.id] = PendingLabels(add: edit.add, remove: edit.remove)
        defer { labelEdits[issue.id] = nil }
        guard let github else { throw CocoaError(.fileNoSuchFile) }
        try await github.editIssueLabels(add: edit.add, remove: edit.remove, repo: issue.repo, number: issue.number)
        let changed = issue.with(labels: RepoLabels.apply(edit, to: issue.labels))
        if changed.isSettled {
            triage.removeAll { $0.id == issue.id }
            if triaging?.id == issue.id { withAnimation(Motion.spring) { triaging = nil } }
            await refresh()
        } else {
            triage = IssueTriage.ordered(triage.map { $0.id == issue.id ? changed : $0 })
            if triaging?.id == issue.id { triaging = changed }
        }
    }

    func refresh() async {
        guard !isRefreshing else {
            refreshAgain = true
            return
        }
        repeat {
            refreshAgain = false
            await tick()
        } while refreshAgain
    }

    /// Starts a PR's move or a schedule before anything else, as soon as its repo is free.
    func runNext(repo: String, item: String) async {
        markStarting(repo: repo, item: item)
        await engine?.runNext(repo: repo, item: item, pressed: true)
        await refresh()
    }

    /// Starts the repo's registry job before anything else: the page's Build the registry.
    func buildRegistry(_ slug: String) async { await runNext(repo: slug, item: FeatureJob.item) }

    /// Whether the repo's code graph is there for the registry job; nil for a repo not watched.
    func graphReadiness(_ slug: String) -> CodeGraph.Readiness? {
        config.repos.first { $0.slug.caseInsensitiveCompare(slug) == .orderedSame }
            .map { CodeGraph.readiness(of: $0, python: CodeGraph.python(configured: graphifyPython), home: home, enabled: codeGraphs) }
    }

    /// How far the repo's graph build is; nil when none runs.
    func graphProgress(_ slug: String) -> CodeGraph.Progress? { CodeGraph.progress(in: CodeGraph.store(for: slug, home: home)) }

    /// The registry job's PR while it is open: the page shows it instead of the job's button.
    func registryPullRequest(_ slug: String) -> PullRequest? {
        me.flatMap { FeatureJob.openPullRequest(openPullRequests, repo: slug, me: $0) }
    }

    /// Starts the PR's move now, again if it failed on this head: the row's Merge and Fix conflicts.
    /// The move failed or was stopped on the PR's current head, and nothing has run it since.
    /// The move's run on this head that failed and may run again, if one did.
    func failedOnHead(_ pr: PullRequest, move: String) -> Job? {
        let key = key(for: pr, move: move)
        return jobs.first { $0.key == key }.flatMap { $0.canRetry(among: jobs) ? $0 : nil }
    }

    /// The newest job of this move on this head and round that succeeded while the move is still
    /// the PR's: its agent pushed or posted nothing, and its report says why.
    func succeededOnHead(_ pr: PullRequest, move: String) -> Job? {
        guard pr.move?.name == move else { return nil }
        let key = key(for: pr, move: move)
        return jobs.first { $0.key == key }.flatMap { $0.status == .succeeded ? $0 : nil }
    }

    /// The key a move of this PR runs under now: `DispatchPlanner.key`, with the round the flow reads.
    func key(for pr: PullRequest, move: String) -> JobKey {
        DispatchPlanner.key(for: pr, move: move, flow: flows[pr.repo]?.flow, me: me ?? "", repo: pr.repo)
    }

    func runNow(_ pr: PullRequest, move: String) async {
        markStarting(repo: pr.repo, item: "pr-\(pr.number)")
        if succeededOnHead(pr, move: move) != nil {
            try? await engine?.runAgain(key(for: pr, move: move))
        } else {
            try? await engine?.runNow(key(for: pr, move: move))
        }
        await refresh()
    }

    /// Says a label-gated move is done: the label goes on GitHub and the next sync reads the next move.
    /// A fresh read must still give me the same move with that label, so a stale popover never
    /// clears a later round's label.
    func removeLabel(_ label: String, from pr: PullRequest, move: Move) async throws {
        guard let github else { throw GitHubClient.Failure.ghNotFound }
        let branch = config.repos.first { $0.slug.caseInsensitiveCompare(pr.repo) == .orderedSame }?.branch
        let flow = Flow.load(try await github.flowFile(repo: pr.repo, branch: branch)).flow
        let read = try await github.openPullRequests(repo: pr.repo)
        guard let flow, let fresh = read.pullRequests.first(where: { $0.number == pr.number }),
              let now = FlowEngine.move(for: fresh, flow: flow), now.name == move.name,
              now.isMine(read.viewer), now.labels.contains(label)
        else { throw SettingsError.invalid("#\(pr.number) changed since the last sync; nothing was removed.") }
        try await github.removeLabel(label, repo: pr.repo, number: pr.number)
        // The row shows its next move now: the sync may wait behind a check that runs for minutes.
        // The shown row keeps its cost and working agent; only its labels and move change.
        if let index = openPullRequests.firstIndex(where: { $0.repo == pr.repo && $0.number == pr.number }) {
            var moved = fresh
            moved.labels.removeAll { $0 == label }
            openPullRequests[index].labels = moved.labels
            openPullRequests[index].move = FlowEngine.move(for: moved, flow: flow)
        }
        Task { await refresh() }
    }

    /// The running schedule job working on the PR, if any.
    func schedule(workingOn pr: PullRequest) -> Job? { schedules(workingOn: pr).first }

    /// Every running schedule whose session is on the PR now; each is a working line on its row.
    func schedules(workingOn pr: PullRequest) -> [Job] {
        jobs.filter { $0.status == .running && $0.key.repo == pr.repo && work.current[$0.id] == pr.number }
    }

    func waitingReason(repo: String, item: String) -> String? { waiting["\(repo.lowercased())#\(item)"] }
    func isNext(repo: String, item: String) -> Bool { next.contains("\(repo.lowercased())#\(item)") }

    /// The row shows "starting" at the click, not after the sync that may already be running.
    func markStarting(repo: String, item: String) {
        let pick = "\(repo.lowercased())#\(item)"
        if !next.contains(pick) { next.insert(pick, at: 0) }
    }

    private func tick() async {
        guard let engine else { return }
        // The engine reads the file every tick; the window shows the same.
        if let latest = try? BtonConfig.loadOrCreate(home: home) { config = latest }
        guard !config.repos.isEmpty else {
            problem = "No repos yet. Add a project folder in Settings."
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        defer { icon.update(mode: problem != nil ? .problem : runningJobs > 0 ? .working : .idle, synced: problem == nil) }
        let before = Before(moves: Set(humanMovesForMe.map(\.id)), jobs: jobs, merged: Set(merged.map(\.id)),
                            outages: Set(outages.keys), first: lastRefresh == nil)
        // The lists show as soon as GitHub is read; cleanup and starting jobs can take minutes.
        let snapshot = await engine.tick { read in await self.apply(read) }
        apply(snapshot)
        local.start(repos: config.repos, defaults: snapshot.defaultBranches, flows: snapshot.flows)
        notify(since: before)
    }

    /// Made-up data and no engine, for the README's screenshots (`DemoShots`).
    func showDemo(_ snapshot: Engine.Snapshot, config: BtonConfig) {
        isDemo = true
        self.config = config
        apply(snapshot)
    }

    /// Load more, pressed: each repo's extra page is read now and its rows shown as they come,
    /// without a full sync; a second press while a repo loads is nothing. A failed read leaves
    /// the list as it was, and the pill comes back for the next press.
    func loadMoreIssues(repos: [String]) async {
        guard let engine else { return }
        let repos = repos.filter { !issuesLoading.contains($0.lowercased()) }
        guard !repos.isEmpty else { return }
        issuesLoading.formUnion(repos.map { $0.lowercased() })
        defer { issuesLoading.subtract(repos.map { $0.lowercased() }) }
        for repo in repos {
            let slug = repo.lowercased()
            // A page that waited behind a later sync's snapshot is older than what is shown.
            guard let page = await engine.readMoreIssues(repo: repo), page.revision >= issueRevisions[slug] ?? 0 else { continue }
            triage = IssueTriage.ordered(triage.filter { $0.repo.lowercased() != slug } + page.triage)
            if page.more { issuesMore.insert(slug) } else { issuesMore.remove(slug) }
            issueRevisions[slug] = page.revision
        }
    }

    private func apply(_ snapshot: Engine.Snapshot) {
        flows = snapshot.flows
        me = snapshot.me ?? me
        // The engine may have refreshed the feed during the tick.
        prices = PriceList.load(home: home)
        jobs = snapshot.jobs.reversed()
        next = snapshot.next
        waiting = snapshot.waiting
        outages = snapshot.outages
        problem = snapshot.problem
        loggedOut = snapshot.loggedOut
        // A failed read keeps the last good lists rather than blanking them: every list when the
        // tick itself failed, an unread repo's own entries otherwise.
        guard snapshot.problem == nil || !snapshot.unread.isEmpty else { return }
        let unread = { (repo: String) in snapshot.unread.contains(repo.lowercased()) }
        openPullRequests = snapshot.openPullRequests + openPullRequests.filter { unread($0.repo) }
        merged = snapshot.merged + merged.filter { unread($0.repo) }
        issueAsks = snapshot.issueAsks
        // A repo that could not be read keeps its issues, like its PRs; so does one whose rows
        // here come from a later read than the snapshot's (a Load more that landed mid-sync).
        let stale = { (repo: String) -> Bool in
            let slug = repo.lowercased()
            return (snapshot.issueRevisions[slug] ?? 0) < (self.issueRevisions[slug] ?? 0)
        }
        triage = IssueTriage.ordered(snapshot.triage.filter { !stale($0.repo) } + triage.filter { unread($0.repo) || stale($0.repo) })
        issuesMore = snapshot.issuesMore.filter { !stale($0) }.union(issuesMore.filter(stale))
        issueRevisions.merge(snapshot.issueRevisions) { max($0, $1) }
        features = features.filter { unread($0.key) }.merging(snapshot.features) { _, read in read }
        // The engine keeps an unread repo's last issues in its own list, so the carried ones are not added twice.
        let readNow = Set(snapshot.ready.map(\.id))
        ready = snapshot.ready + ready.filter { unread($0.repo) && !readNow.contains($0.id) }
        lastRefresh = snapshot.at
    }
}

enum RepoInputError: Error, LocalizedError {
    case notASlug
    case alreadyWatched(String)

    var errorDescription: String? {
        switch self {
        case .notASlug: "Enter the repo as owner/name."
        case let .alreadyWatched(name): "\(name) is already watched."
        }
    }
}

enum SettingsError: Error, LocalizedError {
    case invalid(String)
    case inUse(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(text), let .inUse(text): text
        }
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", repos = "Repos", agents = "Agents", schedules = "Schedules", supervisor = "Supervisor",
         voice = "Voice", prices = "Prices", more = "More apps", about = "About"
    var id: Self { self }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
