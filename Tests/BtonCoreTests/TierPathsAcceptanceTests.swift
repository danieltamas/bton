import Foundation
import Testing
@testable import BtonCore

@Suite struct TierPathsAcceptanceTests {
    private let rule = try! JSONDecoder().decode(TierRule.self, from: Data("""
    {"marker":"Tier:","values":["quick fix","feature","high-risk"],"default":"feature",
     "paths":{"high-risk":["migrations/**","scripts/wt","*.sql",".github/"],"feature":["gateway/src/tools/**"]}}
    """.utf8))

    private func pr(body: String = "", files: [String], truncated: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: "o/r", number: 1, title: "t", author: "a", authorAssociation: "MEMBER",
                             url: URL(string: "https://github.com/o/r/pull/1")!, headSha: "abc", headRef: "h", baseRef: "main",
                             body: body, isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
        pr.changedFiles = files
        pr.changedFilesTruncated = truncated
        return pr
    }

    @Test(arguments: [
        ("migrations/**", "migrations/031_x.sql", true),
        ("migrations/**", "db/migrations/031_x.sql", false),
        ("scripts/wt", "scripts/wt", true),
        ("scripts/wt", "scripts/wtx", false),
        ("*.sql", "db/deep/a.sql", true),
        ("*.sql", "a.sqlx", false),
        (".github/", ".github/workflows/ci.yml", true),
        ("gateway/src/services/billing*", "gateway/src/services/billing-webhook.ts", true),
        ("gateway/src/services/billing*", "gateway/src/services/billing/a.ts", true),
        ("gateway/**/x.ts", "gateway/x.ts", true),
        ("gateway/**/x.ts", "gateway/a/b/x.ts", true),
        ("src/?.ts", "src/a.ts", true),
        ("src/?.ts", "src/ab.ts", false),
        ("/README.md", "README.md", true),
        ("/README.md", "docs/README.md", false),
    ])
    func globsFollowGitignoreSyntax(pattern: String, path: String, expected: Bool) {
        #expect(PathGlob.matches(pattern, path) == expected)
    }

    @Test func negationAndEmptyPatternsAreNotGlobs() {
        #expect(!PathGlob.isValid("!keep"))
        #expect(!PathGlob.isValid("migrations/[0-9]*.sql"))
        #expect(!PathGlob.isValid(""))
        #expect(PathGlob.isValid("migrations/**"))
    }

    @Test func aMatchingFileRaisesTheTierAboveWhatTheBodySays() {
        let verdict = FlowEngine.tierVerdict(of: pr(body: "Tier: quick fix", files: ["README.md", "migrations/031_x.sql"]), rule: rule)
        #expect(verdict == TierVerdict(tier: "high-risk", reason: "migrations/031_x.sql"))
    }

    @Test func theBodyStandsWhenNoFileMatchesOrItIsHigher() {
        #expect(FlowEngine.tierVerdict(of: pr(body: "Tier: quick fix", files: ["README.md"]), rule: rule)
            == TierVerdict(tier: "quick fix", reason: nil))
        #expect(FlowEngine.tierVerdict(of: pr(body: "Tier: high-risk", files: ["gateway/src/tools/a.ts"]), rule: rule)
            == TierVerdict(tier: "high-risk", reason: nil))
    }

    @Test func withoutPathsTheBodyWinsAndBothMissingIsTheDefault() throws {
        let plain = try JSONDecoder().decode(TierRule.self, from: Data(
            #"{"marker":"Tier:","values":["quick fix","feature"],"default":"feature"}"#.utf8))
        #expect(FlowEngine.tierVerdict(of: pr(body: "Tier: quick fix", files: ["migrations/a.sql"]), rule: plain).tier == "quick fix")
        #expect(FlowEngine.tierVerdict(of: pr(files: []), rule: plain).tier == "feature")
        #expect(FlowEngine.tierVerdict(of: pr(files: []), rule: rule).tier == "feature")
    }

    @Test func tooManyFilesCountAsTheHighestTier() {
        let verdict = FlowEngine.tierVerdict(of: pr(body: "Tier: quick fix", files: ["a", "b"], truncated: true), rule: rule)
        #expect(verdict.tier == "high-risk")
        #expect(verdict.reason == "more than 2 changed files")
    }

    @Test func aPathsKeyOutsideValuesInvalidatesTheFlow() {
        let data = Data("""
        {"version":1,"base":"main","tier":{"marker":"Tier:","values":["a","b"],"default":"a","paths":{"c":["x/**"]}},
         "reviews":{"a":[{"heading":"## Review:"}]},"fixed":"## Fixed:","moves":[],"dispatch":{}}
        """.utf8)
        guard case let .invalid(message) = Flow.load(data) else { Issue.record("expected invalid"); return }
        #expect(message.contains("tier.paths.c"))
    }

    @Test func filesAreReadFromTheOpenPullRequestsQuery() throws {
        let json = """
        {"data":{"viewer":{"login":"me"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"nodes":[
        {"number":5,"title":"t","url":"https://github.com/o/r/pull/5","isDraft":false,"headRefOid":"abc","headRefName":"h",
         "baseRefName":"main","body":"","updatedAt":"2026-10-01T00:00:00Z","authorAssociation":"MEMBER","mergeable":"MERGEABLE",
         "author":{"login":"a"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]},
         "files":{"totalCount":150,"nodes":[{"path":"a.ts"},{"path":"b.ts"}]}}]}}}}
        """
        let pr = try #require(GitHubClient.decodeOpenPullRequests(Data(json.utf8), repo: "o/r").pullRequests.first)
        #expect(pr.changedFiles == ["a.ts", "b.ts"])
        #expect(pr.changedFilesTruncated)
    }

    @Test func tierFillsIntoACommand() {
        #expect(DispatchPlanner.fill("{number} {tier}", repo: "o/r", number: 4, head: "h", base: "main", issue: nil, tier: "feature")
            == "4 feature")
    }
}
