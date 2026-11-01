@testable import BtonCore
import Foundation
import Testing

/// A flow's `decide.table`: an open row of an issue's Decisions table is an ask to the owner
/// without a mention, keyed on the rows' wording and decided by the owner's own Bton.
private enum DecisionTableFixture {
    static let me = "dani"
    static let agents = ["claude": AgentTemplate(argv: ["claude", "-p", "{prompt}"])]
    static let table = Flow.DecisionTable(names: ["Dani": "dani"], open: nil)

    static let header = """
    ## Plan

    Steps here.

    ## Decisions

    | D-n | Decision | Recommendation | Who | Date |
    | --- | --- | --- | --- | --- |
    """

    static func body(rows: [String]) -> String { header + "\n" + rows.joined(separator: "\n") + "\n" }

    static let openForMe = "| D-3 | ROW_THREE_TEXT_DATA | Pick A | Dani | open |"
    static let decidedByMe = "| D-1 | ROW_ONE_TEXT_DATA | Keep | Dani | 2026-10-29 |"
    static let decidedByBoth = "| D-2 | ROW_TWO_TEXT_DATA | Keep | Bogdan, Dani | 2026-10-30 |"
    static let openForBogdan = "| D-4 | ROW_FOUR_TEXT_DATA | Keep | Bogdan | open |"

    static func comment(_ id: String, author: String, body: String = "COMMENT_BODY_DATA", second: Int = 1) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: body,
                     createdAt: Date(timeIntervalSince1970: Double(second)), url: nil)
    }

    static func issue(rows: [String] = [decidedByMe, openForMe], labels: [String] = [], association: String = "MEMBER",
                      comments: [IssueComment] = []) -> OpenIssue {
        OpenIssue(repo: "synthetic/project", number: 7, title: "ISSUE_TITLE_DATA", url: URL(string: "https://example.invalid/issues/7")!,
                  createdAt: Date(timeIntervalSince1970: 0), author: "lee", authorAssociation: association,
                  body: body(rows: rows), comments: comments, labels: labels)
    }

    static func data(decide: String) -> Data {
        Data("""
        {"version":1,"base":"main",
         "tier":{"marker":"Tier:","values":["feature"],"default":"feature"},
         "reviews":{"feature":[{"heading":"## Review:","notByAuthor":true}]},
         "fixed":"## Fixed:","moves":[],"dispatch":{}, "decide":\(decide)}
        """.utf8)
    }

    static let withTable = #"{"by":["dani"],"except":["high-risk"],"table":{"names":{"Dani":"dani"}}}"#

    static func flow(_ decide: String = withTable) throws -> Flow { try #require(Flow.load(data(decide: decide)).flow) }

    static func candidate(_ issue: OpenIssue = issue(), decide: String = withTable, me: String = me) throws -> DispatchCandidate? {
        let flow = try flow(decide)
        guard let ask = IssueAsks.ask(in: issue, me: me, table: flow.decide?.table) else { return nil }
        return IssueDecisions.candidate(ask: ask, issue: issue, flow: flow, agents: agents, defaultBranch: "main", me: me)
    }
}

struct DecisionTableAcceptanceTests {
    private typealias F = DecisionTableFixture

