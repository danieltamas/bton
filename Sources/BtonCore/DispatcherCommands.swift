import Foundation
import os

/// A flow's checks and a merge command: run with their output in the job's log, and the PR
/// re-read that guards the command.
extension Dispatcher {
    /// Why the checks failed, or nil when every one passed, now or in an earlier run of the key
    /// over the same base tip: a team's suite can take 20 minutes, and a merge that failed after
    /// it passed must not pay them again. Each gets the move's own time limit: a team's suite can take
    /// longer than any fixed limit, and the flow's `timeoutMinutes` is where the team says how long
    /// a move may take.
    func runChecks(_ checks: [[String]], job: inout Job, in worktree: URL, clone: URL, base: String,
                   environment: [String: String], timeout: Duration) async throws -> String? {
        let tip = try await Worktrees.tip(of: base, clone: clone, ghPath: github.ghPath, runner: runner)
        let passed = PassedChecks(base: tip, checks: checks, pressed: environment["BTON_PRESSED"] == "1")
        if let earlier = jobs.all().first(where: { $0.id != job.id && $0.key == job.key && $0.checked == passed }) {
            jobs.note(job.id, "checks passed on \(job.key.head.prefix(7)) over \(base) \(tip.prefix(7)) in job \(earlier.id.uuidString); not run again")
        } else {
            for check in checks {
                let status = try await runLogged(check, in: worktree, job: job.id, environment: environment, timeout: timeout)
                guard status == 0 else { return "`\(check.joined(separator: " "))` exited \(status)" }
            }
        }
        job.checked = passed
        // Unsaved, the next run only checks again.
        try? jobs.save(job)
        return nil
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

    func runLogged(_ argv: [String], in directory: URL, job id: UUID, environment: [String: String],
                   timeout: Duration) async throws -> Int32 {
        guard let first = argv.first, let executable = Executables.resolve(first) else {
            throw DispatchError.agentNotFound(argv.first ?? "")
        }
        // The command is logged as it starts and its output as it comes, so a log that stops shows
        // what is still running and how far it got, even when it is stopped at its time limit.
        let handle = try FileHandle.appending(to: jobs.logURL(id))
        defer { try? handle.close() }
        handle.write(Data("$ \(argv.joined(separator: " "))\n".utf8))
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
                                        output: { handle.write($0) }).status
        } catch ProcessRunner.Failure.timedOut {
            throw DispatchError.timedOut(argv.joined(separator: " "), minutes: Int(timeout.components.seconds / 60))
        }
    }
}
