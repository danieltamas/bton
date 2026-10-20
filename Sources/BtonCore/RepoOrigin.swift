import Foundation

/// Checks that a folder is a clone of the repo it is chosen for, so worktrees for one repo's
/// work are never made in another repo's clone.
public enum RepoOrigin {
    public enum Mismatch: Error, LocalizedError {
        case noOrigin(clone: String, expected: String, detail: String)
        case notGitHub(clone: String, expected: String, remote: String)
        case otherRepo(clone: String, expected: String, actual: String)

        public var errorDescription: String? {
            switch self {
            case let .noOrigin(clone, expected, detail):
                "\(clone) is not a clone of \(expected): it has no origin remote. \(detail.prefix(200))"
            case let .notGitHub(clone, expected, remote):
                "\(clone) is not a clone of \(expected): its origin is \(remote), not a GitHub repo."
            case let .otherRepo(clone, expected, actual):
                "\(clone) is a clone of \(actual), not \(expected)."
            }
        }
    }

    private static let githubPrefixes = ["git@github.com:", "ssh://git@github.com/", "https://github.com/"]

    /// `owner/name` from a GitHub remote URL in its SSH, scp-like or HTTPS form; nil for any other host.
    public static func slug(fromRemoteURL remote: String) -> String? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prefix = githubPrefixes.first(where: { trimmed.hasPrefix($0) }) else { return nil }
        var path = trimmed.dropFirst(prefix.count)
        if path.hasSuffix("/") { path = path.dropLast() }
        if path.hasSuffix(".git") { path = path.dropLast(4) }
        return BtonConfig.isRepoSlug(String(path)) ? String(path) : nil
    }

    /// The branches origin has, as this clone last fetched them, for choosing the branch PRs merge
    /// into. Only plain names; an unreadable clone has none.
    public static func remoteBranches(clone: URL, runner: ProcessRunner = ProcessRunner()) async -> [String] {
        guard let result = try? await runner.run("/usr/bin/git", ["-C", clone.path, "for-each-ref", "--format=%(refname:lstrip=3)",
                                                                   "refs/remotes/origin"], timeout: .seconds(10)),
              result.status == 0 else { return [] }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0 != "HEAD" && WatchedRepo.isBranchName($0) }.sorted()
    }

    /// The GitHub repo a folder is a clone of, and the clone's top level: git answers from any
    /// folder inside a clone, and worktrees made from a subfolder would land inside the tracked tree.
    public static func inspect(clone: URL, runner: ProcessRunner = ProcessRunner()) async throws -> (slug: String, top: URL) {
        let result = try await runner.run("/usr/bin/git", ["-C", clone.path, "remote", "get-url", "origin"],
                                          timeout: .seconds(10))
        guard result.status == 0 else { throw Unreadable.noOrigin(clone: clone.path, detail: result.stderr) }
        let remote = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let slug = Self.slug(fromRemoteURL: remote) else { throw Unreadable.notGitHub(clone: clone.path, remote: remote) }
        let top = try await runner.run("/usr/bin/git", ["-C", clone.path, "rev-parse", "--show-toplevel"],
                                       timeout: .seconds(10))
        guard top.status == 0 else { throw Unreadable.noOrigin(clone: clone.path, detail: top.stderr) }
        let path = String(decoding: top.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        return (slug, URL(fileURLWithPath: path, isDirectory: true))
    }

    public enum Unreadable: Error, LocalizedError {
        case noOrigin(clone: String, detail: String)
        case notGitHub(clone: String, remote: String)

        public var errorDescription: String? {
            switch self {
            case let .noOrigin(clone, detail): "\(clone) is not a git clone with an origin remote. \(detail.prefix(200))"
            case let .notGitHub(clone, remote): "\(clone) is a clone of \(remote), not of a GitHub repo."
            }
        }
    }

    /// Returns the clone's top level when the folder is a clone of `slug`.
    @discardableResult
    public static func verify(clone: URL, matches slug: String, runner: ProcessRunner = ProcessRunner()) async throws -> URL {
        let found: (slug: String, top: URL)
        do {
            found = try await inspect(clone: clone, runner: runner)
        } catch let Unreadable.noOrigin(path, detail) {
            throw Mismatch.noOrigin(clone: path, expected: slug, detail: detail)
        } catch let Unreadable.notGitHub(path, remote) {
            throw Mismatch.notGitHub(clone: path, expected: slug, remote: remote)
        }
        guard found.slug.caseInsensitiveCompare(slug) == .orderedSame else {
            throw Mismatch.otherRepo(clone: clone.path, expected: slug, actual: found.slug)
        }
        return found.top
    }
}
