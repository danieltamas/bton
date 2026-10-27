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
    /// Why the clone could not be read: a git that failed or hung. A missing ref is not one;
    /// the branch has not been fetched, and its sets are empty.
    public var problem: String?

    public init() {}

    static let timeout: Duration = .seconds(60)

    public static func read(clone: URL, base: String, to: String, commits: [String],
                            runner: ProcessRunner = ProcessRunner()) async -> FeatureGit {
        var git = FeatureGit()
        guard LocalBranches.isPlain(base), LocalBranches.isPlain(to) else { return git }
        let release = "refs/remotes/origin/\(to)", develop = "refs/remotes/origin/\(base)"
        do {
            let hasRelease = try await exists(release, clone: clone, runner: runner)
            let hasBase = try await exists(develop, clone: clone, runner: runner)
            if hasRelease {
                git.onRelease = Set(try await lines(["rev-list", release], clone: clone, runner: runner))
            }
            if hasBase {
                git.onBase = Set(try await lines(["rev-list", develop], clone: clone, runner: runner))
            }
            let firstParent = hasRelease ? Set(try await lines(["rev-list", "--first-parent", release], clone: clone, runner: runner)) : []
            for sha in commits where git.onRelease.contains(sha) && Self.isSHA(sha) {
                // A merge made on <to> itself dates itself; one brought in by a later merge (develop into
                // main) is dated by the oldest first-parent commit of <to> that descends from it.
                let last = firstParent.contains(sha)
                    ? try await lines(["show", "-s", "--format=%H:%ct", sha], clone: clone, runner: runner).last
                    : try await lines(["log", "--first-parent", "--ancestry-path", "--format=%H:%ct", "\(sha)..\(release)"],
                                      clone: clone, runner: runner).last
                if let seconds = last?.split(separator: ":").last.flatMap({ TimeInterval($0) }) {
                    git.releasedAt[sha] = Date(timeIntervalSince1970: seconds)
                }
            }
            if base != to, hasRelease, hasBase {
                let ahead = try await lines(["log", "--format=%ct", "\(release)..\(develop)"], clone: clone, runner: runner)
                git.unreleasedSince = ahead.last.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
            }
        } catch {
            git.problem = error.localizedDescription
        }
        return git
    }

    struct Failure: Error, LocalizedError {
        let command: String
        let reason: String
        var errorDescription: String? { "git \(command): \(reason)" }
    }

    private static func exists(_ ref: String, clone: URL, runner: ProcessRunner) async throws -> Bool {
        let result = try await run(["rev-parse", "--verify", "--quiet", ref], clone: clone, runner: runner)
        return result.status == 0
    }

    static func isSHA(_ text: String) -> Bool {
        text.count == 40 && text.allSatisfy { $0.isHexDigit }
    }

    private static func lines(_ arguments: [String], clone: URL, runner: ProcessRunner) async throws -> [String] {
        let result = try await run(arguments, clone: clone, runner: runner)
        guard result.status == 0 else {
            throw Failure(command: arguments.first ?? "", reason: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private static func run(_ arguments: [String], clone: URL, runner: ProcessRunner) async throws -> ProcessOutput {
        do {
            return try await runner.run("/usr/bin/git", arguments, in: clone, environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: timeout)
        } catch {
            throw Failure(command: arguments.first ?? "", reason: error.localizedDescription)
        }
    }
}
