import Foundation

/// The one way Bton starts a process: an argv array, never a shell, and a timeout.
public struct ProcessRunner: Sendable {
    public enum Failure: Error, LocalizedError, Equatable {
        case timedOut

        public var errorDescription: String? { "The command did not finish in time and was stopped." }
    }

    public init() {}

    /// A non-zero exit is returned, not thrown: what it means is the caller's call. `environment`
    /// is added to this process's own. `started` gets the child's process group as it starts.
    public func run(_ executable: String, _ arguments: [String], in directory: URL? = nil,
                    environment: [String: String] = [:], timeout: Duration,
                    started: (@Sendable (Int32) -> Void)? = nil) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        }
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let (exits, exited) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.finish() }
        try process.run()
        started?(process.processIdentifier)

        // Foundation starts the child as the leader of its own process group, so signalling the
        // group also reaches grandchildren (a test runner's workers) that would keep the pipes
        // open, even after the child itself has exited: the group id lives while any member does.
        let group = -process.processIdentifier
        let signal: @Sendable (Int32) -> Void = { kill(group, $0) }
        // The watchdog runs until the pipes close, not only until the child exits, so a
        // grandchild holding them is stopped at the deadline too. It answers whether it fired.
        let watchdog = Task { () -> Bool in
            do { try await Task.sleep(for: timeout) } catch { return false }
            signal(SIGTERM)
            if (try? await Task.sleep(for: .seconds(2))) != nil { signal(SIGKILL) }
            return true
        }
        return try await withTaskCancellationHandler {
            // Both pipes drain while the child runs: a child that fills one 64 KB pipe buffer
            // while nobody reads it never exits.
            async let out = Self.drain(stdout.fileHandleForReading)
            async let err = Self.drain(stderr.fileHandleForReading)
            let (outData, errData) = await (out, err)
            for await _ in exits {}
            watchdog.cancel()
            // A child that handles SIGTERM and exits 0 still ran past its deadline.
            if await watchdog.value { throw Failure.timedOut }
            try Task.checkCancellation()
            return ProcessOutput(status: process.terminationStatus, stdout: outData,
                                 stderr: String(decoding: errData, as: UTF8.self))
        } onCancel: {
            signal(SIGKILL)
        }
    }

    /// Reads on a dispatch thread, not the cooperative pool, since `readToEnd` blocks until EOF.
    private static func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: (try? handle.readToEnd()) ?? Data())
            }
        }
    }
}

public struct ProcessOutput: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: String
}

/// A menu bar app gets a minimal PATH, so agents are also looked for where installers put them.
public enum Executables {
    public static let searchPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        return (inherited + extra.filter { !inherited.contains($0) }).joined(separator: ":")
    }()

    /// The PATH for `program`, its own directory first: nvm's `codex` runs `#!/usr/bin/env node`,
    /// and its node sits beside the link, not beside what the link points to.
    public static func searchPath(for program: String) -> String {
        guard program.contains("/") else { return searchPath }
        let directory = URL(fileURLWithPath: program).deletingLastPathComponent().path
        return ([directory] + searchPath.split(separator: ":").map(String.init).filter { $0 != directory }).joined(separator: ":")
    }

    public static func resolve(_ name: String) -> String? {
        if name.contains("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.split(separator: ":").map { "\($0)/\(name)" }
            .first(where: FileManager.default.isExecutableFile)
    }
}

extension FileHandle {
    /// `O_APPEND`, so Bton's notes and the agent's stderr, written through separate handles,
    /// never overwrite each other.
    static func appending(to url: URL) throws -> FileHandle {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
