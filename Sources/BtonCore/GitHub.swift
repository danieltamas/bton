import Foundation

/// Reads pull requests through the user's own `gh` login, so Bton holds no token.
public struct GitHubClient: Sendable {
    public enum Failure: Error, LocalizedError {
        case ghNotFound
        case ghFailed(status: Int32, stderr: String)
        case invalidBranch(String)
        case noFailedRun(sha: String)

        public var errorDescription: String? {
            switch self {
            case let .noFailedRun(sha): "No failed workflow run on \(sha.prefix(12)): GitHub may still be reporting, or the red check is not an Actions workflow. Re-run it on GitHub."
            case .ghNotFound: "gh not found. Install the GitHub CLI and run gh auth login."
            case let .ghFailed(status, stderr): "gh exited \(status): \(stderr.prefix(300))"
            case let .invalidBranch(name): "\(name.prefix(100)) is not a branch Bton can read; pick another in Settings → Repos."
            }
        }
    }

    // A menu bar app launched from Finder gets a minimal PATH, so look where Homebrew installs.
    static let ghCandidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]

    let ghPath: String
    let runner = ProcessRunner()

    public init() throws {
        guard let path = Self.locateGh(resolve: Executables.resolve, candidates: Self.ghCandidates) else {
            throw Failure.ghNotFound
        }
        ghPath = path
    }

    /// The `gh` the agents' PATH finds (a custom Homebrew prefix linked into ~/.local/bin counts),
    /// else the first of the usual places that has one.
    static func locateGh(resolve: (String) -> String?, candidates: [String]) -> String? {
        resolve("gh") ?? candidates.first(where: FileManager.default.isExecutableFile)
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
                for index in pullRequests.indices where pullRequests[index].changedFilesTruncated {
                    await readAllFiles(of: &pullRequests[index])
                }
                return OpenPullRequests(viewer: page.viewer, defaultBranch: page.defaultBranch,
                                        pullRequests: pullRequests)
            }
            after = next
        }
    }

    /// GitHub lists at most this many files of a PR; a PR with more counts as too big to read.
    static let fileListLimit = 3000

    /// A PR with more than the first page of files gets the full list from the REST endpoint. A
    /// failed read leaves it marked truncated, so its tier counts as the highest.
    private func readAllFiles(of pr: inout PullRequest) async {
        guard let data = try? await gh(["api", "--paginate", "repos/\(pr.repo)/pulls/\(pr.number)/files?per_page=100",
                                        "--jq", ".[].filename"]) else { return }
        let files = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        guard files.count > pr.changedFiles.count else { return }
        pr.changedFiles = files
        pr.changedFilesTruncated = files.count >= Self.fileListLimit
    }

    /// The flow file from the default branch; nil when the repo has none. Never a PR branch's
    /// copy, so a PR cannot change what Bton runs.
    /// The flow on `branch`, or on the default branch when nil.
    public func flowFile(repo: String, branch: String? = nil) async throws -> Data? {
        try await file(repo: repo, path: Flow.relativePath, branch: branch)
    }

    /// A file of the repo on `branch`, or on the default branch when nil; nil when there is none.
    public func file(repo: String, path: String, branch: String? = nil) async throws -> Data? {
        // A name that fails the check is refused, never read as "the default branch".
        if let branch, !WatchedRepo.isBranchName(branch) { throw Failure.invalidBranch(branch) }
        let ref = branch.map { "?ref=\($0)" } ?? ""
        let result = try await runner.run(ghPath, ["api", "repos/\(repo)/contents/\(path)\(ref)",
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

    /// The PR's head commit on GitHub now.
    public func pullRequestHead(repo: String, number: Int) async throws -> String {
        try Self.decodeHead(try await gh(["pr", "view", String(number), "--repo", repo, "--json", "headRefOid"]))
    }

    /// The PR's head commit and state ("OPEN", "MERGED", "CLOSED") on GitHub now.
    public func pullRequestHeadAndState(repo: String, number: Int) async throws -> (head: String, state: String) {
        struct Row: Decodable { let headRefOid: String, state: String }
        let row = try JSONDecoder().decode(Row.self, from: try await gh(["pr", "view", String(number), "--repo", repo,
                                                                          "--json", "headRefOid,state"]))
        return (row.headRefOid, row.state)
    }

    static func decodeHead(_ data: Data) throws -> String {
        struct Row: Decodable { let headRefOid: String }
        return try JSONDecoder().decode(Row.self, from: data).headRefOid
    }

    public func mergedPullRequests(repo: String, limit: Int = 30) async throws -> [MergedPullRequest] {
        let data = try await gh(["pr", "list", "--repo", repo, "--state", "merged", "--limit", String(limit),
                                 "--json", "number,title,author,url,mergedAt,headRefName,headRefOid"])
        return try Self.decodeMerged(data, repo: repo)
    }

    /// Posts a comment whose body Bton wrote or validated; never PR text passed through.
    /// Opens a PR from `head` into `base`; GitHub refuses a second one on the same pair.
    public func createPullRequest(repo: String, base: String, head: String, title: String, bodyFile: URL) async throws {
        _ = try await gh(["pr", "create", "--repo", repo, "--base", base, "--head", head, "--title", title, "--body-file", bodyFile.path])
    }

    public func comment(repo: String, number: Int, bodyFile: URL) async throws {
        _ = try await gh(["pr", "comment", String(number), "--repo", repo, "--body-file", bodyFile.path])
    }

    /// Files a posted review's verdict as a GitHub review on the commit it read, so GitHub's own
    /// review request clears and its lists show the verdict. `summary` is the comment's validated
    /// first line; the full review stays in the comment.
    public func submitReview(_ verdict: Verdict, repo: String, number: Int, head: String, summary: String) async throws {
        _ = try await gh(["api", "--method", "POST", "repos/\(repo)/pulls/\(number)/reviews",
                          "-f", "commit_id=\(head)", "-f", "event=\(verdict == .approve ? "APPROVE" : "REQUEST_CHANGES")",
                          "-f", "body=\(summary)"])
    }

    /// The owner's reply on an issue, posted only when they press Post reply. The body is read
    /// from a file, never passed in argv.
    public func commentOnIssue(repo: String, number: Int, bodyFile: URL) async throws {
        _ = try await gh(["issue", "comment", String(number), "--repo", repo, "--body-file", bodyFile.path])
    }

    public func addAssignee(_ login: String, repo: String, number: Int) async throws {
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--add-assignee", login])
    }

    /// Makes `login` the PR's only assignee, in one edit.
    public func assign(_ login: String, replacing others: [String], repo: String, number: Int) async throws {
        let removed = others.filter { $0.caseInsensitiveCompare(login) != .orderedSame }
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--add-assignee", login]
                         + (removed.isEmpty ? [] : ["--remove-assignee", removed.joined(separator: ",")]))
    }

    public func addReviewer(_ login: String, repo: String, number: Int) async throws {
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--add-reviewer", login])
    }

    /// Makes `login` the PR's only requested reviewer, in one edit; assignees are not touched.
    public func requestReview(_ login: String, replacing others: [String], repo: String, number: Int) async throws {
        let removed = others.filter { $0.caseInsensitiveCompare(login) != .orderedSame }
        _ = try await gh(["pr", "edit", String(number), "--repo", repo, "--add-reviewer", login]
                         + (removed.isEmpty ? [] : ["--remove-reviewer", removed.joined(separator: ",")]))
    }

    /// Creates the label once when the repo lacks it (the add fails), then adds it again.
    public func addLabel(_ label: String, repo: String, number: Int) async throws {
        let add = ["pr", "edit", String(number), "--repo", repo, "--add-label", label]
        do {
            _ = try await gh(add)
        } catch {
            _ = try? await gh(["label", "create", label, "--repo", repo, "--description", "A Bton is working on this PR"])
            _ = try await gh(add)
        }
    }

    /// Runs the failed jobs of every workflow run on `sha` again, and names the workflows asked.
    /// The flow's gate reads the check on the head, so the re-run is on that exact commit;
    /// a head with no failed run (GitHub still reporting, or a check from outside Actions)
    /// throws, so nothing passes for a press that did nothing.
    public func rerunFailedRuns(repo: String, sha: String) async throws -> [String] {
        let data = try await gh(["run", "list", "--repo", repo, "--commit", sha, "--limit", "50",
                                 "--json", "databaseId,workflowName,conclusion"])
        let failed = try Self.failedRuns(data)
        guard !failed.isEmpty else {
            throw Failure.noFailedRun(sha: sha)
        }
        for run in failed {
            _ = try await gh(["run", "rerun", String(run.id), "--repo", repo, "--failed"])
        }
        return failed.map(\.workflow)
    }

    /// The workflow runs that ended in failure (or were cancelled or timed out), from `gh run list` JSON.
    static func failedRuns(_ data: Data) throws -> [(id: Int, workflow: String)] {
        struct Run: Decodable { let databaseId: Int; let workflowName: String; let conclusion: String }
        let rerun: Set<String> = ["failure", "cancelled", "timed_out", "startup_failure"]
        return try JSONDecoder().decode([Run].self, from: data)
            .filter { rerun.contains($0.conclusion) }
            .map { (id: $0.databaseId, workflow: $0.workflowName) }
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
            number title url isDraft headRefOid headRefName baseRefName body createdAt updatedAt authorAssociation mergeable isCrossRepository
            author { login }
            labels(first: 100) { nodes { name } }
            assignees(first: 10) { nodes { login } }
            reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login } } } }
            comments(last: 100) { nodes { author { login } authorAssociation body createdAt } }
            commits(last: 10) { nodes { commit { oid committedDate parents(first: 5) { nodes { oid } } } } }
            headCommit: commits(last: 1) { nodes { commit { statusCheckRollup { \(rollupFields) } } } }
            files(first: 100) { totalCount nodes { path } }
          }
        }
      }
    }
    """

    /// The checks of one commit, as both queries read them.
    static let rollupFields = """
    contexts(first: 50) { totalCount nodes { __typename ... on CheckRun { name status conclusion startedAt } ... on StatusContext { context state } } }
    """

    /// The checks on one commit, for the read right before a gated command.
    public static let checksQuery = """
    query($owner: String!, $name: String!, $oid: GitObjectID!) {
      repository(owner: $owner, name: $name) {
        object(oid: $oid) { ... on Commit { statusCheckRollup { \(rollupFields) } } }
      }
    }
    """

    /// The checks on `sha` now. Throws when GitHub does not know the commit or the read fails:
    /// a gate never passes on a guess.
    public func checks(repo: String, sha: String) async throws -> (checks: [CheckResult], truncated: Bool) {
        let parts = repo.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { throw Failure.ghFailed(status: 1, stderr: "not an owner/name repo: \(repo)") }
        return try Self.decodeChecks(try await gh(["api", "graphql", "-f", "query=\(Self.checksQuery)",
                                                   "-F", "owner=\(parts[0])", "-F", "name=\(parts[1])", "-F", "oid=\(sha)"]))
    }

    public static func decodeChecks(_ data: Data) throws -> (checks: [CheckResult], truncated: Bool) {
        struct Response: Decodable {
            struct Payload: Decodable { let repository: Repository }
            struct Repository: Decodable { let object: Object? }
            struct Object: Decodable { let statusCheckRollup: Rollup? }
            let data: Payload
        }
        guard let object = try decoder.decode(Response.self, from: data).data.repository.object else {
            throw Failure.ghFailed(status: 1, stderr: "GitHub does not know the commit")
        }
        return reduce(object.statusCheckRollup)
    }

    /// GitHub's rollup of check runs and statuses on a commit.
    struct Rollup: Decodable {
        struct Contexts: Decodable { let totalCount: Int?; let nodes: [Context] }
        struct Context: Decodable {
            let name: String?, status: String?, conclusion: String?, startedAt: Date?
            let context: String?, state: String?
        }
        let contexts: Contexts?
    }

    /// One result per name, the newest run of a name winning; nothing is read as green that
    /// GitHub did not call SUCCESS.
    static func reduce(_ rollup: Rollup?) -> (checks: [CheckResult], truncated: Bool) {
        guard let contexts = rollup?.contexts else { return ([], false) }
        var newest: [String: (started: Date?, state: CheckResult.State)] = [:]
        var order: [String] = []
        for node in contexts.nodes {
            let name: String, state: CheckResult.State
            if let runName = node.name {
                name = runName
                state = node.status != "COMPLETED" ? .pending : node.conclusion == "SUCCESS" ? .success : .failure
            } else if let context = node.context {
                name = context
                state = node.state == "SUCCESS" ? .success : ["PENDING", "EXPECTED"].contains(node.state ?? "") ? .pending : .failure
            } else { continue }
            if let earlier = newest[name] {
                // A run without a start is the one just created: it is the newest, wherever it
                // sits in the list; between two dated runs the later start wins.
                switch (node.startedAt, earlier.started) {
                case (nil, _): newest[name] = (nil, state)
                case (_, nil): break
                case let (started?, before?) where started > before: newest[name] = (started, state)
                default: break
                }
            } else {
                order.append(name)
                newest[name] = (node.startedAt, state)
            }
        }
        let truncated = (contexts.totalCount ?? contexts.nodes.count) > contexts.nodes.count
        return (order.map { CheckResult(name: $0, state: newest[$0]!.state) }, truncated)
    }

    private struct OpenResponse: Decodable {
        struct Payload: Decodable { let viewer: Author; let repository: Repository }
        struct Repository: Decodable { let defaultBranchRef: Name?; let pullRequests: Page }
        struct Page: Decodable { let pageInfo: PageInfo?; let nodes: [Row] }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Row: Decodable {
            let number: Int, title: String, url: URL, isDraft: Bool, headRefOid: String, headRefName: String
            let baseRefName: String, body: String, createdAt: Date?, updatedAt: Date, authorAssociation: String, mergeable: String?
            let isCrossRepository: Bool?
            let author: Author?, labels: Nodes<Name>, assignees: Nodes<Author>, comments: Nodes<Comment>
            let reviewRequests: Nodes<ReviewRequest>?
            let commits: Nodes<CommitNode>?
            let headCommit: Nodes<HeadCommit>?
            let files: Files?
        }
        struct HeadCommit: Decodable {
            struct Commit: Decodable { let statusCheckRollup: Rollup? }
            let commit: Commit
        }
        struct Files: Decodable { let totalCount: Int; let nodes: [Path] }
        /// A team's request decodes as a reviewer without a login.
        struct ReviewRequest: Decodable { let requestedReviewer: TeamOrUser? }
        struct TeamOrUser: Decodable { let login: String? }
        struct Path: Decodable { let path: String }
        struct CommitNode: Decodable {
            struct Commit: Decodable { let oid: String?; let committedDate: Date; let parents: Nodes<Oid>? }
            struct Oid: Decodable { let oid: String }
            let commit: Commit
        }
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

    /// The commits the head reaches through merge commits alone: what a conflict fix (the base merged
    /// in) leaves under it. A review of one of them still stands for the head, as a reviewer would
    /// carry it over; any other commit above a reviewed one makes the head new.
    private static func mergeOnlyAncestors(of head: String, in commits: [OpenResponse.CommitNode.Commit]) -> [String] {
        let byOid = Dictionary(commits.compactMap { commit in commit.oid.map { ($0, commit) } }, uniquingKeysWith: { first, _ in first })
        var found: [String] = []
        var queue = [head]
        while let oid = queue.popLast() {
            guard let parents = byOid[oid]?.parents?.nodes.map(\.oid), parents.count > 1 else { continue }
            for parent in parents where !found.contains(parent) {
                found.append(parent)
                queue.append(parent)
            }
        }
        return found
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
            pr.createdAt = row.createdAt
            pr.requestedReviewers = row.reviewRequests?.nodes.compactMap(\.requestedReviewer?.login) ?? []
            pr.headCommittedAt = row.commits?.nodes.last?.commit.committedDate
            pr.mergeOnlyAncestors = Self.mergeOnlyAncestors(of: row.headRefOid, in: row.commits?.nodes.map(\.commit) ?? [])
            pr.changedFiles = row.files?.nodes.map(\.path) ?? []
            // No file list at all (a partial answer) counts as too many to read: it never hides a sensitive path.
            pr.changedFilesTruncated = row.files.map { $0.totalCount > $0.nodes.count } ?? true
            // Unanswered counts as a fork: a branch pair alone never names the release PR.
            pr.isCrossRepository = row.isCrossRepository ?? true
            (pr.checks, pr.checksTruncated) = Self.reduce(row.headCommit?.nodes.first?.commit.statusCheckRollup)
            pr.conflicting = row.mergeable == "CONFLICTING"
            pr.mergeable = row.mergeable == "MERGEABLE"
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
