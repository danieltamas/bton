@testable import BtonCore
import Foundation
import Testing

/// The hats: a role's pick and playbook are Bton's and the owner's, the move's procedure stays
/// Bton's, and a repo's own pick for the role wins over the hat's.
struct HatsAcceptanceTests {
    private static let agents: [String: AgentTemplate] = [
        "claude": AgentTemplate(argv: ["claude", "-p", "{prompt}", "--session-id", "{session}"]),
        "codex": AgentTemplate(argv: ["codex", "exec", "{prompt}"]),
    ]

    private static func candidate(move: String, post: Bool = true, agent: String? = "claude", denied: [String] = []) -> DispatchCandidate {
        let pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: "d67db2a8d67db2a8", headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: .now)
        var made = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "feature", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: pr.headSha), agent: agent,
            prompt: "Do \(move).", command: nil, postComment: post, timeout: .seconds(60))
        made.denied = denied
        return made
    }

    private static func repo(work: String? = nil, reviewer: String? = nil, rules: String? = nil) -> WatchedRepo {
        var repo = WatchedRepo(slug: "synthetic/project", path: "/tmp/synthetic")
        repo.work = work
        repo.reviewer = reviewer
        repo.reviewRules = rules
        return repo
    }

    @Test func everyDispatchedMoveHasItsHatAndTheRestHaveNone() {
        #expect(Hats.hat(for: "review") == .reviewer)
        #expect(Hats.hat(for: "fix") == .coder)
        #expect(Hats.hat(for: "resolve") == .coder)
        #expect(Hats.hat(for: IssueIntake.move) == .coder)
        #expect(Hats.hat(for: FeatureJob.move) == .coder)
        #expect(Hats.hat(for: "decide") == .decider)
        #expect(Hats.hat(for: "triage") == .triager)
        for unowned in [DispatchPlanner.scheduleMove, Supervision.move, IssueDrafts.move, NewIssues.move, Release.move, "merge"] {
            #expect(Hats.hat(for: unowned) == nil, "\(unowned)")
        }
    }

    @Test(arguments: ["review", "fix", "resolve", "decide", "schedule", "custom-move"])
    func withoutSettingsTheTextIsBtonsPlaybookUnchanged(move: String) throws {
        #expect(try Hats.text(for: move, settings: [:]) == PRPlaybook.text(for: move))
        #expect(Hats.describe(move: move, settings: [:]).hasSuffix("playbook v\(PRPlaybook.version)"))
    }

    @Test func anOwnPlaybookReplacesTheCoreAndKeepsTheMovesProcedure() throws {
        let settings = ["reviewer": HatSettings(playbook: "Review like a careful colleague.\n")]
        let text = try Hats.text(for: "review", settings: settings)
        #expect(text.hasPrefix("Review like a careful colleague.\n\nMove: review\n"))
        #expect(!text.contains("Bton operating defaults"))
        #expect(text.contains("| ID | Severity | Location | Finding and evidence |"))
        #expect(Hats.describe(move: "review", settings: settings) == "reviewer hat, own playbook")
        // The coder's playbook is the coder's: a review is untouched by it.
        #expect(try Hats.text(for: "review", settings: ["coder": HatSettings(playbook: "Build.")]) == PRPlaybook.text(for: "review"))
        #expect(try Hats.text(for: "fix", settings: ["coder": HatSettings(playbook: "Build.")]).hasPrefix("Build.\n\nMove: fix\n"))
    }

    @Test func aPlaybookLineNamingAFileReadsItAndAMissingFileFailsLoudly() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hat-\(UUID().uuidString).md")
        try "From the file.\n".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Hats.file(in: file.path) == file)
        #expect(Hats.file(in: "Two words") == nil)
        #expect(Hats.file(in: "/one\n/two") == nil)
        #expect(Hats.file(in: "/one\r/two") == nil)
        #expect(Hats.file(in: "~/one") == URL(fileURLWithPath: NSHomeDirectory() + "/one"))
        #expect(try Hats.text(for: "fix", settings: ["coder": HatSettings(playbook: file.path)]).hasPrefix("From the file.\n\nMove: fix\n"))
        let missing = file.path + ".missing"
        #expect(throws: Hats.PlaybookError.self) {
            try Hats.text(for: "fix", settings: ["coder": HatSettings(playbook: missing)])
        }
        do {
            _ = try Hats.text(for: "fix", settings: ["coder": HatSettings(playbook: missing)])
        } catch {
            #expect(error.localizedDescription.contains(missing))
        }
    }

    @Test func theRepoPickWinsOverTheHatOverTheFlow() {
        let hats = ["reviewer": HatSettings(pick: "codex:gpt-5 high"), "coder": HatSettings(pick: "claude:sonnet low")]
        let byHat = Engine.hatted(Self.candidate(move: "review"), repo: Self.repo(), hats: hats, agents: Self.agents)
        #expect(byHat.agent == "codex")
        #expect(byHat.model == "gpt-5")
        #expect(byHat.effort == "high")
        let byRepo = Engine.hatted(Self.candidate(move: "review"), repo: Self.repo(reviewer: "claude:opus max"), hats: hats, agents: Self.agents)
        #expect(byRepo.agent == "claude")
        #expect(byRepo.model == "opus")
        #expect(byRepo.effort == "max")
        let fix = Engine.hatted(Self.candidate(move: "fix"), repo: Self.repo(reviewer: "claude:opus max"), hats: hats, agents: Self.agents)
        #expect(fix.agent == "claude")
        #expect(fix.model == "sonnet")
        #expect(fix.effort == "low")
        let flow = Engine.hatted(Self.candidate(move: "fix"), repo: Self.repo(), hats: [:], agents: Self.agents)
        #expect(flow.agent == "claude")
        #expect(flow.model == nil)
    }

    @Test func theReviewRulesFollowEveryReviewHereBothReviewersAndNothingElse() {
        let repo = Self.repo(rules: "Be brief.")
        var paired = Self.candidate(move: "review")
        paired.second = "codex"
        paired.secondPrompt = "Second review."
        let review = Engine.hatted(paired, repo: repo, hats: [:], agents: Self.agents)
        #expect(review.prompt == "Do review.\n\nReview rules from the reviewer:\nBe brief.")
        #expect(review.secondPrompt == "Second review.\n\nReview rules from the reviewer:\nBe brief.")
        #expect(review.agent == "claude")
        let decide = Engine.hatted(Self.candidate(move: "decide"), repo: repo, hats: [:], agents: Self.agents)
        #expect(decide.prompt == "Do decide.")
    }

    @Test func withoutHatsTheRepoIssueWorkPickRunsIssueWorkOnlyAsBefore() {
        let repo = Self.repo(work: "codex:gpt-5 high")
        for move in ["fix", "resolve", "review", "decide"] {
            let made = Engine.hatted(Self.candidate(move: move), repo: repo, hats: [:], agents: Self.agents)
            #expect(made.agent == "claude", Comment(rawValue: move))
            #expect(made.model == nil, Comment(rawValue: move))
            #expect(made.effort == nil, Comment(rawValue: move))
            #expect(made.prompt == "Do \(move).", Comment(rawValue: move))
        }
        for move in [IssueIntake.move, FeatureJob.move] {
            let made = Engine.hatted(Self.candidate(move: move), repo: repo, hats: [:], agents: Self.agents)
            #expect(made.agent == "codex", Comment(rawValue: move))
            #expect(made.model == "gpt-5", Comment(rawValue: move))
            #expect(made.effort == "high", Comment(rawValue: move))
        }
        var config = BtonConfig.initial
        config.agents["codex"] = Self.agents["codex"]
        #expect(Engine.coderPick(repo, config: config) == AgentPick(agent: "codex", model: "gpt-5", effort: "high"))
        config.hats = ["coder": HatSettings(pick: "claude:sonnet low")]
        #expect(Engine.coderPick(Self.repo(), config: config) == AgentPick(agent: "claude", model: "sonnet", effort: "low"))
        #expect(Engine.coderPick(Self.repo(work: "gemini"), config: config) == AgentPick(agent: "claude", model: "sonnet", effort: "low"))
    }

    @Test func aReviewTheAgentPostsItselfACommandAndAnUnknownAgentAreLeftAlone() {
        let hats = ["reviewer": HatSettings(pick: "codex:gpt-5 high"), "decider": HatSettings(pick: "gemini")]
        #expect(Engine.hatted(Self.candidate(move: "review", post: false), repo: Self.repo(), hats: hats, agents: Self.agents).agent == "claude")
        #expect(Engine.hatted(Self.candidate(move: "review", agent: nil), repo: Self.repo(), hats: hats, agents: Self.agents).agent == nil)
        #expect(Engine.hatted(Self.candidate(move: "decide"), repo: Self.repo(), hats: hats, agents: Self.agents).agent == "claude")
        #expect(Engine.hatted(Self.candidate(move: "review"), repo: Self.repo(reviewer: "gemini"), hats: hats, agents: Self.agents).agent == "codex")
    }

    @Test func aJobWithToolsDeniedTakesOnlyClaudeAndTheDeciderRefusesAnotherAgent() {
        let hats = ["decider": HatSettings(pick: "codex:gpt-5 high")]
        let denied = Engine.hatted(Self.candidate(move: "decide", denied: ["Bash(gh issue close:*)"]), repo: Self.repo(), hats: hats, agents: Self.agents)
        #expect(denied.agent == "claude")
        #expect(denied.model == nil)
        let open = Engine.hatted(Self.candidate(move: "decide"), repo: Self.repo(), hats: hats, agents: Self.agents)
        #expect(open.agent == "codex")
        #expect(Hats.problem(pick: AgentPick(agent: "codex"), for: .decider, agents: Self.agents)?.contains("claude") == true)
        #expect(Hats.problem(pick: AgentPick(agent: "claude"), for: .decider, agents: Self.agents) == nil)
        #expect(Hats.problem(pick: AgentPick(agent: "codex"), for: .reviewer, agents: Self.agents) == nil)
        // The triager posts under the owner's login with tools denied too: a pick Settings would save and then ignore is refused.
        #expect(Hats.problem(pick: AgentPick(agent: "codex"), for: .triager, agents: Self.agents)?.contains("triager") == true)
        #expect(Hats.problem(pick: AgentPick(agent: "claude"), for: .triager, agents: Self.agents) == nil)
        #expect(Hats.problem(pick: AgentPick(agent: "gemini"), for: .coder, agents: Self.agents) != nil)
    }

    @Test func aConfigWithoutHatsReadsAndOneWithThemRoundTrips() throws {
        let old = try JSONDecoder().decode(BtonConfig.self, from: Data(#"{"repos":[],"pollSeconds":60,"maxAgents":2,"agents":{},"schedules":[]}"#.utf8))
        #expect(old.hats == nil)
        #expect(old.hatSettings.isEmpty)
        var config = BtonConfig.initial
        config.hats = ["coder": HatSettings(pick: "claude:sonnet medium", playbook: "Build it.")]
        let back = try JSONDecoder().decode(BtonConfig.self, from: JSONEncoder().encode(config))
        #expect(back.hats == config.hats)
        #expect(HatSettings().isEmpty)
        #expect(!HatSettings(pick: "claude").isEmpty)
    }
}
