import Foundation

/// A repo's `.bton/flow.json`, version 1. The full specification is `docs/FLOW.md`.
public struct Flow: Decodable, Sendable {
    public static let relativePath = ".bton/flow.json"
    public static let supportedVersion = 1

    public let version: Int
    public let base: String
    public let tier: TierRule
    public let reviews: [String: [ReviewHeading]]
    public let fixed: String
    public let reviewers: [String]?
    public let moves: [MoveRule]
    public let dispatch: [String: DispatchRule]
    public let checks: Checks?
    public let intake: Intake?
    public let caps: Caps?
    public let stale: Stale?
    public let decision: Decision?
    /// How `from` reaches `to` (develop to main): the owner's release move, plan and predicates
    /// in docs/FLOW.md "Release". Read here so the repo page can tell "in develop" from "live".
    public let release: Release?

    public struct Release: Decodable, Sendable {
        public let from: String
        public let to: String
        /// The login whose Bton may start the release; every other Bton shows its state only.
        public let who: String
        /// First match makes a release due: `ahead_commits:N`, `ahead_days:N`, `features_waiting:N`.
        public let when: [String]
        /// Any match blocks it: `pr_in_review_on_paths:<glob>`; `release_pr_open` is always implied.
        public let blockedBy: [String]?
        public let checks: [[String]]?
        /// `merge-commit` (the default) or `fast-forward`.
        public let merge: String?
        public let timeoutMinutes: Int?

        public static let merges = ["merge-commit", "fast-forward"]
    }

    /// A person's ruling that ends a review loop (docs/FLOW.md "Decisions"): from one of `by`,
    /// it counts as the latest review whoever authored the PR, and the round cap restarts after it.
    public struct Decision: Decodable, Sendable {
        public let heading: String
        /// The move whose agent's final message is posted as the decision.
        public let move: String
        public let by: [String]
    }

    /// nil is a repo without a flow file. Anything that is not a valid version 1 flow is never
    /// dispatched, but the two cases read differently in the Repos panel.
    public static func load(_ data: Data?) -> FlowStatus {
        guard let data else { return .none }
        struct Version: Decodable { let version: Int? }
        do {
            let version = try JSONDecoder().decode(Version.self, from: data).version
            guard version == supportedVersion else { return .unsupported(version: version) }
            let flow = try JSONDecoder().decode(Flow.self, from: data)
            // A decision read as a review (or the reverse) would let any reviewer reset the round cap.
            if let heading = flow.decision?.heading,
               heading.isEmpty || flow.allReviewHeadings.contains(where: { $0.hasPrefix(heading) || heading.hasPrefix($0) }) {
                return .invalid("decision.heading \(heading) overlaps a review heading")
            }
            for (tier, globs) in flow.tier.paths ?? [:] {
                guard flow.tier.values.contains(tier) else { return .invalid("tier.paths.\(tier) is not one of tier.values") }
                if let bad = globs.first(where: { !PathGlob.isValid($0) }) {
                    return .invalid("tier.paths.\(tier): \(bad) is not a glob (no negation, no empty pattern)")
                }
            }
            for (tier, globs) in flow.tier.only ?? [:] {
                guard flow.tier.values.contains(tier) else { return .invalid("tier.only.\(tier) is not one of tier.values") }
                if let bad = globs.first(where: { !PathGlob.isValid($0) }) {
                    return .invalid("tier.only.\(tier): \(bad) is not a glob (no negation, no empty pattern)")
                }
            }
            for (index, rule) in flow.moves.enumerated() {
                // Any other unknown predicate never holds and the flow stays valid: an older Bton
                // must not refuse a flow for a predicate it does not know yet.
                let prefix = FlowEngine.checksPredicate
                if rule.when.contains(where: { ($0 == prefix || $0.hasPrefix(prefix + ":")) && FlowEngine.checkNames(String($0.dropFirst(prefix.count + 1))) == nil }) {
                    return .invalid("moves[\(index)].when: \(prefix) needs at least one check name")
                }
            }
            var grouped: Set<[String]> = []
            for group in flow.checks?.together ?? [] {
                guard group.count >= 2, group.allSatisfy({ !$0.isEmpty }) else {
                    return .invalid("checks.together: each group names at least two argv")
                }
                for argv in group {
                    guard grouped.insert(argv).inserted else {
                        return .invalid("checks.together: \(argv.joined(separator: " ")) is in two groups")
                    }
                }
            }
            for (move, rule) in flow.dispatch {
                // Agents given per tier leave the tiers without one to the command.
                if rule.command != nil, let agent = rule.agent, case .same = agent {
                    return .invalid("dispatch.\(move): a move runs a command or an agent, not both")
                }
                if let helpers = rule.helpers, helpers.count > 3 || !helpers.allSatisfy(BtonConfig.isAgentName) {
                    return .invalid("dispatch.\(move).helpers: up to three agent names")
                }
            }
            if let release = flow.release {
                if let merge = release.merge, !Release.merges.contains(merge) {
                    return .invalid("release.merge \(merge) is not one of \(Release.merges.joined(separator: ", "))")
                }
                for name in [release.from, release.to] where !WatchedRepo.isBranchName(name) {
                    return .invalid("release: \(name.prefix(100)) is not a branch name")
                }
                if release.from == release.to { return .invalid("release: from and to are the same branch") }
                if let bad = release.when.first(where: { ReleasePredicate($0) == nil }) {
                    return .invalid("release.when: \(bad.prefix(100)) is not a predicate")
                }
                if let bad = release.blockedBy?.first(where: { ReleaseBlocker($0) == nil }) {
                    return .invalid("release.blockedBy: \(bad.prefix(100)) is not a blocker")
                }
                if let minutes = release.timeoutMinutes, minutes <= 0 { return .invalid("release.timeoutMinutes must be positive") }
            }
            return .ready(flow)
        } catch {
            return .invalid(String(describing: error))
        }
    }

