@testable import BtonCore
import Foundation
import Testing

struct ResolveReviewFallbackAcceptanceTests {
    @Test(arguments: ["small", "large"])
    func reviewOnlyAgentResolvesWithBuiltInPromptAndNoReviewSideEffects(tier: String) throws {
        let flow = try ResolveReviewFallbackFixture.flow()
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveReviewFallbackFixture.pr(body: "Tier: \(tier)"),
            flow: flow, me: "owner", repo: ResolveReviewFallbackFixture.repo))
        #expect(candidate.move.name == "resolve")
        #expect(candidate.move.owner == "owner")
        #expect(candidate.move.tier == tier)
        #expect(candidate.agent == "\(tier)-reviewer")
        #expect(candidate.command == nil)
        #expect(!candidate.postComment)
        #expect(candidate.skipsChecks)
        #expect(candidate.prompt == DispatchPlanner.resolvePrompt(number: 42, base: "develop"))
        #expect(candidate.prompt != "Do not use this review prompt.")
        #expect(candidate.key == JobKey(repo: ResolveReviewFallbackFixture.repo, item: "pr-42",
                                       move: "resolve", head: ResolveReviewFallbackFixture.head))
    }

    @Test func resolveAgentTakesPrecedenceOverFixAndReviewAndKeepsItsOwnPrompt() throws {
        let flow = try ResolveReviewFallbackFixture.flow(extraDispatch:
            #""resolve":{"agent":{"large":"large-resolver"},"prompt":"Resolve #{number} onto {base}."},"fix":{"agent":{"large":"large-fixer"},"prompt":"Unused fix prompt."},"#)
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveReviewFallbackFixture.pr(body: "Tier: large"),
            flow: flow, me: "owner", repo: ResolveReviewFallbackFixture.repo))
        #expect(candidate.agent == "large-resolver")
        #expect(candidate.prompt == "Resolve #42 onto develop.")
    }

    @Test(arguments: ["", #""resolve":{"agent":{"small":"small-resolver"},"prompt":"Unused resolve prompt."},"#])
    func fixAgentTakesPrecedenceOverReviewWhenResolveHasNoAgentForTier(resolve: String) throws {
        let flow = try ResolveReviewFallbackFixture.flow(extraDispatch: resolve +
            #""fix":{"agent":{"large":"large-fixer"},"prompt":"Do not use this fix prompt."},"#)
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveReviewFallbackFixture.pr(body: "Tier: large"),
            flow: flow, me: "owner", repo: ResolveReviewFallbackFixture.repo))
        #expect(candidate.agent == "large-fixer")
        #expect(candidate.prompt == DispatchPlanner.resolvePrompt(number: 42, base: "develop"))
    }

    @Test(arguments: [
        #""resolve":{"agent":{"small":"small-resolver"},"prompt":"Unused resolve prompt."},"#,
        #""fix":{"agent":{"small":"small-fixer"},"prompt":"Unused fix prompt."},"#,
        #""resolve":{"agent":{"small":"small-resolver"},"prompt":"Unused resolve prompt."},"fix":{"agent":{"small":"small-fixer"},"prompt":"Unused fix prompt."},"#
    ])
    func reviewAgentIsUsedWhenEarlierRulesLackThePullRequestsTier(extraDispatch: String) throws {
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveReviewFallbackFixture.pr(body: "Tier: large"),
            flow: ResolveReviewFallbackFixture.flow(extraDispatch: extraDispatch),
            me: "owner", repo: ResolveReviewFallbackFixture.repo))
        #expect(candidate.agent == "large-reviewer")
        #expect(candidate.prompt == DispatchPlanner.resolvePrompt(number: 42, base: "develop"))
        #expect(candidate.move.name == "resolve")
        #expect(candidate.command == nil)
        #expect(!candidate.postComment)
        #expect(candidate.skipsChecks)
    }

    @Test(arguments: ["", #""resolve":{"agent":{"small":"small-resolver"}},"fix":{"agent":{"small":"small-fixer"}},"#])
    func missingTierInEveryAvailableAgentMapCannotResolve(extraDispatch: String) throws {
        let flow = try ResolveReviewFallbackFixture.flow(extraDispatch: extraDispatch,
            reviewDispatch: #""review":{"agent":{"small":"small-reviewer"},"prompt":"Review #{number}.","post":"comment"},"#)
        #expect(DispatchPlanner.resolveCandidate(ResolveReviewFallbackFixture.pr(body: "Tier: large"),
            flow: flow, me: "owner", repo: ResolveReviewFallbackFixture.repo) == nil)
    }

    @Test func mergeCommandAloneCannotResolve() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveReviewFallbackFixture.pr(),
            flow: try ResolveReviewFallbackFixture.flow(reviewDispatch: ""),
            me: "owner", repo: ResolveReviewFallbackFixture.repo) == nil)
    }

    @Test(arguments: ["other-author", "draft", "not-conflicting", "other-base", "untrusted"])
    func reviewFallbackPreservesResolveGuards(ineligible: String) throws {
        let pr = ResolveReviewFallbackFixture.pr(
            author: ineligible == "other-author" ? "other" : "owner",
            draft: ineligible == "draft",
            base: ineligible == "other-base" ? "main" : "develop",
            association: ineligible == "untrusted" ? "CONTRIBUTOR" : "OWNER",
            conflicting: ineligible != "not-conflicting")
        #expect(DispatchPlanner.resolveCandidate(pr,
            flow: try ResolveReviewFallbackFixture.flow(),
            me: "owner", repo: ResolveReviewFallbackFixture.repo) == nil)
    }
}

private enum ResolveReviewFallbackFixture {
    static let repo = "synthetic/project"
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func pr(author: String = "owner", draft: Bool = false, base: String = "develop",
                   association: String = "OWNER", body: String = "",
                   conflicting: Bool = true) -> PullRequest {
        var pr = PullRequest(repo: repo, number: 42, title: "Synthetic PR", author: author,
            authorAssociation: association, url: URL(string: "https://example.invalid/pr/42")!,
            headSha: head, headRef: "feature", baseRef: base, body: body, isDraft: draft,
            labels: [], assignees: [], comments: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        pr.conflicting = conflicting
        return pr
    }

    static func flow(extraDispatch: String = "", reviewDispatch: String =
        #""review":{"agent":{"small":"small-reviewer","large":"large-reviewer"},"prompt":"Do not use this review prompt.","post":"comment","checks":true},"#
    ) throws -> Flow {
        let json = """
        {"version":1,"base":"develop",
         "tier":{"marker":"Tier:","values":["small","large"],"default":"small"},
         "reviews":{"small":[{"heading":"## Review:","notByAuthor":true}],
                    "large":[{"heading":"## Review:","notByAuthor":true}]},"fixed":"## Fixed:",
         "moves":[{"move":"review","when":["no_review_or_response_newer"],"who":"author"}],
         "dispatch":{\(extraDispatch)\(reviewDispatch)"merge":{"command":["merge","{number}"]}}}
        """
        return try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
    }
}
