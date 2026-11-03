@testable import BtonCore
import Foundation
import Testing

private enum ProofFixture {
    static let argv = ["test", "{repo}", "{number}", "{head}", "{base}", "{issue}", "{tier}"]
    static func data(empty: String? = nil) throws -> Data {
        var intake: [String: Any] = ["search": ["repo:{repo}", "is:issue", "is:open", "no:assignee", "label:stage:ready"],
            "claim": [["claim", "{issue}"]], "worktree": ["worktree", "{issue}"],
            "worktreePath": ".worktrees/issue-{issue}", "priority": ["priority:high"],
            "type": ["default": "feat", "labels": [:]] as [String: Any],
            "agent": "claude", "prompt": "Implement {issue}"]
        intake["proof"] = empty == "intake" ? [[]] : [["test", "{repo}", "{issue}", "{base}", "{type}"]]
        return try FlowFixture.data("sandbox", overrides: [
            "dispatch": ["review": ["agent": "claude", "prompt": "Review", "proof": empty == "dispatch" ? [[]] : [argv]]],
            "intake": intake
        ])
    }
}

@Suite(ProcessBound())
struct ProofAcceptanceTests {
    @Test func flowDecodesProofForDispatchAndIntake() throws {
        let flow = try #require(Flow.load(ProofFixture.data()).flow)
        #expect(flow.dispatch["review"]?.proof == [ProofFixture.argv])
        #expect(flow.intake?.proof == [["test", "{repo}", "{issue}", "{base}", "{type}"]])
    }

    @Test(arguments: ["dispatch", "intake"])
    func flowRefusesAnEmptyProofArgvWithItsLocation(section: String) throws {
        guard case let .invalid(reason) = Flow.load(try ProofFixture.data(empty: section)) else {
            Issue.record("Empty proof argv must be invalid"); return
        }
        #expect(reason.contains(section == "dispatch" ? "dispatch.review.proof[0]: empty" : "intake.proof[0]: empty"))
    }

    @Test func pullRequestCandidateFillsProofWithMovePlaceholders() throws {
        let flow = try #require(Flow.load(ProofFixture.data()).flow)
        let pr = try FlowFixture.pr(tier: "quick fix", assignees: [], author: "me", base: "main")
        let candidate = try #require(DispatchPlanner.candidates([pr], flow: flow, me: "me", repo: pr.repo).first)
        // Spec: PR moves fill through `DispatchPlanner.fill(_:repo:number:head:base:issue:tier:redChecks:)`,
        // which keeps a placeholder it has no value for as written (a PR move has no issue).
        #expect(candidate.proof == [["test", pr.repo, "325", pr.headSha, "main", "{issue}", "quick fix"]])
    }

    @Test func implementCandidateFillsProofWithIntakePlaceholders() throws {
        let flow = try #require(Flow.load(ProofFixture.data()).flow)
        let intake = try #require(flow.intake)
        let candidate = try CriterionFixture.candidate(CriterionFixture.issue(), intake: intake)
        #expect(candidate.proof == [["test", "synthetic/project", "7", "main", "feat"]])
    }

