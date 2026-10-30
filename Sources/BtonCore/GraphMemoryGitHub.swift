import Foundation

extension GitHubClient {
    /// How many pages one refresh reads at most: the first export of a busy repo takes several,
    /// a sync after it one, and a GitHub that keeps paging never holds a sync.
    static let memoryPages = 12

    /// The repo's issues and PRs changed since `since`, newest first, read in pages of 50 a side
    /// until a page ends older than `since`. nil reaches `GraphMemory.firstReach` back.
    public func memoryItems(repo: String, since: Date?, now: Date) async throws -> GraphMemory.Items {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return GraphMemory.Items() }
        let floor = since ?? now.addingTimeInterval(-GraphMemory.firstReach)
        var items = GraphMemory.Items()
        var issuesAfter: String?, prsAfter: String?
        var moreIssues = true, morePRs = true
        for _ in 0..<Self.memoryPages where moreIssues || morePRs {
            var arguments = ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                             "-f", "query=\(Self.memoryQuery)", "-F", "issues=\(moreIssues)", "-F", "prs=\(morePRs)"]
            if let issuesAfter { arguments += ["-f", "issuesAfter=\(issuesAfter)"] }
            if let prsAfter { arguments += ["-f", "prsAfter=\(prsAfter)"] }
            let page = try Self.decodeMemoryItems(try await gh(arguments))
            // A page is taken whole (an item already exported writes nothing); a side stops when
            // its page ran out or its oldest item is older than the floor.
            items.issues += page.items.issues
            items.pullRequests += page.items.pullRequests
            moreIssues = moreIssues && page.issuesNext != nil && (page.items.issues.last?.updatedAt ?? .distantPast) >= floor
            morePRs = morePRs && page.prsNext != nil && (page.items.pullRequests.last?.updatedAt ?? .distantPast) >= floor
            issuesAfter = page.issuesNext
            prsAfter = page.prsNext
        }
        return items
    }

    public static let memoryQuery = """
    query($owner: String!, $name: String!, $issuesAfter: String, $prsAfter: String, $issues: Boolean!, $prs: Boolean!) {
      repository(owner: $owner, name: $name) {
        issues(states: [OPEN, CLOSED], first: 50, after: $issuesAfter, orderBy: {field: UPDATED_AT, direction: DESC}) @include(if: $issues) {
          pageInfo { hasNextPage endCursor }
          nodes { number title state createdAt updatedAt closedAt author { login } body
            labels(first: 30) { nodes { name } }
            comments(last: 50) { nodes { databaseId author { login } body createdAt } } }
        }
        pullRequests(states: [OPEN, MERGED, CLOSED], first: 50, after: $prsAfter, orderBy: {field: UPDATED_AT, direction: DESC}) @include(if: $prs) {
          pageInfo { hasNextPage endCursor }
          nodes { number title state createdAt updatedAt mergedAt baseRefName headRefName author { login } body
            files(first: 100) { nodes { path } }
            reviews(last: 30) { nodes { author { login } state body submittedAt } }
            comments(last: 50) { nodes { databaseId author { login } body createdAt } } }
        }
      }
    }
    """

    private struct MemoryResponse: Decodable {
        struct Author: Decodable { let login: String }
        struct Nodes<Node: Decodable>: Decodable { let nodes: [Node] }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Page<Node: Decodable>: Decodable { let pageInfo: PageInfo?; let nodes: [Node] }
        struct Label: Decodable { let name: String }
        struct File: Decodable { let path: String }
        struct Comment: Decodable { let databaseId: Int?, author: Author?, body: String, createdAt: Date }
        struct Review: Decodable { let author: Author?, state: String, body: String, submittedAt: Date? }
        struct Issue: Decodable {
            let number: Int, title: String, state: String, createdAt: Date, updatedAt: Date, closedAt: Date?
            let author: Author?, body: String, labels: Nodes<Label>?, comments: Nodes<Comment>?
        }
        struct PullRequest: Decodable {
            let number: Int, title: String, state: String, createdAt: Date, updatedAt: Date, mergedAt: Date?
            let baseRefName: String, headRefName: String, author: Author?, body: String
            let files: Nodes<File>?, reviews: Nodes<Review>?, comments: Nodes<Comment>?
        }
        struct Repository: Decodable { let issues: Page<Issue>?, pullRequests: Page<PullRequest>? }
        struct Payload: Decodable { let repository: Repository }
        let data: Payload
    }

    /// One page as the query returns it; a connection the page left out (its flag was false) is empty.
    public static func decodeMemoryItems(_ data: Data) throws -> (items: GraphMemory.Items, issuesNext: String?, prsNext: String?) {
        let repository = try issueDecoder.decode(MemoryResponse.self, from: data).data.repository
        func comments(_ nodes: MemoryResponse.Nodes<MemoryResponse.Comment>?) -> [IssueComment] {
            (nodes?.nodes ?? []).map {
                IssueComment(id: $0.databaseId.map(String.init) ?? "", author: $0.author?.login, authorAssociation: nil,
                             body: $0.body, createdAt: $0.createdAt, url: nil)
            }.sorted { $0.createdAt < $1.createdAt }
        }
        let issues = (repository.issues?.nodes ?? []).map {
            GraphMemory.Issue(number: $0.number, title: $0.title, state: $0.state, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                              closedAt: $0.closedAt, author: $0.author?.login, body: $0.body,
                              labels: $0.labels?.nodes.map(\.name) ?? [], comments: comments($0.comments))
        }
        let prs = (repository.pullRequests?.nodes ?? []).map {
            GraphMemory.PullRequestRecord(number: $0.number, title: $0.title, state: $0.state, createdAt: $0.createdAt,
                                          updatedAt: $0.updatedAt, mergedAt: $0.mergedAt, baseRef: $0.baseRefName,
                                          headRef: $0.headRefName, author: $0.author?.login, body: $0.body,
                                          files: $0.files?.nodes.map(\.path) ?? [],
                                          reviews: ($0.reviews?.nodes ?? []).map {
                                              GraphMemory.Review(author: $0.author?.login, state: $0.state, body: $0.body, submittedAt: $0.submittedAt)
                                          },
                                          comments: comments($0.comments))
        }
        func next(_ info: MemoryResponse.PageInfo?) -> String? { info?.hasNextPage == true ? info?.endCursor : nil }
        return (GraphMemory.Items(issues: issues, pullRequests: prs), next(repository.issues?.pageInfo), next(repository.pullRequests?.pageInfo))
    }
}
