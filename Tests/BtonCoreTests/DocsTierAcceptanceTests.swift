@testable import BtonCore
import Foundation
import Testing

private enum DocsTierFixture {
    static func rule(values: [String] = ["docs", "quick fix", "feature", "high-risk"],
                     only: [String: [String]] = ["docs": ["*.md", "docs/**/*.md"]],
                     paths: [String: [String]] = [:]) throws -> TierRule {
        try JSONDecoder().decode(TierRule.self, from: JSONSerialization.data(withJSONObject: [
            "marker": "Tier:", "values": values, "default": "feature", "only": only, "paths": paths]))
    }

    static func pr(body: String = "", files: [String], truncated: Bool = false) -> PullRequest {
        var pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: "abcdef0123456789abcdef0123456789abcdef0123", headRef: "feature", baseRef: "main",
            body: body, isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
        pr.changedFiles = files
        pr.changedFilesTruncated = truncated
        pr.mergeable = true
        return pr
    }

    static func data(only: [String: [String]] = ["docs": ["*.md", "docs/**/*.md"]],
                     agent: Any? = ["feature": "claude"],
                     second: [String: Any]? = nil,
                     command: [String] = ["/usr/bin/true", "{head}", "{tier}"]) throws -> Data {
        var dispatch: [String: Any] = ["prompt": ["feature": "p"], "command": command, "post": "comment"]
        if let agent { dispatch["agent"] = agent }
        if let second { dispatch["second"] = second }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["docs", "quick fix", "feature", "high-risk"],
                     "default": "feature", "only": only],
            "reviews": ["docs": [["heading": "## Review:"]], "feature": [["heading": "## Review:"]]],
            "fixed": "## Fixed:",
            "moves": [["move": "review", "when": ["no_review_or_response_newer"], "who": "author"]],
            // A command review gets BTON_OUT only on a move that posts a comment (docs/FLOW.md).
            "dispatch": ["review": dispatch]])
    }

    static func flow(command: [String] = ["/usr/bin/true", "{head}", "{tier}"]) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: data(command: command))
    }
}

@Suite(ProcessBound())
struct DocsTierAcceptanceTests {
    @Test func aOnlyDecodesAndValidatesTiersAndGlobs() throws {
        #expect(try DocsTierFixture.rule().only?["docs"] == ["*.md", "docs/**/*.md"])
        for (only, message) in [
            (["unknown": ["*.md"]], "tier.only.unknown is not one of tier.values"),
            (["docs": ["!README.md"]], "tier.only.docs: !README.md is not a glob (no negation, no empty pattern)"),
            (["docs": [""]], "tier.only.docs:  is not a glob (no negation, no empty pattern)")
        ] {
            guard case let .invalid(actual) = Flow.load(try DocsTierFixture.data(only: only)) else {
                Issue.record("Expected invalid tier.only"); continue
            }
            #expect(actual.contains(message))
        }
    }

    @Test func bOnlyLowersCompleteMatchingFilesUnlessTheAuthorRaises() throws {
        let rule = try DocsTierFixture.rule()
        let cases: [(String, [String], Bool, String, String?)] = [
            ("", ["README.md", "docs/guide/x.md"], false, "docs", "only 2 files, all under tier.only"),
            ("", ["README.md"], false, "docs", "only 1 file, all under tier.only"),
            ("", ["README.md", "src/a.swift"], false, "feature", nil),
            ("", [], false, "feature", nil),
            // A truncated list never lowers; the raise to the highest tier is `tier.paths`' rule (test c's rule has paths).
            ("", ["README.md"], true, "feature", nil),
            ("Tier: feature", ["README.md"], false, "docs", "only 1 file, all under tier.only"),
            ("Tier: docs", ["src/a.swift"], false, "feature", nil),
            ("Tier: quick fix", ["README.md"], false, "quick fix", nil),
            ("Tier: high-risk", ["README.md"], false, "high-risk", nil),
            ("Tier:", ["README.md"], false, "docs", "only 1 file, all under tier.only"),
            ("Tier: docs | feature", ["README.md"], false, "docs", "only 1 file, all under tier.only")
        ]
        for (body, files, truncated, tier, reason) in cases {
            let verdict = FlowEngine.tierVerdict(of: DocsTierFixture.pr(body: body, files: files, truncated: truncated), rule: rule)
            #expect(verdict.tier == tier, "body: \(body), files: \(files)")
            #expect(verdict.reason == reason)
        }
        #expect(FlowEngine.namedTier(of: "Tier: quick fix", rule: rule) == "quick fix")
        #expect(FlowEngine.namedTier(of: "Tier: docs | feature", rule: rule) == nil)
    }

