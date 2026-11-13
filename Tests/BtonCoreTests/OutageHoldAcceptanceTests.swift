@testable import BtonCore
import Darwin
import Foundation
import Testing

@Suite(ProcessBound())
struct OutageHoldAcceptanceTests {
    typealias F = IntakeAcceptanceFixture

    @Test func judgedHoldLogsOnlyItsStartAndLift() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let engine = try f.engine()
        let known: Set<String> = [F.repo]
        #expect(await engine.settleOutages([:], judged: known, known: known).isEmpty)
        #expect(try f.logs().isEmpty)
        for _ in 0..<2 {
            #expect(await engine.settleOutages([F.repo: "service unavailable"], judged: known, known: known)
                == [F.repo: "service unavailable"])
        }
        let started = try f.logs()
        #expect(started.count == 1)
        #expect(started.first?.contains(F.repo) == true)
        #expect(started.first?.contains("service unavailable") == true)
        // A different failed service updates the reason without starting another hold.
        #expect(await engine.settleOutages([F.repo: "another service unavailable"], judged: known, known: known)
            == [F.repo: "another service unavailable"])
        #expect(try f.logs() == started)
        for _ in 0..<2 {
            #expect(await engine.settleOutages([:], judged: known, known: known).isEmpty)
        }
        let lifted = try f.logs()
        #expect(lifted.count == 2)
        #expect(lifted.last?.contains(F.repo) == true)
        #expect(lifted.last?.contains("lift") == true)
        #expect(await engine.outages.isEmpty)
    }

    @Test func unjudgedRepoKeepsItsLastHoldUntilItLeavesKnown() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let engine = try f.engine()
        let other = "synthetic/other"
        let known: Set<String> = [F.repo, other]
        let holds = [F.repo: "database unavailable", other: "cache unavailable"]
        #expect(await engine.settleOutages(holds, judged: known, known: known) == holds)
        let started = try f.logs()
        #expect(started.count == 2)
        // No judgement is not a successful probe, even if now contains a different reason.
        #expect(await engine.settleOutages([F.repo: "unjudged replacement"], judged: [], known: known) == holds)
        #expect(try f.logs() == started)
        #expect(await engine.settleOutages([:], judged: [other], known: known) == [F.repo: holds[F.repo]!])
        let afterOtherLifted = try f.logs()
        #expect(afterOtherLifted.count == 3)
        #expect(afterOtherLifted.last?.contains(other) == true)
        #expect(await engine.settleOutages([:], judged: [], known: [other]).isEmpty)
        #expect(await engine.outages.isEmpty)
        #expect(try f.logs() == afterOtherLifted)
    }

    @Test func holdKeepsTextCandidatesAndEarlierReposWithTheirQueuePlaces() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let engine = try f.engine()
        let earlier = f.candidate(item: "pr-1", repo: "synthetic/other")
        let code = f.candidate(item: "pr-7")
        var text = f.candidate(item: "issue-8", move: "draft")
        text.textOnly = true
        var pending = [earlier, code, text].map { (candidate: $0, clone: f.root, flow: Optional<Flow>.none) }
        for candidate in [earlier, code, text] {
            await engine.runNext(repo: candidate.key.repo, item: candidate.key.item)
        }
        let before = await engine.next
        await engine.holdPending(f.watched, hold: f.hold, me: "me", pending: &pending, from: 1)
        #expect(pending.map(\.candidate.key) == [earlier.key, text.key])
        #expect(await engine.next == before)
        #expect(await engine.deferred == [Engine.pick(repo: F.repo, item: code.key.item): f.hold])
        #expect(try f.calls().isEmpty)
    }

    @Test func heldResumePostsLatestJobsNoticeOnceEvenWithStaleComments() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let older = F.job(retry: true, time: 100)
        let latest = F.job(retry: true, time: 200, repo: F.repo.uppercased())
        let unrelated = [F.job(8, time: 300), F.job(time: 400, repo: "other/repo"), F.job(time: 500, move: "draft")]
        for job in [latest, older] + unrelated { try f.store.save(job) }
        let candidate = try f.resume(jobs: [latest, older])
        let engine = try f.engine()
        // The fake keeps returning no comments, as GitHub can before the post is visible.
        for _ in 0..<2 { await f.applyHold(engine, candidates: [candidate, candidate]) }
        #expect(try f.calls().filter { $0.hasPrefix("comment ") } == ["comment 7"])
        #expect(try f.posted() == IssueIntake.heldComment(login: "me", job: latest.id))
        #expect(BtonMarker.keys(in: try f.posted()) == ["implement-held \(latest.id.uuidString)"])
        #expect(!BtonMarker.keys(in: try f.posted()).contains("implement-held \(older.id.uuidString)"))
        #expect(try f.store.all().count == 5)
        let nextBuild = F.job(retry: true, time: 600)
        try f.store.save(nextBuild)
        await f.applyHold(engine, candidates: [try f.resume(jobs: [latest, older, nextBuild])])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.count == 2)
        #expect(BtonMarker.keys(in: try f.posted()) == ["implement-held \(nextBuild.id.uuidString)"])
    }

    @Test(arguments: ["mE", "teammate", "older job", "unmarked"])
    func onlyMyExactLatestJobMarkerSuppressesThePost(existing: String) async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let latest = F.job(retry: true)
        try f.store.save(latest)
        let marker = "implement-held \((existing == "older job" ? UUID() : latest.id).uuidString)"
        try f.comments(author: existing == "teammate" ? "teammate" : "mE",
            body: existing == "unmarked" ? marker : BtonMarker.line(marker))
        let candidate = try f.resume(jobs: [latest])
        // A new Engine has no in-memory notice history: the issue is the restart boundary.
        for _ in 0..<2 {
            let engine = try f.engine()
            await f.applyHold(engine, candidates: [candidate])
        }
        let posts = try f.calls().filter { $0.hasPrefix("comment ") }
        #expect(posts.count == (existing == "mE" ? 0 : 2))
    }

    @Test func failedPostIsRetriedOnTheNextHeldTurn() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let job = F.job(retry: true)
        try f.store.save(job)
        let candidate = try f.resume(jobs: [job])
        let engine = try f.engine()
        try Data().write(to: f.file("fail-post"))
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.count == 1)
        try FileManager.default.removeItem(at: f.file("fail-post"))
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.count == 2)
        #expect(try f.posted() == IssueIntake.heldComment(login: "me", job: job.id))
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.count == 2)
    }

    @Test(arguments: [("CLOSED", ["me"], "in-progress"), ("OPEN", ["teammate"], "in-progress"), ("OPEN", ["me"], "ready")])
    func anIssueNoLongerMineInProgressGetsNoNotice(state: String, assignees: [String], stage: String) async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let job = F.job(retry: true)
        try f.store.save(job)
        try f.live(state: state, assignees: assignees, stage: stage)
        let engine = try f.engine()
        await f.applyHold(engine, candidates: [try f.resume(jobs: [job])])
        #expect(try f.calls().filter { $0.hasPrefix("live ") }.count == 1)
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.isEmpty)
    }

    @Test func aBuildAnotherProcessAlreadyStartedGetsNoNotice() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let waiting = F.job(retry: true, time: 100)
        try f.store.save(waiting)
        let candidate = try f.resume(jobs: [waiting])
        try f.store.save(F.job(status: .running, retry: true, time: 200))
        let engine = try f.engine()
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") }.isEmpty)
    }

    @Test func anotherProcessHoldingTheBuildsNoticeLockLeavesItForTheNextTick() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let job = F.job(retry: true)
        try f.store.save(job)
        let candidate = try f.resume(jobs: [job])
        let engine = try f.engine()
        let locks = f.home.url.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let other = try #require(LocalLock(locks.appendingPathComponent("held-\(job.id.uuidString).lock")))
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().isEmpty)
        other.release()
        await f.applyHold(engine, candidates: [candidate])
        #expect(try f.calls().filter { $0.hasPrefix("comment ") } == ["comment 7"])
    }

    @Test func candidatesOtherThanClaimedImplementResumesPostNothing() async throws {
        let f = try OutageNoticeFixture()
        defer { f.remove() }
        let job = F.job(retry: true)
        try f.store.save(job)
        let fresh = try #require(try F.candidate())
        #expect(try !F.plan(fresh).resumes)
        var wrongMove = f.candidate(item: "issue-7", move: "draft")
        wrongMove.target = try f.resume(jobs: [job]).target
        let branchImplement = f.candidate(item: "issue-7", move: "implement")
        let noJob = try #require(try F.candidate([F.issue(8, assignees: ["me"])], jobs: [F.job(8, retry: true)]))
        var textResume = try f.resume(jobs: [job])
        textResume.textOnly = true
        let engine = try f.engine()
        await f.applyHold(engine, candidates: [fresh, wrongMove, branchImplement, noJob, textResume])
        #expect(try f.calls().isEmpty)
    }

    @Test func heldCommentIsPrivateAndIsNeitherANewRoundNorAnAsk() throws {
        let job = UUID()
        let body = IssueIntake.heldComment(login: "me", job: job)
        #expect(BtonMarker.keys(in: body) == ["implement-held \(job.uuidString)"])
        for privateValue in ["127.0.0.1", "localhost", "55439", "DATABASE_URL", "REDIS_URL", "://", "probe-secret"] {
            #expect(!body.contains(privateValue))
        }
        // Exclude the UUID marker before looking for arbitrary address/variable syntax.
        let prose = body.components(separatedBy: "<!--").first ?? body
        #expect(prose.range(of: #"\b[A-Z][A-Z0-9]*_[A-Z0-9_]+\b|\b\d{1,3}(?:\.\d{1,3}){3}\b|:\d{2,5}\b|\b[\w-]+\.(?:local|internal|com|net|invalid)\b"#,
            options: .regularExpression) == nil)
        #expect(IssueAsks.isNotice(body))
        let addressed = "@me, " + body
        #expect(IssueAsks.mentions(addressed, login: "me"))
        let notice = IssueAskFixture.comment(body: addressed, second: 20)
        #expect(IssueIntake.round(of: F.issue(comments: [notice])) == "")
        let human = IssueAskFixture.comment("22", body: "Please continue", second: 10)
        #expect(IssueIntake.round(of: F.issue(comments: [notice, human])) == String(Int(human.createdAt.timeIntervalSince1970)))
        #expect(IssueAsks.ask(in: IssueAskFixture.issue(body: "No question", comments: [notice]), me: "me") == nil)
        let question = IssueAskFixture.comment("23", body: "@me which option?", second: 1)
        let myNotice = IssueAskFixture.comment("24", author: "me", body: addressed, second: 20)
        #expect(try #require(IssueAsks.ask(in: IssueAskFixture.issue(body: "No question", comments: [question, myNotice]),
            me: "me")).commentID == "23")
    }

    @Test func downServiceBlocksAutomaticTakeAndCodeButTextStillRuns() async throws {
        let socket = try OutageHoldSocket()
        defer { socket.close() }
        let f = try await OutageTickFixture.make(port: socket.port)
        defer { f.base.remove() }
        let engine = try f.base.engine()
        await engine.runNext(repo: f.base.repo, item: "pr-8")
        let held = await engine.tick()
        #expect(held.problem == nil)
        let reason = try #require(held.outages[f.base.repo])
        #expect(held.jobs.isEmpty)
        #expect(await engine.autoTaken.isEmpty)
        #expect(try f.assignments().isEmpty)
        #expect(held.waiting[Engine.pick(repo: f.base.repo, item: "pr-8")] == reason)
        let flow = try #require(held.flows[f.base.repo]?.flow)
        #expect(Engine.autoTakeable(held.openPullRequests, flow: flow, me: "owner", repo: f.base.repo, tried: [])
            .map(\.number) == [7])
        #expect(DispatchPlanner.candidates(held.openPullRequests, flow: flow, me: "owner", repo: f.base.repo)
            .contains { $0.key.item == "pr-8" && !$0.textOnly })
        // A pressed Take it is refused the same way, before anything is written.
        do {
            _ = try await engine.take(repo: f.base.repo, number: 7, from: "teammate")
            Issue.record("Expected TakeError.held")
        } catch let error as TakeError {
            #expect(error == .held(reason))
        }
        #expect(try f.assignments().isEmpty)
        // A service found down by the take itself (it fell after the sync's probe) is handed back as the
        // sync's hold, and the PR stays untried, so it is taken once the service is back.
        let taking = try #require(held.flows[f.base.repo]?.flow)
        #expect(await engine.autoTake(held.openPullRequests, flow: taking, repo: f.base.repo, me: "owner") == reason)
        #expect(await engine.autoTaken.isEmpty)
        let ask = try #require(held.issueAsks.first { $0.number == 9 })
        await engine.requestDraft(ask)
        let drafting = await engine.tick()
        #expect(drafting.problem == nil)
        #expect(drafting.outages[f.base.repo] == reason)
        #expect(drafting.jobs.map(\.key) == [IssueDrafts.key(for: ask)])
        #expect(await engine.autoTaken.isEmpty)
        #expect(try f.assignments().isEmpty)
        try await f.base.waitForJobs()
        #expect(try String(contentsOf: f.base.root.appendingPathComponent("text-ran"), encoding: .utf8) == "yes")
        let store = try JobStore(home: f.base.home)
        #expect(store.all().first { $0.key == IssueDrafts.key(for: ask) }?.status == .succeeded)
        // Recovery uses the same environment and Engine. Zero slots isolates automatic Take it.
        try socket.listen()
        var config = try BtonConfig.loadOrCreate(home: f.base.home)
        config.maxAgents = 0
        try config.save(to: f.base.home.configURL)
        let recovered = await engine.tick()
        #expect(recovered.problem == nil)
        #expect(recovered.outages.isEmpty)
        #expect(await engine.autoTaken.count == 1)
        #expect(try f.assignments().count == 1)
    }
}

