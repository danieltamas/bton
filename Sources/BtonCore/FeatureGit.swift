import Foundation

/// What the clone says about where merge commits went: on the release branch, on the base, and
/// when each reached the release branch. Read from `refs/remotes/origin/<branch>` as they are:
/// the app's LocalSync fetches both every sync; `bton watch` reads what the last fetch left.
public struct FeatureGit: Sendable, Equatable {
    /// Every commit on origin/<to> and on origin/<base>; empty when the ref is missing.
    public var onRelease: Set<String> = []
    public var onBase: Set<String> = []
    /// For each merge commit asked that is on <to>: the commit date of the oldest first-parent
    /// commit of <to> that contains it, which is when the branch was released. A merge commit
    /// that is itself first-parent on <to> dates itself.
    public var releasedAt: [String: Date] = [:]
    /// The oldest commit on origin/<base> that origin/<to> lacks: how long the release waits.
    public var unreleasedSince: Date?

    public init() {}

    static let timeout: Duration = .seconds(60)

    public static func read(clone: URL, base: String, to: String, commits: [String],
                            runner: ProcessRunner = ProcessRunner()) async -> FeatureGit {
        var git = FeatureGit()
        guard LocalBranches.isPlain(base), LocalBranches.isPlain(to) else { return git }
        let release = "refs/remotes/origin/\(to)", develop = "refs/remotes/origin/\(base)"
        git.onRelease = Set(await lines(["rev-list", release], clone: clone, runner: runner))
        git.onBase = Set(await lines(["rev-list", develop], clone: clone, runner: runner))
        let firstParent = Set(await lines(["rev-list", "--first-parent", release], clone: clone, runner: runner))
        for sha in commits where git.onRelease.contains(sha) && Self.isSHA(sha) {
            // A merge made on <to> itself dates itself; one brought in by a later merge (develop into
            // main) is dated by the oldest first-parent commit of <to> that descends from it.
            let last = firstParent.contains(sha)
                ? await lines(["show", "-s", "--format=%H:%ct", sha], clone: clone, runner: runner).last
                : await lines(["log", "--first-parent", "--ancestry-path", "--format=%H:%ct", "\(sha)..\(release)"],
                              clone: clone, runner: runner).last
            if let seconds = last?.split(separator: ":").last.flatMap({ TimeInterval($0) }) {
                git.releasedAt[sha] = Date(timeIntervalSince1970: seconds)
            }
        }
        if base != to {
            let ahead = await lines(["log", "--format=%ct", "\(release)..\(develop)"], clone: clone, runner: runner)
            git.unreleasedSince = ahead.last.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
        }
        return git
    }

    static func isSHA(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit }
    }

    private static func lines(_ arguments: [String], clone: URL, runner: ProcessRunner) async -> [String] {
        guard let result = try? await runner.run("/usr/bin/git", arguments, in: clone, environment: ["GIT_TERMINAL_PROMPT": "0"],
                                                 timeout: timeout), result.status == 0 else { return [] }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }
}
