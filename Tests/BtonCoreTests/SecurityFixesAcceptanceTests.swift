@testable import BtonCore
import Foundation
import Testing

private enum SecurityFixture {
    static let associations: [String?] = [
        "OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "NONE",
        "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "MANNEQUIN", "UNKNOWN", "", "owner", nil,
    ]
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func comment(_ body: String, association: String?, hour: Int = 12) -> PullRequestComment {
        PullRequestComment(author: "reviewer", authorAssociation: association, body: body,
                           createdAt: Date(timeIntervalSince1970: Double(hour * 3600)))
    }

    static func pr(_ comments: [PullRequestComment]) -> PullRequest {
        PullRequest(repo: "synthetic/security", number: 7, title: "Synthetic PR", author: "author",
                    authorAssociation: "OWNER", url: URL(string: "https://github.com/synthetic/security/pull/7")!,
                    headSha: head, headRef: "feature", baseRef: "develop", body: "**Tier:** feature",
                    isDraft: false, labels: [], assignees: ["reviewer"], comments: comments, updatedAt: .distantPast)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                          "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(15))
        guard result.status == 0 else {
            Issue.record("Synthetic git setup failed: \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct SecurityFixesAcceptanceTests {
    @Test(arguments: [true, false], ["OWNER", "MEMBER", "COLLABORATOR"])
    func deletedAuthorReviewRequiresHeadingWithoutNotByAuthor(notByAuthor: Bool, association: String) throws {
        let json: [String: Any] = [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": notByAuthor]]],
            "fixed": "## Fixed:", "moves": [], "dispatch": [:],
        ]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        let comment = PullRequestComment(author: nil, authorAssociation: association,
            body: "## Review: approve (head d67db2a8)", createdAt: .distantPast)
        let reviews = FlowEngine.reviews(of: SecurityFixture.pr([comment]), flow: flow)
        #expect(reviews.count == (notByAuthor ? 0 : 1))
        if !notByAuthor { #expect(try #require(reviews.first).author == nil) }
    }

    @Test(arguments: SecurityFixture.associations)
    func reviewAssociationCountsOnlyWriteAccess(association: String?) throws {
        let trusted = ["OWNER", "MEMBER", "COLLABORATOR"].contains(association ?? "")
        let pr = SecurityFixture.pr([SecurityFixture.comment(
            "## Review: approve (head d67db2a8)", association: association)])
        let flow = try FlowFixture.flow()
        #expect(FlowEngine.reviews(of: pr, flow: flow).count == (trusted ? 1 : 0))
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == (trusted ? "merge" : "review"))
    }

    @Test(arguments: SecurityFixture.associations)
    func fixedAssociationCountsOnlyWriteAccess(association: String?) throws {
        let trusted = ["OWNER", "MEMBER", "COLLABORATOR"].contains(association ?? "")
        let pr = SecurityFixture.pr([
            SecurityFixture.comment("## Review: changes (head d67db2a8)", association: "MEMBER"),
            SecurityFixture.comment("## Fixed: addressed (head d67db2a8)", association: association, hour: 13),
        ])
        // A newer trusted Fixed reply reopens review; an untrusted reply leaves the fix move.
        #expect(FlowEngine.move(for: pr, flow: try FlowFixture.flow())?.name == (trusted ? "review" : "fix"))
    }

    @Test func defaultCommentAssociationFailsClosed() throws {
        let comment = PullRequestComment(author: "reviewer", body: "## Review: approve (head d67db2a8)",
                                         createdAt: .now)
        #expect(comment.authorAssociation == nil)
        #expect(FlowEngine.reviews(of: SecurityFixture.pr([comment]), flow: try FlowFixture.flow()).isEmpty)
    }

    @Test(arguments: ["MEMBER", "NONE", "missing", "null"])
    func graphqlCommentAssociationDecodes(value: String) throws {
        var comment: [String: Any] = ["author": ["login": "reviewer"],
            "body": "## Review: approve (head d67db2a8)", "createdAt": "2026-10-19T12:00:00Z"]
        if value == "null" { comment["authorAssociation"] = NSNull() }
        else if value != "missing" { comment["authorAssociation"] = value }
        let node: [String: Any] = [
            "number": 7, "title": "Synthetic PR", "url": "https://github.com/synthetic/security/pull/7",
            "author": ["login": "author"], "authorAssociation": "OWNER", "isDraft": false,
            "headRefOid": SecurityFixture.head, "headRefName": "feature", "baseRefName": "develop",
            "body": "**Tier:** feature", "updatedAt": "2026-10-19T11:00:00Z",
            "labels": ["nodes": []], "assignees": ["nodes": [["login": "reviewer"]]],
            "comments": ["nodes": [comment]],
        ]
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "author"], "repository": ["defaultBranchRef": ["name": "develop"],
                "pullRequests": ["nodes": [node]]]]])
        let pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/security").pullRequests.first)
        #expect(pr.comments.count == 1)
        #expect(pr.comments.first?.authorAssociation == (["missing", "null"].contains(value) ? nil : value))
    }

    @Test func untrustedCurrentHeadApprovalNeverDispatchesMerge() throws {
        let pr = SecurityFixture.pr([SecurityFixture.comment(
            "## Review: approve (head d67db2a8)", association: "NONE")])
        let flow = try FlowFixture.flow()
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
        // The PR author owns merge; an outsider's approval must not offer it to that author.
        #expect(DispatchPlanner.candidates([pr], flow: flow, me: "author", repo: pr.repo).isEmpty)
    }

    @Test(arguments: ["disabled", "absent", "relative", "invalid"])
    func lockedSandboxAlwaysEnablesAndClosesEscape(scenario: String) throws {
        let input: String?
        switch scenario {
        case "disabled": input = #"{"model":"synthetic","sandbox":{"enabled":false,"failIfUnavailable":false,"allowUnsandboxedCommands":true}}"#
        case "relative": input = ".claude/settings.json"
        case "invalid": input = "{invalid JSON"
        default: input = nil
        }
        let output = AgentHardening.lockedSandbox(input)
        let settings = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        if scenario == "disabled" {
            #expect(settings["model"] as? String == "synthetic")
        } else {
            #expect(output == #"{"sandbox":{"allowUnsandboxedCommands":false,"enabled":true,"failIfUnavailable":true}}"#)
        }
    }

    // Dispatcher.dispatch requires GitHub lease reads; the current e2e harness uses a live repo.
    // Keep this synthetic suite offline and exercise the requested Worktrees fallback with real git.
    @Test(arguments: ["clean", "tracked", "untracked"])
    func removeCleanRemovesOnlyUnchangedWorktrees(state: String) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-security-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin.git")
        let clone = root.appendingPathComponent("clone")
        try await SecurityFixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
        try await SecurityFixture.git(["clone", origin.path, clone.path], in: root)
        try Data("base content\n".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
        try await SecurityFixture.git(["add", "tracked.txt"], in: clone)
        try await SecurityFixture.git(["-c", "user.name=Synthetic Tester", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "Synthetic base"], in: clone)
        try await SecurityFixture.git(["push", "origin", "main"], in: clone)
        let tip = try await SecurityFixture.git(["rev-parse", "HEAD"], in: clone)
        let tree = try await Worktrees.prepare(clone: clone, branch: "main", item: "base-pr-7",
                                               ghPath: "/usr/bin/true", runner: ProcessRunner())
        #expect(tree.path == clone.appendingPathComponent(".worktrees/bton-base-pr-7").path)
        #expect(try await SecurityFixture.git(["rev-parse", "HEAD"], in: tree) == tip)
        let branch = try await ProcessRunner().run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"],
                                                  in: tree, timeout: .seconds(15))
        #expect(branch.status == 1)
        let changed = tree.appendingPathComponent(state == "tracked" ? "tracked.txt" : "untracked.txt")
        let contents = Data("command left changes\n".utf8)
        if state != "clean" { try contents.write(to: changed) }
        let removed = await Worktrees.removeClean(tree, clone: clone, ghPath: "/usr/bin/true", runner: ProcessRunner())
        #expect(removed == (state == "clean"))
        #expect(FileManager.default.fileExists(atPath: tree.path) == (state != "clean"))
        if state != "clean" { #expect(try Data(contentsOf: changed) == contents) }
    }
}
