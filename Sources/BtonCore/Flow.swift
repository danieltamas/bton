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
            for (move, rule) in flow.dispatch {
                if let helpers = rule.helpers, helpers.count > 3 || !helpers.allSatisfy(BtonConfig.isAgentName) {
                    return .invalid("dispatch.\(move).helpers: up to three agent names")
                }
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

    enum CodingKeys: String, CodingKey { case marker, values, defaultTier = "default" }
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
    public let who: PerTier<String>
}

public struct DispatchRule: Decodable, Sendable {
    public let agent: PerTier<String>?
    public let prompt: PerTier<String>?
    /// `"comment"`: Bton posts the agent's final message as the review comment.
    public let post: String?
    /// An argv run instead of an agent (merge).
    public let command: [String]?
    public let timeoutMinutes: Int?
    /// false: the flow's `checks` do not run before this move. A `resolve` agent works on a PR
    /// that conflicts with its base, which a merge check would refuse.
    public let checks: Bool?
    /// Agents on the Mac that runs the move which its Claude may ask (Bton's `ask` tool): the
    /// sandbox keeps them from running from the agent's Bash.
    public let helpers: [String]?

    public var timeout: Duration { .seconds(60 * (timeoutMinutes ?? 60)) }
}

public struct Checks: Decodable, Sendable {
    public let beforeSession: [[String]]
    public let beforeMerge: [[String]]
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
