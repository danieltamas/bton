@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CheckTimeLimitAcceptanceTests {
    @Test func flowMoveTimeLimitUsesConfiguredMinutesOrDefaultsToSixty() throws {
        #expect(Dispatcher.agentPollInterval == .milliseconds(20))
        let configured = try JSONDecoder().decode(DispatchRule.self,
            from: Data(#"{"command":["/usr/bin/true"],"timeoutMinutes":20}"#.utf8))
        let implicit = try JSONDecoder().decode(DispatchRule.self,
            from: Data(#"{"command":["/usr/bin/true"]}"#.utf8))
        #expect(configured.timeout == .seconds(1200))
        #expect(implicit.timeout == .seconds(3600))
    }

    @Test(arguments: [false, true])
    func checkPastMoveLimitFailsAndRunsNothingAfterIt(agentMove: Bool) async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.base.leases.root) }
        let later = f.root.appendingPathComponent("later-check")
        let checks = [["/bin/sh", "-c", "echo retained-out; echo retained-err >&2; sleep 8"],
                      ["/bin/sh", "-c", "touch \"$LATER_CHECK\""]]
        let id = try await f.start(checks: checks, timeout: .seconds(1), agentMove: agentMove,
                                   environment: ["LATER_CHECK": later.path])
        let ended = try await f.finished(id)
        #expect(ended.status == .failed)
        let detail = (ended.detail ?? "").lowercased()
        #expect(detail.contains("did not finish"))
        #expect(detail.contains("stopped"))
        #expect(!FileManager.default.fileExists(atPath: later.path))
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
        let lines = f.log(id).components(separatedBy: "\n")
        #expect(lines.contains("retained-out"))
        #expect(lines.contains("retained-err"))
    }

    @Test(arguments: [false, true])
    func eachCheckGetsTheFullMoveLimit(agentMove: Bool) async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        // Each fits in two seconds; together they exceed two seconds.
        let check = ["/bin/sh", "-c", "sleep 1; echo check-finished"]
        let id = try await f.start(checks: [check, check, check], timeout: .seconds(2), agentMove: agentMove)
        let ended = try await f.finished(id)
        #expect(ended.status == .succeeded)
        #expect(FileManager.default.fileExists(atPath: f.action.path))
        #expect(f.log(id).components(separatedBy: "\n").filter { $0 == "check-finished" }.count == 3)
    }

    @Test func runningCheckAppendsBothStreamsBeforeItExits() async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let done = f.root.appendingPathComponent("check-done")
        let release = f.root.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let id = try await f.start(checks: [["/bin/sh", "-c",
            "echo early-check-out; echo early-check-err >&2; while [ ! -f \"$RELEASE\" ]; do sleep 0.02; done; touch \"$CHECK_DONE\""]],
            timeout: .seconds(10), environment: ["CHECK_DONE": done.path, "RELEASE": release.path])
        let streamed = try await CheckTimeFixture.poll(for: .seconds(60)) {
            let lines = f.log(id).components(separatedBy: "\n")
            return lines.contains("early-check-out") && lines.contains("early-check-err")
        }
        #expect(streamed)
        #expect(!FileManager.default.fileExists(atPath: done.path))
        #expect(f.store.all().first { $0.id == id }?.status == .running)
        try Data().write(to: release)
        let ended = try await f.finished(id)
        #expect(ended.status == .succeeded)
    }

    @Test func runningMergeAppendsBothStreamsBeforeItExits() async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let command = ["/bin/sh", "-c",
            "echo early-merge-out; echo early-merge-err >&2; while [ ! -f \"$RELEASE\" ]; do sleep 0.02; done; touch \"$ACTION_FILE\""]
        let release = f.root.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let id = try await f.start(checks: [], timeout: .seconds(10), command: command, environment: ["RELEASE": release.path])
        let streamed = try await CheckTimeFixture.poll(for: .seconds(60)) {
            let lines = f.log(id).components(separatedBy: "\n")
            return lines.contains("early-merge-out") && lines.contains("early-merge-err")
        }
        #expect(streamed)
        #expect(!FileManager.default.fileExists(atPath: f.action.path))
        #expect(f.store.all().first { $0.id == id }?.status == .running)
        try Data().write(to: release)
        let ended = try await f.finished(id)
        #expect(ended.status == .succeeded)
    }

    @Test func successfulCheckAndMergeLogEachStreamOnceAfterTheirAnnouncement() async throws {
        let f = try await CheckTimeFixture.make()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let check = ["/bin/sh", "-c", "echo unique-check-out; echo unique-check-err >&2"]
        let command = ["/bin/sh", "-c", "echo unique-merge-out; echo unique-merge-err >&2"]
        let id = try await f.start(checks: [check], timeout: .seconds(5), command: command)
        let ended = try await f.finished(id)
        #expect(ended.status == .succeeded)
        let lines = f.log(id).components(separatedBy: "\n")
        for (argv, markers) in [(check, ["unique-check-out", "unique-check-err"]),
                                 (command, ["unique-merge-out", "unique-merge-err"])] {
            let announcement = try #require(lines.firstIndex(of: "$ " + argv.joined(separator: " ")))
            for marker in markers {
                #expect(lines.filter { $0 == marker }.count == 1)
                let position = try #require(lines.firstIndex(of: marker))
                #expect(position > announcement)
            }
        }
    }

    @Test func processOutputCallbackStreamsBothPipesAndPreservesReturnedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let done = root.appendingPathComponent("done")
        let release = root.appendingPathComponent("release")
        defer { try? Data().write(to: release) }
        let capture = CheckTimeCapture()
        let task = Task {
            try await ProcessRunner().run("/bin/sh", ["-c",
                "printf 'callback-out\\n'; printf 'callback-err\\n' >&2; while [ ! -f \"$RELEASE\" ]; do sleep 0.02; done; touch \"$DONE_FILE\""],
                environment: ["DONE_FILE": done.path, "RELEASE": release.path], timeout: .seconds(10),
                output: { capture.append($0) })
        }
        let streamed = try await CheckTimeFixture.poll(for: .seconds(60)) {
            capture.text.contains("callback-out\n") && capture.text.contains("callback-err\n")
        }
        #expect(streamed)
        #expect(!FileManager.default.fileExists(atPath: done.path))
        try Data().write(to: release)
        let result = try await task.value
        #expect(result.status == 0)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "callback-out\n")
        #expect(result.stderr == "callback-err\n")
        let lines = capture.text.components(separatedBy: "\n")
        #expect(lines.filter { $0 == "callback-out" }.count == 1)
        #expect(lines.filter { $0 == "callback-err" }.count == 1)
    }

    @Test func processTimeoutThrowsAfterDeliveringOutputFromBothPipes() async throws {
        let capture = CheckTimeCapture()
        do {
            _ = try await ProcessRunner().run("/bin/sh", ["-c",
                "echo before-timeout-out; echo before-timeout-err >&2; sleep 8; echo too-late"],
                timeout: .seconds(1), output: { capture.append($0) })
            Issue.record("A child past its deadline must throw timedOut")
        } catch let error as ProcessRunner.Failure {
            #expect(error == .timedOut)
        }
        #expect(capture.text.contains("before-timeout-out\n"))
        #expect(capture.text.contains("before-timeout-err\n"))
        #expect(!capture.text.contains("too-late"))
    }

    @Test func processWithoutOutputCallbackStillReturnsBothStreams() async throws {
        let result = try await ProcessRunner().run("/bin/sh",
            ["-c", "printf 'legacy-out'; printf 'legacy-err' >&2; exit 7"], timeout: .seconds(5))
        #expect(result.status == 7)
        #expect(String(decoding: result.stdout, as: UTF8.self) == "legacy-out")
        #expect(result.stderr == "legacy-err")
    }
}

