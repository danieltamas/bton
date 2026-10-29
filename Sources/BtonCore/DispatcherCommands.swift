import Foundation
import os

/// A flow's checks and a merge command: run with their output in the job's log, and the PR
/// re-read that guards the command.
extension Dispatcher {
    /// Why the checks failed, or nil when every one passed, now or in an earlier run on the same
    /// code: a team's suite can take 20 minutes, and review, fix and merge on one head, or a
    /// merge that failed after it passed, must not pay them again. The code is the tree of the
    /// commit the worktree is at (the base is not merged in), over the base tip a check may read,
    /// with the environment and the kind of start; each check that passes is a receipt of its
    /// own, so a later one failing keeps the earlier ones. A check in
    /// `fresh` always runs. Each gets the move's own time limit: a team's suite can take longer
    /// than any fixed limit, and the flow's `timeoutMinutes` is where the team says how long a
    /// move may take.
    func runChecks(_ checks: [[String]], fresh: [[String]] = [], together: [[[String]]] = [], job: inout Job, in worktree: URL,
                   clone: URL, base: String, environment: [String: String], timeout: Duration) async throws -> String? {
        let tip = try await Worktrees.tip(of: base, clone: clone, ghPath: github.ghPath, runner: runner)
        let tree = await Worktrees.tree(of: worktree, ghPath: github.ghPath, runner: runner)
        let pressed = environment["BTON_PRESSED"] == "1"
        let fingerprint = PassedChecks.fingerprint(environment.filter { $0.key != "BTON_PRESSED" })
        let others = jobs.all().filter { $0.id != job.id && $0.key.repo == job.key.repo && $0.checked?.pressed == pressed }
        func receipt(covering check: [String]) -> Job? {
            guard !fresh.contains(check) else { return nil }
            return others.first { other in
                guard let checked = other.checked, checked.checks.contains(check) else { return false }
                if let tree, checked.tree == tree { return checked.base == tip && checked.environment == fingerprint }
                // A receipt from before trees: the same job over the same base tip, as it was.
                return checked.tree == nil && other.key == job.key && checked.base == tip && checked.checks == checks
            }
        }
        var passed: [[String]] = []
        var index = 0
        while index < checks.count {
            let check = checks[index]
            // Consecutive checks of one declared group, none with a receipt, start together.
            var run = [check]
            if receipt(covering: check) == nil, let group = together.first(where: { $0.contains(check) }) {
                while index + run.count < checks.count, group.contains(checks[index + run.count]),
                      receipt(covering: checks[index + run.count]) == nil {
                    run.append(checks[index + run.count])
                }
            }
            index += run.count
            var failure: String?
            if run.count > 1 {
                jobs.note(job.id, "ran together: \(run.count) checks")
                let (statuses, thrown) = await runTogether(run, in: worktree, job: job.id, environment: environment, timeout: timeout)
                passed += zip(run, statuses).filter { $0.1 == 0 }.map(\.0)
                if let thrown {
                    // The checks that passed before the error keep their receipts.
                    job.checked = PassedChecks(base: tip, checks: passed, pressed: pressed, tree: tree, environment: fingerprint)
                    try? jobs.save(job)
                    throw thrown
                }
                failure = zip(run, statuses).first { $0.1 > 0 }.map { "`\($0.0.joined(separator: " "))` exited \($0.1)" }
            } else if let earlier = receipt(covering: check) {
                let on = "\(tree.map { "tree \($0.prefix(7))" } ?? job.key.head.prefix(7).description) over \(base) \(tip.prefix(7))"
                jobs.note(job.id, "check `\(check.joined(separator: " "))` passed on \(on) in job \(earlier.id.uuidString); not run again")
                passed.append(check)
            } else {
                let status = try await runLogged(check, in: worktree, job: job.id, environment: environment, timeout: timeout)
                if status == 0 { passed.append(check) } else { failure = "`\(check.joined(separator: " "))` exited \(status)" }
            }
            job.checked = PassedChecks(base: tip, checks: passed, pressed: pressed, tree: tree, environment: fingerprint)
            // Unsaved, the next run only checks again.
            try? jobs.save(job)
            if let failure { return failure }
        }
        return nil
    }

    /// Declared-independent checks at the same time, each with its own time limit and its output
    /// as one block in the log. The first ending that is not a pass (a non-zero exit, a time limit,
    /// an error) ends the others: their process groups are killed, as a cancelled run's are, and
    /// what they report after that is noise. A terminated sibling keeps -1, never a pass. The
    /// statuses come back beside the error, so the checks that passed keep their receipts.
    private func runTogether(_ run: [[String]], in worktree: URL, job id: UUID, environment: [String: String],
                             timeout: Duration) async -> (statuses: [Int32], thrown: Error?) {
        await withTaskGroup(of: (Int, Result<Int32, Error>).self) { group in
            for (offset, argv) in run.enumerated() {
                group.addTask {
                    do {
                        return (offset, .success(try await self.runLogged(argv, in: worktree, job: id, environment: environment,
                                                                          timeout: timeout, buffered: true)))
                    } catch { return (offset, .failure(error)) }
                }
            }
            var statuses = [Int32](repeating: -1, count: run.count)
            var thrown: Error?
            var ended = false
            for await (offset, result) in group {
                switch result {
                case .success(let status):
                    statuses[offset] = status
                    if status != 0, !ended { ended = true; group.cancelAll() }
                case .failure(let error):
                    if !ended { ended = true; thrown = error; group.cancelAll() }
                }
            }
            return (statuses, thrown)
        }
    }

