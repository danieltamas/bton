@testable import BtonCore
import Foundation
import Testing

struct FeaturePlanPullRequestAcceptanceTests {
    @Test func queryRequestsPullRequestFilePaths() {
        let query = FeatureFacts.query(numbers: [120, 259])
        let compact = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(compact.contains("files(first: 100) { nodes { path } }"))
    }

    @Test func decodesKnownEmptyAndMissingFiles() throws {
        let data = Data(#"""
        {"data":{"repository":{
          "n259":{"__typename":"PullRequest","number":259,"state":"MERGED",
            "createdAt":"2026-10-10T10:00:00Z","mergedAt":"2026-10-12T10:00:00Z",
            "baseRefName":"develop","mergeCommit":{"oid":"abc"},
            "files":{"nodes":[{"path":"jobs/loose-docs-filing/PLAN-120.md"},{"path":"gateway/src/services/gdrive-sync.ts"}]}},
          "n260":{"__typename":"PullRequest","number":260,"state":"OPEN",
            "createdAt":"2026-10-10T10:00:00Z","baseRefName":"develop","files":{"nodes":[]}},
          "n261":{"__typename":"PullRequest","number":261,"state":"OPEN",
            "createdAt":"2026-10-10T10:00:00Z","baseRefName":"develop"}
        }}}
        """#.utf8)
        let facts = try FeatureFacts.decode(data)
        #expect(try #require(facts.pullRequests[259]).files == [
            "jobs/loose-docs-filing/PLAN-120.md", "gateway/src/services/gdrive-sync.ts"])
        #expect(try #require(facts.pullRequests[260]).files == [])
        #expect(try #require(facts.pullRequests[261]).files == nil)
        let legacy = FeatureFacts.PullRequestFact(number: 262, state: "OPEN",
            createdAt: FeatureHistoryFixture.date(1), mergedAt: nil, mergeCommit: nil, baseRef: "develop")
        #expect(legacy.files == nil)
    }

    @Test(arguments: ["OPEN", "MERGED", "RELEASED"])
    func onlyCodeAdvancesDelivery(stage: String) throws {
        let registry = try registry(featurePaths: [], areaPaths: ["gateway/src/services/gdrive*.ts"])
        let feature = try #require(registry.feature("filing-dedupe"))
        for files: [String]? in [["jobs/loose-docs-filing/PLAN-120.md"],
                                ["gateway/src/services/gdrive-sync.ts"], nil, []] {
            let (facts, git) = history(stage: stage, files: files)
            let result = FeatureStatuses.standing(of: feature, facts: facts, git: git,
                base: "develop", hasRelease: true, areaPaths: ["gateway/src/services/gdrive*.ts"])
            let code = files == nil || files == [] || files == ["gateway/src/services/gdrive-sync.ts"]
            let expected: FeatureStatus = !code ? .idea : stage == "OPEN" ? .building
                : stage == "MERGED" ? .inDevelop : .live
            #expect(result.status == expected)
            #expect(result.openIssues == 1)
            #expect(result.changes == (stage == "OPEN" ? [] : [259]))
            #expect(result.timeline.first?.status == .idea)
            if !code { #expect(result.timeline.map(\.status) == [.idea]) }
        }
    }

    @Test func nonMarkdownFilesCountRegardlessOfPathsAndPathsCanClaimMarkdown() throws {
        let (facts, git) = history(stage: "RELEASED", files: ["gateway/src/services/gdrive-sync.ts"])
        let scoped = try registry(featurePaths: ["other/**"], areaPaths: ["gateway/src/services/gdrive*.ts"])
        let feature = try #require(scoped.feature("filing-dedupe"))
        #expect(FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop",
            hasRelease: true, areaPaths: ["gateway/src/services/gdrive*.ts"]).status == .live)
        let unscoped = try registry(featurePaths: [], areaPaths: [])
        #expect(FeatureStatuses.standing(of: try #require(unscoped.feature("filing-dedupe")),
            facts: facts, git: git, base: "develop", hasRelease: true).status == .live)
        let matching = try registry(featurePaths: ["gateway/**"], areaPaths: ["other/**"])
        #expect(FeatureStatuses.standing(of: try #require(matching.feature("filing-dedupe")),
            facts: facts, git: git, base: "develop", hasRelease: true, areaPaths: ["other/**"]).status == .live)
    }

    @Test(arguments: ["MERGED", "RELEASED"])
    func unclaimedMarkdownDoesNotAdvanceDelivery(stage: String) throws {
        for areaPaths in [["gateway/src/services/gdrive*.ts"], []] {
            let registry = try registry(featurePaths: [], areaPaths: areaPaths)
            let feature = try #require(registry.feature("filing-dedupe"))
            for files in [["jobs/loose-docs-filing/PLAN-120.md"], ["docs/PROCESS.md", "README.md"],
                          ["docs/PROCESS.MD", "README.Md"]] {
                let (facts, git) = history(stage: stage, files: files)
                let result = FeatureStatuses.standing(of: feature, facts: facts, git: git,
                    base: "develop", hasRelease: true, areaPaths: areaPaths)
                #expect(result.status == .idea)
                #expect(result.changes == [259])
                #expect(result.openIssues == 1)
            }
        }
    }

    @Test func pathsCanClaimMarkdownFiles() throws {
        let (facts, git) = history(stage: "RELEASED", files: ["docs/PROCESS.md"])
        for (featurePaths, areaPaths) in [(["docs/**"], ["other/**"]), ([], ["docs/**"])] {
            let registry = try registry(featurePaths: featurePaths, areaPaths: areaPaths)
            let feature = try #require(registry.feature("filing-dedupe"))
            #expect(FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop",
                hasRelease: true, areaPaths: areaPaths).status == .live)
        }
        let registry = try registry(featurePaths: ["other/**"], areaPaths: ["docs/**"])
        let feature = try #require(registry.feature("filing-dedupe"))
        #expect(FeatureStatuses.standing(of: feature, facts: facts, git: git, base: "develop",
            hasRelease: true, areaPaths: ["docs/**"]).status == .idea)
    }

    @Test func linkedPlanStillSuppliesIdeaWithoutAnIssueOrFirstSeen() throws {
        let feature = try FeatureAcceptanceData.feature(prs: [259], firstSeen: nil)
        let (facts, git) = history(stage: "RELEASED", files: ["jobs/loose-docs-filing/PLAN-120.md"])
        let result = FeatureStatuses.standing(of: feature, facts: facts, git: git,
            base: "develop", hasRelease: true)
        #expect(result.status == .idea)
        #expect(result.timeline.map(\.status) == [.idea])
        #expect(result.changes == [259])
    }

    @Test func reportUsesAreaPathsForFeaturesWithoutPaths() throws {
        let registry = try registry(featurePaths: [], areaPaths: ["gateway/src/services/gdrive*.ts"])
        for files in [["jobs/loose-docs-filing/PLAN-120.md"], ["gateway/src/services/gdrive-sync.ts"]] {
            let (facts, git) = history(stage: "RELEASED", files: files)
            let report = Engine.report(repo: "owner/repo", registry: registry, facts: facts,
                git: git, base: "develop", hasRelease: true)
            #expect(report.standings["filing-dedupe"]?.status == (files[0].hasPrefix("jobs/") ? .idea : .live))
        }
    }

    @Test func promptExplainsIssueOwnershipSlicesPlansAndClosure() {
        let lower = FeatureJob.prompt(repo: "owner/repo", base: "develop", branch: "bton/features",
            tier: nil, loads: true).lowercased()
        for text in ["#n", "title", "branch", "issue", "slice", "parent", "plans or docs", "closed without code"] {
            #expect(lower.contains(text))
        }
    }

    private func registry(featurePaths: [String], areaPaths: [String]) throws -> FeatureRegistry {
        var object = try FeatureAcceptanceData.object()
        var features = try #require(object["features"] as? [[String: Any]])
        var areas = try #require(object["areas"] as? [[String: Any]])
        features[0]["paths"] = featurePaths
        features[0]["issues"] = [["number": 120, "why": "title"]]
        features[0]["prs"] = [["number": 259, "why": "title"]]
        areas[0]["paths"] = areaPaths
        object["features"] = features
        object["areas"] = areas
        return try FeatureAcceptanceData.registry(object)
    }

    private func history(stage: String, files: [String]?) -> (FeatureFacts, FeatureGit) {
        var facts = FeatureFacts()
        facts.issues[120] = .init(number: 120, open: true, createdAt: FeatureHistoryFixture.date(1),
            labels: [], labeledAt: [:])
        facts.pullRequests[259] = .init(number: 259, state: stage == "OPEN" ? "OPEN" : "MERGED",
            createdAt: FeatureHistoryFixture.date(5), mergedAt: stage == "OPEN" ? nil : FeatureHistoryFixture.date(10),
            mergeCommit: "merged", baseRef: "develop", files: files)
        var git = FeatureGit()
        git.onBase = ["merged"]
        if stage == "RELEASED" {
            git.onRelease = ["merged"]
            git.releasedAt["merged"] = FeatureHistoryFixture.date(19)
        }
        return (facts, git)
    }
}
