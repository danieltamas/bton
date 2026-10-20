@testable import BtonCore
import Foundation
import Testing

private enum QueueFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let agents = ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]

    static func candidate(_ repo: String = "owner/a", _ number: Int = 1,
                          schedule: Bool = false, agent: String = "synthetic") -> DispatchCandidate {
        let pr = PullRequest(repo: repo, number: number, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/\(number)")!,
            headSha: "synthetic-head", headRef: "feat/x", baseRef: "main", body: "",
            isDraft: false, labels: [], assignees: [], comments: [], updatedAt: now)
        let move = schedule ? "schedule" : "review"
        return DispatchCandidate(target: schedule ? .branch("main") : .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: repo, item: schedule ? "schedule-\(number)" : "pr-\(number)",
                        move: move, head: "synthetic-head"),
            agent: agent, prompt: "Synthetic", command: nil, postComment: false, timeout: .seconds(60))
    }

    static func job(_ key: JobKey, status: Job.Status = .running) -> Job {
        Job(id: UUID(), key: key, agent: "synthetic", startedAt: now.addingTimeInterval(-60), status: status)
    }

    static func select(_ candidates: [DispatchCandidate], jobs: [Job] = [], max: Int = 10,
                       first: [String] = []) -> [JobKey] {
        DispatchPlanner.select(candidates, jobs: jobs, maxAgents: max, agents: agents, first: first).map(\.key)
    }
}

struct QueueAcceptanceTests {
    @Test func repositoriesTakeTurns() {
        let a = (1...3).map { QueueFixture.candidate("owner/a", $0) }
        let b = QueueFixture.candidate("owner/b", 4)
        #expect(QueueFixture.select(a + [b], max: 2) == [a[0].key, b.key])
    }

    @Test func oldestPRPrecedesOtherPRsAndSchedule() {
        let twelve = QueueFixture.candidate("owner/a", 12)
        let five = QueueFixture.candidate("owner/a", 5)
        let nine = QueueFixture.candidate("owner/a", 9)
        let schedule = QueueFixture.candidate(schedule: true)
        #expect(QueueFixture.select([schedule, twelve, five, nine], max: 1) == [five.key])
        #expect(QueueFixture.select([schedule, twelve, five, nine]) == [five.key, nine.key, twelve.key])
        #expect(QueueFixture.select([schedule]) == [schedule.key])
    }

    @Test func scheduleWaitsForRunningRepoRegardlessOfCase() {
        let schedule = QueueFixture.candidate("OWNER/A", schedule: true)
        let other = QueueFixture.candidate("owner/b")
        let running = QueueFixture.job(QueueFixture.candidate("owner/a", 99).key)
        #expect(QueueFixture.select([schedule, other], jobs: [running]) == [other.key])
    }

    @Test func scheduleWaitsForRepoPickedInSameCall() {
        let pr = QueueFixture.candidate("owner/a")
        let schedule = QueueFixture.candidate("OWNER/A", schedule: true)
        #expect(QueueFixture.select([schedule, pr]) == [pr.key])
    }

    @Test func runningScheduleBlocksOnlyItsRepo() {
        let pr = QueueFixture.candidate("OWNER/A")
        let schedule = QueueFixture.candidate("owner/a", 2, schedule: true)
        let other = QueueFixture.candidate("owner/b")
        let running = QueueFixture.job(QueueFixture.candidate("owner/a", 99, schedule: true).key)
        #expect(QueueFixture.select([pr, schedule, other], jobs: [running]) == [other.key])
    }

    @Test(arguments: [Job.Status.running, .succeeded, .failed, .cancelled])
    func existingJobKeyIsNeverPicked(status: Job.Status) {
        let candidate = QueueFixture.candidate()
        #expect(QueueFixture.select([candidate], jobs: [QueueFixture.job(candidate.key, status: status)]).isEmpty)
    }

    @Test func runningItemUnknownAgentAndCapacityAreRespected() {
        let candidate = QueueFixture.candidate()
        let sameItem = JobKey(repo: "OWNER/A", item: candidate.key.item, move: "fix", head: "older")
        #expect(QueueFixture.select([candidate], jobs: [QueueFixture.job(sameItem)]).isEmpty)
        #expect(QueueFixture.select([QueueFixture.candidate(agent: "unknown")]).isEmpty)
        let other = QueueFixture.candidate("owner/b")
        let running = QueueFixture.job(QueueFixture.candidate("owner/c").key)
        #expect(QueueFixture.select([candidate, other], jobs: [running], max: 2) == [candidate.key])
        #expect(QueueFixture.select([candidate], jobs: [running], max: 1).isEmpty)
    }

