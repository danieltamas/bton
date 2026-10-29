import Foundation

/// An open issue as one sync reads it: enough to find a question put to the owner.
public struct OpenIssue: Hashable, Sendable {
    public let repo: String
    public let number: Int
    public let title: String
    public let url: URL
    public let createdAt: Date
    /// nil for a deleted account.
    public let author: String?
    public let authorAssociation: String
    public let body: String
    /// Oldest first, the last 20.
    public let comments: [IssueComment]
    public let labels: [String]
    /// Logins of whoever has taken the issue.
    public let assignees: [String]

    public init(repo: String, number: Int, title: String, url: URL, createdAt: Date, author: String?,
                authorAssociation: String, body: String, comments: [IssueComment], labels: [String] = [],
                assignees: [String] = []) {
        self.labels = labels
        self.assignees = assignees
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.author = author
        self.authorAssociation = authorAssociation
        self.body = body
        self.comments = comments
    }
}

/// One page of a repo's open issues, with the cursor of the next.
public struct OpenIssues: Sendable {
    public let issues: [OpenIssue]
    /// The cursor after the last issue read of the main connection; nil on the last page.
    public var nextPage: String?

    public init(issues: [OpenIssue], nextPage: String? = nil) {
        self.issues = issues
        self.nextPage = nextPage
    }
}

public struct IssueComment: Hashable, Sendable {
    /// GitHub's databaseId, as text.
    public let id: String
    public let author: String?
    public let authorAssociation: String?
    public let body: String
    public let createdAt: Date
    public let url: URL?

    public init(id: String, author: String?, authorAssociation: String?, body: String, createdAt: Date, url: URL?) {
        self.id = id
        self.author = author
        self.authorAssociation = authorAssociation
        self.body = body
        self.createdAt = createdAt
        self.url = url
    }
}

/// A teammate's question to the owner on an issue, not answered yet.
public struct IssueAsk: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String
    public let number: Int
    public let title: String
    /// The asking comment, or the issue when the body asks.
    public let url: URL
    public let asker: String
    public let askedAt: Date
    /// "body" when the issue's body is the ask.
    public let commentID: String
    /// Whether an agent may work on it: the issue's author has write access too, as for a PR.
    public let draftable: Bool
    /// The comment carries a `bton handoff` marker for me: an agent or a teammate sent it on purpose.
    public let handoff: Bool
    /// The whole conversation the ask sits in, for reading while the reply is edited: the issue
    /// body first (id "body"), then its comments oldest first, the asking one at `commentID`.
    public let thread: [IssueComment]

    public init(repo: String, number: Int, title: String, url: URL, asker: String, askedAt: Date, commentID: String,
                draftable: Bool = true, handoff: Bool = false, thread: [IssueComment] = []) {
        self.handoff = handoff
        self.thread = thread
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.asker = asker
        self.askedAt = askedAt
        self.commentID = commentID
        self.draftable = draftable
    }
}

/// Which open issues ask the owner something. Only the mention is looked for; the text itself
/// never reaches a prompt or an argv.
public enum IssueAsks {
    public static func mentions(_ text: String, login: String) -> Bool {
        guard !login.isEmpty else { return false }
        // Fences first (closed by a run at least as long, or the end), then spans: a span closes
        // on a run of exactly as many backticks, within its paragraph.
        // GitHub keeps the CRLF a browser sends; "\r\n" is one Character, never "\n".
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let prose = replacing(#"(?m)^ {0,3}(`{3,})[^\n]*\n?[\s\S]*?(?:^ {0,3}\1`*[ \t]*$|\z)"#, in: text)
        let escaped = NSRegularExpression.escapedPattern(for: login)
        return matches("(?i)(?<![A-Za-z0-9_/-])@\(escaped)(?![A-Za-z0-9_-])", in: withoutCodeSpans(prose))
    }

    /// CommonMark's code spans blanked out: a run of backticks opens one, closed by the next run
    /// of exactly as many within the paragraph. Outside a span a backslash escapes the next
    /// character; inside one it is literal.
    static func withoutCodeSpans(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        func run(at start: Int) -> Int {
            var end = start
            while end < characters.count, characters[end] == "`" { end += 1 }
            return end - start
        }
        func blankLine(after newline: Int) -> Bool {
            var next = newline + 1
            while next < characters.count, characters[next] == " " || characters[next] == "\t" { next += 1 }
            return next < characters.count && characters[next] == "\n"
        }
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count {
                result.append(character)
                result.append(characters[index + 1])
                index += 2
                continue
            }
            guard character == "`" else {
                result.append(character)
                index += 1
                continue
            }
            let length = run(at: index)
            var close = index + length
            var closed: Int?
            while close < characters.count {
                if characters[close] == "`" {
                    let other = run(at: close)
                    if other == length { closed = close + other; break }
                    close += other
                } else if characters[close] == "\n", blankLine(after: close) {
                    break
                } else {
                    close += 1
                }
            }
            if let closed {
                result.append(" ")
                index = closed
            } else {
                result.append(String(repeating: "`", count: length))
                index += length
            }
        }
        return result
    }