    @Test func theTableDecodesAndAFlowWithoutItStillHasNoTableAsk() throws {
        let flow = try F.flow()
        #expect(flow.decide?.table?.names == ["Dani": "dani"])
        #expect(flow.decide?.table?.open == nil)
        let plain = try F.flow(#"{"by":["dani"]}"#)
        #expect(plain.decide?.table == nil)
        #expect(IssueAsks.ask(in: F.issue(), me: F.me, table: plain.decide?.table) == nil)
    }

    @Test func onlyTheRowsOpenForMeAreRead() {
        let rows = DecisionRows.open(in: F.body(rows: [F.decidedByMe, F.decidedByBoth, F.openForMe, F.openForBogdan]), for: F.me, table: F.table)
        #expect(rows.map(\.id) == ["D-3"])
        // The header and the rule are not rows; a date decides the row whoever it names.
        #expect(DecisionRows.open(in: F.header, for: F.me, table: F.table).isEmpty)
        // The login counts for itself, bold or in a note; the name must be a whole word.
        let variants = [
            "| **D-5** | X | **Dani** | Open |", "| D-6 | X | dani (asked by lee) | |", "| D-7 | X | Daniel | open |",
            "| D-8 | X | Dani | **Approved by Dani, 2026-10-31** |", "| D-9 | X | Dani | Pending, revision 2 |",
        ]
        #expect(DecisionRows.open(in: variants.joined(separator: "\n"), for: F.me, table: F.table).map(\.id) == ["D-5", "D-6"])
        // A configured open word reads the pending row too; the four-column layout reads the same.
        let pending = Flow.DecisionTable(names: ["Dani": "dani"], open: ["open", "pending"])
        #expect(DecisionRows.open(in: variants.joined(separator: "\n"), for: F.me, table: pending).map(\.id) == ["D-5", "D-6", "D-9"])
        #expect(DecisionRows.open(in: "| ID | Decision | Who | Date |\n| D-1 | X | Dani | open |", for: F.me, table: F.table).map(\.id) == ["D-1"])
        // An escaped pipe and a pipe in a code span are text: the date cell stays one decided cell,
        // and a code span in a middle column does not shift Who and Date.
        let pipes = [
            "| D-10 | X | Dani | 2026-10-30 (Dani \\| open) |",
            "| D-11 | `a | b` and `c` | Dani | open |",
            "| D-12 | X | Dani | o pen |",
        ]
        #expect(DecisionRows.open(in: pipes.joined(separator: "\n"), for: F.me, table: F.table).map(\.id) == ["D-11", "D-12"])
        #expect(DecisionRows.cells(of: "| D-11 | `a | b` and `c` | Dani | open |") == ["D-11", "`a | b` and `c`", "Dani", "open"])
    }

    @Test func theRevisionFollowsTheOpenRowsOnly() {
        let rows = DecisionRows.open(in: F.body(rows: [F.decidedByMe, F.openForMe]), for: F.me, table: F.table)
        let revision = DecisionRows.revision(rows)
        #expect(revision.count == "rows-".count + 12)
        // An edit elsewhere in the body, or to a decided row, keeps the revision; the open row's wording changes it.
        let elsewhere = DecisionRows.open(in: "Other text.\n" + F.body(rows: [F.decidedByMe.replacingOccurrences(of: "Keep", with: "Drop"), F.openForMe]),
                                          for: F.me, table: F.table)
        #expect(DecisionRows.revision(elsewhere) == revision)
        let reworded = DecisionRows.open(in: F.body(rows: [F.openForMe.replacingOccurrences(of: "Pick A", with: "Pick B")]), for: F.me, table: F.table)
        #expect(DecisionRows.revision(reworded) != revision)
    }

    @Test func theRowsMakeAnAskKeyedOnTheirWordingAndAMentionComesFirst() throws {
        let ask = try #require(IssueAsks.ask(in: F.issue(), me: F.me, table: F.table))
        #expect(ask.rows == ["D-3"])
        #expect(ask.commentID.hasPrefix("rows-"))
        #expect(!ask.commentID.contains("@m"))
        #expect(ask.askedAt == Date(timeIntervalSince1970: 0))
        // A comment leaves the key alone; an edit to the row is a new ask.
        let commented = try #require(IssueAsks.ask(in: F.issue(comments: [F.comment("1", author: "lee")]), me: F.me, table: F.table))
        #expect(commented.commentID == ask.commentID)
        let edited = try #require(IssueAsks.ask(in: F.issue(rows: [F.decidedByMe, F.openForMe.replacingOccurrences(of: "Pick A", with: "Pick B")]),
                                                me: F.me, table: F.table))
        #expect(edited.commentID != ask.commentID)
        // Decided in the body: no ask. A mention nobody answered is the ask, the rows wait behind it.
        #expect(IssueAsks.ask(in: F.issue(rows: [F.decidedByMe]), me: F.me, table: F.table) == nil)
        let mention = F.comment("2", author: "lee", body: "@dani which one?")
        let asked = try #require(IssueAsks.ask(in: F.issue(comments: [mention]), me: F.me, table: F.table))
        #expect(asked.commentID == "2")
        #expect(asked.rows.isEmpty)
        // Once I answer the mention, the open row is the ask again.
        let answered = try #require(IssueAsks.ask(in: F.issue(comments: [mention, F.comment("3", author: F.me, second: 2)]), me: F.me, table: F.table))
        #expect(answered.rows == ["D-3"])
    }

    @Test func theDecisionNamesTheRowAndNeverItsText() throws {
        let candidate = try #require(try F.candidate())
        let prompt = try #require(candidate.prompt)
        #expect(prompt.contains("D-3"))
        #expect(prompt.contains("Who and Date"))
        #expect(!prompt.contains("ROW_THREE_TEXT_DATA"))
        #expect(candidate.attachments["issue.md"]?.contains("ROW_THREE_TEXT_DATA") == true)
        #expect(candidate.key.head.hasPrefix("rows-"))
        #expect(candidate.decide?.rows == candidate.key.head)
        #expect(candidate.decide?.table != nil)
        // The team's own prompt gets the rows by placeholder.
        let own = try #require(try F.candidate(decide: #"{"by":["dani"],"table":{"names":{"Dani":"dani"}},"prompt":"Rows: {rows} on {issue}"}"#))
        #expect(own.prompt == "Rows: D-3 on 7")
        // A mention ask carries no rows and the plan no table.
        let mention = try #require(try F.candidate(F.issue(rows: [F.decidedByMe], comments: [F.comment("2", author: "lee", body: "@dani which?")])))
        #expect(mention.decide?.rows == nil)
        #expect(mention.prompt?.contains("Decisions table, addressed") == false)
    }

    @Test func theDraftNamesTheRowToo() throws {
        let flow = try F.flow()
        let ask = try #require(IssueAsks.ask(in: F.issue(), me: F.me, table: flow.decide?.table))
        let draft = try #require(IssueDrafts.candidate(ask: ask, issue: F.issue(), agents: F.agents, defaultBranch: "main", me: F.me,
                                                       table: flow.decide?.table))
        #expect(draft.prompt?.contains("D-3") == true)
        #expect(draft.prompt?.contains("ROW_THREE_TEXT_DATA") == false)
        #expect(draft.key.head == ask.commentID)
        // Without the table the same ask is not a draft: the row is not an ask there.
        #expect(IssueDrafts.candidate(ask: ask, issue: F.issue(), agents: F.agents, defaultBranch: "main", me: F.me) == nil)
    }

    @Test func exceptionsAndTheDecidersStillHold() throws {
        #expect(try F.candidate(F.issue(labels: ["tier:high-risk"])) == nil)
        #expect(try F.candidate(me: "bogdan") == nil)
        // Bogdan's Bton, same flow: the "Dani" row is not his, so no ask at all for him.
        #expect(IssueAsks.ask(in: F.issue(), me: "bogdan", table: F.table) == nil)
    }

    @Test func underTheLeaseAChangedTableRefusesAndACommentDoesNot() throws {
        let plan = try #require(try F.candidate()?.decide)
        let open = IssueNow(state: "OPEN", labels: [], assignees: [])
        let same = IssueDecisions.Live(now: open, body: F.body(rows: [F.decidedByMe, F.openForMe]),
                                       comments: [F.comment("9", author: "lee", second: 500)])
        #expect(IssueDecisions.refusal(same, plan: plan) == nil)
        let decided = IssueDecisions.Live(now: open, body: F.body(rows: [F.decidedByMe, F.openForMe.replacingOccurrences(of: "open", with: "2026-11-01")]), comments: [])
        #expect(IssueDecisions.refusal(decided, plan: plan)?.contains("Decisions table") == true)
        let closed = IssueDecisions.Live(now: IssueNow(state: "CLOSED", labels: [], assignees: []), body: same.body, comments: [])
        #expect(IssueDecisions.refusal(closed, plan: plan) != nil)
    }
}
