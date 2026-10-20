@testable import BtonCore
import Foundation
import Testing

private enum PullRequestHelpersFixture {
    static func data(_ helpers: [String]?, other: [String]? = nil) throws -> Data {
        var dispatch: [String: Any] = [
            "review": ["agent": "claude", "prompt": "Synthetic review.", "timeoutMinutes": 5],
            "fix": ["agent": "claude", "prompt": "Synthetic fix."]
        ]
        if let helpers {
            var rule = dispatch["review"] as! [String: Any]
            rule["helpers"] = helpers
            dispatch["review"] = rule
        }
        if let other {
            var rule = dispatch["fix"] as! [String: Any]
            rule["helpers"] = other
            dispatch["fix"] = rule
        }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["feature"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:"]]], "fixed": "## Fixed:",
            "moves": [["move": "review", "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": dispatch
        ])
    }

    static func pr() -> PullRequest {
        PullRequest(repo: "synthetic/widget", number: 12, title: "Synthetic PR", author: "author-dev",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pull/12")!,
            headSha: String(repeating: "a", count: 40), headRef: "synthetic", baseRef: "main",
            body: "Tier: feature", isDraft: false, labels: [], assignees: ["author-dev"],
            comments: [], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
}

struct PullRequestHelpersAcceptanceTests {
    @Test func dispatchRuleDecodesOptionalHelpersInOrder() throws {
        for names: [String]? in [nil, [], ["codex"], ["second-agent", "codex", "helper-3"]] {
            let flow = try JSONDecoder().decode(Flow.self, from: PullRequestHelpersFixture.data(names))
            #expect(try #require(flow.dispatch["review"]).helpers == names)
            #expect(try #require(flow.dispatch["fix"]).helpers == nil)
        }
    }

    @Test func flowLoadAcceptsAbsentEmptyAndOneToThreeValidHelpers() throws {
        for names: [String]? in [nil, [], ["codex"], ["codex", "helper-2"], ["third", "codex", "helper-2"]] {
            let status = Flow.load(try PullRequestHelpersFixture.data(names))
            guard case let .ready(flow) = status else {
                Issue.record("Valid dispatch helpers must load as ready: \(String(describing: names))")
                continue
            }
            #expect(try #require(flow.dispatch["review"]).helpers == names)
        }
    }

    @Test func flowLoadRejectsTooManyOrInvalidHelpersInAnyDispatchEntry() throws {
        let invalid = [["one", "two", "three", "four"], [""], ["Codex"], ["codex;rm"],
                       ["codex", "bad name"], ["codex", "helper_2"], ["codex", "helper/2"]]
        for names in invalid {
            for data in [try PullRequestHelpersFixture.data(names),
                         try PullRequestHelpersFixture.data(["codex"], other: names)] {
                guard case .invalid = Flow.load(data) else {
                    Issue.record("Invalid helpers in any dispatch entry must reject the flow: \(names)")
                    continue
                }
            }
        }
    }

    @Test func pullRequestCandidatesCarryOnlyTheirMovesHelpersInOrder() throws {
        for names: [String]? in [nil, [], ["codex"], ["third", "codex", "helper-2"]] {
            let flow = try JSONDecoder().decode(Flow.self,
                from: PullRequestHelpersFixture.data(names, other: ["unrelated-helper"]))
            let candidates = DispatchPlanner.candidates([PullRequestHelpersFixture.pr()], flow: flow,
                me: "author-dev", repo: "synthetic/widget")
            #expect(candidates.count == 1)
            let candidate = try #require(candidates.first)
            #expect(candidate.move.name == "review")
            #expect(candidate.helpers == (names ?? []))
        }
    }

    @Test func scheduleCandidatesKeepTheirOwnHelpers() throws {
        for names: [String]? in [nil, [], ["helper-2", "codex"]] {
            let entry = ScheduleEntry(name: "Synthetic check", everyMinutes: 10, enabled: true,
                repo: "synthetic/widget", agent: "claude", prompt: "Synthetic inspection", number: 7,
                model: nil, helpers: names)
            let candidates = DispatchPlanner.scheduled([entry], jobs: [], repo: "synthetic/widget",
                defaultBranch: "main", me: "author-dev")
            #expect(candidates.count == 1)
            #expect(try #require(candidates.first).helpers == (names ?? []))
        }
    }

    @Test func helperInstructionsNameToolAndHelpersAndForbidBashInvocation() {
        #expect(Helpers.tool == "mcp__bton__ask")
        #expect(Helpers.instructions([]) == "")
        for names in [["codex"], ["codex", "helper-2"]] {
            let text = Helpers.instructions(names)
            for name in names { #expect(text.contains(name)) }
            #expect(text.contains("mcp__bton__ask"))
            #expect(text.contains("Bash"))
        }
    }

    @Test func refusedHelperUsesJobWordingAndNeverResolvesExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-pr-helpers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let jobs = try JobStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path]))
        for allowed in [[], ["codex"]] {
            let result = await Helpers.ask(agent: "other-helper", question: "Synthetic review question",
                allowed: allowed, agents: ["other-helper": AgentTemplate(argv: ["/synthetic/helper", "{prompt}"])],
                cwd: root, job: UUID(), jobs: jobs, timeout: .seconds(1), resolve: { _ in
                    Issue.record("A refused helper must not resolve or execute a program")
                    return nil
                })
            #expect(result.isError)
            #expect(result.text.contains("not one of this job's helpers"))
        }
    }
}
