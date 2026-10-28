import Foundation
import Testing
@testable import BtonCore

struct OwnerFallbackAcceptanceTests {
    @Test func ownerOverridesWhoForFeatureMoveAndEngine() throws {
        let flow = try flow(move: ["who": "assignee", "owner": "reviewer"])
        #expect(flow.moves[0].who.value(for: "feature") == "reviewer")
        let pr = PullRequest(
            repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "author",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: String(repeating: "a", count: 40), headRef: "feature", baseRef: "develop",
            body: "Tier: feature", isDraft: false, labels: [], assignees: ["teammate"],
            comments: [], updatedAt: Date(timeIntervalSince1970: 1_792_411_200)
        )
        #expect(FlowEngine.ownerKind(for: pr, flow: flow) == "reviewer")
    }

    @Test func perTierOwnerOverridesWho() throws {
        let flow = try flow(move: [
            "who": "assignee", "owner": ["feature": "reviewer", "small": "assignee"]
        ])
        #expect(flow.moves[0].who.value(for: "feature") == "reviewer")
        #expect(flow.moves[0].who.value(for: "small") == "assignee")
    }

    @Test func ownerDecodesWithoutWho() throws {
        let flow = try flow(move: ["owner": "reviewer"])
        #expect(flow.moves[0].who.value(for: "feature") == "reviewer")
    }

    @Test func whoRemainsEffectiveWithoutOwner() throws {
        let flow = try flow(move: ["who": "assignee"])
        #expect(flow.moves[0].who.value(for: "feature") == "assignee")
    }

    @Test func missingOwnerAndWhoFailsToDecode() throws {
        let data = try flowData(move: [:])
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(Flow.self, from: data)
        }
    }

    private func flow(move: [String: Any]) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: flowData(move: move))
    }

    private func flowData(move ownership: [String: Any]) throws -> Data {
        var move = ownership
        move["move"] = "review"
        move["when"] = ["no_review_or_response_newer"]
        let object: [String: Any] = [
            "version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["feature", "small"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": true]]],
            "fixed": "## Fixed:", "reviewers": [String](), "moves": [move],
            "dispatch": ["review": ["agent": "synthetic", "prompt": "Review"]]
        ]
        return try JSONSerialization.data(withJSONObject: object)
    }
}
