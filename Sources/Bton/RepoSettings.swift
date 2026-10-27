import BtonCore
import Foundation

/// One watched repo's settings on this Mac (Settings > Repos).
extension AppStore {
    /// The branch PRs merge into; empty means GitHub's default branch.
    func setBranch(_ branch: String, for slug: String) throws {
        let branch = branch.trimmingCharacters(in: .whitespaces)
        guard branch.isEmpty || WatchedRepo.isBranchName(branch) else {
            throw SettingsError.invalid("\(branch) is not a branch name.")
        }
        try updateRepo(slug) { $0.branch = branch.isEmpty ? nil : branch }
    }

    /// Variables the repo's checks, merge commands and agents get on this Mac, as KEY=VALUE lines.
    func setEnvironment(_ text: String, for slug: String) throws {
        let environment: [String: String]
        do { environment = try WatchedRepo.parseEnvironment(text) } catch { throw SettingsError.invalid(error.localizedDescription) }
        try updateRepo(slug) { $0.environment = environment.isEmpty ? nil : environment }
    }

    /// The label a PR carries while a Bton works it; empty turns it off.
    func setWorkLabel(_ label: String, for slug: String) throws {
        guard label.isEmpty || WatchedRepo.isLabelName(label) else {
            throw SettingsError.invalid("A label is 1 to 50 characters, with no comma, control character or space at either end.")
        }
        try updateRepo(slug) { $0.workLabel = label.isEmpty ? nil : label }
    }

    /// How this Mac runs the repo's issue work, as `AgentPick` text; empty: the flow's agent as it is.
    func setWork(_ text: String, for slug: String) throws {
        let pick = try validPick(text)
        try updateRepo(slug) { $0.work = pick?.text }
    }

    /// How this Mac runs the repo's reviews, and the rules added to the review prompt.
    func setReviewer(_ text: String, rules: String, for slug: String) throws {
        let pick = try validPick(text)
        let rules = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rules.count <= 4_000 else { throw SettingsError.invalid("Review rules are 4000 characters at most.") }
        try updateRepo(slug) {
            $0.reviewer = pick?.text
            $0.reviewRules = rules.isEmpty ? nil : rules
        }
    }

    private func validPick(_ text: String) throws -> AgentPick? {
        let text = text.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        guard let pick = AgentPick(text) else {
            throw SettingsError.invalid("Write it as agent:model effort, like claude:sonnet medium. Effort is one of \(AgentPick.efforts.joined(separator: ", ")).")
        }
        guard agents[pick.agent] != nil else { throw SettingsError.invalid("\(pick.agent) is not an agent on this Mac.") }
        return pick
    }

    /// Whether my PRs that conflict with their base are resolved on their own; nil is on.
    func setResolveConflicts(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.resolveConflicts = on ? nil : false }
    }

    /// Whether a sync starts the flow's moves here; off, only schedules and the owner's asks start agents.
    func setStartMoves(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.startMoves = on ? true : nil }
    }

    /// Whether a sync takes teammates' moves on its own (needs startMoves); nil is off.
    func setTakeMoves(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.takeMoves = on ? true : nil }
    }

    /// Whether Bton keeps a code graph of the repo for its agents; nil is off.
    func setCodeGraph(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.codeGraph = on ? true : nil }
    }

    /// The Python with graphify, for every repo's graph; empty means the usual venv places.
    func setGraphifyPython(_ path: String) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        try update { $0.graphifyPython = trimmed.isEmpty ? nil : trimmed }
    }

    private func updateRepo(_ slug: String, _ change: (inout WatchedRepo) -> Void) throws {
        try update { config in
            for index in config.repos.indices where config.repos[index].slug == slug { change(&config.repos[index]) }
        }
    }
}
