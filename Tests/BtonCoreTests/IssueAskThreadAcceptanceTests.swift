import BtonCore
import Foundation
import Testing

private enum IssueAskThreadFixture {
    static func date(_ second: Int) -> Date {
        Date(timeIntervalSince1970: 1_792_368_000 + Double(second))
    }

    static func comment(_ id: String, author: String = "teammate", body: String,
                        second: Int) -> IssueComment {
        IssueComment(id: id, author: author, authorAssociation: "MEMBER", body: body,
                     createdAt: date(second),
                     url: URL(string: "https://example.invalid/issues/7#issuecomment-\(id)"))
    }

    static func issue(body: String = "Issue context", comments: [IssueComment]) -> OpenIssue {
        OpenIssue(repo: "synthetic/project", number: 7, title: "Thread question",
                  url: URL(string: "https://example.invalid/issues/7")!, createdAt: date(0),
                  author: "issue-author", authorAssociation: "MEMBER", body: body, comments: comments)
    }

    static func bodyEntry(_ issue: OpenIssue) -> IssueComment {
        IssueComment(id: "body", author: issue.author, authorAssociation: issue.authorAssociation,
                     body: issue.body, createdAt: issue.createdAt, url: nil)
    }
}

struct IssueAskThreadAcceptanceTests {
    @Test func commentAskIncludesBodyAndShuffledCommentsInTimeOrder() throws {
        let earlier = IssueAskThreadFixture.comment("21", body: "Earlier context", second: 1)
        let asking = IssueAskThreadFixture.comment("22", body: "@dani which option?", second: 2)
        let later = IssueAskThreadFixture.comment("23", body: "More context", second: 3)
        let issue = IssueAskThreadFixture.issue(comments: [later, asking, earlier])

        let ask = try #require(IssueAsks.ask(in: issue, me: "dani"))

        #expect(ask.thread == [IssueAskThreadFixture.bodyEntry(issue), earlier, asking, later])
        #expect(ask.commentID == asking.id)
        #expect(ask.thread.first(where: { $0.id == ask.commentID }) == asking)
    }

    @Test func bodyAskIncludesBodyAndLaterComments() throws {
        let earlier = IssueAskThreadFixture.comment("21", body: "First detail", second: 1)
        let later = IssueAskThreadFixture.comment("22", body: "Second detail", second: 2)
        let issue = IssueAskThreadFixture.issue(body: "@dani can you decide?", comments: [later, earlier])

        let ask = try #require(IssueAsks.ask(in: issue, me: "dani"))

        #expect(ask.commentID == "body")
        #expect(ask.thread.first?.id == "body")
        #expect(ask.thread == [IssueAskThreadFixture.bodyEntry(issue), earlier, later])
        #expect(ask.thread.first(where: { $0.id == ask.commentID }) == IssueAskThreadFixture.bodyEntry(issue))
    }

    @Test func earlierOwnerCommentAndThirdPersonAfterAskAreKept() throws {
        let mine = IssueAskThreadFixture.comment("21", author: "dani", body: "My earlier input", second: 1)
        let asking = IssueAskThreadFixture.comment("22", body: "@dani ready to choose?", second: 2)
        let thirdPerson = IssueAskThreadFixture.comment("23", author: "third-person",
                                                       body: "Additional context", second: 3)
        let issue = IssueAskThreadFixture.issue(comments: [thirdPerson, mine, asking])

        let ask = try #require(IssueAsks.ask(in: issue, me: "dani"))

        #expect(ask.commentID == asking.id)
        #expect(ask.thread == [IssueAskThreadFixture.bodyEntry(issue), mine, asking, thirdPerson])
    }

    @Test func asksCarriesTheWholeThread() throws {
        let asking = IssueAskThreadFixture.comment("21", body: "@dani which approach?", second: 1)
        let later = IssueAskThreadFixture.comment("22", body: "Supporting detail", second: 2)
        let issue = IssueAskThreadFixture.issue(comments: [later, asking])

        let asks = IssueAsks.asks([issue], me: "dani")
        #expect(asks.count == 1)
        let ask = try #require(asks.first)

        #expect(ask.thread == [IssueAskThreadFixture.bodyEntry(issue), asking, later])
        #expect(ask.commentID == asking.id)
        #expect(ask.thread.first(where: { $0.id == ask.commentID }) == asking)
        #expect(ask.thread == IssueAsks.ask(in: issue, me: "dani")?.thread)
    }
}
