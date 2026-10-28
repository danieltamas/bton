import Foundation

/// One entry of `release.when`: the first that holds makes a release due.
public enum ReleasePredicate: Sendable, Equatable {
    case aheadCommits(Int)
    case aheadDays(Int)
    case featuresWaiting(Int)

    public init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, let count = Int(parts[1]), count > 0 else { return nil }
        switch parts[0] {
        case "ahead_commits": self = .aheadCommits(count)
        case "ahead_days": self = .aheadDays(count)
        case "features_waiting": self = .featuresWaiting(count)
        default: return nil
        }
    }

    /// Why the release is due, or nil when this predicate does not hold.
    func reason(report: FeatureReport, now: Date) -> String? {
        switch self {
        case let .aheadCommits(count):
            guard let ahead = report.aheadCommits, ahead >= count else { return nil }
            return "\(ahead) commits ahead"
        case let .aheadDays(count):
            guard let since = report.unreleasedSince else { return nil }
            let days = Int(now.timeIntervalSince(since) / 86_400)
            return days >= count ? "\(days) days ahead" : nil
        case let .featuresWaiting(count):
            let waiting = FeaturePage.count(.shipsNext, report: report)
            return waiting >= count ? "\(waiting) features waiting" : nil
        }
    }
}

/// One entry of `release.blockedBy`: any that holds blocks the release. An open release PR
/// blocks a second one whether or not `release_pr_open` is written.
public enum ReleaseBlocker: Sendable, Equatable {
    case prInReviewOnPaths(String)
    case releasePROpen

    public init?(_ text: String) {
        if text == "release_pr_open" { self = .releasePROpen; return }
        let prefix = "pr_in_review_on_paths:"
        guard text.hasPrefix(prefix) else { return nil }
        let glob = String(text.dropFirst(prefix.count))
        guard PathGlob.isValid(glob) else { return nil }
        self = .prInReviewOnPaths(glob)
    }
}

/// Where a repo's release stands this sync, in the order the page tells it.
public enum ReleaseStanding: Sendable, Equatable {
    /// The release PR is open; `due` says whether the repo would merge it on its own.
    case open(number: Int, due: Bool)
    case blocked(String)
    case due(String)
    /// No predicate holds.
    case waiting
    /// No registry, or its facts could not be read: nothing to decide on.
    case unknown
}

/// The move that takes `from` to `to`: a PR Bton opens when the release is due and merges, after
/// the flow's release checks, on the owner's press or on its own when the repo starts its moves.
public enum Release {
    public static let move = "release"
    public static let item = "release"
    public static let defaultTimeoutMinutes = 40

    /// The release PR: the oldest open PR from `from` into `to`, whoever opened it.
    public static func pullRequest(_ pullRequests: [PullRequest], release: Flow.Release) -> PullRequest? {
        pullRequests.filter { isRelease($0, release) }.min { $0.number < $1.number }
    }

    /// A PR on the release pair is the release's, not the flow's: no move, no dispatch, no take,
    /// also in a flow whose base is `to`.
    public static func isRelease(_ pr: PullRequest, flow: Flow) -> Bool {
        flow.release.map { isRelease(pr, $0) } ?? false
    }

    /// Only this repo's own branch, opened by someone trusted: a fork can name its branches
    /// anything, and its PR would otherwise run the release checks and merge as the release.
    static func isRelease(_ pr: PullRequest, _ release: Flow.Release) -> Bool {
        pr.headRef == release.from && pr.baseRef == release.to && !pr.isCrossRepository
            && FlowEngine.trustedAssociations.contains(pr.authorAssociation)
    }

    public static func standing(release: Flow.Release, report: FeatureReport?, pullRequests: [PullRequest], now: Date) -> ReleaseStanding {
        guard let report, report.problem == nil, report.registry.registry != nil else { return .unknown }
        let due = dueReason(release: release, report: report, now: now)
        if let pr = pullRequest(pullRequests, release: release) { return .open(number: pr.number, due: due != nil) }
        if let blocked = blockedReason(release: release, pullRequests: pullRequests) { return .blocked(blocked) }
        if let due { return .due(due) }
        return .waiting
    }

    /// The first predicate that holds, as the page says it.
    public static func dueReason(release: Flow.Release, report: FeatureReport, now: Date) -> String? {
        release.when.compactMap(ReleasePredicate.init).lazy.compactMap { $0.reason(report: report, now: now) }.first
    }

    /// The first blocker that holds: an open PR into `from`, not a draft and not the release PR
    /// itself, touching a guarded path.
    public static func blockedReason(release: Flow.Release, pullRequests: [PullRequest]) -> String? {
        let releasePR = pullRequest(pullRequests, release: release)
        let open = pullRequests.filter { $0.baseRef == release.from && !$0.isDraft && $0.number != releasePR?.number }
            .sorted { $0.number < $1.number }
        for blocker in (release.blockedBy ?? []).compactMap(ReleaseBlocker.init) {
            guard case let .prInReviewOnPaths(glob) = blocker else { continue }
            // A PR whose files GitHub did not fully list may touch the path: it blocks until read.
            if let pr = open.first(where: { pr in pr.changedFilesTruncated || pr.changedFiles.contains { PathGlob.matches(glob, $0) } }) {
                return pr.changedFilesTruncated ? "PR #\(pr.number) has more files than GitHub lists" : "PR #\(pr.number) touches \(glob)"
            }
        }
        return nil
    }

    /// The merge of the open release PR, for `who`: its checks at the PR's head (the `from` tip)
    /// and the merge pinned to that head, run in a trusted worktree of `to`. `startsMoves`: the
    /// repo starts its moves and the release is due; a press needs neither, but no blocker.
    public static func candidate(pr: PullRequest, release: Flow.Release, repo: String, me: String, jobs: [Job],
                                 pullRequests: [PullRequest], startsMoves: Bool, pressed: Bool) -> DispatchCandidate? {
        guard release.who.caseInsensitiveCompare(me) == .orderedSame, !pr.isDraft, pressed || startsMoves,
              blockedReason(release: release, pullRequests: pullRequests) == nil,
              !jobs.contains(where: { $0.status == .running && $0.key.move == move
                  && $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame })
        else { return nil }
        let command = release.merge == "fast-forward"
            ? ["git", "push", "origin", "\(pr.headSha):refs/heads/\(release.to)"]
            : ["gh", "pr", "merge", String(pr.number), "--repo", repo, "--merge", "--match-head-commit", pr.headSha]
        var made = DispatchCandidate(target: .pullRequest(pr),
                                     move: Move(name: move, owner: me, ownerFromRotation: false, tier: "", hasDispatch: true),
                                     key: JobKey(repo: repo, item: "pr-\(pr.number)", move: move, head: pr.headSha),
                                     agent: nil, prompt: nil, command: command, postComment: false,
                                     timeout: .seconds((release.timeoutMinutes ?? defaultTimeoutMinutes) * 60), model: nil)
        // Empty, never nil: nil would hand the merge the flow's session checks.
        made.checks = release.checks ?? []
        made.commandBase = release.to
        made.pressed = pressed
        return made
    }
}
