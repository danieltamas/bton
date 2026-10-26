@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct MergeAnyAcceptanceTests {
    @Test func pullRequestsDefaultToNotMergeableAndAllowUpdatingMergeability() {
        var pr = MergeAnyFixture.pr()
        #expect(!pr.mergeable)
        pr.mergeable = true
        #expect(pr.mergeable)
        pr.mergeable = false
        #expect(!pr.mergeable)
    }

    @Test func onlyMergeableStateDecodesAsMergeableAndOnlyConflictingAsConflicting() throws {
        let states: [String?] = ["MERGEABLE", "CONFLICTING", "UNKNOWN", nil]
        let nodes = states.enumerated().map { index, state in
            MergeAnyFixture.node(number: index + 1, mergeable: state)
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "owner"], "repository": [
                "defaultBranchRef": ["name": "main"],
                "pullRequests": ["nodes": nodes,
                                 "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]
            ]
        ]])
        let page = try GitHubClient.decodeOpenPullRequests(data, repo: MergeAnyFixture.repo)
        #expect(page.pullRequests.count == 4)
        for (index, _) in states.enumerated() {
            let pr = try #require(page.pullRequests.first { $0.number == index + 1 })
            #expect(pr.mergeable == (index == 0))
            #expect(pr.conflicting == (index == 1))
        }
    }

    @Test(arguments: ["OWNER", "MEMBER", "COLLABORATOR"])
    func trustedAuthorsCanRunTheirFlowsMergeCommand(association: String) throws {
        var pr = MergeAnyFixture.pr(association: association)
        pr.mergeable = true
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr,
            flow: MergeAnyFixture.flow(), me: "owner", repo: MergeAnyFixture.repo))
        #expect(candidate.key == JobKey(repo: MergeAnyFixture.repo, item: "pr-42",
                                        move: "merge", head: MergeAnyFixture.head))
        #expect(candidate.move.name == "merge")
        #expect(candidate.move.owner == "owner")
        #expect(candidate.command == ["bash", "scripts/wt", "merge", "42"])
        #expect(candidate.agent == nil)
        #expect(candidate.timeout == .seconds(420))
    }

    @Test func authorMatchIgnoresCaseAndCandidateOwnerUsesCurrentLogin() throws {
        var pr = MergeAnyFixture.pr(author: "OwNeR")
        pr.mergeable = true
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr,
            flow: MergeAnyFixture.flow(), me: "OWNER", repo: MergeAnyFixture.repo))
        #expect(candidate.move.owner == "OWNER")
    }

    @Test func humanDecideMoveDoesNotPreventMergeCandidate() throws {
        let flow = try MergeAnyFixture.flow()
        var pr = MergeAnyFixture.pr(labels: ["turn:lead"])
        pr.mergeable = true
        let current = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(current.name == "decide")
        #expect(current.owner == "lead")
        #expect(!current.hasDispatch)
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr,
            flow: flow, me: "owner", repo: MergeAnyFixture.repo))
        #expect(candidate.move.name == "merge")
        #expect(candidate.move.owner == "owner")
        #expect(candidate.command == ["bash", "scripts/wt", "merge", "42"])
    }

    @Test func anotherAuthorsPullRequestCannotBeMerged() throws {
        var pr = MergeAnyFixture.pr(author: "other")
        pr.mergeable = true
        #expect(DispatchPlanner.mergeCandidate(pr, flow: try MergeAnyFixture.flow(),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }

    @Test func pullRequestThatIsNotMergeableCannotBeMerged() throws {
        let pr = MergeAnyFixture.pr()
        #expect(DispatchPlanner.mergeCandidate(pr, flow: try MergeAnyFixture.flow(),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }

    @Test func draftPullRequestCannotBeMerged() throws {
        var pr = MergeAnyFixture.pr(draft: true)
        pr.mergeable = true
        #expect(DispatchPlanner.mergeCandidate(pr, flow: try MergeAnyFixture.flow(),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }

    @Test func pullRequestTargetingAnotherBaseCannotBeMerged() throws {
        var pr = MergeAnyFixture.pr(base: "develop")
        pr.mergeable = true
        #expect(DispatchPlanner.mergeCandidate(pr, flow: try MergeAnyFixture.flow(),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }

    @Test func contributorAssociationCannotMergeEvenTheirOwnPullRequest() throws {
        var pr = MergeAnyFixture.pr(association: "CONTRIBUTOR")
        pr.mergeable = true
        #expect(DispatchPlanner.mergeCandidate(pr, flow: try MergeAnyFixture.flow(),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }

    @Test func flowWithoutMergeDispatchCannotProduceMergeCandidate() throws {
        var pr = MergeAnyFixture.pr()
        pr.mergeable = true
        #expect(DispatchPlanner.mergeCandidate(pr,
            flow: try MergeAnyFixture.flow(withMergeDispatch: false),
            me: "owner", repo: MergeAnyFixture.repo) == nil)
    }
}

private enum MergeAnyFixture {
    static let repo = "synthetic/project"
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func pr(author: String = "owner", draft: Bool = false, base: String = "main",
                   association: String = "OWNER", labels: [String] = []) -> PullRequest {
        PullRequest(repo: repo, number: 42, title: "Synthetic PR", author: author,
            authorAssociation: association, url: URL(string: "https://example.invalid/pr/42")!,
            headSha: head, headRef: "feature", baseRef: base, body: "", isDraft: draft,
            labels: labels, assignees: ["reviewer"], comments: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func node(number: Int, mergeable: String?) -> [String: Any] {
        var node: [String: Any] = [
            "number": number, "title": "Synthetic PR", "url": "https://example.invalid/pr/\(number)",
            "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
            "body": "", "updatedAt": "2026-10-19T12:00:00Z", "authorAssociation": "OWNER",
            "author": ["login": "owner"], "labels": ["nodes": []],
            "assignees": ["nodes": []], "comments": ["nodes": []]
        ]
        if let mergeable { node["mergeable"] = mergeable }
        return node
    }

    static func flow(withMergeDispatch: Bool = true) throws -> Flow {
        let dispatch = withMergeDispatch
            ? #"{"merge":{"command":["bash","scripts/wt","merge","{number}"],"timeoutMinutes":7}}"#
            : "{}"
        let json = """
        {"version":1,"base":"main",
         "tier":{"marker":"Tier:","values":["small"],"default":"small"},
         "reviews":{"small":[{"heading":"## Review:","notByAuthor":true}]},"fixed":"## Fixed:",
         "moves":[
           {"move":"decide","when":["label:turn:lead"],"who":"lead"},
           {"move":"review","when":["no_review_or_response_newer"],"who":"assignee"},
           {"move":"merge","when":["approved_current_head"],"who":"author"}],
         "dispatch":\(dispatch)}
        """
        return try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
    }
}
