import Foundation

/// One Bton instance's tick, shared by the menu bar app and `bton watch`: read every watched
/// repo, evaluate its flow, assign rotation picks, dispatch this Mac's moves, report.
public actor Engine {
    public struct Snapshot: Sendable {
        public var openPullRequests: [PullRequest] = []
        public var merged: [MergedPullRequest] = []
        public var flows: [String: FlowStatus] = [:]
        public var me: String?
        public var jobs: [Job] = []
        public var problem: String?
        public var at: Date?
        /// The owner's run-next picks still waiting, `owner/name#item`, first to start first.
        public var next: [String] = []
        /// Repos GitHub couldn't read this tick, slugs lowercased: their last lists still stand.
        public var unread: Set<String> = []
        /// Each read repo's default branch on GitHub (main), by slug.
        public var defaultBranches: [String: String] = [:]
        /// Questions put to me on open issues, newest first.
        public var issueAsks: [IssueAsk] = []
        /// Agents whose CLI login expired: none of their jobs starts until I log in again.
        public var loggedOut: [String] = []

        public init() {}
    }

    public let home: BtonHome
    let github: GitHubClient
    let jobs: JobStore
    let log: @Sendable (String) -> Void
    private var dispatcher: Dispatcher?
    /// When each labelled PR's lease was last read for the work label cleanup, by "repo#number".
    private var labelReadAt: [String: Date] = [:]
    private var assigned: Set<String> = []
    /// Stale notices posted by this instance, so one lagging read never posts one twice.
    private var noticed: Set<String> = []
    /// A failed price refresh waits an hour, not one tick, before the next try.
    private var lastPriceAttempt: Date?
    private var lastPrune: Date?
    private var jobEnded: (@Sendable () -> Void)?
    /// Run-next picks, `owner/name#item` lowercased repo, the latest pick first. A pick stays until
    /// it starts (its repo may be busy), or until a tick finds nothing of it to run.
    private var next: [String] = []
    /// The owner's Merge and Fix conflicts picks, with the head each was asked on: the PR takes that
    /// move instead of its flow move, and a new head drops the pick, so nothing runs on a head the
    /// owner did not see.
    private var asked: [String: JobKey] = [:]
    /// Automatic resolves a lease refused, and when: another Mac holds or ran that head, so the flow's
    /// move goes on for a while before the resolve is tried again.
    private var declined: [JobKey: Date] = [:]
    /// Steered retries are put back in line once, at the first tick after a start.
    var restoredRetries = false
    /// Each repo's open issues as last read, by lowercased slug: a failed read keeps the last.
    var openIssues: [String: [OpenIssue]] = [:]
    /// The repos whose issues this tick read: only a current thread starts a draft.
    var issuesReadThisTick: Set<String> = []
    /// The asks the owner pressed Draft reply on, until their job starts or the ask is gone.
    var draftRequests: [IssueAsk] = []
    /// When each merged PR's leftover worktrees were last looked at: a tree someone was still in
    /// is tried again an hour later.
    private var cleaned: [String: Date] = [:]

    public init(home: BtonHome = BtonHome(), log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try self.init(home: home, github: GitHubClient(), log: log)
    }

    init(home: BtonHome, github: GitHubClient, log: @escaping @Sendable (String) -> Void) throws {
        self.home = home
        self.github = github
        jobs = try JobStore(home: home)
        self.log = log
    }

    public func onJobEnded(_ handler: @escaping @Sendable () -> Void) async {
        jobEnded = handler
        await dispatcher?.onJobEnded(handler)
    }

    /// Puts a PR's move or a schedule first in line; a schedule runs whether or not it is due.
    public func runNext(repo: String, item: String) {
        let pick = Self.pick(repo: repo, item: item)
        next.removeAll { $0 == pick }
        next.insert(pick, at: 0)
    }

    static func pick(repo: String, item: String) -> String { "\(repo.lowercased())#\(item)" }

    /// The run-next picks that stay after a tick: not started, and either still runnable or in a
    /// repo (lowercased slug in `unread`) that couldn't be read this time.
    static func keptPicks(_ next: [String], started: Set<String>, runnable: Set<String>, unread: Set<String>) -> [String] {
        next.filter { pick in
            !started.contains(pick) && (runnable.contains(pick) || unread.contains { pick.hasPrefix($0 + "#") })
        }
    }

    /// The merged PRs with a head whose leftovers were never looked at, or not for an hour.
    static func cleanupDue(_ merged: [MergedPullRequest], tried: [String: Date], now: Date) -> [MergedPullRequest] {
        merged.filter { pr in !pr.headSha.isEmpty && tried[pr.id].map { now.timeIntervalSince($0) >= 3_600 } ?? true }
    }

    /// Each merged PR at most hourly: the worktrees it leaves go, with their branch, when nothing
    /// is left in them (`Worktrees.removeMerged`). Running jobs' trees are busy too.
    private func clearMerged(_ merged: [MergedPullRequest], clone: URL) async {
        let fresh = Self.cleanupDue(merged, tried: cleaned, now: .now)
        guard !fresh.isEmpty else { return }
        let runner = ProcessRunner()
        // Without the list of working directories a tree in use can't be told apart: try again later.
        guard let busy = await Worktrees.workingDirectories(runner: runner) else { return }
        let running = jobs.all().filter { $0.status == .running }.compactMap(\.worktree)
        for pr in fresh {
            cleaned[pr.id] = .now
            for path in await Worktrees.removeMerged(pr, clone: clone, busy: busy + running, ghPath: github.ghPath, runner: runner) {
                log("\(pr.id): removed the merged PR's worktree \(path)")
            }
        }
    }

    /// `dispatching: false` reads and reports only. `onRead` gets every repo's lists as soon as
    /// they are read, before cleanup and dispatch, which can take minutes.
    public func tick(dispatching: Bool = true, onRead: (@Sendable (Snapshot) async -> Void)? = nil) async -> Snapshot {
        var snapshot = Snapshot()
        // A pick made while this tick awaits GitHub is the next tick's to judge.
        let picksAtStart = Set(next)
        if dispatching, lastPrune.map({ Date.now.timeIntervalSince($0) >= 86_400 }) ?? true {
            lastPrune = .now
            let cleared = jobs.prune()
            if cleared > 0 { log("jobs: removed the logs of \(cleared) jobs older than \(JobStore.keepDays) days") }
        }
        do {
            // Read every tick: the app's Repos panel and a hand edit both change it.
            let config = try BtonConfig.loadOrCreate(home: home)
            // Every repo is read before anything starts, so the agents go where the work is.
            var reads: [(repo: WatchedRepo, flow: Flow?, viewer: String, defaultBranch: String,
                         pullRequests: [PullRequest], merged: [MergedPullRequest])] = []
            var failures: [String] = [], unread: Set<String> = []
            issuesReadThisTick = []
            for repo in config.repos {
                // One repo GitHub won't read leaves the others' work to start.
                do {
                    let status = Flow.load(try await github.flowFile(repo: repo.slug, branch: repo.branch))
                    snapshot.flows[repo.slug] = status
                    let read = try await github.openPullRequests(repo: repo.slug)
                    snapshot.me = read.viewer
                    let pullRequests = read.pullRequests.map { pr in
                        var pr = pr
                        pr.move = status.flow.flatMap { FlowEngine.move(for: pr, flow: $0) }
                        return pr
                    }
                    let merged = try await github.mergedPullRequests(repo: repo.slug)
                    // A repo's lists land together or not at all: a half-read repo counts as unread.
                    snapshot.openPullRequests += pullRequests
                    snapshot.merged += merged
                    snapshot.defaultBranches[repo.slug] = read.defaultBranch
                    reads.append((repo, status.flow, read.viewer, read.defaultBranch, pullRequests, merged))
                    await readIssues(repo.slug)
                } catch {
                    failures.append("\(repo.slug): \(error.localizedDescription)")
                    unread.insert(repo.slug.lowercased())
                }
            }
            snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            snapshot.unread = unread
            snapshot.issueAsks = issueAsks(in: config.repos, me: snapshot.me)
            snapshot.loggedOut = heldAgents().sorted()
            if let onRead { await onRead(decorated(snapshot)) }
            guard dispatching else { return decorated(snapshot) }
            await refreshPricesIfDue()
            applyVerdicts()
            var pending: [(candidate: DispatchCandidate, clone: URL, flow: Flow?)] = []
            // Read but not acted on: its run-next picks wait, like an unread repo's.
            var unplanned = unread
            for read in reads {
                guard let path = read.repo.path else { continue }
                let clone = URL(fileURLWithPath: path)
                do {
                    await clearMerged(read.merged, clone: clone)
                    let dispatcher = try await dispatcher(me: read.viewer, repos: config.repos)
                    await clearWorkLabels(read.pullRequests, repo: read.repo, leases: dispatcher.leases)
                    if let flow = read.flow {
                        await assignRotation(read.pullRequests, repo: read.repo.slug, me: read.viewer, dispatcher: dispatcher)
                        if let stale = flow.stale {
                            await postStaleNotices(read.pullRequests, stale: stale, repo: read.repo.slug, me: read.viewer, dispatcher: dispatcher)
                        }
                        var candidates = DispatchPlanner.candidates(read.pullRequests, flow: flow, me: read.viewer, repo: read.repo.slug)
                        for pr in read.pullRequests {
                            // An agent this Mac lacks would leave the PR with no move at all.
                            guard let chosen = override(pr, flow: flow, repo: read.repo, me: read.viewer),
                                  chosen.agent.map({ config.agents[$0] != nil }) ?? true else { continue }
                            candidates.removeAll { $0.key.item == chosen.key.item }
                            candidates.append(chosen)
                        }
                        if !read.repo.startsMoves {
                            candidates.removeAll { !next.contains(Self.pick(repo: $0.key.repo, item: $0.key.item)) }
                        }
                        pending += candidates.map { ($0, clone, flow) }
                    }
                    // Schedules need no flow: they are this Mac's own, like its agents. They start from
                    // the branch PRs merge into, which the owner picks per repo.
                    let runNow = Set(config.schedules.compactMap(\.item).filter { next.contains(Self.pick(repo: read.repo.slug, item: $0)) })
                    let changedAt = (read.pullRequests.map(\.updatedAt) + read.merged.map(\.mergedAt)).max()
                    pending += DispatchPlanner.scheduled(config.schedules, jobs: jobs.all(), repo: read.repo.slug,
                                                         defaultBranch: read.repo.branch ?? read.defaultBranch, me: read.viewer,
                                                         runNow: runNow, changedAt: changedAt)
                        .map { ($0, clone, nil) }
                    // One supervisor at a time: the first repo with a flagged job takes this tick's.
                    if !pending.contains(where: { $0.candidate.key.move == Supervision.move }),
                       let supervise = Supervision.candidate(settings: config.supervisor, agents: config.agents, jobs: jobs.all(),
                                                             repo: read.repo.slug, pullRequests: read.pullRequests,
                                                             defaultBranch: read.repo.branch ?? read.defaultBranch,
                                                             me: read.viewer, log: supervisorLog) {
                        pending.append((supervise, clone, read.flow))
                    }
                    pending += draftCandidates(repo: read.repo.slug, defaultBranch: read.repo.branch ?? read.defaultBranch,
                                               me: read.viewer, agents: config.agents).map { ($0, clone, nil) }
                } catch {
                    failures.append("\(read.repo.slug): \(error.localizedDescription)")
                    unplanned.insert(read.repo.slug.lowercased())
                }
            }
            snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            if let me = snapshot.me {
                // A move already run on its head can't start, so a pick waiting on it would wait forever.
                let seen = Set(jobs.all().filter { $0.retry != true }.map(\.key))
                let runnable = Set(pending.filter { $0.candidate.pr == nil || !seen.contains($0.candidate.key) }
                    .map { Self.pick(repo: $0.candidate.key.repo, item: $0.candidate.key.item) })
                var started: Set<String> = [], startedKeys: Set<JobKey> = [], refused: Set<JobKey> = [], ran: Set<JobKey> = []
                // A pick whose lease is held elsewhere frees its slot for the next candidate.
                while true {
                    // Read again each round: an agent may have logged out while the last round started jobs.
                    let held = heldAgents()
                    let open = pending.map(\.candidate).filter { candidate in
                        !refused.contains(candidate.key) && !(candidate.agent.map(held.contains) ?? false)
                    }
                    let selected = DispatchPlanner.select(open, jobs: jobs.all(), maxAgents: config.maxAgents,
                                                          agents: config.agents, first: next)
                    guard !selected.isEmpty else { break }
                    let dispatcher = try await dispatcher(me: me, repos: config.repos)
                    for chosen in selected {
                        guard let entry = pending.first(where: { $0.candidate.key == chosen.key }) else { continue }
                        if let agent = chosen.agent, heldAgents().contains(agent) {
                            refused.insert(chosen.key)
                            continue
                        }
                        let candidate = Supervision.steered(chosen, jobs: jobs.all())
                        let environment = config.repos.first { $0.slug.lowercased() == candidate.key.repo.lowercased() }?.environment ?? [:]
                        switch await dispatcher.dispatch(candidate, clone: entry.clone, flow: entry.flow, agents: config.agents,
                                                         environment: environment) {
                        case .started:
                            started.insert(Self.pick(repo: candidate.key.repo, item: candidate.key.item))
                            startedKeys.insert(candidate.key)
                        case .busy: refused.insert(candidate.key)
                        case .ran: refused.insert(candidate.key); ran.insert(candidate.key)
                        }
                    }
                }
                // A pick whose move already ran elsewhere would wait forever, or hand its place to another move.
                let ranPicks = Set(ran.map { Self.pick(repo: $0.repo, item: $0.item) })
                for pick in started { asked[pick] = nil }
                // Only the ask that ran: a newer one on the same issue, asked meanwhile, stays.
                let drafted = startedKeys.union(ran)
                draftRequests.removeAll { drafted.contains(IssueDrafts.key(for: $0)) }
                next.removeAll { ranPicks.contains($0) }
                let kept = Set(Self.keptPicks(next, started: started, runnable: runnable, unread: unplanned))
                next.removeAll { picksAtStart.contains($0) && !kept.contains($0) }
                // A request whose lease history says it already ran elsewhere would hold the PR's flow move
                // back; one whose lease is only held now (a schedule's agent on the PR) waits for it.
                asked = asked.filter { next.contains($0.key) && !ran.contains($0.value) }
                for key in refused where key.move == "resolve" { declined[key] = .now }
                declined = declined.filter { $0.value > .now.addingTimeInterval(-900) }
            }
        } catch {
            snapshot.problem = error.localizedDescription
        }
        return decorated(snapshot)
    }

    /// The snapshot with this Mac's jobs, picks and costs, newest first.
    private func decorated(_ read: Snapshot) -> Snapshot {
        var snapshot = read
        snapshot.jobs = jobs.all()
        snapshot.next = next
        snapshot.openPullRequests = snapshot.openPullRequests.map { pr in
            var pr = pr
            pr.cost = Self.total(of: snapshot.jobs, repo: pr.repo, number: pr.number)
            pr.isWorking = snapshot.jobs.contains { $0.status == .running && $0.key.repo == pr.repo && $0.key.item == "pr-\(pr.number)" }
            return pr
        }
        snapshot.merged = snapshot.merged.map { merged in
            var merged = merged
            merged.totalCost = Self.total(of: snapshot.jobs, repo: merged.repo, number: merged.number)
            return merged
        }
        snapshot.openPullRequests.sort { $0.updatedAt > $1.updatedAt }
        snapshot.merged.sort { $0.mergedAt > $1.mergedAt }
        snapshot.at = .now
        return snapshot
    }

    /// Stops a job this instance runs and releases its lease.
    public func stop(_ id: UUID) async {
        await dispatcher?.stop(id)
    }

    /// Runs a failed or stopped PR move again on its head, or an issue draft on its comment, first in line.
    public func retry(_ id: UUID) throws -> Bool {
        guard let job = jobs.all().first(where: { $0.id == id }), try jobs.requestRetry(id) else { return false }
        runNext(repo: job.key.repo, item: job.key.item)
        ask(job.key)
        return true
    }

    func heldAgents() -> Set<String> {
        AgentLogins.held(jobs: jobs.all(), loggedInAt: AgentLogins.load(home: home))
    }

    /// I logged the agent in again: its jobs start from the next sync.
    public func markLoggedIn(_ agent: String) throws {
        try AgentLogins.markLoggedIn(agent, at: .now, home: home)
    }

    /// Starts a PR's move now (the panel's Merge and Fix conflicts): first in line, and again
    /// when it failed or was stopped on this head. A `merge` key merges whatever the flow's move.
    public func runNow(_ key: JobKey) throws {
        let all = jobs.all()
        if let ended = all.last(where: { $0.key == key && $0.canRetry(among: all) }) { _ = try jobs.requestRetry(ended.id) }
        runNext(repo: key.repo, item: key.item)
        ask(key)
    }

    /// A Merge or Fix conflicts runs instead of the PR's flow move, also when retried from Jobs.
    func ask(_ key: JobKey) {
        if key.move == "merge" || key.move == "resolve" { asked[Self.pick(repo: key.repo, item: key.item)] = key }
    }

    /// What runs on a PR instead of its flow move: the owner's Merge or Fix conflicts on the head they
    /// saw, or else, where the sync starts moves, Bton's own resolve on a PR of mine that conflicts, once per head.
    private func override(_ pr: PullRequest, flow: Flow, repo: WatchedRepo, me: String) -> DispatchCandidate? {
        let pick = Self.pick(repo: repo.slug, item: "pr-\(pr.number)")
        let all = jobs.all()
        let fresh = { (c: DispatchCandidate) in !all.contains { $0.key == c.key } || DispatchPlanner.isRetry(c.key, jobs: all) }
        if let request = asked[pick] {
            // The flow's own move needs no override (a reviewer's merge on a teammate's PR): its
            // candidate runs, first in line. The request stays, pinning the head, until it starts.
            if request.head == pr.headSha, request.move == pr.move?.name { return nil }
            let made = request.head != pr.headSha ? nil : request.move == "merge"
                ? DispatchPlanner.mergeCandidate(pr, flow: flow, me: me, repo: repo.slug)
                : DispatchPlanner.resolveCandidate(pr, flow: flow, me: me, repo: repo.slug)
            // A new head, a PR that can't take the move any more, or a move already run on this head
            // ends it, and its place in line: the owner asked for that move, not whatever comes next.
            if let made, fresh(made) { return made }
            let why = request.head != pr.headSha ? "the head moved" : made == nil ? "the PR cannot take it now" : "it already ran on this head"
            log("\(repo.slug)#\(pr.number): \(request.move) not started: \(why)")
            asked[pick] = nil
            next.removeAll { $0 == pick }
        }
        guard repo.startsMoves, repo.resolvesConflicts, let resolve = DispatchPlanner.resolveCandidate(pr, flow: flow, me: me, repo: repo.slug),
              fresh(resolve), declined[resolve.key] == nil else { return nil }
        return resolve
    }

    /// A PR's jobs' cost; nil when it has none or one of them has no price yet.
    public static func total(of jobs: [Job], repo: String, number: Int) -> Decimal? {
        let mine = jobs.filter { $0.key.repo == repo && $0.key.item == "pr-\(number)" }
        guard !mine.isEmpty else { return nil }
        var sum: Decimal = 0
        for job in mine {
            if let cost = job.cost { sum += cost } else if !job.usage.isEmpty { return nil }
        }
        return sum
    }

    private func refreshPricesIfDue() async {
        guard PriceFeed.isStale(PriceList.load(home: home)),
              lastPriceAttempt.map({ Date.now.timeIntervalSince($0) >= 3_600 }) ?? true else { return }
        lastPriceAttempt = .now
        do {
            let list = try await PriceFeed.refresh(home: home)
            log("prices: \(list.models.count) models from \(PriceFeed.source)")
        } catch {
            log("prices: \(error.localizedDescription)")
        }
    }

    /// A label whose holder crashed or lost its lease comes off once the lease is free or gone. The
    /// PRs read longest ago go first, so ten held ones never hide the rest. A lease claimed while
    /// this ran gets its label back.
    private func clearWorkLabels(_ prs: [PullRequest], repo: WatchedRepo, leases: LeaseStore) async {
        guard let label = repo.workLabel else { return }
        let oldestFirst = prs.filter { $0.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
            .sorted { lastRead(repo.slug, $0.number) < lastRead(repo.slug, $1.number) }
        for pr in oldestFirst.prefix(WorkLabels.maxReadsPerSync) { labelReadAt[Self.labelKey(repo.slug, pr.number)] = .now }
        let state = { (number: Int) async throws -> LeaseState in
            guard let item = LeaseItem("pr-\(number)") else { throw LeaseError.failed("pr-\(number) is not a lease item") }
            return try await leases.state(of: item, in: repo.slug)
        }
        for number in await WorkLabels.stale(oldestFirst, label: label, state: state) {
            guard let item = LeaseItem("pr-\(number)") else { continue }
            let pr = Self.labelKey(repo.slug, number)
            let note = { [log] (text: String) in log("\(pr): \(text)") }
            await WorkLabels.set(false, label: label, item: item, repo: repo.slug, github: github, note: note)
            if case .held? = try? await state(number) {
                await WorkLabels.set(true, label: label, item: item, repo: repo.slug, github: github, note: note)
            }
        }
    }

    private static func labelKey(_ repo: String, _ number: Int) -> String { "\(repo)#\(number)" }
    private func lastRead(_ repo: String, _ number: Int) -> Date { labelReadAt[Self.labelKey(repo, number)] ?? .distantPast }

    func dispatcher(me: String, repos: [WatchedRepo]) async throws -> Dispatcher {
        if let dispatcher {
            await dispatcher.useRepos(repos)
            return dispatcher
        }
        let leases = try LeaseStore(home: home, holder: me, github: github)
        let made = Dispatcher(github: github, leases: leases, jobs: jobs, log: log)
        if let jobEnded { await made.onJobEnded(jobEnded) }
        // Before adopting: a job that ended while Bton was down posts its review at once.
        await made.useRepos(repos)
        await made.adopt()
        dispatcher = made
        return made
    }

    /// The author's Bton assigns the rotation's pick, under the PR's lease, once.
    private func assignRotation(_ pullRequests: [PullRequest], repo: String, me: String, dispatcher: Dispatcher) async {
        for pr in pullRequests {
            guard let move = pr.move, move.ownerFromRotation, let owner = move.owner,
                  pr.author.caseInsensitiveCompare(me) == .orderedSame, let item = LeaseItem("pr-\(pr.number)"),
                  assigned.insert("\(repo)#\(pr.number)").inserted else { continue }
            guard case let .claimed(lease)? = try? await dispatcher.leases.claim(item, in: repo) else {
                assigned.remove("\(repo)#\(pr.number)")
                continue
            }
            do {
                try await github.addAssignee(owner, repo: repo, number: pr.number)
                log("\(repo)#\(pr.number): assigned \(owner) (rotation)")
            } catch {
                assigned.remove("\(repo)#\(pr.number)")
                log("\(repo)#\(pr.number): could not assign \(owner): \(error.localizedDescription)")
            }
            try? await dispatcher.leases.release(lease)
        }
    }

    /// The author's Bton posts a PR's stale notices, under the PR's lease: while a job holds
    /// it, the move is being worked on anyway.
    private func postStaleNotices(_ pullRequests: [PullRequest], stale: Stale, repo: String, me: String,
                                  dispatcher: Dispatcher) async {
        for pr in pullRequests where pr.author.caseInsensitiveCompare(me) == .orderedSame {
            guard let notice = Staleness.notice(for: pr, stale: stale), let item = LeaseItem("pr-\(pr.number)"),
                  noticed.insert("\(repo)#\(pr.number) \(notice.marker)").inserted else { continue }
            guard case let .claimed(lease)? = try? await dispatcher.leases.claim(item, in: repo) else {
                noticed.remove("\(repo)#\(pr.number) \(notice.marker)")
                continue
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
            do {
                try notice.body.write(to: file, atomically: true, encoding: .utf8)
                try await github.comment(repo: repo, number: pr.number, bodyFile: file)
                log("\(repo)#\(pr.number): posted \(notice.marker)")
            } catch {
                noticed.remove("\(repo)#\(pr.number) \(notice.marker)")
                log("\(repo)#\(pr.number): could not post \(notice.marker): \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: file)
            try? await dispatcher.leases.release(lease)
        }
    }
}