    @Test func cPathsRaiseAfterOnlyLowers() throws {
        let rule = try DocsTierFixture.rule(only: ["docs": ["*.md"]], paths: ["high-risk": ["SECURITY.md"]])
        #expect(FlowEngine.tierVerdict(of: DocsTierFixture.pr(files: ["SECURITY.md"]), rule: rule)
            == TierVerdict(tier: "high-risk", reason: "SECURITY.md"))
    }

    @Test func dLowestRankedCoveringOnlyTierWins() throws {
        let rule = try DocsTierFixture.rule(values: ["docs", "notes", "quick fix", "feature"],
            only: ["notes": ["*.txt"], "docs": ["*.md", "*.txt"]])
        for file in ["a.txt", "a.md"] {
            #expect(FlowEngine.tierVerdict(of: DocsTierFixture.pr(files: [file]), rule: rule)
                == TierVerdict(tier: "docs", reason: "only 1 file, all under tier.only"))
        }
    }

    @Test func eCommandAllowsPerTierAgentsButRejectsOneAgentForEveryTier() throws {
        guard case let .invalid(message) = Flow.load(try DocsTierFixture.data(agent: "claude")) else {
            Issue.record("Expected command beside string agent to be invalid"); return
        }
        #expect(message.contains("dispatch.review: a move runs a command or an agent, not both"))
        guard case .ready = Flow.load(try DocsTierFixture.data()) else {
            Issue.record("Per-tier agent beside command must validate"); return
        }
    }

    @Test func fCandidatesCarryExactlyTheTierSpecificExecutor() throws {
        let flow = try DocsTierFixture.flow()
        for (files, tier) in [(["README.md"], "docs"), (["src/a.swift"], "feature")] {
            let pr = DocsTierFixture.pr(files: files)
            let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "owner", repo: pr.repo)
            #expect(candidates.count == 1)
            let candidate = try #require(candidates.first)
            #expect(candidate.move.tier == tier)
            #expect(candidate.agent == (tier == "docs" ? nil : "claude"))
            #expect(candidate.command == (tier == "docs" ? ["/usr/bin/true", pr.headSha, "docs"] : nil))
        }
    }

    @Test func gDispatcherPostsDocsPolicyAndRunsAnAgentForFeature() async throws {
        // Separate stores and leases ensure the two jobs do not suppress each other by key.
        for docs in [true, false] {
            let f = try await DocsTierCommandFixture.make()
            defer { try? FileManager.default.removeItem(at: f.root) }
            var pr = f.pr
            pr.changedFiles = docs ? ["README.md", "docs/guide/x.md"] : ["src/a.swift"]
            let script = "printf '%s\\n%s' '## Review: approve (head {head})' 'Policy check, not a judgment.' > \"$BTON_OUT\""
            let flow = try DocsTierFixture.flow(command: ["/bin/sh", "-c", script])
            let job = try await f.finished(f.start(pr: pr, flow: flow))
            #expect(job.status == .succeeded, "\(job.detail ?? "") \(f.log(job.id))")
            if docs {
                #expect(f.posted == "## Review: approve (head \(pr.headSha))\nPolicy check, not a judgment.")
                #expect(f.ghCalls.contains("pr comment 7 --repo synthetic/project"))
                #expect(!FileManager.default.fileExists(atPath: f.marker.path))
            } else {
                #expect(try String(contentsOf: f.marker, encoding: .utf8) == "ran")
            }
        }
    }

    @Test func hTeamExampleIncludesDocsPolicyReview() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard case let .ready(flow) = Flow.load(try Data(contentsOf: root.appendingPathComponent("examples/team.flow.json"))) else {
            Issue.record("Team example must validate"); return
        }
        #expect(flow.tier.values.first == "docs")
        #expect(flow.tier.only?["docs"]?.contains("*.md") == true)
        #expect(flow.reviews["docs"]?.isEmpty == false)
        // 0.16.0 (spec-docs-review item 5): the policy review ships as `bton docs-review`, not a team script.
        #expect(flow.dispatch["review"]?.command?.prefix(2) == ["bton", "docs-review"])
        #expect(flow.dispatch["review"]?.agent?.value(for: "docs") == nil)
    }

    @Test func iCommandCandidateCarriesNoSecondReviewer() throws {
        let data = try DocsTierFixture.data(second: ["agent": "second", "prompt": "Second review {number} at {head}"])
        guard case let .ready(flow) = Flow.load(data) else {
            Issue.record("Command beside per-tier agents and a second reviewer must validate"); return
        }
        let docs = DocsTierFixture.pr(files: ["README.md"])
        let candidates = DispatchPlanner.candidates([docs], flow: flow, me: "owner", repo: docs.repo)
        #expect(candidates.count == 1)
        let command = try #require(candidates.first)
        #expect(command.agent == nil)
        #expect(command.command == ["/usr/bin/true", docs.headSha, "docs"])
        #expect(command.second == nil)
        #expect(command.secondPrompt == nil)
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 1, agents: [:]).map(\.key) == [command.key])

        let feature = DocsTierFixture.pr(files: ["src/a.swift"])
        let agent = try #require(DispatchPlanner.candidates([feature], flow: flow, me: "owner", repo: feature.repo).first)
        #expect(agent.agent == "claude")
        #expect(agent.command == nil)
        #expect(agent.second == "second")
        #expect(agent.secondPrompt == "Second review 7 at \(feature.headSha)")
        let template = AgentTemplate(argv: ["/usr/bin/true"])
        #expect(DispatchPlanner.select([agent], jobs: [], maxAgents: 1, agents: ["claude": template]).isEmpty)
        #expect(DispatchPlanner.select([agent], jobs: [], maxAgents: 1,
            agents: ["claude": template, "second": template]).map(\.key) == [agent.key])
    }

    @Test func jCommandBesidePromptWithoutAgentIsValid() throws {
        guard case let .ready(flow) = Flow.load(try DocsTierFixture.data(agent: nil)) else {
            Issue.record("Command beside a prompt without an agent must validate"); return
        }
        let pr = DocsTierFixture.pr(files: ["src/a.swift"])
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "owner", repo: pr.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.move.tier == "feature")
        #expect(candidate.agent == nil)
        #expect(candidate.command == ["/usr/bin/true", pr.headSha, "feature"])
        #expect(DispatchPlanner.select(candidates, jobs: [], maxAgents: 1, agents: [:]).map(\.key) == [candidate.key])
    }

}

