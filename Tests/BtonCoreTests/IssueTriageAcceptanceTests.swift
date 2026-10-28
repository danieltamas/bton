import Foundation
import Testing
@testable import BtonCore

@Suite struct IssueTriageAcceptanceTests {
    private func issue(_ number: Int, labels: [String], age: TimeInterval = 0) -> OpenIssue {
        OpenIssue(repo: "o/r", number: number, title: "t\(number)", url: URL(string: "https://github.com/o/r/issues/\(number)")!,
                  createdAt: Date(timeIntervalSince1970: 1_000_000 - age), author: "a", authorAssociation: "MEMBER", body: "b",
                  comments: [], labels: labels)
    }

    @Test func issuesPastReadyAreNotPending() {
        let pending = IssueTriage.pending([
            issue(1, labels: ["stage:ready"]), issue(2, labels: ["stage:in-progress"]), issue(3, labels: ["stage:review"]),
            issue(4, labels: ["stage:spec"]), issue(5, labels: []),
        ])
        #expect(Set(pending.map(\.number)) == [4, 5])
    }

    @Test func withoutPriorityComesFirstThenOldest() {
        let pending = IssueTriage.pending([
            issue(1, labels: ["priority:low"], age: 10), issue(2, labels: ["priority:low"], age: 500), issue(3, labels: [], age: 1),
        ])
        #expect(pending.map(\.number) == [3, 2, 1])
    }

    @Test func verdictNeedsEveryAnswer() {
        #expect(IssueTriage.verdict([0, 0, nil]) == nil)
        #expect(IssueTriage.verdict([0, 0]) == nil)
        #expect(IssueTriage.verdict([0, 9, 1]) == nil)
    }

    @Test func theScoreAddsImpactUrgencyAndAQuickWinBonus() {
        #expect(IssueTriage.verdict([0, 0, 0]) == TriageVerdict(score: 9, priority: "high", stage: "ready"))
        #expect(IssueTriage.verdict([1, 1, 1]) == TriageVerdict(score: 5, priority: "medium", stage: "ready"))
        #expect(IssueTriage.verdict([3, 2, 2]) == TriageVerdict(score: 0, priority: "low", stage: "spec"))
    }

    @Test func priorityBandsSplitAtThreeAndSix() {
        #expect(IssueTriage.priority(forScore: 6) == "high")
        #expect(IssueTriage.priority(forScore: 5) == "medium")
        #expect(IssueTriage.priority(forScore: 3) == "medium")
        #expect(IssueTriage.priority(forScore: 2) == "low")
    }

    @Test func onlyAClearPlanIsReady() {
        #expect(IssueTriage.verdict([0, 0, 1])?.stage == "ready")
        #expect(IssueTriage.verdict([0, 0, 2])?.stage == "spec")
        #expect(IssueTriage.verdict([0, 0, 3])?.stage == "spec")
        #expect(IssueTriage.verdict([0, 0, 4])?.stage == "triage")
    }

    @Test func theEditSwapsOnlyTheLabelsThatChange() throws {
        let triage = try #require(IssueTriage.pending([issue(1, labels: ["bug", "priority:low", "stage:triage"])]).first)
        let edit = IssueTriage.edit(for: TriageVerdict(score: 1, priority: "low", stage: "ready"), on: triage)
        #expect(edit.add == ["stage:ready"])
        #expect(edit.remove == ["stage:triage"])
    }

    @Test func labelsAreReadFromGitHubsAnswer() throws {
        let json = """
        {"data":{"repository":{"issues":{"nodes":[{"number":7,"title":"x","url":"https://github.com/o/r/issues/7",
        "createdAt":"2026-10-01T00:00:00Z","body":"","authorAssociation":"MEMBER","author":{"login":"a"},
        "labels":{"nodes":[{"name":"priority:high"}]},"comments":{"nodes":[]}}]}}}}
        """
        let issues = try GitHubClient.decodeOpenIssues(Data(json.utf8), repo: "o/r").issues
        #expect(issues.first?.labels == ["priority:high"])
    }
}
