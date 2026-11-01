import Foundation

/// The roles Bton's agents play, whatever the repo: a coder builds and fixes, a reviewer reads and
/// judges, a triager sorts issues, a decider rules in the owner's place. A hat says how its role runs
/// on this Mac (agent, model, effort) and the operating defaults it works by; a flow's prompt adds the
/// repo's own rules on top. Bton's, not a repo's: the owner shapes their hats their way, a teammate
/// theirs, and the flow stays the team's shared part.
public enum Hat: String, CaseIterable, Codable, Sendable {
    case coder, reviewer, triager, decider

    /// The moves this hat runs, as the flow and Bton name them.
    public var moves: [String] {
        switch self {
        case .coder: ["fix", "resolve", IssueIntake.move, FeatureJob.move]
        case .reviewer: ["review"]
        case .triager: Hats.triagerMoves
        case .decider: ["decide"]
        }
    }

    /// What the role does, for the settings card.
    public var detail: String {
        switch self {
        case .coder: "Fixes what a review found, resolves conflicts, builds ready issues and keeps the feature registry."
        case .reviewer: "Reads a PR and posts the review Bton parses; the repo's review rules are added after its playbook."
        case .triager: "Scores and stages issues once the flow has issue moves, under the owner's login with tools denied, so Claude Code only; until then nothing runs under it."
        case .decider: "Rules on a review's open findings and on what the team asks the owner, under the owner's login with tools denied, so Claude Code only."
        }
    }
}

/// One hat as the owner set it: `pick` as `AgentPick` text, nil for the flow's agent; `playbook` as
/// the operating defaults that replace Bton's core, or one line naming a file to read them from at
/// each start (an agent-os skill, say), nil for Bton's own.
public struct HatSettings: Codable, Hashable, Sendable {
    public var pick: String?
    public var playbook: String?

    public init(pick: String? = nil, playbook: String? = nil) {
        self.pick = pick
        self.playbook = playbook
    }

    public var isEmpty: Bool { pick == nil && playbook == nil }
}

public enum Hats {
    /// Issue moves of the next flow version; named here so the triager hat has its moves before they dispatch.
    public static let triagerMoves = IssueMoves.moves

    /// The hat a move runs under; nil for a move no hat owns (a schedule, the supervisor, a draft, a
    /// release), which keeps Bton's own text.
    public static func hat(for move: String) -> Hat? {
        Hat.allCases.first { $0.moves.contains(move) }
    }

    /// This Mac's pick for a hat, when it names one and an agent here.
    public static func pick(for hat: Hat, settings: [String: HatSettings], agents: [String: AgentTemplate]) -> AgentPick? {
        guard let pick = settings[hat.rawValue]?.pick.flatMap(AgentPick.init), agents[pick.agent] != nil else { return nil }
        return pick
    }

    /// A playbook line that names a file rather than holding the text.
    public static func file(in playbook: String) -> URL? {
        let line = playbook.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.contains(where: \.isNewline), line.hasPrefix("/") || line.hasPrefix("~/") else { return nil }
        return URL(fileURLWithPath: (line as NSString).expandingTildeInPath)
    }

    public enum PlaybookError: Error, LocalizedError {
        case unreadable(hat: Hat, path: String)
        public var errorDescription: String? {
            if case let .unreadable(hat, path) = self { "the \(hat.rawValue) hat's playbook file cannot be read: \(path)" } else { nil }
        }
    }

    /// The operating defaults the hat works by: the owner's text, the file it names, or Bton's core.
    /// A file that cannot be read is an error, never a silent fall back to other defaults.
    public static func core(for hat: Hat?, settings: [String: HatSettings]) throws -> String {
        guard let hat, let playbook = settings[hat.rawValue]?.playbook?.trimmingCharacters(in: .whitespacesAndNewlines),
              !playbook.isEmpty else { return PRPlaybook.core }
        guard let file = file(in: playbook) else { return playbook }
        guard let text = try? String(contentsOf: file, encoding: .utf8), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybookError.unreadable(hat: hat, path: file.path)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What a job's agent reads first: its hat's operating defaults, then the move's own procedure,
    /// which stays Bton's whatever the hat says, since Bton parses what it produces.
    public static func text(for move: String, onIssue: Bool = false, settings: [String: HatSettings]) throws -> String {
        try PRPlaybook.text(for: move, onIssue: onIssue, core: core(for: hat(for: move), settings: settings))
    }

    /// The job log's word for what the agent was given.
    public static func describe(move: String, settings: [String: HatSettings]) -> String {
        guard let hat = hat(for: move) else { return "playbook v\(PRPlaybook.version)" }
        let custom = settings[hat.rawValue]?.playbook?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return "\(hat.rawValue) hat, " + (custom ? "own playbook" : "playbook v\(PRPlaybook.version)")
    }

    /// Why a pick cannot run this hat; nil when it can. The decider acts under the owner's login with
    /// tools denied, which only Claude Code enforces, so it takes no other agent.
    public static func problem(pick: AgentPick, for hat: Hat, agents: [String: AgentTemplate]) -> String? {
        guard let program = agents[pick.agent]?.argv.first else { return "\(pick.agent) is not an agent on this Mac." }
        if hat == .decider || hat == .triager, !AgentHardening.isClaude(program) {
            return "The \(hat.rawValue) posts as you with tools denied, which only Claude Code enforces: pick a claude agent."
        }
        return nil
    }
}
