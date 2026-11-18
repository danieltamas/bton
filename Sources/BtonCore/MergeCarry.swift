import Foundation

/// Which commits under a head that merges the base in a review still counts for.
///
/// A review names one commit. It also counts for a merge commit above that commit only when the
/// merge commit is what this Mac's git makes by merging the base into it: two parents, the tree
/// `git merge-tree` writes for them, and a second parent that is in the PR's base. Whoever made
/// such a commit chose no line of it, only which commit of the base to merge in. Anything else (a
/// conflict resolved by hand, an edited merge, another branch merged in, a check that could not
/// be made) carries nothing, and the flow asks for a review of the new head.
///
/// GitHub's list of the head's parents only says there is a merge to look at: the parents and the
/// tree are read from the clone's own objects. A commit the clone lacks is fetched by its id,
/// which writes objects and nothing else: no ref, no `FETCH_HEAD`, no working tree, no index.
actor MergeCarry {
    struct Verdict: Sendable, Equatable {
        /// The commits whose review also counts for the head, nearest first.
        var carried: [String] = []
        /// Why the walk stopped at a merge commit; nil when it ended at an ordinary one.
        var refusal: String?
    }

    /// What a commit's own object and `git merge-tree` say about it, which never changes for an id.
    private enum Shape: Sendable {
        /// Fewer than two parents: the walk ends here.
        case ordinary
        /// Two parents, and the tree is git's own merge of them.
        case clean(first: String, second: String)
        /// A merge commit no review is carried over, with what the log says after its short id.
        case refused(String)
    }

    /// The check could not be made. Never remembered, so the next read tries again.
    private struct Unchecked: Error { let reason: String }

    /// Git in the clone for one read: every call ends by the read's deadline.
    private struct Git: Sendable {
        let clone: URL
        let environment: [String: String]
        let deadline: ContinuousClock.Instant
        let runner: ProcessRunner

        /// A non-zero exit is the caller's to read.
        func run(_ arguments: [String], limit: Duration = .seconds(30), input: Data? = nil) async throws(Unchecked) -> ProcessOutput {
            let left = deadline - ContinuousClock.now
            guard left > .zero else { throw Unchecked(reason: "no time left in this read") }
            do {
                return try await runner.run("/usr/bin/git", ["-C", clone.path] + arguments, environment: environment,
                                            timeout: min(limit, left), input: input)
            } catch ProcessRunner.Failure.timedOut {
                throw Unchecked(reason: "git \(arguments[0]) did not finish in time")
            } catch {
                throw Unchecked(reason: "git \(arguments[0]) could not run")
            }
        }
    }

    /// A row of "Update branch" merges longer than this is not walked to its end.
    static let maxSteps = 10
    /// One read's whole check, fetch included: a sync never waits longer than this for it.
    private static let budget: Duration = .seconds(60)
    private static let memoLimit = 2000

    private let runner = ProcessRunner()
    private var shapes: [String: Shape] = [:]
    private var ancestries: [String: Bool] = [:]

    /// One verdict per PR, in the PRs' order. A PR whose head GitHub does not list as a merge
    /// commit is not looked at: nothing is carried for it and no git runs.
    func verdicts(for pullRequests: [PullRequest], clone: URL?, ghPath: String) async -> [Verdict] {
        var verdicts = [Verdict](repeating: Verdict(), count: pullRequests.count)
        let merges = pullRequests.indices.filter { !pullRequests[$0].mergeOnlyAncestors.isEmpty }
        guard !merges.isEmpty else { return verdicts }
        // Replace refs are switched off: one could make a commit read as another.
        let git = clone.map { clone in
            Git(clone: clone, environment: Dispatcher.gitOverHTTPS(ghPath: ghPath).merging(["GIT_NO_REPLACE_OBJECTS": "1"]) { $1 },
                deadline: ContinuousClock.now + Self.budget, runner: runner)
        }
        if let git {
            await fetchMissing(merges.flatMap { [pullRequests[$0].headSha, pullRequests[$0].baseSha].compactMap { $0 } }, git: git)
        }
        for index in merges {
            verdicts[index] = await verdict(for: pullRequests[index], git: git)
        }
        return verdicts
    }

    private func verdict(for pr: PullRequest, git: Git?) async -> Verdict {
        var verdict = Verdict()
        var commit = pr.headSha
        do throws(Unchecked) {
            guard let git else { throw Unchecked(reason: "no clone of the repo on this Mac") }
            guard let base = pr.baseSha else { throw Unchecked(reason: "GitHub did not name the tip of \(pr.baseRef)") }
            guard Self.isCommitID(base) else { throw Unchecked(reason: "the tip of \(pr.baseRef) is not a commit id") }
            while true {
                let found = try await shape(of: commit, git: git)
                if case .ordinary = found { break }
                guard verdict.carried.count < Self.maxSteps else {
                    throw Unchecked(reason: "more than \(Self.maxSteps) merge commits in a row")
                }
                guard case let .clean(first, second) = found else {
                    if case let .refused(why) = found { verdict.refusal = "\(Self.short(commit)) \(why)" }
                    break
                }
                // Against this read's base tip, every read: a PR can be retargeted and a base rewound.
                guard try await isAncestor(second, of: base, git: git) else {
                    verdict.refusal = "\(Self.short(commit)) merges \(Self.short(second)), which is not in \(pr.baseRef)"
                    break
                }
                verdict.carried.append(first)
                commit = first
            }
        } catch {
            verdict.refusal = "could not check \(Self.short(commit)): \(error.reason)"
        }
        return verdict
    }

    private func shape(of commit: String, git: Git) async throws(Unchecked) -> Shape {
        let key = "\(git.clone.path) \(commit)"
        if let known = shapes[key] { return known }
        let read = try await Self.readShape(of: commit, git: git)
        if shapes.count >= Self.memoLimit { shapes.removeAll() }
        shapes[key] = read
        return read
    }

    private static func readShape(of commit: String, git: Git) async throws(Unchecked) -> Shape {
        guard isCommitID(commit) else { throw Unchecked(reason: "it is not a commit id") }
        let object = try await git.run(["cat-file", "commit", commit])
        guard object.status == 0 else { throw Unchecked(reason: "it is not in the clone and could not be fetched") }
        // As git reads a commit: the tree, then its parents, before anything else. A line further
        // down, or in the message, that reads like a parent is not one.
        let header = String(decoding: object.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = header.first, first.hasPrefix("tree ") else { throw Unchecked(reason: "its object does not read as a commit") }
        let tree = String(first.dropFirst("tree ".count))
        let parents = header.dropFirst().prefix { $0.hasPrefix("parent ") }.map { String($0.dropFirst("parent ".count)) }
        guard ([tree] + parents).allSatisfy(isCommitID) else { throw Unchecked(reason: "its object does not read as a commit") }
        guard parents.count > 1 else { return .ordinary }
        guard parents.count == 2 else { return .refused("has \(parents.count) parents") }
        let merged = try await git.run(["merge-tree", "--write-tree", parents[0], parents[1]])
        let written = String(decoding: merged.stdout, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        // A conflict is exit 1 with the tree git wrote for it. Exit 1 with no tree is an object
        // git could not read, and any other exit (unrelated histories) is no verdict either.
        switch (merged.status, isCommitID(written)) {
        case (0, true): return written == tree ? .clean(first: parents[0], second: parents[1]) : .refused("is not git's own merge of its parents")
        case (1, true): return .refused("resolves a conflict by hand")
        default: throw Unchecked(reason: "git merge-tree exited with \(merged.status)")
        }
    }

    private func isAncestor(_ commit: String, of base: String, git: Git) async throws(Unchecked) -> Bool {
        if commit == base { return true }
        let key = "\(git.clone.path) \(commit) \(base)"
        if let known = ancestries[key] { return known }
        let answer = try await git.run(["merge-base", "--is-ancestor", commit, base])
        guard answer.status == 0 || answer.status == 1 else { throw Unchecked(reason: "git merge-base exited with \(answer.status)") }
        if ancestries.count >= Self.memoLimit { ancestries.removeAll() }
        ancestries[key] = answer.status == 0
        return answer.status == 0
    }

    /// Brings the commits the clone lacks from `origin`, by id. A failure is not reported here:
    /// the walk says which commit it could not read.
    private func fetchMissing(_ commits: [String], git: Git) async {
        let wanted = Set(commits.filter(Self.isCommitID)).sorted()
        guard !wanted.isEmpty,
              let listed = try? await git.run(["cat-file", "--batch-check"], input: Data((wanted.joined(separator: "\n") + "\n").utf8)),
              listed.status == 0 else { return }
        let missing = String(decoding: listed.stdout, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasSuffix(" missing") }.map { String($0.dropLast(" missing".count)) }.filter(Self.isCommitID)
        guard !missing.isEmpty else { return }
        let fetch = ["fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-auto-maintenance", "--no-recurse-submodules", "origin"]
        guard let together = try? await git.run(fetch + missing, limit: .seconds(60)), together.status != 0, missing.count > 1 else { return }
        // One commit origin does not have fails the whole request: each is asked for alone, so
        // only the PR that needs that commit goes unchecked.
        for commit in missing { _ = try? await git.run(fetch + [commit], limit: .seconds(60)) }
    }

    /// 40 lower-case hex digits and nothing else: what reaches git as an argument is never an option.
    static func isCommitID(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0) }
    }

    static func short(_ commit: String) -> String { String(commit.prefix(7)) }
}
