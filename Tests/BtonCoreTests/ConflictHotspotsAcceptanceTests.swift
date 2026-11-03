@testable import BtonCore
import Foundation
import Testing

private enum HotspotsFixture {
    static let now = WatchdogFixture.now
    static func job(item: String = "pr-7", paths: [String] = ["Sources/Shared.swift"],
                    repo: String = "synthetic/project", move: String = "resolve", age: TimeInterval = 60) -> Job {
        var job = Job(id: UUID(), key: JobKey(repo: repo, item: item, move: move, head: "head"),
            agent: "claude", startedAt: now.addingTimeInterval(-age), endedAt: now,
            status: .succeeded)
        job.conflicts = paths
        return job
    }
}

@Suite(ProcessBound())
struct ConflictHotspotsAcceptanceTests {
    @Test func conflictPathsStopsBeforeMergeTreeInformationalMessagesAndDeduplicatesInOrder() {
        // merge-tree --write-tree --name-only envelope: tree id, conflicted paths, blank,
        // then informational messages (which must never be mistaken for paths).
        let output = """
        62b0cfa2101ad4981e32c051681b8cd456fd8509
        Sources/Shared.swift
        Sources/Other.swift
        Sources/Shared.swift

        Auto-merging Sources/Shared.swift
        CONFLICT (content): Merge conflict in Sources/Shared.swift
        """
        #expect(Worktrees.conflictPaths(in: output) == ["Sources/Shared.swift", "Sources/Other.swift"])
    }

    @Test func rankCountsDistinctPRsAndFiltersByStartWindowRepoAndResolveMove() {
        let jobs = [HotspotsFixture.job(paths: ["a", "a", "b"]), HotspotsFixture.job(paths: ["a"]),
            HotspotsFixture.job(item: "pr-8", paths: ["a"]),
            HotspotsFixture.job(item: "pr-old", paths: ["old"], age: 14 * 86400 + 1),
            HotspotsFixture.job(item: "pr-other", paths: ["other"], repo: "other/repo"),
            HotspotsFixture.job(item: "pr-fix", paths: ["fix"], move: "fix")]
        let ranked = ConflictHotspots.rank(jobs: jobs, repo: "synthetic/project", now: HotspotsFixture.now)
        #expect(ConflictHotspots.window == 14 * 86400)
        #expect(ranked.map(\.path) == ["a", "b"])
        #expect(ranked.map(\.pullRequests) == [2, 1])
    }

    @Test func rankSortsByCountThenPathAndShowsAtMostEight() {
        let jobs = [HotspotsFixture.job(paths: (0..<10).reversed().map { "file-\($0)" }),
            HotspotsFixture.job(item: "pr-8", paths: ["file-9"])]
        let ranked = ConflictHotspots.rank(jobs: jobs, repo: "synthetic/project", now: HotspotsFixture.now)
        #expect(ConflictHotspots.shown == 8)
        #expect(ranked.map(\.path) == ["file-9", "file-0", "file-1", "file-2", "file-3", "file-4", "file-5", "file-6"])
        #expect(ranked.map(\.pullRequests) == [2, 1, 1, 1, 1, 1, 1, 1])
    }

    @Test func summaryUsesSingularAndPluralAndIsAbsentForNoHotspots() {
        #expect(ConflictHotspots.line([(path: "a.swift", pullRequests: 3), (path: "b.swift", pullRequests: 1)])
            == "Conflicts, 14 days: a.swift (3 PRs), b.swift (1 PR)")
        #expect(ConflictHotspots.line([]) == nil)
    }

    @Test func jobConflictsRoundTripAndLegacyRecordWithoutConflictsStillDecodes() throws {
        let job = HotspotsFixture.job()
        let data = try JSONEncoder().encode(job)
        #expect(try JSONDecoder().decode(Job.self, from: data) == job)
        #expect(try JSONDecoder().decode(Job.self, from: data).conflicts == ["Sources/Shared.swift"])
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "conflicts")
        let decoded = try JSONDecoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.conflicts == nil)
        #expect(decoded.key == job.key)
    }
}
