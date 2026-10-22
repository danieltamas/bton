import Foundation

/// The repo's work label on a PR while a Bton holds its lease (U9): shown to teammates, never read
/// back. The lease stays the lock.
public enum WorkLabels {
    public static let maxReadsPerSync = 10

    /// Where `bton lease claim` keeps the label it added until the release: the setting may change
    /// between them.
    /// One file per claim: a job may hold several leases.
    public static func claimFile(job: UUID, repo: String, item: LeaseItem, home: BtonHome) -> URL {
        let name = "\(job.uuidString.lowercased())-\(repo.lowercased().replacingOccurrences(of: "/", with: "~"))-\(item)"
        return home.url.appendingPathComponent("work-labels", isDirectory: true).appendingPathComponent(name)
    }

    public static func label(for repo: String, in config: BtonConfig) -> String? {
        config.repos.first { $0.slug.caseInsensitiveCompare(repo) == .orderedSame }?.workLabel
    }

    /// Adds or removes the label on a PR's lease item; a schedule's or an issue's has none. A failure
    /// is one line to `note`, never thrown: a label never fails a job or a claim.
    public static func set(_ on: Bool, label: String?, item: LeaseItem, repo: String, github: GitHubClient,
                           note: (String) -> Void) async {
        guard let label, item.kind == "pr" else { return }
        do {
            if on {
                try await github.addLabel(label, repo: repo, number: item.number)
            } else {
                try await github.removeLabel(label, repo: repo, number: item.number)
            }
        } catch {
            let reason = error.localizedDescription.split(whereSeparator: \.isNewline).joined(separator: " ")
            note("could not \(on ? "add" : "remove") the label \(label): \(reason)")
        }
    }

    /// PRs carrying the label whose lease is free or absent, reading at most `maxReadsPerSync`
    /// leases; a held lease or a failed read keeps the label.
    public static func stale(_ prs: [PullRequest], label: String,
                             state: (Int) async throws -> LeaseState) async -> [Int] {
        var stale: [Int] = []
        let labelled = prs.filter { $0.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        for pr in labelled.prefix(maxReadsPerSync) {
            switch try? await state(pr.number) {
            case .free, .absent: stale.append(pr.number)
            case .held, nil: continue
            }
        }
        return stale
    }
}
