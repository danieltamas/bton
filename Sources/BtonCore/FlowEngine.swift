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
    /// What raised the tier above the PR body's: a changed file that matches `tier.paths`.
    public let tierReason: String?
    /// The `checks_green:` checks that are red on the head, when they are all that holds the
    /// move: nobody's agent runs it, its owner re-runs the check or fixes the base.
    public let redChecks: [String]

    public init(name: String, owner: String?, ownerFromRotation: Bool, tier: String, hasDispatch: Bool, labels: [String] = [],
                ownerWroteIt: Bool = false, tierReason: String? = nil, redChecks: [String] = []) {
        self.tierReason = tierReason
        self.redChecks = redChecks
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
        namedTier(of: body, rule: rule) ?? rule.defaultTier
    }

    /// The one tier the body's marker line names; nil when there is no line, no value or several.
    public static func namedTier(of body: String, rule: TierRule) -> String? {
        guard let line = body.split(whereSeparator: \.isNewline)
            .first(where: { $0.range(of: rule.marker, options: .caseInsensitive) != nil }),
            let marker = line.range(of: rule.marker, options: .caseInsensitive) else { return nil }
        let rest = line[marker.upperBound...]
        let named = rule.values.filter { value in
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: value) + "(?![A-Za-z0-9])"
            return rest.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
        return named.count == 1 ? named[0] : nil
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
        let counting = flow.reviews[tier(of: pr, rule: flow.tier)] ?? []
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

    /// The PR's review round for me: the newest counting review or decision by someone else, as
    /// the seconds of its time, or "" before any. My own posts never open a round for me, so a
    /// job's own review or decision cannot start it again.
    public static func round(of pr: PullRequest, flow: Flow, me: String) -> String {
        reviews(of: pr, flow: flow).last { $0.author?.caseInsensitiveCompare(me) != .orderedSame }
            .map { String(Int($0.createdAt.timeIntervalSince1970)) } ?? ""
    }

    /// The first rule whose conditions all hold for the PR.
    static func rule(for pr: PullRequest, flow: Flow) -> MoveRule? {
        let facts = Facts(pr: pr, flow: flow, reviews: reviews(of: pr, flow: flow))
        return flow.moves.first { $0.when.allSatisfy(facts.holds) }
    }

    /// The first rule that holds but for its `checks_green:` predicates, every named check done
    /// on the head and at least one red, with the red names. A check still pending or not there
    /// may yet turn green; a red one does not, and a move held only by it is a person's: re-run
    /// it, or fix the base.
    static func blockedRule(for pr: PullRequest, flow: Flow) -> (rule: MoveRule, red: [String])? {
        let facts = Facts(pr: pr, flow: flow, reviews: reviews(of: pr, flow: flow))
        guard facts.checksReadable else { return nil }
        for rule in flow.moves {
            let names = requiredChecks(of: rule)
            guard !names.isEmpty, rule.when.filter({ !$0.hasPrefix(checksPredicate + ":") }).allSatisfy(facts.holds) else { continue }
            let states = names.map { name in pr.checks.first { $0.name == name }?.state }
            guard states.allSatisfy({ $0 == .success || $0 == .failure }) else { continue }
            let red = zip(names, states).filter { $0.1 == .failure }.map(\.0)
            if !red.isEmpty { return (rule, red) }
        }
        return nil
    }

    public static func move(for pr: PullRequest, flow: Flow) -> Move? {
        let verdict = tierVerdict(of: pr, rule: flow.tier)
        let tier = verdict.tier
        guard !Release.isRelease(pr, flow: flow) else { return nil }
        guard let rule = rule(for: pr, flow: flow) else {
            guard let blocked = blockedRule(for: pr, flow: flow) else { return nil }
            let (owner, fromRotation) = resolve(blocked.rule.who.value(for: tier), pr: pr, flow: flow)
            return Move(name: blocked.rule.move, owner: owner, ownerFromRotation: fromRotation, tier: tier, hasDispatch: false,
                        tierReason: verdict.reason, redChecks: blocked.red)
        }
        let (owner, fromRotation) = resolve(rule.who.value(for: tier), pr: pr, flow: flow)
        // The rotation never picks the author for `assignee`; an author who assigned themselves
        // a review their tier won't count from them is flagged instead.
        let counting = flow.reviews[tier] ?? []
        let ownerWroteIt = rule.who.value(for: tier).map(takableKinds.contains) ?? false && rule.when.contains("no_review_or_response_newer")
            && !counting.isEmpty && counting.allSatisfy(\.notByAuthor)
            && owner?.caseInsensitiveCompare(pr.author) == .orderedSame
        return Move(name: rule.move, owner: owner, ownerFromRotation: fromRotation, tier: tier,
                    hasDispatch: flow.dispatch[rule.move] != nil,
                    labels: completionLabels(of: rule, in: flow), ownerWroteIt: ownerWroteIt, tierReason: verdict.reason)
    }

    static let checksPredicate = "checks_green"

    /// The names of a `checks_green:` predicate, comma-separated and trimmed; nil when any is
    /// empty, so `checks_green:` gates nothing open.
    static func checkNames(_ list: String) -> [String]? {
        let names = list.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return names.isEmpty || names.contains("") ? nil : names
    }

    /// The checks a rule's `checks_green:` predicates name, in order of first appearance.
    static func requiredChecks(of rule: MoveRule) -> [String] {
        var names: [String] = []
        for predicate in rule.when where predicate.hasPrefix(checksPredicate + ":") {
            for name in checkNames(String(predicate.dropFirst(checksPredicate.count + 1))) ?? [] where !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    /// The GitHub checks the PR's move waits on: the command re-reads them on the exact head right
    /// before it runs. Empty when the producing rule has no `checks_green:` or no rule matches.
    public static func requiredChecks(for pr: PullRequest, flow: Flow) -> [String] {
        rule(for: pr, flow: flow).map(requiredChecks(of:)) ?? []
    }

    /// The checks every rule for `move` names: the owner's Merge press at any move is gated by
    /// the flow's merge rules too.
    public static func requiredChecks(ofMove move: String, flow: Flow) -> [String] {
        var names: [String] = []
        for rule in flow.moves where rule.move == move {
            for name in requiredChecks(of: rule) where !names.contains(name) { names.append(name) }
        }
        return names
    }

    /// The rule's `label:` conditions that no other rule names: removing one ends this move and
    /// can't skip or start another.
    static func completionLabels(of rule: MoveRule, in flow: Flow) -> [String] {
        let others = Set(flow.moves.filter { $0.move != rule.move || $0.when != rule.when }.flatMap(\.when))
        return rule.when.filter { $0.hasPrefix("label:") && !others.contains($0) }.map { String($0.dropFirst("label:".count)) }
    }

    public static func isDispatchable(_ move: Move, pr: PullRequest, flow: Flow, me: String) -> Bool {
        move.hasDispatch && !move.ownerWroteIt && move.isMine(me) && pr.baseRef == flow.base
            && !Release.isRelease(pr, flow: flow) && trustedAssociations.contains(pr.authorAssociation)
    }

    /// The `who` kinds a GitHub field owns, which Take it can move to me: `assignee` through the
    /// PR's assignees, `reviewer` through its requested reviewers.
    static let takableKinds: Set<String> = ["assignee", "reviewer"]

    /// The producing rule's `who` for the PR's tier: `author`, `assignee`, `reviewer` or a login.
    public static func ownerKind(for pr: PullRequest, flow: Flow) -> String? {
        rule(for: pr, flow: flow)?.who.value(for: tier(of: pr, rule: flow.tier))
    }

    /// Take it: the PR's move once its owning field names me alone, when that makes it mine to
    /// start. Only an `assignee` or `reviewer` move moves this way; an `author` or named one stays
    /// with its person.
    public static func takeover(of pr: PullRequest, flow: Flow, me: String) -> Move? {
        guard let current = move(for: pr, flow: flow), current.hasDispatch, !current.isMine(me),
              let kind = ownerKind(for: pr, flow: flow), takableKinds.contains(kind) else { return nil }
        // GitHub refuses a review request to the PR's author: no dead button.
        if kind == "reviewer", pr.author.caseInsensitiveCompare(me) == .orderedSame { return nil }
        var taken = pr
        if kind == "reviewer" { taken.requestedReviewers = [me] } else { taken.assignees = [me] }
        guard let after = move(for: taken, flow: flow), after.name == current.name, after.isMine(me),
              isDispatchable(after, pr: taken, flow: flow, me: me) else { return nil }
        return after
    }

    /// `author`, `assignee` (the first assignee), `reviewer` (the first requested reviewer), each
    /// of the last two with the rotation when the field is empty, `approver` (whoever wrote the
    /// latest counting review or decision: GitHub ends a reviewer's request once they review, so
    /// "merge, by whoever approved" cannot be said with `reviewer`), or a literal login.
    static func resolve(_ who: String?, pr: PullRequest, flow: Flow) -> (owner: String?, fromRotation: Bool) {
        switch who {
        case nil: return (nil, false)
        case "author": return (pr.author, false)
        case "assignee": return pr.assignees.first.map { ($0, false) } ?? rotation(for: pr, flow: flow)
        case "reviewer": return pr.requestedReviewers.first.map { ($0, false) } ?? rotation(for: pr, flow: flow)
        case "approver": return (reviews(of: pr, flow: flow).last?.author, false)
        case let login?: return (login, false)
        }
    }

    /// `reviewers` without the author, indexed by the PR number: the same pick on every Mac. A
    /// submitted GitHub review (Bton files one with each review comment) ends that user's request,
    /// so a `reviewer` move comes back here for its next round.
    private static func rotation(for pr: PullRequest, flow: Flow) -> (owner: String?, fromRotation: Bool) {
        let pool = (flow.reviewers ?? []).filter { $0.caseInsensitiveCompare(pr.author) != .orderedSame }
        guard !pool.isEmpty else { return (nil, false) }
        return (pool[pr.number % pool.count], true)
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

        /// A `pull_request` workflow runs the PR's copy of the workflow file, so a PR that edits
        /// one is not vouched for by its own check; more checks than were read, or more files, is
        /// a guess, and a gate never passes on a guess.
        var checksReadable: Bool {
            !pr.checksTruncated && !pr.changedFilesTruncated && !pr.changedFiles.contains { $0.hasPrefix(".github/workflows/") }
        }

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
                || pr.mergeOnlyAncestors.contains { $0.lowercased().hasPrefix(review.head) }
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
            case let ("checks_green", names?):
                guard let names = FlowEngine.checkNames(names), checksReadable else { return false }
                return names.allSatisfy { name in pr.checks.contains { $0.name == name && $0.state == .success } }
            default:
                // An unknown predicate never holds, so a typo in a flow never starts anything.
                return false
            }
        }
    }
}
