@testable import BtonCore
import Testing

@Suite(ProcessBound())
struct ListFilterAcceptanceTests {
    /// The Issues tab's reason to exist: the asks that still need me, apart from the ones already answered or drafted.
    @Test func askNeedsAReplyUntilADraftIsReadyOrPosted() {
        let needs = ListFilter.IssueState.needsReply.rawValue
        #expect(ListFilter.askStates(posted: false, handoff: false, draft: nil, decision: nil) == [needs])
        #expect(ListFilter.askStates(posted: false, handoff: false, draft: .running, decision: nil) == [needs, "working"])
        #expect(ListFilter.askStates(posted: false, handoff: false, draft: .succeeded, decision: nil) == ["draft-ready"])
        #expect(ListFilter.askStates(posted: true, handoff: false, draft: .succeeded, decision: nil) == ["reply-posted"])
        #expect(ListFilter.askStates(posted: false, handoff: false, draft: nil, decision: .succeeded) == ["reply-posted"])
        // A failed draft still needs me, and shows under Failed too.
        #expect(ListFilter.askStates(posted: false, handoff: true, draft: .failed, decision: nil) == [needs, "failed", "handed-off"])
    }

    @Test func readyIssueStatesFollowAssigneesAndTheNewestJob() {
        #expect(ListFilter.readyStates(isReady: true, assignees: [], job: nil) == ["unclaimed"])
        #expect(ListFilter.readyStates(isReady: true, assignees: ["me"], job: .running) == ["owned", "working"])
        #expect(ListFilter.readyStates(isReady: false, assignees: [], job: .cancelled) == ["failed"])
    }

    @Test func dynamicFiltersListEachNameOnceAndKeepTheListsOrder() {
        let prs = ListFilter.pullRequestFilters(moves: ["review", "merge", "Review", "review"])
        #expect(prs.map(\.id).suffix(2) == ["move:review", "move:merge"])
        let triage = ListFilter.triageFilters(labels: [["priority:p2", "type:bug"], ["Type:Bug", "priority:p1"]])
        #expect(triage.map(\.id) == ["label:type:bug", "label:priority:p2", "label:priority:p1"])
        #expect(ListFilter.triageIds(labels: ["Type:Bug", "stage:spec"]).contains("label:type:bug"))
    }
}
