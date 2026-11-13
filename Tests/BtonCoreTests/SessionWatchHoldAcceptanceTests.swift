@testable import BtonCore
import Dispatch
import Foundation
import XCTest

final class SessionWatchHoldAcceptanceTests: XCTestCase {
    private var root: URL!
    private var home: BtonHome!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-watch-hold-\(UUID())")
        home = BtonHome(environment: ["BTON_HOME": root.path])
        try home.prepare()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testClearingOneHolderPreservesTheOtherAndLastClearRemovesFile() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, holder: "first", now: now)
        try watch.mark(repo: "o/r", number: 7, for: 120, holder: "second", now: now)
        XCTAssertEqual(try holders(), ["first", "second"])
        try watch.clear(repo: "o/r", number: 7, holder: "first")
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now + 90))
        XCTAssertEqual(try holders(), ["second"])
        try watch.clear(repo: "o/r", number: 7, holder: "second")
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now))
        XCTAssertTrue(try markFiles().isEmpty)
    }

    func testRemarkReplacesOnlyThatHoldersLine() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, holder: "first", now: now)
        try watch.mark(repo: "o/r", number: 7, for: 90, holder: "second", now: now)
        try watch.mark(repo: "o/r", number: 7, for: 180, holder: "first", now: now)
        XCTAssertEqual(try holders(), ["first", "second"])
        try watch.clear(repo: "o/r", number: 7, holder: "second")
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now + 179))
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + 180))
    }

    func testTwentyConcurrentHoldersSurviveUntilEachClears() throws {
        let watch = SessionWatch(home: home)
        let reference = now
        let failures = MarkFailures()
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try watch.mark(repo: "o/r", number: 7, for: 120,
                               holder: "holder-\(index)", now: reference)
            } catch { failures.append(error) }
        }
        XCTAssertTrue(failures.errors.isEmpty, "Concurrent marks failed: \(failures.errors)")
        XCTAssertEqual(try holders().sorted(), (0..<20).map { "holder-\($0)" }.sorted())
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now))
        for index in 0..<19 {
            try watch.clear(repo: "o/r", number: 7, holder: "holder-\(index)")
            XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now), "Cleared holder \(index)")
        }
        try watch.clear(repo: "o/r", number: 7, holder: "holder-19")
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now))
        XCTAssertTrue(try markFiles().isEmpty)
    }

    func testRenamedRepoRecognizesURLAndConfiguredNamesButNotUnrelatedRepo() throws {
        let watch = SessionWatch(home: home)
        let pr = pullRequest(repo: "old/name", url: "https://github.com/new/name/pull/7")
        for repo in ["new/name", "old/name", "unrelated/name"] {
            try watch.mark(repo: repo, number: 7, for: 120, holder: "session", now: now)
            XCTAssertEqual(watch.isWatched(pr, repo: "old/name", at: now), repo != "unrelated/name", repo)
            try watch.clear(repo: repo, number: 7, holder: "session")
        }
    }

    func testPersonsRunNextStartsWatchedAuthorsFix() async throws {
        try await assertEngine(move: "fix", marked: true, pressed: true, starts: true, held: false)
    }

    func testSupervisorRunNextDoesNotStartWatchedAuthorsFix() async throws {
        try await assertEngine(move: "fix", marked: true, pressed: false, starts: false, held: true)
    }

    func testHeldFixSetsSnapshotRowFlag() async throws {
        try await assertEngine(move: "fix", marked: true, starts: false, held: true)
    }

    func testUnmarkedFixDoesNotSetSnapshotRowFlag() async throws {
        try await assertEngine(move: "fix", marked: false, starts: true, held: false)
    }

    func testWatchedCommentReviewStartsWithoutSnapshotHoldFlag() async throws {
        try await assertEngine(move: "review", marked: true, starts: true, held: false)
    }

    func testMarkAfterPlanningBlocksDispatcherUnderLeaseWithoutRecordingJob() async throws {
        try await assertDispatch(pressed: false)
    }

    func testPressedCandidateBypassesMarkUnderDispatcherLease() async throws {
        try await assertDispatch(pressed: true)
    }

    private func markFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: home.url.appendingPathComponent("watching"),
                                                    includingPropertiesForKeys: nil)
    }

    private func holders() throws -> [String] {
        let files = try markFiles()
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        return try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline).map {
            String($0.split(separator: " ", maxSplits: 1).last ?? "")
        }.sorted()
    }

    private func pullRequest(repo: String, url: String, head: String = "same-head") -> PullRequest {
        PullRequest(repo: repo, number: 7, title: "Synthetic", author: "owner", authorAssociation: "OWNER",
            url: URL(string: url)!, headSha: head, headRef: "feature", baseRef: "main", body: "",
            isDraft: false, labels: [], assignees: [], comments: [], updatedAt: now)
    }

    private func assertEngine(move: String, marked: Bool, pressed: Bool? = nil, starts: Bool, held: Bool,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let gh = f.root.appendingPathComponent("gh")
        var script = try String(contentsOf: gh, encoding: .utf8)
        let oldFlow = try XCTUnwrap(script.components(separatedBy: "\n").first { $0.hasPrefix("{\"version\":") })
        var flow = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(oldFlow.utf8)) as? [String: Any])
        flow["moves"] = [["move": move, "when": ["no_review_or_response_newer"], "who": "owner"]]
        flow["dispatch"] = [move: ["agent": "synthetic", "prompt": "Task",
                                  "post": move == "review" ? "comment" : "none"]]
        script = script.replacingOccurrences(of: oldFlow,
            with: String(decoding: try JSONSerialization.data(withJSONObject: flow), as: UTF8.self))
        try script.write(to: gh, atomically: true, encoding: .utf8)
        if marked {
            // Engine has no clock injection; only the integration mark uses its live clock.
            try SessionWatch(home: f.home).mark(repo: f.repo, number: 7, for: 3600,
                                               holder: "author-session", now: Date.now)
        }
        let engine = try f.engine()
        if let pressed { await engine.runNext(repo: f.repo, item: "pr-7", pressed: pressed) }
        let snapshot = await engine.tick()
        for job in snapshot.jobs { await engine.stop(job.id) }
        XCTAssertNil(snapshot.problem, file: file, line: line)
        XCTAssertEqual(snapshot.openPullRequests.count, 1, file: file, line: line)
        XCTAssertEqual(snapshot.openPullRequests.first?.author, "owner", file: file, line: line)
        XCTAssertEqual(snapshot.openPullRequests.first?.move?.name, move, file: file, line: line)
        XCTAssertEqual(snapshot.jobs.map(\.key.move), starts ? [move] : [], file: file, line: line)
        XCTAssertEqual(snapshot.openPullRequests.first?.heldBySession, held, file: file, line: line)
    }

    private func assertDispatch(pressed: Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let github = GitHubClient(ghPath: f.leases.root.appendingPathComponent("gh").path)
        let remote = f.leases.root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "owner", host: "fixture",
            github: github, remoteURL: { _ in remote })
        let jobs = try JobStore(home: f.home)
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: jobs, home: f.home, log: { _ in })
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", f.clone.path, "rev-parse", "HEAD"],
                                                   timeout: .seconds(30))
        XCTAssertEqual(result.status, 0, result.stderr, file: file, line: line)
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let pr = pullRequest(repo: f.leases.repo, url: "https://github.com/\(f.leases.repo)/pull/7", head: head)
        var candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "fix", owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "fix", head: head), agent: "synthetic",
            prompt: "Task", command: nil, postComment: false, timeout: .seconds(30))
        candidate.pressed = pressed
        XCTAssertTrue(jobs.all().isEmpty, file: file, line: line)
        // The candidate already exists when the author's session takes over the branch.
        try SessionWatch(home: f.home).mark(repo: pr.repo, number: pr.number, for: 3600,
                                           holder: "late-session", now: Date.now)
        let outcome = await dispatcher.dispatch(candidate, clone: f.clone, flow: nil,
            agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])])
        let recorded = jobs.all()
        for job in recorded { await dispatcher.stopAndWait(job.id, reason: "acceptance test cleanup") }
        if pressed {
            guard case .started = outcome else {
                return XCTFail("A person's pressed fix must start, got \(outcome)", file: file, line: line)
            }
            XCTAssertEqual(recorded.map(\.key), [candidate.key], file: file, line: line)
        } else {
            guard case .busy = outcome else {
                return XCTFail("The late mark must hold the fix, got \(outcome)", file: file, line: line)
            }
            XCTAssertTrue(recorded.isEmpty, file: file, line: line)
        }
    }

    func testSupervisorRetryOfPressedFixWaitsForWatchingSessionUntilFreshPress() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let store = try JobStore(home: f.home)
        let reference = Date.now
        var flagged = Job(id: UUID(), key: f.key("fix"), agent: "synthetic",
            startedAt: reference - 60, endedAt: reference - 30, status: .failed, cost: 0)
        flagged.pressed = true
        flagged.flags = [.agentFailed]
        var verdict = Job(id: UUID(), key: f.key(Supervision.move), agent: "claude",
            startedAt: reference - 20, endedAt: reference - 10, status: .succeeded, cost: 0,
            supervises: flagged.id)
        let note = "Recheck the transient failure, then repeat the original task."
        verdict.verdict = SupervisorVerdict(action: .retry, note: note)
        try store.save(flagged)
        try store.save(verdict)
        try SessionWatch(home: f.home).mark(repo: f.repo, number: 7, for: 3600,
                                           holder: "author-session", now: reference)
        let engine = try f.engine()
        // A completed verdict reaches applyVerdicts and its real steered retry during the tick.
        let held = await engine.tick()
        for job in held.jobs where job.status == .running { await engine.stop(job.id) }
        XCTAssertNil(held.problem)
        XCTAssertEqual(Set(held.jobs.map(\.id)), Set([flagged.id, verdict.id]))
        XCTAssertEqual(held.openPullRequests.first?.heldBySession, true)
        let saved = try XCTUnwrap(store.all().first { $0.id == verdict.id }?.verdict)
        XCTAssertEqual(saved.applied, true)
        XCTAssertEqual(saved.outcome, "retried")
        XCTAssertEqual(store.all().first { $0.id == flagged.id }?.steer, note)
        XCTAssertEqual(store.all().first { $0.id == flagged.id }?.retry, true)

        await engine.runNext(repo: f.repo, item: "pr-7", pressed: true)
        let pressed = await engine.tick()
        for job in pressed.jobs where job.status == .running { await engine.stop(job.id) }
        XCTAssertNil(pressed.problem)
        let started = pressed.jobs.filter { $0.id != flagged.id && $0.id != verdict.id }
        XCTAssertEqual(started.map(\.key), [flagged.key])
        XCTAssertEqual(started.first?.pressed, true)
        XCTAssertEqual(pressed.openPullRequests.first?.heldBySession, false)
        XCTAssertTrue(SessionWatch(home: f.home).isWatched(repo: f.repo, number: 7))
    }

    func testClearingOneHolderOfUnreadableMarkThrowsAndKeepsPRWatched() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, holder: "first", now: now)
        try watch.mark(repo: "o/r", number: 7, for: 120, holder: "second", now: now)
        XCTAssertEqual(try holders(), ["first", "second"])
        let file = try XCTUnwrap(markFiles().first)
        let unreadable = Data([0xff, 0xfe])
        try unreadable.write(to: file)

        XCTAssertThrowsError(try watch.clear(repo: "o/r", number: 7, holder: "first"))
        XCTAssertEqual(try markFiles(), [file])
        XCTAssertEqual(try Data(contentsOf: file), unreadable)
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now))
    }

    func testSixHourMarkSurvivesBackwardClockAndRejectsExpiryBeyondFileWriteCap() throws {
        let watch = SessionWatch(home: home)
        let sixHours: TimeInterval = 6 * 3600
        XCTAssertEqual(try watch.mark(repo: "o/r", number: 7, for: sixHours, holder: "session", now: now),
                       now + sixHours)
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now - 60))
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now + sixHours - 1))
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + sixHours))
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + sixHours + 1))

        let file = try XCTUnwrap(markFiles().first)
        try Data(((now + sixHours + 60).formatted(.iso8601) + " session\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now - 60))
        // The cap belongs to the file's write time even once the reader is within six hours.
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + 120))
    }
}

private final class MarkFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(String(describing: error))
    }

    var errors: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
