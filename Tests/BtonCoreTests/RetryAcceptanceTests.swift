@testable import BtonCore
import Foundation
import Testing

private enum RetryFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let key = JobKey(repo: "synthetic/project", item: "pr-7", move: "merge", head: "same-head")

    static func job(_ key: JobKey = RetryFixture.key, status: Job.Status = .failed,
                    offset: TimeInterval = 0, retry: Bool? = nil) -> Job {
        Job(id: UUID(), key: key, agent: "synthetic", startedAt: now.addingTimeInterval(offset),
            endedAt: status == .running ? nil : now.addingTimeInterval(offset + 1),
            status: status, detail: "Synthetic outcome", retry: retry)
    }

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-retry-\(UUID())")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func store(_ root: URL) throws -> JobStore {
        try JobStore(home: BtonHome(environment: ["BTON_HOME": root.path]))
    }

    static func candidate() -> DispatchCandidate {
        let pr = PullRequest(repo: key.repo, number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: key.head, headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: now)
        return DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: key.move, owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: key, agent: "synthetic", prompt: "Synthetic", command: nil,
            postComment: false, timeout: .seconds(60))
    }

    static func select(_ jobs: [Job], max: Int = 2) -> [JobKey] {
        DispatchPlanner.select([candidate()], jobs: jobs, maxAgents: max,
            agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]).map(\.key)
    }
}

