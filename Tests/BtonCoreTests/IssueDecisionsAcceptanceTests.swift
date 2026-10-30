@testable import BtonCore
import Foundation
import Testing

private enum IssueDecisionsFixture {
    static let body = "ISSUE_BODY_DATA"
    static let question = "COMMENT_BODY_DATA @dani choose A or B?"
    static let agents = ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"])]

    static func comment(_ id: String = "21", author: String = "jonas", second: Int = 1) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: question,
                     createdAt: Date(timeIntervalSince1970: Double(second)), url: nil)
    }

    static func issue(body: String = body, labels: [String] = [],
                      comments: [IssueComment] = [comment()]) -> OpenIssue {
        OpenIssue(repo: "synthetic/project", number: 7, title: "ISSUE_TITLE_DATA",
                  url: URL(string: "https://example.invalid/issues/7")!,
                  createdAt: Date(timeIntervalSince1970: 0), author: "lee", authorAssociation: "MEMBER",
                  body: body, comments: comments, labels: labels)
    }

    static func data(decide: String? = #"{"by":["dani"]}"#, heading: String? = nil) -> Data {
        let decision = heading.map { #", "decision":{"heading":"\#($0)","move":"decide","by":["dani"]}"# } ?? ""
        let decide = decide.map { ", \"decide\":\($0)" } ?? ""
        return Data("""
        {"version":1,"base":"main",
         "tier":{"marker":"Tier:","values":["feature"],"default":"feature"},
         "reviews":{"feature":[{"heading":"## Review:","notByAuthor":true}]},
         "fixed":"## Fixed:","moves":[],"dispatch":{}\(decision)\(decide)}
        """.utf8)
    }

    static func flow(decide: String? = #"{"by":["dani"]}"#, heading: String? = nil) throws -> Flow {
        try #require(Flow.load(data(decide: decide, heading: heading)).flow)
    }

    static func candidate(_ issue: OpenIssue = issue(), ask: IssueAsk? = nil,
                          decide: String? = #"{"by":["dani"]}"#, heading: String? = nil,
                          agents: [String: AgentTemplate] = agents, branch: String = "main",
                          me: String = "dani") throws -> DispatchCandidate? {
        let ask = try ask ?? #require(IssueAsks.ask(in: issue, me: me))
        return try IssueDecisions.candidate(ask: ask, issue: issue, flow: flow(decide: decide, heading: heading),
                                           agents: agents, defaultBranch: branch, me: me)
    }
}

struct IssueDecisionsAcceptanceTests {
    private typealias F = IssueDecisionsFixture

