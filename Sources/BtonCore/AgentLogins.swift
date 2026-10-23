import Foundation

/// Why an agent exited non-zero, in one line from what it printed, and whether its CLI login
/// expired: such a job fails in seconds, and every job queued behind it would fail the same way.
public enum AgentFailure {
    static let reasonLimit = 200
    /// Read from the end of each file: the reason is in the agent's last lines.
    static let tailBytes = 16_384
    /// How many of the agent's last error lines are searched for a login failure: earlier ones may
    /// be a tool's output the agent read (codex logs its whole transcript), not why it stopped.
    static let loginLines = 3
    /// Bton's note right before the agent starts: what its log holds after it is the agent's own.
    static let startNote = "agent starts"
    static let loginPhrases = ["failed to authenticate", "oauth session expired", "invalid api key", "please run /login",
                               "not logged in"]

    /// The last line the agent printed, else the last line of its log that is not one of Bton's notes.
    /// It may quote a contributor, so escapes and invisible characters are dropped before it is shown.
    public static func reason(output: String, log: String) -> String? {
        let line = (lines(output).last ?? lines(log).last).map(plain)
        return line.flatMap { $0.isEmpty ? nil : String($0.prefix(reasonLimit)) }
    }

    public static func isLoginFailure(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return loginPhrases.contains { lowered.contains($0) }
    }

    public static func detail(status: Int32?, output: String, log: String) -> String {
        let reason = reason(output: output, log: log)
        // The agent's own errors only: what it last said, and its stderr since it started, never a
        // setup command's output logged before.
        let all = log.components(separatedBy: .newlines)
        let start = all.lastIndex { isNote($0) && $0.hasSuffix("bton: \(startNote)") }
        let stderr = start.map { all[($0 + 1)...].joined(separator: "\n") } ?? log
        let recent = lines(output).suffix(1) + lines(stderr).suffix(loginLines)
        if recent.contains(where: isLoginFailure) { return "agent logged out: \(reason ?? "")" }
        return "agent exited \(status.map(String.init) ?? "abnormally")" + (reason.map { ": \($0)" } ?? "")
    }

    /// The end of a job's file; empty when it is missing.
    static func tail(of url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Non-empty trimmed lines, without Bton's own notes.
    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isNote($0) }
    }

    /// A line of Bton's own: "<ISO date> bton: ...".
    private static func isNote(_ line: String) -> Bool {
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 2)
        return words.count >= 2 && words[1] == "bton:" && (try? Date(String(words[0]), strategy: .iso8601)) != nil
    }

    /// Without terminal escapes, control characters and invisible ones (bidi marks, zero-width).
    private static func plain(_ line: String) -> String {
        let unescaped = line.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        let scalars = unescaped.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }
}

/// Agents whose CLI login expired: their jobs wait, rather than fail one after another, until
/// the owner logs in again and says so, or one of its jobs ends without that failure (or is stopped).
public enum AgentLogins {
    public static func held(jobs: [Job], loggedInAt: [String: Date]) -> Set<String> {
        var newest: [String: Job] = [:]
        for job in jobs where job.status != .running {
            guard let agent = job.agent, let ended = job.endedAt else { continue }
            if ended > newest[agent]?.endedAt ?? .distantPast { newest[agent] = job }
        }
        return Set(newest.filter { agent, job in
            job.flags?.contains(.loggedOut) == true && job.endedAt.map { $0 > loggedInAt[agent] ?? .distantPast } == true
        }.keys)
    }

    /// When the owner last said they logged each agent in again; empty when unreadable.
    public static func load(home: BtonHome) -> [String: Date] {
        guard let data = try? Data(contentsOf: url(home)) else { return [:] }
        return (try? decoder.decode([String: Date].self, from: data)) ?? [:]
    }

    public static func markLoggedIn(_ agent: String, at date: Date, home: BtonHome) throws {
        var marks = load(home: home)
        marks[agent] = date
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(marks).write(to: url(home), options: .atomic)
    }

    private static func url(_ home: BtonHome) -> URL { home.url.appendingPathComponent("agent-logins.json") }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}
