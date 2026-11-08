@testable import BtonCore
import Foundation
import Testing

private enum IssueMovesFixture {
    static let agents = ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"]),
                         "codex": AgentTemplate(argv: ["codex", "exec", "{prompt}"])]
    static let me = "dani"
    static let repo = "synthetic/project"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func comment(_ id: String, author: String, hoursAgo: Double, body: String = "COMMENT_BODY_DATA") -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: body,
                     createdAt: now.addingTimeInterval(-hoursAgo * 3600), url: nil)
    }

    static func issue(_ number: Int = 7, labels: [String] = [], assignees: [String] = [], association: String = "MEMBER",
                      daysOld: Double = 10, comments: [IssueComment] = [], labelEvents: [LabelEvent] = []) -> OpenIssue {
        OpenIssue(repo: repo, number: number, title: "ISSUE_TITLE_DATA", url: URL(string: "https://example.invalid/issues/\(number)")!,
                  createdAt: now.addingTimeInterval(-daysOld * 86400), author: "lee", authorAssociation: association,
                  body: "ISSUE_BODY_DATA", comments: comments, labels: labels, assignees: assignees, labelEvents: labelEvents)
    }

    static func pr(body: String) -> PullRequest {
        PullRequest(repo: repo, number: 90, title: "Synthetic PR", author: "lee", authorAssociation: "MEMBER",
                    url: URL(string: "https://example.invalid/pr/90")!, headSha: "d67db2a8d67db2a8", headRef: "work", baseRef: "main",
                    body: body, isDraft: false, labels: [], assignees: [], comments: [], updatedAt: now)
    }

    static let rules = """
    [{"move":"triage","when":["no_label:priority:","no_assignee"]},
     {"move":"stage","when":["label:priority:","label:stage:triage","no_assignee","unassigned_ready_under:3"]},
     {"move":"restage","when":["label:stage:review","no_open_pr","quiet_hours:24"]}]
    """
    static let dispatch = #"{"triage":{"agent":"claude"},"stage":{"agent":"claude","prompt":"Stage #{issue} of {repo} on {base}."},"restage":{"agent":"claude","timeoutMinutes":5}}"#

    static func data(issues: String? = rules, dispatch: String = dispatch, moves: String = "[]") -> Data {
        Data("""
        {"version":1,"base":"develop",
         "tier":{"marker":"Tier:","values":["feature"],"default":"feature"},
         "reviews":{"feature":[{"heading":"## Review:","notByAuthor":true}]},
         "fixed":"## Fixed:","moves":\(moves),"dispatch":\(dispatch)\(issues.map { ",\"issues\":\($0)" } ?? "")}
        """.utf8)
    }

    static func flow(issues: String? = rules, dispatch: String = dispatch) throws -> Flow {
        try #require(Flow.load(data(issues: issues, dispatch: dispatch)).flow)
    }

    static func job(_ key: JobKey, status: Job.Status = .succeeded, hoursAgo: Double = 1, retry: Bool? = nil) -> Job {
        Job(id: UUID(), key: key, agent: "claude", startedAt: now.addingTimeInterval(-hoursAgo * 3600), status: status, retry: retry)
    }

    static func candidate(_ issues: [OpenIssue], flow: Flow? = nil, pullRequests: [PullRequest] = [], jobs: [Job] = [],
                          agents: [String: AgentTemplate] = agents, ranElsewhere: Set<JobKey> = []) throws -> DispatchCandidate? {
        IssueMoves.candidate(issues: issues, flow: try flow ?? Self.flow(), pullRequests: pullRequests, jobs: jobs,
                             repo: repo, me: me, agents: agents, ranElsewhere: ranElsewhere, now: now)
    }

    /// A comment the triager posted for a move, on any Mac: it ends with Bton's hidden marker line.
    static func triagers(_ id: String, author: String, hoursAgo: Double, move: String = "triage") -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: "Impact: 1, because...\n\n" + IssueMoves.marker(for: move),
                     createdAt: now.addingTimeInterval(-hoursAgo * 3600), url: nil)
    }
}

/// The issue moves: a flow's rules over open issues, run under the triager hat, bounded like a
/// decision and read back from GitHub.
struct IssueMovesAcceptanceTests {
    private typealias F = IssueMovesFixture

    @Test func aTwoJobFlowCapRefusesTheThirdIssueJobAndNamesTheCap() throws {
        var json = try #require(JSONSerialization.jsonObject(with: F.data()) as? [String: Any])
        json["caps"] = ["issuesPerDay": 2]
        let flow = try #require(Flow.load(JSONSerialization.data(withJSONObject: json)).flow)
        let jobs = (1...2).map { F.job(IssueMoves.key(repo: F.repo, number: 100 + $0, move: "triage", round: "")) }
        #expect(IssueMoves.hold(jobs: Array(jobs.prefix(1)), repo: F.repo, now: F.now, cap: 2) == nil)
        #expect(try F.candidate([F.issue()], flow: flow, jobs: Array(jobs.prefix(1))) != nil)
        #expect(IssueMoves.hold(jobs: jobs, repo: F.repo, now: F.now, cap: 2) == "2 issue jobs in a day")
        #expect(try F.candidate([F.issue()], flow: flow, jobs: jobs) == nil)
    }