    /// Why the command must not run, or nil when the PR on GitHub is still open at the head the
    /// move was started for. Read after the checks, which can take minutes: a commit pushed after
    /// the review, or while they ran, is never merged unreviewed. A failed read refuses too; a Stop
    /// during it is thrown, so the job ends stopped.
    func headRefusal(repo: String, pr number: Int, expected: String, job id: UUID) async throws -> String? {
        let now: (head: String, state: String)
        do {
            now = try await github.pullRequestHeadAndState(repo: repo, number: number)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "could not read the PR before merging; nothing was merged"
        }
        guard now.state == "OPEN" else { return "PR is not open (\(now.state.lowercased())); nothing was merged" }
        guard now.head == expected else {
            return "head moved from \(expected.prefix(7)) to \(now.head.prefix(7)) since the move started; nothing was merged"
        }
        jobs.note(id, "head \(expected.prefix(7)) verified on GitHub before the command")
        return nil
    }

    /// Why the command must not run, or nil when every check the move's rule named is green on
    /// GitHub for `head` now. The tick's snapshot is minutes old by the time the checks above
    /// have run; a re-run that failed since, or a check that was still pending, must not merge.
    /// A failed read refuses too; a Stop during it is thrown.
    func checksRefusal(_ required: [String], pr: PullRequest, head: String, job id: UUID) async throws -> String? {
        guard !required.isEmpty else { return nil }
        let repo = pr.repo
        // The same guard as the predicate's, for the owner's Merge press too: a PR that edits a
        // workflow ran its own check, and a file list cut short may hide such an edit.
        if pr.changedFilesTruncated { return "checks not trusted: the PR changes more files than were read; nothing was run" }
        if let workflow = pr.changedFiles.first(where: { $0.hasPrefix(".github/workflows/") }) {
            return "checks not trusted: the PR edits \(workflow), which ran them; nothing was run"
        }
        let now: (checks: [CheckResult], truncated: Bool)
        do {
            now = try await github.checks(repo: repo, sha: head)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return "could not read checks on \(head.prefix(7)) before the command; nothing was run"
        }
        let states = Dictionary(now.checks.map { ($0.name, $0.state) }) { first, _ in first }
        var notGreen = required.compactMap { name -> String? in
            switch states[name] {
            case .success: nil
            case let .some(state): "\(name) \(state.rawValue)"
            case nil: "\(name) missing"
            }
        }
        if now.truncated { notGreen.append("more checks than were read") }
        guard notGreen.isEmpty else { return "checks not green: \(notGreen.joined(separator: ", ")); nothing was run" }
        jobs.note(id, "checks \(required.joined(separator: ", ")) green on \(head.prefix(7)) before the command")
        return nil
    }

    func runLogged(_ argv: [String], in directory: URL, job id: UUID, environment: [String: String],
                   timeout: Duration, buffered: Bool = false) async throws -> Int32 {
        guard let first = argv.first, let executable = Executables.resolve(first) else {
            throw DispatchError.agentNotFound(argv.first ?? "")
        }
        // The command is logged as it starts and its output as it comes, so a log that stops shows
        // what is still running and how far it got, even when it is stopped at its time limit. A
        // check running beside others is written as one block when it ends, so lines never mix.
        let handle = try FileHandle.appending(to: jobs.logURL(id))
        defer { try? handle.close() }
        let header = Data("$ \(argv.joined(separator: " "))\n".utf8)
        let buffer = OSAllocatedUnfairLock<Data>(initialState: Data())
        defer { if buffered { handle.write(header + buffer.withLock { $0 }) } }
        if !buffered { handle.write(header) }
        let write: @Sendable (Data) -> Void
        if buffered { write = { data in buffer.withLock { $0.append(data) } } } else { write = { handle.write($0) } }
        let group = OSAllocatedUnfairLock<Int32?>(initialState: nil)
        defer { group.withLock { $0 }.map { try? FileManager.default.removeItem(at: jobs.checkGroupURL(id, group: $0)) } }
        do {
            return try await runner.run(executable, Array(argv.dropFirst()), in: directory,
                                        environment: DispatchPlanner.processEnvironment(repo: environment, bton: ["PATH": Executables.searchPath(for: executable)]),
                                        timeout: timeout,
                                        started: { [jobs] pid in
                                            group.withLock { $0 = pid }
                                            FileManager.default.createFile(atPath: jobs.checkGroupURL(id, group: pid).path, contents: nil)
                                        },
                                        output: write).status
        } catch ProcessRunner.Failure.timedOut {
            throw DispatchError.timedOut(argv.joined(separator: " "), minutes: Int(timeout.components.seconds / 60))
        }
    }
}
