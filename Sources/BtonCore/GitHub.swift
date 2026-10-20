import Foundation

/// Reads pull requests through the user's own `gh` login, so Bton holds no token.
public struct GitHubClient: Sendable {
    public enum Failure: Error, LocalizedError {
        case ghNotFound
        case ghFailed(status: Int32, stderr: String)
        case invalidBranch(String)

        public var errorDescription: String? {
            switch self {
            case .ghNotFound: "gh not found. Install the GitHub CLI and run gh auth login."
            case let .ghFailed(status, stderr): "gh exited \(status): \(stderr.prefix(300))"
            case let .invalidBranch(name): "\(name.prefix(100)) is not a branch Bton can read; pick another in Settings → Repos."
            }
        }
    }

    // A menu bar app launched from Finder gets a minimal PATH, so look where Homebrew installs.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    let ghPath: String
    private let runner = ProcessRunner()

    public init() throws {
        guard let path = Self.ghCandidates.first(where: FileManager.default.isExecutableFile) else {
            throw Failure.ghNotFound
        }
        ghPath = path
    }

    /// A given `gh`, such as a test's stand-in.
    init(ghPath: String) {
        self.ghPath = ghPath
    }

    /// One GraphQL query per repo per tick (one per 100 open PRs): everything the flow needs for
    /// every open PR. The last 100 comments, not the first, so a long PR's latest review is never
    /// paged off.
    public func openPullRequests(repo: String) async throws -> OpenPullRequests {
        let parts = repo.split(separator: "/").map(String.init)
        var pullRequests: [PullRequest] = [], after: String?
        while true {
            // -f, not -F: -F would turn a repo named "123" into a number.
            var arguments = ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                             "-f", "query=\(Self.openPullRequestsQuery)"]
            if let after { arguments += ["-f", "after=\(after)"] }
            let page = try Self.decodeOpenPullRequests(try await gh(arguments), repo: repo)
            pullRequests += page.pullRequests
            guard let next = page.nextPage else {
                return OpenPullRequests(viewer: page.viewer, defaultBranch: page.defaultBranch,
                                        pullRequests: pullRequests)
            }
            after = next
        }
    }

    /// The flow file from the default branch; nil when the repo has none. Never a PR branch's
    /// copy, so a PR cannot change what Bton runs.
    /// The flow on `branch`, or on the default branch when nil.
    public func flowFile(repo: String, branch: String? = nil) async throws -> Data? {
        // A name that fails the check is refused, never read as "the default branch".
        if let branch, !WatchedRepo.isBranchName(branch) { throw Failure.invalidBranch(branch) }
        let ref = branch.map { "?ref=\($0)" } ?? ""
        let result = try await runner.run(ghPath, ["api", "repos/\(repo)/contents/\(Flow.relativePath)\(ref)",
                                                   "-H", "Accept: application/vnd.github.raw"], timeout: .seconds(60))
        if result.status != 0, result.stderr.contains("HTTP 404") { return nil }
        guard result.status == 0 else { throw Failure.ghFailed(status: result.status, stderr: result.stderr) }
        return result.stdout
    }

    /// This Mac's `gh` login.
    public func viewer() async throws -> String {
        String(decoding: try await gh(["api", "user", "--jq", ".login"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A REST GET; nil on 404.
    func get(_ path: String) async throws -> Data? {
        let result = try await runner.run(ghPath, ["api", path], timeout: .seconds(60))
        if result.status != 0, result.stderr.contains("HTTP 404") { return nil }
        guard result.status == 0 else { throw Failure.ghFailed(status: result.status, stderr: result.stderr) }
        return result.stdout
    }

    /// The repo's canonical `owner/name`; throws when it does not exist or the user cannot read it.
    public func canonicalName(of repo: String) async throws -> String {
        let data = try await gh(["repo", "view", repo, "--json", "nameWithOwner"])
        struct Row: Decodable { let nameWithOwner: String }
        return try JSONDecoder().decode(Row.self, from: data).nameWithOwner
    }

    public func mergedPullRequests(repo: String, limit: Int = 30) async throws -> [MergedPullRequest] {
        let data = try await gh(["pr", "list", "--repo", repo, "--state", "merged", "--limit", String(limit),
                                 "--json", "number,title,author,url,mergedAt,headRefName,headRefOid"])
        return try Self.decodeMerged(data, repo: repo)
    }

    /// Posts a comment whose body Bton wrote or validated; never PR text passed through.
    public func comment(repo: String, number: Int, bodyFile: URL) async throws {
        _ = try await gh(["pr", "comment", String(number), "--repo", repo, "--body-file", bodyFile.path])
    }

    public func addAssignee(_ login: String, repo: String, number: Int) async throws {
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--add-assignee", login])
    }

    public func removeLabel(_ label: String, repo: String, number: Int) async throws {
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--remove-label", label])
    }

    func gh(_ arguments: [String]) async throws -> Data {
        let result = try await runner.run(ghPath, arguments, timeout: .seconds(60))
        guard result.status == 0 else { throw Failure.ghFailed(status: result.status, stderr: result.stderr) }
        return result.stdout
    }

    // MARK: decoding (static so tests feed captured gh output)

    private struct Author: Decodable { let login: String }
    private struct Nodes<Node: Decodable>: Decodable { let nodes: [Node] }
    private struct Name: Decodable { let name: String }

    static let openPullRequestsQuery = """
    query($owner: String!, $name: String!, $after: String) {
      viewer { login }
      repository(owner: $owner, name: $name) {
        defaultBranchRef { name }
        pullRequests(states: OPEN, first: 100, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number title url isDraft headRefOid headRefName baseRefName body updatedAt authorAssociation mergeable
            author { login }
            labels(first: 100) { nodes { name } }
            assignees(first: 10) { nodes { login } }
            comments(last: 100) { nodes { author { login } authorAssociation body createdAt } }
            commits(last: 1) { nodes { commit { committedDate } } }
          }
        }
      }
    }
    """

    private struct OpenResponse: Decodable {
        struct Payload: Decodable { let viewer: Author; let repository: Repository }
        struct Repository: Decodable { let defaultBranchRef: Name?; let pullRequests: Page }
        struct Page: Decodable { let pageInfo: PageInfo?; let nodes: [Row] }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Row: Decodable {
            let number: Int, title: String, url: URL, isDraft: Bool, headRefOid: String, headRefName: String
            let baseRefName: String, body: String, updatedAt: Date, authorAssociation: String, mergeable: String?
            let author: Author?, labels: Nodes<Name>, assignees: Nodes<Author>, comments: Nodes<Comment>
            let commits: Nodes<CommitNode>?
        }
        struct CommitNode: Decodable { struct Commit: Decodable { let committedDate: Date }; let commit: Commit }
        struct Comment: Decodable { let author: Author?; let authorAssociation: String?; let body: String; let createdAt: Date }
        let data: Payload
    }

    private struct MergedRow: Decodable {
        let number: Int, title: String, author: Author, url: URL, mergedAt: Date
        let headRefName: String?, headRefOid: String?
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Bton's own comments are dropped here, so they never change a move.
    public static func decodeOpenPullRequests(_ data: Data, repo: String) throws -> OpenPullRequests {
        let payload = try decoder.decode(OpenResponse.self, from: data).data
        let pullRequests = payload.repository.pullRequests.nodes.map { row in
            var pr = PullRequest(repo: repo, number: row.number, title: row.title, author: row.author?.login ?? "ghost",
                        authorAssociation: row.authorAssociation, url: row.url, headSha: row.headRefOid,
                        headRef: row.headRefName, baseRef: row.baseRefName, body: row.body, isDraft: row.isDraft,
                        labels: row.labels.nodes.map(\.name), assignees: row.assignees.nodes.map(\.login),
                        comments: row.comments.nodes
                            .filter { !$0.body.contains(BtonMarker.prefix) }
                            .map { PullRequestComment(author: $0.author?.login, authorAssociation: $0.authorAssociation,
                                                       body: $0.body, createdAt: $0.createdAt) }
                            .sorted { $0.createdAt < $1.createdAt },
                        updatedAt: row.updatedAt)
            pr.headCommittedAt = row.commits?.nodes.last?.commit.committedDate
            pr.conflicting = row.mergeable == "CONFLICTING"
            pr.btonMarkers = Set(row.comments.nodes.flatMap { BtonMarker.keys(in: $0.body) })
            return pr
        }
        let page = payload.repository.pullRequests.pageInfo
        return OpenPullRequests(viewer: payload.viewer.login,
                                defaultBranch: payload.repository.defaultBranchRef?.name ?? "",
                                pullRequests: pullRequests,
                                nextPage: page?.hasNextPage == true ? page?.endCursor : nil)
    }

    public static func decodeMerged(_ data: Data, repo: String) throws -> [MergedPullRequest] {
        try decoder.decode([MergedRow].self, from: data).map {
            MergedPullRequest(repo: repo, number: $0.number, title: $0.title, author: $0.author.login,
                              url: $0.url, mergedAt: $0.mergedAt, totalCost: nil,
                              headRef: $0.headRefName ?? "", headSha: $0.headRefOid ?? "")
        }
    }
}
