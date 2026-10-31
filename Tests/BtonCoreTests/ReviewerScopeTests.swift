@testable import BtonCore
import Foundation
import Testing

/// The repo's Reviewer setting (`codex:gpt-6-astra medium`) runs the review move; every other
/// move that posts a comment, the decision first, keeps the agent the flow names.
struct ReviewerScopeTests {
    private static let pick = AgentPick(agent: "codex", model: "gpt-6-astra", effort: "medium")

    private static func candidate(move: String, post: Bool = true, agent: String? = "claude") -> DispatchCandidate {
        let pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: "d67db2a8d67db2a8", headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: .now)
        return DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: pr.headSha), agent: agent,
            prompt: "Do \(move).", command: nil, postComment: post, timeout: .seconds(60))
    }

    @Test func reviewRunsWithTheRepoReviewerAndItsRules() {
        let made = Engine.reviewed(Self.candidate(move: "review"), by: Self.pick, rules: "Be brief.")
        #expect(made.agent == "codex")
        #expect(made.model == "gpt-6-astra")
        #expect(made.effort == "medium")
        #expect(made.prompt == "Do review.\n\nReview rules from the reviewer:\nBe brief.")
    }

    @Test func decideKeepsTheFlowAgent() {
        let made = Engine.reviewed(Self.candidate(move: "decide"), by: Self.pick, rules: "Be brief.")
        #expect(made.agent == "claude")
        #expect(made.model == nil)
        #expect(made.effort == nil)
        #expect(made.prompt == "Do decide.")
    }

    @Test func aReviewThatPostsNoCommentOrHasNoAgentIsLeftAlone() {
        let silent = Engine.reviewed(Self.candidate(move: "review", post: false), by: Self.pick, rules: nil)
        #expect(silent.agent == "claude")
        let none = Engine.reviewed(Self.candidate(move: "review", agent: nil), by: Self.pick, rules: nil)
        #expect(none.agent == nil)
    }
}
