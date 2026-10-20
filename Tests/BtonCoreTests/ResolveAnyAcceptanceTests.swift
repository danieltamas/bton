@testable import BtonCore
import Foundation
import Testing

struct ResolveAnyAcceptanceTests {
    @Test func dispatchCandidatesDefaultToRunningChecksAndAllowOptingOut() throws {
        let flow = try ResolveAnyFixture.flow()
        let pr = ResolveAnyFixture.pr()
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        var candidate = DispatchCandidate(target: .pullRequest(pr), move: move,
            key: JobKey(repo: ResolveAnyFixture.repo, item: "pr-42", move: move.name,
                        head: ResolveAnyFixture.head),
            agent: "fix-agent", prompt: "Fix #42", command: nil,
            postComment: false, timeout: .seconds(60))
        #expect(!candidate.skipsChecks)
        candidate.skipsChecks = true
        #expect(candidate.skipsChecks)
    }

    @Test(arguments: ["", #","checks":true"#, #","checks":false"#])
    func ordinaryCandidatesSkipChecksExactlyWhenTheirRuleDisablesThem(checks: String) throws {
        let flow = try ResolveAnyFixture.flow(dispatch:
            "\"fix\":{\"agent\":\"fix-agent\",\"prompt\":\"Fix #{number}\"\(checks)}")
        let candidates = DispatchPlanner.candidates([ResolveAnyFixture.pr()],
            flow: flow, me: "owner", repo: ResolveAnyFixture.repo)
        #expect(candidates.count == 1)
        let candidate = try #require(candidates.first)
        #expect(candidate.move.name == "fix")
        #expect(candidate.skipsChecks == (checks == #","checks":false"#))
    }

    @Test(arguments: ["", #","checks":true"#, #","checks":false"#])
    func mergeCandidatesSkipChecksExactlyWhenTheirRuleDisablesThem(checks: String) throws {
        let flow = try ResolveAnyFixture.flow(dispatch:
            "\"merge\":{\"command\":[\"merge\",\"{number}\"]\(checks)}")
        var pr = ResolveAnyFixture.pr()
        pr.mergeable = true
        let candidate = try #require(DispatchPlanner.mergeCandidate(pr,
            flow: flow, me: "owner", repo: ResolveAnyFixture.repo))
        #expect(candidate.skipsChecks == (checks == #","checks":false"#))
    }

    @Test(arguments: ["OWNER", "MEMBER", "COLLABORATOR"])
    func trustedOwnersGetAnIndependentResolveWithTheResolveRulesAgentAndPrompt(association: String) throws {
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveAnyFixture.pr(association: association), flow: ResolveAnyFixture.flow(),
            me: "owner", repo: ResolveAnyFixture.repo))
        #expect(candidate.key == JobKey(repo: ResolveAnyFixture.repo, item: "pr-42",
                                       move: "resolve", head: ResolveAnyFixture.head))
        #expect(candidate.move.name == "resolve")
        #expect(candidate.move.owner == "owner")
        #expect(candidate.agent == "resolve-agent")
        #expect(candidate.prompt == "Resolve #42 onto develop.")
        #expect(candidate.skipsChecks)
        #expect(candidate.command == nil)
        #expect(!candidate.postComment)
    }

    @Test func missingResolveRuleUsesFixAgentForThePullRequestsTierAndBuiltInPrompt() throws {
        let flow = try ResolveAnyFixture.flow(dispatch:
            #""fix":{"agent":{"small":"small-fixer","large":"large-fixer"},"prompt":"Do not use this fix prompt."}"#)
        let pr = ResolveAnyFixture.pr(body: "Tier: large")
        let candidate = try #require(DispatchPlanner.resolveCandidate(pr,
            flow: flow, me: "owner", repo: ResolveAnyFixture.repo))
        #expect(candidate.agent == "large-fixer")
        #expect(candidate.prompt == DispatchPlanner.resolvePrompt(number: 42, base: "develop"))
        #expect(candidate.prompt?.contains("#42") == true)
        #expect(candidate.prompt?.contains("develop") == true)
        #expect(candidate.move.name == "resolve")
        #expect(candidate.move.owner == "owner")
        #expect(candidate.key == JobKey(repo: ResolveAnyFixture.repo, item: "pr-42",
                                       move: "resolve", head: ResolveAnyFixture.head))
        #expect(candidate.skipsChecks)
        #expect(candidate.command == nil)
        #expect(!candidate.postComment)
    }

    @Test func builtInResolvePromptIdentifiesThePullRequestAndBase() {
        let prompt = DispatchPlanner.resolvePrompt(number: 42, base: "develop")
        #expect(prompt.contains("#42"))
        #expect(prompt.contains("develop"))
    }

    @Test func resolveAuthorMatchIgnoresCaseAndUsesCurrentLoginAsOwner() throws {
        let candidate = try #require(DispatchPlanner.resolveCandidate(
            ResolveAnyFixture.pr(author: "OwNeR"), flow: ResolveAnyFixture.flow(),
            me: "OWNER", repo: ResolveAnyFixture.repo))
        #expect(candidate.move.owner == "OWNER")
    }

    @Test func humanDecideMoveDoesNotPreventAnIndependentResolve() throws {
        let flow = try ResolveAnyFixture.flow()
        let pr = ResolveAnyFixture.pr(labels: ["turn:lead"])
        let current = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(current.name == "decide")
        #expect(current.owner == "lead")
        #expect(!current.hasDispatch)
        let candidate = try #require(DispatchPlanner.resolveCandidate(pr,
            flow: flow, me: "owner", repo: ResolveAnyFixture.repo))
        #expect(candidate.move.name == "resolve")
        #expect(candidate.move.owner == "owner")
    }

    @Test func nonConflictingPullRequestCannotBeResolved() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(conflicting: false),
            flow: try ResolveAnyFixture.flow(), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test func anotherAuthorsPullRequestCannotBeResolved() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(author: "other"),
            flow: try ResolveAnyFixture.flow(), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test func draftPullRequestCannotBeResolved() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(draft: true),
            flow: try ResolveAnyFixture.flow(), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test func pullRequestTargetingAnotherBaseCannotBeResolved() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(base: "main"),
            flow: try ResolveAnyFixture.flow(), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test func contributorCannotResolveEvenTheirOwnPullRequest() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(association: "CONTRIBUTOR"),
            flow: try ResolveAnyFixture.flow(), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test func flowWithNeitherResolveNorFixRuleCannotResolve() throws {
        #expect(DispatchPlanner.resolveCandidate(ResolveAnyFixture.pr(),
            flow: try ResolveAnyFixture.flow(dispatch: ""), me: "owner", repo: ResolveAnyFixture.repo) == nil)
    }

    @Test(arguments: ["true", "false", "absent"])
    func configDecodesConflictResolutionPreferenceAndPreservesItThroughRoundTrip(value: String) throws {
        let setting = value == "absent" ? "" : ",\"resolveConflicts\":\(value)"
        let json = """
        {"repos":[{"slug":"synthetic/project"\(setting)}],
         "pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}
        """
        let config = try JSONDecoder().decode(BtonConfig.self, from: Data(json.utf8))
        let repo = try #require(config.repos.first)
        let expected: Bool? = value == "absent" ? nil : value == "true"
        #expect(repo.resolveConflicts == expected)
        #expect(repo.resolvesConflicts == (value != "false"))

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(BtonConfig.self, from: encoded)
        let roundTripped = try #require(decoded.repos.first)
        #expect(roundTripped.resolveConflicts == expected)
        #expect(roundTripped.resolvesConflicts == (value != "false"))
    }
}

