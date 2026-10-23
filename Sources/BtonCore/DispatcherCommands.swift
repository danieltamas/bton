import Foundation

/// A flow's checks and a merge command: run with their output in the job's log, and the PR
/// re-read that guards the command.
extension Dispatcher {
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
        do {
            return try await runner.run(executable, Array(argv.dropFirst()), in: directory,
                                        environment: DispatchPlanner.processEnvironment(repo: environment, bton: ["PATH": Executables.searchPath(for: executable)]),
                                        timeout: timeout, output: { handle.write($0) }).status
        } catch ProcessRunner.Failure.timedOut {
            throw DispatchError.timedOut(argv.joined(separator: " "), minutes: Int(timeout.components.seconds / 60))
        }
    }
}
