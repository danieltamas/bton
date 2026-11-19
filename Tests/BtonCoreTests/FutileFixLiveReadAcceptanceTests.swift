@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FutileFixLiveReadAcceptanceTests {
    @Test func listReadAfterSyncUnlocksRetry() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.assertPR7(await engine.tick(dispatching: false), commentOffsets: [])
        try f.answer(pr7: [1])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [1])
        #expect(try await engine.retry(f.job.id))
        #expect(try f.storedJob().retry == true)
    }

    @Test func listReadAfterSyncUnlocksRunNow() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.assertPR7(await engine.tick(dispatching: false), commentOffsets: [])
        try f.answer(pr7: [1])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [1])
        try await engine.runNow(f.job.key)
        #expect(try f.storedJob().retry == true)
    }

    @Test func listReadAloneUnlocksRetry() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.answer(pr7: [1])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [1])
        #expect(try await engine.retry(f.job.id))
        #expect(try f.storedJob().retry == true)
    }

    @Test func readsWithoutCommentsRefuseRetryAndRunNow() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.assertPR7(await engine.tick(dispatching: false), commentOffsets: [])
        try f.answer(pr7: [])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [])
        #expect(try await !engine.retry(f.job.id))
        #expect(try f.storedJob().retry != true)
        try await engine.runNow(f.job.key)
        #expect(try f.storedJob().retry != true)
    }

    @Test func laterListReadAndSyncDoNotForgetNewerComment() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.answer(pr7: [1])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [1])
        try f.answer(pr7: [])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [])
        try f.assertPR7(await engine.tick(dispatching: false), commentOffsets: [])
        #expect(try await engine.retry(f.job.id))
        #expect(try f.storedJob().retry == true)
    }

    @Test(arguments: [0.0, -1.0])
    func commentAtOrBeforeJobEndDoesNotUnlockRetry(offset: Double) async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.answer(pr7: [offset])
        try f.assertPR7(try #require(await engine.readLists()), commentOffsets: [offset])
        #expect(try await !engine.retry(f.job.id))
        #expect(try f.storedJob().retry != true)
    }

    @Test func anotherPRCommentDoesNotUnlockRetry() async throws {
        let f = try await FutileLiveReadFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.answer(pr7: [], pr8: [1])
        let snapshot = try #require(await engine.readLists())
        try f.assertPR7(snapshot, commentOffsets: [])
        let other = try #require(snapshot.openPullRequests.first { $0.repo == "synthetic/project" && $0.number == 8 })
        #expect(other.comments.map(\.createdAt) == [FutileLiveReadFixture.time.addingTimeInterval(1)])
        #expect(try await !engine.retry(f.job.id))
        #expect(try f.storedJob().retry != true)
    }
}

private struct FutileLiveReadFixture {
    static let time = Date(timeIntervalSince1970: 1_700_000_000)
    let root: URL
    let head: String
    let job: Job
    var home: BtonHome { BtonHome(environment: ["BTON_HOME": file("home").path]) }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: { _ in })
    }

    func storedJob() throws -> Job {
        let store = try JobStore(home: home)
        return try #require(store.all().first { $0.id == job.id })
    }

    func assertPR7(_ snapshot: Engine.Snapshot, commentOffsets: [Double]) throws {
        #expect(snapshot.problem == nil)
        let pr = try #require(snapshot.openPullRequests.first { $0.repo == "synthetic/project" && $0.number == 7 })
        #expect(pr.headSha == head)
        #expect(pr.comments.map(\.createdAt) == commentOffsets.map { Self.time.addingTimeInterval($0) })
        #expect(pr.comments.map(\.body) == commentOffsets.map { _ in "New information" })
    }

    // Each read consumes this file's current contents, independent of call count.
    func answer(pr7: [Double], pr8: [Double]? = nil) throws {
        func node(_ number: Int, _ offsets: [Double]) -> [String: Any] {
            let comments: [[String: Any]] = offsets.map {
                ["author": ["login": "someone-else"], "authorAssociation": "MEMBER",
                 "body": "New information", "createdAt": ISO8601DateFormatter().string(from: Self.time.addingTimeInterval($0))]
            }
            return ["number": number, "title": "Synthetic", "url": "https://example.invalid/pr/\(number)",
                "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
                "body": "", "updatedAt": "2023-11-14T22:13:21Z", "mergeable": "MERGEABLE",
                "authorAssociation": "OWNER", "author": ["login": "owner"],
                "labels": ["nodes": []], "assignees": ["nodes": []], "comments": ["nodes": comments]]
        }
        var nodes = [node(7, pr7)]
        if let pr8 { nodes.append(node(8, pr8)) }
        let response: [String: Any] = ["data": ["viewer": ["login": "owner"], "repository": [
            "defaultBranchRef": ["name": "main"], "pullRequests": [
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": nodes]]]]
        try JSONSerialization.data(withJSONObject: response).write(to: file("answer.json"), options: .atomic)
    }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("futile-live-read-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let remote = root.appendingPathComponent("origin.git").path
            let clone = root.appendingPathComponent("clone").path
            for args in [["init", "--bare", "--initial-branch=main", remote], ["clone", remote, clone],
                         ["-C", clone, "commit", "--allow-empty", "-m", "Synthetic"],
                         ["-C", clone, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"]] {
                _ = try await git(args)
            }
            let head = try await git(["-C", clone, "rev-parse", "HEAD"])
            var job = Job(id: UUID(), key: JobKey(repo: "synthetic/project", item: "pr-7", move: "fix", head: head),
                agent: "synthetic", startedAt: time.addingTimeInterval(-1), endedAt: time, status: .failed,
                detail: "no push can clear the review: the review waits for the other developer's approval")
            job.pushes = true
            let f = Self(root: root, head: head, job: job)
            try f.home.prepare()
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": [String: String](), "fixed": "## Fixed:",
                "moves": [["move": "fix", "when": ["no_review_or_response_newer"], "who": "author"]],
                "dispatch": ["fix": ["agent": "synthetic", "prompt": "Synthetic task"]]]
            try JSONSerialization.data(withJSONObject: flow).write(to: f.file("flow"))
            var watched = WatchedRepo(slug: "synthetic/project", path: clone)
            watched.startMoves = false
            watched.environment = [:]
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 2,
                agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])], schedules: []).save(to: f.home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: f.home)
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
            git() { /usr/bin/git -c user.name=Synthetic -c user.email=synthetic@example.invalid -c commit.gpgsign=false "$@"; }
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' 'HEAD_VALUE'; exit 0
            fi
            if [ "${1-}" != api ]; then
              if [ "${2-}" = list ]; then echo '[]'; fi
              exit 0
            fi
            case "$2" in
              repos/synthetic/project/contents/.bton/flow.json) cat flow ;;
              graphql) cat answer.json ;;
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else echo 'HTTP 404' >&2; exit 1; fi ;;
              repos/synthetic/project/git/commits/*)
                message=$(git --git-dir=origin.git show -s --format=%s "${2##*/}")
                message=${message//\\/\\\\}
                message=${message//\"/\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """#.replacingOccurrences(of: "HEAD_VALUE", with: head)
            try script.write(to: f.file("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.file("gh").path)
            try f.answer(pr7: [])
            try JobStore(home: f.home).save(job)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    private static func git(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git",
            ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "-c", "commit.gpgsign=false"] + arguments,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(30))
        try #require(result.status == 0, "Local git setup: \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
