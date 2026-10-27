@testable import BtonCore
import Foundation
import Testing

struct FeatureStatusAcceptanceTests {
    @Test(ProcessBound()) func liveTakesTheMainMergeDate() async throws {
        let f = try await FeatureHistoryFixture.make()
        defer { f.remove() }
        var facts = FeatureFacts()
        facts.issues[402] = .init(number: 402, open: false, createdAt: f.date(1), labels: [], labeledAt: [:])
        facts.pullRequests[428] = .init(number: 428, state: "MERGED", createdAt: f.date(5),
            mergedAt: f.date(10), mergeCommit: f.m1, baseRef: "develop")
        let git = await f.read()
        #expect(git.onRelease.contains(f.m1))
        #expect(!git.onRelease.contains(f.m2))
        #expect(git.onBase.contains(f.m2))
        #expect(git.releasedAt[f.m1] == f.date(19))
        // A first-parent commit uses its own date, rather than the next commit's date.
        #expect(git.releasedAt[f.r1] == f.date(19))
        let feature = try FeatureAcceptanceData.feature(issues: [402], prs: [428])
        let standing = FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop", hasRelease: true)
        #expect(standing.status == .live)
        #expect(standing.since == f.date(19))
        #expect(standing.timeline.map(\.status) == [.idea, .building, .inDevelop, .live])
        #expect(standing.timeline.map(\.at) == [f.date(1), f.date(5), f.date(10), f.date(19)])
        #expect(standing.timeline.map(\.number) == [402, 428, 428, 428])
        #expect(standing.openIssues == 0)
        #expect(standing.openPullRequests == 0)
        #expect(standing.changes == [428])
    }

    @Test(ProcessBound()) func mergedIntoDevelopIsInDevelopOnlyWithARelease() async throws {
        let f = try await FeatureHistoryFixture.make()
        defer { f.remove() }
        var facts = FeatureFacts()
        facts.pullRequests[430] = .init(number: 430, state: "MERGED", createdAt: f.date(18),
            mergedAt: f.date(20), mergeCommit: f.m2, baseRef: "develop")
        let feature = try FeatureAcceptanceData.feature(prs: [430])
        let git = await f.read()
        let released = FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop", hasRelease: true)
        #expect(released.status == .inDevelop)
        #expect(released.since == f.date(20))
        #expect(released.timeline.last?.number == 430)
        #expect(FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop", hasRelease: false).status == .idea)
    }

    @Test func openPullRequestBeatsClosedReadyIssue() throws {
        var facts = FeatureFacts()
        facts.issues[402] = .init(number: 402, open: false, createdAt: day(1),
            labels: ["stage:ready"], labeledAt: ["stage:ready": day(9)])
        facts.pullRequests[428] = .init(number: 428, state: "OPEN", createdAt: day(10),
            mergedAt: nil, mergeCommit: nil, baseRef: "develop")
        facts.pullRequests[419] = .init(number: 419, state: "OPEN", createdAt: day(8),
            mergedAt: nil, mergeCommit: nil, baseRef: "develop")
        let standing = try standing(issues: [402], prs: [428, 419], facts: facts)
        #expect(standing.status == .building)
        #expect(standing.since == day(8))
        #expect(standing.timeline.last?.number == 419)
        #expect(!standing.timeline.contains { $0.status == .ready })
        #expect(standing.openIssues == 0)
        #expect(standing.openPullRequests == 2)
    }

    @Test(arguments: ["stage:ready", "stage:spec"])
    func readyAndSpecFromOpenIssueLabels(label: String) throws {
        var facts = FeatureFacts()
        facts.issues[402] = .init(number: 402, open: true, createdAt: day(1), labels: [label], labeledAt: [label: day(9)])
        let expected: FeatureStatus = label == "stage:ready" ? .ready : .spec
        let labeled = try standing(issues: [402], facts: facts)
        #expect(labeled.status == expected)
        #expect(labeled.since == day(9))
        #expect(labeled.timeline.last?.number == 402)
        #expect(labeled.openIssues == 1)
        facts.issues[402] = .init(number: 402, open: true, createdAt: day(1), labels: [label], labeledAt: [:])
        #expect(try standing(issues: [402], facts: facts).since == day(1))
    }