    @Test(arguments: [(2.0, true), (0.5, false)])
    func theFlowCooldownAllowsAnOldTriagerCommentAndHoldsARecentOne(hoursAgo: Double, mayStart: Bool) throws {
        var json = try #require(JSONSerialization.jsonObject(with: F.data()) as? [String: Any])
        json["caps"] = ["issueCooldownHours": 1]
        let flow = try #require(Flow.load(JSONSerialization.data(withJSONObject: json)).flow)
        let issue = F.issue(comments: [F.triagers("triaged", author: "teammate", hoursAgo: hoursAgo)])
        #expect((IssueMoves.cooldownHold(move: "triage", comments: issue.comments, at: F.now, cooldown: 3600) == nil) == mayStart)
        #expect((try F.candidate([issue], flow: flow) != nil) == mayStart)
    }

    @Test(arguments: ["triage", "stage", "restage"])
    func everyIssueMoveCandidateCarriesTheFlowCostCap(move: String) throws {
        let rules = "[{\"move\":\"\(move)\",\"when\":[\"no_assignee\"]}]"
        var json = try #require(JSONSerialization.jsonObject(with: F.data(issues: rules)) as? [String: Any])
        json["caps"] = ["costPerJob": 1.25]
        let flow = try #require(Flow.load(JSONSerialization.data(withJSONObject: json)).flow)
        let candidate = try #require(try F.candidate([F.issue()], flow: flow))
        #expect(candidate.costCap == Decimal(string: "1.25"))
        #expect(try F.candidate([F.issue()])?.costCap == nil)
    }

