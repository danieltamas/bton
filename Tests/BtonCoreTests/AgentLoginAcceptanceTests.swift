@testable import BtonCore
import Foundation
import Testing

private enum AgentLoginFixture {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let draft = JobKey(repo: "synthetic/project", item: "issue-7", move: IssueDrafts.move, head: "synthetic-comment")

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-login-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func file(_ root: URL, _ name: String, executable: Bool = true) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/usr/bin/env node\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: executable ? 0o700 : 0o600], ofItemAtPath: url.path)
        return url
    }

    static func job(agent: String? = "synthetic-agent", status: Job.Status = .failed,
                    end: TimeInterval = -30, key: JobKey = draft, flags: [JobFlag] = []) -> Job {
        var job = Job(id: UUID(), key: key, agent: agent, startedAt: now.addingTimeInterval(end - 60),
                      endedAt: status == .running ? nil : now.addingTimeInterval(end), status: status, cost: 0)
        job.flags = flags
        return job
    }

    static func candidate(_ jobs: [Job]) -> DispatchCandidate? {
        Supervision.candidate(settings: SupervisorSettings(enabled: true),
            agents: ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"])], jobs: jobs,
            repo: "synthetic/project", pullRequests: [], defaultBranch: "main", me: "synthetic-owner",
            now: now, log: { _ in "Synthetic diagnostic" })
    }
}

struct AgentLoginAcceptanceTests {
    @Test func locateGhPrefersResolvedCustomPrefix() throws {
        let root = try AgentLoginFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = try AgentLoginFixture.file(root, "custom-prefix/bin/gh")
        let fallback = try AgentLoginFixture.file(root, "fallback/gh")
        var names: [String] = []
        let found = GitHubClient.locateGh(resolve: { names.append($0); return custom.path }, candidates: [fallback.path])
        #expect(names == ["gh"])
        #expect(found == custom.path)
    }

    @Test func locateGhFallsBackToFirstExecutableOrNil() throws {
        let root = try AgentLoginFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = try AgentLoginFixture.file(root, "plain", executable: false)
        let first = try AgentLoginFixture.file(root, "first/gh")
        let second = try AgentLoginFixture.file(root, "second/gh")
        let missing = root.appendingPathComponent("missing").path
        #expect(GitHubClient.locateGh(resolve: { _ in nil }, candidates: [missing, plain.path, first.path, second.path]) == first.path)
        #expect(GitHubClient.locateGh(resolve: { _ in nil }, candidates: [missing, plain.path]) == nil)
        #expect(GitHubClient.locateGh(resolve: { _ in nil }, candidates: []) == nil)
    }

    @Test func searchPathKeepsSymlinkDirectoryBesideNode() throws {
        let root = try AgentLoginFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try AgentLoginFixture.file(root, "package/cli")
        let node = try AgentLoginFixture.file(root, "synthetic-nvm/bin/node")
        let link = node.deletingLastPathComponent().appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(Executables.searchPath(for: link.path) == node.deletingLastPathComponent().path + ":" + Executables.searchPath)
    }

    @Test func searchPathDeduplicatesDirectoryAndLeavesBareNamesUnchanged() throws {
        let dir = try #require(Executables.searchPath.split(separator: ":").first.map(String.init))
        let rest = Executables.searchPath.split(separator: ":").map(String.init).filter { $0 != dir }
        #expect(Executables.searchPath(for: dir + "/synthetic-cli") == ([dir] + rest).joined(separator: ":"))
        #expect(Executables.searchPath(for: "synthetic-cli") == Executables.searchPath)
    }

    @Test func failureReasonUsesLastTrimmedOutputLineAcrossCRLFAndBlanks() {
        #expect(AgentFailure.reason(output: "first\r\n  synthetic failure  \r\n \r\n", log: "log failure") == "synthetic failure")
    }

    @Test func failureReasonFallsBackToLogAndSkipsBtonNotes() {
        let notes = "2026-10-22T21:24:46Z bton: started synthetic\r\n"
        #expect(AgentFailure.reason(output: " \r\n\t", log: notes + " first \r\n final diagnostic \r\n" + notes) == "final diagnostic")
        #expect(AgentFailure.reason(output: "", log: notes + " \r\n") == nil)
        #expect(AgentFailure.reason(output: " \n", log: "\r\n") == nil)
        #expect(AgentFailure.reason(output: "", log: "synthetic bton: diagnostic") == "synthetic bton: diagnostic")
    }