    @Test func readyPrecedesSpecAndUsesEarliestLabelDate() throws {
        var facts = FeatureFacts()
        facts.issues[402] = .init(number: 402, open: true, createdAt: day(1),
            labels: ["stage:ready", "stage:spec"], labeledAt: ["stage:spec": day(5), "stage:ready": day(9)])
        facts.issues[403] = .init(number: 403, open: true, createdAt: day(2),
            labels: ["stage:ready"], labeledAt: ["stage:ready": day(8)])
        let result = try standing(issues: [402, 403], facts: facts)
        #expect(result.status == .ready)
        #expect(result.since == day(8))
        #expect(result.timeline.map(\.status) == [.idea, .spec, .ready])
        #expect(result.timeline.map(\.at) == [day(1), day(5), day(8)])
        #expect(result.timeline.map(\.number) == [402, 402, 403])
    }

    @Test func ideaUsesEarliestIssueThenFirstSeen() throws {
        var facts = FeatureFacts()
        facts.issues[402] = .init(number: 402, open: false, createdAt: day(2), labels: [], labeledAt: [:])
        facts.issues[403] = .init(number: 403, open: false, createdAt: day(1), labels: [], labeledAt: [:])
        let result = try standing(issues: [402, 403], facts: facts)
        #expect(result.status == .idea)
        #expect(result.since == day(1))
        #expect(result.timeline.first?.number == 403)
        #expect(try standing(facts: FeatureFacts()).since == FeatureAcceptanceData.date("2026-10-03T00:00:00Z"))
        let undated = try FeatureAcceptanceData.feature(firstSeen: nil)
        #expect(FeatureStatuses.standing(of: undated, facts: FeatureFacts(), git: FeatureGit(), base: "main", hasRelease: false).since == nil)
    }

    @Test func unknownLinksCountForNothing() throws {
        let result = try standing(issues: [999], prs: [998], facts: FeatureFacts())
        #expect(result.status == .idea)
        #expect(result.openIssues == 0)
        #expect(result.openPullRequests == 0)
        #expect(result.changes.isEmpty)
        #expect(result.since == FeatureAcceptanceData.date("2026-10-03T00:00:00Z"))
    }

    @Test func earliestMergeWinsAndChangesAreNewestFirst() throws {
        var facts = FeatureFacts()
        for (number, dayNumber) in [(428, 10), (430, 20)] {
            facts.pullRequests[number] = .init(number: number, state: "MERGED", createdAt: day(5),
                mergedAt: day(dayNumber), mergeCommit: "sha\(number)", baseRef: "develop")
        }
        let result = try standing(prs: [430, 428], facts: facts)
        #expect(result.status == .inDevelop)
        #expect(result.since == day(10))
        #expect(result.changes == [430, 428])
    }

    @Test(ProcessBound()) func unreleasedSinceIsTheOldestCommitNotOnMain() async throws {
        let f = try await FeatureHistoryFixture.make()
        defer { f.remove() }
        #expect(await f.read().unreleasedSince == f.date(18))
    }

    @Test(ProcessBound()) func missingRefsReadAsEmpty() async throws {
        let f = try await FeatureHistoryFixture.make()
        defer { f.remove() }
        try await FeatureHistoryFixture.git(["update-ref", "-d", "refs/remotes/origin/main"], in: f.clone)
        let missingMain = await f.read()
        #expect(missingMain.onRelease.isEmpty)
        #expect(missingMain.releasedAt.isEmpty)
        #expect(missingMain.onBase.contains(f.m2))
        try await FeatureHistoryFixture.git(["update-ref", "-d", "refs/remotes/origin/develop"], in: f.clone)
        let missingBoth = await f.read()
        #expect(missingBoth.onBase.isEmpty)
        #expect(missingBoth.onRelease.isEmpty)
        #expect(missingBoth.unreleasedSince == nil)
    }

