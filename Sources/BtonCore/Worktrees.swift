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
                                  at: pr.headSha, base: "refs/remotes/origin/\(base)", clone: clone, ghPath: ghPath,
                                  runner: runner, note: note)
    }

    /// A schedule's tree, `.worktrees/bton-<item>`, detached at the default branch's tip as just
    /// fetched, so each run starts from what the team has merged.
    static func prepare(clone: URL, branch: String, item: String, ghPath: String, runner: ProcessRunner,
                        fresh: Bool = false, note: @Sendable (String) -> Void = { _ in }) async throws -> URL {
        try await git(["fetch", "--quiet", "origin", "+refs/heads/\(branch):refs/remotes/origin/\(branch)"],
                      in: clone, ghPath: ghPath, runner: runner)
        let tip = try await tip(of: branch, clone: clone, ghPath: ghPath, runner: runner)
        return try await detached(clone.appendingPathComponent(".worktrees/bton-\(item)", isDirectory: true),
                                  at: tip, base: nil, clone: clone, ghPath: ghPath, runner: runner, fresh: fresh, note: note)
    }

    /// What `origin/<branch>` names in the clone, as last fetched.
    static func tip(of branch: String, clone: URL, ghPath: String, runner: ProcessRunner) async throws -> String {
        try await git(["rev-parse", "refs/remotes/origin/\(branch)"], in: clone, ghPath: ghPath, runner: runner)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bton's own tree at `sha`. An earlier job's leftover changes go to the clone's `git stash`,
    /// named after the tree, for a person to look at; refusing instead stopped the tree's every
    /// later job (a build step that rewrites a tracked file leaves such changes on each run).
    /// `fresh` replaces the tree outright, ignored files included. `base` is what a PR merges
    /// into, nil for a schedule's tree.
    private static func detached(_ path: URL, at sha: String, base: String?, clone: URL, ghPath: String, runner: ProcessRunner,
                                 fresh: Bool = false, note: @Sendable (String) -> Void) async throws -> URL {
        if FileManager.default.fileExists(atPath: path.path) || (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) != nil {
            // A trusted base tree holds nothing to keep, so an orphan in its place goes; a
            // schedule's folder could hold someone's files and is refused below.
            if fresh, path.lastPathComponent.hasPrefix("bton-base-"),
               try await isOrphan(path, clone: clone, ghPath: ghPath, runner: runner) {
                try FileManager.default.removeItem(at: path)
                note("removed \(path.lastPathComponent): git no longer listed it as a worktree")
                return try await detached(path, at: sha, base: base, clone: clone, ghPath: ghPath, runner: runner, note: note)
            }
            // A PR's check could plant a link here to someone's checkout: nothing is stashed or
            // switched until the path is Bton's own worktree of this clone.
            guard try await isOwnWorktree(path, clone: clone, ghPath: ghPath, runner: runner) else {
                throw DispatchError.worktree("\(path.path) is not a worktree Bton made in this clone; left as it is")
            }
            if fresh {
                try await git(["worktree", "remove", "--force", path.path], in: clone, ghPath: ghPath, runner: runner)
                return try await detached(path, at: sha, base: base, clone: clone, ghPath: ghPath, runner: runner, note: note)
            }
            if try await cleanHead(path, ghPath: ghPath, runner: runner) == nil {
                let message = "bton: leftovers in \(path.lastPathComponent) before \(Date.now.formatted(.iso8601))"
                try await git(["stash", "push", "--include-untracked", "--message", message], in: path, ghPath: ghPath, runner: runner)
                let stash = (try? await git(["rev-parse", "--verify", "refs/stash"], in: path, ghPath: ghPath, runner: runner))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
                note("saved an earlier job's changes in \(path.lastPathComponent) to git stash \(stash): \(message)")
                // The old head only needs a clean tree to move off; what may stay out is decided
                // at the head the job runs on.
                try await leaveOutVanished(path, base: nil, ghPath: ghPath, runner: runner, note: note)
                let left = try await git(["status", "--porcelain"], in: path, ghPath: ghPath, runner: runner)
                guard left.isEmpty else {
                    // A stash leaves a dirty submodule behind.
                    let paths = left.split(separator: "\n").prefix(3).map { $0.dropFirst(3) }.joined(separator: ", ")
                    throw DispatchError.worktree("\(path.path) still has changes after stashing them: \(paths)")
                }
            }
            try await git(["checkout", "--quiet", "--detach", sha], in: path, ghPath: ghPath, runner: runner)
        } else {
            try await git(["worktree", "add", "--quiet", "--detach", path.path, sha], in: clone,
                          ghPath: ghPath, runner: runner)
        }
        try await leaveOutVanished(path, base: base, ghPath: ghPath, runner: runner, note: note)
        return path
    }

    /// Right after git wrote the tree, a tracked file that is already gone was removed by
    /// something outside git, such as an antivirus that quarantines it each time. Sparse checkout
    /// leaves it out of this tree, so the tree is clean and no commit deletes it; the clone's
    /// other checkouts are untouched. A file the PR or its base changed since they parted is never
    /// left out, since a review, a check or a merge must see it: that stops the job, as does a name
    /// a pattern can't hold.
    private static func leaveOutVanished(_ path: URL, base: String?, ghPath: String, runner: ProcessRunner,
                                         note: @Sendable (String) -> Void) async throws {
        func paths(_ output: String, tagged tag: String) -> [String] {
            output.split(separator: "\0").filter { $0.hasPrefix(tag) }.map { String($0.dropFirst(tag.count)) }
        }
        let vanished = paths(try await git(["status", "--porcelain", "-z"], in: path, ghPath: ghPath, runner: runner),
                             tagged: " D ")
        let leftOut = paths(try await git(["ls-files", "-z", "-t"], in: path, ghPath: ghPath, runner: runner), tagged: "S ")
        guard !vanished.isEmpty || !leftOut.isEmpty else { return }
        // Either side, so the agent's merge of the base never conflicts on a file it can't see.
        var changed: Set<String> = []
        if let base {
            for range in ["\(base)...HEAD", "HEAD...\(base)"] {
                changed.formUnion(paths(try await git(["diff", "--name-only", "--no-renames", "-z", range],
                                                      in: path, ghPath: ghPath, runner: runner), tagged: ""))
            }
        }
        let wanted = Set(leftOut + vanished).filter { !changed.contains($0) && !$0.contains(where: \.isNewline) }
        if wanted != Set(leftOut) {
            let arguments = wanted.isEmpty ? ["sparse-checkout", "disable"]
                : ["sparse-checkout", "set", "--no-cone", "--", "/*"] + wanted.sorted().map { "!/" + sparseEscaped($0) }
            try await git(arguments, in: path, ghPath: ghPath, runner: runner)
        }
        // A file brought back in may vanish again as git writes it.
        let kept = paths(try await git(["status", "--porcelain", "-z"], in: path, ghPath: ghPath, runner: runner),
                         tagged: " D ").filter { !wanted.contains($0) }
        guard kept.isEmpty else {
            throw DispatchError.worktree("something outside git (an antivirus?) deletes \(kept.prefix(3).joined(separator: ", ")) in \(path.lastPathComponent) as soon as git writes it, and it cannot be left out: the PR or its base changed it, so a review, check or merge must see it, or its name holds a line break")
        }
        let added = wanted.subtracting(leftOut)
        if !added.isEmpty {
            note("left out of \(path.lastPathComponent), since something outside git deletes them as soon as git writes them (an antivirus?): \(added.sorted().joined(separator: ", "))")
        }
    }

    /// A path as a literal sparse-checkout pattern: gitignore syntax gives `\`, `*`, `?` and `[`
    /// meaning, and trailing spaces are dropped unless escaped.
    private static func sparseEscaped(_ path: String) -> String {
        var escaped = ""
        for character in path {
            if "\\*?[".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        if escaped.hasSuffix(" ") { escaped = String(escaped.dropLast()) + "\\ " }
        return escaped
    }

    /// The path is `.worktrees/<name>` of the clone itself, no link on the way, and git lists it
    /// as one of the clone's worktrees.
    private static func isOwnWorktree(_ path: URL, clone: URL, ghPath: String, runner: ProcessRunner) async throws -> Bool {
        let expected = realPath(clone.path) + "/.worktrees/" + path.lastPathComponent
        guard realPath(path.path) == expected, try await isListed(expected, clone: clone, ghPath: ghPath, runner: runner)
        else { return false }
        // A tree whose `.git` file is gone would have git fall through to the main checkout.
        let top = try? await git(["rev-parse", "--show-toplevel"], in: path, ghPath: ghPath, runner: runner)
        return top.map { realPath($0.trimmingCharacters(in: .whitespacesAndNewlines)) } == expected
    }

    /// A real folder at `.worktrees/<name>` of the clone, no link on the way, that git no longer
    /// lists as a worktree: a command's own cleanup pruned it, and nothing else would remove it.
    private static func isOrphan(_ path: URL, clone: URL, ghPath: String, runner: ProcessRunner) async throws -> Bool {
        var isFolder: ObjCBool = false
        let expected = realPath(clone.path) + "/.worktrees/" + path.lastPathComponent
        guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isFolder), isFolder.boolValue,
              (try? FileManager.default.destinationOfSymbolicLink(atPath: path.path)) == nil,
              realPath(path.path) == expected else { return false }
        return try await !isListed(expected, clone: clone, ghPath: ghPath, runner: runner)
    }

    /// `git worktree list` names the real path `expected`.
    private static func isListed(_ expected: String, clone: URL, ghPath: String, runner: ProcessRunner) async throws -> Bool {
        let listing = try await git(["worktree", "list", "--porcelain"], in: clone, ghPath: ghPath, runner: runner)
        return listing.split(separator: "\n").contains { line in
            line.hasPrefix("worktree ") && realPath(String(line.dropFirst("worktree ".count))) == expected
        }
    }

    /// Removes Bton's own tree when nothing in it changed, or when it is an orphan; false when it stays.
    static func removeClean(_ path: URL, clone: URL, ghPath: String, runner: ProcessRunner) async -> Bool {
        if (try? await isOrphan(path, clone: clone, ghPath: ghPath, runner: runner)) == true {
            return (try? FileManager.default.removeItem(at: path)) != nil
        }
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

    static let permissionRetries = 2
    /// Past Avast's 14-second wait for its cloud's answer.
    static let permissionRetryWait: Duration = .seconds(20)

    @discardableResult
    private static func git(_ arguments: [String], in directory: URL, ghPath: String, runner: ProcessRunner) async throws -> String {
        // GitHub over HTTPS with gh's token, like the agents: an SSH key behind an agent that asks
        // for a touch (Secretive, 1Password) would hang every unattended fetch.
        var result = try await runner.run("/usr/bin/git", arguments, in: directory,
                                          environment: Dispatcher.gitOverHTTPS(ghPath: ghPath), timeout: .seconds(120))
        // An antivirus that asks its cloud before letting a program change a file denies the change
        // when the answer is late, and allows the same one a moment later.
        for _ in 0..<permissionRetries where result.status != 0 && result.stderr.contains("Operation not permitted") {
            try await Task.sleep(for: permissionRetryWait)
            result = try await runner.run("/usr/bin/git", arguments, in: directory,
                                          environment: Dispatcher.gitOverHTTPS(ghPath: ghPath), timeout: .seconds(120))
        }
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
