import Foundation

/// A flow's checks and a merge command, run with their output in the job's log.
extension Dispatcher {
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
