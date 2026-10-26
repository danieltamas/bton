import Foundation

/// Bton marks every comment it posts with this, so its own comments are never read as facts.
public enum BtonMarker {
    public static let prefix = "<!-- bton:"

    public static func line(_ key: String) -> String { "\(prefix)\(key) -->" }

    /// The keys of every marker line in a comment Bton wrote.
    static func keys(in body: String) -> [String] {
        body.split(whereSeparator: \.isNewline).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(prefix), line.hasSuffix(" -->") else { return nil }
            return String(line.dropFirst(prefix.count).dropLast(" -->".count))
        }
    }
}

public enum Verdict: String, Hashable, Sendable {
    case approve, changes, blocked
}

/// A comment that counts as a review for the PR's tier.
public struct Review: Hashable, Sendable {
    public let heading: String
    public let verdict: Verdict
    public let head: String
    public let author: String?
    public let createdAt: Date
}

/// Whose move a PR is, and whether Bton could start something for it.
public struct Move: Hashable, Sendable {
    public let name: String
    /// nil when nobody is assigned and the flow has no rotation for it.
    public let owner: String?
    /// The owner is the rotation's pick and not yet assigned on GitHub.
    public let ownerFromRotation: Bool
    public let tier: String
    /// A move without a `dispatch` entry is a human's.
    public let hasDispatch: Bool
    /// The labels only this move's rule waits on (`label:` conditions): removing one is how a
    /// person says the move is done.
    public let labels: [String]
    /// The move waits on a review its owner wrote the PR for, on a tier that counts no review
    /// from the PR's author: the owner's review can never clear it, so it is never started.
    public let ownerWroteIt: Bool

    public init(name: String, owner: String?, ownerFromRotation: Bool, tier: String, hasDispatch: Bool, labels: [String] = [],
                ownerWroteIt: Bool = false) {
        self.name = name
        self.owner = owner
        self.ownerFromRotation = ownerFromRotation
        self.tier = tier
        self.hasDispatch = hasDispatch
        self.labels = labels
        self.ownerWroteIt = ownerWroteIt
    }

    public func isMine(_ me: String) -> Bool {
        owner?.caseInsensitiveCompare(me) == .orderedSame
    }
}

/// Evaluates a flow (`docs/FLOW.md`) against one PR. Pure: every Mac computes the same answer.
public enum FlowEngine {
    static let trustedAssociations: Set<String> = ["OWNER", "MEMBER", "COLLABORATOR"]

