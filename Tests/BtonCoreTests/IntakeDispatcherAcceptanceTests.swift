import Foundation
import Testing
@testable import BtonCore

@Suite(ProcessBound())
struct IntakeDispatcherAcceptanceTests {
    @Test(arguments: [false, true])
    func noPRPostsTheReasonBeforeGivingBackTheIssue(commentFails: Bool) async throws {
        try await assertNoPRGiveBack(commentFails: commentFails)
    }

    @Test func noPRAlreadyReportedStillGivesBackTheIssueWithoutAnotherComment() async throws {
        try await assertNoPRGiveBack(alreadyPosted: true)
    }

    @Test func noPRLeavesAnIssueAssignedToSomeoneElseAlone() async throws {
        try await assertNoPRGiveBack(assignee: "other")
    }

    private func assertNoPRGiveBack(commentFails: Bool = false, alreadyPosted: Bool = false,
                                   assignee: String = "me") async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let root = f.leases.root
        let gh = root.appendingPathComponent("gh")
        let calls = root.appendingPathComponent("intake-outcome-calls")
        let posted = root.appendingPathComponent("intake-comment.md")
        let comments: [[String: Any]] = alreadyPosted ? [[
            "id": "IC_failed", "author": ["login": "me"],
            "body": BtonMarker.line("implement-failed main"),
            "createdAt": "2026-11-03T08:00:00Z", "url": NSNull()
        ]] : []
        try JSONSerialization.data(withJSONObject: ["comments": comments])
            .write(to: root.appendingPathComponent("intake-comments.json"))
        try Data().write(to: calls)
        try FileManager.default.moveItem(at: gh, to: root.appendingPathComponent("gh-original"))
        try """
        #!/bin/sh
        case "$1 $2" in
          'api user') printf 'me'; exit 0 ;;
          'pr list') printf '[]'; exit 0 ;;
          'issue view')
            case "$*" in
              *'--json comments'*) cat "${0%/*}/intake-comments.json"; exit 0 ;;
            esac
            printf '{"state":"OPEN","labels":[{"name":"stage:in-progress"}],"assignees":[{"login":"\(assignee)"}]}'
            exit 0 ;;
          'issue comment')
            printf '%s\\n' "$*" >> "${0%/*}/intake-outcome-calls"
            while [ "$#" -gt 0 ]; do
              if [ "$1" = '--body-file' ]; then cp "$2" "${0%/*}/intake-comment.md"; break; fi
              shift
            done
            \(commentFails ? "echo 'comment unavailable' >&2; exit 17" : "exit 0") ;;
          'issue edit')
            printf '%s\\n' "$*" >> "${0%/*}/intake-outcome-calls"
            exit 0 ;;
        esac
        exec "${0%/*}/gh-original" "$@"
        """.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let github = GitHubClient(ghPath: gh.path)
        let store = try JobStore(home: f.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "intake-test", host: "fixture", github: github,
                                    remoteURL: { _ in remote })
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: store, log: { _ in })
        let job = Job(id: UUID(), key: JobKey(repo: f.leases.repo, item: "issue-7", move: "implement", head: ""),
                      agent: "claude", worktree: f.clone.path, startedAt: .now, status: .running)
        let report = "The build stopped because the schema decision needs @me."
        try report.write(to: store.outputURL(job.id), atomically: true, encoding: .utf8)

        let outcome = await dispatcher.intakeOutcome(of: job)

        #expect(outcome.status == .failed)
        let detail = try #require(outcome.detail)
        let original = "the agent finished without opening a PR for main; its report says why"
        if assignee != "me" {
            #expect(detail == original + "; the issue is assigned to @other now, left as it is")
        } else if alreadyPosted {
            #expect(detail == original + ", already said so on the issue")
        } else if commentFails {
            #expect(detail.hasPrefix(original + "; could not say so on the issue: "))
            #expect(detail.contains("comment unavailable"))
        } else {
            #expect(detail == original + ", said so on the issue")
        }
        let order = try String(contentsOf: calls, encoding: .utf8).split(separator: "\n").map(String.init)
        if assignee != "me" {
            #expect(order.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: posted.path))
            return
        }
        let edit = "issue edit 7 --repo \(f.leases.repo) --add-label stage:ready --remove-label stage:in-progress --remove-assignee @me"
        if alreadyPosted {
            #expect(order == [edit])
            #expect(!FileManager.default.fileExists(atPath: posted.path))
            return
        }
        try #require(order.count == 2)
        #expect(order[0].hasPrefix("issue comment 7 --repo \(f.leases.repo) --body-file "))
        #expect(order[1] == edit)
        let body = try String(contentsOf: posted, encoding: .utf8)
        #expect(body.contains(report))
        #expect(body.hasSuffix(BtonMarker.line("implement-failed main")))
    }

    @Test(arguments: ["claim-first", "claim-fails", "existing", "resume", "changed"])
    func dispatcherHonoursClaimAndWorktreeBoundaries(scenario: String) async throws {
        let f = try await SupervisionRunFixture.make()
        defer { try? FileManager.default.removeItem(at: f.leases.root) }
        let fm = FileManager.default
        let root = f.leases.root
        let tree = f.clone.appendingPathComponent(".worktrees/issue-7")
        let calls = root.appendingPathComponent("intake-order")
        let state = root.appendingPathComponent("issue-now.json")
        func writeState(_ assigned: [String], ready: Bool = true) throws {
            let object: [String: Any] = ["state": "OPEN", "labels": [["name": ready ? "stage:ready" : "stage:in-progress"]],
                                       "assignees": assigned.map { ["login": $0] }]
            try JSONSerialization.data(withJSONObject: object).write(to: state)
        }
        try writeState(scenario == "resume" ? ["me"] : scenario == "changed" ? ["other"] : [], ready: scenario != "resume")
        let gh = root.appendingPathComponent("gh")
        try fm.moveItem(at: gh, to: root.appendingPathComponent("gh-original"))
        try """
        #!/bin/sh
        if [ "$1 $2" = 'issue view' ]; then cat '${0%/*}/issue-now.json'; exit 0; fi
        if [ "$1 $2" = 'pr list' ]; then printf '[{"number":90,"isDraft":false}]'; exit 0; fi
        exec "${0%/*}/gh-original" "$@"
        """.replacingOccurrences(of: "'${0%/*}/issue-now.json'", with: "\"${0%/*}/issue-now.json\"")
            .write(to: gh, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let claim = root.appendingPathComponent("claim")
        try """
        #!/bin/sh
        printf 'claim\\n' >> '\(calls.path)'
        exit \(scenario == "claim-fails" ? 17 : 0)
        """.write(to: claim, atomically: true, encoding: .utf8)
        let worktree = root.appendingPathComponent("worktree")
        try """
        #!/bin/sh
        printf 'worktree\\n' >> '\(calls.path)'
        exec /usr/bin/git worktree add -b issue-7 .worktrees/issue-7 main
        """.write(to: worktree, atomically: true, encoding: .utf8)
        for script in [claim, worktree] { try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path) }
        if scenario == "existing" || scenario == "resume" {
            let made = try await ProcessRunner().run("/usr/bin/git", ["worktree", "add", "-b", "issue-7", tree.path, "main"], in: f.clone, timeout: .seconds(30))
            try #require(made.status == 0)
            try Data("preserve me".utf8).write(to: tree.appendingPathComponent("owner-work"))
        }
        let terms = try #require(IssueIntake.terms(["no:assignee", "label:stage:ready"], repo: f.leases.repo))
        let plan = IntakePlan(issue: 7, base: "main", terms: terms, claim: [[claim.path]], worktree: [worktree.path],
                              worktreePath: ".worktrees/issue-7", resumes: scenario == "resume")
        var candidate = DispatchCandidate(target: .issue(plan),
            move: Move(name: "implement", owner: "me", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: f.leases.repo, item: "issue-7", move: "implement", head: ""), agent: "claude",
            prompt: "Synthetic intake", command: nil, postComment: false, timeout: .seconds(30))
        candidate.skipsChecks = true
        let github = GitHubClient(ghPath: gh.path)
        let store = try JobStore(home: f.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: f.home, holder: "intake-test", host: "fixture", github: github, remoteURL: { _ in remote })
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: store, log: { _ in })
        let agents = ["claude": AgentTemplate(argv: ["/usr/bin/true"])]
        let outcome = await dispatcher.dispatch(candidate, clone: f.clone, flow: nil, agents: agents)
        if scenario == "changed" {
            if case .started = outcome { Issue.record("Changed issue must not start a job") }
            #expect(store.all().isEmpty)
            #expect(!fm.fileExists(atPath: calls.path))
            #expect(!fm.fileExists(atPath: tree.path))
            // Restore the issue and dispatch the SAME key: refusal must not burn it.
            try writeState([])
            let again = await dispatcher.dispatch(candidate, clone: f.clone, flow: nil, agents: agents)
            guard case .started = again else { Issue.record("Refused standing used up the key"); return }
        } else {
            guard case .started = outcome else { Issue.record("Fixture must reach the job boundary"); return }
        }
        var ended: Job?
        for _ in 0..<400 {
            ended = store.all().first { $0.status != .running }
            if ended != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        if ended == nil { for job in store.all() { await dispatcher.stop(job.id) } }
        let job = try #require(ended, "Intake must finish its synthetic job")
        let order = fm.fileExists(atPath: calls.path) ? try String(contentsOf: calls, encoding: .utf8) : ""
        switch scenario {
        case "existing":
            #expect(job.status == .failed)
            #expect(order.isEmpty)
            #expect(try String(contentsOf: tree.appendingPathComponent("owner-work"), encoding: .utf8) == "preserve me")
        case "claim-fails":
            #expect(job.status == .failed)
            #expect(order == "claim\n")
            #expect(!fm.fileExists(atPath: tree.path))
        case "resume":
            #expect(order.isEmpty)
            #expect(job.worktree == tree.path)
            #expect(job.status == .succeeded)
            #expect(try String(contentsOf: tree.appendingPathComponent("owner-work"), encoding: .utf8) == "preserve me")
        default:
            #expect(order == "claim\nworktree\n")
            #expect(job.status == .succeeded)
            #expect(fm.fileExists(atPath: tree.appendingPathComponent(".git").path))
        }
    }
}
