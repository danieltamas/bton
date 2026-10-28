import Foundation
import os

/// Second opinions for a schedule or a PR move: other agents its Claude may ask through Bton's `ask` MCP tool.
/// The tool runs outside Claude's Bash sandbox, as Bton's own process, so a helper such as codex can reach its API, and every ask lands in the job's log.
public enum Helpers {
    public static let tool = "mcp__bton__ask"
    static let maxQuestion = 20_000
    static let maxAnswer = 20_000
    /// How long one ask may take; Claude Code waits a minute longer for the tool.
    public static let askTimeout: Duration = .seconds(20 * 60)
    static let toolTimeoutMilliseconds = 21 * 60 * 1000

    /// `bton ask-server`: the CLI inside the app bundle, or the CLI itself when it is the host.
    /// The bundle's own binary is `Bton`, so the CLI is `BtonCLI` there (APFS ignores case).
    public static var serverPath: String? {
        if let bundled = Bundle.main.path(forAuxiliaryExecutable: "BtonCLI") { return bundled }
        return Bundle.main.executablePath.flatMap { URL(fileURLWithPath: $0).lastPathComponent == "BtonCLI" ? $0 : nil }
    }

    public struct AskResult: Sendable, Equatable {
        public var text: String
        public var isError: Bool

        public init(text: String, isError: Bool) {
            self.text = text
            self.isError = isError
        }
    }

    /// Helpers that can run here, and the ones that cannot: not configured or not installed.
    public static func usable(_ names: [String], agents: [String: AgentTemplate],
                              resolve: (String) -> String?) -> (usable: [String], missing: [String]) {
        var usable: [String] = [], missing: [String] = []
        for name in names {
            if let program = agents[name]?.argv.first, resolve(program) != nil { usable.append(name) } else { missing.append(name) }
        }
        return (usable, missing)
    }

