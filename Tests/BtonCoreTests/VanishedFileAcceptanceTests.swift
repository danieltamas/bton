@testable import BtonCore
import Foundation
import Testing

private enum VanishedTarget: CaseIterable, Sendable {
    case pullRequest, schedule
    var directory: String { self == .pullRequest ? "bton-pr-7" : "bton-nightly" }
}

private final class VanishedNotes: @unchecked Sendable {
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

private struct VanishedGitFixture {
    let root: URL
    let clone: URL
    let runner = ProcessRunner()

    private static let templates = VanishedTemplates()

    static func make(path: String) async throws -> Self {
        let seed = try await templates.seed(path: path)
        let root = try GitFixtureCopies.copy(seed.root)
        return Self(root: root, clone: root.appendingPathComponent("clone"))
    }

    fileprivate static func makeTemplate(path: String) async throws -> Self {
        let root = GitFixtureCopies.templates
            .appendingPathComponent("bton-vanished-acceptance-\(UUID())").resolvingSymlinksInPath()
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

    func prepare(_ target: VanishedTarget, notes: VanishedNotes) async throws -> URL {
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
        #expect(try await git(["config", "--bool", "core.sparseCheckoutCone"], in: tree) == "false")
        let patterns = try await git(["sparse-checkout", "list"], in: tree).split(separator: "\n").map(String.init)
        #expect(patterns.contains("/*"))
        #expect(patterns.contains("!/" + path.replacingOccurrences(of: "*", with: "\\*")))
        #expect(try String(contentsOf: tree.appendingPathComponent("quarantined other file.txt"), encoding: .utf8)
            == "literal glob witness\n")
    }
}

@Suite(ProcessBound())
struct VanishedFileAcceptanceTests {
    @Test(arguments: VanishedTarget.allCases, [
        ("quarantined.txt", false), ("quarantined.txt", true),
        ("quarantined * file.txt", false), ("quarantined * file.txt", true)
    ])
    fileprivate func quarantineIsSparseLocalLiteralAndSurvivesNewerHead(
        target: VanishedTarget, scenario: (String, Bool)
    ) async throws {
        let (path, existing) = scenario
        let fixture = try await VanishedGitFixture.make(path: path)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tree = fixture.clone.appendingPathComponent(".worktrees/\(target.directory)")
        if existing {
            try await fixture.git(["worktree", "add", "--detach", tree.path, "HEAD"])
            try FileManager.default.removeItem(at: tree.appendingPathComponent(path))
            #expect(try await fixture.git(["status", "--porcelain", "-z"], in: tree) == " D \(path)\0")
        }
        try await fixture.installQuarantine(path: path)
        let notes = VanishedNotes()
        let prepared = try await fixture.prepare(target, notes: notes)
        #expect(prepared.standardizedFileURL == tree.standardizedFileURL)
        try await fixture.expectCleanSparseTree(tree, path: path)
        #expect(notes.messages.contains { $0.contains(path) && $0.contains("left out") })
        // The hook saw actual restored content, including on the stash path for an existing tree.
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("quarantine.log"), encoding: .utf8)
            .contains("original quarantined content"))
        if existing {
            #expect(!(try await fixture.git(["stash", "list"])).isEmpty)
        }
        try fixture.write("agent.txt", "agent work\n", in: tree)
        try await fixture.git(["add", "-A"], in: tree)
        try await fixture.commit("Synthetic agent work", in: tree)
        #expect(try await fixture.git(["show", "HEAD:\(path)"], in: tree) == "original quarantined content")
        #expect(try await fixture.git(["diff", "HEAD^", "HEAD", "--name-only"], in: tree) == "agent.txt")

        try fixture.write(path, "new upstream quarantined content\n")
        try fixture.write("keep.txt", "new upstream other content\n")
        try await fixture.git(["add", "-A"])
        try await fixture.commit("Synthetic upstream update")
        try await fixture.push()
        let newHead = try await fixture.git(["rev-parse", "HEAD"])
        let again = try await fixture.prepare(target, notes: notes)
        #expect(again.standardizedFileURL == tree.standardizedFileURL)
        #expect(try await fixture.git(["rev-parse", "HEAD"], in: tree) == newHead)
        try await fixture.expectCleanSparseTree(tree, path: path)
        #expect(try String(contentsOf: tree.appendingPathComponent("keep.txt"), encoding: .utf8) == "new upstream other content\n")
        #expect(try await fixture.git(["show", "HEAD:\(path)"], in: tree) == "new upstream quarantined content")
        #expect(try String(contentsOf: fixture.clone.appendingPathComponent(path), encoding: .utf8) == "new upstream quarantined content\n")
        #expect(try await fixture.git(["status", "--porcelain"]).isEmpty)
        let sparse = try await fixture.runner.run("/usr/bin/git", ["config", "--bool", "core.sparseCheckout"],
            in: fixture.clone, timeout: .seconds(120))
        #expect(sparse.status == 1 || String(decoding: sparse.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "false")
    }

    @Test(arguments: VanishedTarget.allCases)
    fileprivate func dirtySubmoduleStillThrowsAfterStash(target: VanishedTarget) async throws {
        let fixture = try await VanishedGitFixture.make(path: "quarantined.txt")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let child = fixture.root.appendingPathComponent("child")
        try await fixture.git(["clone", fixture.clone.path, child.path], in: fixture.root)
        try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "add", child.path, "module"])
        try await fixture.commit("Synthetic submodule")
        try await fixture.push()
        let tree = fixture.clone.appendingPathComponent(".worktrees/\(target.directory)")
        try await fixture.git(["worktree", "add", "--detach", tree.path, "HEAD"])
        try await fixture.git(["-c", "protocol.file.allow=always", "submodule", "update", "--init"], in: tree)
        try fixture.write("module/keep.txt", "dirty submodule content\n", in: tree)
        let notes = VanishedNotes()
        do {
            _ = try await fixture.prepare(target, notes: notes)
            Issue.record("Preparation must reject changes that remain after stashing")
        } catch DispatchError.worktree(let message) {
            #expect(message.contains("still has changes after stashing"))
            #expect(message.contains("module"))
        }
        #expect(try String(contentsOf: tree.appendingPathComponent("module/keep.txt"), encoding: .utf8) == "dirty submodule content\n")
    }
}

private actor VanishedTemplates {
    private var seeds: [String: Task<VanishedGitFixture, Error>] = [:]

    func seed(path: String) async throws -> VanishedGitFixture {
        if let seed = seeds[path] { return try await seed.value }
        let seed = Task { try await VanishedGitFixture.makeTemplate(path: path) }
        seeds[path] = seed
        return try await seed.value
    }
}