    @Test func firstPicksPrecedeTurnsInRequestedOrder() {
        let a = QueueFixture.candidate("owner/a", 1)
        let b = QueueFixture.candidate("Owner/Name", 9)
        let c = QueueFixture.candidate("owner/c", 3)
        #expect(QueueFixture.select([a, b, c], first: ["owner/name#pr-9", "owner/c#pr-3"])
            == [b.key, c.key, a.key])
    }

    @Test func firstScheduleExcludesLaterCandidatesInItsRepo() {
        let pr = QueueFixture.candidate()
        let schedule = QueueFixture.candidate(schedule: true)
        let other = QueueFixture.candidate("owner/b")
        #expect(QueueFixture.select([pr, other, schedule], first: ["owner/a#schedule-1"])
            == [schedule.key, other.key])
    }

    @Test func firstPicksStillRespectExclusions() {
        let schedule = QueueFixture.candidate(schedule: true)
        let seen = QueueFixture.candidate("owner/b", 9)
        let busy = QueueFixture.candidate("owner/c", 9)
        let unknown = QueueFixture.candidate("owner/d", 9, agent: "unknown")
        let allowed = QueueFixture.candidate("owner/e", 9)
        let jobs = [QueueFixture.job(QueueFixture.candidate("OWNER/A", 99).key),
                    QueueFixture.job(seen.key, status: .failed),
                    QueueFixture.job(JobKey(repo: "owner/c", item: "pr-9", move: "fix", head: "old"))]
        #expect(QueueFixture.select([schedule, seen, busy, unknown, allowed], jobs: jobs, max: 3,
            first: ["owner/a#schedule-1", "owner/b#pr-9", "owner/c#pr-9", "owner/d#pr-9", "owner/e#pr-9"])
            == [allowed.key])
    }

    @Test(arguments: [true, false])
    func runNowOverridesRecentRunAndDisabledEntry(enabled: Bool) throws {
        let entry = ScheduleEntry(name: "Synthetic", everyMinutes: 60, enabled: enabled,
            repo: "owner/a", agent: "synthetic", prompt: "Synthetic", number: 7)
        let item = try #require(entry.item)
        let job = QueueFixture.job(JobKey(repo: "owner/a", item: item, move: "schedule", head: "previous"),
                                   status: .succeeded)
        let ordinary = DispatchPlanner.scheduled([entry], jobs: [job], repo: "owner/a",
            defaultBranch: "main", me: "owner", now: QueueFixture.now)
        let forced = DispatchPlanner.scheduled([entry], jobs: [job], repo: "owner/a",
            defaultBranch: "main", me: "owner", now: QueueFixture.now, runNow: [item])
        #expect(ordinary.isEmpty)
        #expect(forced.map(\.key.item) == [item])
        #expect(forced.map(\.key.move) == ["schedule"])
    }

    @Test(arguments: [true, false])
    func mergedHeadFieldsDecodeWithLegacyDefaults(includeHead: Bool) throws {
        var row: [String: Any] = ["number": 7, "title": "Synthetic", "author": ["login": "owner"],
            "url": "https://example.invalid/pr/7", "mergedAt": "2026-10-19T12:00:00Z"]
        if includeHead { row["headRefName"] = "feat/x"; row["headRefOid"] = "synthetic-sha" }
        let rows = try GitHubClient.decodeMerged(JSONSerialization.data(withJSONObject: [row]), repo: "owner/a")
        let pr = try #require(rows.first)
        #expect(rows.count == 1)
        #expect(pr.headRef == (includeHead ? "feat/x" : ""))
        #expect(pr.headSha == (includeHead ? "synthetic-sha" : ""))
    }

    @Test func mergedCleanTreesAndBranchAreRemoved() async throws {
        let fixture = try await QueueGitFixture.make()
        defer { fixture.dispose() }
        let removed = await fixture.remove()
        #expect(Set(removed) == Set([fixture.branchTree.path, fixture.detachedTree.path]))
        let paths = try await fixture.listedPaths()
        #expect(!paths.contains(fixture.branchTree.path))
        #expect(!paths.contains(fixture.detachedTree.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.branchTree.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.detachedTree.path))
        #expect(try await fixture.git(["branch", "--list", "feat/x"]).isEmpty)
    }

    @Test(arguments: ["untracked", "modified", "different-head", "busy", "busy-subfolder", "locked"])
    func unsafeMergedTreeAndItsBranchStay(reason: String) async throws {
        let fixture = try await QueueGitFixture.make()
        defer { fixture.dispose() }
        var busy: [String] = []
        switch reason {
        case "untracked":
            try Data("keep".utf8).write(to: fixture.branchTree.appendingPathComponent("untracked.txt"))
        case "modified":
            try Data("changed".utf8).write(to: fixture.branchTree.appendingPathComponent("tracked.txt"))
        case "different-head":
            _ = try await fixture.git(["commit", "--allow-empty", "-m", "Later synthetic commit"], in: fixture.branchTree)
        case "busy": busy = [fixture.branchTree.path]
        case "busy-subfolder":
            let child = fixture.branchTree.appendingPathComponent("subfolder")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            busy = [child.path]
        case "locked": _ = try await fixture.git(["worktree", "lock", fixture.branchTree.path])
        default: Issue.record("Unknown fixture condition")
        }
        let removed = await fixture.remove(busy: busy)
        #expect(!removed.contains(fixture.branchTree.path))
        #expect(removed == [fixture.detachedTree.path])
        #expect(FileManager.default.fileExists(atPath: fixture.branchTree.path))
        #expect(try await fixture.listedPaths().contains(fixture.branchTree.path))
        #expect(try await fixture.git(["branch", "--list", "feat/x"]).contains("feat/x"))
    }

    @Test func mainCheckoutOnMergedBranchIsNeverRemoved() async throws {
        let fixture = try await QueueGitFixture.make()
        defer { fixture.dispose() }
        _ = try await fixture.git(["worktree", "remove", fixture.branchTree.path])
        _ = try await fixture.git(["checkout", "feat/x"])
        #expect(try await fixture.git(["rev-parse", "HEAD"]) == fixture.sha)
        let removed = await fixture.remove()
        #expect(removed == [fixture.detachedTree.path])
        #expect(!removed.contains(fixture.clone.path))
        #expect(FileManager.default.fileExists(atPath: fixture.clone.appendingPathComponent("tracked.txt").path))
        #expect(try await fixture.listedPaths().contains(fixture.clone.path))
        #expect(try await fixture.git(["symbolic-ref", "--short", "HEAD"]) == "feat/x")
    }

    @Test func emptyMergedHeadRemovesNothing() async throws {
        let fixture = try await QueueGitFixture.make()
        defer { fixture.dispose() }
        #expect(await fixture.remove(headSha: "").isEmpty)
        #expect(try await fixture.listedPaths() == Set([fixture.clone.path, fixture.branchTree.path, fixture.detachedTree.path]))
        #expect(try await fixture.git(["branch", "--list", "feat/x"]).contains("feat/x"))
    }

    @Test func workingDirectoriesContainsThisProcessDirectory() async throws {
        let directories = try #require(await Worktrees.workingDirectories(runner: ProcessRunner()))
        let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).resolvingSymlinksInPath().path
        #expect(directories.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }.contains(current))
    }
}

