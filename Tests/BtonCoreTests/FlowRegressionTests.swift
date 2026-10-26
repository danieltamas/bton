import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FlowRegressionTests {
    @Test(arguments: ["", ":", "draft:", "label:", "draft"])
    func malformedPredicatesNeverHold(predicate: String) throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("examples/team.flow.json"))
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let moves = try #require(json["moves"] as? [[String: Any]])
        json["moves"] = [["move": "predicate-probe", "when": [predicate], "who": "author"]] + moves
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
        let page = try GitHubClient.decodeOpenPullRequests(Self.graphql(draft: true), repo: "o/r")
        let pr = try #require(page.pullRequests.first)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == (predicate == "draft" ? "predicate-probe" : "finish"))
    }

    @Test(arguments: [
        ("## Review: approve0 (head abc1234)", ""),
        ("## Review: approve_x (head abc1234)", ""),
        ("## Review: approved (head abc1234)", ""),
        ("## Review: approve (head abc1234)", "approve"),
        ("## Review: APPROVE: looks good (head abc1234)", "approve"),
        ("## Review: changes needed (head abc1234)", "changes")
    ])
    func verdictMustBeAWholeWord(line: String, verdict: String) {
        let review = FlowEngine.review(fromFirstLine: line, headings: ["## Review:"])
        if verdict.isEmpty {
            #expect(review == nil)
        } else {
            #expect(review?.verdict.rawValue == verdict)
            #expect(review?.head == "abc1234")
        }
    }

    @Test(arguments: ["next", "last", "absent"])
    func paginationDecodesNextCursor(scenario: String) throws {
        let pageInfo: [String: Any]? = scenario == "absent" ? nil : [
            "hasNextPage": scenario == "next", "endCursor": "Y3Vy"
        ]
        let page = try GitHubClient.decodeOpenPullRequests(Self.graphql(pageInfo: pageInfo), repo: "o/r")
        #expect(page.pullRequests.count == 1)
        #expect(page.nextPage == (scenario == "next" ? "Y3Vy" : nil))
    }

    // Synthetic data in the exact envelope printed by `gh api graphql`.
    private static func graphql(draft: Bool = false, pageInfo: [String: Any]? = nil) throws -> Data {
        let node: [String: Any] = [
            "number": 325, "title": "Synthetic PR", "url": "https://github.com/o/r/pull/325",
            "isDraft": draft, "headRefOid": "abc1234" + String(repeating: "a", count: 33),
            "headRefName": "feat/x", "baseRefName": "develop", "body": "**Tier:** feature",
            "updatedAt": "2026-10-19T11:00:00Z", "authorAssociation": "OWNER",
            "author": ["login": "dev-b"], "labels": ["nodes": []],
            "assignees": ["nodes": [["login": "dev-c"]]], "comments": ["nodes": []]
        ]
        var pullRequests: [String: Any] = ["nodes": [node]]
        if let pageInfo { pullRequests["pageInfo"] = pageInfo }
        return try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "lead-dev"], "repository": [
                "defaultBranchRef": ["name": "main"], "pullRequests": pullRequests
            ]
        ]])
    }
}
