import Foundation

/// What a command or an agent that posts a review shares: the target, the exit-2 rule, and the post.
extension Dispatcher {
    /// A command that exits with this status could not run its review here (a helper this Mac lacks).
    static let unavailableStatus: Int32 = 2

    func reviewTarget(for candidate: DispatchCandidate, flow: Flow?) -> ReviewTarget? {
        guard candidate.postComment, let pr = candidate.pr else { return nil }
        return ReviewTarget(number: pr.number, head: pr.headSha,
                            headings: flow.map { DispatchPlanner.commentHeadings(for: candidate.move, flow: $0) } ?? [],
                            clearLabels: flow.map { DispatchPlanner.clearedLabels(for: candidate.move, flow: $0) })
    }

    /// A command's end: exit 2 on a review is "unavailable", never a verdict: nothing is posted, and
    /// the job is marked for another run at the next sync, so another Mac or a later one takes it. Exit 0 on a
    /// review posts what the command wrote to `$BTON_OUT`; any other exit fails the job.
    func finishCommand(_ job: Job, status: Int32, command: [String], out: URL) async {
        defer { try? FileManager.default.removeItem(at: out) }
        if status == Self.unavailableStatus, job.review != nil {
            var waiting = job
            waiting.retry = true
            return await finish(waiting, status: .failed,
                                detail: "waiting: \(command.first ?? "the command") is unavailable on this Mac (exit 2); it runs again in 30 minutes")
        }
        guard status == 0 else { return await finish(job, status: .failed, detail: "\(command.first ?? "command") exited \(status)") }
        guard let review = job.review else { return await finish(job, status: .succeeded, detail: nil) }
        let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        await postReview(job, text: text, review: review)
    }

    /// Posts `text` as the PR's review when its first line is a review heading of the PR's tier
    /// naming the current head; anything else fails the job and posts nothing. Then mirrors the
    /// verdict as a GitHub review and clears the move's labels.
    func postReview(_ job: Job, text output: String, review: ReviewTarget, detail: String? = nil) async {
        guard let body = DispatchPlanner.reviewComment(fromFinalMessage: output, headings: review.headings,
                                                       head: review.head) else {
            return await finish(job, status: .failed, detail: "the review's first line names no review heading for the current head")
        }
        guard lost[job.id] == nil, !stopRequested(job.id) else {
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
                         detail: kept.isEmpty ? detail : "decision posted; remove \(kept.joined(separator: ", ")) by hand")
        } catch {
            await finish(job, status: .failed, detail: "posting the review failed: \(error.localizedDescription)")
        }
    }
}
