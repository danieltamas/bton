@testable import BtonCore
import Foundation
import Testing

struct DocsReviewAcceptanceTests {
    private let allowed = ["*.md", "docs/**/*.md"]
    private let policy = "Policy check by bton docs-review, not a judgment: every changed file is documentation, non-empty UTF-8, with no secret-shaped strings, no invisible characters and no broken relative links."

    @Test func cleanDocumentationAndResolvedRelativeLinkApprove() {
        let files = [
            DocsReview.File(path: "README.md", bytes: Data("# Project\n".utf8)),
            DocsReview.File(path: "docs/a.md", bytes: Data("[Home](../README.md)\n".utf8))
        ]
        let verdict = DocsReview.review(files, tree: ["README.md", "docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func individualDefectsHaveExactlyOneFinding() throws {
        let cases: [(String, Data, String)] = [
            ("src/x.swift", Data("let x = 1\n".utf8),
             "src/x.swift: not a documentation file under tier.only"),
            ("docs/empty.md", Data(), "docs/empty.md: empty file"),
            ("docs/whitespace.md", Data(" \t\r\n".utf8), "docs/whitespace.md: empty file"),
            ("docs/invalid.md", Data([0xFF, 0xFE]), "docs/invalid.md: not UTF-8 text"),
            ("docs/invisible.md", Data("Heading\nzero\u{200B}width\n".utf8),
             "docs/invisible.md: line 2: invisible character U+200B"),
            ("docs/link.md", Data("Heading\n[Missing](missing.md)\n".utf8),
             "docs/link.md: line 2: link to missing.md points at no file in the PR's tree")
        ]
        for (path, bytes, finding) in cases {
            let verdict = DocsReview.review([DocsReview.File(path: path, bytes: bytes)],
                                            tree: [path], allowed: allowed)
            #expect(verdict == DocsReview.Verdict(approve: false, findings: [finding]))
        }

        let token = "ghp_" + String(repeating: "A", count: 36)
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/secret.md", bytes: Data("Heading\n\(token)\n".utf8))
        ], tree: ["docs/secret.md"], allowed: allowed)
        #expect(!verdict.approve)
        let finding = try #require(verdict.findings.count == 1 ? verdict.findings.first : nil)
        // The spec requires a kind, but does not prescribe its spelling.
        #expect(finding.range(of: #"^docs/secret\.md: line 2: looks like a secret \([^()\r\n]+\)$"#,
                              options: .regularExpression) != nil)
        #expect(!finding.contains(token))
        #expect(!DocsReview.report(verdict, head: "abc1234").contains(token))
    }

    @Test func multipleDefectsKeepPolicyOrderAndInputFileOrder() throws {
        let token = "ghp_" + String(repeating: "B", count: 36)
        let verdict = DocsReview.review([
            DocsReview.File(path: "src/x.swift", bytes: Data("\(token)\u{200B} [x](missing.md)\n".utf8)),
            DocsReview.File(path: "src/empty.swift", bytes: Data()),
            DocsReview.File(path: "docs/invalid.md", bytes: Data([0xFF]))
        ], tree: [], allowed: allowed)
        #expect(!verdict.approve)
        try #require(verdict.findings.count == 7)
        #expect(verdict.findings[0] == "src/x.swift: not a documentation file under tier.only")
        #expect(verdict.findings[1].range(
            of: #"^src/x\.swift: line 1: looks like a secret \([^()\r\n]+\)$"#,
            options: .regularExpression) != nil)
        #expect(!verdict.findings[1].contains(token))
        #expect(Array(verdict.findings.dropFirst(2)) == [
            "src/x.swift: line 1: invisible character U+200B",
            "src/x.swift: line 1: link to missing.md points at no file in the PR's tree",
            "src/empty.swift: not a documentation file under tier.only",
            "src/empty.swift: empty file",
            "docs/invalid.md: not UTF-8 text"
        ])
    }

    @Test func directoryAndExternalAndAnchorLinksApprove() {
        let text = """
        [Directory](../assets)
        [Web](https://example.invalid/missing.md)
        [Mail](mailto:synthetic@example.invalid)
        [Section](#anchor)
        """
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data(text.utf8))
        ], tree: ["docs/a.md", "assets/image.png"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func doubleBacktickSpanContainingLinkIsIgnored() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("``example ` [x](missing.md) end``\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func singleBacktickSpanContainingLongerRunAndLinkIsIgnored() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("`example `` [x](missing.md) end`\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func codeSpanAcrossTwoLinesContainingLinkIsIgnored() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("`example\n[x](missing.md)`\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func tripleBacktickSpanOnOwnLineDoesNotHideFollowingBrokenLink() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("```example```\n[x](missing.md)\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: false, findings: [
            "docs/a.md: line 2: link to missing.md points at no file in the PR's tree"
        ]))
    }

    @Test func fourBacktickFenceContainingTripleBacktickLineAndLinkIsIgnored() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("````markdown\n```\n[x](missing.md)\n````\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func balancedParenthesesInDestinationResolveCompleteFilename() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("[x](guide(v2).md)\n".utf8))
        ], tree: ["docs/a.md", "docs/guide(v2).md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func nestedParenthesesInDestinationResolveCompleteFilename() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("[x](guide(v2(draft)).md)\n".utf8))
        ], tree: ["docs/a.md", "docs/guide(v2(draft)).md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func escapedParenthesesInDestinationResolveUnescapedFilename() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("[x](guide\\(v2\\).md)\n".utf8))
        ], tree: ["docs/a.md", "docs/guide(v2).md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func parentDirectoryLinkFromDocsResolvesRepositoryRoot() {
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("[Home](../)\n".utf8))
        ], tree: ["README.md", "docs/a.md"], allowed: allowed)
        #expect(verdict == DocsReview.Verdict(approve: true, findings: []))
    }

    @Test func githubTokenShapedLinkTargetIsRedactedInFindingAndReport() throws {
        let token = "ghp_" + String(repeating: "C", count: 36)
        let verdict = DocsReview.review([
            DocsReview.File(path: "docs/a.md", bytes: Data("[x](\(token))\n".utf8))
        ], tree: ["docs/a.md"], allowed: allowed)
        #expect(!verdict.approve)
        try #require(verdict.findings.count == 2)
        #expect(verdict.findings[0].contains("line 1: looks like a secret ("))
        #expect(verdict.findings[1].hasPrefix("docs/a.md: line 1: link to "))
        #expect(verdict.findings[1].hasSuffix(" points at no file in the PR's tree"))
        #expect(verdict.findings[1].contains("redacted"))
        #expect(verdict.findings.allSatisfy { !$0.contains(token) })
        #expect(!DocsReview.report(verdict, head: "abc1234").contains(token))
    }

    @Test func reportsMatchContractAndDispatcherAcceptsBothVerdicts() {
        let findings = ["docs/a.md: empty file", "docs/b.md: not UTF-8 text"]
        let changes = DocsReview.report(DocsReview.Verdict(approve: false, findings: findings), head: "abc1234")
        let approve = DocsReview.report(DocsReview.Verdict(approve: true, findings: []), head: "abc1234")
        #expect(changes.components(separatedBy: "\n").first == "## Review: changes (head abc1234)")
        #expect(changes.trimmingCharacters(in: .newlines) ==
                "## Review: changes (head abc1234)\n\(policy)\n\n- \(findings[0])\n- \(findings[1])")
        #expect(approve.components(separatedBy: "\n").first == "## Review: approve (head abc1234)")
        #expect(Array(approve.components(separatedBy: "\n").dropFirst()).first == policy)
        #expect(approve.trimmingCharacters(in: .newlines) == "## Review: approve (head abc1234)\n\(policy)")
        for report in [changes, approve] {
            #expect(DispatchPlanner.reviewComment(fromFinalMessage: report,
                headings: ["## Review:"], head: "abc1234") == report.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    @Test func executableResolutionPrefersBundleOnlyForBton() {
        #expect(Executables.resolve("bton", bundled: { "/tmp/x/BtonCLI" }) == "/tmp/x/BtonCLI")
        var gitBundleCalled = false
        let git = Executables.resolve("git", bundled: {
            gitBundleCalled = true
            return "/tmp/x/BtonCLI"
        })
        let expectedGit = Executables.searchPath.split(separator: ":").map { "\($0)/git" }
            .first(where: FileManager.default.isExecutableFile)
        #expect(expectedGit != nil)
        #expect(git == expectedGit)
        #expect(!gitBundleCalled)
        var otherBundleCalled = false
        #expect(Executables.resolve("not-bton", bundled: {
            otherBundleCalled = true
            return "/tmp/x/BtonCLI"
        }) == nil)
        #expect(!otherBundleCalled)
    }
}