private struct DocsTierCommandFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let pr: PullRequest
    var root: URL { base.leases.root }
    var marker: URL { root.appendingPathComponent("marker") }
    var posted: String { (try? String(contentsOf: root.appendingPathComponent("posted"), encoding: .utf8)) ?? "" }
    var ghCalls: String { (try? String(contentsOf: root.appendingPathComponent("gh-seen"), encoding: .utf8)) ?? "" }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let runner = ProcessRunner()
            let pushed = try await runner.run("/usr/bin/git",
                ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(120))
            try #require(pushed.status == 0, "PR ref setup: \(pushed.stderr)")
            let head = try await runner.run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(120))
            try #require(head.status == 0)
            let sha = String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            var pr = PullRequest(repo: base.leases.repo, number: 7, title: "Synthetic PR", author: "owner",
                authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
                headSha: sha, headRef: "feature", baseRef: "main", body: "", isDraft: false,
                labels: [], assignees: [], comments: [], updatedAt: .now)
            pr.mergeable = true
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = #"""
            cd "$(dirname "$0")"
            printf '%s\n' "$*" >> gh-seen
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' "$HEAD_SHA"
              exit 0
            fi
            if [ "${1-}" = pr ] && [ "${2-}" = comment ]; then
              while [ $# -gt 0 ]; do [ "$1" = --body-file ] && cp "$2" posted; shift; done
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """#
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\nHEAD_SHA=\(sha)\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            let github = GitHubClient(ghPath: gh.path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), pr: pr)
        } catch { try? FileManager.default.removeItem(at: base.leases.root); throw error }
    }

    func start(pr: PullRequest, flow: Flow) async throws -> UUID {
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "owner", repo: pr.repo)
        let candidate = try #require(candidates.first)
        let agent = AgentTemplate(argv: ["/bin/sh", "-c",
            "printf ran > \"$MARKER\"; printf '%s\\n%s' '## Review: approve (head \(pr.headSha))' 'Agent review.'", "{prompt}"])
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
            agents: ["claude": agent], environment: ["MARKER": marker.path])
        guard case .started = outcome else { throw DispatchError.worktree("Fixture job did not start: \(outcome)") }
        return try #require(store.all().first?.id)
    }

    func log(_ id: UUID) -> String { (try? String(contentsOf: store.logURL(id), encoding: .utf8)) ?? "" }

    func finished(_ id: UUID) async throws -> Job {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline, !store.all().contains(where: { $0.id == id && $0.status != .running }) {
            try await Task.sleep(for: .milliseconds(25))
        }
        return try #require(store.all().first { $0.id == id && $0.status != .running }, "Job must finish")
    }
}
