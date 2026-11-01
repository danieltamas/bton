import Foundation

/// Which agent runs a move, by hat: the repo's own pick for the role over the hat's pick over the
/// flow's agent.
extension Engine {
    /// An agent move run under its hat. The repo's Issue work pick stands over the coder hat for the
    /// issue work it names (intake, the registry), never for a PR's fix or resolve, which it never
    /// ran; the repo's Reviewer stands over the reviewer hat, and its review rules follow every
    /// review here, both reviewers' prompts. A move no hat owns, a command move and a review the
    /// agent posts itself keep the flow's agent. A job with tools denied (a decision under the
    /// owner's login) takes no agent but Claude, the only one that enforces them.
    static func hatted(_ candidate: DispatchCandidate, repo: WatchedRepo, hats: [String: HatSettings],
                       agents: [String: AgentTemplate]) -> DispatchCandidate {
        guard candidate.agent != nil, let hat = Hats.hat(for: candidate.key.move) else { return candidate }
        if hat == .reviewer, !candidate.postComment { return candidate }
        var made = candidate
        let own: String? = switch hat {
        case .coder: [IssueIntake.move, FeatureJob.move].contains(candidate.key.move) ? repo.work : nil
        case .reviewer: repo.reviewer
        case .triager, .decider: nil
        }
        let pick = own.flatMap(AgentPick.init).flatMap { agents[$0.agent] != nil ? $0 : nil } ?? Hats.pick(for: hat, settings: hats, agents: agents)
        if let pick, candidate.denied.isEmpty || agents[pick.agent]?.argv.first.map(AgentHardening.isClaude) == true {
            made.agent = pick.agent
            made.model = pick.model
            made.effort = pick.effort
        }
        if hat == .reviewer, let rules = repo.reviewRules?.trimmingCharacters(in: .whitespacesAndNewlines), !rules.isEmpty {
            let suffix = "\n\nReview rules from the reviewer:\n" + rules
            made.prompt = made.prompt.map { $0 + suffix }
            made.secondPrompt = made.secondPrompt.map { $0 + suffix }
        }
        return made
    }

    /// How the repo's issue work runs here: its own Issue work pick, else the coder hat's.
    static func coderPick(_ repo: WatchedRepo, config: BtonConfig) -> AgentPick? {
        repo.work.flatMap(AgentPick.init).flatMap { config.agents[$0.agent] != nil ? $0 : nil }
            ?? Hats.pick(for: .coder, settings: config.hatSettings, agents: config.agents)
    }
}