@Suite(ProcessBound())
struct RetryAcceptanceTests {
    @Test func legacyJobDecodesWithoutRetryAndInitializerDefaultsToNil() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111",
         "key":{"repo":"synthetic/project","item":"pr-7","move":"merge","head":"same-head"},
         "startedAt":100,"status":"failed","usage":{}}
        """
        #expect(try JSONDecoder().decode(Job.self, from: Data(json.utf8)).retry == nil)
        #expect(RetryFixture.job().retry == nil)
    }

    @Test(arguments: [true, false])
    func retryUsesLiteralCodableKeyAndRoundTrips(retry: Bool) throws {
        let job = RetryFixture.job(retry: retry)
        let data = try JSONEncoder().encode(job)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["retry"] as? Bool == retry)
        #expect(try JSONDecoder().decode(Job.self, from: data) == job)
    }

    @Test(arguments: [Job.Status.failed, .cancelled])
    func requestRetryPersistsLatestFailedOrCancelledPR(status: Job.Status) throws {
        let root = try RetryFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RetryFixture.store(root)
        let job = RetryFixture.job(status: status)
        try store.save(job)
        #expect(try store.requestRetry(job.id))
        var expected = job
        expected.retry = true
        #expect(try RetryFixture.store(root).all() == [expected])
    }

    @Test(arguments: ["running", "succeeded", "schedule", "issue", "unknown", "superseded"])
    func rejectedRetryChangesNothing(reason: String) throws {
        let root = try RetryFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RetryFixture.store(root)
        let item = reason == "schedule" ? "schedule-7" : reason == "issue" ? "issue-7" : "pr-7"
        let key = JobKey(repo: RetryFixture.key.repo, item: item, move: "merge", head: "same-head")
        let status: Job.Status = reason == "running" ? .running : reason == "succeeded" ? .succeeded : .failed
        let job = RetryFixture.job(key, status: status, retry: false)
        try store.save(job)
        if reason == "superseded" { try store.save(RetryFixture.job(key, offset: 10)) }
        let before = store.all()
        let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("jobs"),
                                                               includingPropertiesForKeys: nil)
        let bytes = try files.map { try Data(contentsOf: $0) }
        #expect(try !store.requestRetry(reason == "unknown" ? UUID() : job.id))
        #expect(try RetryFixture.store(root).all() == before)
        #expect(try files.map { try Data(contentsOf: $0) } == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).count == files.count)
    }

    @Test func newerDifferentKeyAndEqualTimestampDoNotSupersedeRetry() throws {
        let root = try RetryFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try RetryFixture.store(root)
        let job = RetryFixture.job()
        try store.save(job)
        try store.save(RetryFixture.job(offset: 0))
        for key in [JobKey(repo: "other/project", item: "pr-7", move: "merge", head: "same-head"),
                    JobKey(repo: RetryFixture.key.repo, item: "pr-8", move: "merge", head: "same-head"),
                    JobKey(repo: RetryFixture.key.repo, item: "pr-7", move: "review", head: "same-head"),
                    JobKey(repo: RetryFixture.key.repo, item: "pr-7", move: "merge", head: "new-head")] {
            try store.save(RetryFixture.job(key, offset: 10))
        }
        #expect(try store.requestRetry(job.id))
        #expect(store.all().first { $0.id == job.id }?.retry == true)
    }

    @Test func onlyUnanimouslyRetriedHistoryIsSelectableAndReportedAsRetry() {
        let failed = RetryFixture.job(retry: true)
        let cancelled = RetryFixture.job(status: .cancelled, offset: 10, retry: true)
        #expect(RetryFixture.select([failed, cancelled]) == [RetryFixture.key])
        #expect(DispatchPlanner.isRetry(RetryFixture.key, jobs: [failed, cancelled]))
        #expect(!DispatchPlanner.isRetry(RetryFixture.key, jobs: []))
        let other = JobKey(repo: "other/project", item: "pr-7", move: "merge", head: "same-head")
        #expect(!DispatchPlanner.isRetry(other, jobs: [failed]))
        #expect(DispatchPlanner.isRetry(RetryFixture.key, jobs: [failed, RetryFixture.job(other)]))
        for retry: Bool? in [nil, false] {
            let newer = RetryFixture.job(offset: 20, retry: retry)
            for jobs in [[failed, newer], [newer, failed], [newer]] {
                #expect(RetryFixture.select(jobs).isEmpty)
                #expect(!DispatchPlanner.isRetry(RetryFixture.key, jobs: jobs))
            }
        }
    }

    @Test func retryStillRespectsCapacityAndBusyItem() {
        let retry = RetryFixture.job(retry: true)
        #expect(RetryFixture.select([retry], max: 0).isEmpty)
        let unrelated = JobKey(repo: "other/project", item: "pr-9", move: "review", head: "other")
        let running = RetryFixture.job(unrelated, status: .running)
        #expect(RetryFixture.select([retry, running], max: 1).isEmpty)
        #expect(RetryFixture.select([retry, running], max: 2) == [RetryFixture.key])
        let sameItem = JobKey(repo: RetryFixture.key.repo, item: "pr-7", move: "review", head: "other")
        #expect(RetryFixture.select([retry, RetryFixture.job(sameItem, status: .running)]).isEmpty)
        #expect(RetryFixture.select([RetryFixture.job(status: .running, retry: true)]).isEmpty)
    }

    @Test(arguments: ["current", "done"])
    func rerunClaimsFreePreviouslyRunLeaseAndPreservesHistory(location: String) async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try fixture.store("a")
        let b = try fixture.store("b")
        let first = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: "earlier"))
        try await a.release(first)
        let second = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: "latest"))
        try await a.release(second)
        let key = location == "current" ? "latest" : "earlier"
        let before = try await b.state(of: fixture.item, in: fixture.repo)
        let ordinary = try await b.claim(fixture.item, in: fixture.repo, key: key)
        if case .claimed = ordinary { Issue.record("Default claim must refuse a previously run key") }
        #expect(try await b.state(of: fixture.item, in: fixture.repo) == before)
        let explicit = try await b.claim(fixture.item, in: fixture.repo, key: key, rerun: false)
        if case .claimed = explicit { Issue.record("rerun false must refuse a previously run key") }
        let job = UUID()
        let retried = try RetryLeaseFixture.claimed(await b.claim(fixture.item, in: fixture.repo,
                                                               job: job, key: key, rerun: true))
        #expect(retried.record.job == job)
        #expect(retried.record.key == key)
        #expect(retried.record.done == ["earlier", "latest"])
        #expect(!retried.record.released)
        #expect(retried.record.hasRun("earlier"))
        #expect(retried.record.hasRun("latest"))
    }

    @Test func rerunCannotStealLiveLease() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try fixture.store("a")
        let b = try fixture.store("b")
        let lease = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: "same"))
        let result = try await b.claim(fixture.item, in: fixture.repo, job: UUID(), key: "same", rerun: true)
        guard case let .notClaimed(holder) = result else {
            Issue.record("Retry must not steal a live lease")
            return
        }
        #expect(holder == lease.record)
        #expect(try await b.state(of: fixture.item, in: fixture.repo) == .held(lease.record))
    }
}

struct RetryLeaseFixture {
    let root: URL
    let repo = "synthetic/project"
    let item: LeaseItem

    private static let seed = Task { try await makeTemplate() }

    static func make(template: Bool = false) async throws -> Self {
        let seed = try await seed.value
        return Self(root: try GitFixtureCopies.copy(seed.root, template: template), item: seed.item)
    }

    private static func makeTemplate() async throws -> Self {
        let root = GitFixtureCopies.templates.appendingPathComponent("leases-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let result = try await ProcessRunner().run("/usr/bin/git",
                ["init", "--bare", "--initial-branch=main", root.appendingPathComponent("origin.git").path],
                environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
            try #require(result.status == 0, "git init: \(result.stderr)")
            // A synthetic gh reads the real local Git ref and commit, with no network or credentials.
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            case "$2" in
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else
                  echo 'HTTP 404' >&2; exit 1
                fi ;;
              repos/synthetic/project/git/commits/*)
                sha="${2##*/}"
                message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "$sha")
                message=${message//\\/\\\\}
                message=${message//\"/\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """#
            let gh = root.appendingPathComponent("gh")
            try Data(script.utf8).write(to: gh)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            return Self(root: root, item: try #require(LeaseItem("pr-7")))
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func store(_ name: String) throws -> LeaseStore {
        let remote = root.appendingPathComponent("origin.git").path
        return try LeaseStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(name).path]),
            holder: name, host: "synthetic-host", github: GitHubClient(ghPath: root.appendingPathComponent("gh").path),
            remoteURL: { _ in remote })
    }

    static func claimed(_ result: ClaimResult) throws -> Lease {
        guard case let .claimed(lease) = result else {
            Issue.record("Synthetic fixture claim must succeed")
            throw LeaseError.failed("Synthetic fixture claim failed")
        }
        return lease
    }
}
