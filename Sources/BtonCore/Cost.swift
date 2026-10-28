import Foundation

/// Token counts of one model call, or the sum of a session.
public struct TokenUsage: Hashable, Codable, Sendable {
    public var input: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var output: Int

    public init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(input: lhs.input + rhs.input, cacheRead: lhs.cacheRead + rhs.cacheRead,
                   cacheWrite: lhs.cacheWrite + rhs.cacheWrite, output: lhs.output + rhs.output)
    }
}

/// USD per million tokens. Prices change, so they come from config, never from code.
public struct ModelPrice: Codable, Hashable, Sendable {
    public let input: Decimal
    public let cacheRead: Decimal
    public let cacheWrite: Decimal
    public let output: Decimal

    public init(input: Decimal, cacheRead: Decimal, cacheWrite: Decimal, output: Decimal) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.output = output
    }

    /// The model-calls term of C_task: Σ (T/10⁶ · P) per token class.
    public func cost(of usage: TokenUsage) -> Decimal {
        let perToken: Decimal = 1_000_000
        return (Decimal(usage.input) * input + Decimal(usage.cacheRead) * cacheRead
            + Decimal(usage.cacheWrite) * cacheWrite + Decimal(usage.output) * output) / perToken
    }
}

/// `$BTON_HOME/prices.json`. `models` comes from the price feed and is replaced whole on each
/// refresh (see `PriceFeed`); `custom` holds what the owner priced for models the feed lacks,
/// and a refresh never touches it.
public struct PriceList: Codable, Sendable {
    public var models: [String: ModelPrice]
    public var custom: [String: ModelPrice]?
    /// Where `models` came from, and when.
    public var source: String?
    public var updatedAt: Date?

    public init(models: [String: ModelPrice], custom: [String: ModelPrice]? = nil, source: String? = nil, updatedAt: Date? = nil) {
        self.models = models
        self.custom = custom
        self.source = source
        self.updatedAt = updatedAt
    }

    /// The exact model first, else the longest key it starts with (`claude-sonnet` prices every
    /// dated Sonnet release). A custom price wins over the feed's at the same match.
    public func price(for model: String) -> ModelPrice? {
        let custom = custom ?? [:]
        if let exact = custom[model] ?? models[model] { return exact }
        let matches = custom.filter { model.hasPrefix($0.key) }.map { ($0.key, $0.value, 1) }
            + models.filter { model.hasPrefix($0.key) }.map { ($0.key, $0.value, 0) }
        return matches.max { ($0.0.count, $0.2) < ($1.0.count, $1.2) }?.1
    }

    /// nil while any model that used tokens has no price: an unknown model is never shown as $0.
    public static func cost(of usage: [String: TokenUsage], prices: PriceList) -> Decimal? {
        var total: Decimal = 0
        for (model, tokens) in usage where tokens != TokenUsage() {
            guard let price = prices.price(for: model) else { return nil }
            total += price.cost(of: tokens)
        }
        return total
    }

    public static func url(home: BtonHome) -> URL { home.url.appendingPathComponent("prices.json") }

    public static func load(home: BtonHome) -> PriceList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PriceList.self, from: Data(contentsOf: url(home: home)))) ?? PriceList(models: [:])
    }

    private static let writing = NSLock()

    /// Load, change and save as one step, so the engine's refresh and the owner's edits in
    /// Settings never save over each other in this process.
    @discardableResult
    public static func update(home: BtonHome, _ change: (inout PriceList) throws -> Void) throws -> PriceList {
        writing.lock()
        defer { writing.unlock() }
        var list = load(home: home)
        try change(&list)
        try list.save(home: home)
        return list
    }

    /// Written whole and atomically: a job reading prices mid-save sees the old list or the new one.
    public func save(home: BtonHome) throws {
        try home.prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.url(home: home), options: .atomic)
    }
}

