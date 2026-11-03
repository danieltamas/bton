import Foundation

/// Which files keep conflicting: every `resolve` job records the paths in conflict between its PR
/// and the base when it started, and the repo page ranks them by how many PRs each one stopped.
public enum ConflictHotspots {
    public static let window: TimeInterval = 14 * 86400
    public static let shown = 8

    public typealias Hotspot = (path: String, pullRequests: Int)

    /// Per path, the distinct PRs whose resolve job of the last `window` listed it; most first,
    /// then by path; at most `shown`.
    public static func rank(jobs: [Job], repo: String, now: Date = .now) -> [Hotspot] {
        let since = now.addingTimeInterval(-window)
        var items: [String: Set<String>] = [:]
        for job in jobs where job.key.move == "resolve" && job.key.repo.caseInsensitiveCompare(repo) == .orderedSame && job.startedAt >= since {
            for path in job.conflicts ?? [] { items[path, default: []].insert(job.key.item) }
        }
        return items.map { (path: $0.key, pullRequests: $0.value.count) }
            .sorted { $0.pullRequests != $1.pullRequests ? $0.pullRequests > $1.pullRequests : $0.path < $1.path }
            .prefix(shown).map { $0 }
    }

    /// `Conflicts, 14 days: src/cli.js (3 PRs), docs/formats.md (1 PR)`; nil with nothing to say.
    public static func line(_ ranked: [Hotspot]) -> String? {
        guard !ranked.isEmpty else { return nil }
        let items = ranked.map { "\($0.path) (\($0.pullRequests) PR\($0.pullRequests == 1 ? "" : "s"))" }
        return "Conflicts, 14 days: " + items.joined(separator: ", ")
    }
}
