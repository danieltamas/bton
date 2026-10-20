@testable import BtonCore
import Foundation
import Testing

private func dispatchRegressionRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("bton-dispatch-regression-\(UUID())").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private struct DispatchGitFixture {
    let root: URL
    let clone: URL
    let userTree: URL
    let head: String
    let pr: PullRequest
    let runner = ProcessRunner()

    static func make() async throws -> DispatchGitFixture {
        let root = try dispatchRegressionRoot()
        do {
            let origin = root.appendingPathComponent("origin.git")
            let clone = root.appendingPathComponent("clone")
            let runner = ProcessRunner()
            try await git(["init", "--bare", "--initial-branch=main", origin.path], in: root, runner: runner)
            try await git(["clone", origin.path, clone.path], in: root, runner: runner)
            try await git(["config", "user.name", "Synthetic Tester"], in: clone, runner: runner)
            try await git(["config", "user.email", "synthetic@example.invalid"], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic main"],
                          in: clone, runner: runner)
            try await git(["push", "origin", "main"], in: clone, runner: runner)
            try await git(["checkout", "-b", "feature"], in: clone, runner: runner)
            try await git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic feature"],
                          in: clone, runner: runner)
            let head = try await git(["rev-parse", "HEAD"], in: clone, runner: runner)
            try await git(["push", "origin", "HEAD:refs/heads/feature", "HEAD:refs/pull/7/head"],
                          in: clone, runner: runner)
            try await git(["checkout", "main"], in: clone, runner: runner)
            return try DispatchGitFixture(root: root, clone: clone,
                userTree: root.appendingPathComponent("user-feature"), head: head, pr: pullRequest(head: head))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func addUserTree() async throws {
        try await Self.git(["worktree", "add", userTree.path, "feature"], in: clone, runner: runner)
    }

    func prepare() async throws -> URL {
        try await Worktrees.prepare(clone: clone, pr: pr, base: "main", ghPath: "/usr/bin/true", runner: runner)
    }

    func head(at path: URL) async throws -> String {
        try await Self.git(["rev-parse", "HEAD"], in: path, runner: runner)
    }

    func expectDetached(at path: URL) async throws {
        #expect(try await head(at: path) == head)
        let branch = try await runner.run("/usr/bin/git", ["symbolic-ref", "-q", "HEAD"],
                                          in: path, timeout: .seconds(15))
        #expect(branch.status == 1)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL, runner: ProcessRunner) async throws -> String {
        let result = try await runner.run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(15))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pullRequest(head: String) throws -> PullRequest {
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
        return try #require(GitHubClient.decodeOpenPullRequests(data, repo: "synthetic/project").pullRequests.first)
    }
}

struct DispatchRegressionTests {
    @Test func leaseRecordRemembersCurrentAndDoneKeys() {
        let record = LeaseRecord(holder: "synthetic", host: "fixture", job: UUID(),
            expires: Date(timeIntervalSince1970: 100), released: true, key: "k3", done: ["k1", "k2"])
        #expect(record.hasRun("k1"))
        #expect(record.hasRun("k3"))
        #expect(!record.hasRun("k4"))
        #expect(record.history == ["k1", "k2", "k3"])
        let empty = LeaseRecord(holder: "synthetic", host: "fixture", job: UUID(),
            expires: Date(timeIntervalSince1970: 100), released: false, key: nil, done: nil)
        #expect(!empty.hasRun("k1"))
        #expect(empty.history == nil)
    }

    @Test func leaseHistoryDropsOldestKeyAtLimit() throws {
        let done = (1...32).map { "k\($0)" }
        let record = LeaseRecord(holder: "synthetic", host: "fixture", job: UUID(),
            expires: Date(timeIntervalSince1970: 100), released: true, key: "k33", done: done)
        let history = try #require(record.history)
        #expect(history.count == 32)
        #expect(history == Array(done.dropFirst()) + ["k33"])
    }

    @Test func legacyLeaseRecordDecodesWithoutDone() throws {
        let json = """
        {"holder":"synthetic","host":"fixture","job":"11111111-1111-1111-1111-111111111111",
         "expires":"2026-10-19T12:00:00Z","released":true,"key":"k3"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(LeaseRecord.self, from: Data(json.utf8))
        #expect(record.done == nil)
        #expect(record.key == "k3")
    }

    @Test func legacyJobStoreLoadsWithoutDeadlineOrReview() throws {
        let root = try dispatchRegressionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try JobStore(home: BtonHome(environment: ["BTON_HOME": root.path]))
        let id = "11111111-1111-1111-1111-111111111111"
        let json = """
        {"id":"\(id)","key":{"repo":"synthetic/project","item":"pr-7","move":"review","head":"synthetic-head"},
         "agent":"synthetic-agent","startedAt":"2026-10-19T11:00:00Z","endedAt":"2026-10-19T12:00:00Z",
         "status":"succeeded","usage":{}}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("jobs/\(id).json"))
        let jobs = store.all()
        #expect(jobs.count == 1)
        let job = try #require(jobs.first)
        #expect(job.id == UUID(uuidString: id))
        #expect(job.startedAt == Date(timeIntervalSince1970: 1_792_407_600))
        #expect(job.deadline == nil)
        #expect(job.review == nil)
    }

    @Test func jobDeadlineAndReviewRoundTrip() throws {
        let root = try dispatchRegressionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let deadline = Date(timeIntervalSince1970: 200)
        let review = ReviewTarget(number: 7, head: "synthetic-head", headings: ["## Review:"])
        let job = Job(id: UUID(), key: JobKey(repo: "synthetic/project", item: "pr-7", move: "review", head: review.head),
            agent: "synthetic-agent", startedAt: Date(timeIntervalSince1970: 100), status: .running,
            deadline: deadline, review: review)
        try store.save(job)
        let jobs = try JobStore(home: home).all()
        #expect(jobs == [job])
        let loaded = try #require(jobs.first)
        #expect(loaded.deadline == deadline)
        #expect(loaded.review == review)
    }

    @Test func localLockExcludesSecondHolderAndClosesOnExec() throws {
        let root = try dispatchRegressionRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lease.lock")
        let lock = try #require(LocalLock(url))
        var released = false
        defer { if !released { lock.release() } }
        let blocked = LocalLock(url)
        defer { blocked?.release() }
        #expect(blocked == nil)
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["5"]
        try sleeper.run()
        defer {
            if sleeper.isRunning { sleeper.terminate() }
            sleeper.waitUntilExit()
        }
        #expect(sleeper.isRunning)
        lock.release()
        released = true
        let deadline = Date().addingTimeInterval(1)
        var replacement = LocalLock(url)
        while replacement == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            replacement = LocalLock(url)
        }
        defer { replacement?.release() }
        #expect(sleeper.isRunning)
        #expect(replacement != nil)
    }

    @Test func cleanBranchWorktreeAtHeadIsReused() async throws {
        let fixture = try await DispatchGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.addUserTree()
        #expect(try await fixture.prepare().standardizedFileURL.path == fixture.userTree.standardizedFileURL.path)
        #expect(try await fixture.head(at: fixture.userTree) == fixture.head)
    }

    @Test func dirtyBranchWorktreeIsPreservedAndDetachedTreeIsUsed() async throws {
        let fixture = try await DispatchGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.addUserTree()
        let dirty = fixture.userTree.appendingPathComponent("uncommitted.txt")
        let contents = Data("Synthetic uncommitted work\n".utf8)
        try contents.write(to: dirty)
        let prepared = try await fixture.prepare()
        #expect(prepared.standardizedFileURL.path == fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").standardizedFileURL.path)
        try await fixture.expectDetached(at: prepared)
        #expect(try Data(contentsOf: dirty) == contents)
        #expect(try await fixture.head(at: fixture.userTree) == fixture.head)
    }

    @Test func branchWorktreeWithExtraLocalCommitIsNotReused() async throws {
        let fixture = try await DispatchGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.addUserTree()
        try await DispatchGitFixture.git(["-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic local work"],
                                         in: fixture.userTree, runner: fixture.runner)
        let localHead = try await fixture.head(at: fixture.userTree)
        #expect(localHead != fixture.head)
        let prepared = try await fixture.prepare()
        #expect(prepared.standardizedFileURL.path == fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").standardizedFileURL.path)
        try await fixture.expectDetached(at: prepared)
        #expect(try await fixture.head(at: fixture.userTree) == localHead)
    }

    @Test func detachedWorktreeIsReusedOnSecondPrepare() async throws {
        let fixture = try await DispatchGitFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try await fixture.prepare()
        let second = try await fixture.prepare()
        #expect(first.standardizedFileURL.path == fixture.clone.appendingPathComponent(".worktrees/bton-pr-7").standardizedFileURL.path)
        #expect(second.standardizedFileURL.path == first.standardizedFileURL.path)
        try await fixture.expectDetached(at: second)
    }
}