private enum ResolveAnyFixture {
    static let repo = "synthetic/project"
    static let head = "d67db2a8" + String(repeating: "a", count: 32)

    static func pr(author: String = "owner", draft: Bool = false, base: String = "develop",
                   association: String = "OWNER", labels: [String] = [], body: String = "",
                   conflicting: Bool = true) -> PullRequest {
        var pr = PullRequest(repo: repo, number: 42, title: "Synthetic PR", author: author,
            authorAssociation: association, url: URL(string: "https://example.invalid/pr/42")!,
            headSha: head, headRef: "feature", baseRef: base, body: body, isDraft: draft,
            labels: labels, assignees: [], comments: [],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        pr.conflicting = conflicting
        return pr
    }

    static func flow(dispatch: String =
        #""resolve":{"agent":"resolve-agent","prompt":"Resolve #{number} onto {base}.","checks":true},"fix":{"agent":"fix-agent","prompt":"Fix #{number}."}"#
    ) throws -> Flow {
        let json = """
        {"version":1,"base":"develop",
         "tier":{"marker":"Tier:","values":["small","large"],"default":"small"},
         "reviews":{"small":[{"heading":"## Review:","notByAuthor":true}],
                    "large":[{"heading":"## Review:","notByAuthor":true}]},"fixed":"## Fixed:",
         "moves":[
           {"move":"decide","when":["label:turn:lead"],"who":"lead"},
           {"move":"fix","when":["no_review_or_response_newer"],"who":"author"}],
         "dispatch":{\(dispatch)}}
        """
        return try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
    }
}
