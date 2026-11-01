import Foundation

extension Dispatcher {
    /// Under the lease: the issue as GitHub has it now, against the plan. One that cannot be read
    /// is not worked on.
    func issueMoveRefusal(_ plan: IssueMoves.Plan, repo: String) async -> String? {
        guard let now = try? await github.issueNow(repo: repo, number: plan.number),
              let comments = try? await github.issueComments(repo: repo, number: plan.number)
        else { return "the issue could not be read again" }
        return IssueMoves.refusal(plan, now: now, comments: comments, at: .now)
    }

    /// What the job did, read back from GitHub: the three answers become the labels Bton sets, a
    /// posted question leaves the issue in the Triage tab with it, a comment or label change of
    /// the agent's own counts, and a run that did none of these fails, so it is seen.
    func issueMoveOutcome(of job: Job, plan: IssueMoves.Plan) async -> (status: Job.Status, detail: String?) {
        let report = (try? String(contentsOf: jobs.outputURL(job.id), encoding: .utf8)) ?? ""
        guard let now = try? await github.issueNow(repo: job.key.repo, number: plan.number),
              let comments = try? await github.issueComments(repo: job.key.repo, number: plan.number)
        else { return (.failed, "the issue could not be read back; check it on GitHub") }
        switch IssueMoves.outcome(report: report, move: job.key.move, plan: plan, now: now, comments: comments, since: job.startedAt) {
        case let .labels(verdict):
            let issue = TriageIssue(repo: job.key.repo, number: plan.number, title: "", url: URL(fileURLWithPath: "/"),
                                    createdAt: job.startedAt, body: "", labels: now.labels)
            let edit = IssueTriage.edit(for: verdict, on: issue)
            do {
                try await github.editIssueLabels(add: edit.add, remove: edit.remove, repo: job.key.repo, number: plan.number)
            } catch {
                return (.failed, "labels not set: \(error.localizedDescription)")
            }
            return (.succeeded, "\(verdict.labels.joined(separator: ", ")), \(verdict.score)/\(IssueTriage.maxScore)")
        case let .asked(question): return (.succeeded, "asked: " + String(question.prefix(200)))
        case .done: return (.succeeded, nil)
        case let .unchanged(why): return (.succeeded, "unchanged: " + String(why.prefix(200)))
        case .nothing: return (.failed, "the agent set no labels, posted nothing and asked nothing")
        }
    }
}