    @Test func decodesDecideWithOptionalDefaultsUnset() throws {
        let flow = try F.flow(decide: #"{"by":["dani"],"except":["high-risk"]}"#)
        #expect(flow.decide?.by == ["dani"])
        #expect(flow.decide?.except == ["high-risk"])
        #expect(flow.decide?.agent == nil)
        #expect(flow.decide?.timeoutMinutes == nil)
    }

    @Test func emptyDecidersAreInvalid() {
        guard case .invalid(let reason) = Flow.load(F.data(decide: #"{"by":[]}"#)) else {
            Issue.record("Empty decide.by must be invalid")
            return
        }
        #expect(reason.contains("decide.by"))
    }

    @Test func flowWithoutDecideRemainsValid() throws {
        guard case .ready(let flow) = Flow.load(F.data(decide: nil)) else {
            Issue.record("A flow without decide must remain valid")
            return
        }
        #expect(flow.decide == nil)
    }

    @Test func keyIdentifiesTheAskingComment() throws {
        let ask = try #require(IssueAsks.ask(in: F.issue(), me: "dani"))
        let key = IssueDecisions.key(for: ask)
        #expect(key.repo == "synthetic/project")
        #expect(key.item == "issue-7")
        #expect(key.move == "decide")
        #expect(key.head == "21")
        #expect(key.round == "")
    }

    @Test(arguments: ["High-Risk", "tier:high-risk", "tier:HIGH-RISK"])
    func matchingLabelIsExcepted(label: String) {
        #expect(IssueDecisions.isExcepted(F.issue(labels: [label]), words: ["high-risk"]))
    }

    @Test func wholeWordBodyMatchIsCaseInsensitive() {
        #expect(IssueDecisions.isExcepted(F.issue(body: "This is High-risk: data deletion"), words: ["high-risk"]))
    }

    @Test(arguments: ["high-risky", "nonhigh-risk", "high-risk2", "2high-risk", "high-risk-extra"])
    func longerWordDoesNotMatch(body: String) {
        #expect(!IssueDecisions.isExcepted(F.issue(body: body), words: ["high-risk"]))
    }

    @Test func emptyExceptionsMatchNothing() {
        #expect(!IssueDecisions.isExcepted(F.issue(body: "high-risk", labels: ["high-risk"]), words: []))
    }

    @Test func candidateUsesDecisionDispatchDefaults() throws {
        let issue = F.issue()
        let ask = try #require(IssueAsks.ask(in: issue, me: "dani"))
        let candidate = try #require(try F.candidate(issue, ask: ask, branch: "develop"))
        #expect(candidate.key == IssueDecisions.key(for: ask))
        #expect(candidate.decide?.askedAt == ask.askedAt)
        guard case .branch(let branch) = candidate.target else {
            Issue.record("Decision must target the default branch")
            return
        }
        #expect(branch == "develop")
        #expect(candidate.move.name == "decide")
        #expect(candidate.move.owner == "dani")
        #expect(candidate.agent == "claude")
        #expect(candidate.postComment == false)
        #expect(candidate.skipsChecks)
        #expect(candidate.timeout == .seconds(60 * 20))
    }

    @Test func issueTextIsAttachedAndNeverInterpolatedIntoPrompt() throws {
        let candidate = try #require(try F.candidate())
        let attachment = try #require(candidate.attachments["issue.md"])
        #expect(attachment.contains("ISSUE_TITLE_DATA"))
        #expect(attachment.contains(F.question))
        let prompt = try #require(candidate.prompt)
        #expect(!prompt.contains(F.body))
        #expect(!prompt.contains(F.question))
        #expect(prompt.contains("#7"))
        #expect(prompt.contains("## Decision:"))
        #expect(prompt.contains("for dani"))
    }

    @Test func configuredDecisionHeadingReachesPrompt() throws {
        let candidate = try #require(try F.candidate(heading: "## Ruling:"))
        #expect(candidate.prompt?.contains("## Ruling:") == true)
    }

    @Test func deciderLoginMatchesIgnoringCase() throws {
        #expect(try F.candidate(decide: #"{"by":["DANI"]}"#) != nil)
    }

    @Test func configuredAgentAndTimeoutAreUsed() throws {
        let candidate = try #require(try F.candidate(
            decide: #"{"by":["dani"],"agent":"codex","timeoutMinutes":3}"#,
            agents: ["codex": AgentTemplate(argv: ["/usr/local/bin/claude", "{prompt}"])]))
        #expect(candidate.agent == "codex")
        #expect(candidate.timeout == .seconds(60 * 3))
    }

    @Test func codexExecutableCannotDispatch() throws {
        #expect(try F.candidate(
            decide: #"{"by":["dani"],"agent":"codex"}"#,
            agents: ["codex": AgentTemplate(argv: ["codex"])] ) == nil)
    }

    @Test func customPromptOnlyFillsDocumentedPlaceholders() throws {
        let candidate = try #require(try F.candidate(
            decide: #"{"by":["dani"],"prompt":"Keep this: {issue} | {repo} | {heading}\nverbatim."}"#,
            heading: "## Ruling:"))
        #expect(candidate.prompt == "Keep this: 7 | synthetic/project | ## Ruling:\nverbatim.")
    }

    @Test func noDecideMeansNoCandidate() throws {
        #expect(try F.candidate(decide: nil) == nil)
    }

    @Test func nonDeciderCannotDispatch() throws {
        #expect(try F.candidate(decide: #"{"by":["lee"]}"#) == nil)
    }

    @Test func exceptedIssueCannotDispatch() throws {
        #expect(try F.candidate(F.issue(labels: ["High-Risk"]),
                                decide: #"{"by":["dani"],"except":["high-risk"]}"#) == nil)
    }

    @Test func newerAskInvalidatesOldAsk() throws {
        let ask = try #require(IssueAsks.ask(in: F.issue(), me: "dani"))
        let updated = F.issue(comments: [F.comment(), F.comment("22", author: "lee", second: 2)])
        #expect(try F.candidate(updated, ask: ask) == nil)
    }

    @Test func nondraftableAskCannotDispatch() throws {
        let issue = F.issue()
        let current = try #require(IssueAsks.ask(in: issue, me: "dani"))
        let ask = IssueAsk(repo: current.repo, number: current.number, title: current.title, url: current.url,
                           asker: current.asker, askedAt: current.askedAt, commentID: current.commentID,
                           draftable: false, thread: current.thread)
        #expect(try F.candidate(issue, ask: ask) == nil)
    }

    @Test func missingDefaultAgentCannotDispatch() throws {
        #expect(try F.candidate(agents: [:]) == nil)
    }

    @Test func missingConfiguredAgentCannotDispatch() throws {
        #expect(try F.candidate(decide: #"{"by":["dani"],"agent":"codex"}"#) == nil)
    }

    @Test func emptyDefaultBranchCannotDispatch() throws {
        #expect(try F.candidate(branch: "") == nil)
    }

    @Test func promptExplainsDecisionAuthorityAndKeepsIssueOpen() {
        let prompt = IssueDecisions.prompt(heading: "## Ruling:", me: "dani")
        #expect(prompt.contains("## Ruling:"))
        #expect(prompt.contains("for dani"))
        #expect(prompt.contains("issue.md"))
        #expect(prompt.lowercased().contains("overrule"))
        let lower = prompt.lowercased()
        #expect(lower.contains("never close") || lower.contains("do not close"))
    }
}