private struct DispatchLeaseFixture: Sendable {
    let root: URL
    let repo: String
    let item: LeaseItem
    let ghPath: String

    init() throws {
        repo = try #require(ProcessInfo.processInfo.environment["BTON_SANDBOX"])
        item = try #require(LeaseItem("pr-\(Int.random(in: 1_000_000...9_999_999))"))
        ghPath = try #require(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: FileManager.default.isExecutableFile))
        root = try dispatchRegressionRoot()
    }

    func store() throws -> LeaseStore {
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(UUID().uuidString).path],
                            homeDirectory: root)
        return try LeaseStore(home: home, holder: "bton-test", host: "dispatch-regression-host", github: GitHubClient())
    }

    func cleanup() async {
        await Task.detached {
            do {
                let result = try await ProcessRunner().run(ghPath,
                    ["api", "-X", "DELETE", "repos/\(repo)/git/refs/bton/leases/\(item)"], timeout: .seconds(20))
                let missing = result.stderr.contains("HTTP 404") || result.stderr.contains("HTTP 422")
                #expect(result.status == 0 || missing, "Lease ref cleanup failed: \(result.stderr)")
            } catch {
                Issue.record("Lease ref cleanup failed: \(error)")
            }
            try? FileManager.default.removeItem(at: root)
        }.value
    }
}

