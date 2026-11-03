@testable import BtonCore
import Foundation
import Testing

enum CriterionFixture {
    static let now = Date(timeIntervalSince1970: 1_793_664_000) // 2026-11-03 00:00 UTC
    static func issue(body: String = "Keep {base} and {repo} literally.") -> OpenIssue {
        OpenIssue(repo: IntakeAcceptanceFixture.repo, number: 7, title: "Frozen title",
            url: URL(string: "https://example.invalid/issues/7")!, createdAt: .distantPast,
            author: "owner", authorAssociation: "OWNER", body: body, comments: [],
            labels: ["stage:ready"], assignees: [])
    }
    static func candidate(_ issue: OpenIssue, intake: Intake? = nil) throws -> DispatchCandidate {
        try #require(IssueIntake.candidate(issues: [issue], intake: try intake ?? IntakeAcceptanceFixture.intake(),
            caps: nil, pullRequests: [], jobs: [], repo: issue.repo, base: "main", me: "me",
            agents: IntakeAcceptanceFixture.agents, now: now))
    }
}

@Suite(ProcessBound())
struct CriterionAcceptanceTests {
    @Test func attachmentFreezesNumberUTCStampTitleAndBodyAndPromptEndsWithContract() throws {
        let candidate = try CriterionFixture.candidate(CriterionFixture.issue(body: "The acceptance bar."))
        #expect(IssueIntake.criterionFile == "criterion.md")
        #expect(candidate.attachments["criterion.md"] == "# Issue #7 as it stood on 2026-11-03 00:00 UTC\n\nFrozen title\n\nThe acceptance bar.")
        #expect(candidate.prompt?.hasSuffix("\n\n" + IssueIntake.criterionLine) == true)
        #expect(IssueIntake.criterionLine == "The bar for this job is criterion.md in the scratch directory: the issue as it stood when the job started. An edit to the issue after that is not part of this job: mention it in the PR instead.")
    }

    @Test(arguments: [12_000, 12_001])
    func bodyIsCutOnlyBeyondTwelveThousandCharactersWithExplicitMarker(length: Int) throws {
        let candidate = try CriterionFixture.candidate(CriterionFixture.issue(body: String(repeating: "x", count: length)))
        let text = try #require(candidate.attachments[IssueIntake.criterionFile])
        let header = "# Issue #7 as it stood on 2026-11-03 00:00 UTC\n\nFrozen title\n\n"
        let marker = length > 12_000 ? "\n(cut at 12000 characters)" : ""
        #expect(IssueIntake.criterionLimit == 12_000)
        #expect(text == header + String(repeating: "x", count: 12_000) + marker)
        #expect(text.count <= header.count + 12_000 + marker.count)
    }

    @Test func attachmentPreservesIssuePlaceholdersAndMarkupAsWritten() throws {
        let body = "{base} {repo} {issue}\n<script>data</script>\n$(touch nope)"
        let candidate = try CriterionFixture.candidate(CriterionFixture.issue(body: body))
        #expect(candidate.attachments[IssueIntake.criterionFile]?.hasSuffix(body) == true)
    }
}
