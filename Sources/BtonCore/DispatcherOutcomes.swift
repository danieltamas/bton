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

    /// One comment per key, carrying Bton's marker so it never changes a move.
    func postFailure(_ candidate: DispatchCandidate, text: String) async {
        guard let pr = candidate.pr else { return }
        let body = "Bton did not start `\(candidate.move.name)` on \(pr.headSha.prefix(7)): \(text).\n\n"
            + BtonMarker.line("check-failed \(candidate.key)")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try body.write(to: file, atomically: true, encoding: .utf8)
            try await github.comment(repo: candidate.key.repo, number: pr.number, bodyFile: file)
        } catch {
            log("\(candidate.key): could not post the check failure: \(error.localizedDescription)")
        }
    }

    /// A resolve is done when the PR's head moved: an agent that stops for a ruling exits 0 too,
    /// and a success there would keep Fix conflicts from running again on this head.
    func resolveOutcome(of job: Job) async -> (status: Job.Status, detail: String?) {
        guard let number = Int(job.key.item.dropFirst("pr-".count)) else {
            return (.failed, "could not confirm the push: \(job.key.item) is not a PR")
        }
        return await DispatchPlanner.resolveOutcome(startedAt: job.key.head) { [github] in
            // GitHub can show the old head for a few seconds after a push.
            var head = try await github.pullRequestHead(repo: job.key.repo, number: number)
            for _ in 0..<2 where head == job.key.head {
                try await Task.sleep(for: .seconds(5))
                head = try await github.pullRequestHead(repo: job.key.repo, number: number)
            }
            return head
        }
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
