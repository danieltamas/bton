@testable import BtonCore
import Foundation
import Testing

struct FeatureFactsAcceptanceTests {
    @Test func queryNamesEveryNumberOnce() {
        let query = FeatureFacts.query(numbers: [402, 428])
        for number in [402, 428] {
            let alias = "n\(number): issueOrPullRequest(number: \(number))"
            #expect(query.components(separatedBy: alias).count == 2)
        }
        #expect(query.contains("__typename"))
        #expect(query.contains("... on Issue"))
        #expect(query.contains("... on PullRequest"))
        #expect(query.contains("labels(first: 30)"))
        #expect(query.contains("timelineItems(itemTypes: [LABELED_EVENT], last: 30)"))
        #expect(query.contains("... on LabeledEvent"))
        #expect(query.contains("mergeCommit { oid }"))
        #expect(query.contains("baseRefName"))
    }

    @Test func decodesIssuesAndPullRequestsAndSkipsUnknown() throws {
        let data = Data(#"""
        {"data":{"repository":{
          "n402":{"__typename":"Issue","number":402,"state":"OPEN","createdAt":"2026-10-01T10:00:00Z",
            "labels":{"nodes":[{"name":"stage:ready"}]},
            "timelineItems":{"nodes":[
              {"createdAt":"2026-10-09T09:00:00Z","label":{"name":"stage:ready"}},
              {"createdAt":"2026-10-05T09:00:00Z","label":{"name":"stage:spec"}},
              {"createdAt":"2026-10-06T09:00:00Z","label":{"name":"stage:ready"}}]}},
          "n428":{"__typename":"PullRequest","number":428,"state":"MERGED","createdAt":"2026-10-10T10:00:00Z",
            "mergedAt":"2026-10-12T10:00:00Z","baseRefName":"develop","mergeCommit":{"oid":"abc"}},
          "n999":null
        }}}
        """#.utf8)
        let facts = try FeatureFacts.decode(data)
        let issue = try #require(facts.issues[402])
        #expect(issue.number == 402)
        #expect(issue.open)
        #expect(issue.createdAt == FeatureAcceptanceData.date("2026-10-01T10:00:00Z"))
        #expect(issue.labels == ["stage:ready"])
        #expect(issue.labeledAt["stage:ready"] == FeatureAcceptanceData.date("2026-10-09T09:00:00Z"))
        #expect(issue.labeledAt["stage:spec"] == FeatureAcceptanceData.date("2026-10-05T09:00:00Z"))
        let pr = try #require(facts.pullRequests[428])
        #expect(pr.number == 428)
        #expect(pr.state == "MERGED")
        #expect(pr.createdAt == FeatureAcceptanceData.date("2026-10-10T10:00:00Z"))
        #expect(pr.mergedAt == FeatureAcceptanceData.date("2026-10-12T10:00:00Z"))
        #expect(pr.mergeCommit == "abc")
        #expect(pr.baseRef == "develop")
        #expect(facts.issues.count == 1)
        #expect(facts.pullRequests.count == 1)
    }

    @Test func chunksAt50() { #expect(FeatureFacts.chunk == 50) }

    @Test func mergeKeepsBoth() {
        var first = FeatureFacts()
        var second = FeatureFacts()
        let at = FeatureAcceptanceData.date("2026-10-01T10:00:00Z")
        first.issues[402] = .init(number: 402, open: false, createdAt: at, labels: [], labeledAt: [:])
        second.issues[403] = .init(number: 403, open: true, createdAt: at, labels: ["stage:spec"], labeledAt: [:])
        first.pullRequests[419] = .init(number: 419, state: "CLOSED", createdAt: at, mergedAt: nil, mergeCommit: nil, baseRef: "main")
        second.pullRequests[428] = .init(number: 428, state: "OPEN", createdAt: at, mergedAt: nil, mergeCommit: nil, baseRef: "develop")
        let original = first
        first.merge(second)
        #expect(Set(first.issues.keys) == [402, 403])
        #expect(Set(first.pullRequests.keys) == [419, 428])
        #expect(first.issues[402] == original.issues[402])
        #expect(first.issues[403] == second.issues[403])
        #expect(first.pullRequests[419] == original.pullRequests[419])
        #expect(first.pullRequests[428] == second.pullRequests[428])
    }
}
