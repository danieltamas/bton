@testable import BtonCore
import Foundation
import Testing

struct QueueFixesAcceptanceTests {
    @Test func keptPicksPreserveOrderAndDiscardStartedOrUnavailableItems() {
        let picks = ["owner/b#pr-2", "owner/a#pr-1", "owner/a#schedule-3",
                     "owner/b#pr-4", "owner/b#pr-5", "owner/a#pr-6"]
        #expect(Engine.keptPicks(picks,
            started: ["owner/b#pr-4", "owner/a#pr-6"],
            runnable: ["owner/b#pr-2", "owner/b#pr-4"], unread: ["owner/a"])
            == ["owner/b#pr-2", "owner/a#pr-1", "owner/a#schedule-3"])
    }

    @Test func unreadRepoMatchesExactSlugBoundary() {
        #expect(Engine.keptPicks(["owner/ab#pr-1", "owner/a#pr-2"],
            started: [], runnable: [], unread: ["owner/a"]) == ["owner/a#pr-2"])
        #expect(Engine.keptPicks(["owner/a#pr-2"],
            started: [], runnable: [], unread: []).isEmpty)
        #expect(Engine.keptPicks([], started: [], runnable: [], unread: ["owner/a"]).isEmpty)
    }

    @Test func cleanupDueUsesHourlyBoundaryAndPreservesOrder() {
        let now = QueueFixesFixture.now
        let recent = QueueFixesFixture.merged(1)
        let never = QueueFixesFixture.merged(2)
        let exact = QueueFixesFixture.merged(3)
        let older = QueueFixesFixture.merged(4)
        let future = QueueFixesFixture.merged(5)
        let tried = [recent.id: now.addingTimeInterval(-3_599),
                     exact.id: now.addingTimeInterval(-3_600),
                     older.id: now.addingTimeInterval(-3_601),
                     future.id: now.addingTimeInterval(1)]
        #expect(Engine.cleanupDue([recent, never, exact, older, future], tried: tried, now: now)
            .map(\.id) == [never.id, exact.id, older.id])
    }

    @Test func cleanupDueKeysByRepoAndNumberRatherThanHead() {
        let a = QueueFixesFixture.merged(7)
        let b = QueueFixesFixture.merged(7, repo: "owner/b")
        let other = QueueFixesFixture.merged(8)
        #expect(Engine.cleanupDue([a, b, other], tried: [a.id: QueueFixesFixture.now],
            now: QueueFixesFixture.now).map(\.id) == [b.id, other.id])
    }

    @Test func emptyMergedHeadIsNeverDue() {
        let never = QueueFixesFixture.merged(1, head: "")
        let old = QueueFixesFixture.merged(2, head: "")
        #expect(Engine.cleanupDue([never, old],
            tried: [old.id: QueueFixesFixture.now.addingTimeInterval(-3_600)],
            now: QueueFixesFixture.now).isEmpty)
        #expect(Engine.cleanupDue([], tried: [:], now: QueueFixesFixture.now).isEmpty)
    }

    @Test(arguments: [false, true])
    func unreadRepoDoesNotHideReadableRepos(failingRepoFirst: Bool) async throws {
        let snapshot = try await QueueFixesFixture.tick(failB: true, failingRepoFirst: failingRepoFirst)
        #expect(snapshot.openPullRequests.map(\.id) == ["owner/a#1"])
        #expect(snapshot.merged.map(\.id) == ["owner/a#2"])
        #expect(snapshot.openPullRequests.first?.headSha == "synthetic-open")
        #expect(snapshot.merged.first?.headSha == "synthetic-merged")
        let problem = try #require(snapshot.problem)
        #expect(problem.contains("owner/b"))
        #expect(snapshot.jobs.isEmpty)
    }

    @Test func readableReposHaveNoProblem() async throws {
        let snapshot = try await QueueFixesFixture.tick(failB: false)
        #expect(Set(snapshot.openPullRequests.map(\.id)) == ["owner/a#1", "owner/b#1"])
        #expect(Set(snapshot.merged.map(\.id)) == ["owner/a#2", "owner/b#2"])
        #expect(snapshot.problem == nil)
        #expect(snapshot.jobs.isEmpty)
    }
}

private enum QueueFixesFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func merged(_ number: Int, repo: String = "owner/a", head: String = "synthetic-head") -> MergedPullRequest {
        MergedPullRequest(repo: repo, number: number, title: "Synthetic", author: "owner",
            url: URL(string: "https://example.invalid/pr/\(number)")!, mergedAt: now,
            totalCost: nil, headRef: "feat/x", headSha: head)
    }

    static func tick(failB: Bool, failingRepoFirst: Bool = false) async throws -> Engine.Snapshot {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-queue-fixes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path])
        let repos = failingRepoFirst ? ["owner/b", "owner/a"] : ["owner/a", "owner/b"]
        let config = BtonConfig(repos: repos.map { WatchedRepo(slug: $0, path: nil) },
            pollSeconds: 60, maxAgents: 0, agents: [:], schedules: [])
        try config.save(to: home.configURL)
        let gh = root.appendingPathComponent("gh")
        // Match each repo-bearing argv form; an unexpected invocation fails locally.
        let script = """
        #!/bin/sh
        repo=
        for arg in "$@"; do
            case "$arg" in
                repos/owner/a/*|owner/a|name=a) repo=owner/a ;;
                repos/owner/b/*|owner/b|name=b) repo=owner/b ;;
            esac
        done
        if [ "\(failB ? "yes" : "no")" = yes ] && [ "$repo" = owner/b ]; then
            echo 'Synthetic read failure for owner/b' >&2
            exit 1
        fi
        case "$repo" in owner/a|owner/b) ;; *) exit 90 ;; esac
        case "$1:$2" in
            api:repos/*/contents/.bton/flow.json)
                echo 'HTTP 404: synthetic absent flow' >&2
                exit 1
                ;;
            api:graphql)
                cat <<'JSON'
        {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":1,"title":"Synthetic open","url":"https://example.invalid/pr/1","isDraft":false,"headRefOid":"synthetic-open","headRefName":"feat/x","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}
        JSON
                ;;
            pr:list)
                cat <<'JSON'
        [{"number":2,"title":"Synthetic merged","author":{"login":"owner"},"url":"https://example.invalid/pr/2","mergedAt":"2026-10-19T12:00:00Z","headRefName":"feat/merged","headRefOid":"synthetic-merged"}]
        JSON
                ;;
            *) echo 'Unexpected synthetic gh invocation' >&2; exit 91 ;;
        esac
        """
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let engine = try Engine(home: home, github: GitHubClient(ghPath: gh.path), log: { _ in })
        return await engine.tick(dispatching: false)
    }
}