private struct QueueGitFixture {
    let clone: URL
    let sha: String
    var branchTree: URL { clone.appendingPathComponent(".worktrees/x").resolvingSymlinksInPath() }
    var detachedTree: URL { clone.appendingPathComponent(".worktrees/bton-pr-7").resolvingSymlinksInPath() }

    static func make() async throws -> Self {
        let clone = FileManager.default.temporaryDirectory.appendingPathComponent("bton-queue-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        do {
            let initial = Self(clone: clone, sha: "")
            _ = try await initial.git(["init", "--initial-branch=main"])
            _ = try await initial.git(["config", "user.name", "Synthetic Test"])
            _ = try await initial.git(["config", "user.email", "test@example.invalid"])
            _ = try await initial.git(["config", "commit.gpgSign", "false"])
            try Data("initial".utf8).write(to: clone.appendingPathComponent("tracked.txt"))
            _ = try await initial.git(["add", "tracked.txt"])
            _ = try await initial.git(["commit", "-m", "Synthetic initial commit"])
            let sha = try await initial.git(["rev-parse", "HEAD"])
            let fixture = Self(clone: clone, sha: sha)
            _ = try await fixture.git(["branch", "feat/x", sha])
            _ = try await fixture.git(["worktree", "add", fixture.branchTree.path, "feat/x"])
            _ = try await fixture.git(["worktree", "add", "--detach", fixture.detachedTree.path, sha])
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: clone)
            throw error
        }
    }

    func dispose() { try? FileManager.default.removeItem(at: clone) }

    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git",
            ["-c", "core.hooksPath=/dev/null"] + arguments, in: directory ?? clone,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                          "GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(20))
        try #require(result.status == 0, "git \(arguments): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func listedPaths() async throws -> Set<String> {
        let listing = try await git(["worktree", "list", "--porcelain"])
        return Set(listing.split(separator: "\n").filter { $0.hasPrefix("worktree ") }
            .map { URL(fileURLWithPath: String($0.dropFirst("worktree ".count)))
                .resolvingSymlinksInPath().path })
    }

    func remove(busy: [String] = [], headSha: String? = nil) async -> [String] {
        let pr = MergedPullRequest(repo: "owner/a", number: 7, title: "Synthetic", author: "owner",
            url: URL(string: "https://example.invalid/pr/7")!, mergedAt: QueueFixture.now,
            totalCost: nil, headRef: "feat/x", headSha: headSha ?? sha)
        return await Worktrees.removeMerged(pr, clone: clone, busy: busy,
                                           ghPath: "/usr/bin/true", runner: ProcessRunner())
    }
}