    /// Every heading any tier counts, for checking what an agent is about to post.
    public var allReviewHeadings: [String] {
        Array(Set(reviews.values.flatMap { $0.map(\.heading) })).sorted()
    }
}

public enum FlowStatus: Sendable {
    case none
    case unsupported(version: Int?)
    case invalid(String)
    case ready(Flow)

    public var flow: Flow? {
        if case let .ready(flow) = self { flow } else { nil }
    }
}

public struct TierRule: Decodable, Sendable {
    public let marker: String
    public let values: [String]
    public let defaultTier: String
    /// Globs of changed files by tier: a PR touching one is at least that tier, whatever its body says.
    public let paths: [String: [String]]?
    /// Globs by tier a PR is lowered to when every changed file matches one of them and the body
    /// names no other tier: earned by the files, never claimed, and raised again by `paths`.
    public let only: [String: [String]]?

    enum CodingKeys: String, CodingKey { case marker, values, defaultTier = "default", paths, only }
}

public struct ReviewHeading: Decodable, Sendable {
    public let heading: String
    public let notByAuthor: Bool

    enum CodingKeys: String, CodingKey { case heading, notByAuthor }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        heading = try container.decode(String.self, forKey: .heading)
        notByAuthor = try container.decodeIfPresent(Bool.self, forKey: .notByAuthor) ?? false
    }
}

public struct MoveRule: Decodable, Sendable {
    public let move: String
    public let when: [String]
    /// Whose move it is per tier. Read from `owner` when the flow has it, else from `who`: a
    /// Bton older than 0.14.0 reads an unknown `who` value (`reviewer`) as a login and stalls, so a
    /// team switching writes `"who": "assignee", "owner": "reviewer"` until every Mac has
    /// updated, and folds `owner` into `who` afterwards.
    public let who: PerTier<String>

    private enum CodingKeys: String, CodingKey { case move, when, who, owner }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        move = try container.decode(String.self, forKey: .move)
        when = try container.decode([String].self, forKey: .when)
        who = try container.decodeIfPresent(PerTier<String>.self, forKey: .owner)
            ?? container.decode(PerTier<String>.self, forKey: .who)
    }
}

/// A review's independent second reviewer: another agent run beside the first in the same job,
/// with its own prompt and transcript; Bton merges both findings tables into the one review posted.
public struct SecondReviewer: Decodable, Sendable {
    public let agent: PerTier<String>
    public let prompt: PerTier<String>
}

public struct DispatchRule: Decodable, Sendable {
    public let agent: PerTier<String>?
    public let prompt: PerTier<String>?
    /// The second reviewer, for the tiers where both its agent and prompt have a value.
    public let second: SecondReviewer?
    /// `"comment"`: Bton posts the agent's final message as the review comment.
    public let post: String?
    /// An argv run instead of an agent (merge).
    public let command: [String]?
    public let timeoutMinutes: Int?
    /// Absent or `true`: the flow's `checks` run before this move. `false`: none run, as for a
    /// `resolve` agent working on a PR that conflicts with its base, which a merge check would
    /// refuse. A list of argv: the move's own gates run instead of the flow's, so a review is
    /// stopped by a lint or type error that a `fix` move must be allowed to reach.
    public let checks: RuleChecks?
    /// Agents on the Mac that runs the move which its Claude may ask (Bton's `ask` tool): the
    /// sandbox keeps them from running from the agent's Bash.
    public let helpers: [String]?

    public var timeout: Duration { .seconds(60 * (timeoutMinutes ?? 60)) }
}

/// What runs before a move: the flow's `checks`, none, or the move's own argv in their place.
public enum RuleChecks: Decodable, Equatable, Sendable {
    case flow
    case none
    case own([[String]])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) { self = flag ? .flow : .none; return }
        if let argv = try? container.decode([[String]].self) { self = .own(argv); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "checks must be true, false or a list of argv")
    }
}

public struct Checks: Decodable, Sendable {
    public let beforeSession: [[String]]
    public let beforeMerge: [[String]]
    /// Checks never covered by an earlier run's receipt: one that reads a service or the clock is
    /// not a function of the tree.
    public let fresh: [[String]]?
    /// Groups of argv a team declares independent: consecutive checks of one group run at the
    /// same time. Declared, never inferred.
    public let together: [[[String]]]?
}

public struct Intake: Decodable, Sendable {
    public let search: [String]
    public let priority: [String]
    public let claim: [[String]]
    public let worktree: [String]
    public let worktreePath: String
    public let type: IssueType
    public let agent: String
    public let prompt: String
    public let timeoutMinutes: Int?

    public struct IssueType: Decodable, Sendable {
        public let `default`: String
        public let labels: [String: String]
    }
}

public struct Caps: Decodable, Sendable {
    public let openPullRequestsPerDeveloper: Int
    public let openPullRequestsTeam: Int
}

public struct Stale: Decodable, Sendable {
    public let pingHours: Double
    public let escalateHours: Double
    public let escalateTo: String
}

/// One value for every tier, or one per tier name.
public enum PerTier<Value: Decodable & Sendable>: Decodable, Sendable {
    case same(Value)
    case byTier([String: Value])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Value.self) {
            self = .same(value)
        } else {
            self = .byTier(try container.decode([String: Value].self))
        }
    }

    public func value(for tier: String) -> Value? {
        switch self {
        case let .same(value): value
        case let .byTier(values): values[tier]
        }
    }

    public var allValues: [Value] {
        switch self {
        case let .same(value): [value]
        case let .byTier(values): Array(values.values)
        }
    }
}