    @Test func statusOrderAndRawValues() {
        #expect(FeatureStatus.allCases == [.live, .inDevelop, .building, .ready, .spec, .idea])
        #expect(FeatureStatus.allCases.map(\.rawValue) == ["live", "in develop", "building", "ready", "spec", "idea"])
        #expect(FeatureStatus.allCases.reversed().sorted() == FeatureStatus.allCases)
    }

    private func day(_ n: Int) -> Date { FeatureHistoryFixture.date(n) }
    private func standing(issues: [Int] = [], prs: [Int] = [], facts: FeatureFacts) throws -> FeatureStanding {
        FeatureStatuses.standing(of: try FeatureAcceptanceData.feature(issues: issues, prs: prs),
            facts: facts, git: FeatureGit(), base: "develop", hasRelease: true)
    }
}

struct FeatureHistoryFixture {
    let clone: URL
    let m1: String, r1: String, m2: String
    // Chosen dates: October 2026, noon UTC each day; B is day 5 and M2's first commit is day 18.
    static func date(_ day: Int) -> Date {
        FeatureAcceptanceData.date(String(format: "2026-10-%02dT12:00:00Z", day))
    }
    func date(_ day: Int) -> Date { Self.date(day) }

    static func make() async throws -> Self {
        let clone = FileManager.default.temporaryDirectory.appendingPathComponent("feature-history-\(UUID())")
        try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
        do {
            try await git(["init", "--initial-branch=main"], in: clone)
            try await git(["config", "user.name", "Synthetic"], in: clone)
            try await git(["config", "user.email", "synthetic@example.invalid"], in: clone)
            try await commit("A", day: 1, in: clone)
            try await git(["branch", "develop"], in: clone)
            try await git(["checkout", "-b", "pr-one"], in: clone)
            try await commit("B", day: 5, in: clone)
            try await git(["checkout", "develop"], in: clone)
            try await git(["merge", "--no-ff", "pr-one", "-m", "M1"], in: clone, day: 10)
            let m1 = try await git(["rev-parse", "HEAD"], in: clone)
            try await git(["checkout", "main"], in: clone)
            try await git(["merge", "--no-ff", "develop", "-m", "R1"], in: clone, day: 19)
            let r1 = try await git(["rev-parse", "HEAD"], in: clone)
            try await git(["checkout", "-b", "pr-two", "develop"], in: clone)
            try await commit("C", day: 18, in: clone)
            try await git(["checkout", "develop"], in: clone)
            try await git(["merge", "--no-ff", "pr-two", "-m", "M2"], in: clone, day: 20)
            let m2 = try await git(["rev-parse", "HEAD"], in: clone)
            try await git(["update-ref", "refs/remotes/origin/main", r1], in: clone)
            try await git(["update-ref", "refs/remotes/origin/develop", m2], in: clone)
            return Self(clone: clone, m1: m1, r1: r1, m2: m2)
        } catch { try? FileManager.default.removeItem(at: clone); throw error }
    }

    func read() async -> FeatureGit {
        await FeatureGit.read(clone: clone, base: "develop", to: "main", commits: [m1, r1, m2])
    }
    func remove() { try? FileManager.default.removeItem(at: clone) }

    private static func commit(_ name: String, day: Int, in clone: URL) async throws {
        try await git(["commit", "--allow-empty", "-m", name], in: clone, day: day)
    }

    @discardableResult
    static func git(_ args: [String], in clone: URL, day: Int? = nil) async throws -> String {
        var env = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"]
        if let day {
            let iso = String(format: "2026-10-%02dT12:00:00Z", day)
            env["GIT_COMMITTER_DATE"] = iso; env["GIT_AUTHOR_DATE"] = iso
        }
        let result = try await ProcessRunner().run("/usr/bin/git", ["-c", "commit.gpgsign=false"] + args,
            in: clone, environment: env, timeout: .seconds(30))
        try #require(result.status == 0, "git \(args): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