    @Test func failureReasonCapsAtTwoHundredCharactersWithoutNewlines() throws {
        for useLog in [false, true] {
            let long = String(repeating: "x", count: 250)
            let reason = try #require(AgentFailure.reason(output: useLog ? "" : long + "\r\n", log: useLog ? long + "\n" : ""))
            #expect(reason == String(repeating: "x", count: 200))
            #expect(!reason.contains("\n") && !reason.contains("\r"))
        }
    }

    @Test(arguments: ["failed to authenticate", "oauth session expired", "invalid api key", "please run /login", "not logged in"])
    func recognizesEveryLoginFailureCaseInsensitively(phrase: String) {
        #expect(AgentFailure.isLoginFailure("Synthetic: " + phrase.uppercased() + "."))
        #expect(!AgentFailure.isLoginFailure("Synthetic compiler failure"))
        #expect(!AgentFailure.isLoginFailure(""))
    }

    @Test func failureDetailRecognizesLoginInOutputOrLogOnly() {
        #expect(AgentFailure.detail(status: 1, output: "Please run /login", log: "") == "agent logged out: Please run /login")
        #expect(AgentFailure.detail(status: 1, output: "", log: "OAuth session expired\n") == "agent logged out: OAuth session expired")
        #expect(AgentFailure.detail(status: 1, output: "final diagnostic", log: "NOT LOGGED IN") == "agent logged out: final diagnostic")
    }

    @Test func failureDetailFormatsStatusReasonAndAbnormalExit() {
        #expect(AgentFailure.detail(status: 1, output: "something", log: "") == "agent exited 1: something")
        #expect(AgentFailure.detail(status: 2, output: "", log: "") == "agent exited 2")
        #expect(AgentFailure.detail(status: nil, output: "diagnostic", log: "") == "agent exited abnormally: diagnostic")
        #expect(AgentFailure.detail(status: nil, output: "", log: "") == "agent exited abnormally")
    }

    @Test func watchdogDistinguishesLoggedOutFromOrdinaryAgentFailure() throws {
        var job = AgentLoginFixture.job()
        job.detail = "agent logged out: invalid api key"
        #expect(Watchdog.flags(for: job, among: []) == [.loggedOut])
        job.detail = "agent exited 1: something"
        #expect(Watchdog.flags(for: job, among: []) == [.agentFailed])
        #expect(try JSONDecoder().decode(JobFlag.self, from: JSONEncoder().encode(JobFlag.loggedOut)) == .loggedOut)
    }

    @Test func supervisorSkipsNewestLoggedOutJobEvenWithOtherFlags() {
        let key = JobKey(repo: "synthetic/project", item: "schedule-7", move: "schedule", head: "synthetic-head")
        let ordinary = AgentLoginFixture.job(end: -60, key: key, flags: [.agentFailed])
        let loggedOut = AgentLoginFixture.job(end: -10, key: key, flags: [.loggedOut, .repeated, .agentFailed])
        #expect(AgentLoginFixture.candidate([loggedOut]) == nil)
        #expect(AgentLoginFixture.candidate([ordinary])?.supervises == ordinary.id)
        #expect(AgentLoginFixture.candidate([ordinary, loggedOut])?.supervises == ordinary.id)
        #expect(AgentLoginFixture.candidate([loggedOut, ordinary])?.supervises == ordinary.id)
    }

    @Test(arguments: [Job.Status.failed, .cancelled])
    func issueDraftRetryRequiresNewestUnrequestedAttempt(status: Job.Status) {
        var job = AgentLoginFixture.job(status: status)
        #expect(job.canRetry(among: [job]))
        job.retry = false
        #expect(job.canRetry(among: [job]))
        let newer = AgentLoginFixture.job(end: -10)
        #expect(!job.canRetry(among: [newer, job]))
        job.retry = true
        #expect(!job.canRetry(among: [job]))
    }