private struct OutageNoticeFixture {
    let root: URL
    let home: BtonHome
    let hold = "DATABASE_URL at 127.0.0.1:55439 does not answer"
    var watched: WatchedRepo { WatchedRepo(slug: IntakeAcceptanceFixture.repo, path: root.path) }
    var store: JobStore { get throws { try JobStore(home: home) } }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("outage-notice-\(UUID())")
        home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try home.prepare()
        try Data().write(to: file("calls"))
        try Data("{\"comments\":[]}".utf8).write(to: file("comments"))
        try live(state: "OPEN", assignees: ["me"], stage: "in-progress")
        try """
        #!/bin/sh
        set -eu
        cd "${0%/*}"
        case "$1 $2" in
          'issue view')
            case "$*" in
              *state,labels,assignees*) printf 'live %s\\n' "$3" >> calls; cat live ;;
              *) printf 'view %s\\n' "$3" >> calls; cat comments ;;
            esac ;;
          'issue comment')
            printf 'comment %s\\n' "$3" >> calls
            cat > posted
            if [ -f fail-post ]; then echo 'comment unavailable' >&2; exit 17; fi ;;
          *) echo 'unexpected gh invocation' >&2; exit 97 ;;
        esac
        """.write(to: file("gh"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file("gh").path)
    }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    /// The issue as the live read before a post finds it.
    func live(state: String, assignees: [String], stage: String) throws {
        let row: [String: Any] = ["state": state, "labels": [["name": "stage:\(stage)"]],
                                  "assignees": assignees.map { ["login": $0] }]
        try JSONSerialization.data(withJSONObject: row).write(to: file("live"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: EngineLog.sink(home: home))
    }
    func calls() throws -> [String] { try String(contentsOf: file("calls"), encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty } }
    func posted() throws -> String { try String(contentsOf: file("posted"), encoding: .utf8) }
    func logs() throws -> [String] {
        guard FileManager.default.fileExists(atPath: EngineLog.url(home: home).path) else { return [] }
        return try String(contentsOf: EngineLog.url(home: home), encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }
    func comments(author: String, body: String) throws {
        try JSONSerialization.data(withJSONObject: ["comments": [["id": "IC_hold", "author": ["login": author],
            "body": body, "createdAt": "2026-11-13T10:00:00Z", "url": NSNull()]]]).write(to: file("comments"))
    }
    func resume(jobs: [Job]) throws -> DispatchCandidate {
        try #require(try IntakeAcceptanceFixture.candidate([
            IntakeAcceptanceFixture.issue(labels: ["stage:in-progress"], assignees: ["me"])
        ], jobs: jobs))
    }
    func candidate(item: String, move: String = "review", repo: String = IntakeAcceptanceFixture.repo) -> DispatchCandidate {
        DispatchCandidate(target: .branch("main"),
            move: Move(name: move, owner: "me", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: repo, item: item, move: move, head: "head"), agent: "claude", prompt: "Work",
            command: nil, postComment: false, timeout: .seconds(30))
    }
    func applyHold(_ engine: Engine, candidates: [DispatchCandidate]) async {
        var pending = candidates.map { (candidate: $0, clone: root, flow: Optional<Flow>.none) }
        await engine.holdPending(watched, hold: hold, me: "me", pending: &pending, from: 0)
    }
}

