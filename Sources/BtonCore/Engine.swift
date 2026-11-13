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
        /// The Pause switch is on: nothing was read or started, and the lists are not this tick's.
        public var paused = false
        /// The owner's run-next picks still waiting, `owner/name#item`, first to start first.
        public var next: [String] = []
        /// Why a pick in `next` has not started yet, by pick: what the last sync found.
        public var waiting: [String: String] = [:]
        /// Repos GitHub couldn't read this tick, slugs lowercased: their last lists still stand.
        public var unread: Set<String> = []
        /// Repos whose jobs wait because a service their environment names does not answer, slugs
        /// lowercased, with the reason (`EnvironmentProbe.hold`).
        public var outages: [String: String] = [:]
        /// Each read repo's default branch on GitHub (main), by slug.
        public var defaultBranches: [String: String] = [:]
        /// Questions put to me on open issues, newest first.
        public var issueAsks: [IssueAsk] = []
        /// Open issues waiting for a priority and a stage.
        public var triage: [TriageIssue] = []
        /// Repos (slugs lowercased) with open issues beyond the pages read: Load more fetches the next.
        public var issuesMore: Set<String> = []
        /// The issue read each repo's rows here come from, by lowercased slug: the store keeps rows
        /// from a later read over these.
        public var issueRevisions: [String: Int] = [:]
        /// Open issues at `stage:ready`, taken or not.
        public var ready: [ReadyIssue] = []
        /// Agents whose CLI login expired: none of their jobs starts until I log in again.
        public var loggedOut: [String] = []
        /// Each read repo's feature registry with every feature's standing, by slug.
        public var features: [String: FeatureReport] = [:]
        /// Checks seen red then green on one commit this tick (`Flakes`).
        public var flakes: [Flake] = []
        /// When the PR and merged lists were read from GitHub, which can be long before the snapshot
        /// ends: a window that already holds a later read keeps it (`readLists`).
        public var listsAt: Date?

        public init() {}
    }

    public let home: BtonHome
    let github: GitHubClient
    let jobs: JobStore
    let log: @Sendable (String) -> Void
    /// Each watched repo's code graph, rebuilt after a sync when its branch moved.
    let graphs: CodeGraphBuilder
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
    var next: [String] = []
    /// Issues the owner pressed Take on, by lowercased repo: taken at the next sync even where the repo does not start its moves.
    private var taken: [String: Int] = [:]
    /// The picks in `next` a person pressed, until one of their moves starts.
    var pressedPicks: Set<String> = []
    /// Pressed picks whose press a supervisor's retry carried over from the job it retries: they keep
    /// `BTON_PRESSED`, but no person asked for them now, so a watching session's mark still holds them.
    var inheritedPresses: Set<String> = []
    /// The owner's Merge and Fix conflicts picks, with the head each was asked on: the PR takes that
    /// move instead of its flow move, and a new head drops the pick, so nothing runs on a head the
    /// owner did not see.
    private var asked: [String: JobKey] = [:]
    /// Automatic resolves a lease refused, and when: another Mac holds or ran that head, so the flow's
    /// move goes on for a while before the resolve is tried again.
    private var declined: [JobKey: Date] = [:]
    /// Moves already logged as left to a watching session, so the log says it once per head.
    private var heldNoted: Set<JobKey> = []
    /// The PRs (picks) whose due move this tick left to a watching session, for their rows.
    private var heldThisTick: Set<String> = []
    /// Steered retries are put back in line once, at the first tick after a start.
    var restoredRetries = false
    /// Each repo's open issues as last read, by lowercased slug: a failed read keeps the last.
    var openIssues: [String: [OpenIssue]] = [:]
    /// How many pages of 50 each repo's issue read fetches (Load more adds one), by lowercased slug.
    var issuePages: [String: Int] = [:]
    /// The repos whose last issue read ended with a next page still unread.
    var issuesMore: Set<String> = []
    /// Each repo's issue reads so far, by lowercased slug: a read commits only while it is the
    /// latest started, so a sync's older read never lands over a Load more that finished first.
    var issueRevisions: [String: Int] = [:]
    /// What each issue's timeline said when it was last read on its own (a page of 50 cuts a long
    /// timeline to its oldest events), kept while GitHub's `updatedAt` for the issue is the same:
    /// by lowercased slug, then number.
    var wholeReads: [String: [Int: WholeRead]] = [:]
    /// The repos whose issues this tick read: only a current thread starts a draft.
    var issuesReadThisTick: Set<String> = []
    /// Issue-move keys another Mac ran (the lease history said so when this Mac tried): without
    /// this, the same issue would be the repo's first candidate every sync and none behind it would start.
    var issueMovesRanElsewhere: Set<JobKey> = []
    /// Each repo's issue read in flight, by lowercased slug, with the page count it asked for: a
    /// second caller waits for it instead of racing it (a Load more during a sync's read, or the reverse).
    var issueReads: [String: (id: UUID, pages: Int, task: Task<Bool, Never>)] = [:]
    /// Label edits made here, by lowercased slug, until a read that started after each one lands:
    /// a read in flight at the edit would otherwise put the old labels back (lexito.ro #19, 2026-11-03).
    var labelEdits: [String: [LabelEdit]] = [:]
    /// The last tick waited on GitHub's quota; the last quota read failed. For the log lines.
    private var rateLimited = false, rateLimitUnread = false
    /// The asks the owner pressed Draft reply on, until their job starts or the ask is gone.
    var draftRequests: [IssueAsk] = []
    var composeRequests: [NewIssues.Request] = []
    /// When each merged PR's leftover worktrees were last looked at: a tree someone was still in
    /// is tried again an hour later.
    private var cleaned: [String: Date] = [:]
    /// The PR, owner and head an automatic Take it already tried: it never retries, or fights a
    /// teammate who takes the PR back, until the owner or the head changes.
    var autoTaken: Set<String> = []
    /// Why each waiting pick did not start at the last sync.
    private var waiting: [String: String] = [:]
    /// Run-next picks this tick could not plan yet, with why: they stay in line, unlike a pick
    /// whose move no longer exists.
    var deferred: [String: String] = [:]
    /// Each repo's registry facts between syncs, by lowercased slug.
    var featureStates: [String: FeatureState] = [:]
    /// What the last sync read of each repo, by lowercased slug: a New issue turn starts from it
    /// while it is under one poll old (`composeTick`), instead of reading GitHub again.
    var lastReads: [String: RepoRead] = [:]
    /// The ETag of each repo's open-PR list at the last probe, by lowercased slug (`listsChanged`).
    var pullTags: [String: String] = [:]
    /// Tags seen at a probe that found a change, kept until `readLists` reads that repo.
    var pendingTags: [String: String] = [:]
    var readingLists = false
    /// Each repo's check states at the last read, by lowercased slug then head and check name: a
    /// check red there and green now on the same head is a flake (`Flakes.flips`).
    var checkStates: [String: [String: [String: CheckResult.State]]] = [:]
    /// When each repo's open issues were last read in full, and how many pages, by lowercased slug.
    var lastIssueReads: [String: (at: Date, pages: Int)] = [:]
    /// The environment holds the last sync found, by lowercased slug: a quick tick shows them
    /// again, since it probes only the repos it starts a turn in.
    var outages: [String: String] = [:]
    /// The held builds whose issue already says it waits (`noticeHeldBuilds`), by job id.
    var heldNoticed: Set<UUID> = []

    /// One repo as a sync read it, in the order the tick needs it.
    struct RepoRead {
        var repo: WatchedRepo
        let status: FlowStatus
        let viewer: String
        let defaultBranch: String
        let pullRequests: [PullRequest]
        let merged: [MergedPullRequest]
        let at: Date
        var flow: Flow? { status.flow }
    }

    public init(home: BtonHome = BtonHome(), log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        try self.init(home: home, github: GitHubClient(), log: log)
    }

    init(home: BtonHome, github: GitHubClient, log: @escaping @Sendable (String) -> Void) throws {
        self.home = home
        self.github = github
        // Only a press sets it, per run: one inherited from whoever launched Bton would mark every start.
        unsetenv("BTON_PRESSED")
        jobs = try JobStore(home: home)
        self.log = log
        graphs = CodeGraphBuilder(home: home, jobs: jobs, log: log)
    }

    /// Awaits the code graph builds a tick started; tests only.
    public func waitForGraphBuilds() async { await graphs.waitForBuilds() }

    public func onJobEnded(_ handler: @escaping @Sendable () -> Void) async {
        jobEnded = handler
        await dispatcher?.onJobEnded(handler)
    }

    /// Puts a PR's move or a schedule first in line; a schedule runs whether or not it is due.
    /// `pressed`: a person asked for it, so its checks and command get `BTON_PRESSED=1` once; a
    /// supervisor's retry is only put first. `inherited`: the press is the retried job's, carried over.
    public func runNext(repo: String, item: String, pressed: Bool = false, inherited: Bool = false) {
        let pick = Self.pick(repo: repo, item: item)
        next.removeAll { $0 == pick }
        next.insert(pick, at: 0)
        if pressed {
            // A person's press still waiting in line stays theirs when a retry carries one over.
            if !inherited {
                inheritedPresses.remove(pick)
            } else if !pressedPicks.contains(pick) {
                inheritedPresses.insert(pick)
            }
            pressedPicks.insert(pick)
        }
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

    /// The running reviews of a head the PR no longer has: a push during the review makes it
    /// nobody's, and every minute it runs on is paid for nothing. A fix moves the head itself and
    /// is not one; a PR the sync did not read says nothing about its reviews.
    static func staleReviews(_ jobs: [Job], pullRequests: [PullRequest]) -> [Job] {
        jobs.filter { job in
            guard job.status == .running, job.review != nil, let pr = Self.pullRequest(of: job, in: pullRequests) else { return false }
            return pr.headSha != job.key.head
        }
    }

    private static func pullRequest(of job: Job, in pullRequests: [PullRequest]) -> PullRequest? {
        guard job.key.item.hasPrefix("pr-"), let number = Int(job.key.item.dropFirst("pr-".count)) else { return nil }
        return pullRequests.first { $0.number == number && $0.repo.lowercased() == job.key.repo.lowercased() }
    }

    /// Stops this Mac's reviews of a head that moved, before they post; the next sync starts the new head's.
    private func stopStaleReviews(_ pullRequests: [PullRequest], dispatcher: Dispatcher) async {
        for job in Self.staleReviews(jobs.all(), pullRequests: pullRequests) {
            let live = Self.pullRequest(of: job, in: pullRequests)?.headSha ?? ""
            let reason = DispatchPlanner.headMovedDuringReview(from: job.key.head, to: live)
            log("\(job.key.repo)#\(job.key.item): \(reason)")
            await dispatcher.stop(job.id, reason: reason)
        }
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
        deferred = [:]
        heldThisTick = []
        do {
            // Read every tick: the app's Repos panel and a hand edit both change it.
            let config = try BtonConfig.loadOrCreate(home: home)
            if dispatching, lastPrune.map({ Date.now.timeIntervalSince($0) >= 86_400 }) ?? true {
                lastPrune = .now
                housekeep(retentionDays: config.costs?.retentionDays ?? CostSettings.defaultRetentionDays)
            }
            // Paused: GitHub is not read, nothing starts, and what this Mac runs is stopped now.
            if config.isPaused {
                await pause()
                snapshot.paused = true
                return decorated(snapshot)
            }
            // Under the floor nothing is read and nothing starts; what runs keeps running, and the
            // lists are the last read's. A quota read that fails holds nothing: it is bookkeeping, not a gate.
            if let hold = await rateLimitHold(floor: config.rateFloor) {
                snapshot.problem = hold
                keptReads(into: &snapshot, config: config)
                return decorated(snapshot)
            }
            // Every repo is read before anything starts, so the agents go where the work is.
            var reads: [RepoRead] = []
            var failures: [String] = [], unread: Set<String> = []
            issuesReadThisTick = []
            let listsAt = Date.now
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
                    let kept = RepoRead(repo: repo, status: status, viewer: read.viewer, defaultBranch: read.defaultBranch,
                                        pullRequests: pullRequests, merged: merged, at: .now)
                    reads.append(kept)
                    lastReads[repo.slug.lowercased()] = kept
                    snapshot.flakes += await recordFlakes(pullRequests, repo: repo.slug)
                    // A flow with issue moves is about the issues nobody looked at, which are the
                    // oldest: every page is read, not the newest one.
                    if repo.worksIssues(me: read.viewer), status.flow?.issues?.isEmpty == false { issuePages[repo.slug.lowercased()] = Self.issuePageCap }
                    await readIssues(repo.slug)
                    snapshot.features[repo.slug] = await readFeatures(repo: repo, flow: status.flow, defaultBranch: read.defaultBranch,
                                                                      viewer: read.viewer, merged: merged, pullRequests: pullRequests)
                } catch {
                    failures.append("\(repo.slug): \(error.localizedDescription)")
                    unread.insert(repo.slug.lowercased())
                }
            }
            snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            snapshot.unread = unread
            snapshot.listsAt = listsAt
            issueLists(into: &snapshot, config: config)
            // Started here, before dispatch, and never awaited: a build runs beside the agents.
            for read in reads where config.buildsGraph(read.repo) {
                await graphs.refresh(repo: read.repo, branch: read.repo.branch ?? read.defaultBranch,
                                     python: CodeGraph.python(configured: config.graphifyPython), ghPath: github.ghPath)
            }
            // The last sync's holds stand until this one probes again: shown without them, an outage
            // would leave the panel, and the sync dot turn green, for the minutes the planning takes.
            snapshot.outages = outages
            if let onRead { await onRead(decorated(snapshot)) }
            guard dispatching else { return decorated(snapshot) }
            // Pressed while the repos were read: what was read is shown, nothing starts, and the
            // sync the press queued stops the rest.
            if (try? BtonConfig.loadOrCreate(home: home))?.isPaused == true { return decorated(snapshot) }
            await refreshPricesIfDue()
            applyVerdicts()
            var pending: [(candidate: DispatchCandidate, clone: URL, flow: Flow?)] = []
            // This sync's probes, by lowercased slug: `settleOutages` turns them into the holds shown.
            var heldNow: [String: String] = [:]
            // Read but not acted on: its run-next picks wait, like an unread repo's.
            var unplanned = unread
            for read in reads {
                guard let path = read.repo.path else { continue }
                let clone = URL(fileURLWithPath: path)
                do {
                    let first = pending.count
                    // Probed before anything is taken: a Mac whose services are down must not take a
                    // teammate's review it cannot run (it sat on six for two days, 2026-11-11).
                    var hold = await environmentHold(of: read.repo)
                    await clearMerged(read.merged, clone: clone)
                    let dispatcher = try await dispatcher(me: read.viewer, config: config)
                    await clearWorkLabels(read.pullRequests, repo: read.repo, leases: dispatcher.leases)
                    await stopStaleReviews(read.pullRequests, dispatcher: dispatcher)
                    if let flow = read.flow {
                        await assignRotation(read.pullRequests, flow: flow, repo: read.repo.slug, me: read.viewer, dispatcher: dispatcher)
                        if read.repo.takesMoves, hold == nil {
                            // A service that went down since the probe holds the rest of this sync too.
                            hold = await autoTake(read.pullRequests, flow: flow, repo: read.repo.slug, me: read.viewer)
                        }
                        if let stale = flow.stale {
                            await postStaleNotices(read.pullRequests, stale: stale, repo: read.repo.slug, me: read.viewer, dispatcher: dispatcher)
                            if read.repo.worksIssues(me: read.viewer), issuesReadThisTick.contains(read.repo.slug.lowercased()) {
                                await postIssueStaleNotices(openIssues[read.repo.slug.lowercased()] ?? [], stale: stale, flow: flow,
                                                            repo: read.repo.slug, me: read.viewer, dispatcher: dispatcher)
                            }
                        }
                        var candidates = DispatchPlanner.candidates(read.pullRequests, flow: flow, me: read.viewer, repo: read.repo.slug)
                        // A teammate's review left past the flow's handOverHours: this Mac's turn, like
                        // its own moves, only where the repo starts moves on its own.
                        if read.repo.startsMoves {
                            candidates += read.pullRequests.compactMap {
                                DispatchPlanner.handoverCandidate($0, flow: flow, me: read.viewer, repo: read.repo.slug)
                            }
                        }
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
                        candidates.removeAll { heldBySession($0, me: read.viewer) }
                        pending += candidates.map { ($0, clone, flow) }
                        // The Mac that works the repo's issues also takes the next ready one, once its PRs have
                        // their turn; any other Mac only resumes what it holds or what the owner pressed.
                        let requested = taken[read.repo.slug.lowercased()]
                        if let intake = flow.intake,
                           issuesReadThisTick.contains(read.repo.slug.lowercased()),
                           let made = IssueIntake.candidate(issues: openIssues[read.repo.slug.lowercased()] ?? [], intake: intake,
                                                            caps: flow.caps, pullRequests: read.pullRequests, jobs: jobs.all(),
                                                            repo: read.repo.slug, base: flow.base, me: read.viewer, agents: config.agents,
                                                            work: Self.coderPick(read.repo, config: config), requested: requested,
                                                            resumeOnly: !read.repo.worksIssues(me: read.viewer) && requested == nil) {
                            pending.append((made, clone, flow))
                        }
                        // An unread repo keeps the press for the next sync.
                        if issuesReadThisTick.contains(read.repo.slug.lowercased()) { taken[read.repo.slug.lowercased()] = nil }
                        // The issues run on the Mac that works them (the repo owner's unless the card
                        // says otherwise): the asks of me, after the PRs and the intake, then the moves.
                        if read.repo.worksIssues(me: read.viewer) {
                            pending += decideCandidates(repo: read.repo.slug, flow: flow, defaultBranch: read.repo.branch ?? read.defaultBranch,
                                                        me: read.viewer, agents: config.agents).map { ($0, clone, flow) }
                            // The issues' own moves, last: the triager sorts what nobody is building.
                            pending += await issueMoveCandidates(repo: read.repo.slug, flow: flow, pullRequests: read.pullRequests,
                                                                 me: read.viewer, agents: config.agents).map { ($0, clone, flow) }
                        }
                    }
                    // A schedule runs a repo without a flow: this Mac's own agent, like its agents,
                    // started from the branch PRs merge into, which the owner picks per repo. A repo
                    // with a flow is run by the flow; a schedule left on it is ignored (Settings says so),
                    // as is a second schedule on one repo: the first in the config is the one the tab shows.
                    if read.flow == nil {
                        let schedules = config.schedules.first { $0.repo?.caseInsensitiveCompare(read.repo.slug) == .orderedSame }.map { [$0] } ?? []
                        let runNow = Set(schedules.compactMap(\.item).filter { next.contains(Self.pick(repo: read.repo.slug, item: $0)) })
                        let changedAt = DispatchPlanner.queueChangedAt(read.pullRequests, merged: read.merged)
                        pending += DispatchPlanner.scheduled(schedules, jobs: jobs.all(), repo: read.repo.slug,
                                                             defaultBranch: read.repo.branch ?? read.defaultBranch, me: read.viewer,
                                                             runNow: runNow, changedAt: changedAt,
                                                             pushedAt: DispatchPlanner.queuePushedAt(read.pullRequests),
                                                             queueHeads: DispatchPlanner.queueHeads(read.pullRequests))
                            .map { ($0, clone, nil) }
                    }
                    // The registry job needs no flow either: nightly, or pressed on the repo's page.
                    if let registry = await featureJob(read, config: config, leases: dispatcher.leases) { pending.append((registry, clone, read.flow)) }
                    // The release: opened here when due, merged through a job once its PR is open.
                    if let release = await planRelease(read) { pending.append((release, clone, read.flow)) }
                    // One supervisor at a time: the first repo with a flagged job takes this tick's.
                    if !pending.contains(where: { $0.candidate.key.move == Supervision.move }),
                       let supervise = Supervision.candidate(settings: config.supervisor, agents: config.agents, jobs: jobs.all(),
                                                             repo: read.repo.slug, pullRequests: read.pullRequests,
                                                             defaultBranch: read.repo.branch ?? read.defaultBranch,
                                                             me: read.viewer, log: supervisorLog) {
                        pending.append((supervise, clone, read.flow))
                    }
                    pending += draftCandidates(repo: read.repo.slug, defaultBranch: read.repo.branch ?? read.defaultBranch,
                                               me: read.viewer, agents: config.agents,
                                               model: config.draftModel ?? BtonConfig.defaultDraftModel,
                                               table: read.flow?.decide?.table).map { ($0, clone, nil) }
                    pending += composeCandidates(repo: read.repo.slug, defaultBranch: read.repo.branch ?? read.defaultBranch,
                                                 me: read.viewer, agents: config.agents, merged: read.merged,
                                                 issuesFresh: issuesReadThisTick.contains(read.repo.slug.lowercased()),
                                                 clone: clone, codeGraph: config.buildsGraph(read.repo),
                                                 model: config.draftModel ?? BtonConfig.defaultDraftModel).map { ($0, clone, nil) }
                    // Every agent job of this repo runs under its hat and starts with what the registry knows about its work.
                    for index in first..<pending.count {
                        let hatted = Self.hatted(pending[index].candidate, repo: read.repo, hats: config.hatSettings, agents: config.agents)
                        pending[index].candidate = Self.withFeatureContext(hatted, report: snapshot.features[read.repo.slug])
                    }
                    // Nothing of this repo but its text-only jobs starts while a service its environment names does not answer.
                    if let hold { heldNow[read.repo.slug.lowercased()] = hold }
                    if first < pending.count, let hold {
                        await holdPending(read.repo, hold: hold, me: read.viewer, pending: &pending, from: first)
                    }
                } catch {
                    failures.append("\(read.repo.slug): \(error.localizedDescription)")
                    unplanned.insert(read.repo.slug.lowercased())
                }
            }
            snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
            snapshot.outages = settleOutages(heldNow, judged: Set(reads.map { $0.repo.slug.lowercased() }).subtracting(unplanned),
                                             known: Set(config.repos.map { $0.slug.lowercased() }))
            if let me = snapshot.me {
                try await start(pending, me: me, config: config, picksAtStart: picksAtStart, unplanned: unplanned)
            }
        } catch {
            snapshot.problem = error.localizedDescription
        }
        return decorated(snapshot)
    }

    /// The lists the window shows from what is in memory: asks, triage rows, ready issues, the
    /// agents whose login expired.
    private func issueLists(into snapshot: inout Snapshot, config: BtonConfig) {
        snapshot.issueAsks = issueAsks(in: config.repos, me: snapshot.me, flows: snapshot.flows)
        snapshot.triage = IssueTriage.ordered(config.repos.flatMap { IssueTriage.pending(openIssues[$0.slug.lowercased()] ?? []) })
        snapshot.issuesMore = issuesMore
        snapshot.issueRevisions = issueRevisions
        snapshot.ready = config.repos.flatMap { repo in
            IssueIntake.ready(openIssues[repo.slug.lowercased()] ?? [], priority: snapshot.flows[repo.slug]?.flow?.intake?.priority,
                              jobs: jobs.all(), me: snapshot.me)
        }
        snapshot.loggedOut = heldAgents().sorted()
    }

    /// A New issue turn, sent: its agent starts from what the last sync read when every list it
    /// needs is under one poll old, instead of waiting for the next sync to read GitHub again (a
    /// repo whose registry links hundreds of issues takes most of a minute to read). Only the
    /// turns start here: a PR's move or an intake reads the live head first, in the full sync.
    /// Nil when no turn waits, or a turn's repo has no read that fresh (its issues included, and
    /// not asked to load more since): the caller syncs in full.
    public func composeTick() async -> Snapshot? {
        guard !composeRequests.isEmpty else { return nil }
        var snapshot = Snapshot()
        do {
            let config = try BtonConfig.loadOrCreate(home: home)
            // Paused: the turn waits in its request until the switch is flipped back.
            if config.isPaused {
                snapshot.paused = true
                return decorated(snapshot)
            }
            // Under the rate floor the turn waits too: a quick tick starts jobs like a full one.
            if let hold = await rateLimitHold(floor: config.rateFloor) {
                snapshot.problem = hold
                keptReads(into: &snapshot, config: config)
                return decorated(snapshot)
            }
            let maxAge = TimeInterval(config.pollSeconds)
            let wanted = Set(composeRequests.map { $0.repo.lowercased() })
            for slug in wanted {
                guard config.repos.contains(where: { $0.slug.lowercased() == slug }),
                      let read = lastReads[slug], let issues = lastIssueReads[slug],
                      Self.isFresh(read: read.at, issues: issues.at, pages: issues.pages,
                                   wanted: max(1, issuePages[slug] ?? 1), now: .now, maxAge: maxAge) else { return nil }
            }
            let reads = keptReads(into: &snapshot, config: config)
            snapshot.listsAt = reads.map(\.at).min()
            guard let me = snapshot.me else { return nil }
            var pending: [(candidate: DispatchCandidate, clone: URL, flow: Flow?)] = []
            var probed: Set<String> = []
            for read in reads where wanted.contains(read.repo.slug.lowercased()) {
                guard let path = read.repo.path else { continue }
                let clone = URL(fileURLWithPath: path)
                let first = pending.count
                pending += composeCandidates(repo: read.repo.slug, defaultBranch: read.repo.branch ?? read.defaultBranch,
                                             me: read.viewer, agents: config.agents, merged: read.merged, issuesFresh: true,
                                             clone: clone, codeGraph: config.buildsGraph(read.repo),
                                             model: config.draftModel ?? BtonConfig.defaultDraftModel).map { ($0, clone, nil) }
                for index in first..<pending.count {
                    let hatted = Self.hatted(pending[index].candidate, repo: read.repo, hats: config.hatSettings, agents: config.agents)
                    pending[index].candidate = Self.withFeatureContext(hatted, report: snapshot.features[read.repo.slug])
                }
                guard first < pending.count else { continue }
                let slug = read.repo.slug.lowercased()
                probed.insert(slug)
                if let hold = await environmentHold(of: read.repo) {
                    snapshot.outages[slug] = hold
                    await holdPending(read.repo, hold: hold, me: read.viewer, pending: &pending, from: first)
                } else if let lifted = snapshot.outages.removeValue(forKey: slug) {
                    // The service answers again: the repo's picks no longer wait on it.
                    let prefix = slug + "#"
                    deferred = deferred.filter { !($0.key.hasPrefix(prefix) && $0.value == lifted) }
                }
            }
            snapshot.outages = settleOutages(snapshot.outages, judged: probed, known: Set(config.repos.map { $0.slug.lowercased() }))
            // Only the turns' own picks are judged: every other pick waits for the full sync, as before.
            let turns = Set(pending.map { Self.pick(repo: $0.candidate.key.repo, item: $0.candidate.key.item) })
            try await start(pending, me: me, config: config, picksAtStart: turns, unplanned: [], judgedOnly: true)
        } catch {
            snapshot.problem = error.localizedDescription
        }
        return decorated(snapshot)
    }

    /// Whether a repo's last read can start a New issue turn: the lists and the issues both
    /// younger than `maxAge`, and the issues read to as many pages as are wanted now.
    static func isFresh(read: Date, issues: Date, pages: Int, wanted: Int, now: Date, maxAge: TimeInterval) -> Bool {
        now.timeIntervalSince(read) < maxAge && now.timeIntervalSince(issues) < maxAge && pages >= wanted
    }

    /// Starts what `pending` holds, picks first, as many as the agent slots allow, and settles the
    /// picks: the started ones leave the line, the unplanned ones say why they wait. `judgedOnly`
    /// (a quick tick) rewrites the reasons of `picksAtStart` alone: the rest were judged by the
    /// last full sync and keep theirs.
    private func start(_ pending: [(candidate: DispatchCandidate, clone: URL, flow: Flow?)], me: String, config: BtonConfig,
                       picksAtStart: Set<String>, unplanned: Set<String>, judgedOnly: Bool = false) async throws {
        // A move already run on its head can't start, so a pick waiting on it would wait forever.
        let seen = Set(jobs.all().filter { $0.retry != true }.map(\.key))
        let runnable = Set(pending.filter { $0.candidate.pr == nil || !seen.contains($0.candidate.key) }
            .map { Self.pick(repo: $0.candidate.key.repo, item: $0.candidate.key.item) }).union(deferred.keys)
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
            let dispatcher = try await dispatcher(me: me, config: config)
            for chosen in selected {
                guard let entry = pending.first(where: { $0.candidate.key == chosen.key }) else { continue }
                if let agent = chosen.agent, heldAgents().contains(agent) {
                    refused.insert(chosen.key)
                    continue
                }
                var candidate = Supervision.steered(chosen, jobs: jobs.all())
                candidate.pressed = pressedPicks.contains(Self.pick(repo: candidate.key.repo, item: candidate.key.item))
                candidate.pressInherited = inheritedPresses.contains(Self.pick(repo: candidate.key.repo, item: candidate.key.item))
                let environment = config.repos.first { $0.slug.lowercased() == candidate.key.repo.lowercased() }?.environment ?? [:]
                switch await dispatcher.dispatch(candidate, clone: entry.clone, flow: entry.flow, agents: config.agents,
                                                 environment: environment) {
                case .started:
                    started.insert(Self.pick(repo: candidate.key.repo, item: candidate.key.item))
                    startedKeys.insert(candidate.key)
                case .busy: refused.insert(candidate.key)
                case .ran:
                    refused.insert(candidate.key)
                    ran.insert(candidate.key)
                    if candidate.issueMove != nil { issueMovesRanElsewhere.insert(candidate.key) }
                }
            }
        }
        // A pick whose move already ran elsewhere would wait forever, or hand its place to another move.
        let ranPicks = Set(ran.map { Self.pick(repo: $0.repo, item: $0.item) })
        for pick in started { asked[pick] = nil }
        // Only the ask that ran: a newer one on the same issue, asked meanwhile, stays.
        let drafted = startedKeys.union(ran)
        draftRequests.removeAll { drafted.contains(IssueDrafts.key(for: $0)) }
        composeRequests.removeAll { drafted.contains($0.key) }
        next.removeAll { ranPicks.contains($0) }
        let kept = Set(Self.keptPicks(next, started: started, runnable: runnable, unread: unplanned))
        // A press that no candidate answers is not dropped in silence: the log says so.
        for pick in next where picksAtStart.contains(pick) && !kept.contains(pick) && !ranPicks.contains(pick) && pressedPicks.contains(pick) {
            log("\(pick): not started: no move of it Bton can start now")
        }
        next.removeAll { picksAtStart.contains($0) && !kept.contains($0) }
        let refusedPicks = Set(refused.map { Self.pick(repo: $0.repo, item: $0.item) })
        let judged = Dictionary(next.filter { !started.contains($0) && (!judgedOnly || picksAtStart.contains($0)) }.map { pick in
            (pick, deferred[pick] ?? (unplanned.contains { pick.hasPrefix($0 + "#") } ? "its repo could not be read this sync"
                : refusedPicks.contains(pick) ? "another job or Mac holds the PR's lease, or its job could not be recorded"
                : runnable.contains(pick) ? "waiting for a free agent slot (\(config.maxAgents) at most) or its agent to log in"
                : "the PR's move is not one Bton can start now"))
        }) { first, _ in first }
        waiting = judgedOnly ? waiting.filter { !picksAtStart.contains($0.key) }.merging(judged) { _, new in new } : judged
        // A press starts one move: a later move of the same PR the sync starts is not pressed.
        pressedPicks = pressedPicks.subtracting(started).filter(next.contains)
        inheritedPresses.formIntersection(pressedPicks)
        // A request whose lease history says it already ran elsewhere would hold the PR's flow move
        // back; one whose lease is only held now (a schedule's agent on the PR) waits for it.
        asked = asked.filter { next.contains($0.key) && !ran.contains($0.value) }
        for key in refused where key.move == "resolve" { declined[key] = .now }
        declined = declined.filter { $0.value > .now.addingTimeInterval(-900) }
    }

    /// The window shows the same lists as after the sync they come from, for the repos as the
    /// config names them now (a path or an environment changed since the sync counts).
    @discardableResult
    private func keptReads(into snapshot: inout Snapshot, config: BtonConfig) -> [RepoRead] {
        let reads: [RepoRead] = config.repos.compactMap { repo in
            guard var read = lastReads[repo.slug.lowercased()] else { return nil }
            read.repo = repo
            return read
        }
        snapshot.outages = outages
        for read in reads {
            snapshot.flows[read.repo.slug] = read.status
            snapshot.me = read.viewer
            snapshot.openPullRequests += read.pullRequests
            snapshot.merged += read.merged
            snapshot.defaultBranches[read.repo.slug] = read.defaultBranch
            if let report = featureStates[read.repo.slug.lowercased()]?.report { snapshot.features[read.repo.slug] = report }
        }
        issueLists(into: &snapshot, config: config)
        return reads
    }

    /// Once a day: finished jobs lose their logs after `JobStore.keepDays`, and their records go
    /// into the month ledgers after `retentionDays`. One line says what went, when anything did.
    private func housekeep(retentionDays: Int) {
        let cleared = jobs.prune()
        var retired = 0
        do {
            retired = try jobs.retire(olderThan: retentionDays, prices: PriceList.load(home: home))
        } catch {
            log("jobs: could not retire old records into the month ledgers: \(error.localizedDescription)")
        }
        guard cleared > 0 || retired > 0 else { return }
        log("jobs: removed the logs of \(cleared) jobs older than \(JobStore.keepDays) days; retired \(retired) records older than \(retentionDays) days into the month ledgers")
    }

    /// Why the sync waits on GitHub's quota, or nil. Logged once when the hold begins and once
    /// when it ends, not every tick. Known gap: a Bton restarted under a hold adopts the jobs
    /// that survived only when the hold ends (adoption reads GitHub); until then nobody watches
    /// their cost cap or deadline.
    func rateLimitHold(floor: Int) async -> String? {
        guard floor > 0 else { return nil }
        let hold: String?
        do {
            hold = try await github.rateLimit().hold(floor: floor)
        } catch {
            if !rateLimitUnread { log("rate limit: could not read the quota, reading on: \(error.localizedDescription)") }
            rateLimitUnread = true
            return nil
        }
        rateLimitUnread = false
        if let hold, !rateLimited { log("rate limit: holding, \(hold)") }
        if hold == nil, rateLimited { log("rate limit: quota back, reading again") }
        rateLimited = hold != nil
        return hold
    }

    /// The snapshot with this Mac's jobs, picks and costs, newest first.
    func decorated(_ read: Snapshot) -> Snapshot {
        var snapshot = read
        // The rows were built before dispatch; a label edit made here since then (the owner
        // pressed while the tick ran) is in the list, not in those rows: those repos' rows again.
        if !labelEdits.isEmpty {
            snapshot.triage.removeAll { labelEdits[$0.repo.lowercased()] != nil }
            snapshot.triage = IssueTriage.ordered(snapshot.triage + labelEdits.keys.flatMap { IssueTriage.pending(openIssues[$0] ?? []) })
        }
        snapshot.jobs = jobs.all()
        snapshot.next = next
        snapshot.waiting = waiting.filter { next.contains($0.key) }
        snapshot.openPullRequests = snapshot.openPullRequests.map { pr in
            var pr = pr
            pr.cost = Self.total(of: snapshot.jobs, repo: pr.repo, number: pr.number)
            pr.isWorking = snapshot.jobs.contains { $0.status == .running && $0.key.repo == pr.repo && $0.key.item == "pr-\(pr.number)" }
            pr.heldBySession = heldThisTick.contains(Self.pick(repo: pr.repo, item: "pr-\(pr.number)"))
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
        runNext(repo: job.key.repo, item: job.key.item, pressed: true)
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

    /// Takes a ready issue now (the Issues tab's Take): the next sync starts its intake job, first in
    /// line, also where the repo does not start its moves.
    public func takeIssue(repo: String, number: Int) {
        taken[repo.lowercased()] = number
        runNext(repo: repo, item: "issue-\(number)", pressed: true)
    }

    /// Starts a PR's move now (the panel's Merge and Fix conflicts): first in line, and again
    /// when it failed or was stopped on this head. A `merge` key merges whatever the flow's move.
    public func runNow(_ key: JobKey) throws {
        let all = jobs.all()
        if let ended = all.last(where: { $0.key == key && $0.canRetry(among: all) }) { _ = try jobs.requestRetry(ended.id) }
        runNext(repo: key.repo, item: key.item, pressed: true)
        ask(key)
    }

    /// Runs a PR's move again although it succeeded on this head (the pill's "Fix again"): the job
    /// that changed nothing is marked to run again, so the key is not seen as done, and the PR goes
    /// first in line. Only a press reaches here; the sync never starts a key that ran.
    public func runAgain(_ key: JobKey) throws {
        let all = jobs.all()
        guard let ended = all.last(where: { $0.key == key && $0.canRunAgain(among: all) }) else { return }
        _ = try jobs.requestRunAgain(ended.id)
        runNext(repo: key.repo, item: key.item, pressed: true)
    }

    /// A Merge or Fix conflicts runs instead of the PR's flow move, also when retried from Jobs.
    func ask(_ key: JobKey) {
        if key.move == "merge" || key.move == "resolve" { asked[Self.pick(repo: key.repo, item: key.item)] = key }
    }

    /// Whether the owner's press (Merge, Fix conflicts) needs a candidate of its own. Not when the
    /// PR's move is that move on that head and mine: the flow's own candidate runs, first in line.
    /// When the flow gives the move to someone else (the reviewer's merge on a PR of mine), the
    /// press is answered by the owner's candidate, or it would wait on a move no Bton here starts.
    static func pressNeedsOverride(_ request: JobKey, pr: PullRequest, me: String) -> Bool {
        !(request.head == pr.headSha && request.move == pr.move?.name && pr.move?.isMine(me) == true)
    }

    /// What runs on a PR instead of its flow move: the owner's Merge or Fix conflicts on the head they
    /// saw, or else, where the sync starts moves, Bton's own resolve on a PR of mine that conflicts, once per head.
    private func override(_ pr: PullRequest, flow: Flow, repo: WatchedRepo, me: String) -> DispatchCandidate? {
        let pick = Self.pick(repo: repo.slug, item: "pr-\(pr.number)")
        let all = jobs.all()
        let fresh = { (c: DispatchCandidate) in !all.contains { $0.key == c.key } || DispatchPlanner.isRetry(c.key, jobs: all) }
        if let request = asked[pick] {
            // The flow's own move of mine needs no override (a reviewer's merge on a teammate's PR):
            // its candidate runs, first in line. The request stays, pinning the head, until it starts.
            // A merge the flow gives to someone else (the reviewer's, on a PR of mine) is the owner's
            // Merge: the override runs it, or the press would wait on a move no Bton here starts.
            if !Self.pressNeedsOverride(request, pr: pr, me: me) { return nil }
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

    /// An agent that would work on the branch of a PR of mine that a session here marked
    /// (`bton watching`): that session answers the PR itself. A person's press (Run next, Fix
    /// conflicts, Retry) still starts it; a supervisor's retry is not a press and waits too.
    private func heldBySession(_ candidate: DispatchCandidate, me: String) -> Bool {
        let pick = Self.pick(repo: candidate.key.repo, item: candidate.key.item)
        guard SessionWatch.holds(candidate, me: me), !pressedPicks.contains(pick) || inheritedPresses.contains(pick),
              let pr = candidate.pr, SessionWatch(home: home).isWatched(pr, repo: candidate.key.repo) else { return false }
        heldThisTick.insert(pick)
        if heldNoted.insert(candidate.key).inserted {
            log("\(candidate.key.repo)#\(pr.number): \(candidate.move.name) left to the session watching it")
        }
        return true
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
    /// A check read red on an earlier tick and green now, on the same head, is recorded in
    /// `flakes.json` and the PR gets its `flaky:<check>` label, so a fix move on that check is told
    /// to rerun before it changes code. Nothing here softens a check.
    private func recordFlakes(_ pullRequests: [PullRequest], repo: String) async -> [Flake] {
        let slug = repo.lowercased()
        let flips = Flakes.flips(previous: checkStates[slug] ?? [:], pullRequests: pullRequests, repo: repo, now: .now)
        checkStates[slug] = Flakes.states(pullRequests)
        guard !flips.isEmpty else { return [] }
        var store = FlakeStore.load(home: home)
        store.flakes = flips + store.flakes
        do { try store.pruned().save(home: home) } catch { log("\(repo): could not save flakes.json: \(error.localizedDescription)") }
        for flake in flips {
            log("\(repo)#\(flake.number): check \(flake.check) turned red then green on \(flake.head.prefix(7))")
            do {
                try await github.addLabel(Flakes.label(for: flake.check), repo: repo, number: flake.number, description: Flakes.labelDescription)
            } catch {
                log("\(repo)#\(flake.number): could not add the flaky label: \(error.localizedDescription)")
            }
        }
        return flips
    }

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

    /// Stops every job this instance runs, each ending cancelled as "paused". Before this
    /// instance has a dispatcher (started paused), a job an earlier instance left behind is ended
    /// here, its agents signalled; one another live instance on this Mac runs is left to that
    /// instance, which reads the same switch.
    private func pause() async {
        let running = jobs.all().filter { $0.status == .running }
        guard let dispatcher else {
            for var job in running {
                guard let lock = LocalLock(jobs.lockURL(job.id)) else { continue }
                defer { lock.release() }
                for pid in [job.pid, job.second?.pid].compactMap({ $0 }) { kill(-pid, SIGTERM) }
                job.status = .cancelled
                job.detail = Dispatcher.pausedReason
                job.retry = true
                job.endedAt = .now
                try? jobs.save(job)
                jobs.note(job.id, "cancelled: paused (left by an earlier Bton)")
                log("\(job.key): paused")
            }
            return
        }
        for job in running { log("\(job.key): paused") }
        // Together: each stop waits out the agent's poll, and the switch answers in one of them.
        await withTaskGroup(of: Void.self) { group in
            for job in running {
                group.addTask { await dispatcher.stopAndWait(job.id, reason: Dispatcher.pausedReason) }
            }
        }
    }

    func dispatcher(me: String, config: BtonConfig) async throws -> Dispatcher {
        if let dispatcher {
            await dispatcher.useRepos(config.repos, graphs: config.codeGraphs, graphInstruction: config.graphInstruction, hats: config.hatSettings)
            return dispatcher
        }
        let leases = try LeaseStore(home: home, holder: me, github: github)
        let made = Dispatcher(github: github, leases: leases, jobs: jobs, log: log)
        if let jobEnded { await made.onJobEnded(jobEnded) }
        // Before adopting: a job that ended while Bton was down posts its review at once.
        await made.useRepos(config.repos, graphs: config.codeGraphs, graphInstruction: config.graphInstruction, hats: config.hatSettings)
        await made.adopt()
        dispatcher = made
        return made
    }

    /// The author's Bton writes the rotation's pick to GitHub, under the PR's lease, once: as the
    /// assignee for an `assignee` move, as the requested reviewer for a `reviewer` move.
    private func assignRotation(_ pullRequests: [PullRequest], flow: Flow, repo: String, me: String, dispatcher: Dispatcher) async {
        for pr in pullRequests {
            guard let move = pr.move, move.ownerFromRotation, let owner = move.owner,
                  pr.author.caseInsensitiveCompare(me) == .orderedSame, let item = LeaseItem("pr-\(pr.number)"),
                  assigned.insert("\(repo)#\(pr.number)").inserted else { continue }
            guard case let .claimed(lease)? = try? await dispatcher.leases.claim(item, in: repo) else {
                assigned.remove("\(repo)#\(pr.number)")
                continue
            }
            let asReviewer = FlowEngine.ownerKind(for: pr, flow: flow) == "reviewer"
            do {
                if asReviewer {
                    try await github.addReviewer(owner, repo: repo, number: pr.number)
                    log("\(repo)#\(pr.number): requested review from \(owner) (rotation)")
                } else {
                    try await github.addAssignee(owner, repo: repo, number: pr.number)
                    log("\(repo)#\(pr.number): assigned \(owner) (rotation)")
                }
            } catch {
                assigned.remove("\(repo)#\(pr.number)")
                log("\(repo)#\(pr.number): could not \(asReviewer ? "request a review from" : "assign") \(owner): \(error.localizedDescription)")
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

    /// The issue author's Bton posts an issue's stale notices, as a PR's author's does, in a repo
    /// that starts its moves, under the issue's lease (a job holding it is the issue moving).
    private func postIssueStaleNotices(_ issues: [OpenIssue], stale: Stale, flow: Flow, repo: String, me: String,
                                       dispatcher: Dispatcher) async {
        let slug = repo.lowercased()
        for read in issues where read.author?.caseInsensitiveCompare(me) == .orderedSame {
            var issue = read
            let askedOfMe = IssueAsks.ask(in: issue, me: me, table: flow.decide?.table) != nil
            // A page of 50 cuts a long timeline to its oldest events, so the page can start the wait
            // days early (a notice due on the page), or hide a new wait behind an older notice (one
            // posted on the issue): those issues are judged on a read on its own, made again only
            // once the issue has changed.
            if Staleness.notice(for: issue, stale: stale, askedOfMe: askedOfMe) != nil || Staleness.noticed(issue),
               !isWhole(issue.number, in: slug) {
                guard await readWhole(issue.number, in: repo), let whole = openIssues[slug]?.first(where: { $0.number == issue.number }) else { continue }
                issue = whole
            }
            // Remembered per wait, not per marker: the marker is the same for every wait of the
            // issue, and a new wait after a ping must get its own.
            let remembered = "\(repo)#\(issue.number) \(Int(Staleness.since(issue).timeIntervalSince1970))"
            guard let notice = Staleness.notice(for: issue, stale: stale, askedOfMe: askedOfMe), let item = LeaseItem("issue-\(issue.number)"),
                  noticed.insert("\(remembered) \(notice.marker)").inserted else { continue }
            guard case let .claimed(lease)? = try? await dispatcher.leases.claim(item, in: repo) else {
                noticed.remove("\(remembered) \(notice.marker)")
                continue
            }
            // Under the lease, every comment of the issue, not the read's last 20: a notice another
            // Mac posted a moment ago, or one older than twenty comments, is seen and not posted again.
            guard let comments = try? await github.issueComments(repo: repo, number: issue.number),
                  Staleness.notice(for: issue.with(comments: comments), stale: stale, askedOfMe: askedOfMe)?.marker == notice.marker else {
                log("\(repo)#\(issue.number): \(notice.marker) not posted, the issue changed since the read")
                try? await dispatcher.leases.release(lease)
                continue
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
            do {
                try notice.body.write(to: file, atomically: true, encoding: .utf8)
                try await github.commentOnIssue(repo: repo, number: issue.number, bodyFile: file)
                log("\(repo)#\(issue.number): posted \(notice.marker)")
            } catch {
                noticed.remove("\(remembered) \(notice.marker)")
                log("\(repo)#\(issue.number): could not post \(notice.marker): \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: file)
            try? await dispatcher.leases.release(lease)
        }
    }
}
