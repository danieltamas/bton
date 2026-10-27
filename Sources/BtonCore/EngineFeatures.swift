import Foundation

/// A repo's registry with every feature's standing, as the repo page shows it.
public struct FeatureReport: Sendable, Equatable {
    public let repo: String
    public let registry: RegistryStatus
    /// By feature id.
    public var standings: [String: FeatureStanding] = [:]
    /// The oldest commit on the base that the release branch lacks.
    public var unreleasedSince: Date?
    /// The latest `live` date across features; nil without a `release` section.
    public var lastRelease: Date?
    public var hasRelease: Bool
    public var readAt: Date?
    /// Why the registry or its facts could not be read this time; the rest is from the last
    /// good read.
    public var problem: String?

    public init(repo: String, registry: RegistryStatus, hasRelease: Bool) {
        self.repo = repo
        self.registry = registry
        self.hasRelease = hasRelease
    }
}

/// What the engine keeps between ticks per repo: the facts cost one GitHub query per 50 links,
/// so they are read again only when something could have changed them.
struct FeatureState: Sendable {
    var registryHash = 0
    var facts = FeatureFacts()
    var factsAt: Date?
    var report: FeatureReport?
    var lastProblem: String?
}

extension Engine {
    /// Facts older than this are read again at the next sync, whatever happened.
    static let factsEvery: TimeInterval = 600

    /// The repo's report for this tick: the registry from the branch PRs merge into, the facts
    /// when due, the standings always. Its own failure never marks the repo unread.
    func readFeatures(repo: WatchedRepo, flow: Flow?, defaultBranch: String, merged: [MergedPullRequest]) async -> FeatureReport {
        let key = repo.slug.lowercased()
        var state = featureStates[key] ?? FeatureState()
        let hasRelease = flow?.release != nil
        let base = flow?.base ?? defaultBranch
        let to = flow?.release?.to ?? defaultBranch
        var report: FeatureReport
        do {
            let data = try await github.file(repo: repo.slug, path: FeatureRegistry.relativePath, branch: repo.branch)
            let status = FeatureRegistry.load(data)
            report = FeatureReport(repo: repo.slug, registry: status, hasRelease: hasRelease)
            if let registry = status.registry {
                let hash = data?.hashValue ?? 0
                if Self.factsDue(state, hash: hash, merged: merged, issues: openIssues[key] ?? [], now: .now) {
                    state.facts = try await github.featureFacts(repo: repo.slug, numbers: registry.linkedNumbers)
                    state.factsAt = .now
                    state.registryHash = hash
                }
                let commits = state.facts.pullRequests.values.compactMap(\.mergeCommit)
                var git = FeatureGit()
                if let path = repo.path {
                    git = await FeatureGit.read(clone: URL(fileURLWithPath: path, isDirectory: true), base: base, to: to, commits: commits)
                }
                report = Self.report(repo: repo.slug, registry: registry, facts: state.facts, git: git, base: base, hasRelease: hasRelease)
            }
            report.readAt = .now
            state.lastProblem = nil
        } catch {
            // The last good report stands, with the reason; said once per reason, not every sync.
            let reason = error.localizedDescription
            report = state.report ?? FeatureReport(repo: repo.slug, registry: .none, hasRelease: hasRelease)
            report.problem = reason
            if state.lastProblem != reason { log("\(repo.slug): features not read: \(reason)") }
            state.lastProblem = reason
        }
        state.report = report
        featureStates[key] = state
        return report
    }

    /// Facts are read when none were, the registry changed, they are older than `factsEvery`,
    /// or a PR merged or an issue appeared since they were read.
    static func factsDue(_ state: FeatureState, hash: Int, merged: [MergedPullRequest], issues: [OpenIssue], now: Date) -> Bool {
        guard let at = state.factsAt else { return true }
        if hash != state.registryHash || now.timeIntervalSince(at) >= factsEvery { return true }
        return merged.contains { $0.mergedAt > at } || issues.contains { $0.createdAt > at }
    }

    static func report(repo: String, registry: FeatureRegistry, facts: FeatureFacts, git: FeatureGit,
                       base: String, hasRelease: Bool) -> FeatureReport {
        var report = FeatureReport(repo: repo, registry: .ready(registry), hasRelease: hasRelease)
        for feature in registry.features {
            report.standings[feature.id] = FeatureStatuses.standing(of: feature, facts: facts, git: git, base: base, hasRelease: hasRelease)
        }
        report.unreleasedSince = git.unreleasedSince
        if hasRelease {
            report.lastRelease = report.standings.values.filter { $0.status == .live }.compactMap(\.since).max()
        }
        return report
    }
}
