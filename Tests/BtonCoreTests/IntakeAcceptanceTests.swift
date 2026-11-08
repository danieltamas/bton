import Foundation
import Testing
@testable import BtonCore

// Expectations come from FLOW.md Intake and ARCHITECTURE.md Issue intake.
enum IntakeAcceptanceFixture {
    static let repo = "synthetic/project"
    static let agents = ["claude": AgentTemplate(argv: ["/usr/bin/true"])]
    static func issue(_ n: Int = 7, labels: [String] = ["stage:ready"],
                      association: String = "MEMBER", assignees: [String] = [], age: Double = 0,
                      comments: [IssueComment] = []) -> OpenIssue {
        OpenIssue(repo: repo, number: n, title: "UNTRUSTED_TITLE", url: URL(string: "https://github.com/\(repo)/issues/\(n)")!,
                  createdAt: Date(timeIntervalSince1970: 1000 - age), author: "author", authorAssociation: association,
                  body: "UNTRUSTED_BODY", comments: comments, labels: labels, assignees: assignees)
    }
    static func intake(search: [String] = ["repo:{repo}", "is:issue", "is:open", "no:assignee", "label:stage:ready"],
                       path: String = ".worktrees/issue-7", type: String = "feat") throws -> Intake {
        let object: [String: Any] = ["search": search, "priority": ["priority:low", "priority:high", "priority:medium"],
            "claim": [["claim", "{issue}", "{repo}", "{base}", "{type}"]],
            "worktree": ["worktree", "{issue}", "{repo}", "{base}", "{type}"], "worktreePath": path,
            "type": ["default": type, "labels": ["bug": "fix", "docs": "docs"]], "agent": "claude",
            "prompt": "{issue} {repo} {base} {type}"]
        return try JSONDecoder().decode(Intake.self, from: JSONSerialization.data(withJSONObject: object))
    }
    static func candidate(_ issues: [OpenIssue] = [issue()], intake: Intake? = nil, caps: Caps? = nil,
                          prs: [PullRequest] = [], jobs: [Job] = [], base: String = "main",
                          agents: [String: AgentTemplate] = agents) throws -> DispatchCandidate? {
        IssueIntake.candidate(issues: issues, intake: try intake ?? self.intake(), caps: caps, pullRequests: prs,
                              jobs: jobs, repo: repo, base: base, me: "me", agents: agents)
    }
    static func plan(_ candidate: DispatchCandidate?) throws -> IntakePlan {
        guard case let .issue(plan) = try #require(candidate).target else {
            throw NSError(domain: "Expected intake target", code: 1)
        }
        return plan
    }
    static func job(_ n: Int = 7, status: Job.Status = .failed, retry: Bool? = nil,
                    time: Double = 100, repo: String = repo, move: String = "implement") -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: "issue-\(n)", move: move, head: ""), agent: "claude",
            startedAt: Date(timeIntervalSince1970: time), status: status, retry: retry)
    }
    static func pr(_ n: Int = 1, author: String = "me") -> PullRequest {
        PullRequest(repo: repo, number: n, title: "PR", author: author, authorAssociation: "MEMBER",
                    url: URL(string: "https://github.com/\(repo)/pull/\(n)")!, headSha: "abc", headRef: "feature",
                    baseRef: "main", body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .distantPast)
    }
}

@Suite struct IntakeAcceptanceTests {
    typealias F = IntakeAcceptanceFixture

