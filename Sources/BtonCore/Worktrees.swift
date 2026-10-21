import Foundation

/// Where a PR's job runs.
enum Worktrees {
    /// The clone's existing worktree for the PR's branch (a team's own worktree script may make
    /// those) when it is clean at the head, else `.worktrees/bton-pr-<n>` detached at the PR
    /// head. The head is fetched from `refs/pull/<n>/head`, so forks and unpushed local branches
    /// make no difference.
    static func prepare(clone: URL, pr: PullRequest, base: String, ghPath: String, runner: ProcessRunner,
                        note: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        try await git(["fetch", "--quiet", "origin", "+refs/pull/\(pr.number)/head:refs/bton/pull/\(pr.number)",
                       "+refs/heads/\(base):refs/remotes/origin/\(base)"], in: clone, ghPath: ghPath, runner: runner)
        let listing = try await git(["worktree", "list", "--porcelain"], in: clone, ghPath: ghPath, runner: runner)
        // Someone's own tree only when it is clean and exactly at the head: otherwise the agent
        // would work on, or commit over, changes nobody reviewed.
        if let path = worktree(onBranch: pr.headRef, in: listing).map({ URL(fileURLWithPath: $0, isDirectory: true) }),
           FileManager.default.fileExists(atPath: path.path),
           try await cleanHead(path, ghPath: ghPath, runner: runner) == pr.headSha {
            return path
        }
        return try await detached(clone.appendingPathComponent(".worktrees/bton-pr-\(pr.number)", isDirectory: true),
                                  at: pr.headSha, clone: clone, ghPath: ghPath, runner: runner, note: note)
    }

    /// A schedule's tree, `.worktrees/bton-<item>`, detached at the default branch's tip as just
    /// fetched, so each run starts from what the team has merged.
    static func prepare(clone: URL, branch: String, item: String, ghPath: String, runner: ProcessRunner,
                        fresh: Bool = false, note: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        try await git(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"],
                      in: clone, ghPath: ghPath, runner: runner)
        let tip = try await git(["rev-parse", "refs/remotes/origin/\(branch)"], in: clone, ghPath: ghPath, runner: runner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try await detached(clone.appendingPathComponent(".worktrees/bton-\(item)", isDirectory: true),
                                  at: tip, clone: clone, ghPath: ghPath, runner: runner, fresh: fresh, note: note)
    }

    /// Bton's own tree at `sha`. An earlier job's leftover changes go to the clone's `git stash`,
    /// named after the tree, for a person to look at; refusing instead stopped the tree's every
    /// later job (a build step that rewrites a tracked file leaves such changes on each run).
    /// `fresh` replaces the tree outright, ignored files included.
    private static func detached(_ path: URL, at sha: String, clone: URL, ghPath: String, runner: ProcessRunner,
                                 fresh: Bool = false, note: @Sendable (String) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: path.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            // A PR's check could plant a link here to someone's checkout: nothing is stashed or
            // switched until the path is Bton's own worktree of this clone.
            guard try await isOwnWorktree(path, clone: clone, ghPath: ghPath, runner: runner) else {
                throw DispatchError.worktree("\(path.path) is not a worktree Bton made in this clone; left as it is")
            }
            if fresh {
                try await git(["worktree", "remove", "--force", path.path], in: clone, ghPath: ghPath, runner: runner)
                return try await detached(path, at: sha, clone: clone, ghPath: ghPath, runner: runner, note: note)
            }
            if try await cleanHead(path, ghPath: ghPath, runner: runner) == nil {
                let message = "bton: leftovers in \(path.lastPathComponent) before \(Date.now.formatted(.iso8601))"
                try await git(["stash", "push", "--include-untracked", "--message", message], in: path, ghPath: ghPath, runner: runner)
                let left = try await git(["status", "--porcelain"], in: path, ghPath: ghPath, runner: runner)
                guard left.isEmpty else {
                    // A stash leaves a dirty submodule, and an antivirus that quarantines a
                    // tracked file deletes it again as soon as git puts it back.
                    let paths = left.split(separator: "\n").prefix(3).map { $0.dropFirst(3) }.joined(separator: ", ")
                    throw DispatchError.worktree("\(path.path) still has changes after stashing them (a dirty submodule, or something outside git such as an antivirus quarantining a file): \(paths)")
                }
                let stash = (try? await git(["rev-parse", "--verify", "refs/stash"], in: path, ghPath: ghPath, runner: runner))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                note("saved an earlier job's changes in \(path.lastPathComponent) to git stash \(stash): \(message)")
            }
            try await git(["checkout", "--quiet", "--detach", sha], in: path, ghPath: ghPath, runner: runner)
        } else {
            try await git(["worktree", "add", "--quiet", "--detach", path.path, sha], in: clone,
                          ghPath: ghPath, runner: runner)
        }
        return path
    }

