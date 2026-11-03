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
