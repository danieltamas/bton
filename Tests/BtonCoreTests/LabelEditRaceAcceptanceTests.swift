@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct LabelEditRaceAcceptanceTests {
    private let repo = IssuePagingPayload.repo

    @Test func editDuringOnReadRemovesSettledIssueFromReturnedTriage() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try writeIssues(to: f, labels: ["stage:spec", "type:bug"])
        let engine = try f.engine()

        let snapshot = await engine.tick(dispatching: false, onRead: { read in
            #expect(read.problem == nil)
            #expect(read.triage.map(\.number) == [1, 2])
            #expect(read.triage.first { $0.number == 1 }?.labels == ["stage:spec", "type:bug"])
            await engine.noteLabelEdit(repo: repo, number: 1,
                                       add: ["stage:ready"], remove: ["stage:spec"])
        })

        #expect(snapshot.problem == nil)
        let edited = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
        #expect(Set(edited.labels) == ["stage:ready", "type:bug"])
        #expect(snapshot.triage.map(\.number) == [2])
    }

    @Test func editShowsImmediatelySurvivesNextReadAndThenYieldsToGitHub() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try writeIssues(to: f, labels: ["stage:spec", "type:bug"])
        let engine = try f.engine()
        try #require(await engine.readIssues(repo))
        let untouched = try #require(await engine.openIssues[repo]?.first { $0.number == 2 })

        let before = Date.now
        await engine.noteLabelEdit(repo: repo.uppercased(), number: 1,
                                   add: ["stage:ready"], remove: ["stage:spec"])
        let after = Date.now
        let edited = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
        #expect(Set(edited.labels) == ["stage:ready", "type:bug"])
        #expect(edited.assignees == ["OwNeR", "teammate"])
        let changedAt = try #require(edited.stateChangedAt)
        #expect(changedAt >= before && changedAt <= after)
        #expect(await engine.openIssues[repo]?.first { $0.number == 2 } == untouched)

        // A read that started after the edit is GitHub's word after the write (spec rule 3): it
        // drops the edit, so what the fake gh still serves is what the engine shows.
        try #require(await engine.readIssues(repo))
        let reread = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
        #expect(Set(reread.labels) == ["stage:spec", "type:bug"])

        try writeIssues(to: f, labels: ["stage:ready", "type:bug"])
        try #require(await engine.readIssues(repo))
        #expect(Set(try #require(await engine.openIssues[repo]?.first { $0.number == 1 }).labels)
                == ["stage:ready", "type:bug"])

        // A later server change proves that the recorded edit has been discarded.
        try writeIssues(to: f, labels: ["stage:in-progress", "type:task"])
        try #require(await engine.readIssues(repo))
        #expect(Set(try #require(await engine.openIssues[repo]?.first { $0.number == 1 }).labels)
                == ["stage:in-progress", "type:task"])
    }

    @Test(arguments: [false, true])
    func editDuringReadSurvivesItsStaleResponse(issueAlreadyCached: Bool) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.release(); f.remove() }
        try writeIssues(to: f, labels: ["stage:spec", "type:bug"])
        let engine = try f.engine()
        if issueAlreadyCached { try #require(await engine.readIssues(repo)) }
        try f.clearCalls()
        try f.hold()
        let read = Task { await engine.readIssues(repo) }
        defer { read.cancel() }
        try await f.waitBlocked(1)

        let before = Date.now
        await engine.noteLabelEdit(repo: repo.uppercased(), number: 1,
                                   add: ["stage:ready"], remove: ["stage:spec"])
        let after = Date.now
        if issueAlreadyCached {
            let immediate = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
            #expect(Set(immediate.labels) == ["stage:ready", "type:bug"])
        } else {
            // Recording an edit for an issue not yet loaded must not invent a list entry.
            #expect(await engine.openIssues[repo]?.isEmpty != false)
        }

        f.release()
        try #require(await read.value)
        let issues = try #require(await engine.openIssues[repo])
        #expect(issues.map(\.number) == [1, 2])
        let edited = try #require(issues.first { $0.number == 1 })
        #expect(Set(edited.labels) == ["stage:ready", "type:bug"])
        #expect(edited.assignees == ["OwNeR", "teammate"])
        let changedAt = try #require(edited.stateChangedAt)
        #expect(changedAt >= before && changedAt <= after)
        let untouched = try #require(issues.first { $0.number == 2 })
        #expect(untouched.labels == ["stage:spec"])
        #expect(untouched.stateChangedAt == nil)
    }

    @Test func giveBackRemovesOnlyTheMatchingLoginIgnoringCaseDuringARead() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.release(); f.remove() }
        try writeIssues(to: f, labels: ["stage:spec", "type:bug"])
        let engine = try f.engine()
        try #require(await engine.readIssues(repo))
        try f.clearCalls()
        try f.hold()
        let read = Task { await engine.readIssues(repo) }
        defer { read.cancel() }
        try await f.waitBlocked(1)

        await engine.noteLabelEdit(repo: repo, number: 1, add: ["stage:ready"],
                                   remove: ["stage:spec"], unassign: "owner")
        let immediate = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
        #expect(immediate.assignees == ["teammate"])
        #expect(Set(immediate.labels) == ["stage:ready", "type:bug"])
        f.release()
        try #require(await read.value)
        let reread = try #require(await engine.openIssues[repo]?.first { $0.number == 1 })
        #expect(reread.assignees == ["teammate"])
        #expect(Set(reread.labels) == ["stage:ready", "type:bug"])
        #expect(reread.stateChangedAt == immediate.stateChangedAt)
        #expect(await engine.openIssues[repo]?.first { $0.number == 2 }?.assignees
                == ["OwNeR", "teammate"])
    }

    @Test(.disabled("No clock or edit timestamp injection seam; TTL cannot be exercised without editing internal storage."))
    func editOlderThanLabelEditTTLIsNotAppliedToAnEarlierRead() {
        // The required scenario needs a read to start, an edit to be noted, and then
        // more than Engine.labelEditTTL to pass before that same read completes.
        // Do not mutate labelEdits or wait ten minutes to simulate this boundary.
        Issue.record("A controllable clock or timestamp seam is required for the TTL acceptance case.")
    }

    @Test func issueCopyReplacesLabelsAssigneesAndStateTimeAndKeepsEveryOtherField() {
        let original = issueWithEveryField()
        let changedAt = original.createdAt.addingTimeInterval(100)
        let changed = original.with(labels: ["stage:ready", "type:task"], assignees: [],
                                    stateChangedAt: changedAt)
        #expect(changed.labels == ["stage:ready", "type:task"])
        #expect(changed.assignees.isEmpty)
        #expect(changed.stateChangedAt == changedAt)
        expectSameContent(changed, original)
        #expect(original.labels == ["stage:spec", "type:bug"])
        #expect(original.assignees == ["OwNeR", "teammate"])
        #expect(original.stateChangedAt == original.createdAt.addingTimeInterval(10))
    }

    @Test func issueCopyWithOnlyLabelsKeepsAssigneesAndStateTime() {
        let original = issueWithEveryField()
        let changed = original.with(labels: [])
        #expect(changed.labels.isEmpty)
        #expect(changed.assignees == original.assignees)
        #expect(changed.stateChangedAt == original.stateChangedAt)
        expectSameContent(changed, original)
    }

    private func writeIssues(to f: IssuePagingEngineFixture, labels: [String]) throws {
        var edited = IssuePagingPayload.node(1)
        edited["labels"] = ["nodes": labels.map { ["name": $0] }]
        edited["assignees"] = ["nodes": [["login": "OwNeR"], ["login": "teammate"]]]
        var untouched = IssuePagingPayload.node(2)
        untouched["labels"] = ["nodes": [["name": "stage:spec"]]]
        untouched["assignees"] = edited["assignees"]
        let payload: [String: Any] = ["data": ["repository": ["issues": [
            "nodes": [edited, untouched],
            "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]
        ]]]]
        try JSONSerialization.data(withJSONObject: payload).write(to: f.file("page-1.json"))
    }

    private func issueWithEveryField() -> OpenIssue {
        let createdAt = Date(timeIntervalSince1970: 1_000_000)
        let comment = IssueComment(id: "42", author: "reviewer", authorAssociation: "MEMBER",
                                   body: "Keep this comment", createdAt: createdAt.addingTimeInterval(20),
                                   url: URL(string: "https://example.invalid/issues/1#issuecomment-42"))
        return OpenIssue(repo: repo, number: 1, title: "Keep this title",
                         url: URL(string: "https://example.invalid/issues/1")!, createdAt: createdAt,
                         author: "teammate", authorAssociation: "MEMBER", body: "Keep this body",
                         comments: [comment], labels: ["stage:spec", "type:bug"],
                         assignees: ["OwNeR", "teammate"], stateChangedAt: createdAt.addingTimeInterval(10))
    }

    private func expectSameContent(_ changed: OpenIssue, _ original: OpenIssue) {
        #expect(changed.repo == original.repo)
        #expect(changed.number == original.number)
        #expect(changed.title == original.title)
        #expect(changed.url == original.url)
        #expect(changed.createdAt == original.createdAt)
        #expect(changed.author == original.author)
        #expect(changed.authorAssociation == original.authorAssociation)
        #expect(changed.body == original.body)
        #expect(changed.comments == original.comments)
    }
}
