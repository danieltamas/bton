import Foundation

/// Taking an issue: a fresh read of it under the lease, then the flow's claim and worktree commands.
extension Dispatcher {
    /// Whether the issue is still the one the sync saw. A failed read refuses too: a claim over
    /// someone's work is worse than waiting a tick.
    func intakeStanding(_ plan: IntakePlan, repo: String, me: String) async -> IssueIntake.Standing {
        do {
            return IssueIntake.standing(of: try await github.issueNow(repo: repo, number: plan.issue), plan: plan, me: me)
        } catch {
            return .refuse("could not read the issue: \(error.localizedDescription)")
        }
    }

    /// Claims the issue, then makes its worktree and returns it. The claim runs first and alone, so
    /// the issue leaves the search before anything else is made; a claim that fails stops the job
    /// before any worktree. A retry of a job that got that far claims nothing and reuses the tree.
    func prepareIssue(_ plan: IntakePlan, clone: URL, job: Job, environment: [String: String],
                      timeout: Duration) async throws -> URL {
        let tree = clone.appendingPathComponent(plan.worktreePath, isDirectory: true).standardizedFileURL
        guard tree.path.hasPrefix(clone.standardizedFileURL.path + "/") else {
            throw DispatchError.worktree("\(plan.worktreePath) is outside the clone")
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: tree.path, isDirectory: &isDirectory)
        // A folder already there is someone's work on this issue: refused before the claim, so the
        // issue stays free for them, and never made over.
        if exists, !plan.resumes { throw DispatchError.worktree("\(plan.worktreePath) already exists; nothing was claimed or made over it") }
        if !plan.resumes {
            for command in plan.claim {
                let status = try await runLogged(command, in: clone, job: job.id, environment: environment, timeout: Self.intakeStep)
                guard status == 0 else { throw DispatchError.worktree("claim `\(command.joined(separator: " "))` exited \(status)") }
            }
            jobs.note(job.id, "issue #\(plan.issue) claimed")
        }
        if exists {
            // A folder a failed worktree command left half-made is not a tree: the agent in it would
            // work on whatever git finds above it, the clone itself.
            guard isDirectory.boolValue, FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path) else {
                throw DispatchError.worktree("\(plan.worktreePath) exists but is not a worktree; remove it and retry")
            }
            jobs.note(job.id, "reusing \(plan.worktreePath)")
            return tree
        }
        let status = try await runLogged(plan.worktree, in: clone, job: job.id, environment: environment, timeout: timeout)
        guard status == 0 else { throw DispatchError.worktree("`\(plan.worktree.joined(separator: " "))` exited \(status)") }
        guard FileManager.default.fileExists(atPath: tree.appendingPathComponent(".git").path) else {
            throw DispatchError.worktree("`\(plan.worktree.joined(separator: " "))` made no worktree at \(plan.worktreePath)")
        }
        return tree
    }

    /// An intake job is done when its branch has a PR: that is the point where the repo's process
    /// hands the move to a reviewer. An agent that stopped without one (it hit a question, ran out
    /// of road, or forgot) exits 0 too, and a success would hide an issue claimed with nothing
    /// behind it. A draft counts as done and says so: it is the author's move still.
    func intakeOutcome(of job: Job) async -> (status: Job.Status, detail: String?) {
        guard let worktree = job.worktree.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else {
            return (.failed, "no worktree to find the branch in")
        }
        do {
            let shown = try await runner.run("/usr/bin/git", ["branch", "--show-current"], in: worktree, timeout: .seconds(30))
            let branch = (String(data: shown.stdout, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !branch.isEmpty else { return (.failed, "the agent left the worktree on no branch, so no PR can follow") }
            guard let pr = try await github.openPullRequest(repo: job.key.repo, branch: branch) else {
                // An agent that stopped on a decision that is not its own moved the issue out of progress, as the
                // process says to: that is a hand-back with a report, not a failure.
                if let number = Int(job.key.item.dropFirst("issue-".count)),
                   let now = try? await github.issueNow(repo: job.key.repo, number: number), now.state == "OPEN",
                   let stage = IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: now.labels), stage != "in-progress" {
                    return (.succeeded, "the agent handed the issue back at stage:\(stage) without a PR: its report says why")
                }
                return (.failed, "the agent finished without opening a PR for \(branch); its report says why")
            }
            return (.succeeded, pr.isDraft ? "PR #\(pr.number) is a draft: finishing it is still the author's move" : nil)
        } catch {
            return (.failed, "could not confirm the PR: \(error.localizedDescription)")
        }
    }

    /// An issue's job that died with Bton or its Mac is asked to run again at once: the issue is still mine,
    /// so the next sync resumes it in its worktree instead of leaving it for a Retry. A job that failed on
    /// its own is not: it needs a person to read why.
    func resumesAfterDeath(_ job: Job) -> Bool? {
        job.key.move == IssueIntake.move ? true : job.retry
    }

    /// A live lease this Mac wrote for a job its store no longer knows (the record was lost with a
    /// killed Bton) would block the issue until it expires: nothing renews it, so it is given back
    /// as never run. Returns whether it was freed.
    func freeOrphan(_ holder: LeaseRecord, item: LeaseItem, repo: String) async -> Bool {
        guard !holder.released, holder.holder.caseInsensitiveCompare(leases.holder) == .orderedSame,
              holder.host.caseInsensitiveCompare(leases.host) == .orderedSame,
              // A claim in flight has not saved its job yet: only a lease untouched for a minute is orphaned.
              holder.expires.timeIntervalSinceNow < leases.ttl.timeInterval - 60,
              !jobs.all().contains(where: { $0.id == holder.job }),
              let lease = try? await leases.current(item, in: repo, job: holder.job) else { return false }
        log("\(repo)#\(item): freed a lease held by job \(holder.job), which this Mac has no record of")
        return (try? await leases.release(lease, ran: false)) != nil
    }

    /// What `repo-sync check` says when another live agent holds the worktree, nil when none does or
    /// the tool is not installed. Asked before the agent starts: its own edit hooks would refuse every
    /// write there and the run would only spend its budget finding that out.
    func claimedByAnotherAgent(_ worktree: URL) async -> String? {
        guard let tool = Executables.resolve("repo-sync"),
              let checked = try? await runner.run(tool, ["check", "."], in: worktree, timeout: .seconds(30)),
              checked.status == 2 else { return nil }
        let text = (String(data: checked.stdout, encoding: .utf8) ?? "") + checked.stderr
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    static let intakeStep: Duration = .seconds(120)
    /// The most an issue's work runs, however steadily it changes its worktree.
    static let intakeCeiling: TimeInterval = 8 * 3_600

    /// What the worktree looks like now: the commit and the changed files. A different value than the
    /// last look means the agent is working; empty when git cannot say, which never counts as progress.
    func worktreeActivity(of job: Job) async -> String {
        guard let tree = job.worktree.map({ URL(fileURLWithPath: $0, isDirectory: true) }) else { return "" }
        var parts: [String] = []
        for arguments in [["rev-parse", "HEAD"], ["status", "--porcelain", "--untracked-files=all"], ["diff", "--shortstat", "HEAD"]] {
            guard let shown = try? await runner.run("/usr/bin/git", arguments, in: tree, timeout: .seconds(30)) else { return "" }
            parts.append(String(data: shown.stdout, encoding: .utf8) ?? "")
        }
        return parts.joined(separator: "|")
    }
}
