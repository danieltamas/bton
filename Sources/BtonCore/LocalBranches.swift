import Foundation

/// One of the owner's own branches in a clone against origin, after a sync.
public struct BranchStatus: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// Local commits origin does not have; nil without a local branch or origin's.
    public var ahead: Int?
    /// Origin commits the local branch still lacks.
    public var behind: Int?
    /// Origin commits this sync brought into the local branch.
    public var pulled = 0
    /// Why a branch that lacks origin's commits was left as it is.
    public var held: String?

    public init(name: String, ahead: Int? = nil, behind: Int? = nil, pulled: Int = 0, held: String? = nil) {
        self.name = name
        self.ahead = ahead
        self.behind = behind
        self.pulled = pulled
        self.held = held
    }
}

/// A clone's working and default branches (develop and main) against origin and each other.
public struct LocalBranchReport: Sendable, Equatable {
    public var branches: [BranchStatus] = []
    public var working = ""
    public var defaultBranch = ""
    /// Commits on origin's working branch that its default branch lacks (to release), and the
    /// reverse; nil when the two are one branch or either is missing.
    public var workingOnly: Int?
    public var defaultOnly: Int?
    /// Why origin could not be read; the counts are then from the last fetch.
    public var problem: String?
    public var at = Date.now

    public init() {}
}

/// Keeps the owner's own develop and main up to date, so a person or an agent starting from
/// them starts from what is merged. A branch only behind origin is fast-forwarded: in the
/// checkout that has it, by `merge --ff-only`, which git refuses when it would overwrite
/// uncommitted changes; elsewhere by a fast-forward-only update of the ref, which git refuses
/// for a branch checked out, rebased or bisected anywhere. A branch with commits of its own is
/// never touched, only reported.
public enum LocalBranches {
    static let timeout: Duration = .seconds(60)

    /// `fetchOnly` names branches brought up to date under `refs/remotes/origin` and not synced
    /// or reported: the flow's base and release branches, which the features page reads.
    public static func sync(clone: URL, working: String, defaultBranch: String, fetchOnly: [String] = [],
                            runner: ProcessRunner = ProcessRunner()) async -> LocalBranchReport {
        var report = LocalBranchReport()
        report.working = working
        report.defaultBranch = defaultBranch
        var names: [String] = []
        for name in [working, defaultBranch] where isPlain(name) && !names.contains(name) { names.append(name) }
        var fetched = names
        for name in fetchOnly where isPlain(name) && !fetched.contains(name) { fetched.append(name) }
        guard !names.isEmpty else {
            report.problem = "no branch to sync"
            return report
        }
        let git = { (arguments: [String], directory: URL) async -> (ok: Bool, out: String, err: String) in
            guard let result = try? await runner.run("/usr/bin/git", arguments, in: directory,
                                                     environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: timeout) else {
                return (false, "", "git did not run")
            }
            return (result.status == 0, String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                    result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let fetch = await git(["fetch", "--quiet", "--no-tags", "origin"] + fetched.map { "+refs/heads/\($0):refs/remotes/origin/\($0)" }, clone)
        if !fetch.ok { report.problem = "fetching origin failed: " + firstLine(fetch.err) }
        let checkouts = checkedOut(await git(["worktree", "list", "--porcelain"], clone).out)
        let counts = { (left: String, right: String) async -> (Int, Int)? in
            let result = await git(["rev-list", "--left-right", "--count", "\(left)...\(right)"], clone)
            let parts = result.out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            return result.ok && parts.count == 2 ? (parts[0], parts[1]) : nil
        }
        for name in names {
            let local = "refs/heads/\(name)", remote = "refs/remotes/origin/\(name)"
            var status = BranchStatus(name: name)
            guard await git(["rev-parse", "--verify", "--quiet", remote], clone).ok else {
                status.held = "origin has no \(name)"
                report.branches.append(status)
                continue
            }
            guard await git(["rev-parse", "--verify", "--quiet", local], clone).ok, let (ahead, behind) = await counts(local, remote) else {
                status.held = "no local \(name)"
                report.branches.append(status)
                continue
            }
            status.ahead = ahead
            status.behind = behind
            if behind > 0 && ahead > 0 {
                status.held = "diverged: \(ahead) local commits origin lacks"
            } else if behind > 0 {
                let before = await git(["rev-parse", "--verify", "--quiet", local], clone).out
                let pull: (ok: Bool, out: String, err: String)
                if let path = checkouts[local] {
                    let checkout = URL(fileURLWithPath: path)
                    // The folder may have switched branch, or started a rebase or bisect, since the listing.
                    if await git(["symbolic-ref", "--quiet", "HEAD"], checkout).out == local {
                        pull = await git(["merge", "--ff-only", "--no-overwrite-ignore", "--quiet", remote], checkout)
                    } else {
                        pull = (false, "", "its folder no longer has \(name) checked out")
                    }
                } else {
                    pull = await git(["fetch", "--quiet", ".", "\(remote):\(local)"], clone)
                }
                if !pull.ok { status.held = "not pulled: " + firstLine(pull.err) }
                // Counted again: Bton's own fetches may move origin's ref while this one pulls.
                if let (ahead, behind) = await counts(local, remote) {
                    status.ahead = ahead
                    status.behind = behind
                }
                let after = await git(["rev-parse", "--verify", "--quiet", local], clone).out
                if pull.ok, let pulled = Int(await git(["rev-list", "--count", "\(before)..\(after)"], clone).out) {
                    status.pulled = pulled
                }
            }
            report.branches.append(status)
        }
        if names.count == 2, let (defaultOnly, workingOnly) = await counts("refs/remotes/origin/\(defaultBranch)", "refs/remotes/origin/\(working)") {
            report.defaultOnly = defaultOnly
            report.workingOnly = workingOnly
        }
        report.at = .now
        return report
    }

    /// A branch name Bton may put in a refspec: no leading dash, no refspec or glob characters.
    static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("-") && !name.hasPrefix("/") && !name.contains("..")
            && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
    }

    /// `refs/heads/<branch>` to the worktree that has it checked out, from `worktree list --porcelain`.
    static func checkedOut(_ porcelain: String) -> [String: String] {
        var result: [String: String] = [:], path: String?
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line.hasPrefix("branch "), let path { result[String(line.dropFirst("branch ".count))] = path }
            if line.isEmpty { path = nil }
        }
        return result
    }

    private static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.isEmpty ? "git gave no reason" : String(line.prefix(200))
    }
}