@Suite(ProcessBound())
struct DocsReviewRunAcceptanceTests {
    @Test func changedFilenameContainingQuoteAndSpaceIsReviewedVerbatim() async throws {
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-docs-review-quoted-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let runner = ProcessRunner()
        try await git(["init", "--initial-branch=main"], in: repo, runner: runner)
        try await git(["config", "user.name", "Synthetic Tester"], in: repo, runner: runner)
        try await git(["config", "user.email", "synthetic@example.invalid"], in: repo, runner: runner)
        try Data("# Project\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try await commit("Initial documentation", in: repo, runner: runner)
        let base = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "-b", "docs"], in: repo, runner: runner)
        let path = "guide \"quoted\".md"
        try Data("[Home](README.md)\n[Missing](missing.md)\n".utf8)
            .write(to: repo.appendingPathComponent(path))
        try await commit("Add quoted documentation filename", in: repo, runner: runner)
        let head = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "main"], in: repo, runner: runner)
        let out = repo.appendingPathComponent("review.txt")
        #expect(await DocsReviewRun.run(number: 7, head: head, base: "main", tier: "docs",
            in: repo, out: out, runner: runner) == 0)
        let report = try String(contentsOf: out, encoding: .utf8)
        #expect(report.hasPrefix("## Review: changes (head \(head))\n"))
        #expect(report.components(separatedBy: "\n").filter { $0.hasPrefix("- ") } == [
            "- \(path): line 2: link to missing.md points at no file in the PR's tree"
        ])
        #expect(try await git(["rev-parse", "HEAD"], in: repo, runner: runner) == base)
    }

    @Test func fixtureRepoReviewsHeadAndRejectsUnavailableOrInvalidHeads() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-docs-review-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let runner = ProcessRunner()
        try await git(["init", "--initial-branch=main"], in: repo, runner: runner)
        try await git(["config", "user.name", "Synthetic Tester"], in: repo, runner: runner)
        try await git(["config", "user.email", "synthetic@example.invalid"], in: repo, runner: runner)
        try Data("# Project\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try await commit("Initial documentation", in: repo, runner: runner)
        try Data("# Project\nWelcome.\n".utf8).write(to: repo.appendingPathComponent("README.md"))
        try await commit("Update main documentation", in: repo, runner: runner)
        let main = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "-b", "docs"], in: repo, runner: runner)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let guide = repo.appendingPathComponent("docs/guide.md")
        try Data("[Missing](missing.md)\n".utf8).write(to: guide)
        try await commit("Add guide with broken link", in: repo, runner: runner)
        let broken = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "main"], in: repo, runner: runner)
        let brokenOut = root.appendingPathComponent("broken.txt")
        #expect(await DocsReviewRun.run(number: 7, head: broken, base: "main", tier: "docs",
            in: repo, out: brokenOut, runner: runner) == 0)
        let brokenReport = try String(contentsOf: brokenOut, encoding: .utf8)
        #expect(brokenReport.hasPrefix("## Review: changes (head \(broken))\n"))
        #expect(brokenReport.contains("\n- docs/guide.md: line 1: link to missing.md points at no file in the PR's tree"))

        try await git(["checkout", "docs"], in: repo, runner: runner)
        try Data("[Home](../README.md)\n".utf8).write(to: guide)
        try await commit("Fix guide link", in: repo, runner: runner)
        let fixed = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "main"], in: repo, runner: runner)
        let fixedOut = root.appendingPathComponent("fixed.txt")
        #expect(await DocsReviewRun.run(number: 7, head: fixed, base: "main", tier: "docs",
            in: repo, out: fixedOut, runner: runner) == 0)
        let fixedReport = try String(contentsOf: fixedOut, encoding: .utf8)
        #expect(fixedReport.hasPrefix("## Review: approve (head \(fixed))\n"))
        #expect(!fixedReport.contains("\n- "))

        let failures: [(String, Int32)] = [("zzz", 3), (String(repeating: "a", count: 40), 2)]
        for (head, status) in failures {
            let out = root.appendingPathComponent("failure-\(status).txt")
            #expect(await DocsReviewRun.run(number: 7, head: head, base: "main", tier: "docs",
                in: repo, out: out, runner: runner) == status)
            #expect(!FileManager.default.fileExists(atPath: out.path))
        }

        try await git(["checkout", "docs"], in: repo, runner: runner)
        try Data("# Notes\n".utf8).write(to: repo.appendingPathComponent("notes.md"))
        try await commit("Add root notes", in: repo, runner: runner)
        let notes = try await git(["rev-parse", "HEAD"], in: repo, runner: runner)
        try await git(["checkout", "main"], in: repo, runner: runner)
        let flowURL = repo.appendingPathComponent(".bton/flow.json")
        try FileManager.default.createDirectory(at: flowURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flow = Data(###"{"version":1,"base":"main","tier":{"marker":"Tier:","values":["docs","feature"],"default":"feature","only":{"docs":["docs/**/*.md"]}},"reviews":{"docs":[{"heading":"## Review:"}]},"fixed":"## Fixed:","moves":[],"dispatch":{}}"###.utf8)
        #expect(Flow.load(flow).flow != nil)
        try flow.write(to: flowURL)
        let restrictedOut = root.appendingPathComponent("restricted.txt")
        #expect(await DocsReviewRun.run(number: 7, head: notes, base: "main", tier: "docs",
            in: repo, out: restrictedOut, runner: runner) == 0)
        let restrictedReport = try String(contentsOf: restrictedOut, encoding: .utf8)
        #expect(restrictedReport.hasPrefix("## Review: changes (head \(notes))\n"))
        #expect(restrictedReport.contains("\n- notes.md: not a documentation file under tier.only"))
        try FileManager.default.removeItem(at: flowURL)
        let defaultOut = root.appendingPathComponent("default.txt")
        #expect(await DocsReviewRun.run(number: 7, head: notes, base: "main", tier: "docs",
            in: repo, out: defaultOut, runner: runner) == 0)
        let defaultReport = try String(contentsOf: defaultOut, encoding: .utf8)
        #expect(defaultReport.hasPrefix("## Review: approve (head \(notes))\n"))
        #expect(!defaultReport.contains("\n- "))
        #expect(try await git(["rev-parse", "HEAD"], in: repo, runner: runner) == main)
        #expect(try await git(["branch", "--show-current"], in: repo, runner: runner) == "main")
    }

    private func commit(_ message: String, in repo: URL, runner: ProcessRunner) async throws {
        try await git(["add", "."], in: repo, runner: runner)
        try await git(["-c", "commit.gpgsign=false", "commit", "-m", message], in: repo, runner: runner)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL, runner: ProcessRunner) async throws -> String {
        let result = try await runner.run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(15))
        guard result.status == 0 else {
            Issue.record("git \(arguments) exited \(result.status): \(result.stderr)")
            throw DispatchError.worktree(result.stderr)
        }
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
