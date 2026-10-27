import Foundation

/// What GitHub knows about the issues and PRs a registry links: enough for every status and its
/// date, read in one GraphQL query per `chunk` numbers rather than one call per link.
public struct FeatureFacts: Sendable, Equatable {
    public struct IssueFact: Sendable, Equatable {
        public let number: Int
        public let open: Bool
        public let createdAt: Date
        public let labels: [String]
        /// When each label was last added, from the issue's last 30 label events.
        public let labeledAt: [String: Date]

        public init(number: Int, open: Bool, createdAt: Date, labels: [String], labeledAt: [String: Date]) {
            self.number = number
            self.open = open
            self.createdAt = createdAt
            self.labels = labels
            self.labeledAt = labeledAt
        }
    }

    public struct PullRequestFact: Sendable, Equatable {
        public let number: Int
        /// OPEN, MERGED or CLOSED, as GitHub says.
        public let state: String
        public let createdAt: Date
        public let mergedAt: Date?
        public let mergeCommit: String?
        public let baseRef: String

        public init(number: Int, state: String, createdAt: Date, mergedAt: Date?, mergeCommit: String?, baseRef: String) {
            self.number = number
            self.state = state
            self.createdAt = createdAt
            self.mergedAt = mergedAt
            self.mergeCommit = mergeCommit
            self.baseRef = baseRef
        }
    }

    public var issues: [Int: IssueFact] = [:]
    public var pullRequests: [Int: PullRequestFact] = [:]

    public init(issues: [Int: IssueFact] = [:], pullRequests: [Int: PullRequestFact] = [:]) {
        self.issues = issues
        self.pullRequests = pullRequests
    }

    /// Aliases per query: GitHub's node limit allows more, but a registry's links are read in
    /// pages of this size so one unknown number costs one page at most.
    public static let chunk = 50

    /// One alias per number: a number GitHub does not know comes back null and is skipped.
    public static func query(numbers: [Int]) -> String {
        let fields = """
          __typename
          ... on Issue { number state createdAt labels(first: 30) { nodes { name } } \
        timelineItems(itemTypes: [LABELED_EVENT], last: 30) { nodes { ... on LabeledEvent { createdAt label { name } } } } }
          ... on PullRequest { number state createdAt mergedAt baseRefName mergeCommit { oid } }
        """
        let aliases = numbers.map { "    n\($0): issueOrPullRequest(number: \($0)) {\n\(fields)\n    }" }
        return """
        query($owner: String!, $name: String!) {
          repository(owner: $owner, name: $name) {
        \(aliases.joined(separator: "\n"))
          }
        }
        """
    }

    private struct Response: Decodable {
        struct Payload: Decodable { let repository: [String: Node?] }
        struct Node: Decodable {
            let __typename: String
            let number: Int
            let state: String
            let createdAt: Date
            let mergedAt: Date?
            let baseRefName: String?
            let mergeCommit: Commit?
            let labels: Nodes<Label>?
            let timelineItems: Nodes<Event>?
        }
        struct Nodes<Element: Decodable>: Decodable { let nodes: [Element] }
        struct Label: Decodable { let name: String }
        struct Commit: Decodable { let oid: String }
        struct Event: Decodable { let createdAt: Date?; let label: Label? }
        let data: Payload
    }

    public static func decode(_ data: Data) throws -> FeatureFacts {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var facts = FeatureFacts()
        for case let node? in try decoder.decode(Response.self, from: data).data.repository.values {
            switch node.__typename {
            case "Issue":
                var labeledAt: [String: Date] = [:]
                for event in node.timelineItems?.nodes ?? [] {
                    guard let name = event.label?.name, let at = event.createdAt else { continue }
                    labeledAt[name] = max(labeledAt[name] ?? .distantPast, at)
                }
                facts.issues[node.number] = IssueFact(number: node.number, open: node.state == "OPEN", createdAt: node.createdAt,
                                                      labels: node.labels?.nodes.map(\.name) ?? [], labeledAt: labeledAt)
            case "PullRequest":
                facts.pullRequests[node.number] = PullRequestFact(number: node.number, state: node.state, createdAt: node.createdAt,
                                                                  mergedAt: node.mergedAt, mergeCommit: node.mergeCommit?.oid,
                                                                  baseRef: node.baseRefName ?? "")
            default: continue
            }
        }
        return facts
    }

    public mutating func merge(_ other: FeatureFacts) {
        issues.merge(other.issues) { _, new in new }
        pullRequests.merge(other.pullRequests) { _, new in new }
    }
}

extension GitHubClient {
    /// The facts for every number, a page per `FeatureFacts.chunk`.
    public func featureFacts(repo: String, numbers: [Int]) async throws -> FeatureFacts {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return FeatureFacts() }
        var facts = FeatureFacts()
        for start in stride(from: 0, to: numbers.count, by: FeatureFacts.chunk) {
            let page = Array(numbers[start..<min(start + FeatureFacts.chunk, numbers.count)])
            let data = try await gh(["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                                     "-f", "query=\(FeatureFacts.query(numbers: page))"])
            facts.merge(try FeatureFacts.decode(data))
        }
        return facts
    }
}