    @Test func noPRCommentKeepsWholeLastLinesWithinFourHundredCharacters() throws {
        let omitted = String(repeating: "a", count: 180)
        let kept = [String(repeating: "b", count: 190), String(repeating: "c", count: 190)]
        let body = IssueIntake.noPRComment(report: omitted + "\n\n" + kept.joined(separator: "\n") + "\n \t\n",
                                          branch: "issue-7")
        let heading = "Bton: the build of this issue ended without a pull request (branch `issue-7`); the issue is back at stage:ready. The agent's last words:"
        let marker = BtonMarker.line("implement-failed issue-7")
        #expect(body.hasPrefix(heading + "\n"))
        #expect(body.hasSuffix(marker))
        let excerpt = String(body.dropFirst(heading.count).dropLast(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(excerpt.count <= 400)
        #expect(excerpt.hasPrefix("..."))
        #expect(excerpt.hasSuffix(kept.joined(separator: "\n")))
        #expect(!excerpt.contains("a"))
        #expect(excerpt.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").map(String.init) == kept)
    }

    @Test func noPRCommentKeepsAnExactlyFourHundredCharacterReport() {
        let report = String(repeating: "a", count: 190) + "\n" + String(repeating: "b", count: 209)
        let body = IssueIntake.noPRComment(report: report, branch: "issue-7")
        #expect(body.contains("\n" + report + "\n"))
        #expect(!body.contains("..."))
        #expect(body.hasSuffix(BtonMarker.line("implement-failed issue-7")))
    }

    @Test func noPRCommentCountsTheOmissionLineWithinFourHundredCharacters() throws {
        let older = "This older line must be omitted."
        let penultimate = String(repeating: "b", count: 190)
        let last = String(repeating: "c", count: 209)
        let body = IssueIntake.noPRComment(report: [older, penultimate, last].joined(separator: "\n"),
                                          branch: "issue-7")
        let headingEnd = try #require(body.range(of: "The agent's last words:\n"))
        let markerStart = try #require(body.range(of: BtonMarker.line("implement-failed issue-7")))
        let excerpt = body[headingEnd.upperBound..<markerStart.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(excerpt.count <= 400)
        #expect(excerpt == "...\n" + last)
        #expect(!excerpt.contains(older))
        #expect(!excerpt.contains(penultimate))
    }

    @Test(arguments: ["", " \n\t\n"])
    func noPRCommentSaysNoReportForEmptyOutput(report: String) {
        let body = IssueIntake.noPRComment(report: report, branch: "issue-7")
        #expect(body.contains("\nno report\n"))
        #expect(body.hasSuffix(BtonMarker.line("implement-failed issue-7")))
    }

    @Test func implementFailedNoticeMentionIsNotAnAsk() {
        let body = "@me, the build could not continue.\n\n" + BtonMarker.line("implement-failed issue-7")
        let comment = IssueComment(id: "failed-7", author: "teammate", authorAssociation: "MEMBER",
                                   body: body, createdAt: Date(timeIntervalSince1970: 1_001), url: nil)
        #expect(IssueAsks.ask(in: F.issue(comments: [comment]), me: "me") == nil)
    }

    @Test func priorityUsesFlowsListThenAgeWithUnlabelledLast() throws {
        let issues = [F.issue(1, age: 900), F.issue(2, labels: ["stage:ready", "priority:high"], age: 800),
                      F.issue(3, labels: ["stage:ready", "priority:low"], age: 1),
                      F.issue(4, labels: ["stage:ready", "priority:low"], age: 2)]
        #expect(try F.plan(F.candidate(issues)).issue == 4)
        #expect(IssueIntake.ready(issues, priority: ["priority:low", "priority:high"]).map(\.number) == [4, 3, 2, 1])
    }

    @Test(arguments: ["OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "FIRST_TIMER", "FIRST_TIME_CONTRIBUTOR", "NONE"])
    func onlyTrustedAuthors(association: String) throws {
        let allowed = ["OWNER", "MEMBER", "COLLABORATOR"].contains(association)
        #expect(try (F.candidate([F.issue(association: association)]) != nil) == allowed)
    }

    @Test func supportedSearchTermsFilterIssues() throws {
        let rule = try F.intake(search: ["repo:synthetic/project", "is:issue", "is:open", "no:assignee", "label:stage:ready", "-label:blocked"])
        let issues = [F.issue(1, labels: ["stage:ready", "blocked"], age: 100),
                      F.issue(2, assignees: ["person"], age: 90), F.issue(3, labels: [], age: 80), F.issue(4)]
        #expect(try F.plan(F.candidate(issues, intake: rule)).issue == 4)
        #expect(try F.candidate(intake: F.intake(search: ["repo:other/repo"])) == nil)
    }

    @Test(arguments: ["author:me", "is:closed", "is:pr", "hello", "label:needs help", "-label:needs help"])
    func unsupportedSearchFailsClosed(term: String) throws {
        #expect(try F.candidate(intake: F.intake(search: [term])) == nil)
    }

    @Test func requiresAgentBaseAndNoRunningImplementInRepo() throws {
        #expect(try F.candidate(agents: [:]) == nil)
        #expect(try F.candidate(base: "") == nil)
        #expect(try F.candidate(jobs: [F.job(9, status: .running)]) == nil)
        #expect(try F.candidate(jobs: [F.job(9, status: .running, repo: "other/repo")]) != nil)
    }

    @Test func capsUseStrictBoundariesAndNilIsUncapped() throws {
        let caps = Caps(openPullRequestsPerDeveloper: 2, openPullRequestsTeam: 3)
        #expect(try F.candidate(caps: caps, prs: [F.pr()]) != nil)
        #expect(try F.candidate(caps: caps, prs: [F.pr(), F.pr(2)]) == nil)
        #expect(try F.candidate(caps: caps, prs: [F.pr(author: "other"), F.pr(2, author: "other"), F.pr(3, author: "other")]) == nil)
        #expect(try F.candidate(caps: nil, prs: (1...10).map { F.pr($0) }) != nil)
    }

    @Test(arguments: [Job.Status.failed, .cancelled, .succeeded])
    func usedKeyIsSkippedForNextIssue(status: Job.Status) throws {
        #expect(try F.plan(F.candidate([F.issue(7, age: 10), F.issue(8)], jobs: [F.job(status: status)])).issue == 8)
    }

    @Test func substitutionsAndFirstMappedIssueLabel() throws {
        let rule = try F.intake()
        let candidate = try #require(try F.candidate([F.issue(labels: ["stage:ready", "docs", "bug"])], intake: rule))
        let plan = try F.plan(candidate)
        #expect(plan.claim == [["claim", "7", F.repo, "main", "docs"]])
        #expect(plan.worktree == ["worktree", "7", F.repo, "main", "docs"])
        #expect(plan.worktreePath == ".worktrees/issue-7")
        // The prompt ends with the criterion line (spec 2026-11-03 pullboard lessons, section 2).
        #expect(candidate.prompt == "7 synthetic/project main docs\n\n" + IssueIntake.criterionLine)
        #expect(try F.candidate()?.prompt == "7 synthetic/project main feat\n\n" + IssueIntake.criterionLine)
    }

    @Test func worktreePathSubstitutesAllFourTokens() throws {
        let rule = try F.intake(path: ".worktrees/{type}/{base}/{repo}/{issue}")
        let plan = try F.plan(F.candidate([F.issue(labels: ["stage:ready", "docs"])], intake: rule))
        #expect(plan.worktreePath == ".worktrees/docs/main/synthetic/project/7")
    }

    @Test(arguments: ["/tmp/fix", "..", "{unknown}", "bad type", "fix;touch"])
    func unsafeTypeRefusesCandidate(type: String) throws {
        #expect(try F.candidate(intake: F.intake(type: type)) == nil)
    }

    @Test(arguments: ["/tmp/tree", "../tree", "trees/../tree", "trees/{unknown}"])
    func unsafePathRefusesCandidate(path: String) throws {
        #expect(try F.candidate(intake: F.intake(path: path)) == nil)
    }

    @Test func retriedClaimedIssueResumesAfterReadyLabelIsGone() throws {
        let job = F.job(retry: true)
        let plan = try F.plan(F.candidate([F.issue(labels: ["stage:in-progress"], assignees: ["me"])], jobs: [job]))
        #expect(plan.resumes)
        let failed = F.job()
        #expect(failed.canRetry(among: [failed]))
    }

    @Test func standingClaimsOnlyWhileSearchStillMatches() throws {
        let plan = try F.plan(F.candidate())
        #expect(IssueIntake.standing(of: IssueNow(state: "OPEN", labels: ["stage:ready"], assignees: []), plan: plan, me: "me") == .claim)
        for now in [IssueNow(state: "CLOSED", labels: ["stage:ready"], assignees: []),
                    IssueNow(state: "OPEN", labels: [], assignees: []),
                    IssueNow(state: "OPEN", labels: ["stage:ready"], assignees: ["other"])] {
            guard case .refuse = IssueIntake.standing(of: now, plan: plan, me: "me") else {
                Issue.record("Changed issue must be refused"); continue
            }
        }
    }

    @Test func resumingStandingResumesMineClaimsFreeAndRefusesOthersOrClosed() throws {
        var plan = try F.plan(F.candidate())
        plan.resumes = true
        #expect(IssueIntake.standing(of: IssueNow(state: "OPEN", labels: ["stage:in-progress"], assignees: ["me"]), plan: plan, me: "me") == .resume)
        #expect(IssueIntake.standing(of: IssueNow(state: "OPEN", labels: ["stage:ready"], assignees: []), plan: plan, me: "me") == .claim)
        for now in [IssueNow(state: "CLOSED", labels: [], assignees: ["me"]),
                    IssueNow(state: "OPEN", labels: ["stage:ready"], assignees: ["other"])] {
            guard case .refuse = IssueIntake.standing(of: now, plan: plan, me: "me") else {
                Issue.record("Retry must not claim a closed or somebody else's issue"); continue
            }
        }
    }

    @Test func readyIncludesTakenIssuesAndEveryInProgressOne() {
        let issues = [F.issue(1, labels: ["stage:ready", "priority:high"], assignees: ["other"]),
                      F.issue(2, labels: ["stage:ready", "priority:high"], age: 10), F.issue(3),
                      F.issue(4, labels: ["stage:in-progress"]), F.issue(5, labels: ["stage:in-progress"])]
        let ready = IssueIntake.ready(issues, jobs: [F.job(4)])
        // Owner decision 2026-10-27: a teammate's in-progress issue shows too, against two people starting one.
        #expect(ready.map(\.number) == [2, 1, 3, 4, 5])
        #expect(ready.first { $0.number == 1 }?.assignees == ["other"])
    }

    @Test func heldUsesLatestImplementJobOnly() {
        let jobs = [F.job(1, status: .running), F.job(2), F.job(3, status: .cancelled), F.job(4, status: .succeeded),
                    F.job(5), F.job(5, status: .succeeded, time: 200), F.job(6, status: .succeeded), F.job(6, time: 200),
                    F.job(7, repo: "other/repo"), F.job(8, move: "draft")]
        let held = (1...8).filter { IssueIntake.held(F.issue($0, labels: ["stage:spec"]), jobs: jobs.reversed()) }
        #expect(held == [1, 2, 3, 6])
    }

    @Test func heldEndsOnceTheIssueIsRelabeledAfterTheJob() {
        var failed = F.job(7)
        failed.endedAt = Date(timeIntervalSince1970: 150)
        func issue(relabeledAt time: Double) -> OpenIssue {
            let seed = F.issue(labels: ["stage:spec"])
            return OpenIssue(repo: seed.repo, number: seed.number, title: seed.title, url: seed.url, createdAt: seed.createdAt,
                             author: seed.author, authorAssociation: seed.authorAssociation, body: seed.body, comments: [],
                             labels: seed.labels, labelEvents: [LabelEvent(kind: .added, label: "stage:spec", at: Date(timeIntervalSince1970: time))])
        }
        // The agent's own hand-back lands before the job ends: the report is still to be read.
        #expect(IssueIntake.held(issue(relabeledAt: 140), jobs: [failed]))
        // Someone acted on it afterwards (made it a tracker, sent it to spec): the card goes.
        #expect(!IssueIntake.held(issue(relabeledAt: 200), jobs: [failed]))
        #expect(IssueIntake.ready([issue(relabeledAt: 200)], jobs: [failed]).isEmpty)
    }

    @Test func issueAliasesMergeWithoutDuplicatesAndDecodeAssignees() throws {
        func node(_ n: Int) -> [String: Any] {
            ["number": n, "title": "Issue", "url": "https://github.com/\(F.repo)/issues/\(n)",
             "createdAt": "2026-10-01T00:00:00Z", "body": "", "authorAssociation": "MEMBER",
             "author": ["login": "author"], "labels": ["nodes": [["name": "stage:ready"]]],
             "assignees": ["nodes": [["login": "me"]]], "comments": ["nodes": []]]
        }
        let first = (1...50).map(node)
        for aliases in [false, true] {
            var repository: [String: Any] = ["issues": ["nodes": first]]
            if aliases {
                repository["ready"] = ["nodes": [node(1), node(51)]]
                repository["inProgress"] = ["nodes": [node(51), node(52)]]
            }
            let data = try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]])
            let issues = try GitHubClient.decodeOpenIssues(data, repo: F.repo).issues
            #expect(issues.count == (aliases ? 52 : 50))
            #expect(Set(issues.map(\.number)) == Set(1...(aliases ? 52 : 50)))
            #expect(issues.allSatisfy { $0.assignees == ["me"] })
        }
    }

    @Test func plannerGivesPRAndScheduleTurnsBeforeIntake() throws {
        let intake = try #require(try F.candidate())
        let pr = DispatchCandidate(target: .pullRequest(F.pr()), move: Move(name: "fix", owner: "me", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: F.repo, item: "pr-1", move: "fix", head: "abc"), agent: "claude", prompt: "fix", command: nil, postComment: false, timeout: .seconds(60))
        let schedule = DispatchCandidate(target: .branch("main"), move: Move(name: "schedule", owner: "me", ownerFromRotation: false, tier: "", hasDispatch: true),
            key: JobKey(repo: F.repo, item: "schedule-1", move: "schedule", head: "minute"), agent: "claude", prompt: "schedule", command: nil, postComment: false, timeout: .seconds(60))
        for earlier in [pr, schedule] {
            #expect(DispatchPlanner.select([intake, earlier], jobs: [], maxAgents: 1, agents: F.agents).map(\.key) == [earlier.key])
        }
        #expect(DispatchPlanner.select([schedule], jobs: [F.job(status: .running)], maxAgents: 2, agents: F.agents).map(\.key) == [schedule.key])
    }

    @Test func newestBranchPRReportsDraftAndEmptyIsNil() throws {
        let data = Data(#"[{"number":9,"isDraft":false},{"number":30,"isDraft":true},{"number":12,"isDraft":false}]"#.utf8)
        #expect(try GitHubClient.decodeBranchPullRequest(data) == BranchPullRequest(number: 30, isDraft: true))
        #expect(try GitHubClient.decodeBranchPullRequest(Data("[]".utf8)) == nil)
    }
}