    /// Swift's `Regex` has no lookbehind, so these go through `NSRegularExpression`.
    private static func replacing(_ pattern: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func ask(in issue: OpenIssue, me: String) -> IssueAsk? {
        let isMe = { (login: String?) in login?.caseInsensitiveCompare(me) == .orderedSame }
        let entries = [IssueComment(id: "body", author: issue.author, authorAssociation: issue.authorAssociation,
                                    body: issue.body, createdAt: issue.createdAt, url: nil)]
            + issue.comments.sorted { $0.createdAt < $1.createdAt }
        guard let index = entries.lastIndex(where: { entry in
            guard let author = entry.author, !isMe(author),
                  entry.authorAssociation.map(FlowEngine.trustedAssociations.contains) == true else { return false }
            return mentions(entry.body, login: me)
        }) else { return nil }
        guard !entries[(index + 1)...].contains(where: { isMe($0.author) }) else { return nil }
        let entry = entries[index]
        return IssueAsk(repo: issue.repo, number: issue.number, title: issue.title, url: entry.url ?? issue.url,
                        asker: entry.author ?? "ghost", askedAt: entry.createdAt, commentID: entry.id,
                        draftable: FlowEngine.trustedAssociations.contains(issue.authorAssociation),
                        handoff: Handoff.isHandoff(entry.body, to: me), thread: entries)
    }

    public static func asks(_ issues: [OpenIssue], me: String) -> [IssueAsk] {
        issues.compactMap { ask(in: $0, me: me) }.sorted { $0.askedAt > $1.askedAt }
    }
}

extension GitHubClient {
    /// One GraphQL query per page: 50 open issues updated last, each with its latest 20 comments,
    /// and on the first page apart from them the open issues at `stage:ready` or
    /// `stage:in-progress`, which a quiet repo's oldest ready issue would otherwise fall out of.
    /// `after` is the previous page's `nextPage`.
    public func openIssues(repo: String, after: String? = nil) async throws -> OpenIssues {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return OpenIssues(issues: []) }
        // -f for the strings (a repo named "123" stays text); -F for the Boolean.
        var arguments = ["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                         "-F", "firstPage=\(after == nil)", "-f", "query=\(Self.openIssuesQuery)"]
        if let after { arguments += ["-f", "after=\(after)"] }
        return try Self.decodeOpenIssues(try await gh(arguments), repo: repo)
    }

    /// The fields every issue read carries, on a connection or a single issue.
    static let issueFields = """
        number title url createdAt body authorAssociation
        author { login }
        labels(first: 30) { nodes { name } }
        assignees(first: 5) { nodes { login } }
        comments(last: 20) { nodes { databaseId author { login } authorAssociation body createdAt url } }
    """

    static let openIssuesQuery = """
    fragment Fields on IssueConnection {
      nodes {
    \(issueFields)
      }
    }
    query($owner: String!, $name: String!, $after: String, $firstPage: Boolean!) {
      repository(owner: $owner, name: $name) {
        issues(states: OPEN, first: 50, after: $after, orderBy: {field: UPDATED_AT, direction: DESC}) { pageInfo { hasNextPage endCursor } ...Fields }
        ready: issues(states: OPEN, labels: ["stage:ready"], first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) @include(if: $firstPage) { ...Fields }
        inProgress: issues(states: OPEN, labels: ["stage:in-progress"], first: 50, orderBy: {field: UPDATED_AT, direction: DESC}) @include(if: $firstPage) { ...Fields }
      }
    }
    """

