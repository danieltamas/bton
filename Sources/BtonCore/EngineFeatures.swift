import Foundation

/// A repo's registry with every feature's standing, as the repo page shows it.
public struct FeatureReport: Sendable, Equatable {
    public let repo: String
    public let registry: RegistryStatus
    /// By feature id.
    public var standings: [String: FeatureStanding] = [:]
    /// The oldest commit on the base that the release branch lacks, and how many there are.
    public var unreleasedSince: Date?
    public var aheadCommits: Int?
    /// Where the release stands; nil without a `release` section.
    public var release: ReleaseStanding?
    /// The latest `live` date across features; nil without a `release` section.
    public var lastRelease: Date?
    public var hasRelease: Bool
    /// The registry job's PR the registry was read from, while the base has none and the PR is
    /// open: the page shows what the job made before the team merges it.
    public var previewPullRequest: Int?
    /// What GitHub said about the linked issues and PRs: the detail's titles and dates.
    public var facts = FeatureFacts()
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
    func readFeatures(repo: WatchedRepo, flow: Flow?, defaultBranch: String, viewer: String, merged: [MergedPullRequest],
                      pullRequests: [PullRequest]) async -> FeatureReport {
        let key = repo.slug.lowercased()
        var state = featureStates[key] ?? FeatureState()
        let hasRelease = flow?.release != nil
        let base = flow?.base ?? defaultBranch
        let to = flow?.release?.to ?? defaultBranch
        var report: FeatureReport
        do {
            var data = try await github.file(repo: repo.slug, path: FeatureRegistry.relativePath, branch: repo.branch)
            var preview: Int?
            // The base has none yet and the job's PR is open: its branch's file, marked as such.
            if data == nil, let pr = FeatureJob.openPullRequest(pullRequests, repo: repo.slug, me: viewer) {
                data = try await github.file(repo: repo.slug, path: FeatureRegistry.relativePath, branch: pr.headRef)
                preview = data == nil ? nil : pr.number
            }
            let status = FeatureRegistry.load(data)
            report = FeatureReport(repo: repo.slug, registry: status, hasRelease: hasRelease)
            report.previewPullRequest = preview
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
                    git = await FeatureGit.read(clone: URL(fileURLWithPath: path, isDirectory: true), base: base, to: to,
                                                from: flow?.release?.from, commits: commits)
                    // A clone that could not be read would turn every live feature into an idea.
                    if let problem = git.problem { throw FeatureGit.Failure(command: "", reason: problem) }
                }
                report = Self.report(repo: repo.slug, registry: registry, facts: state.facts, git: git, base: base, hasRelease: hasRelease)
                report.previewPullRequest = preview
                report.facts = state.facts
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
        if let release = flow?.release {
            report.release = Release.standing(release: release, report: report, pullRequests: pullRequests, now: .now)
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
        report.aheadCommits = git.aheadCommits
        if hasRelease {
            report.lastRelease = report.standings.values.filter { $0.status == .live }.compactMap(\.since).max()
        }
        return report
    }
}

extension Engine {
    /// The registry job when due and the repo's code graph is built; a press made before that
    /// waits in line with the reason. An automatic run also asks the item's lease when the last
    /// run started on any Mac, so two Btons keep one nightly clock; a lease that cannot be read
    /// means no automatic run this tick.
    func featureJob(_ read: (repo: WatchedRepo, flow: Flow?, viewer: String, defaultBranch: String,
                                     pullRequests: [PullRequest], merged: [MergedPullRequest]),
                            agents: [String: AgentTemplate], graphifyPython: String?, leases: LeaseStore) async -> DispatchCandidate? {
        let slug = read.repo.slug
        let pick = Self.pick(repo: slug, item: FeatureJob.item)
        let pressed = next.contains(pick)
        // The areas come from the graph: without one, the job would draw them from the tree's layout.
        if let hold = CodeGraph.readiness(of: read.repo, python: CodeGraph.python(configured: graphifyPython), home: home).hold {
            if pressed { deferred[pick] = hold }
            return nil
        }
        let make = { (teamLast: Date?) -> DispatchCandidate? in
            FeatureJob.candidate(jobs: self.jobs.all(), repo: slug, flow: read.flow,
                                 defaultBranch: read.repo.branch ?? read.defaultBranch, me: read.viewer,
                                 agents: agents, work: read.repo.work.flatMap(AgentPick.init),
                                 registry: self.featureStates[slug.lowercased()]?.report?.registry ?? .none,
                                 pullRequests: read.pullRequests, merged: read.merged,
                                 issues: self.openIssues[slug.lowercased()] ?? [],
                                 startsMoves: read.repo.startsMoves, pressed: pressed, teamLast: teamLast)
        }
        guard let local = make(nil) else { return nil }
        if pressed { return local }
        guard let item = LeaseItem(FeatureJob.item), let state = try? await leases.state(of: item, in: slug) else { return nil }
        return make(FeatureJob.lastStart(state))
    }
}

extension Engine {
    /// The moves that get no feature context: the one that builds the registry, and the drafts,
    /// which read the code map instead.
    static let movesWithoutContext: Set = [FeatureJob.move, NewIssues.move, IssueDrafts.move]

    /// The candidate with the registry's knowledge of its work attached, for an agent job of a
    /// repo whose registry loads. The prompt gains Bton's line naming the file and, for a job that
    /// edits the PR, the `Feature:` line the body carries.
    static func withFeatureContext(_ candidate: DispatchCandidate, report: FeatureReport?) -> DispatchCandidate {
        guard candidate.agent != nil, let prompt = candidate.prompt, !Self.movesWithoutContext.contains(candidate.key.move),
              candidate.attachments[FeatureContext.file] == nil,
              let report, let context = FeatureContext.make(for: candidate.target, report: report) else { return candidate }
        var made = candidate
        made.attachments[FeatureContext.file] = context.text
        let writes = !candidate.postComment && candidate.key.move != Supervision.move
        made.prompt = prompt + "\n\n" + FeatureContext.promptLine(feature: context.feature, writes: writes)
        return made
    }
}