extension IssueDecisionsAcceptanceTests {
    @Test func candidateCarriesDeniedCommandsAndDecisionPlan() throws {
        let candidate = try #require(try F.candidate(
            decide: #"{"by":["dani"],"except":["high-risk","private"]}"#))
        #expect(candidate.denied == IssueDecisions.denied)
        #expect(candidate.decide?.number == 7)
        #expect(candidate.decide?.except == ["high-risk", "private"])
        #expect(candidate.decide?.me == "dani")
        let defaults = try #require(try F.candidate())
        #expect(defaults.decide?.except == [])
    }

    @Test func deniedCommandsProtectIssueClosurePullRequestsAndPushes() {
        let denied: [String] = IssueDecisions.denied
        #expect(denied.contains("Bash(gh issue close:*)"))
        #expect(denied.contains("Bash(gh pr:*)"))
        #expect(denied.contains("Bash(git push:*)"))
        #expect(!denied.contains { $0.hasPrefix("Bash(gh issue comment") })
        #expect(!denied.contains { $0.hasPrefix("Bash(gh issue edit") })
    }

    @Test func openIssueWithoutExceptedLabelIsNotRefused() {
        let now = IssueNow(state: "OPEN", labels: ["feature", "not-high-risk"], assignees: [])
        #expect(IssueDecisions.refusal(now, except: ["high-risk"]) == nil)
        #expect(IssueDecisions.refusal(now, except: []) == nil)
    }

    @Test(arguments: ["CLOSED", "MERGED", "open", ""])
    func issueOutsideOpenStateIsRefused(state: String) {
        #expect(IssueDecisions.refusal(IssueNow(state: state, labels: [], assignees: []), except: []) != nil)
    }

    @Test(arguments: ["High-Risk", "tier:High-Risk", "tier:HIGH-RISK"])
    func refreshedExceptionLabelIsRefused(label: String) {
        let now = IssueNow(state: "OPEN", labels: [label], assignees: [])
        #expect(IssueDecisions.refusal(now, except: ["high-risk"]) != nil)
    }

    @Test(arguments: [99, 100, 101])
    func refreshedLabelReadFailsClosedAtOneHundred(count: Int) {
        let labels = (0..<count).map { "label-\($0)" }
        let now = IssueNow(state: "OPEN", labels: labels, assignees: [])
        #expect((IssueDecisions.refusal(now, except: []) != nil) == (count >= 100))
    }

    @Test(arguments: [99, 100, 101])
    func initialLabelReadFailsClosedAtOneHundred(count: Int) {
        let labels = (0..<count).map { "label-\($0)" }
        #expect(IssueDecisions.isExcepted(F.issue(labels: labels), words: ["high-risk"]) == (count >= 100))
    }

    @Test(arguments: [-60, -1, 0, 60])
    func ownerCommentCountsOnlySinceJobStarted(offset: Int) {
        let since = Date(timeIntervalSince1970: 1_000)
        let comment = F.comment(author: "DaNi", second: 1_000 + offset)
        let outcome = IssueDecisions.outcome(comments: [comment], me: "dani", since: since, report: "Needs owner")
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == (offset >= 0 ? nil : "left to you: Needs owner"))
    }

    @Test func oldOwnerAndRecentOtherCommentsDoNotCountAsPosted() {
        let comments = [F.comment(author: "dani", second: 939), F.comment(author: "lee", second: 1_001)]
        let outcome = IssueDecisions.outcome(comments: comments, me: "dani",
                                             since: Date(timeIntervalSince1970: 1_000),
                                             report: "First line\n\n  Ask the owner for the missing fact. \t\n \n")
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == "left to you: Ask the owner for the missing fact.")
    }

    @Test(arguments: ["", " \n\t\n"])
    func missingReportIsLeftToOwner(report: String) {
        let outcome = IssueDecisions.outcome(comments: [], me: "dani", since: Date(), report: report)
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == "left to you: no report")
    }

    @Test func ownerHandoffTruncatesLastReportLineToTwoHundredCharacters() {
        let outcome = IssueDecisions.outcome(comments: [], me: "dani", since: Date(),
                                             report: "Earlier line\n  " + String(repeating: "x", count: 201) + "  \n")
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail == "left to you: " + String(repeating: "x", count: 200))
    }

    @Test func decodesGhCommentFieldsAndNullAuthor() throws {
        let data = Data(###"{"comments":[{"id":"IC_1","author":{"login":"dani"},"body":"## Decision: ruled","createdAt":"2026-10-30T08:00:00Z","url":"https://github.com/o/r/issues/1#issuecomment-1"},{"id":"IC_2","author":null,"body":"Deleted author","createdAt":"2026-10-30T08:00:00Z","url":null}]}"###.utf8)
        let comments = try IssueDecisions.decodeComments(data)
        #expect(comments.count == 2)
        let first = try #require(comments.first)
        #expect(first.id == "IC_1")
        #expect(first.author == "dani")
        #expect(first.body == "## Decision: ruled")
        #expect(first.createdAt == ISO8601DateFormatter().date(from: "2026-10-30T08:00:00Z"))
        #expect(first.url == URL(string: "https://github.com/o/r/issues/1#issuecomment-1"))
        #expect(first.authorAssociation == nil)
        let deleted = try #require(comments.last)
        #expect(deleted.id == "IC_2")
        #expect(deleted.author == nil)
        #expect(deleted.authorAssociation == nil)
        #expect(deleted.url == nil)
    }
}

