@testable import BtonCore
import Darwin
import Foundation
import Testing

private enum LeftoverTarget: String, CaseIterable, Sendable {
    case pullRequest, schedule

    var directory: String { self == .pullRequest ? "bton-pr-7" : "bton-nightly" }
}

private enum LeftoverState: String, CaseIterable, Sendable {
    case tracked, untracked, both

    var hasTracked: Bool { self != .untracked }
    var hasUntracked: Bool { self != .tracked }
}

// The callback is synchronous and Sendable; protect its observations across executor hops.
private final class LeftoverNotes: @unchecked Sendable {
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

private struct LeftoverGitFixture {
    let root: URL
    let clone: URL
    let oldHead: String
    let requestedHead: String
    let pr: PullRequest
    let runner = ProcessRunner()

    private static let template = Task { try await makeTemplate() }

    static func make() async throws -> Self {
        let seed = try await template.value
        let root = try GitFixtureCopies.copy(seed.root)
        return Self(root: root, clone: root.appendingPathComponent("clone"), oldHead: seed.oldHead, requestedHead: seed.requestedHead, pr: seed.pr)
    }

    private static func makeTemplate() async throws -> Self {
        let root = GitFixtureCopies.templates
            .appendingPathComponent("bton-leftover-acceptance-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let clone = root.appendingPathComponent("clone")
            let origin = root.appendingPathComponent("origin.git")
            let runner = ProcessRunner()
            try await git(["init", "--bare", "--initial-branch=main", origin.path], in: root, runner: runner)
            try await git(["clone", origin.path, clone.path], in: root, runner: runner)
            try await git(["config", "user.name", "Synthetic Tester"], in: clone, runner: runner)
            try await git(["config", "user.email", "synthetic@example.invalid"], in: clone, runner: runner)
            try Data("original tracked content\n".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
            try Data("ignored.txt\n.worktrees/\n".utf8).write(to: clone.appendingPathComponent(".gitignore"))
            try await git(["add", "tracked.txt", ".gitignore"], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic initial"], in: clone, runner: runner)
            let oldHead = try await git(["rev-parse", "HEAD"], in: clone, runner: runner)
            try await git(["push", "origin", "main"], in: clone, runner: runner)
            try Data("requested tip\n".utf8).write(to: clone.appendingPathComponent("tip.txt"))
            try await git(["add", "tip.txt"], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic requested tip"], in: clone, runner: runner)
            let requestedHead = try await git(["rev-parse", "HEAD"], in: clone, runner: runner)
            try await git(["push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"], in: clone, runner: runner)
            // Make the clone's remote-tracking ref stale: schedule preparation must fetch the tip.
            try await git(["update-ref", "refs/remotes/origin/main", oldHead], in: clone, runner: runner)
            let node: [String: Any] = [
                "number": 7, "title": "Synthetic PR", "url": "https://github.com/synthetic/project/pull/7",
                "isDraft": false, "headRefOid": requestedHead, "headRefName": "feature", "baseRefName": "main",
                "body": "**Tier:** feature", "updatedAt": "2026-10-19T11:00:00Z", "authorAssociation": "OWNER",
                "author": ["login": "synthetic"], "labels": ["nodes": []], "assignees": ["nodes": []],
                "comments": ["nodes": []]
            ]
            let data = try JSONSerialization.data(withJSONObject: ["data": [
                "viewer": ["login": "synthetic"], "repository": ["defaultBranchRef": ["name": "main"],
                "pullRequests": ["nodes": [node]]]]])
            let pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/project").pullRequests.first)
            return Self(root: root, clone: clone, oldHead: oldHead, requestedHead: requestedHead, pr: pr)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func existingTree(_ target: LeftoverTarget) async throws -> URL {
        let tree = clone.appendingPathComponent(".worktrees/\(target.directory)")
        try await git(["worktree", "add", "--detach", tree.path, oldHead])
        return tree
    }

    func prepare(_ target: LeftoverTarget, notes: LeftoverNotes) async throws -> URL {
        switch target {
        case .pullRequest:
            return try await Worktrees.prepare(clone: clone, pr: pr, base: "main", ghPath: "/usr/bin/true",
                                               runner: runner, note: { notes.append($0) })
        case .schedule:
            return try await Worktrees.prepare(clone: clone, branch: "main", item: "nightly", ghPath: "/usr/bin/true",
                                               runner: runner, note: { notes.append($0) })
        }
    }

    func expectPrepared(_ prepared: URL, tree: URL) async throws {
        #expect(prepared.standardizedFileURL == tree.standardizedFileURL)
        #expect(try await git(["rev-parse", "HEAD"], in: tree) == requestedHead)
        #expect(try await git(["status", "--porcelain", "--untracked-files=all"], in: tree).isEmpty)
        let symbolic = try await runner.run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"], in: tree, timeout: .seconds(120))
        #expect(symbolic.status == 1)
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
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite(ProcessBound())
struct LeftoverStashAcceptanceTests {
    @Test(arguments: LeftoverTarget.allCases, LeftoverState.allCases)
    fileprivate func existingBtonTreeStashesLeftoversAndPreparesRequestedHead(
        target: LeftoverTarget, state: LeftoverState
    ) async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.existingTree(target)
        if state.hasTracked {
            try Data("leftover tracked modification\n".utf8).write(to: tree.appendingPathComponent("tracked.txt"))
        }
        if state.hasUntracked {
            try Data("leftover untracked content\n".utf8).write(to: tree.appendingPathComponent("untracked.txt"))
        }
        let notes = LeftoverNotes()
        let before = Date()
        let prepared = try await fixture.prepare(target, notes: notes)
        let stashOID = try await fixture.git(["rev-parse", "refs/stash"])
        let after = Date()
        try await fixture.expectPrepared(prepared, tree: tree)
        let messages = notes.messages
        #expect(messages.count == 1)
        #expect(messages.first?.contains("git stash") == true)
        #expect(messages.first?.contains(target.directory) == true)
        // Read through the clone to prove this is the shared stash, with exactly one entry.
        #expect(try await fixture.git(["stash", "list", "--format=%H"]).split(separator: "\n").count == 1)
        let subject = try await fixture.git(["log", "-1", "--format=%s", "refs/stash"])
        let prefix = "bton: leftovers in \(target.directory) before "
        let range = try #require(subject.range(of: prefix))
        let timestamp = String(subject[range.upperBound...])
        let message = String(subject[range.lowerBound...])
        #expect(messages == ["saved an earlier job's changes in \(target.directory) to git stash \(stashOID): \(message)"])
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: timestamp) ?? ISO8601DateFormatter().date(from: timestamp)
        let savedAt = try #require(date)
        #expect(savedAt >= before.addingTimeInterval(-1))
        #expect(savedAt <= after.addingTimeInterval(1))
        #expect(try await fixture.git(["show", "refs/stash:tracked.txt"]) ==
                (state.hasTracked ? "leftover tracked modification" : "original tracked content"))
        if state.hasUntracked {
            #expect(try await fixture.git(["show", "refs/stash^3:untracked.txt"]) == "leftover untracked content")
            #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent("untracked.txt").path))
        }
        #expect(try String(contentsOf: tree.appendingPathComponent("tracked.txt"), encoding: .utf8) == "original tracked content\n")
        // Reusing the now-clean tree must not stash or notify again.
        _ = try await fixture.prepare(target, notes: notes)
        #expect(notes.messages.count == 1)
        #expect(try await fixture.git(["stash", "list", "--format=%H"]).split(separator: "\n").count == 1)
    }

    @Test func freshOwnTreeDiscardsAllLeftoversWithoutAddingStash() async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        // Preserve an older stash as well as proving replacement adds none.
        try Data("older saved work\n".utf8).write(to: fixture.clone.appendingPathComponent("tracked.txt"))
        try await fixture.git(["stash", "push", "-m", "Synthetic older stash"])
        let stashBefore = try await fixture.git(["stash", "list", "--format=%H %s"])
        let tree = try await fixture.existingTree(.schedule)
        for name in ["tracked.txt", "untracked.txt", "ignored.txt"] {
            try Data("leftover work\n".utf8).write(to: tree.appendingPathComponent(name))
        }
        let notes = LeftoverNotes()
        let prepared = try await Worktrees.prepare(clone: fixture.clone, branch: "main", item: "nightly",
            ghPath: "/usr/bin/true", runner: fixture.runner, fresh: true, note: { notes.append($0) })
        try await fixture.expectPrepared(prepared, tree: tree)
        #expect(try String(contentsOf: tree.appendingPathComponent("tracked.txt"), encoding: .utf8) == "original tracked content\n")
        for name in ["untracked.txt", "ignored.txt"] {
            #expect(!FileManager.default.fileExists(atPath: tree.appendingPathComponent(name).path))
        }
        #expect(try await fixture.git(["stash", "list", "--format=%H %s"]) == stashBefore)
        #expect(notes.messages.isEmpty)
        let resolved = Darwin.realpath(tree.path, nil)
        let canonicalTree = try #require(resolved)
        defer { free(canonicalTree) }
        #expect(try await fixture.git(["worktree", "list", "--porcelain"]).contains("worktree \(String(cString: canonicalTree))\n"))
    }

    @Test(arguments: LeftoverTarget.allCases, ["checkoutLink", "parentLink", "plainDirectory", "danglingLink"])
    fileprivate func existingForeignPathsAreRejectedWithoutStashOrSwitch(target: LeftoverTarget, kind: String) async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = FileManager.default
        let parent = fixture.clone.appendingPathComponent(".worktrees")
        let tree = parent.appendingPathComponent(target.directory)
        let external = fixture.root.appendingPathComponent("external")
        let contents = Data("external uncommitted work\n".utf8)
        var protectedCheckout: URL?
        switch kind {
        case "checkoutLink":
            try await fixture.git(["clone", fixture.clone.path, external.path], in: fixture.root)
            try await fixture.git(["checkout", "--detach", fixture.oldHead], in: external)
            try contents.write(to: external.appendingPathComponent("tracked.txt"))
            try contents.write(to: external.appendingPathComponent("untracked.txt"))
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: tree.path, withDestinationPath: external.path)
            protectedCheckout = external
        case "parentLink":
            try manager.createDirectory(at: external, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: parent.path, withDestinationPath: external.path)
            // Even a registered tree must be rejected when its real path is outside the clone.
            try await fixture.git(["worktree", "add", "--detach", tree.path, fixture.oldHead])
            try contents.write(to: tree.appendingPathComponent("tracked.txt"))
            try contents.write(to: tree.appendingPathComponent("untracked.txt"))
            protectedCheckout = tree
        case "plainDirectory":
            try manager.createDirectory(at: tree, withIntermediateDirectories: true)
            try contents.write(to: tree.appendingPathComponent("sentinel.txt"))
        default:
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            try manager.createSymbolicLink(atPath: tree.path, withDestinationPath: external.path)
        }
        let listingBefore = try await fixture.git(["worktree", "list", "--porcelain"])
        let cloneHead = try await fixture.git(["rev-parse", "HEAD"])
        let notes = LeftoverNotes()
        // Exercise the replacement path as well as the default stash/checkout path.
        for fresh in [false, true] {
            if target == .pullRequest && fresh { continue }
            do {
                if target == .schedule {
                    _ = try await Worktrees.prepare(clone: fixture.clone, branch: "main", item: "nightly",
                        ghPath: "/usr/bin/true", runner: fixture.runner, fresh: fresh, note: { notes.append($0) })
                } else {
                    _ = try await fixture.prepare(target, notes: notes)
                }
                Issue.record("Preparation must reject a foreign existing path")
            } catch DispatchError.worktree(let message) {
                #expect(message.contains("not a worktree Bton made"))
            }
            #expect(try await fixture.git(["stash", "list"]).isEmpty)
            #expect(try await fixture.git(["rev-parse", "HEAD"]) == cloneHead)
            #expect(try await fixture.git(["worktree", "list", "--porcelain"]) == listingBefore)
            #expect(notes.messages.isEmpty)
            if let checkout = protectedCheckout {
                #expect(try await fixture.git(["rev-parse", "HEAD"], in: checkout) == fixture.oldHead)
                #expect(try Data(contentsOf: checkout.appendingPathComponent("tracked.txt")) == contents)
                #expect(try Data(contentsOf: checkout.appendingPathComponent("untracked.txt")) == contents)
                #expect(try await fixture.git(["stash", "list"], in: checkout).isEmpty)
            }
            if kind == "plainDirectory" {
                #expect(try Data(contentsOf: tree.appendingPathComponent("sentinel.txt")) == contents)
            }
            if kind == "checkoutLink" || kind == "danglingLink" {
                #expect(try manager.destinationOfSymbolicLink(atPath: tree.path) == external.path)
            }
            if kind == "parentLink" {
                #expect(try manager.destinationOfSymbolicLink(atPath: parent.path) == external.path)
            }
        }
    }

    @Test(arguments: LeftoverTarget.allCases)
    fileprivate func registeredBtonTreeWithDeletedGitFileRejectsWithoutStashingMainCheckout(target: LeftoverTarget) async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.existingTree(target)
        try FileManager.default.removeItem(at: tree.appendingPathComponent(".git"))
        let contents = Data("main checkout uncommitted work\n".utf8)
        try contents.write(to: fixture.clone.appendingPathComponent("tracked.txt"))
        try contents.write(to: fixture.clone.appendingPathComponent("untracked.txt"))
        let headBefore = try await fixture.git(["rev-parse", "HEAD"])
        let statusBefore = try await fixture.git(["status", "--porcelain", "--untracked-files=all"])
        let listingBefore = try await fixture.git(["worktree", "list", "--porcelain"])
        let resolvedTree = Darwin.realpath(tree.path, nil)
        let canonicalTree = try #require(resolvedTree)
        defer { free(canonicalTree) }
        #expect(listingBefore.contains("worktree \(String(cString: canonicalTree))\n"))
        #expect(try await fixture.git(["stash", "list"]).isEmpty)
        // Without .git, Git walks up to the main checkout despite the stale registration.
        let topLevel = try await fixture.git(["rev-parse", "--show-toplevel"], in: tree)
        let resolvedTopLevel = Darwin.realpath(topLevel, nil)
        let canonicalTopLevel = try #require(resolvedTopLevel)
        defer { free(canonicalTopLevel) }
        let resolvedClone = Darwin.realpath(fixture.clone.path, nil)
        let canonicalClone = try #require(resolvedClone)
        defer { free(canonicalClone) }
        #expect(String(cString: canonicalTopLevel) == String(cString: canonicalClone))
        let notes = LeftoverNotes()
        do {
            _ = try await fixture.prepare(target, notes: notes)
            Issue.record("Preparation must reject a registered tree whose .git file was deleted")
        } catch DispatchError.worktree(let message) {
            #expect(message.contains("not a worktree Bton made"))
        }
        #expect(try await fixture.git(["rev-parse", "HEAD"]) == headBefore)
        #expect(try await fixture.git(["status", "--porcelain", "--untracked-files=all"]) == statusBefore)
        #expect(try Data(contentsOf: fixture.clone.appendingPathComponent("tracked.txt")) == contents)
        #expect(try Data(contentsOf: fixture.clone.appendingPathComponent("untracked.txt")) == contents)
        #expect(try await fixture.git(["stash", "list"]).isEmpty)
        #expect(try await fixture.git(["worktree", "list", "--porcelain"]) == listingBefore)
        #expect(notes.messages.isEmpty)
    }

    @Test(arguments: LeftoverTarget.allCases)
    fileprivate func cleanExistingBtonTreeDoesNotStashOrNotify(target: LeftoverTarget) async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.existingTree(target)
        let notes = LeftoverNotes()
        let prepared = try await fixture.prepare(target, notes: notes)
        try await fixture.expectPrepared(prepared, tree: tree)
        #expect(try await fixture.git(["stash", "list"]).isEmpty)
        #expect(notes.messages.isEmpty)
    }

    @Test(arguments: LeftoverTarget.allCases)
    fileprivate func ignoredFilesInExistingBtonTreeDoNotStashOrNotify(target: LeftoverTarget) async throws {
        let fixture = try await LeftoverGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = try await fixture.existingTree(target)
        let ignored = tree.appendingPathComponent("ignored.txt")
        let contents = Data("ignored build output\n".utf8)
        try contents.write(to: ignored)
        let notes = LeftoverNotes()
        let prepared = try await fixture.prepare(target, notes: notes)
        try await fixture.expectPrepared(prepared, tree: tree)
        #expect(try await fixture.git(["stash", "list"]).isEmpty)
        #expect(notes.messages.isEmpty)
        #expect(try Data(contentsOf: ignored) == contents)
    }
}
