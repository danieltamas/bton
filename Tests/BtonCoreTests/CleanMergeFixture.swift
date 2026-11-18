@testable import BtonCore
import Foundation
import Testing

/// Only gh and its remote are synthetic. All commit objects and merges use /usr/bin/git.
struct CleanMergeFixture {
    let root: URL
    let clone: URL
    let origin: URL
    let base0: String
    let a: String
    let base1: String
    let other: String
    let head: String
    var gh: URL { root.appendingPathComponent("gh") }
    var client: GitHubClient { GitHubClient(ghPath: gh.path) }
    static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    static let environment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_COUNT": "0", "GIT_TERMINAL_PROMPT": "0"]

    @discardableResult
    static func git(_ at: URL, _ args: [String], status: Int32 = 0) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git",
            ["-C", at.path, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
             "-c", "commit.gpgsign=false"] + args,
            environment: environment, timeout: .seconds(20))
        try #require(result.status == status, "git \(args): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func write(_ at: URL, _ file: String, _ text: String) throws {
        try text.write(to: at.appendingPathComponent(file), atomically: true, encoding: .utf8)
    }

    static func commit(_ at: URL, file: String, text: String) async throws -> String {
        try write(at, file, text)
        try await git(at, ["add", file])
        try await git(at, ["commit", "-m", "Fixture \(file)"])
        return try await git(at, ["rev-parse", "HEAD"])
    }

    static func make(conflict: Bool = false, remoteOnly: Bool = false) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clean-merge-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let origin = root.appendingPathComponent("origin.git")
            let clone = root.appendingPathComponent("clone")
            try await git(root, ["init", "--bare", "--initial-branch=main", origin.path])
            try await git(root, ["clone", origin.path, clone.path])
            try write(clone, "b.txt", "base b\nline two\nline three\n")
            try await git(clone, ["add", "b.txt"])
            let base0 = try await commit(clone, file: "a.txt", text: "base a\nline two\nline three\n")
            try await git(clone, ["push", "origin", "main"])
            // In remoteOnly cases, none of A, base1 or M exists in the observed clone.
            let writer = remoteOnly ? root.appendingPathComponent("writer") : clone
            if remoteOnly { try await git(root, ["clone", origin.path, writer.path]) }
            try await git(writer, ["checkout", "-b", "feature", base0])
            let a = try await commit(writer, file: "a.txt", text: "approved a\nline two\nline three\n")
            try await git(writer, ["checkout", "main"])
            let base1 = try await commit(writer, file: conflict ? "a.txt" : "b.txt",
                text: conflict ? "base conflict\nline two\nline three\n" : "base b advanced\nline two\nline three\n")
            try await git(writer, ["checkout", "-b", "other", base0])
            let other = try await commit(writer, file: "b.txt", text: "other b\nline two\nline three\n")
            try await git(writer, ["checkout", "feature"])
            try await git(writer, ["merge", "--no-ff", "-m", "Merge base", base1], status: conflict ? 1 : 0)
            if conflict {
                _ = try await commit(writer, file: "a.txt", text: "hand chosen a\nline two\nline three\n")
            }
            let head = try await git(writer, ["rev-parse", "HEAD"])
            try await git(writer, ["push", "origin", "main", "HEAD:refs/pull/7/head"])
            let f = Self(root: root, clone: clone, origin: origin, base0: base0,
                a: a, base1: base1, other: other, head: head)
            try f.page([f.node()])
            try write(root, "gh", """
            #!/bin/sh
            if [ "$1" = api ] && [ "$2" = graphql ]; then
              cat "$(dirname "$0")/page.json"; exit 0
            fi
            exit 1
            """)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.gh.path)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func node(head: String? = nil, base: String? = nil, branch: String = "main",
              parents: [String]? = nil, number: Int = 7) -> [String: Any] {
        Self.node(head: head ?? self.head, base: base ?? base1, branch: branch,
            parents: parents ?? [a, base1], number: number)
    }

    static func node(head: String, base: String, branch: String = "main",
                     parents: [String], number: Int = 7) -> [String: Any] {
        ["number": number, "title": "Synthetic", "url": "https://example.invalid/pr/\(number)",
         "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": branch,
         "baseRef": ["target": ["oid": base]], "body": "", "updatedAt": "2026-10-19T12:00:00Z",
         "mergeable": "MERGEABLE", "authorAssociation": "OWNER", "author": ["login": "owner"],
         "labels": ["nodes": []], "assignees": ["nodes": []], "comments": ["nodes": []],
         "files": ["totalCount": 0, "nodes": []],
         "commits": ["nodes": [["commit": ["oid": head, "committedDate": "2026-10-19T11:00:00Z",
             "parents": ["nodes": parents.map { ["oid": $0] }]]]]]]
    }

    static func payload(_ nodes: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": "owner"],
            "repository": ["defaultBranchRef": ["name": "main"], "pullRequests": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": nodes]]]])
    }

    func page(_ nodes: [[String: Any]]) throws {
        try Self.payload(nodes).write(to: root.appendingPathComponent("page.json"))
    }

    func read(_ client: GitHubClient? = nil) async throws -> PullRequest {
        let result = try await (client ?? self.client).openPullRequests(repo: "synthetic/project", clone: clone)
        return try #require(result.pullRequests.first)
    }

    func chosenCommit(tree: String, parents: [String]) async throws -> String {
        try await Self.git(clone, ["commit-tree", tree] + parents.flatMap { ["-p", $0] } + ["-m", "Chosen merge"])
    }

    func editedMerge() async throws -> String {
        try Self.write(clone, "b.txt", "unreviewed extra change\n")
        try await Self.git(clone, ["add", "b.txt"])
        let tree = try await Self.git(clone, ["write-tree"])
        return try await chosenCommit(tree: tree, parents: [a, base1])
    }

    /// Advance main without touching a.txt, then merge it into the current PR branch.
    func nextMerge(_ index: Int) async throws -> (head: String, base: String) {
        try await Self.git(clone, ["checkout", "main"])
        let base = try await Self.commit(clone, file: "base-\(index).txt", text: "base \(index)\n")
        try await Self.git(clone, ["checkout", "feature"])
        try await Self.git(clone, ["merge", "--no-ff", "-m", "Merge \(index)", base])
        return (try await Self.git(clone, ["rev-parse", "HEAD"]), base)
    }

    static func flow() throws -> Flow {
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:", "notByAuthor": true]]], "fixed": "Fixed:",
            "moves": [
                ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"],
                ["move": "review", "when": ["no_review_or_response_newer"], "who": "reviewer"],
                ["move": "merge", "when": ["approved_current_head"], "who": "author"]],
            "dispatch": ["fix": ["agent": "synthetic", "prompt": "Fix"],
                         "merge": ["command": ["/usr/bin/true"]]]]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func refusal(_ pr: PullRequest, at head: String) throws {
        #expect(pr.carriedHeads.isEmpty)
        let reason = try #require(pr.carryRefusal)
        let prefix = "could not check \(short(head)): "
        #expect(reason.hasPrefix(prefix))
        #expect(reason.count > prefix.count)
    }
}
