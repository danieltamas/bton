import Foundation

/// What a PR without a move waits for: a rule that holds but for its `checks_green:` predicates.
/// It is said, never acted on: a wait starts nothing, assigns nobody and posts nothing, which is
/// why it is not a `Move` (a move pings its owner when it goes stale and writes the rotation's
/// pick to GitHub).
public struct MoveWait: Hashable, Sendable {
    /// The move the holding rule gives once its checks are green.
    public let move: String
    /// The rule's named checks that have not completed on the head (running, or not there), in
    /// the rule's order.
    public let checks: [String]
    /// The rule's named checks that are red on the head, beside the ones still awaited: the red
    /// hold shows only once every named check is done.
    public let redChecks: [String]
    /// GitHub lists more checks on the head than were read, and no gate is judged on a part of
    /// the list. Waiting does not end this one: the move is a person's on GitHub.
    public let checksUnread: Bool

    public init(move: String, checks: [String] = [], redChecks: [String] = [], checksUnread: Bool = false) {
        self.move = move
        self.checks = checks
        self.redChecks = redChecks
        self.checksUnread = checksUnread
    }

    /// One line for the log and the CLI.
    public var summary: String {
        if checksUnread { return "\(move) waits for a person: the head has more checks than Bton reads" }
        let red = redChecks.isEmpty ? "" : " (\(redChecks.joined(separator: ", ")) red)"
        return "\(move) waits for \(checks.joined(separator: ", "))\(red)"
    }
}

extension FlowEngine {
    /// What a PR without a move waits for: the first rule that holds but for its `checks_green:`
    /// predicates. Nil while the PR has a move, so nothing ever shows both, and nil where no
    /// rule is that close (a PR nobody approved waits for its review, which is a move).
    public static func wait(for pr: PullRequest, flow: Flow, now: Date = .now) -> MoveWait? {
        guard !Release.isRelease(pr, flow: flow), move(for: pr, flow: flow, now: now) == nil else { return nil }
        let held = rulesHeldByChecks(for: pr, flow: flow)
        guard let (rule, names) = held.rules.first else { return nil }
        guard held.readable else { return MoveWait(move: rule.move, checksUnread: true) }
        let state = { (name: String) in pr.checks.first { $0.name == name }?.state }
        return MoveWait(move: rule.move, checks: names.filter { state($0) != .success && state($0) != .failure },
                        redChecks: names.filter { state($0) == .failure })
    }

    /// The PR as the flow judges it: its move, or else what it waits for. Every read of a repo
    /// sets both here, so a row never carries a wait from an older read beside a move.
    public static func judged(_ pr: PullRequest, flow: Flow?, now: Date = .now) -> PullRequest {
        var pr = pr
        pr.move = flow.flatMap { move(for: pr, flow: $0, now: now) }
        pr.waiting = pr.move == nil ? flow.flatMap { wait(for: pr, flow: $0, now: now) } : nil
        return pr
    }
}