    @Test func issueDraftRetryIgnoresOtherKeysAndEqualTimestampButRejectsOtherItems() {
        let job = AgentLoginFixture.job()
        let other = JobKey(repo: "synthetic/project", item: "issue-7", move: IssueDrafts.move, head: "other-comment")
        #expect(job.canRetry(among: [job, AgentLoginFixture.job(), AgentLoginFixture.job(end: -10, key: other)]))
        for status in [Job.Status.running, .succeeded] {
            #expect(!AgentLoginFixture.job(status: status).canRetry(among: []))
        }
        for (item, move) in [("schedule-7", "schedule"), ("issue-7", "merge")] {
            let key = JobKey(repo: "synthetic/project", item: item, move: move, head: "synthetic-head")
            #expect(!AgentLoginFixture.job(key: key).canRetry(among: []))
        }
        let pr = JobKey(repo: "synthetic/project", item: "pr-7", move: "fix", head: "synthetic-head")
        #expect(AgentLoginFixture.job(key: pr).canRetry(among: []))
    }

    @Test func heldUsesNewestEndedJobPerAgentAndIgnoresRunningAndCommands() {
        let old = AgentLoginFixture.job(end: -60, flags: [.loggedOut])
        var latest = AgentLoginFixture.job(end: -10, flags: [.loggedOut])
        latest = Job(id: latest.id, key: latest.key, agent: latest.agent,
                     startedAt: AgentLoginFixture.now.addingTimeInterval(-300), endedAt: latest.endedAt,
                     status: .failed)
        latest.flags = [.loggedOut]
        let running = AgentLoginFixture.job(status: .running, end: 0)
        let command = AgentLoginFixture.job(agent: nil, flags: [.loggedOut])
        let other = AgentLoginFixture.job(agent: "synthetic-other", status: .succeeded)
        for jobs in [[old, latest, running, command, other], [other, command, running, latest, old]] {
            #expect(AgentLogins.held(jobs: jobs, loggedInAt: [:]) == Set(["synthetic-agent"]))
        }
        #expect(AgentLogins.held(jobs: [], loggedInAt: [:]).isEmpty)
    }

    @Test(arguments: [Job.Status.succeeded, .failed])
    func laterOrdinaryEndedJobClearsHold(status: Job.Status) {
        let loggedOut = AgentLoginFixture.job(end: -60, flags: [.loggedOut])
        let later = AgentLoginFixture.job(status: status, end: -10)
        #expect(AgentLogins.held(jobs: [later, loggedOut], loggedInAt: [:]).isEmpty)
    }

    @Test func loginTimestampClearsHoldUntilStrictlyLaterLogout() {
        let job = AgentLoginFixture.job(flags: [.loggedOut])
        let ended = AgentLoginFixture.now.addingTimeInterval(-30)
        #expect(AgentLogins.held(jobs: [job], loggedInAt: ["synthetic-agent": ended]).isEmpty)
        #expect(AgentLogins.held(jobs: [job], loggedInAt: ["synthetic-agent": ended.addingTimeInterval(1)]).isEmpty)
        #expect(AgentLogins.held(jobs: [job], loggedInAt: ["synthetic-agent": ended.addingTimeInterval(-1)]) == Set(["synthetic-agent"]))
    }

    @Test func markLoggedInRoundTripsPreservesAgentsAndClearsHold() throws {
        let root = try AgentLoginFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        #expect(AgentLogins.load(home: home).isEmpty)
        let job = AgentLoginFixture.job(flags: [.loggedOut])
        try AgentLogins.markLoggedIn("synthetic-agent", at: AgentLoginFixture.now, home: home)
        let otherDate = AgentLoginFixture.now.addingTimeInterval(-10)
        try AgentLogins.markLoggedIn("synthetic-other", at: otherDate, home: home)
        let reopened = BtonHome(environment: ["BTON_HOME": root.path])
        #expect(AgentLogins.load(home: reopened) == ["synthetic-agent": AgentLoginFixture.now, "synthetic-other": otherDate])
        #expect(AgentLogins.held(jobs: [job], loggedInAt: AgentLogins.load(home: reopened)).isEmpty)
        try AgentLogins.markLoggedIn("synthetic-agent", at: otherDate, home: reopened)
        #expect(AgentLogins.load(home: home)["synthetic-agent"] == otherDate)
    }

    @Test func corruptLoginPersistenceLoadsAsEmpty() throws {
        let root = try AgentLoginFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        try AgentLogins.markLoggedIn("synthetic-agent", at: AgentLoginFixture.now, home: home)
        // Discover persistence without coupling the contract to a filename or encoding.
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        var files: [URL] = []
        for case let url as URL in enumerator {
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { files.append(url) }
        }
        #expect(!files.isEmpty)
        for file in files { try Data("synthetic corrupt data".utf8).write(to: file) }
        #expect(AgentLogins.load(home: home).isEmpty)
    }
}
