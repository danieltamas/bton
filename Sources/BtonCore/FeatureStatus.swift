import Foundation

/// Where a feature is, from the first that applies: its code is on the release branch, merged
/// into the base and waiting for a release, in an open PR, ready for work, being specified, or
/// an idea nobody has started. A feature the registry closed is retired whatever its code did.
public enum FeatureStatus: String, Sendable, CaseIterable, Comparable {
    case live, inDevelop = "in develop", building, ready, spec, idea, retired

    public static func < (lhs: FeatureStatus, rhs: FeatureStatus) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public struct FeatureStanding: Sendable, Equatable {
    /// One status the feature reached, when, and the issue or PR that put it there.
    public struct Event: Sendable, Equatable {
        public let status: FeatureStatus
        public let at: Date?
        public let number: Int?

        public init(status: FeatureStatus, at: Date?, number: Int?) {
            self.status = status
            self.at = at
            self.number = number
        }
    }

    public let status: FeatureStatus
    /// Oldest first, one per status reached.
    public let timeline: [Event]
    public let openIssues: Int
    public let openPullRequests: Int
    /// Merged PR numbers, newest merge first.
    public let changes: [Int]

    public var since: Date? { timeline.last { $0.status == status }?.at }

    public init(status: FeatureStatus, timeline: [Event], openIssues: Int, openPullRequests: Int, changes: [Int]) {
        self.status = status
        self.timeline = timeline
        self.openIssues = openIssues
        self.openPullRequests = openPullRequests
        self.changes = changes
    }
}

public enum FeatureStatuses {
    public static let readyLabel = "stage:ready"
    public static let specLabel = "stage:spec"

    /// The spec's table, top down; `hasRelease` false means merges into the base count only when
    /// the base is the release branch itself, so "in develop" never applies. `areaPaths` are the
    /// feature's area's, the code a feature without paths of its own is measured against.
    public static func standing(of feature: FeatureRegistry.Feature, facts: FeatureFacts, git: FeatureGit,
                                base: String, hasRelease: Bool, areaPaths: [String] = []) -> FeatureStanding {
        // A number linked twice (title and body) is one issue or PR; by number, so two PRs
        // merged in the same release resolve the same way every sync.
        let linked = Set(feature.prs.map(\.number)).sorted().compactMap { facts.pullRequests[$0] }
        let issues = Set(feature.issues.map(\.number)).sorted().compactMap { facts.issues[$0] }
        // A plan or a doc merged for the feature is one of its changes, but not the feature
        // built: on lexito the plan PR of an open issue showed the feature live.
        let paths = feature.paths.isEmpty ? areaPaths : feature.paths
        let prs = linked.filter { isCode($0, paths: paths) }
        let merged = prs.filter { $0.state == "MERGED" }
        let allMerged = linked.filter { $0.state == "MERGED" }
        let live = merged.compactMap { pr in pr.mergeCommit.flatMap { git.releasedAt[$0] }.map { (pr.number, $0) } }
            .min { $0.1 < $1.1 }
        let inDevelop = hasRelease
            ? merged.filter { $0.baseRef == base && $0.mergedAt != nil }.min { $0.mergedAt! < $1.mergedAt! }
            : nil
        let openPRs = prs.filter { $0.state == "OPEN" }
        let building = openPRs.min { $0.createdAt < $1.createdAt }
        // A merged PR was open once: the feature passed through building when it was opened.
        let built = building ?? merged.min { $0.createdAt < $1.createdAt }
        let open = issues.filter(\.open)
        let ready = labeled(open, readyLabel)
        let spec = labeled(open, specLabel)
        let idea: (Date?, Int?) = issues.min { $0.createdAt < $1.createdAt }.map { ($0.createdAt, $0.number) }
            ?? (feature.firstSeen.flatMap(Self.day), nil)

        var timeline: [FeatureStanding.Event] = []
        if idea.0 != nil || idea.1 != nil || !issues.isEmpty || !linked.isEmpty {
            timeline.append(.init(status: .idea, at: idea.0, number: idea.1))
        }
        if let spec { timeline.append(.init(status: .spec, at: spec.1, number: spec.0)) }
        if let ready { timeline.append(.init(status: .ready, at: ready.1, number: ready.0)) }
        if let built { timeline.append(.init(status: .building, at: built.createdAt, number: built.number)) }
        if let inDevelop { timeline.append(.init(status: .inDevelop, at: inDevelop.mergedAt, number: inDevelop.number)) }
        if let live { timeline.append(.init(status: .live, at: live.1, number: live.0)) }
        // Events that happened in the order they did, not the rank's: a spec after a PR reads as it was.
        timeline.sort { ($0.at ?? .distantPast, $0.status) < ($1.at ?? .distantPast, $1.status) }

        let reached: FeatureStatus = live != nil ? .live : inDevelop != nil ? .inDevelop : building != nil ? .building
            : ready != nil ? .ready : spec != nil ? .spec : .idea
        // A status reached by rank is reached whatever its date; the first event of it is kept.
        if !timeline.contains(where: { $0.status == reached }) {
            timeline.append(.init(status: reached, at: idea.0, number: idea.1))
        }
        // A retirement ends the story after everything the feature went through.
        let status: FeatureStatus
        if let closed = feature.closed {
            timeline.append(.init(status: .retired, at: Self.day(closed), number: nil))
            status = .retired
        } else {
            status = reached
        }
        return FeatureStanding(status: status, timeline: timeline, openIssues: open.count,
                               openPullRequests: openPRs.count,
                               changes: allMerged.sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.map(\.number))
    }

    /// A PR is the feature's code unless every file it changes is Markdown: a plan under
    /// `jobs/`, a doc, a log entry. The feature's paths can still claim such a file (a feature
    /// of the team's process is made of docs). Files not read leave the PR counting as it
    /// always did. The feature's globs alone would be too narrow a measure: on lexito most
    /// features' code sits outside the few paths the registry lists for them.
    static func isCode(_ pr: FeatureFacts.PullRequestFact, paths: [String]) -> Bool {
        guard let files = pr.files, !files.isEmpty else { return true }
        return files.contains { file in !file.lowercased().hasSuffix(".md") || paths.contains { PathGlob.matches($0, file) } }
    }

    /// The open issue that carried the label first, with when it got it (its creation when the
    /// label event is older than the last 30).
    private static func labeled(_ issues: [FeatureFacts.IssueFact], _ label: String) -> (Int, Date)? {
        issues.filter { $0.labels.contains(label) }
            .map { ($0.number, $0.labeledAt[label] ?? $0.createdAt) }
            .min { $0.1 < $1.1 }
    }

    static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }
}