private struct OutageTickFixture {
    let base: StartMovesFixture
    static func make(port: Int) async throws -> Self {
        let base = try await StartMovesFixture.make(startMoves: true, maxAgents: 4)
        do {
            let root = base.root
            let clone = root.appendingPathComponent("clone")
            for args in [["clone", root.appendingPathComponent("origin.git").path, clone.path],
                ["-C", clone.path, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic"],
                ["-C", clone.path, "push", "origin", "HEAD:refs/heads/main"]] {
                let result = try await ProcessRunner().run("/usr/bin/git", args, timeout: .seconds(120))
                try #require(result.status == 0, "Local Git fixture: \(result.stderr)")
            }
            let nodes: [[String: Any]] = [7, 8].map { number in
                ["number": number, "title": "Synthetic", "url": "https://example.invalid/pr/\(number)",
                 "isDraft": false, "headRefOid": "same-head", "headRefName": "feature-\(number)", "baseRefName": "main",
                 "body": "Tier: small", "updatedAt": "2026-11-13T10:00:00Z", "authorAssociation": "MEMBER",
                 "author": ["login": "author"], "labels": ["nodes": []], "comments": ["nodes": []],
                 "assignees": ["nodes": [["login": number == 7 ? "teammate" : "owner"]]]]
            }
            try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": "owner"], "repository": [
                "defaultBranchRef": ["name": "main"], "pullRequests": ["nodes": nodes,
                    "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]).write(to: root.appendingPathComponent("outage-prs"))
            try IssueAskFixture.payload([IssueAskFixture.issue(number: 9)]).write(to: root.appendingPathComponent("outage-issues"))
            try Data(#"{"version":1,"base":"main","tier":{"marker":"Tier:","values":["small"],"default":"small"},"reviews":{"small":[{"heading":"Review:","notByAuthor":true}]},"fixed":"Fixed:","moves":[{"move":"review","when":["no_review_or_response_newer"],"who":"assignee"}],"dispatch":{"review":{"agent":"synthetic","prompt":"Review"}}}"#.utf8)
                .write(to: root.appendingPathComponent("outage-flow"))
            let gh = root.appendingPathComponent("gh")
            try FileManager.default.moveItem(at: gh, to: root.appendingPathComponent("gh-original"))
            try """
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            case "$1 $2" in
              'api repos/synthetic/project/contents/.bton/flow.json') cat outage-flow; exit 0 ;;
              'api graphql')
                case "$*" in *'issues('*) cat outage-issues ;; *) cat outage-prs ;; esac
                exit 0 ;;
              'pr edit') printf '%s\\n' "$*" >> assignments; exit 0 ;;
            esac
            exec ./gh-original "$@"
            """.write(to: gh, atomically: true, encoding: .utf8)
            let agent = root.appendingPathComponent("claude")
            try "#!/bin/sh\nprintf yes > '\(root.appendingPathComponent("text-ran").path)'\nprintf 'Draft reply\\n'\n"
                .write(to: agent, atomically: true, encoding: .utf8)
            for script in [gh, agent] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path) }
            var config = try BtonConfig.loadOrCreate(home: base.home)
            config.repos[0].path = clone.path
            config.repos[0].takeMoves = true
            config.repos[0].environment = ["DATABASE_URL": "postgres://user:probe-secret@127.0.0.1:\(port)/db"]
            config.agents["claude"] = AgentTemplate(argv: [agent.path, "-p", "{prompt}"])
            try config.save(to: base.home.configURL)
            return Self(base: base)
        } catch { base.remove(); throw error }
    }
    func assignments() throws -> [String] {
        let file = base.root.appendingPathComponent("assignments")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}

// Bind without listening: connection attempts fail, while the reserved port cannot be stolen.
private final class OutageHoldSocket {
    private var descriptor: Int32
    let port: Int
    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Darwin.close(fd); throw POSIXError(.EINVAL) }
        descriptor = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }
    func listen() throws { try #require(Darwin.listen(descriptor, 32) == 0) }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