// The callback can arrive concurrently from the two pipe readers.
private final class CheckTimeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }
    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct CheckTimeFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest
    var root: URL { base.leases.root }
    var action: URL { root.appendingPathComponent("action-ran") }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(20))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(20))
            try #require(head.status == 0)
            let pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                headRef: "feature", baseRef: "main", body: "", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            let gh = base.leases.root.appendingPathComponent("gh")
            let script = """
            #!/bin/sh
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '%s\\n' '{"headRefOid":"\(pr.headSha)","state":"OPEN"}'
            fi
            exit 0
            """
            try script.write(to: gh, atomically: true, encoding: .utf8)
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

    func start(checks: [[String]], timeout: Duration, agentMove: Bool = false,
               command: [String]? = nil, environment: [String: String] = [:]) async throws -> UUID {
        let move = agentMove ? "fix" : "merge"
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": [String: String](), "fixed": "Fixed:", "moves": [], "dispatch": [:],
            "checks": ["beforeSession": agentMove ? checks : [["/usr/bin/false"]],
                       "beforeMerge": agentMove ? [["/usr/bin/false"]] : checks]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let actionCommand = ["/bin/sh", "-c", "touch \"$ACTION_FILE\""]
        let candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: pr.headSha),
            agent: agentMove ? "synthetic" : nil, prompt: agentMove ? "TASK" : nil,
            command: agentMove ? nil : command ?? actionCommand, postComment: false, timeout: timeout)
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
            agents: ["synthetic": AgentTemplate(argv: actionCommand)],
            environment: environment.merging(["ACTION_FILE": action.path]) { _, new in new })
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start") }
        return try #require(store.all().first?.id)
    }

    func log(_ id: UUID) -> String {
        (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? ""
    }

    func finished(_ id: UUID) async throws -> Job {
        let ended = try await Self.poll(for: .seconds(60)) {
            store.all().contains { $0.id == id && $0.status != .running }
        }
        if !ended {
            await dispatcher.stop(id)
            _ = try await Self.poll(for: .seconds(5)) {
                store.all().contains { $0.id == id && $0.status != .running }
            }
        }
        try #require(ended, "Job must finish within the bounded acceptance deadline")
        return try #require(store.all().first { $0.id == id })
    }

    static func poll(for duration: Duration, until condition: () -> Bool) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while clock.now < deadline {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(25))
        }
        return condition()
    }
}
