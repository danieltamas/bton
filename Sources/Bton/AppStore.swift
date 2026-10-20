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
    private(set) var isRefreshing = false
    /// A refresh asked for while one runs: it runs right after, never dropped.
    private var refreshAgain = false
    /// Run-next picks waiting for their repo, `owner/name#item` with the repo lowercased.
    private(set) var next: [String] = []
    /// The PR each running schedule's agent works on now, read from its session every few seconds.
    private(set) var focus: [UUID: Int] = [:]
    /// The job whose session the window shows in place of its list.
    var watchingJob: UUID?
    let icon = MenuBarIcon()
    /// Each watched repo's flow as last read from its default branch.
    private(set) var flows: [String: FlowStatus] = [:]
    /// This Mac's `gh` login; moves owned by it are "mine".
    private(set) var me: String?

    var repos: [WatchedRepo] { config.repos }
    var schedules: [ScheduleEntry] { config.schedules }
    var agents: [String: AgentTemplate] { config.agents }
    var pollSeconds: Int { config.pollSeconds }
    var maxAgents: Int { config.maxAgents }
    private(set) var prices = PriceList(models: [:])
    /// Which Settings pane opens next, and the schedule it shows.
    var settingsPane: SettingsPane = .general
    let home = BtonHome()
    /// Made once: making one prepares the home on disk, too much for every render that asks for
    /// a job's files.
    @ObservationIgnored private lazy var jobStore = try? JobStore(home: home)

    /// Moves that wait for me as a person: mine without a dispatch entry, or an unassigned move
    /// on a PR I opened.
    var humanMovesForMe: [PullRequest] {
        guard let me else { return [] }
        return openPullRequests.filter { pr in
            guard let move = pr.move else { return false }
            if let owner = move.owner { return owner.caseInsensitiveCompare(me) == .orderedSame && !move.hasDispatch }
            return pr.author.caseInsensitiveCompare(me) == .orderedSame
        }
    }

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
    private var github: GitHubClient?
    private var engine: Engine?
    private var loop: Task<Void, Never>?
    private var focusLoop: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
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
                await self?.readFocus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let started = Date.now
                await self?.refresh()
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

    /// The branch PRs merge into; empty means GitHub's default branch.
    func setBranch(_ branch: String, for slug: String) throws {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard branch.isEmpty || WatchedRepo.isBranchName(branch) else {
            throw SettingsError.invalid("\(branch) is not a branch name.")
        }
        try update { config in
            for index in config.repos.indices where config.repos[index].slug == slug {
                config.repos[index].branch = branch.isEmpty ? nil : branch
            }
        }
    }

    /// Variables the repo's checks, merge commands and agents get on this Mac, as KEY=VALUE lines.
    func setEnvironment(_ text: String, for slug: String) throws {
        let environment: [String: String]
        do { environment = try WatchedRepo.parseEnvironment(text) } catch { throw SettingsError.invalid(error.localizedDescription) }
        try update { config in
            for index in config.repos.indices where config.repos[index].slug == slug {
                config.repos[index].environment = environment.isEmpty ? nil : environment
            }
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
    private func update(_ change: (inout BtonConfig) throws -> Void) throws {
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
        await engine?.runNext(repo: repo, item: item)
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
        await refresh()
    }

    /// The running schedule job working on the PR, if any.
    func schedule(workingOn pr: PullRequest) -> Job? {
        jobs.first { $0.status == .running && $0.key.repo == pr.repo && focus[$0.id] == pr.number }
    }

    /// Off the main actor: a session file can be large, and only its tail is read.
    private func readFocus() async {
        let ids = jobs.filter { $0.status == .running && !$0.key.item.hasPrefix("pr-") }.map(\.id)
        guard !ids.isEmpty || !focus.isEmpty else { return }
        let read = await Task.detached {
            Dictionary(uniqueKeysWithValues: ids.compactMap { id in
                ClaudeSessions.sessionFile(id: id).flatMap { SessionTranscript.currentPullRequest(ofSessionFile: $0) }.map { (id, $0) }
            })
        }.value
        if read != focus { focus = read }
    }

    func isNext(repo: String, item: String) -> Bool { next.contains("\(repo.lowercased())#\(item)") }

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
        let before = (moves: Set(humanMovesForMe.map(\.id)), jobs: jobs, merged: Set(merged.map(\.id)), first: lastRefresh == nil)
        // The lists show as soon as GitHub is read; cleanup and starting jobs can take minutes.
        let snapshot = await engine.tick { read in await self.apply(read) }
        apply(snapshot)
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
        problem = snapshot.problem
        // A failed read keeps the last good lists rather than blanking them: every list when the
        // tick itself failed, an unread repo's own entries otherwise.
        guard snapshot.problem == nil || !snapshot.unread.isEmpty else { return }
        let unread = { (repo: String) in snapshot.unread.contains(repo.lowercased()) }
        openPullRequests = snapshot.openPullRequests + openPullRequests.filter { unread($0.repo) }
        merged = snapshot.merged + merged.filter { unread($0.repo) }
        lastRefresh = snapshot.at
    }
}

extension AppStore {
    /// What changed since the last tick and concerns me: a move now waiting for me, a job that
    /// failed, my PR merged. Nothing on the first tick, which would replay the whole state.
    fileprivate func notify(since before: (moves: Set<String>, jobs: [Job], merged: Set<String>, first: Bool)) {
        guard !before.first, let me else { return }
        for pr in humanMovesForMe where !before.moves.contains(pr.id) {
            Notifier.post(title: "\(pr.move?.name ?? "Move") · #\(pr.number)", body: pr.title, id: "move-\(pr.id)")
        }
        let wasRunning = Set(before.jobs.filter { $0.status == .running }.map(\.id))
        for job in jobs where job.status == .failed && wasRunning.contains(job.id) {
            Notifier.post(title: "Job failed · \(job.key.item) \(job.key.move)", body: job.detail ?? "", id: "job-\(job.id)")
        }
        for pr in merged where !before.merged.contains(pr.id) && pr.author.caseInsensitiveCompare(me) == .orderedSame {
            Notifier.post(title: "Merged · #\(pr.number)", body: pr.title, id: "merged-\(pr.id)")
        }
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
    case general = "General", repos = "Repos", agents = "Agents", schedules = "Schedules", prices = "Prices"
    var id: Self { self }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
