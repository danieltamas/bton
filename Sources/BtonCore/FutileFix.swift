import Foundation

/// A fix that pushed nothing because its review waits for something no change to the branch can
/// supply (another person's approval, facts the job cannot read). It failed like any fix without
/// a push (`pushOutcome`); what differs is that the same run on the same PR ends the same way, so
/// it gets no Retry until the PR has a comment the run did not see (`Job.canRetry`). Measured on
/// kazu from 2026-11-03 to 2026-11-19: 11 such runs on two PRs, 5 of them started by a press, each
/// told to "fix that on this Mac, then press Retry".
///
/// The reason is the agent's own text, and the agent reads PR text that may be hostile. It is
/// shown as plain text and decides one thing, whether Retry is offered: it never turns a run
/// into a success and starts nothing.
extension DispatchPlanner {
    /// How the detail of such a run starts; the agent's reason follows it.
    public static let noPushCanClear = "no push can clear the review"
    /// What a fix agent's final message ends on in that case (`fixLine` asks for it).
    public static let futileMarker = "## No push can clear this:"
    static let futileReasonLimit = 200

    /// What the review waits for, by a fix agent's final message: the text after `futileMarker`
    /// on its last line, as one line of plain text. Only the last line counts, so a marker the
    /// agent quotes from the PR's text further up names nothing.
    public static func futileReason(in report: String) -> String? {
        guard let last = report.split(whereSeparator: \.isNewline).last(where: { !$0.allSatisfy(\.isWhitespace) }) else { return nil }
        let line = last.trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix(futileMarker) else { return nil }
        let reason = Supervision.clean(String(line.dropFirst(futileMarker.count))).prefix(futileReasonLimit)
        return reason.isEmpty ? nil : String(reason)
    }

    /// What every fix agent is told about ending without a push. A `fixed` comment is a response:
    /// it asks for the review again, and a review by someone else then starts one more fix, so an
    /// agent that can change nothing must not post one.
    public static func fixLine(fixed: String?) -> String {
        let noResponse = fixed.flatMap { $0.isEmpty ? nil : "post no comment that starts with `\($0)` (it would ask for the review again), and " } ?? ""
        return "If you push nothing because every blocking finding left waits for something "
            + "no change to this branch can supply (another person's approval or decision, or facts this job cannot read, "
            + "such as production data), \(noResponse)end your final message with one last line in exactly this form, with "
            + "nothing after it: `\(futileMarker) <what the review waits for, in one sentence>`. A denied tool, a failed push "
            + "or a question of your own is not that case: say what stopped you instead."
    }

    /// Whether the PR got a comment after the job ended, by GitHub's time against this Mac's: for
    /// a fix that no push could help, the one change on an unchanged head and round that may be
    /// what its review waited for (an approval posted as a comment, the facts it could not read).
    public static func commentedSince(_ job: Job, pr: PullRequest) -> Bool {
        commentedSince(job, newestComment: pr.comments.map(\.createdAt).max())
    }

    /// The same question for a caller that kept only the PR's newest comment date (`Engine.newestComments`).
    static func commentedSince(_ job: Job, newestComment: Date?) -> Bool {
        guard let ended = job.endedAt, let newestComment else { return false }
        return newestComment > ended
    }
}
