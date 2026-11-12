@testable import BtonCore
import Foundation
import XCTest

final class SessionWatchAcceptanceTests: XCTestCase {
    private var root: URL!
    private var home: BtonHome!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-watch-\(UUID())")
        home = BtonHome(environment: ["BTON_HOME": root.path])
        try home.prepare()
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testAbsentMarkIsNotWatched() {
        XCTAssertFalse(SessionWatch(home: home).isWatched(repo: "Owner/Repo", number: 7, at: now))
    }

    func testMarkReturnsExpiryAndPersistsUnderWatching() throws {
        let watch = SessionWatch(home: home)
        XCTAssertEqual(try watch.mark(repo: "Owner/Repo", number: 7, for: 90, now: now), now + 90)
        XCTAssertTrue(SessionWatch(home: home).isWatched(repo: "Owner/Repo", number: 7, at: now))
        XCTAssertEqual(try markFiles().count, 1)
    }

    func testDurationIsCappedAtSixHours() throws {
        let watch = SessionWatch(home: home)
        XCTAssertEqual(SessionWatch.longest, 6 * 3600)
        XCTAssertEqual(try watch.mark(repo: "o/r", number: 7, for: 100_000, now: now), now + 21_600)
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now))
    }

    func testNegativeAndZeroDurationsExpireImmediately() throws {
        let watch = SessionWatch(home: home)
        for duration: TimeInterval in [-10, 0] {
            XCTAssertEqual(try watch.mark(repo: "o/r", number: 7, for: duration, now: now), now)
            XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now))
        }
    }

    func testExpiryBoundaryReleasesDeadSession() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, now: now)
        XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now + 59))
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + 60))
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now + 61))
    }

    func testMalformedFileFailsClosed() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, now: now)
        let file = try XCTUnwrap(markFiles().first)
        for contents in [Data("not a date".utf8), Data(), Data([0xff, 0xfe])] {
            try contents.write(to: file)
            XCTAssertTrue(watch.isWatched(repo: "o/r", number: 7, at: now))
        }
    }

    func testHandwrittenExpiryBeyondSixHoursIsNotWatched() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "o/r", number: 7, for: 60, now: now)
        let file = try XCTUnwrap(markFiles().first)
        try Data((now + 21_601).formatted(.iso8601).utf8).write(to: file)
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now))
    }

    func testCaseInsensitiveRemarkReplacesOnePRWithoutAffectingOthers() throws {
        let watch = SessionWatch(home: home)
        try watch.mark(repo: "Owner/Repo", number: 7, for: 60, now: now)
        XCTAssertTrue(watch.isWatched(repo: "owner/repo", number: 7, at: now))
        XCTAssertFalse(watch.isWatched(repo: "owner/repo", number: 8, at: now))
        XCTAssertFalse(watch.isWatched(repo: "other/repo", number: 7, at: now))
        try watch.mark(repo: "owner/repo", number: 7, for: 120, now: now)
        XCTAssertEqual(try markFiles().count, 1)
        try watch.mark(repo: "other/repo", number: 7, for: 120, now: now)
        try watch.mark(repo: "owner/repo", number: 8, for: 120, now: now)
        XCTAssertEqual(try markFiles().count, 3)
        XCTAssertTrue(watch.isWatched(repo: "OWNER/REPO", number: 7, at: now + 90))
        try watch.clear(repo: "OWNER/REPO", number: 7)
        XCTAssertFalse(watch.isWatched(repo: "owner/repo", number: 7, at: now))
        XCTAssertTrue(watch.isWatched(repo: "other/repo", number: 7, at: now))
        XCTAssertTrue(watch.isWatched(repo: "owner/repo", number: 8, at: now))
    }

    func testClearRemovesFileAndIsIdempotent() throws {
        let watch = SessionWatch(home: home)
        XCTAssertNoThrow(try watch.clear(repo: "o/r", number: 7))
        try watch.mark(repo: "o/r", number: 7, for: 60, now: now)
        try watch.clear(repo: "o/r", number: 7)
        XCTAssertEqual(try markFiles().count, 0)
        XCTAssertFalse(watch.isWatched(repo: "o/r", number: 7, at: now))
        XCTAssertNoThrow(try watch.clear(repo: "o/r", number: 7))
    }

    func testOnlyBranchWritingPRCandidatesWriteBranch() {
        let pr = PullRequest(repo: "o/r", number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: "same-head", headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: now)
        func candidate(agent: String? = "synthetic", comment: Bool = false) -> DispatchCandidate {
            DispatchCandidate(target: .pullRequest(pr),
                move: Move(name: comment ? "review" : "fix", owner: "owner", ownerFromRotation: false,
                           tier: "small", hasDispatch: true),
                key: JobKey(repo: pr.repo, item: "pr-7", move: "fix", head: pr.headSha),
                agent: agent, prompt: "Task", command: agent == nil ? ["/usr/bin/true"] : nil,
                postComment: comment, timeout: .seconds(60))
        }
        XCTAssertTrue(candidate().writesBranch)
        XCTAssertFalse(candidate(comment: true).writesBranch)
        XCTAssertFalse(candidate(agent: nil).writesBranch)
        var text = candidate()
        text.textOnly = true
        XCTAssertFalse(text.writesBranch)
        var supervisor = candidate()
        supervisor.supervises = UUID()
        XCTAssertFalse(supervisor.writesBranch)
        var branch = candidate()
        branch.target = .branch("main")
        XCTAssertFalse(branch.writesBranch)
        var issue = candidate()
        issue.target = .issue(IntakePlan(issue: 8, base: "main", terms: IssueIntake.Terms(),
            claim: [], worktree: [], worktreePath: ".worktrees/issue-8"))
        XCTAssertFalse(issue.writesBranch)
    }

    func testLiveWatchBlocksAuthorsFix() async throws {
        try await assertEngine(move: "fix", mark: "live", otherAuthor: false, starts: false)
    }

    func testLiveWatchAllowsAuthorsCommentReview() async throws {
        try await assertEngine(move: "review", mark: "live", otherAuthor: false, starts: true)
    }

    func testExpiredWatchAllowsAuthorsFix() async throws {
        try await assertEngine(move: "fix", mark: "expired", otherAuthor: false, starts: true)
    }

    func testClearedWatchAllowsAuthorsFix() async throws {
        try await assertEngine(move: "fix", mark: "cleared", otherAuthor: false, starts: true)
    }

    func testLiveWatchDoesNotBlockOtherAuthorsFix() async throws {
        try await assertEngine(move: "fix", mark: "live", otherAuthor: true, starts: true)
    }

    private func markFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("watching"),
                                                    includingPropertiesForKeys: nil)
    }

    private func assertEngine(move: String, mark: String, otherAuthor: Bool, starts: Bool) async throws {
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
        if otherAuthor {
            script = script.replacingOccurrences(of: "\"author\":{\"login\":\"owner\"}",
                                                with: "\"author\":{\"login\":\"teammate\"}")
        }
        try script.write(to: gh, atomically: true, encoding: .utf8)
        let watch = SessionWatch(home: f.home)
        let reference = Date.now
        try watch.mark(repo: f.repo, number: 7, for: 3600,
                       now: mark == "expired" ? reference - 7200 : reference)
        if mark == "cleared" { try watch.clear(repo: f.repo, number: 7) }
        let engine = try f.engine()
        let snapshot = await engine.tick()
        // Stop any dispatched work before removing its isolated fixture; no polling or sleeps.
        for job in snapshot.jobs { await engine.stop(job.id) }
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.openPullRequests.count, 1)
        XCTAssertEqual(snapshot.openPullRequests.first?.author, otherAuthor ? "teammate" : "owner")
        XCTAssertEqual(snapshot.openPullRequests.first?.move?.name, move)
        XCTAssertEqual(snapshot.jobs.map(\.key.move), starts ? [move] : [])
    }
}
