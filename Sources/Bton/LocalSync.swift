import BtonCore
import Foundation
import Observation

/// The owner's own develop and main in each watched clone, brought up to date after every sync.
@MainActor
@Observable
final class LocalSync {
    /// Each repo's last report, by slug.
    private(set) var reports: [String: LocalBranchReport] = [:]
    private var running: Task<Void, Never>?

    /// Syncs every repo with a clone, unless a sync still runs: it never holds up GitHub's.
    /// A repo GitHub could not read this time has no default branch and waits for the next one.
    func start(repos: [WatchedRepo], defaults: [String: String]) {
        guard running == nil else { return }
        running = Task { [weak self] in
            for repo in repos {
                guard let path = repo.path, let main = defaults[repo.slug], !main.isEmpty else { continue }
                let report = await LocalBranches.sync(clone: URL(fileURLWithPath: path), working: repo.branch ?? main,
                                                      defaultBranch: main)
                self?.reports[repo.slug] = report
            }
            self?.running = nil
        }
    }
}
