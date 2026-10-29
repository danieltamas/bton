import Foundation

/// The side-effecting half of dispatch: claims the lease, prepares the worktree, runs the checks and
/// the agent or command, keeps the lease renewed, and records the job. One per Bton instance.
actor Dispatcher {
    @TaskLocal static var agentPollInterval: Duration = .seconds(2)

    static let renewEvery: Duration = .seconds(300)
    static let renewRetry: Duration = .seconds(30)
    static let renewMargin: TimeInterval = 120

    let github: GitHubClient
    let leases: LeaseStore
    let jobs: JobStore
    let home: BtonHome
    let log: @Sendable (String) -> Void
    let runner = ProcessRunner()
    /// Agents this instance started; Foundation reaps a child only while its Process lives.
    private var processes: [UUID: Process] = [:]
    /// A review job's second reviewer, by job.
    private var secondProcesses: [UUID: Process] = [:]
    /// Per job this instance runs, from the claim to `finish`: the lease as last written, the task
    /// renewing it, the lock that keeps other instances on this home from adopting the job, and
    /// the work before the agent starts (cancelled when the lease is lost).
    private var held: [UUID: Lease] = [:]
    private var renewals: [UUID: Task<Void, Never>] = [:]
    private var expiryWatches: [UUID: Task<Void, Never>] = [:]
    private var locks: [UUID: LocalLock] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]
    var lost: [UUID: String] = [:]
    var stopping: Set<UUID> = []
    /// Each watched repo's environment, by lowercased slug, to redact what a job posts.
    var environments: [String: [String: String]] = [:]
    /// Each watched repo's work label, by lowercased slug.
    private(set) var workLabels: [String: String] = [:]
    /// The code graph store of each repo that builds one, by lowercased slug.
    private(set) var graphStores: [String: URL] = [:]
    /// Settings > Agents' line about the graph; nil is the default.
    private(set) var graphInstruction: String?
    /// Called after every job ends, so the next one starts without waiting for the next tick.
    private var jobEnded: (@Sendable () -> Void)?

    func onJobEnded(_ handler: @escaping @Sendable () -> Void) { jobEnded = handler }

    /// `graphs` off: no job gets a graph, whatever the repos say.
    func useRepos(_ repos: [WatchedRepo], graphs: Bool = true, graphInstruction: String? = nil) {
        environments = Dictionary(repos.map { ($0.slug.lowercased(), $0.environment ?? [:]) }) { first, _ in first }
        workLabels = Dictionary(repos.compactMap { repo in repo.workLabel.map { (repo.slug.lowercased(), $0) } }) { first, _ in first }
        graphStores = graphs
            ? Dictionary(repos.filter(\.buildsGraph).map { ($0.slug.lowercased(), CodeGraph.store(for: $0.slug, home: home)) }) { first, _ in first }
            : [:]
        self.graphInstruction = graphInstruction
    }

    /// `home` is where the repos' graph stores live; the job store's home unless given.
    init(github: GitHubClient, leases: LeaseStore, jobs: JobStore, home: BtonHome? = nil, log: @escaping @Sendable (String) -> Void) {
        self.github = github
        self.leases = leases
        self.jobs = jobs
        self.home = home ?? jobs.home
        self.log = log
    }

    /// Picks up jobs a previous run of Bton left running: their agents outlive the app. A job
    /// whose lock another instance holds is that instance's.
    func adopt() async {
        for running in jobs.all() where running.status == .running && locks[running.id] == nil {
            var job = running
            guard let lock = LocalLock(jobs.lockURL(job.id)) else { continue }
            locks[job.id] = lock
            guard let pid = job.pid else {
                jobs.stopChecks(job.id)
                // The dead run's lease is still live for up to 15 minutes and keeps the PR from
                // starting again: `finish` releases what it holds, so hold it first.
                if let item = LeaseItem(job.key.item),
                   let current = try? await leases.current(item, in: job.key.repo, job: job.id, anyHost: true) {
                    held[job.id] = current
                }
                job.retry = resumesAfterDeath(job)
                await finish(job, status: .failed, detail: "Bton stopped before the job started its agent")
                continue
            }
            // Renewed at once: while Bton was down the lease may have run out, and the CAS on its
            // sha proves nobody took it meanwhile.
            guard let item = LeaseItem(job.key.item),
                  let current = try? await leases.current(item, in: job.key.repo, job: job.id, anyHost: true),
                  let lease = try? await leases.renew(current), lease.isLive(at: .now + Self.renewMargin) else {
                await terminateAll(job)
                job.retry = resumesAfterDeath(job)
                await finish(job, status: .failed, detail: "lease lost while Bton was not running")
                continue
            }
            // An agent that ended meanwhile goes through `watch` too, so its review is still posted.
            hold(lease, for: job.id)
            Task { await self.watch(job) }
        }
    }

    /// `flow` is nil for a schedule, which has no checks and posts nothing. Returns once the job is
    /// recorded, or why it never started.
    @discardableResult
    func dispatch(_ candidate: DispatchCandidate, clone: URL, flow: Flow?, agents: [String: AgentTemplate],
                  environment: [String: String] = [:]) async -> DispatchOutcome {
        guard let item = LeaseItem(candidate.key.item) else { return .busy }
        var candidate = candidate
        let id = UUID()
        let rerun = DispatchPlanner.isRetry(candidate.key, jobs: jobs.all())
        let lease: Lease
        do {
            var claim = try await leases.claim(item, in: candidate.key.repo, job: id, key: candidate.key.description, rerun: rerun)
            if case let .notClaimed(holder?) = claim, await freeOrphan(holder, item: item, repo: candidate.key.repo) {
                claim = try await leases.claim(item, in: candidate.key.repo, job: id, key: candidate.key.description, rerun: rerun)
            }
            switch claim {
            case let .claimed(claimed) where claimed.isLive(): lease = claimed
            case let .notClaimed(holder) where !rerun && holder?.hasRun(candidate.key.description) == true: return .ran
            default: return .busy
            }
        } catch {
            log("\(candidate.key): lease not held (\(error.localizedDescription))")
            return .busy
        }
        // Under the lease, its history is the team's: another Mac may have started this move
        // between this sync's plan and the claim.
        if let cooldown = candidate.cooldown, let last = lease.record.lastStart(of: candidate.key.move, includingKey: false),
           Date.now.timeIntervalSince(last) < cooldown {
            log("\(candidate.key): not started, another run began \(Int(Date.now.timeIntervalSince(last) / 60)) min ago")
            try? await leases.release(lease, ran: false)
            return .busy
        }
        // Under the lease, so no other Mac is reading the same issue: it must still be free.
        if case var .issue(plan) = candidate.target, let me = candidate.move.owner {
            switch await intakeStanding(plan, repo: candidate.key.repo, me: me) {
            case .claim:
                plan.resumes = false
                candidate.target = .issue(plan)
            case .resume:
                plan.resumes = true
                candidate.target = .issue(plan)
            case let .refuse(reason):
                log("\(candidate.key): not taken, \(reason)")
                try? await leases.release(lease, ran: false)
                return .busy
            }
        }
        var job = Job(id: id, key: candidate.key, agent: candidate.agent, startedAt: .now, status: .running,
                      supervises: candidate.supervises, steered: candidate.steered ? true : nil)
        job.pressed = candidate.pressed ? true : nil
        job.queueHeads = candidate.queueHeads
        // The agent may have logged out while the lease was claimed: its job waits with the others.
        guard !isLoggedOut(candidate.agent), let lock = LocalLock(jobs.lockURL(id)) else {
            try? await leases.release(lease, ran: false)
            return .busy
        }
        guard (try? jobs.save(job)) != nil else {
            lock.release()
            try? await leases.release(lease, ran: false)
            return .busy
        }
        locks[id] = lock
        hold(lease, for: id)
        log("\(candidate.key): started job \(id.uuidString)")
        jobs.note(id, "started \(candidate.key)")
        // Not awaited: checks and a merge command run for minutes, and the sync that started them
        // would hold every refresh and button behind them. The saved job already counts as running.
        work[id] = Task { [candidate] in
            let job = await self.addWorkLabel(to: job)
            await self.run(job, candidate, clone: clone, flow: flow, agents: agents, environment: environment)
            self.work[id] = nil
        }
        return .started
    }

    /// Stops a job; the lease is released as the job finishes. A job another instance on this
    /// home runs is stopped through its agent, and that instance finishes it; an orphan is
    /// adopted first.
    func stop(_ id: UUID) async {
        if locks[id] == nil, LocalLock(jobs.lockURL(id)).map({ $0.release() }) != nil { await adopt() }
        let job = jobs.all().first(where: { $0.id == id })
        guard locks[id] != nil else {
            // Another instance owns the job: it reads the request before it spawns or posts anything more.
            jobs.requestStop(id)
            for pid in [job?.pid, job?.second?.pid].compactMap({ $0 }) { signal(pid, SIGTERM) }
            return
        }
        stopping.insert(id)
        work[id]?.cancel()
        if let job { await terminateAll(job) }
    }

    /// Links the repo's built graph into the job's worktree and says what the agent is told about
    /// it; nil when the repo has no graph yet. A name the tree already uses is left alone and
    /// noted: the graph is a help, never what fails a job.
    private func graphLine(for repo: String, in worktree: URL, base: String, job: UUID) -> String? {
        guard let store = graphStores[repo.lowercased()], CodeGraph.isBuilt(store), let marker = CodeGraph.marker(in: store) else { return nil }
        do {
            if case let .kept(reason) = try CodeGraph.link(into: worktree, store: store) {
                jobs.note(job, "\(CodeGraph.linkName) kept: \(reason)")
                return nil
            }
        } catch {
            jobs.note(job, "\(CodeGraph.linkName) kept: \(error.localizedDescription)")
            return nil
        }
        return CodeGraph.instructionLine(base: base, marker: marker, template: graphInstruction)
    }

    /// Worktree, checks, then the command, or the agent's spawn: `watch` takes the agent from there.
    private func run(_ job: Job, _ candidate: DispatchCandidate, clone: URL, flow: Flow?,
                     agents: [String: AgentTemplate], environment: [String: String]) async {
        var job = job
        var candidate = candidate
        do {
            // A hand-edited config is checked here too: a bad variable fails the job before anything runs.
            if let problem = WatchedRepo.environmentProblem(environment) { throw DispatchError.environment(problem) }
            if !environment.isEmpty { try jobs.saveEnvironment(environment, for: job.id) }
            if !environment.isEmpty { jobs.note(job.id, "environment: \(environment.keys.sorted().joined(separator: ", "))") }
            let base: String, worktree: URL
            switch candidate.target {
            case let .pullRequest(pr):
                base = flow?.base ?? pr.baseRef
                worktree = try await Worktrees.prepare(clone: clone, pr: pr, base: base, ghPath: github.ghPath, runner: runner,
                                                       note: { [jobs, id = job.id] in jobs.note(id, $0) })
            case let .branch(branch):
                base = branch
                worktree = try await Worktrees.prepare(clone: clone, branch: branch, item: candidate.key.item,
                                                       ghPath: github.ghPath, runner: runner, note: { [jobs, id = job.id] in jobs.note(id, $0) })
            case let .issue(plan):
                base = plan.base
                worktree = try await prepareIssue(plan, clone: clone, job: job, environment: environment, timeout: candidate.timeout)
            }
            job.worktree = worktree.path
            try jobs.save(job)
            jobs.note(job.id, "worktree \(worktree.path)")
            if candidate.agent != nil, candidate.prompt != nil, let pr = candidate.pr,
               candidate.key.move != Supervision.move, candidate.attachments[PREvidence.file] == nil {
                // What Bton read already, as data, so the agent fetches none of it again.
                let local = await PREvidence.read(worktree: worktree, base: base, ghPath: github.ghPath, runner: runner)
                let receipts = jobs.all().filter { $0.key.repo == candidate.key.repo && $0.key.head == pr.headSha }.compactMap(\.checked)
                var previous = flow.flatMap { PREvidence.previousReview(pr: pr, flow: $0) }
                if let review = previous?.review {
                    previous?.delta = await PREvidence.delta(worktree: worktree, base: base, reviewed: review.head,
                                                             ghPath: github.ghPath, runner: runner)
                }
                candidate.attachments[PREvidence.file] = PREvidence.text(pr: pr, local: local, receipts: receipts, previous: previous,
                                                                         reviewHeadings: flow?.allReviewHeadings ?? [], now: .now)
                candidate.prompt = Supervision.adding(PREvidence.promptLine(), to: candidate)
                if let secondPrompt = candidate.secondPrompt { candidate.secondPrompt = secondPrompt + "\n\n" + PREvidence.promptLine() }
            }
            let graphLine = graphLine(for: candidate.key.repo, in: worktree, base: base, job: job.id)
            if candidate.needsGraph, graphLine == nil { throw DispatchError.graphNotLinked }
            let values = try DispatchPlanner.repoValues(repo: candidate.key.repo, base: base, clone: clone)
            let checks = candidate.pr == nil || candidate.skipsChecks ? nil
                : candidate.checks ?? (candidate.key.move == "merge" ? flow?.checks?.beforeMerge : flow?.checks?.beforeSession)
            // Not in the saved environment: a posted "1" must not be redacted.
            let runEnvironment = candidate.pressed ? environment.merging(["BTON_PRESSED": "1"]) { $1 } : environment
            if let checks, !checks.isEmpty,
               let failure = try await runChecks(checks, fresh: flow?.checks?.fresh ?? [], job: &job, in: worktree, clone: clone, base: candidate.commandBase ?? base,
                                                 environment: runEnvironment, timeout: candidate.timeout) {
                await postFailure(candidate, text: failure)
                return await finish(job, status: .failed, detail: "check \(failure.prefix(300))")
            }
            if let command = candidate.command, candidate.agent == nil {
                // The repo's scripts as merged into the base, never the PR's copy: a PR that edits its
                // merge script can't have Bton run the edit. Checks above test the PR, so they run its code.
                let base = candidate.commandBase ?? base
                guard WatchedRepo.isBranchName(base) else { throw DispatchError.worktree("invalid base branch \(base)") }
                // Made anew each time, so nothing an earlier run left (ignored files included) is run.
                let trusted = try await Worktrees.prepare(clone: clone, branch: base, item: "base-\(candidate.key.item)",
                                                          ghPath: github.ghPath, runner: runner, fresh: true,
                                                          note: { [jobs, id = job.id] in jobs.note(id, $0) })
                jobs.note(job.id, "command runs in \(trusted.path), \(base) as merged")
                // Last, so only seconds separate the read from the command; the command pins `{head}`
                // to close those.
                if let pr = candidate.pr {
                    var refusal = try await headRefusal(repo: candidate.key.repo, pr: pr.number, expected: candidate.key.head, job: job.id)
                    if refusal == nil {
                        refusal = try await checksRefusal(candidate.requiredChecks, pr: pr, head: candidate.key.head, job: job.id)
                    }
                    if let refusal {
                        _ = await Worktrees.removeClean(trusted, clone: clone, ghPath: github.ghPath, runner: runner)
                        return await finish(job, status: .failed, detail: refusal)
                    }
                }
                job.review = reviewTarget(for: candidate, flow: flow)
                let out = jobs.outputURL(job.id).appendingPathExtension("post")
                let status = try await runLogged(command, in: trusted, job: job.id,
                                                 environment: job.review == nil ? runEnvironment : runEnvironment.merging(["BTON_OUT": out.path]) { $1 },
                                                 timeout: candidate.timeout)
                if await !Worktrees.removeClean(trusted, clone: clone, ghPath: github.ghPath, runner: runner) {
                    jobs.note(job.id, "kept \(trusted.path): the command left changes in it")
                }
                return await finishCommand(job, status: status, command: command, out: out)
            }
            guard let agent = candidate.agent, let template = agents[agent], let prompt = candidate.prompt else {
                return await finish(job, status: .failed, detail: "no agent or prompt for \(candidate.move.name)")
            }
            try Task.checkCancellation()
            if let holder = await claimedByAnotherAgent(worktree) {
                return await finish(job, status: .failed, detail: "another live agent has claimed this worktree, so none was started: \(holder)")
            }
            job.deadline = .now + candidate.timeout.timeInterval
            job.review = reviewTarget(for: candidate, flow: flow)
            let isClaude = template.argv.first.map(AgentHardening.isClaude) == true
            var instructions = isClaude ? try await TeamInstructions.read(clone: clone, base: base, runner: runner) : nil
            if isClaude, let graphLine { instructions = [instructions, graphLine].compactMap { $0 }.joined(separator: "\n\n") }
            let helpers = isClaude ? try offerHelpers(candidate.helpers, agents: agents, to: job.id, in: worktree) : nil
            var playbook = candidate.key.move == Supervision.move ? nil : PRPlaybook.text(for: candidate.key.move)
            if let helpers {
                instructions = [instructions, Helpers.instructions(helpers.names)].compactMap { $0 }.joined(separator: "\n\n")
            } else if !candidate.helpers.isEmpty {
                // Named helpers that cannot be offered: the agent hears it, since its task may say to ask one.
                let note = Helpers.unavailable(agent: agent, helpers: candidate.helpers)
                if isClaude { instructions = [instructions, note].compactMap { $0 }.joined(separator: "\n\n") }
                else { playbook = [playbook, note].compactMap { $0 }.joined(separator: "\n\n") }
                jobs.note(job.id, "no ask tool for \(agent): told to do the helper's checks itself")
            }
            var scratch: String?
            if isClaude || !candidate.attachments.isEmpty {
                // Made anew and private: a path already there, a link above all, fails the job.
                try FileManager.default.createDirectory(at: Self.scratch(job.id), withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try Self.attach(candidate.attachments, in: Self.scratch(job.id))
                scratch = Self.scratch(job.id).path
            }
            // Claude learns these through its system prompt; another agent has only the task.
            let task = isClaude ? prompt : Self.told(prompt, scratch: scratch, graphLine: graphLine)
            var secondTemplate: AgentTemplate?
            if let secondAgent = candidate.second {
                // The independent reviewer beside the first: same worktree and data, its own prompt,
                // session and files. A Mac without its program leaves the review to one that has it.
                guard let template = agents[secondAgent], let first = template.argv.first, Executables.resolve(first) != nil else {
                    job.retry = true
                    return await finish(job, status: .failed,
                                        detail: "waiting: \(secondAgent) is unavailable on this Mac; the review runs where it is installed")
                }
                secondTemplate = template
                // Recorded before either agent starts: a restart in between adopts a job that still
                // owes a second verdict, and posts blocked without one.
                job.second = SecondRun(agent: secondAgent, session: UUID())
            }
            // A Stop from another instance while the prompt was prepared: neither agent starts.
            if stopRequested(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
            job.pid = try spawn(DispatchPlanner.argv(template.argv, prompt: DispatchPlanner.fill(task, values), session: job.id,
                                                     instructions: instructions, values: values, model: candidate.model, effort: candidate.effort,
                                                     helpersConfig: helpers?.config, scratch: scratch,
                                                     playbook: playbook,
                                                     denying: candidate.denied),
                                in: worktree, job: job.id,
                                repoEnvironment: environment,
                                environment: helpers == nil ? [:] : ["MCP_TOOL_TIMEOUT": String(Helpers.toolTimeoutMilliseconds)])
            // Saved at once: a Stop or a restart in the next awaits must find the pid.
            try jobs.save(job)
            if let secondTemplate, let first = secondTemplate.argv.first, let secondPrompt = candidate.secondPrompt, var second = job.second {
                let secondIsClaude = AgentHardening.isClaude(first)
                var secondInstructions = secondIsClaude ? try await TeamInstructions.read(clone: clone, base: base, runner: runner) : nil
                if secondIsClaude, let graphLine { secondInstructions = [secondInstructions, graphLine].compactMap { $0 }.joined(separator: "\n\n") }
                let secondTask = secondIsClaude ? secondPrompt : Self.told(secondPrompt, scratch: scratch, graphLine: graphLine)
                if stopRequested(job.id) {
                    await terminateAll(job)
                    return await finish(job, status: .cancelled, detail: "stopped")
                }
                second.pid = try spawn(DispatchPlanner.argv(secondTemplate.argv, prompt: DispatchPlanner.fill(secondTask, values), session: second.session,
                                                            instructions: secondInstructions, values: values, scratch: scratch,
                                                            playbook: PRPlaybook.text(for: candidate.key.move), denying: candidate.denied),
                                       in: worktree, job: job.id, repoEnvironment: environment, second: true)
                job.second = second
            }
            try jobs.save(job)
            jobs.note(job.id, "\(agent) (\(template.argv.first ?? "?")) running, pid \(job.pid.map(String.init) ?? "?"), playbook v\(PRPlaybook.version)")
            if let second = job.second { jobs.note(job.id, "second reviewer \(second.agent) running, pid \(second.pid.map(String.init) ?? "?")") }
            let started = job
            Task { await self.watch(started) }
        } catch {
            // An agent whose job could not be recorded must not run on without its lease.
            await terminateAll(job)
            if stopping.contains(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
            await finish(job, status: .failed, detail: lost[job.id].map { "lease lost: \($0)" } ?? error.localizedDescription)
        }
    }

    /// Polls the agent until it exits, refreshing the cost meanwhile; stops it at its deadline or
    /// when the lease is lost. A review job then posts the final message.
    private func watch(_ job: Job) async {
        var job = job
        let clock = ContinuousClock()
        var lastCost = clock.now
        // An issue's work runs as long as it makes progress: the limit counts from the last change in
        // its worktree, up to a ceiling, so a long job is not killed while it is still writing.
        let idleWindow = job.deadline.map { $0.timeIntervalSince(job.startedAt) }
        let ceiling = job.startedAt.addingTimeInterval(Self.intakeCeiling)
        var activity = ""
        while isAlive(job) {
            try? await Task.sleep(for: Self.agentPollInterval)
            if lost[job.id] != nil {
                await terminateAll(job)
                return await finish(job, status: .failed, detail: nil)
            }
            if stopRequested(job.id) {
                await terminateAll(job)
                return await finish(job, status: .cancelled, detail: "stopped")
            }
            if clock.now - lastCost >= .seconds(30) {
                await refreshCost(&job)
                if job.key.move == IssueIntake.move, let idleWindow {
                    let seen = await worktreeActivity(of: job)
                    if seen != activity {
                        activity = seen
                        job.deadline = min(Date.now.addingTimeInterval(idleWindow), ceiling)
                    }
                }
                try? jobs.save(job)
                lastCost = clock.now
            }
            // One that exited during the sleep is judged below, by when it exited.
            if let deadline = job.deadline, Date.now >= deadline, isAlive(job) {
                // The first still running is the job timing out; only the second running leaves
                // the first's timely answer to post, with the second's absence as blocked.
                guard let pid = job.pid, !isAlive(job.id, pid: pid) else {
                    await terminateAll(job)
                    return await finish(job, status: .failed, detail: "timed out")
                }
                await terminateAll(job)
            }
        }
        processes[job.id] = nil
        secondProcesses[job.id] = nil
        // What the agents left running in the background (a dev server, a watcher) goes with them.
        await terminateAll(job)
        if stopRequested(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
        // By the exit file's time, not the poll's: an agent that exited inside its limit while this
        // slept passes, and one that ran past it while Bton was down does not.
        if let deadline = job.deadline, let exited = exitTime(job.id), exited > deadline {
            return await finish(job, status: .failed, detail: "timed out")
        }
        guard exitStatus(job.id) == 0 else {
            // No exit status at all: the agent was killed with its Mac or its session, not by its own failure.
            if exitStatus(job.id) == nil { job.retry = resumesAfterDeath(job) }
            return await finish(job, status: .failed, detail: AgentFailure.detail(
                status: exitStatus(job.id), output: AgentFailure.tail(of: jobs.outputURL(job.id)), log: AgentFailure.tail(of: jobs.logURL(job.id))))
        }
        if job.key.move == "resolve" {
            let outcome = await resolveOutcome(of: job)
            // A Stop pressed while GitHub was read stands over what it said.
            if stopping.contains(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
            return await finish(job, status: outcome.status, detail: outcome.detail)
        }
        if job.key.move == IssueIntake.move {
            let outcome = await intakeOutcome(of: job)
            if stopping.contains(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
            return await finish(job, status: outcome.status, detail: outcome.detail)
        }
        let output = (try? String(contentsOf: jobs.outputURL(job.id), encoding: .utf8)) ?? ""
        if job.key.move == Supervision.move {
            job.verdict = Supervision.verdict(fromFinalMessage: output)
            return await finish(job, status: job.verdict == nil ? .failed : .succeeded,
                                detail: job.verdict == nil ? "final message names no supervisor verdict" : nil)
        }
        guard let review = job.review else { return await finish(job, status: .succeeded, detail: nil) }
        guard let second = job.second else { return await postReview(job, text: output, review: review) }
        let (text, reason) = secondResult(of: job)
        let judged = text.flatMap { ReviewMerge.table(of: $0, headings: review.headings, head: review.head) } != nil
        guard let merged = ReviewMerge.merged(first: output, second: text, reason: reason, headings: review.headings,
                                              head: review.head, agent: second.agent) else {
            return await finish(job, status: .failed, detail: "the review's first line names no review heading for the current head")
        }
        if !judged { jobs.note(job.id, "second reviewer \(second.agent): no result: \(text == nil ? reason : "no verdict")") }
        await postReview(job, text: merged, review: review,
                         detail: judged ? nil : "posted blocked: the second reviewer (\(second.agent)) \(text == nil ? reason : "gave no verdict")")
    }

    /// The second reviewer's final message, or why there is none.
    private func secondResult(of job: Job) -> (text: String?, reason: String) {
        guard let status = exitStatus(job.id, second: true) else {
            return (nil, job.deadline.map { Date.now >= $0 } == true ? "timed out" : "did not finish")
        }
        // By its exit file's time, as for the first: one that ran past the deadline while Bton was down is late.
        if let deadline = job.deadline, let exited = exitTime(job.id, second: true), exited > deadline { return (nil, "timed out") }
        guard status == 0 else { return (nil, "exited \(status)") }
        return ((try? String(contentsOf: jobs.secondOutputURL(job.id), encoding: .utf8)) ?? "", "")
    }

    /// Stopped here, or asked to stop by another instance that could only signal.
    func stopRequested(_ id: UUID) -> Bool {
        stopping.contains(id) || jobs.stopRequested(id)
    }

    /// The first agent or the second still runs.
    private func isAlive(_ job: Job) -> Bool {
        (job.pid.map { isAlive(job.id, pid: $0) } ?? false)
            || (job.second?.pid.map { isAlive(job.id, pid: $0, second: true) } ?? false)
    }

    /// Both agents' process groups, and whatever they left behind.
    private func terminateAll(_ job: Job) async {
        if let pid = job.pid, isAlive(job.id, pid: pid) || kill(-pid, 0) == 0 { await terminate(job.id, pid: pid) }
        if let pid = job.second?.pid, isAlive(job.id, pid: pid, second: true) || kill(-pid, 0) == 0 { await terminate(job.id, pid: pid, second: true) }
    }

    private func hold(_ lease: Lease, for id: UUID) {
        held[id] = lease
        renewals[id] = Task { await self.keepRenewing(id) }
        expiryWatches[id] = Task { await self.watchExpiry(id) }
    }

    /// Stops the job when its lease nears expiry, also while a renewal is still waiting on GitHub.
    private func watchExpiry(_ id: UUID) async {
        while (try? await Task.sleep(for: .seconds(5))) != nil, let lease = held[id] {
            if !lease.isLive(at: .now + 60) { return loseLease(id, reason: "expired before it was renewed") }
        }
    }

    /// Renews the job's lease until `finish` cancels this. A failed push is retried while the
    /// lease has more than `renewMargin` left; a lease taken over, or that close to expiry, stops
    /// the job. The margin covers one more push and the clock skew between Macs.
    private func keepRenewing(_ id: UUID) async {
        var wait = Self.renewEvery
        while (try? await Task.sleep(for: wait)) != nil, let lease = held[id] {
            guard lease.isLive(at: .now + Self.renewMargin) else {
                return loseLease(id, reason: "not renewed before it expired")
            }
            let leases = leases
            do {
                // Unstructured, so a cancel from `finish` never kills a push halfway.
                let renewed = try await Task { try await leases.renew(lease) }.value
                guard renewed.isLive(at: .now + Self.renewMargin) else {
                    return loseLease(id, reason: "renewed too late")
                }
                held[id] = renewed
                wait = Self.renewEvery
            } catch let LeaseError.failed(reason) {
                log("\(lease.repo)#\(lease.item): renewing the lease failed, retrying (\(reason))")
                wait = Self.renewRetry
            } catch {
                return loseLease(id, reason: error.localizedDescription)
            }
        }
    }

    private func loseLease(_ id: UUID, reason: String) {
        held[id] = nil
        lost[id] = reason
        work[id]?.cancel()
    }

    func finish(_ job: Job, status: Job.Status, detail: String?) async {
        var job = job
        try? FileManager.default.removeItem(at: Self.scratch(job.id))
        jobs.clearStopRequest(job.id)
        expiryWatches.removeValue(forKey: job.id)?.cancel()
        if let renewal = renewals.removeValue(forKey: job.id) {
            renewal.cancel()
            await renewal.value
        }
        if let reason = lost[job.id] {
            job.status = .failed
            job.detail = "lease lost: \(reason)"
        } else {
            job.status = status
            job.detail = detail
        }
        job.endedAt = .now
        await refreshCost(&job)
        if let count = await graphQueries(of: job) { jobs.note(job.id, "graph queries: \(count)") }
        let flags = Watchdog.flags(for: job, among: jobs.all())
        job.flags = flags.isEmpty ? nil : flags
        try? jobs.save(job)
        jobs.note(job.id, job.status.rawValue + (job.detail.map { ": \($0)" } ?? "")
                  + (job.cost.map { ", cost $\($0)" } ?? ""))
        jobs.stopHelpers(job.id)
        // Only once nothing of the agent is left: a survivor would go on writing to the old file.
        if job.pid.map({ kill(-$0, 0) != 0 }) ?? true { jobs.trim(job.id) }
        if let lease = held.removeValue(forKey: job.id) {
            // Not in a stopped job's cancelled task, which kills each process as it starts: the
            // label and the lease would stay until the lease expired, and the PR read as busy.
            await Task { [job] in
                await self.removeWorkLabel(from: job)
                // A review that waited for a missing tool did not run: another Mac may take it.
                try? await self.leases.release(lease, ran: job.detail?.hasPrefix("waiting:") != true)
            }.value
        }
        lost[job.id] = nil
        stopping.remove(job.id)
        locks.removeValue(forKey: job.id)?.release()
        try? FileManager.default.removeItem(at: jobs.lockURL(job.id))
        try? FileManager.default.removeItem(at: jobs.environmentURL(job.id))
        log("\(job.key): job \(job.id.uuidString) \(job.status.rawValue)\(job.detail.map { " (\($0))" } ?? "")")
        jobEnded?()
    }

    /// How often the agent asked the code graph, for a job whose worktree had one: Claude's own
    /// transcript or the codex sessions of the worktree. "unknown" when neither can be read, so
    /// a missing transcript never reads as an agent that searched the tree instead.
    private func graphQueries(of job: Job) async -> String? {
        guard let worktree = job.worktree,
              FileManager.default.fileExists(atPath: URL(fileURLWithPath: worktree).appendingPathComponent(CodeGraph.linkName).path)
        else { return nil }
        let (id, start, end) = (job.id, job.startedAt, job.endedAt ?? .now)
        let count = await Task.detached(priority: .utility) { () -> Int? in
            if let file = ClaudeSessions.sessionFile(id: id), let count = GraphUse.queries(inClaudeSessionFile: file) { return count }
            return GraphUse.queries(inCodexWorktree: worktree, from: start, to: end)
        }.value
        return count.map(String.init) ?? "unknown"
    }

    /// The agent's own session plus every codex run inside its worktree, so a Claude agent that
    /// asks codex for a review pays for it in the same job. Parsed off the actor: the transcripts
    /// grow for as long as the agent works, and lease renewals must not wait on them.
    private func refreshCost(_ job: inout Job) async {
        let (id, worktree, start, end, home) = (job.id, job.worktree, job.startedAt, job.endedAt ?? .now, jobs.home)
        let secondSession = job.second.map { [$0.session] } ?? []
        let helperSessions = ((try? String(contentsOf: jobs.helperSessionsURL(id), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) }
        let (usage, cost) = await Task.detached(priority: .utility) { () -> ([String: TokenUsage], Decimal?) in
            var usage: [String: TokenUsage] = [:]
            for session in [id] + secondSession + helperSessions {
                if let file = ClaudeSessions.sessionFile(id: session), let found = try? ClaudeSessions.usage(ofSessionFile: file) {
                    usage.merge(found, uniquingKeysWith: +)
                }
            }
            if let worktree {
                usage.merge(CodexSessions.usage(inWorktree: worktree, from: start, to: end), uniquingKeysWith: +)
            }
            return (usage, PriceList.cost(of: usage, prices: PriceList.load(home: home)))
        }.value
        guard !usage.isEmpty else { return }
        job.usage = usage
        job.cost = cost
    }

    /// Writes the job's `ask` server file for the helpers that can run here; one note for each
    /// that cannot, so a missing program is said once instead of timing out on every ask.
    private func offerHelpers(_ names: [String], agents: [String: AgentTemplate], to id: UUID, in worktree: URL) throws -> (names: [String], config: String)? {
        guard !names.isEmpty else { return nil }
        let (usable, missing) = Helpers.usable(names, agents: agents, resolve: Executables.resolve)
        for name in missing { jobs.note(id, "helper \(name) skipped: not an agent here or its program is not installed") }
        guard !usable.isEmpty else { return nil }
        guard let server = Helpers.serverPath else {
            jobs.note(id, "helpers skipped: this build has no ask server")
            return nil
        }
        let url = jobs.helpersConfigURL(id)
        try Helpers.serverConfig(server: server, job: id, home: jobs.home.url, cwd: worktree, helpers: usable).write(to: url)
        jobs.note(id, "can ask \(usable.joined(separator: ", "))")
        return (usable, url.path)
    }

    /// Runs the agent under `/bin/sh` only to record its exit status in a file, so the status
    /// survives a Bton restart. The argv reaches the agent as `"$@"`, never parsed by the shell.
    private func spawn(_ argv: [String], in worktree: URL, job id: UUID, repoEnvironment: [String: String] = [:],
                       environment: [String: String] = [:], second: Bool = false) throws -> Int32 {
        guard let first = argv.first, let executable = Executables.resolve(first) else {
            throw DispatchError.agentNotFound(argv.first ?? "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$@\"; echo $? > \"$BTON_EXIT_FILE\"", "bton-agent", executable] + argv.dropFirst()
        process.currentDirectoryURL = worktree
        let bton = [
            "PATH": Executables.searchPath(for: executable), "BTON_EXIT_FILE": (second ? jobs.secondExitURL(id) : jobs.exitURL(id)).path,
            "BTON_JOB": id.uuidString,
        ].merging(Self.gitOverHTTPS(ghPath: github.ghPath)) { $1 }.merging(environment) { $1 }
        process.environment = ProcessRunner.inheritedEnvironment
            .merging(DispatchPlanner.processEnvironment(repo: repoEnvironment, bton: bton)) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle.appending(to: second ? jobs.secondOutputURL(id) : jobs.outputURL(id))
        process.standardError = try FileHandle.appending(to: second ? jobs.secondLogURL(id) : jobs.logURL(id))
        if !second { jobs.note(id, AgentFailure.startNote) }
        try process.run()
        if second { secondProcesses[id] = process } else { processes[id] = process }
        return process.processIdentifier
    }

    private func isAlive(_ id: UUID, pid: Int32, second: Bool = false) -> Bool {
        if let process = second ? secondProcesses[id] : processes[id] { return process.isRunning }
        return kill(pid, 0) == 0
    }

    /// SIGTERM, then SIGKILL after 5 s, and returns once the agent is gone: its lease is released
    /// only after that.
    private func terminate(_ id: UUID, pid: Int32, second: Bool = false) async {
        for sent in [SIGTERM, SIGKILL] {
            signal(pid, sent)
            for _ in 0..<25 {
                // The whole group: the wrapper shell can be gone while the agent it ran lives on.
                guard isAlive(id, pid: pid, second: second) || kill(-pid, 0) == 0 else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// The agent leads its own process group, so this reaches everything it started.
    private nonisolated func signal(_ pid: Int32, _ signal: Int32) {
        kill(-pid, signal)
    }

    private func exitTime(_ id: UUID, second: Bool = false) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: (second ? jobs.secondExitURL(id) : jobs.exitURL(id)).path))?[.modificationDate] as? Date
    }

    private func exitStatus(_ id: UUID, second: Bool = false) -> Int32? {
        (try? String(contentsOf: second ? jobs.secondExitURL(id) : jobs.exitURL(id), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