    @Test(arguments: [Int32(0), 1, 127, -1])
    func proofDetailFunctionsDistinguishAlreadyGreenStillRedAndUnrun(status: Int32) {
        #expect(Proof.beforeDetail(["swift", "test"], status: status, head: "abcdef12345")
            == (status == 0 ? "proves nothing: `swift test` already passes on abcdef1" : nil))
        #expect(Proof.afterDetail(["swift", "test"], status: status)
            == (status == 0 ? nil : "proof still red: `swift test` exited \(status)"))
        #expect(Proof.unrunDetail(["swift", "test"], reason: "timed out") == "proof: `swift test` timed out")
    }

    @Test(arguments: [
        ("proves nothing: `test` already passes on abcdef1", "escalate", "the proof command passes before the work: nothing shows the problem; sharpen the issue or the findings, then press Retry"),
        ("proof still red: `test` exited 1", "none", "the agent pushed but the proof still fails: the new head gets its own move"),
        ("proof: `test` not found", "escalate", "the proof command could not run on this Mac: fix what the detail names, then press Retry")
    ])
    func supervisorHasTheSpecifiedAnswerForEachProofFailure(detail: String, action: String, note: String) throws {
        let answer = try #require(Supervision.knownAnswer(for: WatchdogFixture.job(detail: detail)))
        #expect(answer.action.rawValue == action)
        #expect(answer.note == note)
    }

    @Test(arguments: ["already-green", "red-then-green", "still-red"])
    func dispatcherRefusesGreenBeforeWorkAndRequiresGreenAfterImplement(scenario: String) async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let root = f.leases.root
        let gh = root.appendingPathComponent("gh")
        try FileManager.default.moveItem(at: gh, to: root.appendingPathComponent("gh-original"))
        try """
        #!/bin/sh
        case "$1 $2" in
          'issue view') printf '{"state":"OPEN","labels":[{"name":"stage:ready"}],"assignees":[]}'; exit 0;;
          'pr list') printf '[{"number":90,"isDraft":false}]'; exit 0;;
        esac
        exec "${0%/*}/gh-original" "$@"
        """.write(to: gh, atomically: true, encoding: .utf8)
        let proof = root.appendingPathComponent("proof")
        let ran = root.appendingPathComponent("agent-started")
        try """
        #!/bin/sh
        \(scenario == "already-green" ? "exit 0" : scenario == "still-red" ? "exit 1" : "test -f '\(ran.path)'")
        """.write(to: proof, atomically: true, encoding: .utf8)
        let agent = root.appendingPathComponent("agent")
        try """
        #!/bin/sh
        touch '\(ran.path)'
        printf 'Opened PR #90\\n'
        """.write(to: agent, atomically: true, encoding: .utf8)
        for script in [gh, proof, agent] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        }
        let terms = try #require(IssueIntake.terms(["no:assignee", "label:stage:ready"], repo: f.leases.repo))
        let plan = IntakePlan(issue: 7, base: "main", terms: terms, claim: [["/usr/bin/true"]],
            worktree: ["/usr/bin/git", "worktree", "add", "-b", "issue-7", ".worktrees/issue-7", "main"],
            worktreePath: ".worktrees/issue-7")
        var candidate = DispatchCandidate(target: .issue(plan),
            move: Move(name: "implement", owner: "me", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: f.leases.repo, item: "issue-7", move: "implement", head: ""),
            agent: "claude", prompt: "Implement", command: nil, postComment: false, timeout: .seconds(30))
        candidate.skipsChecks = true
        candidate.proof = [[proof.path]]
        let github = GitHubClient(ghPath: gh.path)
        let store = try JobStore(home: f.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "proof-test", host: "fixture", github: github,
            remoteURL: { _ in remote })
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: store, log: { _ in })
        let outcome = await dispatcher.dispatch(candidate, clone: f.clone, flow: nil,
            agents: ["claude": AgentTemplate(argv: [agent.path])])
        guard case .started = outcome else { Issue.record("Expected proof job to start"); return }
        var ended: Job?
        for _ in 0..<400 {
            ended = store.all().first { $0.status != .running }
            if ended != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if ended == nil { for job in store.all() { await dispatcher.stop(job.id) } }
        let job = try #require(ended, "Proof job must finish")
        #expect(job.status == (scenario == "red-then-green" ? .succeeded : .failed))
        if scenario == "already-green" {
            #expect(job.detail?.hasPrefix("proves nothing: ") == true)
            #expect(!FileManager.default.fileExists(atPath: ran.path))
        } else if scenario == "still-red" {
            #expect(job.detail == "proof still red: `\(proof.path)` exited 1")
        }
    }
}
