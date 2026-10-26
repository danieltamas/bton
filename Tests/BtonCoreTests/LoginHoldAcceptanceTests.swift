@testable import BtonCore
import Foundation
import Testing

private enum LoginHoldFixture {
    static let start = "2026-10-23T10:00:00Z bton: agent starts"
    static let running = "2026-10-23T10:00:01Z bton: claude running, pid 1"

    static func detail(output: String = "", lines: [String]) -> String {
        AgentFailure.detail(status: 7, output: output, log: lines.joined(separator: "\n"))
    }

    static func job(agent: String, status: Job.Status, start: TimeInterval,
                    end: TimeInterval, loggedOut: Bool = false) -> Job {
        var job = Job(id: UUID(),
            key: JobKey(repo: "synthetic/project", item: "pr-7", move: "review", head: "synthetic-head"),
            agent: agent, startedAt: Date(timeIntervalSince1970: start),
            endedAt: Date(timeIntervalSince1970: end), status: status)
        job.flags = loggedOut ? [.loggedOut] : nil
        return job
    }
}

@Suite(ProcessBound())
struct LoginHoldAcceptanceTests {
    @Test func setupLoginPhraseBeforeStartDoesNotHoldAgent() {
        #expect(LoginHoldFixture.detail(lines: ["not logged in", LoginHoldFixture.start,
            "synthetic failure"]) == "agent exited 7: synthetic failure")
        #expect(LoginHoldFixture.detail(lines: ["not logged in", LoginHoldFixture.start])
            == "agent exited 7: not logged in")
    }

    @Test func fastLoginFailureBeforeRunningNoteStillHoldsAgent() {
        #expect(LoginHoldFixture.detail(lines: [LoginHoldFixture.start, "Please run /login",
            LoginHoldFixture.running]) == "agent logged out: Please run /login")
    }

    @Test func lastStartNoteDefinesAgentLogBoundary() {
        #expect(LoginHoldFixture.detail(lines: [LoginHoldFixture.start, "invalid api key",
            LoginHoldFixture.start, "synthetic failure", LoginHoldFixture.running])
            == "agent exited 7: synthetic failure")
        #expect(LoginHoldFixture.detail(lines: ["synthetic bton: agent starts", "not logged in",
            "2026-10-23T10:00:00Z bton: setup command agent starts", "synthetic failure"])
            == "agent logged out: synthetic failure")
    }

    @Test func loginSearchCountsThreeAgentLinesRatherThanNotes() {
        #expect(LoginHoldFixture.detail(lines: [LoginHoldFixture.start, "not logged in",
            LoginHoldFixture.running, "synthetic second", LoginHoldFixture.running, "synthetic final"])
            == "agent logged out: synthetic final")
        #expect(LoginHoldFixture.detail(lines: [LoginHoldFixture.start, "not logged in",
            "synthetic second", LoginHoldFixture.running, "synthetic third", "synthetic final"])
            == "agent exited 7: synthetic final")
    }

    @Test func logWithoutStartUsesOnlyLastThreeNonNoteLines() {
        #expect(LoginHoldFixture.detail(lines: ["OAuth session expired", LoginHoldFixture.running,
            "synthetic second", "synthetic final"]) == "agent logged out: synthetic final")
        #expect(LoginHoldFixture.detail(lines: ["OAuth session expired", "synthetic second",
            LoginHoldFixture.running, "synthetic third", "synthetic final"])
            == "agent exited 7: synthetic final")
    }

    @Test func outputLoginSearchUsesOnlyFinalLineAndReasonPrefersOutput() {
        #expect(LoginHoldFixture.detail(output: "not logged in\nsynthetic final\n", lines: [])
            == "agent exited 7: synthetic final")
        #expect(LoginHoldFixture.detail(output: "synthetic first\nNOT LOGGED IN\r\n", lines: [])
            == "agent logged out: NOT LOGGED IN")
        #expect(LoginHoldFixture.detail(output: "synthetic final", lines: [LoginHoldFixture.start,
            "invalid api key", LoginHoldFixture.running]) == "agent logged out: synthetic final")
    }

    @Test func reasonRemovesCSIAndControlAndFormatScalarsFromEitherSource() {
        // CSI parameter bytes include the entire 0x30...0x3F range, including colon and greater-than.
        let decorated = "\u{1B}[38:2:1:2:3m\u{202E}synthetic\u{200B}\u{0007}\u{2066} reason\u{2069}\u{1B}[>0c\u{1B}[0m"
        for useLog in [false, true] {
            #expect(LoginHoldFixture.detail(output: useLog ? "" : decorated,
                lines: useLog ? [decorated, LoginHoldFixture.running] : ["other diagnostic"])
                == "agent exited 7: synthetic reason")
        }
    }

    @Test func reasonIsSanitizedBeforeTwoHundredCharacterCap() {
        let long = "\u{1B}[31m\u{202E}" + String(repeating: "x", count: 205) + "\u{1B}[0m"
        for useLog in [false, true] {
            #expect(LoginHoldFixture.detail(output: useLog ? "" : long, lines: useLog ? [long] : [])
                == "agent exited 7: " + String(repeating: "x", count: 200))
        }
    }

    @Test func invisibleOnlyFinalLineGivesNoReason() {
        let invisible = "\u{1B}[31m\u{202E}\u{200B}\u{0007}\u{1B}[0m"
        #expect(LoginHoldFixture.detail(output: invisible, lines: ["synthetic older reason"])
            == "agent exited 7")
        #expect(LoginHoldFixture.detail(lines: ["synthetic older reason", invisible,
            LoginHoldFixture.running]) == "agent exited 7")
        #expect(AgentFailure.reason(output: invisible, log: "synthetic older reason") == nil)
    }

    @Test func laterCancellationClearsOnlyItsAgentsHoldRegardlessOfStartOrder() {
        let logout = LoginHoldFixture.job(agent: "synthetic-alpha", status: .failed,
            start: 100, end: 200, loggedOut: true)
        let cancelled = LoginHoldFixture.job(agent: "synthetic-alpha", status: .cancelled,
            start: 50, end: 300)
        let other = LoginHoldFixture.job(agent: "synthetic-beta", status: .failed,
            start: 100, end: 200, loggedOut: true)
        for jobs in [[logout, cancelled, other], [other, cancelled, logout]] {
            #expect(AgentLogins.held(jobs: jobs, loggedInAt: [:]) == Set(["synthetic-beta"]))
        }
        let earlier = LoginHoldFixture.job(agent: "synthetic-alpha", status: .cancelled,
            start: 50, end: 150)
        #expect(AgentLogins.held(jobs: [logout, earlier], loggedInAt: [:]) == Set(["synthetic-alpha"]))
    }

    @Test func releaseWithoutRunAllowsSameKeyWithoutRerun() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try fixture.store("synthetic-a"), b = try fixture.store("synthetic-b")
        let lease = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: "synthetic-key"))
        try await a.release(lease, ran: false)
        let reclaimed = try RetryLeaseFixture.claimed(await b.claim(fixture.item, in: fixture.repo, key: "synthetic-key"))
        #expect(reclaimed.record.key == "synthetic-key")
        #expect(reclaimed.record.done?.contains("synthetic-key") != true)
        try await b.release(reclaimed, ran: false)
    }

    @Test func defaultReleaseRecordsRunAndRefusesSameKey() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try fixture.store("synthetic-a"), b = try fixture.store("synthetic-b")
        let lease = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: "synthetic-key"))
        try await a.release(lease)
        guard case let .notClaimed(holder) = try await b.claim(fixture.item, in: fixture.repo, key: "synthetic-key") else {
            Issue.record("Default release must prevent another run of the same key")
            return
        }
        #expect(holder?.hasRun("synthetic-key") == true)
        #expect(holder?.released == true)
    }

    @Test(arguments: [false, true])
    func releasePreservesHistoryCarriedBeforeClaim(ran: Bool) async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let a = try fixture.store("synthetic-a"), b = try fixture.store("synthetic-b")
        for key in ["synthetic-earlier", "synthetic-previous"] {
            let lease = try RetryLeaseFixture.claimed(await a.claim(fixture.item, in: fixture.repo, key: key))
            try await a.release(lease)
        }
        let current = try RetryLeaseFixture.claimed(await b.claim(fixture.item, in: fixture.repo, key: "synthetic-current"))
        #expect(current.record.done == ["synthetic-earlier", "synthetic-previous"])
        try await b.release(current, ran: ran)
        for key in ["synthetic-earlier", "synthetic-previous"] {
            guard case let .notClaimed(holder) = try await a.claim(fixture.item, in: fixture.repo, key: key) else {
                Issue.record("Release must retain prior run history")
                return
            }
            #expect(holder?.done == ["synthetic-earlier", "synthetic-previous"])
            #expect(holder?.hasRun(key) == true)
            #expect(holder?.hasRun("synthetic-current") == ran)
        }
    }
}
