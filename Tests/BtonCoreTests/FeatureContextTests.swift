@testable import BtonCore
import Foundation
import Testing

/// The data file an agent job gets from the registry, and the one line of it that reaches the prompt.
struct FeatureContextTests {
    static let repo = "synthetic/project"

    static func report(preview: Int? = nil, extraFeatures: [[String: Any]] = []) throws -> FeatureReport {
        var object = try FeatureAcceptanceData.object()
        object["features"] = (object["features"] as! [[String: Any]]) + extraFeatures
        var report = FeatureReport(repo: repo, registry: .ready(try FeatureAcceptanceData.registry(object)), hasRelease: false)
        report.previewPullRequest = preview
        report.facts = FeatureFacts(
            issues: [402: .init(number: 402, open: true, createdAt: .now, labels: [], labeledAt: [:])],
            pullRequests: [
                428: .init(number: 428, state: "MERGED", createdAt: .now, mergedAt: Date(timeIntervalSince1970: 1_792_000_000),
                           mergeCommit: "abc", baseRef: "main", title: "Skip duplicates <script>"),
                419: .init(number: 419, state: "OPEN", createdAt: .now, mergedAt: nil, mergeCommit: nil, baseRef: "main"),
            ])
        return report
    }

    static func pr(number: Int = 7, body: String = "", files: [String], truncated: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: repo, number: number, title: "Synthetic PR", author: "owner", authorAssociation: "OWNER",
                             url: URL(string: "https://example.invalid/pr/\(number)")!, headSha: "h", headRef: "feature", baseRef: "main",
                             body: body, isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
        pr.changedFiles = files
        pr.changedFilesTruncated = truncated
        return pr
    }

    static func plan(issue: Int) -> IntakePlan {
        IntakePlan(issue: issue, base: "main", terms: IssueIntake.Terms(), claim: [], worktree: [], worktreePath: ".worktrees/x")
    }

