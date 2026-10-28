import Foundation

/// A message from one person's agent (or the person) to a teammate, as a comment on an issue: the
/// teammate's @mention is what their Bton already shows as an ask, and the marker only tags it.
public enum Handoff {
    public static let maxTextLength = 4000
    /// The label of a repo's inbox issue: where a handoff goes when no issue is its subject. The
    /// team makes it (one open issue with the label, pinned), never an agent.
    public static let inboxLabel = "bton:inbox"

    public enum Problem: LocalizedError, Equatable {
        case badLogin, emptyText, tooLong, markup, otherMention(String), noInbox(repo: String)

        public var errorDescription: String? {
            switch self {
            case let .noInbox(repo):
                "\(repo) has no open issue labelled \(Handoff.inboxLabel): name the issue, or have the team create one " +
                    "(gh issue create --repo \(repo) --title \"Bton inbox\" --label \(Handoff.inboxLabel), then pin it)"
            case .badLogin: "not a GitHub login"
            case .emptyText: "nothing to say"
            case .tooLong: "longer than \(Handoff.maxTextLength) characters: link the plan instead of pasting it"
            case .markup: "HTML comments are not allowed in the text"
            case let .otherMention(login): "the text mentions @\(login): a handoff names one person"
            }
        }
    }

    public static func marker(to login: String) -> String { "<!-- bton:handoff to=\(login) -->" }

    static func isLogin(_ login: String) -> Bool {
        // GitHub's grammar: alphanumerics and single hyphens, never at either end; the whole string.
        login.range(of: #"\A[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z"#, options: .regularExpression) != nil && login.count <= 39
    }

    /// The comment to post: the teammate's @mention first, the text, the marker last. The text may
    /// not mention anyone else or carry markup of its own, so a handoff never notifies a third
    /// person and never quotes another handoff.
    public static func body(to login: String, text: String) throws -> String {
        guard isLogin(login) else { throw Problem.badLogin }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Problem.emptyText }
        guard text.count <= maxTextLength else { throw Problem.tooLong }
        guard !text.contains("<!--") else { throw Problem.markup }
        let mention = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_/-])@([A-Za-z0-9][A-Za-z0-9/_-]*)"#)
        for match in mention.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let named = String(text[Range(match.range(at: 1), in: text)!])
            if named.caseInsensitiveCompare(login) != .orderedSame { throw Problem.otherMention(named) }
        }
        return "@\(login)\n\n\(text)\n\n\(marker(to: login))"
    }

    /// The inbox issue among a repo's open issues with the label: the lowest number when the team
    /// left more than one open, so every sender picks the same; nil when there is none.
    public static func inboxIssue(in data: Data) throws -> Int? {
        struct Row: Decodable { let number: Int }
        return try JSONDecoder().decode([Row].self, from: data).map(\.number).min()
    }

    /// Whether a comment ends with the marker addressed to `login`: where `body` puts it, so a
    /// marker quoted or fenced mid-comment does not tag the comment.
    public static func isHandoff(_ body: String, to login: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasSuffix(marker(to: login).lowercased())
    }
}

extension GitHubClient {
    /// Posts a handoff on an issue as the running user, once: a comment of theirs with the same
    /// body already there is the answer. With no issue, the repo's inbox issue. Returns whether it posted.
    @discardableResult
    public func handOff(to login: String, text: String, repo: String, issue: Int?) async throws -> Bool {
        let body = try Handoff.body(to: login, text: text)
        let issue = if let issue { issue } else { try await inboxIssue(repo: repo) }
        let me = try await viewer()
        struct Thread: Decodable {
            struct Author: Decodable { let login: String }
            struct Comment: Decodable { let author: Author?, body: String }
            let comments: [Comment]
        }
        let thread = try JSONDecoder().decode(Thread.self, from: try await gh(["issue", "view", String(issue), "--repo", repo,
                                                                                "--json", "comments"]))
        if thread.comments.contains(where: { $0.author?.login.caseInsensitiveCompare(me) == .orderedSame && $0.body == body }) {
            return false
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-handoff-\(UUID().uuidString).md")
        try Data(body.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        defer { try? FileManager.default.removeItem(at: file) }
        try await commentOnIssue(repo: repo, number: issue, bodyFile: file)
        return true
    }

    func inboxIssue(repo: String) async throws -> Int {
        let data = try await gh(["issue", "list", "--repo", repo, "--label", Handoff.inboxLabel, "--state", "open",
                                 "--json", "number", "--limit", "10"])
        guard let number = try Handoff.inboxIssue(in: data) else { throw Handoff.Problem.noInbox(repo: repo) }
        return number
    }
}
