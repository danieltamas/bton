@testable import BtonCore
import Foundation
import Testing

private enum PRVanishedTarget: CaseIterable, Sendable {
    case pullRequest, schedule
    var directory: String { self == .pullRequest ? "bton-pr-7" : "bton-nightly" }
}

private final class PRVanishedNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }
    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private struct PRVanishedGitFixture {
    let root: URL
    let clone: URL
    let runner = ProcessRunner()

    static func make(path: String) async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-vanished-pr-acceptance-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Self(root: root, clone: root.appendingPathComponent("clone"))
        do {
            let origin = root.appendingPathComponent("origin.git")
            try await fixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
            try await fixture.git(["clone", origin.path, fixture.clone.path], in: root)
            try await fixture.git(["config", "user.name", "Synthetic Tester"])
            try await fixture.git(["config", "user.email", "synthetic@example.invalid"])
            try fixture.write(path, "original quarantined content\n")
            try fixture.write("keep.txt", "original other content\n")
            // This would also match an unescaped '*' exclusion.
            try fixture.write("quarantined other file.txt", "literal glob witness\n")
            try fixture.write(".gitignore", ".worktrees/\n")
            try await fixture.git(["add", "."])
            try await fixture.commit("Synthetic initial")
            try await fixture.git(["push", "origin", "HEAD:refs/heads/main"])
            try await fixture.git(["checkout", "-b", "fixture-authoring"])
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func write(_ path: String, _ contents: String, in directory: URL? = nil) throws {
        try Data(contents.utf8).write(to: (directory ?? clone).appendingPathComponent(path))
    }

    func commit(_ message: String, in directory: URL? = nil) async throws {
        try await git(["-c", "commit.gpgsign=false", "commit", "-m", message], in: directory)
    }

    func push() async throws {
        try await git(["push", "origin", "HEAD:refs/pull/7/head"])
    }

    func prepare(_ target: PRVanishedTarget, notes: PRVanishedNotes) async throws -> URL {
        if target == .schedule {
            return try await Worktrees.prepare(clone: clone, branch: "main", item: "nightly",
                ghPath: "/usr/bin/true", runner: runner, note: { notes.append($0) })
        }
        let head = try await git(["rev-parse", "HEAD"])
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
        return try await Worktrees.prepare(clone: clone, pr: pr, base: "main", ghPath: "/usr/bin/true",
            runner: runner, note: { notes.append($0) })
    }

    // Real Git hooks model quarantine synchronously, without racing a file watcher or changing
    // ProcessRunner. Only Bton's worktrees are affected, even though hooks are shared by Git.
    func installQuarantine(path: String) async throws {
        let hooks = root.appendingPathComponent("hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = """
        #!/bin/sh
        case "$PWD" in
          */.worktrees/bton-*)
            if [ -f \(quote(path)) ]; then
              /bin/cat \(quote(path)) >> \(quote(root.appendingPathComponent("quarantine.log").path))
              /bin/rm -f -- \(quote(path))
            fi
            ;;
        esac
        """
        for name in ["post-checkout", "post-index-change"] {
            let hook = hooks.appendingPathComponent(name)
            try Data(script.utf8).write(to: hook)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        }
        try await git(["config", "core.hooksPath", hooks.path])
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await runner.run("/usr/bin/git", arguments, in: directory ?? clone,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(120))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func expectCleanSparseTree(_ tree: URL, path: String) async throws {
        #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent(path).path))
        #expect(try await git(["status", "--porcelain"], in: tree).isEmpty)
        #expect(try await git(["config", "--bool", "core.sparseCheckout"], in: tree) == "true")
        let patterns = try await git(["sparse-checkout", "list"], in: tree).split(separator: "\n").map(String.init)
        #expect(patterns.contains("!/" + path))
    }
}

@Suite(ProcessBound())
struct VanishedPullRequestAcceptanceTests {
    @Test(arguments: [false, true])
    fileprivate func quarantinedPRChangeThrows(existingOnBase: Bool) async throws {
        let path = existingOnBase ? "quarantined.txt" : "added-by-pr.txt"
        let fixture = try await PRVanishedGitFixture.make(path: "quarantined.txt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write(path, "PR content that must be reviewed\n")
        try await fixture.git(["add", "-A"])
        try await fixture.commit("PR adds or modifies quarantined file")
        try await fixture.push()
        try await fixture.installQuarantine(path: path)

        await expectPRRejection(fixture, path: path)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("quarantine.log"), encoding: .utf8)
            .contains("PR content that must be reviewed"))
    }

    @Test
    fileprivate func newerPRHeadLiftsPreviouslyUnchangedFileExclusion() async throws {
        let path = "quarantined.txt"
        let fixture = try await PRVanishedGitFixture.make(path: path)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.write("keep.txt", "first PR change\n")
        try await fixture.git(["add", "-A"])
        try await fixture.commit("PR changes only another file")
        try await fixture.push()
        try await fixture.installQuarantine(path: path)
        let tree = try await fixture.prepare(.pullRequest, notes: PRVanishedNotes())
        try await fixture.expectCleanSparseTree(tree, path: path)

        try fixture.write(path, "new PR head changes quarantined file\n")
        try await fixture.git(["add", "-A"])
        try await fixture.commit("PR now changes previously excluded file")
        try await fixture.push()
        let head = try await fixture.git(["rev-parse", "HEAD"])
        await expectPRRejection(fixture, path: path)
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: tree) == head)
        let sparse = try await fixture.runner.run("/usr/bin/git", ["sparse-checkout", "list"],
            in: tree, timeout: .seconds(120))
        if sparse.status == 0 {
            let patterns = String(decoding: sparse.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            #expect(!patterns.contains("!/" + path))
        } else {
            // A failed list is acceptable only when sparse checkout really is disabled.
            let enabled = try await fixture.runner.run("/usr/bin/git", ["config", "--bool", "core.sparseCheckout"],
                in: tree, timeout: .seconds(120))
            #expect(enabled.status == 1 || (enabled.status == 0 &&
                String(decoding: enabled.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "false"))
        }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("quarantine.log"), encoding: .utf8)
            .contains("new PR head changes quarantined file"))
    }

    @Test
    fileprivate func scheduleStillExcludesQuarantinedFileAcrossChangedCommits() async throws {
        let path = "quarantined.txt"
        let fixture = try await PRVanishedGitFixture.make(path: path)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.installQuarantine(path: path)
        let tree = try await fixture.prepare(.schedule, notes: PRVanishedNotes())
        try await fixture.expectCleanSparseTree(tree, path: path)
        try fixture.write(path, "changed schedule content\n")
        try await fixture.git(["add", "-A"])
        try await fixture.commit("Schedule upstream changes quarantined file")
        try await fixture.git(["push", "origin", "HEAD:refs/heads/main"])
        let head = try await fixture.git(["rev-parse", "HEAD"])
        let again = try await fixture.prepare(.schedule, notes: PRVanishedNotes())
        #expect(again == tree)
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: tree) == head)
        try await fixture.expectCleanSparseTree(tree, path: path)
        #expect(try await fixture.git(["show", "HEAD:\(path)"], in: tree) == "changed schedule content")
    }

    private func expectPRRejection(_ fixture: PRVanishedGitFixture, path: String) async {
        do {
            _ = try await fixture.prepare(.pullRequest, notes: PRVanishedNotes())
            Issue.record("PR preparation must reject a quarantined file changed by the PR: \(path)")
        } catch DispatchError.worktree(let message) {
            #expect(message.contains(path))
        } catch {
            Issue.record("Expected DispatchError.worktree, got \(error)")
        }
    }
}
