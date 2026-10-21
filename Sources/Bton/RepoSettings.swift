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

    /// Whether my PRs that conflict with their base are resolved on their own; nil is on.
    func setResolveConflicts(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.resolveConflicts = on ? nil : false }
    }

    /// Whether a sync starts the flow's moves here; off, only schedules and the owner's asks start agents.
    func setStartMoves(_ on: Bool, for slug: String) throws {
        try updateRepo(slug) { $0.startMoves = on ? true : nil }
    }

    private func updateRepo(_ slug: String, _ change: (inout WatchedRepo) -> Void) throws {
        try update { config in
            for index in config.repos.indices where config.repos[index].slug == slug { change(&config.repos[index]) }
        }
    }
}
