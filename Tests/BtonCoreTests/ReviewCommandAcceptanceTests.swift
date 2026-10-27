@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ReviewCommandAcceptanceTests {
    private let movedHead = "abcdef0123456789abcdef0123456789abcdef01"

    @Test func aReviewWithTheHeadingAndHeadIsPostedAsTheComment() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let review = "## Review: approve (head \(f.pr.headSha.prefix(12)))\nLooks fine."
        let job = try await f.finished(f.start(script: "printf '%s\\n%s' '## Review: approve (head \(f.pr.headSha.prefix(12)))' 'Looks fine.' > \"$BTON_OUT\""))
        #expect(job.status == .succeeded, "\(job.detail ?? "") \(f.log(job.id))")
        #expect(f.posted == review)
        #expect(f.ghCalls.contains("pr comment 7 --repo synthetic/project"))
    }

    @Test func aFirstLineWithoutAHeadingPostsNothingAndFails() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let job = try await f.finished(f.start(script: "echo 'looks fine to me' > \"$BTON_OUT\""))
        #expect(job.status == .failed)
        #expect((job.detail ?? "").contains("review heading"))
        #expect(f.posted.isEmpty)
        #expect(!f.ghCalls.contains("pr comment"))
    }

    @Test func aReviewNamingAnotherHeadPostsNothing() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let job = try await f.finished(f.start(script: "echo '## Review: approve (head \(movedHead.prefix(12)))' > \"$BTON_OUT\""))
        #expect(job.status == .failed)
        #expect(f.posted.isEmpty)
    }

    @Test func exitTwoPostsNothingAndWaitsForTheNextSync() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let job = try await f.finished(f.start(script: "echo 'codex is not installed' >&2; exit 2"))
        #expect(job.status == .failed)
        #expect((job.detail ?? "").hasPrefix("waiting:"))
        #expect(job.retry == true)
        #expect(f.posted.isEmpty)
        #expect(!f.ghCalls.contains("pr comment"))
    }

    @Test func anyOtherExitFailsWithoutRetryAndPostsNothing() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let job = try await f.finished(f.start(script: "echo '## Review: approve (head \(f.pr.headSha.prefix(12)))' > \"$BTON_OUT\"; exit 1"))
        #expect(job.status == .failed)
        #expect(job.retry != true)
        #expect(f.posted.isEmpty)
    }

    @Test func btonOutIsOnlyPassedToReviewCommands() async throws {
        let f = try await ReviewCommandFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let job = try await f.finished(f.start(script: "echo \"${BTON_OUT-unset}\" > \"$MARKER\"", review: false))
        #expect(job.status == .succeeded)
        #expect(try String(contentsOf: f.marker, encoding: .utf8) == "unset\n")
        #expect(!f.ghCalls.contains("pr comment"))
    }

    @Test func aCommandAndAnAgentOnOneMoveInvalidateTheFlow() {
        let data = Data("""
        {"version":1,"base":"main","tier":{"marker":"Tier:","values":["a"],"default":"a"},
         "reviews":{"a":[{"heading":"## Review:"}]},"fixed":"## Fixed:","moves":[],
         "dispatch":{"review":{"agent":"claude","prompt":"x","command":["true"]}}}
        """.utf8)
        guard case let .invalid(message) = Flow.load(data) else { Issue.record("expected invalid"); return }
        #expect(message.contains("dispatch.review"))
    }
}