/// Claude Code transcripts: `~/.claude/projects/<encoded cwd>/<session id>.jsonl`.
public enum ClaudeSessions {
    public static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    }

    public static func sessionFile(id: UUID, projectsRoot: URL = projectsRoot) -> URL? {
        let name = "\(id.uuidString.lowercased()).jsonl"
        let projects = (try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        return projects.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Tokens per model, with the session's subagents: Claude Code writes each one's transcript
    /// to `<session id>/subagents/agent-*.jsonl` beside the session's own file.
    public static func usage(ofSessionFile url: URL) throws -> [String: TokenUsage] {
        let subagents = url.deletingPathExtension().appendingPathComponent("subagents", isDirectory: true)
        let files = ((try? FileManager.default.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        return try files.reduce(into: try usage(ofTranscript: url)) { totals, file in
            totals.merge(try usage(ofTranscript: file), uniquingKeysWith: +)
        }
    }

    /// A message's usage repeats on every line of that message, so each `message.id` +
    /// `requestId` counts once.
    private static func usage(ofTranscript url: URL) throws -> [String: TokenUsage] {
        struct Line: Decodable {
            struct Message: Decodable {
                struct Usage: Decodable {
                    let input_tokens: Int?, cache_read_input_tokens: Int?, cache_creation_input_tokens: Int?, output_tokens: Int?
                }
                let id: String?, model: String?, usage: Usage?
            }
            let type: String?, requestId: String?, message: Message?
        }
        var seen = Set<String>(), totals: [String: TokenUsage] = [:]
        let decoder = JSONDecoder()
        for text in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            guard let line = try? decoder.decode(Line.self, from: Data(text.utf8)), line.type == "assistant",
                  let message = line.message, let model = message.model, let usage = message.usage,
                  seen.insert("\(message.id ?? UUID().uuidString)|\(line.requestId ?? "")").inserted else { continue }
            totals[model, default: TokenUsage()] = totals[model, default: TokenUsage()]
                + TokenUsage(input: usage.input_tokens ?? 0, cacheRead: usage.cache_read_input_tokens ?? 0,
                             cacheWrite: usage.cache_creation_input_tokens ?? 0, output: usage.output_tokens ?? 0)
        }
        return totals
    }
}

/// Codex sessions, Bton's own codex agents and any `codex exec` a Claude agent runs:
/// `$CODEX_HOME/sessions/YYYY/MM/DD/rollout-<local time>-<id>.jsonl`. Nothing in one names the
/// job, so a job owns the sessions that started in its worktree while it ran.
public enum CodexSessions {
    public static var sessionsRoot: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Tokens per model of every session whose working directory is `worktree` or inside it and
    /// that started between `start` and `end`. A Bton worktree nested in it (a job working the
    /// main checkout while another works `.worktrees/bton-…`) belongs to its own job.
    public static func usage(inWorktree worktree: String, from start: Date, to end: Date,
                             sessionsRoot: URL = sessionsRoot) -> [String: TokenUsage] {
        let root = URL(fileURLWithPath: worktree).standardizedFileURL.path
        let owns = { (cwd: String) in
            (cwd == root || cwd.hasPrefix(root + "/")) && !cwd.hasPrefix(root + "/.worktrees/")
        }
        var totals: [String: TokenUsage] = [:]
        for file in files(from: start, to: end, sessionsRoot: sessionsRoot) {
            guard let meta = try? meta(of: file), let started = meta.started, started >= start, started <= end,
                  owns(meta.cwd), let usage = try? usage(ofSessionFile: file) else { continue }
            totals.merge(usage, uniquingKeysWith: +)
        }
        return totals
    }

    /// The shell commands those same sessions ran, one text per call: an `exec` call's script
    /// (`cmd:"..."` fragments) or a `shell` call's arguments. nil when the window has no session
    /// of the worktree, so an unreadable history is never a count of zero.
    public static func commands(inWorktree worktree: String, from start: Date, to end: Date,
                                sessionsRoot: URL = sessionsRoot) -> [String]? {
        let root = URL(fileURLWithPath: worktree).standardizedFileURL.path
        let owns = { (cwd: String) in
            (cwd == root || cwd.hasPrefix(root + "/")) && !cwd.hasPrefix(root + "/.worktrees/")
        }
        var commands: [String]? = nil
        for file in files(from: start, to: end, sessionsRoot: sessionsRoot) {
            guard let meta = try? meta(of: file), let started = meta.started, started >= start, started <= end,
                  owns(meta.cwd), let data = try? Data(contentsOf: file) else { continue }
            var found: [String] = []
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let payload = (try? JSONDecoder().decode(Line.self, from: Data(line)))?.payload else { continue }
                switch (payload.type, payload.name) {
                case ("custom_tool_call", "exec"): if let input = payload.input { found.append(input) }
                case ("function_call", "shell"), ("function_call", "shell_command"): if let arguments = payload.arguments { found.append(arguments) }
                default: continue
                }
            }
            commands = (commands ?? []) + found
        }
        return commands
    }

    private struct Line: Decodable {
        struct Payload: Decodable {
            struct Info: Decodable {
                struct Usage: Decodable {
                    let input_tokens: Int?, cached_input_tokens: Int?, cache_write_input_tokens: Int?, output_tokens: Int?
                }
                let total_token_usage: Usage?
            }
            let type: String?, cwd: String?, timestamp: String?, model: String?, info: Info?
            let name: String?, input: String?, arguments: String?
        }
        let type: String?, payload: Payload?
    }

    /// From the first line alone, so a session in another folder is never read whole.
    private static func meta(of url: URL) throws -> (cwd: String, started: Date?) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data += chunk[..<newline]
                break
            }
            data += chunk
        }
        let line = try JSONDecoder().decode(Line.self, from: data)
        guard line.type == "session_meta", let cwd = line.payload?.cwd else { throw CocoaError(.fileReadCorruptFile) }
        let dates = ISO8601DateFormatter()
        dates.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let started = line.payload?.timestamp.flatMap { dates.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
        return (URL(fileURLWithPath: cwd).standardizedFileURL.path, started)
    }

    /// The day folders the window touches, a day either side: the folders and file names are in
    /// the local time of the Mac that ran codex.
    private static func files(from start: Date, to end: Date, sessionsRoot: URL) -> [URL] {
        let calendar = Calendar.current
        var day = calendar.startOfDay(for: start.addingTimeInterval(-86_400))
        var files: [URL] = []
        while day <= end.addingTimeInterval(86_400) {
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = sessionsRoot.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            files += ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "jsonl" }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return files
    }

    /// `token_count` events carry the session's running total, so each one adds what grew since
    /// the last, to the model of the turn it belongs to. Codex counts cached input inside input.
    private static func usage(ofSessionFile url: URL) throws -> [String: TokenUsage] {
        let decoder = JSONDecoder()
        var model = "codex", last = TokenUsage(), totals: [String: TokenUsage] = [:]
        for text in try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline) {
            guard let line = try? decoder.decode(Line.self, from: Data(text.utf8)), let payload = line.payload else { continue }
            switch line.type {
            case "turn_context":
                model = payload.model ?? model
            case "event_msg" where payload.type == "token_count":
                guard let total = payload.info?.total_token_usage else { continue }
                let cached = total.cached_input_tokens ?? 0
                let now = TokenUsage(input: (total.input_tokens ?? 0) - cached, cacheRead: cached,
                                     cacheWrite: total.cache_write_input_tokens ?? 0, output: total.output_tokens ?? 0)
                totals[model, default: TokenUsage()] = totals[model, default: TokenUsage()]
                    + TokenUsage(input: now.input - last.input, cacheRead: now.cacheRead - last.cacheRead,
                                 cacheWrite: now.cacheWrite - last.cacheWrite, output: now.output - last.output)
                last = now
            default: continue
            }
        }
        return totals
    }
}
