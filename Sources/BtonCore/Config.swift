import Foundation

/// `$BTON_HOME/config.json`. Machine-level settings only; the rules of a team's flow live in
/// each repo (`.bton/flow.json`) so every teammate's Bton runs the same ones.
public struct BtonConfig: Codable, Sendable {
    public var repos: [WatchedRepo]
    public var pollSeconds: Int
    public var maxAgents: Int
    /// The agents this Mac starts unattended, keyed by name. Which tools run unattended is the
    /// Mac owner's call, so this never comes from a repo. An agent without an entry is
    /// never started.
    public var agents: [String: AgentTemplate]
    public var schedules: [ScheduleEntry]

    /// Where the skeleton kept its config; read once, moved to `$BTON_HOME`.
    public static let legacyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/bton/config.json")

    public static let initial = BtonConfig(
        repos: [],
        pollSeconds: 60,
        maxAgents: 2,
        agents: ["claude": AgentTemplate(argv: [
            "claude", "-p", "{prompt}", "--session-id", "{session}", "--permission-mode", "acceptEdits",
            "--allowedTools", "Bash(git:*)", "Bash(gh:*)", "Bash(bun:*)", "Bash(bash scripts/*)",
        ])],
        schedules: []
    )

    /// Reads the config. On first launch it migrates the skeleton's file, or writes the initial
    /// config so the user has a file to edit.
    public static func loadOrCreate(home: BtonHome = BtonHome(), legacyURL: URL = legacyURL) throws -> BtonConfig {
        try home.prepare()
        let files = FileManager.default
        if files.fileExists(atPath: home.configURL.path) {
            return try JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: home.configURL))
        }
        guard files.fileExists(atPath: legacyURL.path) else {
            try initial.save(to: home.configURL)
            return initial
        }
        let legacy = try JSONDecoder().decode(LegacyConfig.self, from: Data(contentsOf: legacyURL))
        var config = initial
        config.repos = legacy.repos.map { WatchedRepo(slug: $0, path: nil) }
        config.pollSeconds = legacy.pollSeconds
        config.schedules = legacy.schedules
        try config.save(to: home.configURL)
        // The new file is what counts from here on; a legacy file that cannot be removed is
        // never read again.
        try? files.removeItem(at: legacyURL)
        return config
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static let pollSecondsRange = 15...3_600
    public static let maxAgentsRange = 0...16

    /// An agent name as config keys and schedules spell it.
    public static func isAgentName(_ text: String) -> Bool {
        text.wholeMatch(of: /[a-z][a-z0-9-]{0,31}/) != nil
    }

    /// `owner/name` as GitHub spells it; anything else is refused before `gh` is called.
    public static func isRepoSlug(_ text: String) -> Bool {
        text.wholeMatch(of: /[A-Za-z0-9-]+\/[A-Za-z0-9._-]+/) != nil
    }

    /// The skeleton's shape: repos were bare slugs.
    private struct LegacyConfig: Decodable {
        let repos: [String]
        let pollSeconds: Int
        let schedules: [ScheduleEntry]
    }
}

/// A repo this Bton watches and the local clone its worktrees are made in.
public struct WatchedRepo: Codable, Hashable, Sendable {
    public var slug: String
    /// Absolute path of the clone; nil until the user chooses one (repos migrated from the
    /// skeleton). Nothing is dispatched for a repo without a clone.
    public var path: String?
    /// The branch PRs merge into: where Bton reads the flow and starts schedules. Nil is GitHub's
    /// default branch, which is not the working branch everywhere (a team may merge into develop).
    public var branch: String?
    /// Variables this Mac's checks, merge commands and agents get in this repo (a test database
    /// that only exists here, for one). This Mac's, never the repo's; never logged.
    public var environment: [String: String]?

    public init(slug: String, path: String?, branch: String? = nil, environment: [String: String]? = nil) {
        self.slug = slug
        self.path = path
        self.branch = branch
        self.environment = environment
    }

    public enum EnvironmentError: Error, LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case let .invalid(message) = self { message } else { nil } }
    }

    /// The Settings editor's text: one `KEY=VALUE` per line, the value verbatim after the first
    /// `=`; blank lines and `#` comments are skipped.
    public static func parseEnvironment(_ text: String) throws -> [String: String] {
        var environment: [String: String] = [:]
        // Split on the scalar: Swift's String treats "\r\n" as one Character, not a "\n".
        let lines = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, scalars) in lines.enumerated() {
            let raw = String(String.UnicodeScalarView(scalars))
            let line = raw.unicodeScalars.last == "\r" ? String(String.UnicodeScalarView(raw.unicodeScalars.dropLast())) : raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let number = index + 1
            guard let equals = line.firstIndex(of: "=") else {
                throw EnvironmentError.invalid("line \(number): write it as NAME=value")
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: equals)...])
            if key.isEmpty { throw EnvironmentError.invalid("line \(number): the name is missing") }
            if let problem = environmentProblem([key: value]) { throw EnvironmentError.invalid("line \(number): \(problem)") }
            guard environment[key] == nil else { throw EnvironmentError.invalid("line \(number): \(key) is set twice") }
            environment[key] = value
        }
        return environment
    }

    public static func environmentText(_ environment: [String: String]) -> String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    /// Bton sets PATH, git's credential config and its own variables itself; a repo's
    /// environment never replaces them.
    public static func environmentProblem(_ environment: [String: String]) -> String? {
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard key.count <= 100, key.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil else {
                return "\(key) is not a variable name"
            }
            if ["PATH", "HOME", "MCP_TOOL_TIMEOUT"].contains(key) || key.hasPrefix("BTON_") || key.hasPrefix("GIT_") {
                return "\(key) is set by Bton"
            }
            if value.contains("\0") { return "\(key) has a NUL character" }
            // One line per variable in Settings: a newline in a value would split it there.
            if value.unicodeScalars.contains("\n") { return "\(key) has a line break" }
        }
        return nil
    }

    /// A plain branch name: it goes into a GitHub API query and a git ref, so nothing either
    /// could read as an option, a range or a parameter.
    public static func isBranchName(_ name: String) -> Bool {
        name.count <= 100 && name.wholeMatch(of: /[A-Za-z0-9_][A-Za-z0-9._\/-]*/) != nil
            && !name.contains("..") && !name.contains("//") && !name.hasSuffix("/") && !name.hasSuffix(".lock")
    }
}

/// The argv that starts one agent. `{prompt}` and `{session}` are filled in per job; the
/// array is passed to the process as is, never through a shell.
public struct AgentTemplate: Codable, Hashable, Sendable {
    public var argv: [String]

    public init(argv: [String]) {
        self.argv = argv
    }

    /// What keeps the template from saving; nil when it can. Without `{prompt}` the agent would
    /// start with no task. `{session}` is optional: only Claude takes a session id, and without
    /// one the job's cost cannot be found.
    public var problem: String? {
        guard let first = argv.first, !first.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "The first line is the program to run."
        }
        if !argv.contains(where: { $0.contains("{prompt}") }) { return "Pass {prompt} as one of the arguments." }
        return nil
    }
}
