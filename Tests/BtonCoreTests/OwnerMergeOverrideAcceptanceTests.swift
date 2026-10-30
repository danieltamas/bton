@testable import BtonCore
import Foundation
import Testing

struct OwnerMergeOverrideAcceptanceTests {
    enum Scenario: String, CaseIterable, Sendable {
        case sameHeadAndMyMerge
        case sameHeadAndMyResolve
        case caseInsensitiveOwner
        case headMoved
        case differentMove
        case noMove
        case mergeBelongsToReviewer
        case resolveBelongsToSomeoneElse
        case unassignedMove
    }

    @Test(arguments: Scenario.allCases)
    func ownerPressNeedsOverride(scenario: Scenario) {
        let me = "danieltamas"
        let isResolve = scenario == .sameHeadAndMyResolve || scenario == .resolveBelongsToSomeoneElse
        let pressedMove = isResolve ? "resolve" : "merge"
        let request = JobKey(repo: "synthetic/project", item: "pr-42", move: pressedMove, head: "seen-head")
        var pr = PullRequest(repo: request.repo, number: 42, title: "Synthetic PR", author: me,
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/42")!,
            headSha: scenario == .headMoved ? "new-head" : "seen-head", headRef: "feature",
            baseRef: "main", body: "", isDraft: false, labels: [], assignees: ["vladnegrean14"],
            comments: [], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let owner: String?
        switch scenario {
        case .mergeBelongsToReviewer, .resolveBelongsToSomeoneElse: owner = "vladnegrean14"
        case .unassignedMove: owner = nil
        case .caseInsensitiveOwner: owner = "DanielTamas"
        default: owner = me
        }
        if scenario != .noMove {
            pr.move = Move(name: scenario == .differentMove ? "review" : pressedMove,
                owner: owner, ownerFromRotation: false, tier: "feature", hasDispatch: true)
        }
        let expected: Bool
        switch scenario {
        case .sameHeadAndMyMerge, .sameHeadAndMyResolve, .caseInsensitiveOwner: expected = false
        default: expected = true
        }
        #expect(Engine.pressNeedsOverride(request, pr: pr, me: me) == expected)
    }
}