    /// The `--mcp-config` file that starts `bton ask-server` for one job.
    public static func serverConfig(server: String, job: UUID, home: URL, cwd: URL, helpers: [String]) -> Data {
        let args = ["ask-server", "--job", job.uuidString, "--cwd", cwd.path] + helpers.flatMap { ["--helper", $0] }
        let config: [String: Any] = ["mcpServers": ["bton": [
            "type": "stdio", "command": server, "args": args, "env": ["BTON_HOME": home.path],
        ]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    public static func instructions(_ helpers: [String]) -> String {
        guard !helpers.isEmpty else { return "" }
        return """
            When the task is hard or you are stuck, you can ask another agent for a second opinion with the \
            \(tool) tool: agent is one of \(helpers.joined(separator: ", ")), question is everything it needs, \
            since it does not see this conversation. It works in the same checkout and cannot change it. \
            Ask other agents only through this tool: run from Bash, the sandbox keeps them from their service. \
            In your final message, say which agent you asked and why.
            """
    }

    /// What a job hears when its flow names helpers it cannot be offered: a codex agent gets no
    /// ask server, and a Claude agent gets none when no helper's program is here. Said as an
    /// identity, not an absence: a task that says "consult codex" is otherwise read as blocked by
    /// the codex agent that could do the check itself.
    public static func unavailable(agent: String, helpers: [String]) -> String {
        let named = helpers.joined(separator: ", ")
        let own = helpers.contains(agent)
            ? " A step that says to consult \(agent) is satisfied by your own work: you are the \(agent) agent."
            : ""
        return """
            No \(tool) tool exists in this session: you are the \(agent) agent, and the helper \(named)             could not be offered here.\(own) Do every check such a step asks for yourself, in this session,             and say in your result that no separate helper was available. That is not a blocker.
            """
    }

    /// A helper answers and never changes the tree the asking agent works in, whatever its
    /// template says: Claude in plan mode without its editing tools, codex in its read-only
    /// sandbox. Another program runs as its owner wrote it.
    static func readOnly(_ template: [String]) -> [String] {
        guard let program = template.first else { return template }
        let end = template.firstIndex(of: "--") ?? template.endIndex
        var kept: [String] = []
        var forced: [String]
        let dropped: Set<String>, droppedWithValue: Set<String>
        switch URL(fileURLWithPath: program).lastPathComponent {
        case "claude":
            forced = ["--permission-mode", "plan", "--disallowedTools", "Bash", "Edit", "Write", "NotebookEdit"]
            dropped = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"]
            droppedWithValue = ["--permission-mode"]
        case "codex":
            forced = ["--sandbox", "read-only"]
            dropped = ["--full-auto", "--dangerously-bypass-approvals-and-sandbox", "--yolo"]
            droppedWithValue = ["--sandbox", "-s"]
        default:
            return template
        }
        var index = 1
        while index < end {
            let argument = template[index]
            index += 1
            let flag = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if dropped.contains(argument) { continue }
            if droppedWithValue.contains(flag) {
                if !argument.contains("="), index < end { index += 1 }
                continue
            }
            kept.append(argument)
        }
        // codex takes its options after the `exec` subcommand.
        if forced.first == "--sandbox", kept.first == "exec" { forced.insert(kept.removeFirst(), at: 0) }
        return [program] + forced + kept + template[end...]
    }

    /// Runs one helper on `question` in `cwd`, like an agent: the question is one argv element,
    /// a Claude helper is hardened and never gets Bton's server (so it cannot ask further), and
    /// the whole process group is stopped at `timeout`. Every ask is recorded in the job's log.
    public static func ask(agent: String, question: String, allowed: [String], agents: [String: AgentTemplate],
                           cwd: URL, job: UUID, jobs: JobStore, timeout: Duration,
                           resolve: (String) -> String? = { Executables.resolve($0) }) async -> AskResult {
        let firstLine = question.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        jobs.note(job, "asked \(agent): \(firstLine)")
        let refused = { (reason: String) -> AskResult in
            jobs.note(job, "\(agent) not asked: \(reason)")
            return AskResult(text: reason, isError: true)
        }
        guard allowed.contains(agent), let template = agents[agent], let program = template.argv.first else {
            return refused("\(agent) is not one of this job's helpers")
        }
        guard let executable = resolve(program) else {
            return refused("\(program) is not installed on this Mac")
        }
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, question.count <= maxQuestion else {
            return refused("the question must be 1 to \(maxQuestion) characters")
        }
        let session = UUID()
        let argv = DispatchPlanner.argv(readOnly(template.argv), prompt: question, session: session)
        if AgentHardening.isClaude(program), template.argv.contains(where: { $0.contains("{session}") }),
           let handle = try? FileHandle.appending(to: jobs.helperSessionsURL(job)) {
            handle.write(Data("\(session.uuidString.lowercased())\n".utf8))
            try? handle.close()
        }
        let started = Date.now
        let result: AskResult
        do {
            let group = OSAllocatedUnfairLock<Int32?>(initialState: nil)
            defer { group.withLock { $0 }.map { try? FileManager.default.removeItem(at: jobs.helperGroupURL(job, group: $0)) } }
            let output = try await ProcessRunner().run(executable, Array(argv.dropFirst()), in: cwd,
                                                       environment: ["PATH": Executables.searchPath(for: executable), "BTON_HELPER": "1"],
                                                       timeout: timeout) { pid in
                group.withLock { $0 = pid }
                FileManager.default.createFile(atPath: jobs.helperGroupURL(job, group: pid).path, contents: nil)
            }
            if output.status == 0 {
                var text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if text.count > maxAnswer { text = String(text.prefix(maxAnswer)) + "\n[answer cut at \(maxAnswer) characters]" }
                result = AskResult(text: text, isError: false)
            } else {
                result = AskResult(text: "\(agent) exited \(output.status): \(String(output.stderr.suffix(2_000)))", isError: true)
            }
        } catch ProcessRunner.Failure.timedOut {
            result = AskResult(text: "\(agent) timed out after \(timeout) and was stopped", isError: true)
        } catch {
            result = AskResult(text: "\(agent) could not run: \(error.localizedDescription)", isError: true)
        }
        let seconds = Int(Date.now.timeIntervalSince(started))
        jobs.note(job, "\(agent) \(result.isError ? "failed" : "answered") after \(seconds)s")
        jobs.note(job, "--- question to \(agent) ---\n\(question)\n--- \(agent)'s answer ---\n\(result.text)\n--- end ---")
        return result
    }
}
