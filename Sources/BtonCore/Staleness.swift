import Foundation

/// A move that waits longer than the flow's `stale.pingHours` gets one comment pinging its
/// owner; past `stale.escalateHours`, one comment mentioning `stale.escalateTo`. Each carries a
/// marker naming the move and the head, so a restart or a second Mac never posts it twice, and a
/// new head starts the clock again.
public enum Staleness {
    public struct Notice: Hashable, Sendable {
        public let marker: String
        public let body: String
    }

    /// When the PR's current state began: its head commit or its latest comment, whichever is
    /// later. Bton's own comments are not in `comments`, so a ping never resets the clock.
    public static func since(_ pr: PullRequest) -> Date? {
        [pr.headCommittedAt, pr.comments.last?.createdAt].compactMap { $0 }.max()
    }

    /// The comment due on `pr` now, if any. A move past the escalation gets only the escalation,
    /// also when its ping was never posted (Bton was off).
    public static func notice(for pr: PullRequest, stale: Stale, now: Date = .now) -> Notice? {
        guard let move = pr.move, let since = since(pr) else { return nil }
        let hours = now.timeIntervalSince(since) / 3600
        let owner = move.owner ?? pr.author
        let head = String(pr.headSha.prefix(12))
        // The author can't clear a review the tier counts only from someone else: it waits for a reviewer.
        let waited = "`\(move.name)` on \(pr.headSha.prefix(7)) has waited \(Int(hours)) hours"
            + (move.ownerWroteIt ? " for a reviewer other than its author" : "")
        let escalation = "stale-escalate \(move.name)@\(head)"
        if hours >= stale.escalateHours {
            guard !pr.btonMarkers.contains(escalation) else { return nil }
            let whom = move.ownerWroteIt ? "" : " for @\(owner)"
            return Notice(marker: escalation, body: "@\(stale.escalateTo): \(waited)\(whom).\n\n"
                + BtonMarker.line(escalation))
        }
        let ping = "stale-ping \(move.name)@\(head)"
        guard hours >= stale.pingHours, !pr.btonMarkers.contains(ping) else { return nil }
        return Notice(marker: ping, body: "@\(owner): \(waited).\n\n" + BtonMarker.line(ping))
    }

    /// When the issue's current state began: its last assignment or label change, or the latest
    /// comment by a person, whichever is later; the issue's opening when none. Bton's own
    /// comments (a marker, the triager's line) never reset it, so a ping is not its own answer.
    public static func since(_ issue: OpenIssue) -> Date {
        let spoken = issue.comments.filter { BtonMarker.keys(in: $0.body).isEmpty && !IssueMoves.isTriagers($0) }
        return ([issue.createdAt, issue.stateChangedAt] + spoken.map(\.createdAt)).compactMap { $0 }.max() ?? issue.createdAt
    }

    /// The comment due on an issue someone took and nobody moved, if any: its assignees are
    /// pinged past `pingHours`, `escalateTo` is told past `escalateHours` (then only that, also
    /// when the ping was never posted). A notice posted since the state began is the wait's
    /// notice: a new assignment, label or comment is a new wait, and the same wait is never
    /// pinged twice, on any Mac, whatever second each Mac read the state's start as (the marker
    /// once carried that second, and two reads of one issue disagreed on it). `askedOfMe` is an
    /// issue waiting on me (a mention, a Decisions row): that wait is mine, not the assignee's,
    /// so nothing is posted.
    public static let issuePing = "stale-ping issue"
    public static let issueEscalation = "stale-escalate issue"

    public static func notice(for issue: OpenIssue, stale: Stale, askedOfMe: Bool = false, now: Date = .now) -> Notice? {
        guard !issue.assignees.isEmpty, !askedOfMe else { return nil }
        let since = since(issue)
        let hours = now.timeIntervalSince(since) / 3600
        // Markers posted since the wait began, by prefix: `stale-ping issue@<second>` from an
        // older Bton is this wait's ping too.
        let posted = Set(issue.comments.filter { $0.createdAt >= since }
            .flatMap { BtonMarker.keys(in: $0.body) }
            .compactMap { key in [issuePing, issueEscalation].first { key == $0 || key.hasPrefix($0 + "@") } })
        let assignees = issue.assignees.map { "@\($0)" }.joined(separator: " ")
        let waited = "#\(issue.number) has waited \(Int(hours)) hours with nothing changed on it"
        let escalation = issueEscalation
        if hours >= stale.escalateHours {
            guard !posted.contains(escalation) else { return nil }
            return Notice(marker: escalation, body: "@\(stale.escalateTo): \(waited), assigned to \(assignees).\n\n" + BtonMarker.line(escalation))
        }
        let ping = issuePing
        guard hours >= stale.pingHours, !posted.contains(ping) else { return nil }
        return Notice(marker: ping, body: "\(assignees): \(waited). Is it still yours? A comment, a label or a hand-off answers this.\n\n"
            + BtonMarker.line(ping))
    }
}
