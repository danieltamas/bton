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
        let waited = "`\(move.name)` on \(pr.headSha.prefix(7)) has waited \(Int(hours)) hours"
        let escalation = "stale-escalate \(move.name)@\(head)"
        if hours >= stale.escalateHours {
            guard !pr.btonMarkers.contains(escalation) else { return nil }
            return Notice(marker: escalation, body: "@\(stale.escalateTo): \(waited) for @\(owner).\n\n"
                + BtonMarker.line(escalation))
        }
        let ping = "stale-ping \(move.name)@\(head)"
        guard hours >= stale.pingHours, !pr.btonMarkers.contains(ping) else { return nil }
        return Notice(marker: ping, body: "@\(owner): \(waited).\n\n" + BtonMarker.line(ping))
    }
}
