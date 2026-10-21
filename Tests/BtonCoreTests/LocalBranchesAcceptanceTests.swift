@testable import BtonCore
import Foundation
import Testing

private struct LocalBranchFixture {
    let root: URL
    let clone: URL
    let upstream: URL
    let runner = ProcessRunner()

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-local-branches-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = Self(root: root, clone: root.appendingPathComponent("owner"),
                     upstream: root.appendingPathComponent("publisher"))
        do {
            let origin = root.appendingPathComponent("origin.git")
            try await f.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
            try await f.git(["clone", origin.path, f.upstream.path], in: root)
            try await f.configure(f.upstream)
            try f.write("tracked.txt", "base\n", in: f.upstream)
            try f.write("unrelated.txt", "base unrelated\n", in: f.upstream)
            try await f.commit(in: f.upstream)
            try await f.git(["branch", "develop"], in: f.upstream)
            try await f.git(["push", "origin", "main", "develop"], in: f.upstream)
            try await f.git(["clone", origin.path, f.clone.path], in: root)
            try await f.configure(f.clone)
            try await f.git(["checkout", "-b", "develop", "origin/develop"])
            return f
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func configure(_ directory: URL) async throws {
        try await git(["config", "user.name", "Synthetic Tester"], in: directory)
        try await git(["config", "user.email", "synthetic@example.invalid"], in: directory)
        try await git(["config", "commit.gpgsign", "false"], in: directory)
        try await git(["config", "core.hooksPath", "/dev/null"], in: directory)
    }

    func write(_ path: String, _ value: String, in directory: URL? = nil) throws {
        try Data(value.utf8).write(to: (directory ?? clone).appendingPathComponent(path))
    }

    func read(_ path: String, in directory: URL? = nil) throws -> String {
        try String(contentsOf: (directory ?? clone).appendingPathComponent(path), encoding: .utf8)
    }

    func commit(in directory: URL? = nil) async throws {
        try await git(["add", "-A"], in: directory)
        try await git(["-c", "commit.gpgsign=false", "commit", "-m", "Synthetic change"], in: directory)
    }

    func advance(_ branch: String, count: Int = 1) async throws {
        try await git(["checkout", branch], in: upstream)
        for index in 1...count {
            try write("tracked.txt", "upstream \(branch) \(index)\n", in: upstream)
            try await commit(in: upstream)
        }
        try await git(["push", "origin", branch], in: upstream)
    }

    func sync(_ working: String = "develop", _ defaultBranch: String = "main") async -> LocalBranchReport {
        await LocalBranches.sync(clone: clone, working: working, defaultBranch: defaultBranch, runner: runner)
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL? = nil) async throws -> String {
        let result = try await runner.run("/usr/bin/git", arguments, in: directory ?? clone,
            environment: ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0"],
            timeout: .seconds(15))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
}

struct LocalBranchesAcceptanceTests {
    @Test func behindCheckedOutDevelopPullsAndPreservesUnrelatedDirtyFile() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.advance("develop", count: 2)
        try f.write("unrelated.txt", "owner edits\n")
        let report = await f.sync()
        #expect(report.problem == nil)
        #expect(report.branches.map(\.name) == ["develop", "main"])
        #expect(report.branches[0] == BranchStatus(name: "develop", ahead: 0, behind: 0, pulled: 2))
        #expect(try await f.git(["rev-parse", "develop"]) == f.git(["rev-parse", "origin/develop"]))
        #expect(try f.read("tracked.txt") == "upstream develop 2\n")
        #expect(try f.read("unrelated.txt") == "owner edits\n")
        #expect(try await f.git(["status", "--porcelain"]) == " M unrelated.txt")
    }

    @Test func conflictingDirtyFileHoldsBranchAndPreservesOwnerContent() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let before = try await f.git(["rev-parse", "develop"])
        try await f.advance("develop")
        try f.write("tracked.txt", "owner conflict\n")
        let report = await f.sync()
        let status = try #require(report.branches.first)
        #expect(status.ahead == 0 && status.behind == 1 && status.pulled == 0)
        #expect(status.held?.hasPrefix("not pulled: ") == true)
        #expect(try await f.git(["rev-parse", "develop"]) == before)
        #expect(try f.read("tracked.txt") == "owner conflict\n")
        #expect(try await f.git(["status", "--porcelain"]) == " M tracked.txt")
    }