    /// The path is `.worktrees/<name>` of the clone itself, no link on the way, and git lists it
    /// as one of the clone's worktrees.
    private static func isOwnWorktree(_ path: URL, clone: URL, ghPath: String, runner: ProcessRunner) async throws -> Bool {
        let expected = realPath(clone.path) + "/.worktrees/" + path.lastPathComponent
        guard realPath(path.path) == expected else { return false }
        let listing = try await git(["worktree", "list", "--porcelain"], in: clone, ghPath: ghPath, runner: runner)
        guard listing.split(separator: "\n").contains(where: { line in
            line.hasPrefix("worktree ") && realPath(String(line.dropFirst("worktree ".count))) == expected
        }) else { return false }
        // A tree whose `.git` file is gone would have git fall through to the main checkout.
        let top = try? await git(["rev-parse", "--show-toplevel"], in: path, ghPath: ghPath, runner: runner)
        return top.map { realPath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == expected
    }

    /// Removes Bton's own tree when nothing in it changed; false when it stays.
    static func removeClean(_ path: URL, clone: URL, ghPath: String, runner: ProcessRunner) async -> Bool {
        guard (try? await cleanHead(path, ghPath: ghPath, runner: runner)) != nil else { return false }
        return (try? await git(["worktree", "remove", path.path], in: clone, ghPath: ghPath, runner: runner)) != nil
    }

    /// The tree's HEAD when nothing is modified or untracked (ignored files aside), else nil.
    private static func cleanHead(_ worktree: URL, ghPath: String, runner: ProcessRunner) async throws -> String? {
        let status = try await git(["status", "--porcelain"], in: worktree, ghPath: ghPath, runner: runner)
        guard status.isEmpty else { return nil }
        return try await git(["rev-parse", "HEAD"], in: worktree, ghPath: ghPath, runner: runner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The path of the worktree that has `refs/heads/<branch>` checked out, from `git worktree list --porcelain`.
    static func worktree(onBranch branch: String, in porcelain: String) -> String? {
        for block in porcelain.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard lines.contains("branch refs/heads/\(branch)"),
                  let path = lines.first(where: { $0.hasPrefix("worktree ") }) else { continue }
            return String(path.dropFirst("worktree ".count))
        }
        return nil
    }

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL, ghPath: String, runner: ProcessRunner) async throws -> String {
        // GitHub over HTTPS with gh's token, like the agents: an SSH key behind an agent that asks
        // for a touch (Secretive, 1Password) would hang every unattended fetch.
        let result = try await runner.run("/usr/bin/git", arguments, in: directory,
                                          environment: Dispatcher.gitOverHTTPS(ghPath: ghPath), timeout: .seconds(120))
        guard result.status == 0 else {
            throw DispatchError.worktree("git \(arguments[0]) exited \(result.status): \(result.stderr.prefix(300))")
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }
}

/// What a merged PR leaves behind.
extension Worktrees {
    /// Removes Bton's `.worktrees/bton-pr-<n>` and any worktree on the PR's branch, then that
    /// branch. Only a tree that is clean, unlocked and exactly at the merged head, with no process
    /// working in it (`busy`): anything else may be someone's work in progress. Returns the
    /// removed paths.
    static func removeMerged(_ pr: MergedPullRequest, clone: URL, busy: [String], ghPath: String,
                             runner: ProcessRunner) async -> [String] {
        guard !pr.headSha.isEmpty, let listing = try? await git(["worktree", "list", "--porcelain"], in: clone,
                                                                ghPath: ghPath, runner: runner) else { return [] }
        // git and lsof print `/private/var/…` where Foundation says `/var/…`: compare real paths.
        let root = realPath(clone.path)
        let own = root + "/.worktrees/bton-pr-\(pr.number)"
        let busy = busy.map(realPath)
        var removed: [String] = []
        // The first block is the main checkout, which is never removed.
        for block in listing.components(separatedBy: "\n\n").dropFirst() {
            let lines = block.split(separator: "\n").map(String.init)
            guard let path = lines.first(where: { $0.hasPrefix("worktree ") }).map({ String($0.dropFirst("worktree ".count)) })
            else { continue }
            let branch = lines.first(where: { $0.hasPrefix("branch refs/heads/") }).map { String($0.dropFirst("branch refs/heads/".count)) }
            guard realPath(path) == own || (!pr.headRef.isEmpty && branch == pr.headRef),
                  lines.contains("HEAD \(pr.headSha)"), !lines.contains(where: { $0.hasPrefix("locked") }),
                  !busy.contains(where: { $0 == realPath(path) || $0.hasPrefix(realPath(path) + "/") }),
                  (try? await cleanHead(URL(fileURLWithPath: path), ghPath: ghPath, runner: runner)) == pr.headSha,
                  (try? await git(["worktree", "remove", path], in: clone, ghPath: ghPath, runner: runner)) != nil
            else { continue }
            // In the clone's own spelling, as the caller knows it.
            let real = realPath(path)
            removed.append(real.hasPrefix(root + "/") ? clone.path + real.dropFirst(root.count) : path)
            // Only while the branch is still at the merged head: a commit made since stays.
            if let branch {
                _ = try? await git(["update-ref", "-d", "refs/heads/\(branch)", pr.headSha], in: clone, ghPath: ghPath, runner: runner)
            }
        }
        return removed
    }

    /// The path with every symlink resolved, or as given when it doesn't exist.
    private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Every process's working directory, nil when they can't be listed: then nothing is removed.
    static func workingDirectories(runner: ProcessRunner) async -> [String]? {
        guard let result = try? await runner.run("/usr/sbin/lsof", ["-d", "cwd", "-Fn"], timeout: .seconds(20)),
              // A warning means some process went unlisted, and its tree could look free.
              result.status == 0, result.stderr.isEmpty else { return nil }
        return String(decoding: result.stdout, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }
}
