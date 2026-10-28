import BtonCore
import Foundation
import Testing

/// A fork can name its branches `develop` and `main` too: only this repo's own branch pair,
/// opened by someone trusted, is the release PR.
struct ReleaseForkRegressionTests {
    private func flow() throws -> Flow {
        let json = #"{"version":1,"base":"develop","tier":{"marker":"Tier:","values":["small"],"default":"small"},"reviews":{},"fixed":"Fixed:","moves":[],"dispatch":{},"release":{"from":"develop","to":"main","who":"owner","when":["ahead_commits:1"]}}"#
        return try #require(Flow.load(Data(json.utf8)).flow)
    }

    private func pr(association: String = "OWNER", fork: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: "acme/app", number: 3, title: "Release", author: "someone", authorAssociation: association,
                             url: URL(string: "https://example.invalid/pr/3")!, headSha: "abc", headRef: "develop", baseRef: "main",
                             body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
        pr.isCrossRepository = fork
        return pr
    }

    @Test func onlyTheRepoOwnTrustedBranchPair() throws {
        let flow = try flow()
        let release = try #require(flow.release)
        #expect(Release.pullRequest([pr()], release: release)?.number == 3)
        #expect(Release.pullRequest([pr(fork: true)], release: release) == nil)
        #expect(Release.pullRequest([pr(association: "NONE")], release: release) == nil)
        #expect(Release.pullRequest([pr(association: "CONTRIBUTOR")], release: release) == nil)
        #expect(Release.isRelease(pr(), flow: flow))
        #expect(!Release.isRelease(pr(fork: true), flow: flow))
    }

    @Test func aForkPairStillGetsTheFlowTreatment() throws {
        let flow = try flow()
        // A fork's PR is an ordinary PR: the flow decides its move as for any other.
        #expect(FlowEngine.move(for: pr(fork: true), flow: flow) == FlowEngine.move(for: pr(fork: true), flow: try #require(Flow.load(Data(#"{"version":1,"base":"develop","tier":{"marker":"Tier:","values":["small"],"default":"small"},"reviews":{},"fixed":"Fixed:","moves":[],"dispatch":{}}"#.utf8)).flow)))
        #expect(FlowEngine.move(for: pr(), flow: flow) == nil)
    }

    @Test func anUnansweredQueryCountsAsAFork() throws {
        let data = Data(#"{"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":3,"title":"Release","url":"https://example.invalid/pr/3","isDraft":false,"headRefOid":"abc","headRefName":"develop","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","mergeable":"MERGEABLE","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}},{"number":4,"title":"Release","url":"https://example.invalid/pr/4","isDraft":false,"headRefOid":"abd","headRefName":"develop","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","mergeable":"MERGEABLE","authorAssociation":"OWNER","isCrossRepository":false,"author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}"#.utf8)
        let prs = try GitHubClient.decodeOpenPullRequests(data, repo: "acme/app").pullRequests
        #expect(prs.map(\.isCrossRepository) == [true, false])
    }
}
