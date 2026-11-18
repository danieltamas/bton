import Foundation

/// An approval that does not count for the PR's head. The flow asks for a review of such a head
/// without a word, so the log and `bton moves` say why, and a review that already ran there runs
/// once more.
extension FlowEngine {
    /// Why the PR's latest approval does not count for its head; nil when it counts, and when the
    /// head is only a commit pushed after it. An approval that gives the start of a commit's id
    /// is said first: it counts for no commit, carried or not.
    public static func uncountedApproval(of pr: PullRequest, flow: Flow) -> String? {
        guard let latest = uncounted(of: pr, flow: flow) else { return nil }
        if ([pr.headSha] + pr.carriedHeads + pr.mergeOnlyAncestors).contains(where: { names(latest, theStartOf: $0) }) {
            return "the approval of \(latest.head) does not count: it names \(latest.head.count) of the 40 digits of the commit's id"
        }
        return uncarriedApproval(of: pr, flow: flow)
    }

    /// Why the PR's approval does not count for its head, when the approved commit sits under a
    /// merge commit no review is carried over; nil for any other PR.
    public static func uncarriedApproval(of pr: PullRequest, flow: Flow) -> String? {
        guard let latest = uncounted(of: pr, flow: flow),
              pr.mergeOnlyAncestors.contains(where: { $0.lowercased() == latest.head }) else { return nil }
        return "the approval of \(latest.head.prefix(7)) does not carry to \(pr.headSha.prefix(7)): "
            + (pr.carryRefusal ?? "no clean merge of the base leads to it")
    }

    /// The round a review runs once more in (`reviewsAgain`). A fixed text, never a time: a second
    /// approval of the same kind gives the same key, so the move never runs a third time for it.
    static let shortIDRound = "+short-id"

    /// The flow asks for `move` again on a head and in a round it already ran in: my own latest
    /// review approves the head by the start of its id (an older Bton posted the reviewer's text
    /// as it was, or I typed it), and my own posts open no round (`round`). Only when the rule
    /// that gives the PR its move now gives `move` on `no_review_or_response_newer`: a move due
    /// for another reason keeps its key, also in a flow where another rule names the predicate.
    public static func reviewsAgain(_ move: String, pr: PullRequest, flow: Flow, me: String) -> Bool {
        guard let latest = uncounted(of: pr, flow: flow),
              latest.author?.caseInsensitiveCompare(me) == .orderedSame, names(latest, theStartOf: pr.headSha),
              let rule = rule(for: pr, flow: flow) else { return false }
        return rule.move == move && rule.when.contains("no_review_or_response_newer")
    }

    /// The PR's latest review when it is an approval that does not count for the head.
    private static func uncounted(of pr: PullRequest, flow: Flow) -> Review? {
        let facts = Facts(pr: pr, flow: flow, reviews: reviews(of: pr, flow: flow))
        guard let latest = facts.latest, latest.verdict == .approve, !facts.countsForHead(latest) else { return nil }
        return latest
    }

    /// The review gives the start of `id`, not all of it.
    private static func names(_ review: Review, theStartOf id: String) -> Bool {
        let id = id.lowercased()
        return id != review.head && id.hasPrefix(review.head)
    }
}
