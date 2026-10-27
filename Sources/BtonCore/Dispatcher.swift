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
    let log: @Sendable (String) -> Void
    let runner = ProcessRunner()
    /// Agents this instance started; Foundation reaps a child only while its Process lives.
    private var processes: [UUID: Process] = [:]
    /// Per job this instance runs, from the claim to `finish`: the lease as last written, the task
    /// renewing it, the lock that keeps other instances on this home from adopting the job, and
    /// the work before the agent starts (cancelled when the lease is lost).
    private var held: [UUID: Lease] = [:]
    private var renewals: [UUID: Task<Void, Never>] = [:]
    private var expiryWatches: [UUID: Task<Void, Never>] = [:]
    private var locks: [UUID: LocalLock] = [:]
    private var work: [UUID: Task<Void, Never>] = [:]
    private var lost: [UUID: String] = [:]
    private var stopping: Set<UUID> = []
    /// Each watched repo's environment, by lowercased slug, to redact what a job posts.
    private var environments: [String: [String: String]] = [:]
    /// Each watched repo's work label, by lowercased slug.
    private(set) var workLabels: [String: String] = [:]
    /// Called after every job ends, so the next one starts without waiting for the next tick.
    private var jobEnded: (@Sendable () -> Void)?

    func onJobEnded(_ handler: @escaping @Sendable () -> Void) { jobEnded = handler }

    func useRepos(_ repos: [WatchedRepo]) {
        environments = Dictionary(repos.map { ($0.slug.lowercased(), $0.environment ?? [:]) }) { first, _ in first }
        workLabels = Dictionary(repos.compactMap { repo in repo.workLabel.map { (repo.slug.lowercased(), $0) } }) { first, _ in first }
    }


    init(github: GitHubClient, leases: LeaseStore, jobs: JobStore, log: @escaping @Sendable (String) -> Void) {
        self.github = github
        self.leases = leases
        self.jobs = jobs
        self.log = log
    }

    /// Picks up jobs a previous run of Bton left running: their agents outlive the app. A job
    /// whose lock another instance holds is that instance's.
    func adopt() async {
        for job in jobs.all() where job.status == .running && locks[job.id] == nil {
            guard let lock = LocalLock(jobs.lockURL(job.id)) else { continue }
            locks[job.id] = lock
            guard let pid = job.pid else {
                jobs.stopChecks(job.id)
                await finish(job, status: .failed, detail: "Bton stopped before the job started its agent")
                continue
            }
            // Renewed at once: while Bton was down the lease may have run out, and the CAS on its
            // sha proves nobody took it meanwhile.
            guard let item = LeaseItem(job.key.item),
                  let current = try? await leases.current(item, in: job.key.repo, job: job.id, anyHost: true),
                  let lease = try? await leases.renew(current), lease.isLive(at: .now + Self.renewMargin) else {
                await terminate(job.id, pid: pid)
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
        let id = UUID()
        let rerun = DispatchPlanner.isRetry(candidate.key, jobs: jobs.all())
        let lease: Lease
        do {
            switch try await leases.claim(item, in: candidate.key.repo, job: id, key: candidate.key.description, rerun: rerun) {
            case let .claimed(claimed) where claimed.isLive(): lease = claimed
            case let .notClaimed(holder) where !rerun && holder?.hasRun(candidate.key.description) == true: return .ran
            default: return .busy
            }
        } catch {
            log("\(candidate.key): lease not held (\(error.localizedDescription))")
            return .busy
        }
        let job = Job(id: id, key: candidate.key, agent: candidate.agent, startedAt: .now, status: .running,
                      supervises: candidate.supervises, steered: candidate.steered ? true : nil)
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
        work[id] = Task {
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
        let pid = jobs.all().first(where: { $0.id == id })?.pid
        guard locks[id] != nil else {
            if let pid { signal(pid, SIGTERM) }
            return
        }
        stopping.insert(id)
        work[id]?.cancel()
        if let pid { await terminate(id, pid: pid) }
    }

    /// Worktree, checks, then the command, or the agent's spawn: `watch` takes the agent from there.
    private func run(_ job: Job, _ candidate: DispatchCandidate, clone: URL, flow: Flow?,
                     agents: [String: AgentTemplate], environment: [String: String]) async {
        var job = job
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
            }
            job.worktree = worktree.path
            try jobs.save(job)
            jobs.note(job.id, "worktree \(worktree.path)")
            let values = try DispatchPlanner.repoValues(repo: candidate.key.repo, base: base, clone: clone)
            let checks = candidate.pr == nil || candidate.skipsChecks ? nil
                : candidate.agent == nil ? flow?.checks?.beforeMerge : flow?.checks?.beforeSession
            // Not in the saved environment: a posted "1" must not be redacted.
            let runEnvironment = candidate.pressed ? environment.merging(["BTON_PRESSED": "1"]) { $1 } : environment
            if let checks, !checks.isEmpty,
               let failure = try await runChecks(checks, job: &job, in: worktree, clone: clone, base: base,
                                                 environment: runEnvironment, timeout: candidate.timeout) {
                await postFailure(candidate, text: failure)
                return await finish(job, status: .failed, detail: "check \(failure.prefix(300))")
            }
            if let command = candidate.command, candidate.agent == nil {
                // The repo's scripts as merged into the base, never the PR's copy: a PR that edits its
                // merge script can't have Bton run the edit. Checks above test the PR, so they run its code.
                guard WatchedRepo.isBranchName(base) else { throw DispatchError.worktree("invalid base branch \(base)") }
                // Made anew each time, so nothing an earlier run left (ignored files included) is run.
                let trusted = try await Worktrees.prepare(clone: clone, branch: base, item: "base-\(candidate.key.item)",
                                                          ghPath: github.ghPath, runner: runner, fresh: true,
                                                          note: { [jobs, id = job.id] in jobs.note(id, $0) })
                jobs.note(job.id, "command runs in \(trusted.path), \(base) as merged")
                // Last, so only seconds separate the read from the command; the command pins `{head}`
                // to close those.
                if let pr = candidate.pr,
                   let refusal = try await headRefusal(repo: candidate.key.repo, pr: pr.number, expected: candidate.key.head, job: job.id) {
                    _ = await Worktrees.removeClean(trusted, clone: clone, ghPath: github.ghPath, runner: runner)
                    return await finish(job, status: .failed, detail: refusal)
                }
                let status = try await runLogged(command, in: trusted, job: job.id, environment: runEnvironment, timeout: candidate.timeout)
                if await !Worktrees.removeClean(trusted, clone: clone, ghPath: github.ghPath, runner: runner) {
                    jobs.note(job.id, "kept \(trusted.path): the command left changes in it")
                }
                return await finish(job, status: status == 0 ? .succeeded : .failed,
                                    detail: status == 0 ? nil : "\(command.first ?? "command") exited \(status)")
            }
            guard let agent = candidate.agent, let template = agents[agent], let prompt = candidate.prompt else {
                return await finish(job, status: .failed, detail: "no agent or prompt for \(candidate.move.name)")
            }
            try Task.checkCancellation()
            job.deadline = .now + candidate.timeout.timeInterval
            job.review = candidate.postComment
                ? candidate.pr.map { pr in
                    ReviewTarget(number: pr.number, head: pr.headSha,
                                 headings: flow.map { DispatchPlanner.commentHeadings(for: candidate.move, flow: $0) } ?? [],
                                 clearLabels: flow.map { DispatchPlanner.clearedLabels(for: candidate.move, flow: $0) })
                }
                : nil
            let isClaude = template.argv.first.map(AgentHardening.isClaude) == true
            var instructions = isClaude ? try await TeamInstructions.read(clone: clone, base: base, runner: runner) : nil
            let helpers = isClaude ? try offerHelpers(candidate.helpers, agents: agents, to: job.id, in: worktree) : nil
            if let helpers { instructions = [instructions, Helpers.instructions(helpers.names)].compactMap { $0 }.joined(separator: "\n\n") }
            var scratch: String?
            if isClaude {
                // Made anew and private: a path already there, a link above all, fails the job.
                try FileManager.default.createDirectory(at: Self.scratch(job.id), withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try Self.attach(candidate.attachments, in: Self.scratch(job.id))
                scratch = Self.scratch(job.id).path
            }
            job.pid = try spawn(DispatchPlanner.argv(template.argv, prompt: DispatchPlanner.fill(prompt, values), session: job.id,
                                                     instructions: instructions, values: values, model: candidate.model,
                                                     helpersConfig: helpers?.config, scratch: scratch,
                                                     playbook: candidate.key.move == Supervision.move ? nil : PRPlaybook.text(for: candidate.key.move),
                                                     denying: candidate.denied),
                                in: worktree, job: job.id,
                                repoEnvironment: environment,
                                environment: helpers == nil ? [:] : ["MCP_TOOL_TIMEOUT": String(Helpers.toolTimeoutMilliseconds)])
            try jobs.save(job)
            jobs.note(job.id, "\(agent) (\(template.argv.first ?? "?")) running, pid \(job.pid.map(String.init) ?? "?"), playbook v\(PRPlaybook.version)")
            let started = job
            Task { await self.watch(started) }
        } catch {
            // An agent whose job could not be recorded must not run on without its lease.
            if let pid = job.pid { await terminate(job.id, pid: pid) }
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
        while let pid = job.pid, isAlive(job.id, pid: pid) {
            try? await Task.sleep(for: Self.agentPollInterval)
            if lost[job.id] != nil {
                await terminate(job.id, pid: pid)
                return await finish(job, status: .failed, detail: nil)
            }
            if clock.now - lastCost >= .seconds(30) {
                await refreshCost(&job)
                try? jobs.save(job)
                lastCost = clock.now
            }
            // One that exited during the sleep is judged below, by when it exited.
            if let deadline = job.deadline, Date.now >= deadline, isAlive(job.id, pid: pid) {
                await terminate(job.id, pid: pid)
                return await finish(job, status: .failed, detail: "timed out")
            }
        }
        processes[job.id] = nil
        // What the agent left running in the background (a dev server, a watcher) goes with it.
        if let pid = job.pid, kill(-pid, 0) == 0 { await terminate(job.id, pid: pid) }
        if stopping.contains(job.id) { return await finish(job, status: .cancelled, detail: "stopped") }
        // By the exit file's time, not the poll's: an agent that exited inside its limit while this
        // slept passes, and one that ran past it while Bton was down does not.
        if let deadline = job.deadline, let exited = exitTime(job.id), exited > deadline {
            return await finish(job, status: .failed, detail: "timed out")
        }
        guard exitStatus(job.id) == 0 else {
            return await finish(job, status: .failed, detail: AgentFailure.detail(
                status: exitStatus(job.id), output: AgentFailure.tail(of: jobs.outputURL(job.id)), log: AgentFailure.tail(of: jobs.logURL(job.id))))
        }
        if job.key.move == "resolve" {
            let outcome = await resolveOutcome(of: job)
            // A Stop pressed while GitHub was read stands over what it said.
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
        guard let body = DispatchPlanner.reviewComment(fromFinalMessage: output, headings: review.headings,
                                                       head: review.head) else {
            return await finish(job, status: .failed, detail: "final message names no review heading for the current head")
        }
        guard lost[job.id] == nil, !stopping.contains(job.id) else {
            return await finish(job, status: .cancelled, detail: "stopped")
        }
        do {
            let file = jobs.outputURL(job.id).appendingPathExtension("comment")
            let redacted = DispatchPlanner.redact(DispatchPlanner.redact(body, environment: try jobs.startedEnvironment(job.id)),
                                                  environment: environments[job.key.repo.lowercased()] ?? [:])
            try redacted.write(to: file, atomically: true, encoding: .utf8)
            try await github.comment(repo: job.key.repo, number: review.number, bodyFile: file)
            // The comment is what counts; the GitHub review only mirrors it, so a refusal (a PR of
            // one's own) is noted and the job still succeeds. The verdict comes from the body checked
            // before redaction, which may rewrite its head marker.
            if let verdict = FlowEngine.review(fromFirstLine: FlowEngine.firstLine(of: body), headings: review.headings)?.verdict {
                do {
                    try await github.submitReview(verdict, repo: job.key.repo, number: review.number, head: review.head,
                                                  summary: FlowEngine.firstLine(of: redacted))
                } catch {
                    jobs.note(job.id, "could not file the GitHub review: \(error.localizedDescription)")
                }
            }
            var kept: [String] = []
            for label in review.clearLabels ?? [] {
                do {
                    try await github.removeLabel(label, repo: job.key.repo, number: review.number)
                } catch {
                    jobs.note(job.id, "could not remove \(label): \(error.localizedDescription)")
                    kept.append(label)
                }
            }
            // The posted decision stands, but the label would hold the PR on this move: say so loudly.
            await finish(job, status: kept.isEmpty ? .succeeded : .failed,
                         detail: kept.isEmpty ? nil : "decision posted; remove \(kept.joined(separator: ", ")) by hand")
        } catch {
            await finish(job, status: .failed, detail: "posting the review failed: \(error.localizedDescription)")
        }
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

    private func finish(_ job: Job, status: Job.Status, detail: String?) async {
        var job = job
        try? FileManager.default.removeItem(at: Self.scratch(job.id))
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
                try? await self.leases.release(lease)
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

    /// The agent's own session plus every codex run inside its worktree, so a Claude agent that
    /// asks codex for a review pays for it in the same job. Parsed off the actor: the transcripts
    /// grow for as long as the agent works, and lease renewals must not wait on them.
    private func refreshCost(_ job: inout Job) async {
        let (id, worktree, start, end, home) = (job.id, job.worktree, job.startedAt, job.endedAt ?? .now, jobs.home)
        let helperSessions = ((try? String(contentsOf: jobs.helperSessionsURL(id), encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline).compactMap { UUID(uuidString: String($0)) }
        let (usage, cost) = await Task.detached(priority: .utility) { () -> ([String: TokenUsage], Decimal?) in
            var usage: [String: TokenUsage] = [:]
            for session in [id] + helperSessions {
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
                       environment: [String: String] = [:]) throws -> Int32 {
        guard let first = argv.first, let executable = Executables.resolve(first) else {
            throw DispatchError.agentNotFound(argv.first ?? "")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\"$@\"; echo $? > \"$BTON_EXIT_FILE\"", "bton-agent", executable] + argv.dropFirst()
        process.currentDirectoryURL = worktree
        let bton = [
            "PATH": Executables.searchPath(for: executable), "BTON_EXIT_FILE": jobs.exitURL(id).path, "BTON_JOB": id.uuidString,
        ].merging(Self.gitOverHTTPS(ghPath: github.ghPath)) { $1 }.merging(environment) { $1 }
        process.environment = ProcessInfo.processInfo.environment
            .merging(DispatchPlanner.processEnvironment(repo: repoEnvironment, bton: bton)) { $1 }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle.appending(to: jobs.outputURL(id))
        process.standardError = try FileHandle.appending(to: jobs.logURL(id))
        jobs.note(id, AgentFailure.startNote)
        try process.run()
        processes[id] = process
        return process.processIdentifier
    }

    private func isAlive(_ id: UUID, pid: Int32) -> Bool {
        if let process = processes[id] { return process.isRunning }
        return kill(pid, 0) == 0
    }

    /// SIGTERM, then SIGKILL after 5 s, and returns once the agent is gone: its lease is released
    /// only after that.
    private func terminate(_ id: UUID, pid: Int32) async {
        for sent in [SIGTERM, SIGKILL] {
            signal(pid, sent)
            for _ in 0..<25 {
                // The whole group: the wrapper shell can be gone while the agent it ran lives on.
                guard isAlive(id, pid: pid) || kill(-pid, 0) == 0 else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// The agent leads its own process group, so this reaches everything it started.
    private nonisolated func signal(_ pid: Int32, _ signal: Int32) {
        kill(-pid, signal)
    }

    private func exitTime(_ id: UUID) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: jobs.exitURL(id).path))?[.modificationDate] as? Date
    }

    private func exitStatus(_ id: UUID) -> Int32? {
        (try? String(contentsOf: jobs.exitURL(id), encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