    private struct IssuesResponse: Decodable {
        struct Author: Decodable { let login: String }
        struct Nodes<Node: Decodable>: Decodable { let nodes: [Node] }
        struct Payload: Decodable { let repository: Repository }
        struct Repository: Decodable { let issues: Page, ready: Nodes<Row>?, inProgress: Nodes<Row>? }
        struct Page: Decodable { let pageInfo: PageInfo?; let nodes: [Row] }
        struct PageInfo: Decodable { let hasNextPage: Bool; let endCursor: String? }
        struct Row: Decodable {
            let number: Int, title: String, url: URL, createdAt: Date, body: String, authorAssociation: String
            let author: Author?, comments: Nodes<Comment>, labels: Nodes<Label>?, assignees: Nodes<Author>?
            /// Only the lookup by number asks for it: the other connections are open by query.
            let state: String?
        }
        struct Label: Decodable { let name: String }
        struct Comment: Decodable {
            let databaseId: Int?, author: Author?, authorAssociation: String?, body: String, createdAt: Date, url: URL?
        }
        let data: Payload
    }

    public static func decodeOpenIssues(_ data: Data, repo: String) throws -> OpenIssues {
        let repository = try Self.issueDecoder.decode(IssuesResponse.self, from: data).data.repository
        var seen = Set<Int>()
        let rows = (repository.issues.nodes + (repository.ready?.nodes ?? []) + (repository.inProgress?.nodes ?? []))
            .filter { seen.insert($0.number).inserted }
        let page = repository.issues.pageInfo
        return OpenIssues(issues: rows.map { issue(from: $0, repo: repo) },
                          nextPage: page?.hasNextPage == true ? page?.endCursor : nil)
    }

    static var issueDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func issue(from row: IssuesResponse.Row, repo: String) -> OpenIssue {
        OpenIssue(repo: repo, number: row.number, title: row.title, url: row.url, createdAt: row.createdAt,
                  author: row.author?.login, authorAssociation: row.authorAssociation, body: row.body,
                  comments: row.comments.nodes.map {
                      IssueComment(id: $0.databaseId.map(String.init) ?? "", author: $0.author?.login,
                                   authorAssociation: $0.authorAssociation, body: $0.body,
                                   createdAt: $0.createdAt, url: $0.url)
                  }.sorted { $0.createdAt < $1.createdAt },
                  labels: row.labels?.nodes.map(\.name) ?? [], assignees: row.assignees?.nodes.map(\.login) ?? [])
    }

    // MARK: search

    /// The open issues of the repo GitHub's search finds for the text, or the one issue a number
    /// names. Display only: nothing here reaches a dispatch.
    public func searchIssues(repo: String, text: String) async throws -> [OpenIssue] {
        let parts = repo.split(separator: "/").map(String.init)
        guard parts.count == 2 else { return [] }
        if let number = IssueSearch.number(in: text) {
            let data = try await gh(["api", "graphql", "-f", "owner=\(parts[0])", "-f", "name=\(parts[1])",
                                     "-F", "number=\(number)", "-f", "query=\(Self.issueByNumberQuery)"])
            return try Self.decodeIssue(data, repo: repo).map { [$0] } ?? []
        }
        let data = try await gh(["api", "graphql", "-f", "q=\(IssueSearch.query(repo: repo, text: text))",
                                 "-f", "query=\(Self.issueSearchQuery)"])
        return try Self.decodeIssueSearch(data, repo: repo)
    }

    static let issueSearchQuery = """
    query($q: String!) {
      search(type: ISSUE, query: $q, first: 50) {
        nodes { ... on Issue {
    \(issueFields)
        } }
      }
    }
    """

    static let issueByNumberQuery = """
    query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issue(number: $number) {
          state
    \(issueFields)
        }
      }
    }
    """

    private struct SearchResponse: Decodable {
        struct Payload: Decodable { let search: Nodes }
        /// A pull request in the answer comes as `{}` (no issue fields): it decodes as nil.
        struct Nodes: Decodable { let nodes: [Node] }
        struct Node: Decodable {
            let row: IssuesResponse.Row?
            init(from decoder: Decoder) throws { row = try? IssuesResponse.Row(from: decoder) }
        }
        let data: Payload
    }

    private struct IssueResponse: Decodable {
        struct Payload: Decodable { let repository: Repository }
        struct Repository: Decodable { let issue: IssuesResponse.Row? }
        let data: Payload
    }

    public static func decodeIssueSearch(_ data: Data, repo: String) throws -> [OpenIssue] {
        try Self.issueDecoder.decode(SearchResponse.self, from: data).data.search.nodes
            .compactMap(\.row).map { issue(from: $0, repo: repo) }
    }

    public static func decodeIssue(_ data: Data, repo: String) throws -> OpenIssue? {
        guard let row = try Self.issueDecoder.decode(IssueResponse.self, from: data).data.repository.issue, row.state != "CLOSED" else { return nil }
        return issue(from: row, repo: repo)
    }
}