    @Test(arguments: [false, true])
    func intakeCandidatesCarryTheFlowCostCapWithoutRequiringPRCaps(capped: Bool) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "caps": capped ? ["costPerJob": 1.25] : [:]
        ])).flow)
        let intake = try #require(flow.intake)
        let candidate = try #require(IssueIntake.candidate(
            issues: [F.issue(labels: ["stage:ready"])], intake: intake, caps: flow.caps,
            pullRequests: [F.pr(body: "Unrelated")], jobs: [], repo: F.repo, base: flow.base, me: F.me, agents: F.agents))
        #expect(candidate.costCap == (capped ? Decimal(string: "1.25") : nil))
    }

    @Test(arguments: [false, true])
    func decideCandidatesCarryTheFlowCostCap(capped: Bool) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "caps": capped ? ["costPerJob": 1.25] : [:], "decide": ["by": [F.me]]
        ])).flow)
        let issue = F.issue(comments: [F.comment("ask", author: "lee", hoursAgo: 1, body: "@dani should we choose A or B?")])
        let ask = try #require(IssueAsks.ask(in: issue, me: F.me))
        let candidate = try #require(IssueDecisions.candidate(ask: ask, issue: issue, flow: flow,
            agents: F.agents, defaultBranch: flow.base, me: F.me))
        #expect(candidate.costCap == (capped ? Decimal(string: "1.25") : nil))
    }

    @Test func notDemotedParsesCaseInsensitiveLabelsAndRejectsAnEmptyLabel() {
        #expect(IssuePredicate("not_demoted:Stage:Ready") == .notDemoted(label: "stage:ready", claim: nil))
        #expect(IssuePredicate("not_demoted:Stage:Ready,Stage:In-Progress") == .notDemoted(label: "stage:ready", claim: "stage:in-progress"))
        #expect(IssuePredicate("not_demoted:") == nil)
        // Only these conditions need the issue's whole label history, read on its own.
        #expect(IssueMoves.readsLabelEvents(["label:stage:spec", "not_demoted:stage:ready"]))
        #expect(!IssueMoves.readsLabelEvents(["label:stage:spec", "not_demoted:"]))
        // A whole read's label history outlives a page read while the labels are the same, and
        // only the history: the rest of the issue is the page's.
        typealias I = IntakeAcceptanceFixture
        let removal = LabelEvent(kind: .removed, label: "stage:ready", at: F.now)
        let history = Engine.LabelHistory(of: I.issue(7, labels: ["stage:spec"]).with(labelEvents: [removal]))
        let comment = IssueComment(id: "new", author: "dani", authorAssociation: "OWNER", body: "edited", createdAt: F.now, url: nil)
        let same = I.issue(7, labels: ["Stage:Spec"], comments: [comment]), moved = I.issue(7, labels: ["stage:ready"])
        let kept = Engine.carryingHistories([same, I.issue(8)], [7: history])
        #expect(kept.issues.first?.labelEvents == [removal])
        #expect(kept.issues.first?.comments == [comment])
        #expect(kept.histories == [7: history])
        let dropped = Engine.carryingHistories([moved], [7: history])
        #expect(dropped.histories.isEmpty && dropped.issues.first?.labelEvents.isEmpty == true)
    }

    @Test func anIssueWithNoLabelHistoryIsNotDemoted() {
        let issue = F.issue()
        #expect(issue.labelEvents.isEmpty)
        #expect(IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now).holds(all: ["not_demoted:stage:ready"]))
    }

    @Test(arguments: [-120.0, -3.0, 0.0, 3.0, 120.0])
    func aClaimWithinTwoMinutesBeforeOrAfterRemovalIsNotADemotion(offset: Double) throws {
        let issue = F.issue(labelEvents: [
            LabelEvent(kind: .removed, label: "Stage:Ready", at: F.now),
            LabelEvent(kind: .added, label: "Stage:In-Progress", at: F.now.addingTimeInterval(offset))
        ])
        let predicate = "not_demoted:STAGE:READY,STAGE:IN-PROGRESS"
        #expect(IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now).holds(all: [predicate]))
        let rules = "[{\"move\":\"stage\",\"when\":[\"\(predicate)\"]}]"
        #expect(try F.candidate([issue], flow: F.flow(issues: rules))?.move.name == "stage")
    }

    @Test(arguments: [-121.0, 121.0])
    func aClaimOutsideTwoMinutesDoesNotUndoADemotion(offset: Double) {
        let issue = F.issue(labelEvents: [
            LabelEvent(kind: .removed, label: "stage:ready", at: F.now),
            LabelEvent(kind: .added, label: "stage:in-progress", at: F.now.addingTimeInterval(offset))
        ])
        #expect(!IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now)
            .holds(all: ["not_demoted:stage:ready,stage:in-progress"]))
    }

    @Test(arguments: ["nothing", "different label", "claim removed"])
    func anUnpairedRemovalOrADifferentAddedLabelIsADemotion(scenario: String) throws {
        var events = [LabelEvent(kind: .removed, label: "stage:ready", at: F.now)]
        if scenario == "different label" {
            events.append(LabelEvent(kind: .added, label: "stage:spec", at: F.now.addingTimeInterval(3)))
        } else if scenario == "claim removed" {
            events.append(LabelEvent(kind: .removed, label: "stage:in-progress", at: F.now.addingTimeInterval(3)))
        }
        let issue = F.issue(labelEvents: events)
        let predicate = "not_demoted:stage:ready,stage:in-progress"
        #expect(!IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now).holds(all: [predicate]))
        let rules = "[{\"move\":\"stage\",\"when\":[\"\(predicate)\"]}]"
        #expect(try F.candidate([issue], flow: F.flow(issues: rules)) == nil)
    }

    @Test func withoutAClaimLabelEvenAnIntakeClaimIsADemotion() {
        let issue = F.issue(labelEvents: [
            LabelEvent(kind: .removed, label: "stage:ready", at: F.now),
            LabelEvent(kind: .added, label: "stage:in-progress", at: F.now.addingTimeInterval(3))
        ])
        #expect(!IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now).holds(all: ["not_demoted:stage:ready"]))
    }

    @Test func aLaterClaimDoesNotEraseAnEarlierUnpairedDemotion() {
        let issue = F.issue(labelEvents: [
            LabelEvent(kind: .removed, label: "stage:ready", at: F.now.addingTimeInterval(-3600)),
            LabelEvent(kind: .removed, label: "stage:ready", at: F.now),
            LabelEvent(kind: .added, label: "stage:in-progress", at: F.now.addingTimeInterval(3))
        ])
        #expect(!IssueFacts.of(issue, issues: [], pullRequests: [], now: F.now)
            .holds(all: ["not_demoted:stage:ready,stage:in-progress"]))
    }

    @Test func theRulesDecodeAndAFlowWithoutThemStaysValid() throws {
        let flow = try F.flow()
        #expect(flow.issues?.map(\.move) == ["triage", "stage", "restage"])
        #expect(flow.issues?.first?.when == ["no_label:priority:", "no_assignee"])
        #expect(try F.flow(issues: nil).issues == nil)
        // The documented example: a move in two rules with different conditions.
        let twice = #"[{"move":"stage","when":["label:stage:triage"]},{"move":"stage","when":["label:stage:spec","quiet_hours:48"]}]"#
        #expect(try F.flow(issues: twice).issues?.count == 2)
    }

    @Test(arguments: [
        (#"[{"move":"score","when":[]}]"#, "not one of"),
        (#"[{"move":"stage","when":["no_label:"]}]"#, "not an issue predicate"),
        (#"[{"move":"stage","when":["quiet_hours:soon"]}]"#, "not an issue predicate"),
        (#"[{"move":"stage","when":["unassigned_ready_under:0"]}]"#, "not an issue predicate"),
        (#"[{"move":"stage","when":["label:x","merged"]}]"#, "not an issue predicate"),
    ])
    func aBadRuleMakesTheFlowInvalidWithTheReason(rules: String, reason: String) {
        guard case let .invalid(why) = Flow.load(F.data(issues: rules)) else {
            Issue.record("\(rules) must be invalid")
            return
        }
        #expect(why.contains(reason), Comment(rawValue: why))
    }

    @Test func aMoveNeedsItsDispatchWithOneAgentOrACommandAndNoPRMoveOfTheSameName() {
        for (dispatch, reason) in [
            (#"{"triage":{"agent":"claude"}}"#, "dispatch.stage is missing"),
            (#"{"triage":{"agent":{"feature":"claude"}},"stage":{"agent":"claude"},"restage":{"agent":"claude"}}"#, "one agent, not per tier"),
            (#"{"triage":{"timeoutMinutes":5},"stage":{"agent":"claude"},"restage":{"agent":"claude"}}"#, "no agent and no command"),
        ] {
            guard case let .invalid(why) = Flow.load(F.data(dispatch: dispatch)) else {
                Issue.record("\(dispatch) must be invalid")
                continue
            }
            #expect(why.contains(reason), Comment(rawValue: why))
        }
        let command = #"{"triage":{"command":["bash","scripts/triage.sh","{issue}"]},"stage":{"agent":"claude"},"restage":{"agent":"claude"}}"#
        #expect(Flow.load(F.data(dispatch: command)).flow != nil)
        let clash = Flow.load(F.data(moves: #"[{"move":"triage","when":["open"],"who":"author"}]"#))
        guard case let .invalid(why) = clash else {
            Issue.record("a PR move named like an issue move must be invalid")
            return
        }
        #expect(why.contains("also a PR move"))
    }

    @Test func thePredicatesReadTheIssueAndWhatTheSyncKnowsAroundIt() {
        let facts = IssueFacts(labels: ["Priority:High", "stage:triage"], assignees: [], authorAssociation: "MEMBER",
                               lastActivity: F.now.addingTimeInterval(-30 * 3600), hasOpenPR: false, unassignedReady: 2, now: F.now)
        let holds = { (text: String) in facts.holds(all: [text]) }
        #expect(holds("label:priority:"))
        #expect(holds("label:priority:high"))
        #expect(!holds("label:priority:low"))
        #expect(!holds("no_label:priority:"))
        #expect(holds("no_label:stage:ready"))
        #expect(holds("no_assignee"))
        #expect(!holds("assigned"))
        #expect(holds("no_open_pr"))
        #expect(!holds("open_pr"))
        #expect(holds("quiet_hours:24"))
        #expect(!holds("quiet_hours:48"))
        // The triager's own comment is not activity: an issue it just capped at spec is quiet for the stage rule.
        let capped = F.issue(8, daysOld: 3, comments: [F.triagers("t1", author: "me", hoursAgo: 1)])
        #expect(IssueFacts.of(capped, issues: [], pullRequests: [], now: F.now).holds(all: ["quiet_hours:48"]))
        let answered = F.issue(9, daysOld: 3, comments: [F.triagers("t1", author: "me", hoursAgo: 3), F.comment("p1", author: "lee", hoursAgo: 1)])
        #expect(!IssueFacts.of(answered, issues: [], pullRequests: [], now: F.now).holds(all: ["quiet_hours:2"]))
        #expect(holds("author_writes"))
        #expect(holds("unassigned_ready_under:3"))
        #expect(!holds("unassigned_ready_under:2"))
        #expect(!holds("merged"))
        var closed = facts
        closed.state = "CLOSED"
        #expect(!closed.holds(all: ["label:priority:"]))
        var outsider = facts
        outsider.authorAssociation = "NONE"
        #expect(!outsider.holds(all: ["author_writes"]))
    }

    @Test func anOpenPRNamingTheIssueIsSeenAsAWholeNumber() {
        let issues = [F.issue(7), F.issue(70, labels: ["stage:ready"])]
        let prs = [F.pr(body: "Closes #70")]
        #expect(IssueFacts.of(F.issue(7), issues: issues, pullRequests: prs, now: F.now).hasOpenPR == false)
        #expect(IssueFacts.of(F.issue(70), issues: issues, pullRequests: prs, now: F.now).hasOpenPR == true)
        #expect(IssueFacts.of(F.issue(7), issues: issues, pullRequests: prs, now: F.now).unassignedReady == 1)
    }

    @Test func theFirstRuleWinsAndTheEarliestRuleMostUrgentOldestIssueGoesFirst() throws {
        let fresh = F.issue(1, daysOld: 1)
        let scoredLow = F.issue(2, labels: ["priority:low", "stage:triage"], daysOld: 30)
        let scoredHigh = F.issue(3, labels: ["priority:high", "stage:triage"], daysOld: 2)
        let orphan = F.issue(4, labels: ["priority:medium", "stage:review"], daysOld: 40)
        let flow = try F.flow()
        #expect(IssueMoves.rule(for: fresh, flow: flow, issues: [], pullRequests: [], now: F.now) == 0)
        #expect(IssueMoves.rule(for: scoredLow, flow: flow, issues: [], pullRequests: [], now: F.now) == 1)
        #expect(IssueMoves.rule(for: orphan, flow: flow, issues: [], pullRequests: [], now: F.now) == 2)
        #expect(IssueMoves.rule(for: F.issue(5, labels: ["priority:low", "stage:ready"]), flow: flow, issues: [], pullRequests: [], now: F.now) == nil)
        let first = try #require(try F.candidate([orphan, scoredLow, scoredHigh, fresh]))
        #expect(first.key.item == "issue-1")
        #expect(first.key.move == "triage")
        let ran = [F.job(first.key)]
        let second = try #require(try F.candidate([orphan, scoredLow, scoredHigh, fresh], jobs: ran))
        #expect(second.key.item == "issue-3")
        #expect(second.key.move == "stage")
        #expect(second.prompt == "Stage #3 of synthetic/project on develop.")
        let third = try #require(try F.candidate([orphan, scoredLow, scoredHigh, fresh], jobs: ran + [F.job(second.key)]))
        #expect(third.key.item == "issue-2")
        let fourth = try #require(try F.candidate([orphan, scoredLow, scoredHigh, fresh], jobs: ran + [F.job(second.key), F.job(third.key)]))
        #expect(fourth.key.item == "issue-4")
        #expect(fourth.key.move == "restage")
        #expect(fourth.timeout == .seconds(300))
        #expect(try F.candidate([orphan, scoredLow, scoredHigh, fresh], jobs: ran + [second, third, fourth].map { F.job($0.key) }) == nil)
    }

    @Test func theCandidateIsBoundedLikeADecision() throws {
        let made = try #require(try F.candidate([F.issue()]))
        #expect(made.agent == "claude")
        #expect(made.skipsChecks)
        #expect(made.cooldown == nil)
        #expect(made.denied == IssueDecisions.denied)
        #expect(made.attachments[IssueMoves.attachment]?.contains("ISSUE_BODY_DATA") == true)
        #expect(made.prompt?.contains("ISSUE_BODY_DATA") == false)
        #expect(made.prompt?.contains("triager hat") == true)
        #expect(made.timeout == .seconds(60 * IssueMoves.defaultTimeoutMinutes))
        if case let .branch(base) = made.target { #expect(base == "develop") } else { Issue.record("an issue move runs at the base") }
        #expect(made.issueMove?.number == 7)
        #expect(made.issueMove?.when == ["no_label:priority:", "no_assignee"])
        #expect(made.issueMove?.facts.labels == [])
        let restage = try #require(try F.candidate([F.issue(labels: ["priority:low", "stage:review"], daysOld: 3)]))
        #expect(restage.denied == IssueDecisions.denied.filter { $0 != "Bash(gh issue close:*)" })
        #expect(restage.denied.contains("Bash(gh pr:*)"))
    }

    @Test func onlyAClaudeCodeAgentOrACommandRunsAnIssueMove() throws {
        let codex = #"{"triage":{"agent":"codex"},"stage":{"agent":"claude"},"restage":{"agent":"claude"}}"#
        #expect(try F.candidate([F.issue()], flow: F.flow(dispatch: codex)) == nil)
        #expect(try F.candidate([F.issue()], agents: [:]) == nil)
        let command = #"{"triage":{"command":["bash","scripts/triage.sh","{issue}","{base}"]},"stage":{"agent":"claude"},"restage":{"agent":"claude"}}"#
        let made = try #require(try F.candidate([F.issue()], flow: F.flow(dispatch: command)))
        #expect(made.agent == nil)
        #expect(made.command == ["bash", "scripts/triage.sh", "7", "develop"])
    }

    @Test func oneRunningPerRepoAndTwentyADay() throws {
        let key = IssueMoves.key(repo: F.repo, number: 99, move: "triage", round: "")
        #expect(IssueMoves.hold(jobs: [F.job(key, status: .running)], repo: F.repo, now: F.now) != nil)
        #expect(try F.candidate([F.issue()], jobs: [F.job(key, status: .running)]) == nil)
        let day = (0..<IssueMoves.dailyCap).map { F.job(IssueMoves.key(repo: F.repo, number: 100 + $0, move: "triage", round: ""), hoursAgo: Double($0)) }
        #expect(IssueMoves.hold(jobs: day, repo: F.repo, now: F.now) != nil)
        #expect(try F.candidate([F.issue()], jobs: day) == nil)
        let yesterday = day.map { F.job($0.key, hoursAgo: 25) }
        #expect(IssueMoves.hold(jobs: yesterday, repo: F.repo, now: F.now) == nil)
        #expect(try F.candidate([F.issue()], jobs: yesterday) != nil)
        let elsewhere = day.map { F.job(JobKey(repo: "other/repo", item: $0.key.item, move: $0.key.move, head: "", round: ""), hoursAgo: 1) }
        #expect(IssueMoves.hold(jobs: elsewhere, repo: F.repo, now: F.now) == nil)
    }

    @Test(arguments: ["implement-failed issue-7", "stale-ping issue-7", "check-failed review@abcdef123456"])
    func noticesDoNotStartAnotherIssueMoveRound(marker: String) {
        let notice = IssueComment(id: "notice", author: F.me, authorAssociation: "MEMBER",
                                  body: "The work stopped.\n\n" + BtonMarker.line(marker),
                                  createdAt: F.now.addingTimeInterval(-3600), url: nil)
        let before = F.comment("before", author: "lee", hoursAgo: 2)
        let after = F.comment("after", author: F.me, hoursAgo: 0.5)
        #expect(IssueMoves.round(of: [notice]) == "")
        #expect(IssueMoves.round(of: [notice, before]) == String(Int(before.createdAt.timeIntervalSince1970)))
        #expect(IssueMoves.round(of: [after, notice, before]) == String(Int(after.createdAt.timeIntervalSince1970)))
    }

    @Test func theRoundIsTheNewestPersonsCommentAndARetryRunsTheKeyAgain() throws {
        let quiet = F.issue()
        #expect(IssueMoves.round(of: quiet.comments) == "")
        // The triager's comment, from this Mac or a teammate's, is not a round; the person's older one is.
        let answered = F.issue(comments: [F.triagers("1", author: F.me, hoursAgo: 2), F.comment("2", author: "lee", hoursAgo: 5)])
        #expect(IssueMoves.round(of: answered.comments) == String(Int(F.now.addingTimeInterval(-5 * 3600).timeIntervalSince1970)))
        let triagersOnly = F.issue(comments: [F.triagers("1", author: "teammate-bton", hoursAgo: 2)])
        #expect(IssueMoves.round(of: triagersOnly.comments) == "")
        // A comment with the sentence the marker was before v0.25 is still the triager's.
        let former = IssueComment(id: "c91", author: "lee", authorAssociation: "MEMBER",
                                  body: "Impact: 1\n\nBton's triager wrote this; a comment from a person overrules it.",
                                  createdAt: F.now.addingTimeInterval(-3600), url: nil)
        #expect(IssueMoves.round(of: [former]) == "")
        // A person who mentions the marker's word is a person: only the whole hidden line is the triager's.
        let asks = IssueComment(id: "c92", author: "lee", authorAssociation: "MEMBER", body: "Does bton:triager survive editing?",
                                createdAt: F.now.addingTimeInterval(-1800), url: nil)
        #expect(IssueMoves.round(of: [asks]) == String(Int(F.now.addingTimeInterval(-1800).timeIntervalSince1970)))
        // The owner's own words under the same login are a person's.
        let owners = F.issue(comments: [F.comment("1", author: "Dani", hoursAgo: 2)])
        #expect(IssueMoves.round(of: owners.comments) == String(Int(F.now.addingTimeInterval(-2 * 3600).timeIntervalSince1970)))
        let key = IssueMoves.key(repo: F.repo, number: 7, move: "triage", round: "")
        #expect(try F.candidate([quiet], jobs: [F.job(key, status: .failed)]) == nil)
        #expect(try F.candidate([quiet], jobs: [F.job(key, status: .failed, retry: true)])?.key == key)
        #expect(try F.candidate([answered], jobs: [F.job(key)])?.key.round != "")
    }

    @Test func underTheLeaseTheIssueMustStillBeOpenDueAndUnanswered() throws {
        let plan = try #require(try F.candidate([F.issue()])).issueMove!
        let open = IssueNow(state: "OPEN", labels: [], assignees: [])
        #expect(IssueMoves.refusal(plan, now: open, comments: []) == nil)
        #expect(IssueMoves.refusal(plan, now: IssueNow(state: "CLOSED", labels: [], assignees: []), comments: []) != nil)
        #expect(IssueMoves.refusal(plan, now: IssueNow(state: "OPEN", labels: ["priority:low"], assignees: []), comments: []) != nil)
        #expect(IssueMoves.refusal(plan, now: IssueNow(state: "OPEN", labels: [], assignees: ["lee"]), comments: []) != nil)
        #expect(IssueMoves.refusal(plan, now: open, comments: [F.comment("9", author: "lee", hoursAgo: 0)]) != nil)
        // The owner's own answer is a person's comment too: a new round, read by the next sync.
        #expect(IssueMoves.refusal(plan, now: open, comments: [F.comment("9", author: F.me, hoursAgo: 0)]) != nil)
        // A triager's comment from any login makes no round, and holds the move off for the cooldown.
        let recent = F.triagers("9", author: "teammate-bton", hoursAgo: 1)
        #expect(IssueMoves.refusal(plan, now: open, comments: [recent], at: F.now)?.contains("triager wrote") == true)
        let old = F.triagers("9", author: "teammate-bton", hoursAgo: 7)
        #expect(IssueMoves.refusal(plan, now: open, comments: [old], at: F.now) == nil)
        // A person's answer after the triager's question is what the move waits for: the cooldown
        // does not hold it back. The plan is keyed on that answer's round, so only the cooldown could refuse.
        let answer = F.comment("9", author: "lee", hoursAgo: 0.5)
        let answered = try #require(try F.candidate([F.issue(9, comments: [recent, answer])])).issueMove!
        #expect(IssueMoves.refusal(answered, now: open, comments: [recent, answer], at: F.now) == nil)
    }

    @Test func theCooldownHoldsARepeatOfTheSameMoveOnlyAndAHeldIssueIsNotPicked() throws {
        let flow = try F.flow(issues: """
        [{"move":"triage","when":["no_label:priority:","no_assignee"]},
         {"move":"stage","when":["label:priority:","label:stage:spec","no_assignee","quiet_hours:48"]}]
        """)
        let spec = ["priority:medium", "stage:spec"]
        // Triage capped the issue at spec an hour ago: its comment is neither activity nor a hold for stage.
        let triaged = F.issue(8, labels: spec, daysOld: 3, comments: [F.triagers("t1", author: F.me, hoursAgo: 1, move: "triage")])
        let next = try #require(try F.candidate([triaged], flow: flow))
        #expect(next.key.move == "stage" && next.issueMove?.number == 8 && next.issueMove?.move == "stage")
        let open = IssueNow(state: "OPEN", labels: spec, assignees: [])
        #expect(IssueMoves.refusal(next.issueMove!, now: open, comments: triaged.comments, at: F.now) == nil)
        // A stage comment an hour ago is another Mac's stage run: held, and the issue behind it gets the turn.
        let staged = F.issue(9, labels: spec, daysOld: 4, comments: [F.triagers("s1", author: "teammate-bton", hoursAgo: 1, move: "stage")])
        let waiting = F.issue(10, labels: spec, daysOld: 3)
        #expect(try F.candidate([staged, waiting], flow: flow)?.issueMove?.number == 10)
        #expect(try F.candidate([staged], flow: flow) == nil)
        #expect(IssueMoves.refusal(next.issueMove!, now: open, comments: staged.comments, at: F.now)?.contains("triager wrote") == true)
        // A marker that names no move (the generic one, the former sentence) holds every move, as before.
        let generic = IssueComment(id: "g1", author: "teammate-bton", authorAssociation: "MEMBER", body: "Scored.\n\n" + IssueMoves.marker,
                                   createdAt: F.now.addingTimeInterval(-3600), url: nil)
        #expect(IssueMoves.refusal(next.issueMove!, now: open, comments: [generic], at: F.now) != nil)
        // An opening with no close, or another word after it, is a person's text: activity and a round.
        for text in ["<!-- bton:triager:stage", "<!-- bton:triager-notes -->", "see bton:triager:stage -->"] {
            let person = IssueComment(id: "p", author: "lee", authorAssociation: "MEMBER", body: text, createdAt: F.now.addingTimeInterval(-60), url: nil)
            #expect(IssueMoves.round(of: [person]) != "", Comment(rawValue: text))
        }
        // A plan written before the move was recorded (jobs.json of v0.24.1) reads as triage.
        let legacy = Data(#"{"number":8,"when":["no_assignee"],"round":"","me":"me","facts":{"state":"OPEN","labels":[],"assignees":[],"authorAssociation":"MEMBER","lastActivity":0,"hasOpenPR":false,"unassignedReady":0,"now":0}}"#.utf8)
        #expect(try JSONDecoder().decode(IssueMoves.Plan.self, from: legacy).move == "triage")
        let kept = try JSONDecoder().decode(IssueMoves.Plan.self, from: JSONEncoder().encode(next.issueMove!))
        #expect(kept.move == "stage")
    }

    @Test func aKeyAnotherMacRanIsRememberedSoTheNextIssueGetsItsTurn() throws {
        let issues = [F.issue(1, daysOld: 5), F.issue(2, daysOld: 3)]
        let first = try #require(try F.candidate(issues))
        #expect(first.key.item == "issue-1")
        let next = try #require(try F.candidate(issues, ranElsewhere: [first.key]))
        #expect(next.key.item == "issue-2")
    }

    @Test func theAnswersAreReadAsTheTabsOptionsAndBecomeTheLabels() throws {
        let report = "I looked at the code.\nImpact: 1\nUrgency: 2\nStart: 1\nGoal: faster invoicing\n"
        #expect(IssueMoves.answers(in: report) == [0, 1, 0])
        #expect(IssueMoves.answers(in: "nothing here") == nil)
        #expect(IssueMoves.answers(in: "impact: 3 (workaround)\nurgency: 3") == [2, 2, nil])
        let plan = try #require(try F.candidate([F.issue()])).issueMove!
        let outcome = IssueMoves.outcome(report: report, plan: plan, now: IssueNow(state: "OPEN", labels: [], assignees: []), comments: [], since: F.now)
        // A clear plan scores its point, and the stage is capped: ready is the stage move's, after the plan.
        #expect(outcome == .labels(TriageVerdict(score: 8, priority: "high", stage: "spec")))
        #expect(IssueTriage.verdict([0, 1, 0])?.stage == "ready")
        let open = IssueMoves.outcome(report: "Impact: 1\nUrgency: 2\nStart: 3", plan: plan, now: IssueNow(state: "OPEN", labels: [], assignees: []), comments: [], since: F.now)
        #expect(open == .labels(TriageVerdict(score: 7, priority: "high", stage: "spec")))
        // Three answers that name no option are not a verdict: the job reads as it is on GitHub.
        let bad = IssueMoves.outcome(report: "Impact: 9\nUrgency: 1\nStart: 1", plan: plan, now: IssueNow(state: "OPEN", labels: [], assignees: []), comments: [], since: F.now)
        #expect(bad == .nothing)
        // Only the triage move scores: a stage that quotes the three lines has not scored the issue.
        let staged = IssueMoves.outcome(report: report, move: "stage", plan: plan, now: IssueNow(state: "OPEN", labels: [], assignees: []), comments: [], since: F.now)
        #expect(staged == .nothing)
    }

    @Test func aQuestionCountsOnlyWhenPostedAndSilenceIsAFailure() throws {
        let plan = try #require(try F.candidate([F.issue()])).issueMove!
        let open = IssueNow(state: "OPEN", labels: [], assignees: [])
        let mine = [F.comment("5", author: F.me, hoursAgo: -0.1)]
        let asked = IssueMoves.outcome(report: "Question: which plan is this for? Ask lee.", plan: plan, now: open, comments: mine, since: F.now)
        #expect(asked == .asked("which plan is this for? Ask lee."))
        // Earlier answers quoted in a report that ends by asking never set the labels.
        let mixed = IssueMoves.outcome(report: "Impact: 1\nUrgency: 1\nStart: 1\nQuestion: is this still wanted?", plan: plan, now: open, comments: mine, since: F.now)
        #expect(mixed == .asked("is this still wanted?"))
        #expect(IssueMoves.outcome(report: "Question: anyone?", plan: plan, now: open, comments: [], since: F.now) == .nothing)
        let earlier = [F.comment("5", author: F.me, hoursAgo: 3)]
        #expect(IssueMoves.outcome(report: "Question: anyone?", plan: plan, now: open, comments: earlier, since: F.now) == .nothing)
        #expect(IssueMoves.outcome(report: "done", plan: plan, now: open, comments: mine, since: F.now) == .done)
        #expect(IssueMoves.outcome(report: "done", plan: plan, now: IssueNow(state: "OPEN", labels: ["stage:ready"], assignees: []), comments: [], since: F.now) == .done)
        #expect(IssueMoves.outcome(report: "Unchanged: the plan is complete", plan: plan, now: open, comments: [], since: F.now) == .unchanged("the plan is complete"))
        #expect(IssueMoves.outcome(report: "I thought about it.", plan: plan, now: open, comments: [], since: F.now) == .nothing)
    }

    @Test func theMovesWearTheTriagerHatAndItsPlaybookListsTheTabsOptions() throws {
        for move in IssueMoves.moves { #expect(Hats.hat(for: move) == .triager, Comment(rawValue: move)) }
        let text = try Hats.text(for: "triage", settings: [:])
        #expect(text.contains("Move: triage"))
        for question in IssueTriage.questions {
            #expect(text.contains(question.text))
            for (index, option) in question.options.enumerated() { #expect(text.contains("\(index + 1). \(option.label)")) }
        }
        #expect(try Hats.text(for: "stage", settings: [:]).contains("Move: stage"))
        #expect(try Hats.text(for: "restage", settings: [:]).contains("Move: restage"))
        // The issue paragraph sits between the hat's core and the move: the graph before the tree, one comment per move.
        #expect(try Hats.text(for: "restage", settings: ["triager": HatSettings(playbook: "Sort kindly.")]).hasPrefix("Sort kindly.\n\nOn an issue\n"))
        for move in IssueMoves.moves {
            let text = try Hats.text(for: move, settings: [:])
            #expect(text.components(separatedBy: "\n\nOn an issue\n").count == 2, Comment(rawValue: move))
            #expect(text.range(of: "On an issue\n")!.lowerBound < text.range(of: "Move: \(move)\n")!.lowerBound, Comment(rawValue: move))
            #expect(text.contains("graphify-src \"<question>\" and naming the issue as #<n>"), Comment(rawValue: move))
        }
        // The marker is hidden on GitHub and the triage text says where the stage stops.
        #expect(IssueMoves.marker.hasPrefix("<!--") && IssueMoves.marker.hasSuffix("-->"))
        #expect(text.contains("the stage at most `stage:spec`"))
        // Each move's text carries its own marker, so a comment says which move wrote it.
        for move in IssueMoves.moves { #expect(try Hats.text(for: move, settings: [:]).contains(IssueMoves.marker(for: move)), Comment(rawValue: move)) }
        let prompt = IssueMoves.prompt(move: "triage", issue: 7, repo: F.repo)
        #expect(prompt.contains("graphify-src \"<question>\"") && prompt.contains("#7"))
        #expect(prompt.contains("for what the graph does not answer"))
        #expect(IssueMoves.latestJob(for: 7, repo: F.repo, jobs: [F.job(IssueMoves.key(repo: F.repo, number: 7, move: "stage", round: ""))])?.key.move == "stage")
    }

    @Test func aFailedIssueMoveCanBeRetried() {
        let job = F.job(IssueMoves.key(repo: F.repo, number: 7, move: "triage", round: ""), status: .failed)
        #expect(job.canRetry(among: [job]))
    }
}