    public static func tier(of body: String, rule: TierRule) -> String {
        guard let line = body.split(whereSeparator: \.isNewline)
            .first(where: { $0.range(of: rule.marker, options: .caseInsensitive) != nil }),
            let marker = line.range(of: rule.marker, options: .caseInsensitive) else { return rule.defaultTier }
        let rest = line[marker.upperBound...]
        let named = rule.values.filter { value in
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])"
            return rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return named.count == 1 ? named[0] : rule.defaultTier
    }

    /// Rules 1–3 of "Reviews": heading, verdict word, then a named head.
    public static func review(fromFirstLine line: String, headings: [String]) -> (heading: String, verdict: Verdict, head: String)? {
        for heading in headings where line.hasPrefix(heading) {
            let rest = line.dropFirst(heading.count)
            guard let verdict = rest.firstMatch(of: /^\s*(?i)(approve|changes|blocked)(?![A-Za-z0-9_])/),
                  let head = rest[verdict.range.upperBound...].firstMatch(of: /\(head\s+`?([0-9a-fA-F]{7,40})(?![0-9a-fA-F])/)
            else { continue }
            return (heading, Verdict(rawValue: verdict.1.lowercased())!, String(head.1).lowercased())
        }
        return nil
    }

    /// A review or a `## Fixed:` reply counts only from someone with write access: on a repo anyone
    /// can comment on, an outsider's approval would otherwise merge. Unknown counts as an outsider.
    static func isTrusted(_ comment: PullRequestComment) -> Bool {
        comment.authorAssociation.map(trustedAssociations.contains) ?? false
    }

    /// The PR's counting reviews for its tier, and its decisions, oldest first.
    public static func reviews(of pr: PullRequest, flow: Flow) -> [Review] {
        let counting = flow.reviews[tier(of: pr.body, rule: flow.tier)] ?? []
        return pr.comments.filter(isTrusted).compactMap { comment in
            if let decision = flow.decision, let author = comment.author,
               decision.by.contains(where: { $0.caseInsensitiveCompare(author) == .orderedSame }),
               let parsed = review(fromFirstLine: firstLine(of: comment.body), headings: [decision.heading]) {
                return Review(heading: parsed.heading, verdict: parsed.verdict, head: parsed.head,
                              author: author, createdAt: comment.createdAt)
            }
            guard let parsed = review(fromFirstLine: firstLine(of: comment.body), headings: counting.map(\.heading)),
                  let entry = counting.first(where: { $0.heading == parsed.heading }) else { return nil }
            // An unknown author (a deleted account) can't be shown not to be the PR's.
            if entry.notByAuthor, comment.author.map({ $0.caseInsensitiveCompare(pr.author) == .orderedSame }) ?? true { return nil }
            return Review(heading: parsed.heading, verdict: parsed.verdict, head: parsed.head,
                          author: comment.author, createdAt: comment.createdAt)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The first rule whose conditions all hold for the PR.
    static func rule(for pr: PullRequest, flow: Flow) -> MoveRule? {
        let facts = Facts(pr: pr, flow: flow, reviews: reviews(of: pr, flow: flow))
        return flow.moves.first { $0.when.allSatisfy(facts.holds) }
    }

    public static func move(for pr: PullRequest, flow: Flow) -> Move? {
        let tier = tier(of: pr.body, rule: flow.tier)
        guard let rule = rule(for: pr, flow: flow) else { return nil }
        let (owner, fromRotation) = resolve(rule.who.value(for: tier), pr: pr, flow: flow)
        // The rotation never picks the author for `assignee`; an author who assigned themselves
        // a review their tier won't count from them is flagged instead.
        let counting = flow.reviews[tier] ?? []
        let ownerWroteIt = rule.who.value(for: tier) == "assignee" && rule.when.contains("no_review_or_response_newer")
            && !counting.isEmpty && counting.allSatisfy(\.notByAuthor)
            && owner?.caseInsensitiveCompare(pr.author) == .orderedSame
        return Move(name: rule.move, owner: owner, ownerFromRotation: fromRotation, tier: tier,
                    hasDispatch: flow.dispatch[rule.move] != nil,
                    labels: completionLabels(of: rule, in: flow), ownerWroteIt: ownerWroteIt)
    }

    /// The rule's `label:` conditions that no other rule names: removing one ends this move and
    /// can't skip or start another.
    static func completionLabels(of rule: MoveRule, in flow: Flow) -> [String] {
        let others = Set(flow.moves.filter { $0.move != rule.move || $0.when != rule.when }.flatMap(\.when))
        return rule.when.filter { $0.hasPrefix("label:") && !others.contains($0) }.map { String($0.dropFirst("label:".count)) }
    }

    public static func isDispatchable(_ move: Move, pr: PullRequest, flow: Flow, me: String) -> Bool {
        move.hasDispatch && !move.ownerWroteIt && move.isMine(me) && pr.baseRef == flow.base
            && trustedAssociations.contains(pr.authorAssociation)
    }

    /// Take it: the PR's move once the PR is assigned to me alone, when that makes it mine to start.
    /// Only an `assignee` move moves this way; an `author` or named one stays with its person.
    public static func takeover(of pr: PullRequest, flow: Flow, me: String) -> Move? {
        guard let current = move(for: pr, flow: flow), current.hasDispatch, !current.isMine(me),
              rule(for: pr, flow: flow)?.who.value(for: current.tier) == "assignee" else { return nil }
        var taken = pr
        taken.assignees = [me]
        guard let after = move(for: taken, flow: flow), after.name == current.name, after.isMine(me),
              isDispatchable(after, pr: taken, flow: flow, me: me) else { return nil }
        return after
    }

    /// `author`, `assignee` (with the rotation when nobody is assigned), or a literal login.
    static func resolve(_ who: String?, pr: PullRequest, flow: Flow) -> (owner: String?, fromRotation: Bool) {
        switch who {
        case nil: return (nil, false)
        case "author": return (pr.author, false)
        case "assignee":
            if let assignee = pr.assignees.first { return (assignee, false) }
            let pool = (flow.reviewers ?? []).filter { $0.caseInsensitiveCompare(pr.author) != .orderedSame }
            guard !pool.isEmpty else { return (nil, false) }
            return (pool[pr.number % pool.count], true)
        case let login?: return (login, false)
        }
    }

    static func firstLine(of body: String) -> String {
        String(body.prefix { !$0.isNewline })
    }

    /// The facts one PR's predicates are judged on.
    private struct Facts {
        let pr: PullRequest
        let flow: Flow
        let reviews: [Review]

        var latest: Review? { reviews.max { $0.createdAt < $1.createdAt } }

        /// The reviews since the latest decision; a decision itself is never a round.
        var rounds: [Review] {
            guard let heading = flow.decision?.heading else { return reviews }
            let decided = reviews.filter { $0.heading == heading }.map(\.createdAt).max()
            return reviews.filter { review in review.heading != heading && decided.map { review.createdAt > $0 } ?? true }
        }

        var latestFixed: Date? {
            pr.comments.filter { isTrusted($0) && firstLine(of: $0.body).hasPrefix(flow.fixed) }.map(\.createdAt).max()
        }

        func matchesHead(_ review: Review) -> Bool {
            pr.headSha.lowercased().hasPrefix(review.head)
        }

        func holds(_ predicate: String) -> Bool {
            // Empty parts are kept, so "draft:" is malformed rather than "draft", and "" cannot trap.
            let parts = predicate.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            switch (parts[0], parts.count > 1 ? parts[1] : nil) {
            case let ("label", name?):
                return pr.labels.contains(name)
            case ("draft", nil):
                return pr.isDraft
            case ("conflicting", nil):
                return pr.conflicting
            case ("no_review_or_response_newer", nil):
                guard let latest else { return true }
                return !matchesHead(latest) || (latestFixed.map { $0 > latest.createdAt } ?? false)
            case ("approved_current_head", nil):
                guard let latest else { return false }
                return latest.verdict == .approve && matchesHead(latest)
            case ("latest_review_changes_or_blocked", nil):
                return latest.map { $0.verdict != .approve } ?? false
            case let ("changes_rounds_at_least", count?):
                guard let latest, latest.verdict != .approve, let needed = Int(count) else { return false }
                return rounds.filter { $0.verdict != .approve }.count >= needed
            default:
                // An unknown predicate never holds, so a typo in a flow never starts anything.
                return false
            }
        }
    }
}
