@testable import BtonCore
import Foundation
import Testing

private enum IssueMovesFixture {
    static let agents = ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"]),
                         "codex": AgentTemplate(argv: ["codex", "exec", "{prompt}"])]
    static let me = "dani"
    static let repo = "synthetic/project"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func comment(_ id: String, author: String, hoursAgo: Double) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: "COMMENT_BODY_DATA",
                     createdAt: now.addingTimeInterval(-hoursAgo * 3600), url: nil)
    }

    static func issue(_ number: Int = 7, labels: [String] = [], assignees: [String] = [], association: String = "MEMBER",
                      daysOld: Double = 10, comments: [IssueComment] = []) -> OpenIssue {
        OpenIssue(repo: repo, number: number, title: "ISSUE_TITLE_DATA", url: URL(string: "https://example.invalid/issues/\(number)")!,
                  createdAt: now.addingTimeInterval(-daysOld * 86400), author: "lee", authorAssociation: association,
                  body: "ISSUE_BODY_DATA", comments: comments, labels: labels, assignees: assignees)
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

    /// A comment the triager posted, on any Mac: it ends with Bton's marker line.
    static func triagers(_ id: String, author: String, hoursAgo: Double) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: "Impact: 1, because...\n\n" + IssueMoves.marker,
                     createdAt: now.addingTimeInterval(-hoursAgo * 3600), url: nil)
    }
}

/// The issue moves: a flow's rules over open issues, run under the triager hat, bounded like a
/// decision and read back from GitHub.
struct IssueMovesAcceptanceTests {
    private typealias F = IssueMovesFixture

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

    @Test func theRoundIsTheNewestPersonsCommentAndARetryRunsTheKeyAgain() throws {
        let quiet = F.issue()
        #expect(IssueMoves.round(of: quiet.comments) == "")
        // The triager's comment, from this Mac or a teammate's, is not a round; the person's older one is.
        let answered = F.issue(comments: [F.triagers("1", author: F.me, hoursAgo: 2), F.comment("2", author: "lee", hoursAgo: 5)])
        #expect(IssueMoves.round(of: answered.comments) == String(Int(F.now.addingTimeInterval(-5 * 3600).timeIntervalSince1970)))
        let triagersOnly = F.issue(comments: [F.triagers("1", author: "teammate-bton", hoursAgo: 2)])
        #expect(IssueMoves.round(of: triagersOnly.comments) == "")
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
        #expect(outcome == .labels(TriageVerdict(score: 8, priority: "high", stage: "ready")))
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
