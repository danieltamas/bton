@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct HandoffAcceptanceTests {
    @Test func bodyHasMentionFirstTextAndMarkerLast() throws {
        let body = try Handoff.body(to: "bogdan", text: "Please choose an option.")
        #expect(body == "@bogdan\n\nPlease choose an option.\n\n<!-- bton:handoff to=bogdan -->")
    }

    @Test(arguments: ["", " ", "\n\t"])
    func emptyTextIsRejected(text: String) {
        #expect(throws: Handoff.Problem.emptyText) {
            try Handoff.body(to: "bogdan", text: text)
        }
    }

    @Test func textLengthBoundary() throws {
        let text = String(repeating: "a", count: 4_000)
        let body = try Handoff.body(to: "bogdan", text: text)
        #expect(body.contains(text))
        #expect(throws: Handoff.Problem.tooLong) {
            try Handoff.body(to: "bogdan", text: text + "a")
        }
    }

    @Test func anotherMentionIsRejected() {
        #expect(throws: Handoff.Problem.otherMention("vlad")) {
            try Handoff.body(to: "bogdan", text: "Please ask @vlad to decide.")
        }
    }

    @Test func htmlCommentIsRejected() {
        #expect(throws: Handoff.Problem.markup) {
            try Handoff.body(to: "bogdan", text: "Please decide. <!-- hidden text -->")
        }
    }

    @Test(arguments: ["", "@bogdan", "bad login", "bad/login"])
    func badLoginIsRejected(login: String) {
        #expect(throws: Handoff.Problem.badLogin) {
            try Handoff.body(to: login, text: "Please decide.")
        }
    }

    @Test func addressedPersonsOwnMentionIsAllowed() throws {
        let body = try Handoff.body(to: "bogdan", text: "Please decide, @bogdan.")
        #expect(body == "@bogdan\n\nPlease decide, @bogdan.\n\n<!-- bton:handoff to=bogdan -->")
    }

    @Test func markerOnlyIdentifiesItsAddressee() throws {
        let body = try Handoff.body(to: "bogdan", text: "Please decide.")
        #expect(Handoff.isHandoff(body, to: "bogdan"))
        #expect(!Handoff.isHandoff(body, to: "vlad"))
        #expect(!Handoff.isHandoff("@bogdan Please decide.", to: "bogdan"))
    }

    @Test func askingCommentWithMyMarkerIsAHandoff() throws {
        let body = try Handoff.body(to: "bogdan", text: "Please decide.")
        let issue = issue(comments: [comment(id: "ask", body: body)])
        let ask = try #require(IssueAsks.ask(in: issue, me: "bogdan"))
        #expect(ask.commentID == "ask")
        #expect(ask.handoff)
    }

    @Test func plainMentionIsAnAskWithoutAHandoff() throws {
        let issue = issue(comments: [
            comment(id: "ask", body: "@bogdan Please decide.")
        ])
        let ask = try #require(IssueAsks.ask(in: issue, me: "bogdan"))
        #expect(ask.commentID == "ask")
        #expect(!ask.handoff)
    }

    @Test func anotherPersonsMarkerDoesNotTagMyAsk() throws {
        let issue = issue(comments: [
            comment(id: "ask", body: "@bogdan Please decide.\n\n<!-- bton:handoff to=vlad -->")
        ])
        let ask = try #require(IssueAsks.ask(in: issue, me: "bogdan"))
        #expect(!ask.handoff)
    }

    @Test func markerInEarlierCommentDoesNotTagTheAskingComment() throws {
        let marked = try Handoff.body(to: "bogdan", text: "First decision.")
        let issue = issue(comments: [
            comment(id: "earlier", body: marked, time: 1),
            comment(id: "ask", body: "@bogdan Please decide this too.", time: 2)
        ])
        let ask = try #require(IssueAsks.ask(in: issue, me: "bogdan"))
        #expect(ask.commentID == "ask")
        #expect(!ask.handoff)
    }

    @Test func nonCollaboratorMarkedCommentProducesNoAsk() throws {
        let body = try Handoff.body(to: "bogdan", text: "Please decide.")
        let issue = issue(comments: [
            comment(id: "ask", body: body, association: "NONE")
        ])
        #expect(IssueAsks.ask(in: issue, me: "bogdan") == nil)
    }

    @Test(arguments: ["review", "fix", "resolve", "decide", "schedule"])
    func everyMoveIncludesHandoffCommand(move: String) {
        #expect(PRPlaybook.text(for: move).contains("bton handoff"))
    }

    @Test func playbookVersionIsFour() {
        #expect(PRPlaybook.version == 4)
    }

    @Test func emptyInboxHasNoIssue() throws {
        #expect(try Handoff.inboxIssue(in: Data("[]".utf8)) == nil)
    }

    @Test func inboxChoosesLowestIssueNumber() throws {
        let data = Data(#"[{"number":12},{"number":7},{"number":19}]"#.utf8)
        #expect(try Handoff.inboxIssue(in: data) == 7)
    }

    @Test func inboxRejectsNonJSON() {
        #expect(throws: (any Error).self) {
            try Handoff.inboxIssue(in: Data("garbage".utf8))
        }
    }

    @Test func missingInboxExplainsHowToCreateIt() throws {
        #expect(Handoff.inboxLabel == "bton:inbox")
        let message = try #require(Handoff.Problem.noInbox(repo: "team/project").errorDescription)
        #expect(message.contains("team/project"))
        #expect(message.contains("bton:inbox"))
        #expect(message.contains("gh issue create"))
    }

    private func issue(comments: [IssueComment]) -> OpenIssue {
        OpenIssue(
            repo: "team/project",
            number: 451,
            title: "Choose an option",
            url: URL(string: "https://github.com/team/project/issues/451")!,
            createdAt: Date(timeIntervalSince1970: 0),
            author: "owner",
            authorAssociation: "OWNER",
            body: "Options and supporting evidence.",
            comments: comments
        )
    }

    private func comment(
        id: String,
        body: String,
        association: String = "OWNER",
        time: TimeInterval = 1
    ) -> IssueComment {
        IssueComment(
            id: id,
            author: "teammate",
            authorAssociation: association,
            body: body,
            createdAt: Date(timeIntervalSince1970: time),
            url: nil
        )
    }
}
