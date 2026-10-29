import Foundation

/// `bton docs-review <number> <head> <base> <tier>`: the git plumbing around `DocsReview`, run
/// in the trusted base worktree (detached at the base's merged tip, so the diff is against HEAD).
/// Exit codes are the dispatcher's contract for a review command: 0 posts `out`, 2 is
/// "unavailable here, retry later" and is reserved for a head that cannot be fetched, 3 fails
/// the job with the line on stderr.
public enum DocsReviewRun {
    public static let defaultGlobs = ["*.md", "**/*.md"]
    static let timeout: Duration = .seconds(60)

    public static func run(number: Int, head: String, base: String, tier: String,
                           in repo: URL, out: URL, runner: ProcessRunner) async -> Int32 {
        guard number > 0, head.count >= 7, head.count <= 40, head.allSatisfy(\.isHexDigit) else {
            return fail("docs-review: the head must be 7 to 40 hex digits and the PR number positive")
        }
        guard WatchedRepo.isBranchName(base) else { return fail("docs-review: invalid base branch \(base)") }
        do {
            if try await git(["cat-file", "-e", "\(head)^{commit}"], in: repo, runner: runner) == nil {
                // The ref GitHub keeps for every PR by number, forks included.
                _ = try await git(["fetch", "--quiet", "origin", "refs/pull/\(number)/head"], in: repo, runner: runner)
                guard try await git(["cat-file", "-e", "\(head)^{commit}"], in: repo, runner: runner) != nil else {
                    return fail("docs-review: head \(head) of PR #\(number) is not fetchable here", status: 2)
                }
            }
            guard let changed = try await git(["diff", "-z", "--name-only", "--diff-filter=ACMR", "HEAD...\(head)"], in: repo, runner: runner),
                  let listed = try await git(["ls-tree", "-r", "-z", "--name-only", head], in: repo, runner: runner) else {
                return fail("docs-review: git could not diff HEAD...\(head) against \(base)", status: 3)
            }
            var files: [DocsReview.File] = []
            for path in paths(changed) {
                let shown = try await runner.run("/usr/bin/git", ["show", "\(head):\(path)"], in: repo,
                                                 environment: environment, timeout: timeout)
                guard shown.status == 0 else { return fail("docs-review: git show \(head):\(path) exited \(shown.status)", status: 3) }
                files.append(DocsReview.File(path: path, bytes: shown.stdout))
            }
            let tree = Set(paths(listed))
            let verdict = DocsReview.review(files, tree: tree, allowed: allowedGlobs(tier: tier, repo: repo))
            try DocsReview.report(verdict, head: head).write(to: out, atomically: true, encoding: .utf8)
            return 0
        } catch {
            return fail("docs-review: \(error.localizedDescription)", status: 3)
        }
    }

    /// The tier's `only` globs from the base's flow, else every markdown file.
    static func allowedGlobs(tier: String, repo: URL) -> [String] {
        let data = try? Data(contentsOf: repo.appendingPathComponent(".bton/flow.json"))
        guard let globs = Flow.load(data).flow?.tier.only?[tier], !globs.isEmpty else { return defaultGlobs }
        return globs
    }

    static let environment = ["GIT_TERMINAL_PROMPT": "0"]

    /// NUL-separated paths from `-z` output: a name with a newline, a tab or a quote arrives whole.
    static func paths(_ output: String) -> [String] {
        output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
    }

    /// Stdout on exit 0, nil on any other exit.
    private static func git(_ arguments: [String], in repo: URL, runner: ProcessRunner) async throws -> String? {
        let result = try await runner.run("/usr/bin/git", arguments, in: repo, environment: environment, timeout: timeout)
        return result.status == 0 ? String(decoding: result.stdout, as: UTF8.self) : nil
    }

    private static func fail(_ message: String, status: Int32 = 3) -> Int32 {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        return status
    }
}
