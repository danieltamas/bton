@testable import BtonCore
import Foundation
import Testing

private enum PermissionTarget: CaseIterable, Sendable {
    case pullRequest, schedule
    var directory: String { self == .pullRequest ? "bton-pr-7" : "bton-nightly" }
}

private struct PermissionGitFixture {
    let root: URL
    let clone: URL
    let runner = ProcessRunner()

    static func make(path: String) async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-permission-acceptance-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = Self(root: root, clone: root.appendingPathComponent("clone"))
        do {
            let origin = root.appendingPathComponent("origin.git")
            try await fixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
            try await fixture.git(["clone", origin.path, fixture.clone.path], in: root)
            try await fixture.git(["config", "user.name", "Synthetic Tester"])
            try await fixture.git(["config", "user.email", "synthetic@example.invalid"])
            try fixture.write(path, "original tracked content\n")
            try fixture.write("keep.txt", "original other content\n")
            try fixture.write(".gitignore", ".worktrees/\n")
            try await fixture.git(["add", "."])
            try await fixture.commit("Synthetic initial")
            try await fixture.push()
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
        try await git(["push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"])
    }

    func prepare(_ target: PermissionTarget) async throws -> URL {
        if target == .schedule {
            return try await Worktrees.prepare(clone: clone, branch: "main", item: "nightly",
                ghPath: "/usr/bin/true", runner: runner)
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
            runner: runner)
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

}

// chflags creates a real kernel denial, rather than a fabricated git error.
private func permissionFlag(_ flag: String, at file: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    process.arguments = [flag, file.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw DispatchError.worktree("chflags \(flag) exited \(process.terminationStatus)")
    }
}

@Suite(ProcessBound())
struct PermissionRetryAcceptanceTests {
    @Test(arguments: PermissionTarget.allCases)
    fileprivate func transientPermissionDenialPreservesLeftovers(target: PermissionTarget) async throws {
        let fixture = try await PermissionGitFixture.make(path: "protected.txt")
        let tree = fixture.clone.appendingPathComponent(".worktrees/\(target.directory)")
        let file = tree.appendingPathComponent("protected.txt")
        defer {
            try? permissionFlag("nouchg", at: file)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await fixture.git(["worktree", "add", "--detach", tree.path, "HEAD"])
        try fixture.write("protected.txt", "leftover job change\n", in: tree)
        // The requested head differs from the existing tree, so success must also advance it.
        try fixture.write("keep.txt", "new requested head\n")
        try await fixture.git(["add", "keep.txt"])
        try await fixture.commit("Synthetic upstream update")
        try await fixture.push()
        let head = try await fixture.git(["rev-parse", "HEAD"])
        try permissionFlag("uchg", at: file)
        try await expectPermissionDenial(fixture, tree: tree)

        #expect(Worktrees.permissionRetryWait == .seconds(20))
        let retries = PermissionRetryCounter()
        let prepared = try await Worktrees.$waitForPermissionRetry.withValue({
            await retries.increment()
            try await Task.sleep(for: .milliseconds(20))
            try permissionFlag("nouchg", at: file)
        }) {
            try await fixture.prepare(target)
        }
        #expect(await retries.count == 1)
        #expect(prepared.standardizedFileURL == tree.standardizedFileURL)
        #expect(try await fixture.git(["status", "--porcelain"], in: tree).isEmpty)
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: tree) == head)
        #expect(try String(contentsOf: file, encoding: .utf8) == "original tracked content\n")
        #expect(try String(contentsOf: tree.appendingPathComponent("keep.txt"), encoding: .utf8)
            == "new requested head\n")
        #expect(try await fixture.git(["stash", "list"]).contains(target.directory))
        #expect(try await fixture.git(["show", "stash@{0}:protected.txt"]) == "leftover job change")
    }

    @Test(arguments: PermissionTarget.allCases)
    fileprivate func persistentPermissionDenialExhaustsRetries(target: PermissionTarget) async throws {
        let fixture = try await PermissionGitFixture.make(path: "protected.txt")
        let tree = fixture.clone.appendingPathComponent(".worktrees/\(target.directory)")
        let file = tree.appendingPathComponent("protected.txt")
        defer {
            try? permissionFlag("nouchg", at: file)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await fixture.git(["worktree", "add", "--detach", tree.path, "HEAD"])
        try fixture.write("protected.txt", "leftover job change\n", in: tree)
        try permissionFlag("uchg", at: file)
        try await expectPermissionDenial(fixture, tree: tree)
        #expect(Worktrees.permissionRetryWait == .seconds(20))
        #expect(Worktrees.permissionRetries == 2)
        let retries = PermissionRetryCounter()
        do {
            _ = try await Worktrees.$waitForPermissionRetry.withValue({
                await retries.increment()
                try await Task.sleep(for: .milliseconds(20))
            }) {
                try await fixture.prepare(target)
            }
            Issue.record("Preparation must throw when every attempt is denied")
        } catch DispatchError.worktree(let message) {
            #expect(message.contains("Operation not permitted"))
        }
        #expect(await retries.count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == "leftover job change\n")
    }

    private func expectPermissionDenial(_ fixture: PermissionGitFixture, tree: URL) async throws {
        let result = try await fixture.runner.run("/usr/bin/git", ["checkout", "--", "protected.txt"],
            in: tree, timeout: .seconds(120))
        try #require(result.status != 0)
        try #require(result.stderr.contains("Operation not permitted"))
    }
}

private actor PermissionRetryCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}