private struct ReviewCommandFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest
    var root: URL { base.leases.root }
    var marker: URL { root.appendingPathComponent("marker") }
    var posted: String { (try? String(contentsOf: root.appendingPathComponent("posted"), encoding: .utf8)) ?? "" }
    var ghCalls: String { (try? String(contentsOf: root.appendingPathComponent("gh-seen"), encoding: .utf8)) ?? "" }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(120))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(120))
            try #require(head.status == 0)
            let sha = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: sha, headRef: "feature", baseRef: "main", body: "", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            pr.mergeable = true
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            cd "$(dirname "$0")"
            printf '%s\n' "$*" >> gh-seen
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' "$HEAD_SHA"
              exit 0
            fi
            if [ "${1-}" = pr ] && [ "${2-}" = comment ]; then
              while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" posted; shift; done
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\nHEAD_SHA=\(sha)\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            let github = GitHubClient(ghPath: gh.path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), pr: pr)
        } catch { try? FileManager.default.removeItem(at: base.leases.root); throw error }
    }

    func start(script: String, review: Bool = true, environment: [String: String] = [:]) async throws -> UUID {
        let command = ["/bin/sh", "-c", script]
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:"]]], "fixed": "## Fixed:", "moves": [],
            "dispatch": ["review": ["command": command]]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "review", owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "review", head: pr.headSha),
            agent: nil, prompt: nil, command: command, postComment: review, timeout: .seconds(20))
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow, agents: [:],
            environment: environment.merging(["MARKER": marker.path]) { _, new in new })
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start: \(outcome)") }
        return try #require(store.all().first?.id)
    }

    func log(_ id: UUID) -> String { (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? "" }

    func finished(_ id: UUID) async throws -> Job {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline, !store.all().contains(where: { $0.id == id && $0.status != .running }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(store.all().first { $0.id == id && $0.status != .running }, "Job must finish")
    }
}

struct WaitingReviewPauseAcceptanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let key = JobKey(repo: "owner/a", item: "pr-1", move: "review", head: "synthetic-head")

    private func candidate() -> DispatchCandidate {
        let pr = PullRequest(repo: "owner/a", number: 1, title: "t", author: "owner", authorAssociation: "OWNER",
            url: URL(string: "https://example.invalid/pr/1")!, headSha: "synthetic-head", headRef: "h", baseRef: "main",
            body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: now)
        return DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "review", owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: key, agent: "synthetic", prompt: "p", command: nil, postComment: true, timeout: .seconds(60))
    }

    private func waiting(endedMinutesAgo: Double) -> Job {
        var job = Job(id: UUID(), key: key, agent: "synthetic", startedAt: now.addingTimeInterval(-3600), status: .failed)
        job.retry = true
        job.detail = "waiting: codex is unavailable on this Mac (exit 2); it runs again at the next sync"
        job.endedAt = now.addingTimeInterval(-endedMinutesAgo * 60)
        return job
    }

    private func picked(_ job: Job, first: [String] = []) -> Int {
        DispatchPlanner.select([candidate()], jobs: [job], maxAgents: 5,
                               agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])], first: first, now: now).count
    }

    @Test func aWaitingReviewIsNotTriedAgainWithinThirtyMinutes() { #expect(picked(waiting(endedMinutesAgo: 10)) == 0) }
    @Test func aWaitingReviewIsTriedAgainAfterThirtyMinutes() { #expect(picked(waiting(endedMinutesAgo: 31)) == 1) }
    @Test func theOwnersPickSkipsThePause() { #expect(picked(waiting(endedMinutesAgo: 1), first: ["owner/a#pr-1"]) == 1) }
}

struct ChangedFilesPagingAcceptanceTests {
    @Test func aPRPastTheFirstPageGetsItsFullFileListFromRest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        let page = #"{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[{"number":5,"title":"t","url":"https://github.com/o/r/pull/5","isDraft":false,"headRefOid":"abc","headRefName":"h","baseRefName":"main","body":"","updatedAt":"2026-10-01T00:00:00Z","authorAssociation":"MEMBER","mergeable":"MERGEABLE","author":{"login":"a"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]},"files":{"totalCount":150,"nodes":[{"path":"a.ts"}]}}]}}}}"#
        let script = """
        #!/bin/sh
        case "$*" in
          *graphql*) printf '%s' '\(page)' ;;
          *pulls/5/files*) printf 'a.ts\\nb.ts\\nmigrations/1.sql\\n' ;;
          *) exit 1 ;;
        esac
        """
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let result = try await GitHubClient(ghPath: gh.path).openPullRequests(repo: "o/r")
        let pr = try #require(result.pullRequests.first)
        #expect(pr.changedFiles == ["a.ts", "b.ts", "migrations/1.sql"])
        #expect(!pr.changedFilesTruncated)
    }

    @Test func aFailedRestReadKeepsThePRTruncated() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let gh = dir.appendingPathComponent("gh")
        let page = #"{"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[{"number":5,"title":"t","url":"https://github.com/o/r/pull/5","isDraft":false,"headRefOid":"abc","headRefName":"h","baseRefName":"main","body":"","updatedAt":"2026-10-01T00:00:00Z","authorAssociation":"MEMBER","mergeable":"MERGEABLE","author":{"login":"a"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]},"files":{"totalCount":150,"nodes":[{"path":"a.ts"}]}}]}}}}"#
        try "#!/bin/sh\ncase \"$*\" in *graphql*) printf '%s' '\(page)' ;; *) exit 1 ;; esac\n"
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let pr = try #require(try await GitHubClient(ghPath: gh.path).openPullRequests(repo: "o/r").pullRequests.first)
        #expect(pr.changedFilesTruncated)
    }
}