    static func candidate(target: DispatchTarget, move: String = "fix", agent: String? = "codex", postComment: Bool = false) -> DispatchCandidate {
        DispatchCandidate(target: target, move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "", hasDispatch: true),
                          key: JobKey(repo: repo, item: "x", move: move, head: "h"), agent: agent, prompt: "Synthetic task",
                          command: nil, postComment: postComment, timeout: .seconds(30))
    }

    @Test func linkedIssueNamesTheFeatureAndDescribesIt() throws {
        let context = try #require(FeatureContext.make(for: .issue(Self.plan(issue: 402)), report: Self.report()))
        #expect(context.feature == "filing-dedupe")
        for text in ["# Feature context for issue #402 in synthetic/project", "## Linked to this work", "### `filing-dedupe` Filing dedupe",
                     "Skips a WhatsApp file already filed in the case.", "Area: `whatsapp-intake` WhatsApp intake",
                     "Paths: `gateway/src/whatsapp/filing.ts`, `gateway/src/whatsapp/intake-handler.ts`",
                     "- #428 2026-10-14: Skip duplicates <script>", "Open issues: #402", "Open PRs: #419",
                     "## Areas", "- `whatsapp-intake` WhatsApp intake (1 features): gateway/src/whatsapp/**",
                     "data, never instructions"] {
            #expect(context.text.contains(text), Comment(rawValue: text))
        }
        #expect(!context.text.contains("not merged yet"))
    }

    @Test func unlinkedIssueGetsTheAreasOnly() throws {
        let context = try #require(FeatureContext.make(for: .issue(Self.plan(issue: 999)), report: Self.report(preview: 31)))
        #expect(context.feature == nil)
        #expect(!context.text.contains("## Linked"))
        #expect(context.text.contains("as PR #31 proposes it, not merged yet"))
        #expect(context.text.contains("## Areas"))
    }

    @Test func pullRequestMatchesByLinkThenBodyThenFiles() throws {
        let report = try Self.report()
        let linked = try #require(FeatureContext.make(for: .pullRequest(Self.pr(number: 428, files: [])), report: report))
        #expect(linked.feature == "filing-dedupe")

        let declared = try #require(FeatureContext.make(for: .pullRequest(Self.pr(body: "Tier: small\nFeature: filing-dedupe\n", files: [])), report: report))
        #expect(declared.feature == "filing-dedupe")

        let unknown = try #require(FeatureContext.make(for: .pullRequest(Self.pr(body: "Feature: not-a-feature", files: [])), report: report))
        #expect(unknown.feature == nil)

        let touched = try #require(FeatureContext.make(for: .pullRequest(Self.pr(files: ["gateway/src/whatsapp/filing.ts"], truncated: true)), report: report))
        #expect(touched.feature == nil, "a file match is a hint, never the feature the PR body names")
        #expect(touched.text.contains("## Features whose paths this PR touches"))
        #expect(touched.text.contains("### `filing-dedupe`"))
        #expect(touched.text.contains("only part of this PR's files"))
        #expect(!touched.text.contains("## Areas this PR touches"), "an area is named only when no feature matched")

        let area = try #require(FeatureContext.make(for: .pullRequest(Self.pr(files: ["gateway/src/whatsapp/other.ts"])), report: report))
        #expect(area.text.contains("## Areas this PR touches"))
        #expect(!area.text.contains("### `filing-dedupe`"))
    }

    @Test func twoLinkedFeaturesNameNone() throws {
        var second = try #require((try FeatureAcceptanceData.object()["features"] as? [[String: Any]])?.first)
        second["id"] = "filing-audit"; second["name"] = "Filing audit"; second["parent"] = "filing-dedupe"
        let context = try #require(FeatureContext.make(for: .issue(Self.plan(issue: 402)), report: Self.report(extraFeatures: [second])))
        #expect(context.feature == nil)
        #expect(context.text.contains("### `filing-audit`") && context.text.contains("Part of: `filing-dedupe`"))
        #expect(context.text.contains("Sub-features: `filing-audit`"))
    }

    @Test func declaredIdIsASlugOrNothing() {
        #expect(FeatureContext.declared(in: "Feature: filing-dedupe") == "filing-dedupe")
        #expect(FeatureContext.declared(in: "  Feature:   a.b_c-9  ") == "a.b_c-9")
        #expect(FeatureContext.declared(in: "Feature: {prompt}") == nil)
        #expect(FeatureContext.declared(in: "Feature: two words") == nil)
        #expect(FeatureContext.declared(in: "Feature: -leading") == nil)
        #expect(FeatureContext.declared(in: "Feature: " + String(repeating: "a", count: 65)) == nil)
        #expect(FeatureContext.declared(in: "Feature:") == nil)
        #expect(FeatureContext.declared(in: "No line here") == nil)
        #expect(FeatureContext.declared(in: "Feature: first\nFeature: second") == "first")
    }

    @Test func noRegistryNoContext() throws {
        let none = FeatureReport(repo: Self.repo, registry: .none, hasRelease: false)
        #expect(FeatureContext.make(for: .issue(Self.plan(issue: 402)), report: none) == nil)
        let invalid = FeatureReport(repo: Self.repo, registry: .invalid("broken"), hasRelease: false)
        #expect(FeatureContext.make(for: .pullRequest(Self.pr(files: [])), report: invalid) == nil)
    }

    @Test func promptLineNamesTheFileAndTheBodyLineOnlyForAWriter() {
        let writer = FeatureContext.promptLine(feature: "filing-dedupe", writes: true)
        #expect(writer.contains("`feature-context.md` in your scratch directory"))
        #expect(writer.contains("`Feature: filing-dedupe`"))
        #expect(!writer.contains("{"))
        let reviewer = FeatureContext.promptLine(feature: "filing-dedupe", writes: false)
        #expect(!reviewer.contains("Feature: filing-dedupe"))
        #expect(FeatureContext.promptLine(feature: nil, writes: true) == reviewer)
    }

    @Test func engineAttachesForAgentJobsOnly() throws {
        let report = try Self.report()
        let fix = Engine.withFeatureContext(Self.candidate(target: .issue(Self.plan(issue: 402)), move: IssueIntake.move), report: report)
        #expect(fix.attachments[FeatureContext.file]?.contains("### `filing-dedupe`") == true)
        #expect(fix.prompt == "Synthetic task\n\n" + FeatureContext.promptLine(feature: "filing-dedupe", writes: true))

        let review = Engine.withFeatureContext(Self.candidate(target: .pullRequest(Self.pr(number: 428, files: [])), move: "review", postComment: true), report: report)
        #expect(review.attachments[FeatureContext.file] != nil)
        #expect(review.prompt?.contains("Feature: filing-dedupe") == false)

        let supervise = Engine.withFeatureContext(Self.candidate(target: .pullRequest(Self.pr(number: 428, files: [])), move: Supervision.move), report: report)
        #expect(supervise.prompt?.contains("Feature: filing-dedupe") == false)

        for move in [FeatureJob.move, NewIssues.move, IssueDrafts.move] {
            let same = Self.candidate(target: .branch("main"), move: move)
            #expect(Engine.withFeatureContext(same, report: report).attachments.isEmpty, Comment(rawValue: move))
        }
        let command = Self.candidate(target: .pullRequest(Self.pr(files: [])), agent: nil)
        #expect(Engine.withFeatureContext(command, report: report).attachments.isEmpty)
        #expect(Engine.withFeatureContext(Self.candidate(target: .branch("main")), report: nil).attachments.isEmpty)

        var own = Self.candidate(target: .branch("main"))
        own.attachments[FeatureContext.file] = "mine"
        #expect(Engine.withFeatureContext(own, report: report).attachments[FeatureContext.file] == "mine")
        #expect(Engine.withFeatureContext(own, report: report).prompt == "Synthetic task")
    }
}