    @Test func uncheckedMainFastForwardsRefWithoutChangingWorkingTree() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let head = try await f.git(["rev-parse", "HEAD"])
        try await f.advance("main", count: 2)
        let report = await f.sync()
        #expect(report.branches[1] == BranchStatus(name: "main", ahead: 0, behind: 0, pulled: 2))
        #expect(try await f.git(["rev-parse", "main"]) == f.git(["rev-parse", "origin/main"]))
        #expect(try await f.git(["rev-parse", "HEAD"]) == head)
        #expect(try await f.git(["branch", "--show-current"]) == "develop")
        #expect(try f.read("tracked.txt") == "base\n")
        #expect(try await f.git(["status", "--porcelain"]).isEmpty)
    }

    @Test func linkedWorktreeReceivesCheckedOutBranchUpdate() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let linked = f.root.appendingPathComponent("linked tree with spaces")
        try await f.git(["worktree", "add", linked.path, "main"])
        try await f.advance("main")
        let report = await f.sync()
        #expect(report.branches[1] == BranchStatus(name: "main", ahead: 0, behind: 0, pulled: 1))
        #expect(try f.read("tracked.txt", in: linked) == "upstream main 1\n")
        #expect(try await f.git(["rev-parse", "HEAD"], in: linked) == f.git(["rev-parse", "origin/main"]))
        #expect(try await f.git(["status", "--porcelain"], in: linked).isEmpty)
        #expect(try f.read("tracked.txt") == "base\n")
    }

    @Test(arguments: [false, true])
    func localCommitsAreUntouchedWhetherAheadOnlyOrDiverged(diverged: Bool) async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("local.txt", "local synthetic commit\n")
        try await f.commit()
        let before = try await f.git(["rev-parse", "HEAD"])
        if diverged { try await f.advance("develop", count: 2) }
        let report = await f.sync()
        let status = try #require(report.branches.first)
        #expect(status.ahead == 1 && status.behind == (diverged ? 2 : 0) && status.pulled == 0)
        if diverged { #expect(status.held?.hasPrefix("diverged: ") == true) }
        else { #expect(status.held == nil) }
        #expect(try await f.git(["rev-parse", "HEAD"]) == before)
        #expect(try f.read("local.txt") == "local synthetic commit\n")
        #expect(try await f.git(["status", "--porcelain"]).isEmpty)
    }

    @Test func missingLocalBranchIsReportedAndNeverCreated() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.git(["branch", "-D", "main"])
        let report = await f.sync()
        #expect(report.branches[1] == BranchStatus(name: "main", held: "no local main"))
        #expect(try await f.git(["for-each-ref", "--format=%(refname)", "refs/heads/main"]).isEmpty)
        #expect(report.workingOnly == 0 && report.defaultOnly == 0)
    }

    @Test func missingOriginBranchHasUnknownCounts() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.git(["branch", "absent"])
        let report = await f.sync("absent")
        #expect(report.branches.map(\.name) == ["absent", "main"])
        #expect(report.branches[0] == BranchStatus(name: "absent", held: "origin has no absent"))
        #expect(report.branches[1] == BranchStatus(name: "main", ahead: 0, behind: 0))
        #expect(report.workingOnly == nil && report.defaultOnly == nil)
    }

    @Test func comparisonCountsUseFreshOriginRefsInBothDirections() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // The configured fetch omits develop; sync must explicitly fetch both names.
        try await f.git(["config", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
        try await f.advance("develop", count: 3)
        try await f.advance("main", count: 2)
        let report = await f.sync()
        #expect(report.problem == nil)
        #expect(report.workingOnly == 3 && report.defaultOnly == 2)
        #expect(report.branches.map(\.pulled) == [3, 2])
        #expect(report.branches.allSatisfy { $0.behind == 0 && $0.held == nil })
    }

    @Test func failedFetchStillUsesExistingTrackingRefsAndPulls() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.advance("develop", count: 2)
        try await f.git(["fetch", "origin"])
        try await f.git(["remote", "set-url", "origin", f.root.appendingPathComponent("nonexistent.git").path])
        let report = await f.sync()
        #expect(report.problem?.hasPrefix("fetching origin failed: ") == true)
        #expect(report.branches[0] == BranchStatus(name: "develop", ahead: 0, behind: 0, pulled: 2))
        #expect(report.branches[1] == BranchStatus(name: "main", ahead: 0, behind: 0))
        #expect(report.workingOnly == 2 && report.defaultOnly == 0)
        #expect(try f.read("tracked.txt") == "upstream develop 2\n")
    }

    @Test func identicalNamesProduceOneStatusAndNoComparison() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        try await f.advance("develop")
        let report = await f.sync("develop", "develop")
        #expect(report.problem == nil)
        #expect(report.branches == [BranchStatus(name: "develop", ahead: 0, behind: 0, pulled: 1)])
        #expect(report.workingOnly == nil && report.defaultOnly == nil)
    }

    @Test func allowedASCIINameWithSlashDotUnderscoreAndDashIsSynced() async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let name = "release/V1.2_fix-3"
        try await f.git(["checkout", "-b", name], in: f.upstream)
        try await f.git(["push", "origin", name], in: f.upstream)
        try await f.git(["fetch", "origin"])
        try await f.git(["branch", name, "origin/\(name)"])
        try await f.advance(name)
        let report = await f.sync(name)
        #expect(report.problem == nil)
        #expect(report.branches.map(\.name) == [name, "main"])
        #expect(report.branches[0] == BranchStatus(name: name, ahead: 0, behind: 0, pulled: 1))
        #expect(report.workingOnly == 1 && report.defaultOnly == 0)
        #expect(try await f.git(["rev-parse", name]) == f.git(["rev-parse", "origin/\(name)"]))
    }

    @Test(arguments: ["", "-main", "/main", "a..b", "a b", "a:b", "a*b", "a?b", "a[b", "a\\b", "maïn", "a\nb"])
    func invalidNamesAreIgnoredAlongsideValidBranch(invalid: String) async throws {
        let f = try await LocalBranchFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for (working, defaultBranch) in [(invalid, "main"), ("main", invalid)] {
            let report = await f.sync(working, defaultBranch)
            #expect(report.problem == nil)
            #expect(report.branches == [BranchStatus(name: "main", ahead: 0, behind: 0)])
            #expect(report.workingOnly == nil && report.defaultOnly == nil)
        }
        let none = await f.sync(invalid, invalid)
        #expect(none.problem == "no branch to sync")
        #expect(none.branches.isEmpty)
        #expect(none.workingOnly == nil && none.defaultOnly == nil)
    }

    @Test func checkedOutParsesPathsAndIgnoresDetachedAndBareEntries() {
        let porcelain = """
        worktree /synthetic/owner clone
        HEAD aaaaaa
        branch refs/heads/develop

        worktree /synthetic/linked tree
        HEAD bbbbbb
        branch refs/heads/release/v1.2_fix-3
        locked synthetic reason

        worktree /synthetic/detached
        HEAD cccccc
        detached

        worktree /synthetic/origin.git
        bare

        """
        #expect(LocalBranches.checkedOut(porcelain) == [
            "refs/heads/develop": "/synthetic/owner clone",
            "refs/heads/release/v1.2_fix-3": "/synthetic/linked tree"
        ])
        #expect(LocalBranches.checkedOut("").isEmpty)
    }
}
