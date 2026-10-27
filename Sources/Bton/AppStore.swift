import AppKit
import BtonCore
import Foundation
import Observation

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
    /// The PRs each schedule's agent works on, read from its session every few seconds.
    let work = ScheduleWork()
    let local = LocalSync()
    /// The job whose session the window shows in place of its list.
    var watchingJob: UUID?
    /// The issue ask whose drafted reply the window shows in place of its list.
    var readingDraft: IssueAsk?
    /// Questions put to me on open issues, newest first.
    private(set) var issueAsks: [IssueAsk] = []
    private(set) var triage: [TriageIssue] = []
    /// The issue open in the triage tab.
    var triaging: TriageIssue?
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
    var voiceSettings: VoiceSettings? { config.voice }
    var draftModel: String { config.draftModel ?? BtonConfig.defaultDraftModel }
    var pollSeconds: Int { config.pollSeconds }
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
            let engine = try Engine(home: home)
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
    func retry(_ job: Job) async {
        guard (try? await engine?.retry(job.id)) == true else { return }
        await refresh()
    }

    /// The job's output and error log, in TextEdit: nothing opens a `.out` file by default.
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

    /// Starts the PR's move now, again if it failed on this head: the row's Merge and Fix conflicts.
    /// The move failed or was stopped on the PR's current head, and nothing has run it since.
    /// The move's run on this head that failed and may run again, if one did.
    func failedOnHead(_ pr: PullRequest, move: String) -> Job? {
        let key = JobKey(repo: pr.repo, item: "pr-\(pr.number)", move: move, head: pr.headSha)
        return jobs.first { $0.key == key }.flatMap { $0.canRetry(among: jobs) ? $0 : nil }
    }

    func runNow(_ pr: PullRequest, move: String) async {
        markStarting(repo: pr.repo, item: "pr-\(pr.number)")
        try? await engine?.runNow(JobKey(repo: pr.repo, item: "pr-\(pr.number)", move: move, head: pr.headSha))
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
    func schedule(workingOn pr: PullRequest) -> Job? {
        jobs.first { $0.status == .running && $0.key.repo == pr.repo && work.current[$0.id] == pr.number }
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
                            first: lastRefresh == nil)
        // The lists show as soon as GitHub is read; cleanup and starting jobs can take minutes.
        let snapshot = await engine.tick { read in await self.apply(read) }
        apply(snapshot)
        local.start(repos: config.repos, defaults: snapshot.defaultBranches)
        notify(since: before)
    }

    /// Made-up data and no engine, for the README's screenshots (`DemoShots`).
    func showDemo(_ snapshot: Engine.Snapshot, config: BtonConfig) {
        self.config = config
        apply(snapshot)
    }

    private func apply(_ snapshot: Engine.Snapshot) {
        flows = snapshot.flows
        me = snapshot.me ?? me
        // The engine may have refreshed the feed during the tick.
        prices = PriceList.load(home: home)
        jobs = snapshot.jobs.reversed()
        next = snapshot.next
        waiting = snapshot.waiting
        problem = snapshot.problem
        loggedOut = snapshot.loggedOut
        // A failed read keeps the last good lists rather than blanking them: every list when the
        // tick itself failed, an unread repo's own entries otherwise.
        guard snapshot.problem == nil || !snapshot.unread.isEmpty else { return }
        let unread = { (repo: String) in snapshot.unread.contains(repo.lowercased()) }
        openPullRequests = snapshot.openPullRequests + openPullRequests.filter { unread($0.repo) }
        merged = snapshot.merged + merged.filter { unread($0.repo) }
        issueAsks = snapshot.issueAsks
        // A repo that could not be read keeps its issues, like its PRs.
        triage = snapshot.triage + triage.filter { unread($0.repo) }
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
         voice = "Voice", prices = "Prices", about = "About"
    var id: Self { self }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