extension IssueDecisionsAcceptanceTests {
    @Test func decodesLiveIssueAndComments() throws {
        let data = Data(###"{"state":"OPEN","labels":[{"name":"x"}],"body":"Live body","comments":[{"id":"IC_1","author":{"login":"dani"},"body":"Decision","createdAt":"2026-10-30T08:00:00Z","url":"https://example.invalid/comment/1"},{"id":"IC_2","author":null,"body":"Deleted author","createdAt":"2026-10-30T08:00:00Z","url":null}]}"###.utf8)
        let live = try IssueDecisions.decodeLive(data)
        #expect(live.now.state == "OPEN")
        #expect(live.now.labels == ["x"])
        #expect(live.now.assignees.isEmpty)
        #expect(live.body == "Live body")
        let comments = try IssueDecisions.decodeComments(data)
        #expect(live.comments.count == comments.count)
        for (actual, expected) in zip(live.comments, comments) {
            #expect(actual.id == expected.id)
            #expect(actual.author == expected.author)
            #expect(actual.authorAssociation == expected.authorAssociation)
            #expect(actual.body == expected.body)
            #expect(actual.createdAt == expected.createdAt)
            #expect(actual.url == expected.url)
        }
    }

    @Test(arguments: ["OPEN", "CLOSED", "MERGED", "open", ""])
    func liveRefusalPreservesStateChecks(state: String) {
        let plan = IssueDecisions.Plan(number: 7, except: [], me: "dani", askedAt: Date(timeIntervalSince1970: 1))
        let live = IssueDecisions.Live(now: IssueNow(state: state, labels: [], assignees: []), body: "Safe body", comments: [])
        #expect((IssueDecisions.refusal(live, plan: plan) != nil) == (state != "OPEN"))
    }

    @Test(arguments: ["High-Risk", "tier:HIGH-RISK"])
    func liveExceptionLabelIsRefused(label: String) {
        let plan = IssueDecisions.Plan(number: 7, except: ["high-risk"], me: "dani", askedAt: Date())
        let live = IssueDecisions.Live(now: IssueNow(state: "OPEN", labels: [label], assignees: []), body: "Safe body", comments: [])
        #expect(IssueDecisions.refusal(live, plan: plan) != nil)
    }

    @Test(arguments: ["High-risk: x", "high-risky", "Safe body"])
    func liveBodyExceptionRequiresWholeWord(body: String) {
        let plan = IssueDecisions.Plan(number: 7, except: ["high-risk"], me: "dani", askedAt: Date())
        let live = IssueDecisions.Live(now: IssueNow(state: "OPEN", labels: [], assignees: []), body: body, comments: [])
        #expect((IssueDecisions.refusal(live, plan: plan) != nil) == (body == "High-risk: x"))
    }

    @Test(arguments: ["dani", "lee", "jonas"], [0, 1, 2])
    func liveCommentsRefuseOnlyAfterAskPlusOneSecond(author: String, offset: Int) {
        let plan = IssueDecisions.Plan(number: 7, except: ["high-risk"], me: "dani", askedAt: Date(timeIntervalSince1970: 100))
        let live = IssueDecisions.Live(now: IssueNow(state: "OPEN", labels: ["feature"], assignees: []),
                                       body: "Safe body", comments: [F.comment(author: author, second: 100 + offset)])
        #expect((IssueDecisions.refusal(live, plan: plan) != nil) == (offset > 1))
    }
}