private func withDispatchLeaseFixture(_ body: (DispatchLeaseFixture) async throws -> Void) async throws {
    let fixture = try DispatchLeaseFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanup()
        throw error
    }
    await fixture.cleanup()
}

private func dispatchClaimedLease(_ result: ClaimResult) throws -> Lease {
    guard case let .claimed(lease) = result else {
        Issue.record("Fixture claim must win before exercising lease history")
        throw LeaseError.failed("Fixture claim did not win")
    }
    return lease
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["BTON_SANDBOX"] != nil))
struct DispatchLeaseRegressionTests {
    @Test(.timeLimit(.minutes(2)))
    func doneKeysSurviveTheNextMove() async throws {
        try await withDispatchLeaseFixture { fixture in
            let store = try fixture.store()
            let a = try dispatchClaimedLease(try await store.claim(fixture.item, in: fixture.repo, key: "A"))
            try await store.release(a)
            let b = try dispatchClaimedLease(try await store.claim(fixture.item, in: fixture.repo, key: "B"))
            try await store.release(b)
            let repeated = try await store.claim(fixture.item, in: fixture.repo, key: "A")
            guard case .notClaimed = repeated else {
                Issue.record("A completed key must not be claimed again")
                return
            }
            let c = try dispatchClaimedLease(try await store.claim(fixture.item, in: fixture.repo, key: "C"))
            #expect(c.record.done == ["A", "B"])
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func renewedAndReleasedLeaseKeepDoneKeys() async throws {
        try await withDispatchLeaseFixture { fixture in
            let store = try fixture.store()
            let a = try dispatchClaimedLease(try await store.claim(fixture.item, in: fixture.repo, key: "A"))
            try await store.release(a)
            let b = try dispatchClaimedLease(try await store.claim(fixture.item, in: fixture.repo, key: "B"))
            #expect(b.record.done == ["A"])
            let renewed = try await store.renew(b)
            #expect(renewed.record.done == ["A"])
            try await store.release(renewed)
            let state = try await store.state(of: fixture.item, in: fixture.repo)
            guard case let .free(record) = state else {
                Issue.record("Expected the renewed lease to be released")
                return
            }
            #expect(record.done == ["A"])
            #expect(record.key == "B")
            #expect(record.released)
        }
    }
}
