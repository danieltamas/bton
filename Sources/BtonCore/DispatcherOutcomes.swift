import Foundation

/// What a job leaves behind: its scratch directory, a check failure on the PR, a resolve's push,
/// the work label.
extension Dispatcher {
    /// A Claude agent's own directory for notes and temporary files, gone when its job ends.
    static func scratch(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(id.uuidString.lowercased())", isDirectory: true)
    }

    func isLoggedOut(_ agent: String?) -> Bool {
        agent.map { AgentLogins.held(jobs: jobs.all(), loggedInAt: AgentLogins.load(home: jobs.home)).contains($0) } ?? false
    }

    /// The marker of the comment that says a move's checks failed on a head: one per move and
    /// head, whatever the round, so the same failure is never posted twice.
    static func checkFailedMarker(move: String, head: String) -> String { "check-failed \(move)@\(head)" }

    /// One comment per move and head, carrying Bton's marker so it never changes a move; a
    /// Makes a teammate's waiting review mine on GitHub and says so on the PR, or answers why not:
    /// the PR moved on since the read (owner, head, or a handover already on it), the lease ran
    /// out, or GitHub refused. Under the lease, from a fresh read.
    func takeOver(_ plan: HandoverPlan, candidate: DispatchCandidate, flow: Flow, lease: Lease) async -> String? {
        guard let me = candidate.move.owner, let pr = candidate.pr else { return "no PR" }
        let repo = candidate.key.repo, number = pr.number
        do {
            let read = try await github.openPullRequests(repo: repo)
            guard let fresh = read.pullRequests.first(where: { $0.number == number }), fresh.headSha == pr.headSha,
                  FlowEngine.handover(of: fresh, flow: flow, me: me) != nil,
                  FlowEngine.move(for: fresh, flow: flow)?.owner?.caseInsensitiveCompare(plan.from) == .orderedSame
            else { return "the review is no longer \(plan.from)'s to take at this head" }
            // A claim pushed, or a read made, while the Mac slept can leave the lease expired by
            // now: it must outlast the two writes too.
            guard lease.isLive(at: .now + 60) else { return "the lease ran out" }
            if plan.kind == "reviewer" {
                try await github.requestReview(me, replacing: fresh.requestedReviewers, repo: repo, number: number)
            } else {
                try await github.assign(me, replacing: fresh.assignees, repo: repo, number: number)
            }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
            defer { try? FileManager.default.removeItem(at: file) }
            try ("Took over the review from @\(plan.from), who had not started it in \(plan.hours) h.\n\n"
                 + BtonMarker.line(FlowEngine.handoverMarker(head: pr.headSha))).write(to: file, atomically: true, encoding: .utf8)
            do {
                try await github.comment(repo: repo, number: number, bodyFile: file)
            } catch {
                // The review is mine on GitHub either way: it runs, and the PR goes without the line.
                log("\(candidate.key): took the review from \(plan.from) but could not say so on the PR: \(error.localizedDescription)")
            }
            log("\(candidate.key): took over the review from \(plan.from) after \(plan.hours) h")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// comment already there (an earlier round, another Mac) counts as posted. Answers whether
    /// the comment is on the PR: a failure nobody can read is not the known kind.
    func postFailure(_ candidate: DispatchCandidate, text: String) async -> Bool {
        guard let pr = candidate.pr else { return false }
        let marker = Self.checkFailedMarker(move: candidate.move.name, head: pr.headSha)
        let body = "Bton did not start `\(candidate.move.name)` on \(pr.headSha.prefix(7)): \(text).\n\n" + BtonMarker.line(marker)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            // An earlier Bton's marker carried the whole key (`check-failed <repo>#pr-N <move>@<12 of the sha>`).
            let posted = { (key: String) in key.hasPrefix("check-failed ") && key.contains("\(candidate.move.name)@\(pr.headSha.prefix(12))") }
            // A read that fails posts nothing: a second copy of a comment already there is the loop this avoids.
            let comments = try await github.pullRequestComments(repo: candidate.key.repo, number: pr.number)
            if comments.contains(where: { BtonMarker.keys(in: $0.body).contains(where: posted) }) {
                log("\(candidate.key): the check failure is already on the PR")
                return true
            }
            try body.write(to: file, atomically: true, encoding: .utf8)
            try await github.comment(repo: candidate.key.repo, number: pr.number, bodyFile: file)
            return true
        } catch {
            log("\(candidate.key): could not post the check failure: \(error.localizedDescription)")
            return false
        }
    }

    /// A pushed outcome with the move's proof run again in the tree the agent pushed from, with
    /// the environment and time allowance of the run before the agent (`proofRuns`): every argv
    /// green, or the outcome is a failure (`Proof.afterDetail`) and the new head's own move runs
    /// it before its agent. A proof that cannot run fails the job the same way as before the
    /// agent: never read as green. A job whose first run this process did not see (a restart
    /// between) runs with the repo's environment now and the move's default hour.
    func proved(_ job: Job, outcome: (status: Job.Status, detail: String?)) async -> (status: Job.Status, detail: String?) {
        guard outcome.status == .succeeded, let proof = job.proof, !proof.isEmpty,
              let path = job.worktree else { return outcome }
        let worktree = URL(fileURLWithPath: path, isDirectory: true)
        let run = proofRuns.removeValue(forKey: job.id) ?? (environments[job.key.repo.lowercased()] ?? [:], .seconds(3600))
        for argv in proof {
            do {
                let status = try await runLogged(argv, in: worktree, job: job.id, environment: run.environment, timeout: run.timeout)
                if let detail = Proof.afterDetail(argv, status: status) { return (.failed, detail) }
                jobs.note(job.id, "proof `\(argv.joined(separator: " "))` passed after the push")
            } catch {
                return (.failed, Proof.unrunDetail(argv, reason: error.localizedDescription))
            }
        }
        return outcome
    }

    /// A resolve is done when the PR's head moved: an agent that stops for a ruling exits 0 too,
    /// and a success there would keep Fix conflicts from running again on this head.
    func resolveOutcome(of job: Job) async -> (status: Job.Status, detail: String?) {
        guard let number = Int(job.key.item.dropFirst("pr-".count)) else {
            return (.failed, "could not confirm the push: \(job.key.item) is not a PR")
        }
        return await DispatchPlanner.resolveOutcome(startedAt: job.key.head) { [github] in
            try await Self.settledHead(of: number, in: job.key.repo, startedAt: job.key.head, github: github)
        }
    }

    /// A fix is done when the PR's head moved: an agent that exits 0 without a push (a blocked
    /// tool, a question nobody answered) wrote a report, not a fix.
    func pushOutcome(of job: Job) async -> (status: Job.Status, detail: String?) {
        guard let number = Int(job.key.item.dropFirst("pr-".count)) else {
            return (.failed, "could not confirm the push: \(job.key.item) is not a PR")
        }
        return await DispatchPlanner.pushOutcome(startedAt: job.key.head) { [github] in
            try await Self.settledHead(of: number, in: job.key.repo, startedAt: job.key.head, github: github)
        }
    }

    /// GitHub can show the old head for a few seconds after a push.
    private static func settledHead(of number: Int, in repo: String, startedAt head: String, github: GitHubClient) async throws -> String {
        var live = try await github.pullRequestHead(repo: repo, number: number)
        for _ in 0..<2 where live == head {
            try await Task.sleep(for: .seconds(5))
            live = try await github.pullRequestHead(repo: repo, number: number)
        }
        return live
    }

    /// On while the lease is held: added after the claim and kept on the job (saved first, so a
    /// restart still knows it), removed before the release, so it never comes off another Mac's
    /// claim. A failure is only noted.
    func addWorkLabel(to job: Job) async -> Job {
        guard let label = workLabels[job.key.repo.lowercased()], let item = LeaseItem(job.key.item), item.kind == "pr" else { return job }
        var job = job
        job.workLabel = label
        try? jobs.save(job)
        await WorkLabels.set(true, label: label, item: item, repo: job.key.repo, github: github,
                             note: { [jobs, id = job.id] in jobs.note(id, $0) })
        return job
    }

    func removeWorkLabel(from job: Job) async {
        guard let item = LeaseItem(job.key.item) else { return }
        await WorkLabels.set(false, label: job.workLabel, item: item, repo: job.key.repo, github: github,
                             note: { [jobs, id = job.id] in jobs.note(id, $0) })
    }
}
