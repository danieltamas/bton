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
          ... on Issue { number issueState: state createdAt labels(first: 30) { nodes { name } } \
        timelineItems(itemTypes: [LABELED_EVENT], last: 30) { nodes { ... on LabeledEvent { createdAt label { name } } } } }
          ... on PullRequest { number prState: state createdAt mergedAt baseRefName mergeCommit { oid } }
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
            // The two `state` enums differ, so the query reads each under its own name; a
            // response made by hand (fixtures, an older cache) may still say `state`.
            let issueState: String?
            let prState: String?
            let plainState: String?
            var state: String { issueState ?? prState ?? plainState ?? "" }

            enum CodingKeys: String, CodingKey {
                case __typename, number, issueState, prState, createdAt, mergedAt, baseRefName, mergeCommit, labels, timelineItems
                case plainState = "state"
            }
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
        struct Problem: Decodable { let type: String?; let message: String? }
        let data: Payload
        let errors: [Problem]?
    }

    public struct QueryFailure: Error, LocalizedError {
        public let messages: [String]
        public var errorDescription: String? { "facts query: " + messages.joined(separator: "; ") }
    }

    public static func decode(_ data: Data) throws -> FeatureFacts {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var facts = FeatureFacts()
        let response = try decoder.decode(Response.self, from: data)
        // A number that is no issue or PR of the repo comes back as a NOT_FOUND beside the rest of
        // the data: that link is ignored, the others are read. Any other error is a failed read.
        let failures = (response.errors ?? []).filter { $0.type != "NOT_FOUND" }
        guard failures.isEmpty else { throw QueryFailure(messages: failures.map { $0.message ?? "unknown error" }) }
        for case let node? in response.data.repository.values {
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
            let result = try await runner.run(ghPath, ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                                                       "-f", "query=\(FeatureFacts.query(numbers: page))"], timeout: .seconds(60))
            // gh exits 1 when the response carries errors but still prints it; the decoder tells
            // a NOT_FOUND (one link, ignored) from a failure.
            guard result.status == 0 || !result.stdout.isEmpty else {
                throw Failure.ghFailed(status: result.status, stderr: result.stderr)
            }
            facts.merge(try FeatureFacts.decode(result.stdout))
        }
        return facts
    }
}
