@testable import BtonCore
import Foundation
import Testing

// Callbacks cross executor boundaries, so their observations need synchronous protection.
private final class ClaimedWorktreeObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [URL] = []
    private var notes: [String] = []

    func checked(_ path: URL) {
        lock.lock()
        defer { lock.unlock() }
        paths.append(path)
    }

    func noted(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        notes.append(message)
    }

    var snapshot: (paths: [URL], notes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (paths, notes)
    }
}

private struct ClaimedWorktreeGitFixture {
    let root: URL
    let clone: URL
    let pr: PullRequest
    let runner: ProcessRunner

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-claimed-acceptance-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let clone = root.appendingPathComponent("clone")
        let runner = ProcessRunner()
        do {
            let origin = root.appendingPathComponent("origin.git")
            try await git(["init", "--bare", "--initial-branch=main", origin.path], in: root, runner: runner)
            try await git(["clone", origin.path, clone.path], in: root, runner: runner)
            try await git(["config", "user.name", "Synthetic Tester"], in: clone, runner: runner)
            try await git(["config", "user.email", "synthetic@example.invalid"], in: clone, runner: runner)
            try Data("base content\n".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
            try Data(".worktrees/\n".utf8).write(to: clone.appendingPathComponent(".gitignore"))
            try await git(["add", "."], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic initial"], in: clone, runner: runner)
            try await git(["push", "origin", "main"], in: clone, runner: runner)
            try await git(["checkout", "-b", "feature"], in: clone, runner: runner)
            try Data("PR head content\n".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
            try await git(["add", "tracked.txt"], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic PR head"], in: clone, runner: runner)
            let head = try await git(["rev-parse", "HEAD"], in: clone, runner: runner)
            try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: clone, runner: runner)
            // Keep the main checkout off the PR branch so each test controls its presence.
            try await git(["checkout", "main"], in: clone, runner: runner)
            let node: [String: Any] = [
                "number": 7, "title": "Synthetic PR", "url": "https://github.com/synthetic/project/pull/7",
                "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
                "body": "**Tier:** feature", "updatedAt": "2026-10-19T11:00:00Z", "authorAssociation": "OWNER",
                "author": ["login": "synthetic"], "labels": ["nodes": []], "assignees": ["nodes": []],
                "comments": ["nodes": []]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                "viewer": ["login": "synthetic"], "repository": ["defaultBranchRef": ["name": "main"],
                "pullRequests": ["nodes": [node]]]]])
            let pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/project").pullRequests.first)
            return Self(root: root, clone: clone, pr: pr, runner: runner)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func branchTree() async throws -> URL {
        // A space also checks that the listing's path reaches the callback intact.
        let tree = root.appendingPathComponent("author worktree")
        try await git(["worktree", "add", tree.path, "feature"])
        // Git's canonical spelling is the callback contract, including /private on macOS.
        let listing = try await git(["worktree", "list", "--porcelain"])
        let block = try #require(listing.components(separatedBy: "\n\n").first {
            $0.split(separator: "\n").contains("branch refs/heads/feature")
        })
        let line = try #require(block.split(separator: "\n").first { $0.hasPrefix("worktree ") })
        return URL(fileURLWithPath: String(line.dropFirst("worktree ".count)), isDirectory: true)
    }

    func expectCleanHead(_ tree: URL) async throws {
        #expect(try await git(["rev-parse", "HEAD"], in: tree) == pr.headSha)
        #expect(try await git(["status", "--porcelain", "--untracked-files=all"], in: tree).isEmpty)
    }

    func expectDetached(_ tree: URL) async throws {
        try await expectCleanHead(tree)
        let result = try await runner.run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"], in: tree,
                                          timeout: .seconds(120))
        #expect(result.status == 1)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        try await Self.git(arguments, in: directory ?? clone, runner: runner)
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL, runner: ProcessRunner) async throws -> String {
        let result = try await runner.run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(120))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

@Suite(ProcessBound())
struct ClaimedWorktreeAcceptanceTests {
    @Test func freeBranchWorktreeIsReused() async throws {
        let fixture = try await ClaimedWorktreeGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.branchTree()
        try await fixture.expectCleanHead(tree)
        let observations = ClaimedWorktreeObservations()
        let prepared = try await Worktrees.prepare(clone: fixture.clone, pr: fixture.pr, base: "main",
            ghPath: "/usr/bin/true", runner: fixture.runner,
            claimedBy: { observations.checked($0); return nil }, note: { observations.noted($0) })
        #expect(prepared.path == tree.path)
        #expect(observations.snapshot.paths.map(\.path) == [tree.path])
        #expect(observations.snapshot.notes.isEmpty)
        try await fixture.expectCleanHead(tree)
        #expect(try await fixture.git(["symbolic-ref", "HEAD"], in: tree) == "refs/heads/feature")
        #expect(!FileManager.default.fileExists(atPath: fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").path))
    }

    @Test func claimedBranchWorktreeUsesDetachedPRTreeAndReportsHolder() async throws {
        let fixture = try await ClaimedWorktreeGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.branchTree()
        try await fixture.expectCleanHead(tree)
        let holder = "agent other-session holds this tree"
        let observations = ClaimedWorktreeObservations()
        let prepared = try await Worktrees.prepare(clone: fixture.clone, pr: fixture.pr, base: "main",
            ghPath: "/usr/bin/true", runner: fixture.runner,
            claimedBy: { observations.checked($0); return holder }, note: { observations.noted($0) })
        #expect(prepared.path == fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").path)
        #expect(prepared.path != tree.path)
        #expect(observations.snapshot.paths.map(\.path) == [tree.path])
        let notes = observations.snapshot.notes
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.contains(tree.path))
        #expect(note.contains("bton-pr-7"))
        #expect(note.contains(holder))
        try await fixture.expectDetached(prepared)
        // Taking a separate tree must preserve the holder's branch checkout.
        try await fixture.expectCleanHead(tree)
        #expect(try await fixture.git(["symbolic-ref", "HEAD"], in: tree) == "refs/heads/feature")
    }

    @Test func absentBranchWorktreeDoesNotCheckClaims() async throws {
        let fixture = try await ClaimedWorktreeGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listing = try await fixture.git(["worktree", "list", "--porcelain"])
        #expect(!listing.contains("branch refs/heads/feature\n"))
        let observations = ClaimedWorktreeObservations()
        let prepared = try await Worktrees.prepare(clone: fixture.clone, pr: fixture.pr, base: "main",
            ghPath: "/usr/bin/true", runner: fixture.runner,
            claimedBy: { observations.checked($0); return "unexpected claim check" },
            note: { observations.noted($0) })
        #expect(prepared.path == fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").path)
        #expect(observations.snapshot.paths.isEmpty)
        #expect(observations.snapshot.notes.isEmpty)
        try await fixture.expectDetached(prepared)
    }
}
