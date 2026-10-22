import Foundation

/// What one dispatch is for. A key that has a job, whatever its status, is never dispatched again:
/// only a new head or a new move makes a new key.
public struct JobKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public let repo: String
    /// `pr-12`, `issue-7`: also the lease item.
    public let item: String
    public let move: String
    /// The PR head SHA; empty for intake.
    public let head: String

    public init(repo: String, item: String, move: String, head: String) {
        self.repo = repo
        self.item = item
        self.move = move
        self.head = head
    }

    public var description: String { "\(repo)#\(item) \(move)@\(head.prefix(12))" }
}

/// One agent session or command working one key, in its own worktree.
public struct Job: Identifiable, Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable { case running, succeeded, failed, cancelled }

    /// Also the lease's job and the agent's session id.
    public let id: UUID
    public let key: JobKey
    /// nil for a command move (merge).
    public let agent: String?
    public var pid: Int32?
    public var worktree: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var status: Status
    /// Why it failed or was skipped, for the Jobs tab.
    public var detail: String?
    /// Tokens per model, as last read from the session's transcript.
    public var usage: [String: TokenUsage]
    /// nil while any model in `usage` has no price.
    public var cost: Decimal?
    /// When the agent is stopped. Kept, like `review`, so a restarted Bton finishes the job as
    /// the one that started it would have.
    public var deadline: Date?
    /// Set when the agent's final message is posted as a review.
    public var review: ReviewTarget?
    /// The owner asked for this failed or stopped move to run again on the same head.
    public var retry: Bool?
    /// What the watchdog found when the job ended; nil when nothing.
    public var flags: [JobFlag]?
    /// A supervise job's flagged job.
    public var supervises: UUID?
    /// A supervisor's note was in this job's prompt, so no supervisor looks at it again.
    public var steered: Bool?
    /// A supervise job's answer, parsed from its final message.
    public var verdict: SupervisorVerdict?
    /// A supervisor's note for this move's next run: on this head for a PR, the next run for a
    /// schedule. Kept here, beside the retry it goes with, so a restart neither loses nor repeats it.
    public var steer: String?
    /// The work label this job put on its PR, so it comes off as added even if Settings changed it.
    public var workLabel: String?

    public init(id: UUID, key: JobKey, agent: String?, pid: Int32? = nil, worktree: String? = nil,
                startedAt: Date, endedAt: Date? = nil, status: Status, detail: String? = nil,
                usage: [String: TokenUsage] = [:], cost: Decimal? = nil, deadline: Date? = nil,
                review: ReviewTarget? = nil, retry: Bool? = nil, supervises: UUID? = nil, steered: Bool? = nil) {
        self.id = id
        self.key = key
        self.agent = agent
        self.pid = pid
        self.worktree = worktree
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.detail = detail
        self.usage = usage
        self.cost = cost
        self.deadline = deadline
        self.review = review
        self.retry = retry
        self.supervises = supervises
        self.steered = steered
    }

    /// A failed or stopped PR job that is its key's latest. A schedule's key names its own time,
    /// so it never comes round again to retry.
    public func canRetry(among jobs: [Job]) -> Bool {
        [.failed, .cancelled].contains(status) && retry != true && key.item.hasPrefix("pr-")
            && !jobs.contains { $0.key == key && $0.startedAt > startedAt }
    }
}

/// Where a review job posts, and which headings its final message may open with.
public struct ReviewTarget: Hashable, Codable, Sendable {
    public let number: Int
    public let head: String
    public let headings: [String]
    /// Removed after the comment is posted; nil in jobs from before decisions.
    public let clearLabels: [String]?

    public init(number: Int, head: String, headings: [String], clearLabels: [String]? = nil) {
        self.number = number
        self.head = head
        self.headings = headings
        self.clearLabels = clearLabels
    }
}

/// `$BTON_HOME/jobs/<id>.json`, plus the agent's output and log beside it.
public struct JobStore: Sendable {
    let home: BtonHome
    let directory: URL

    public init(home: BtonHome) throws {
        self.home = home
        try home.prepare()
        directory = home.url.appendingPathComponent("jobs", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Oldest first. A file that does not decode is skipped, never fatal.
    public func all() -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? Self.decoder.decode(Job.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt < $1.startedAt }
    }

    public func save(_ job: Job) throws {
        try Self.encoder.encode(job).write(to: directory.appendingPathComponent("\(job.id.uuidString).json"),
                                           options: .atomic)
    }

    /// Marks a job the owner retries, so its move runs again on the same head.
    public func requestRetry(_ id: UUID) throws -> Bool {
        let all = all()
        guard var job = all.first(where: { $0.id == id }), job.canRetry(among: all) else { return false }
        job.retry = true
        try save(job)
        return true
    }

    /// A supervisor's retry: a PR's failed move runs again on its head, a schedule at its next run,
    /// either with the note. Asking twice with the same note changes nothing.
    public func requestSteeredRetry(_ id: UUID, note: String) throws -> Bool {
        let all = all()
        guard var job = all.first(where: { $0.id == id }) else { return false }
        if job.steer == note { return true }
        if job.key.item.hasPrefix("pr-") {
            guard job.canRetry(among: all) else { return false }
            job.retry = true
        }
        job.steer = note
        try save(job)
        return true
    }

    /// The agent's stdout: its final message.
    public func outputURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).out") }

    /// Bton's own account of the job (worktree, agent, pid, outcome), the agent's stderr and
    /// every check's and command's output.
    public func logURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).log") }

    /// One timestamped line of Bton's in the job's log; a log that can't be written loses it.
    public func note(_ id: UUID, _ line: String) {
        guard let handle = try? FileHandle.appending(to: logURL(id)) else { return }
        defer { try? handle.close() }
        handle.write(Data("\(Date.now.formatted(.iso8601)) bton: \(line)\n".utf8))
    }

    /// A finished job's output and log keep their last `limit` bytes, so a chatty agent can't
    /// fill the disk.
    public func trim(_ id: UUID, limit: Int = 2_000_000) {
        for url in [outputURL(id), logURL(id)] {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > limit,
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard (try? handle.seek(toOffset: UInt64(size - limit))) != nil, let tail = try? handle.readToEnd() else { continue }
            try? (Data("[\(size - limit) earlier bytes trimmed]\n".utf8) + tail).write(to: url, options: .atomic)
        }
    }

    /// How long a finished job's output, log and exit status stay. Its record stays for good,
    /// for the costs.
    public static let keepDays = 30

    /// Removes the files of jobs that ended more than `days` ago; returns how many jobs it cleared.
    @discardableResult
    public func prune(now: Date = .now, keepingDays days: Int = keepDays) -> Int {
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var cleared = 0
        for job in all() where job.status != .running {
            guard let ended = job.endedAt, ended < cutoff else { continue }
            let files = [outputURL(job.id), logURL(job.id), exitURL(job.id), helperSessionsURL(job.id), helpersConfigURL(job.id)]
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !files.isEmpty else { continue }
            files.forEach { try? FileManager.default.removeItem(at: $0) }
            cleared += 1
        }
        return cleared
    }

    /// The Claude sessions of the job's helpers, one id per line, so their cost is the job's.
    public func helperSessionsURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).helpers") }
    /// The process groups of the job's helpers running now, one marker file each: the ask server
    /// runs them in groups of their own, so stopping the agent's group does not reach them.
    public func helperProcessGroups(_ id: UUID) -> [Int32] {
        let prefix = "\(id.uuidString).helper-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.compactMap { Int32($0.dropFirst(prefix.count)) }
    }

    func helperGroupURL(_ id: UUID, group: Int32) -> URL { directory.appendingPathComponent("\(id.uuidString).helper-\(group)") }

    /// Kills every helper the job still has running; the job is over, so their answers are not wanted.
    public func stopHelpers(_ id: UUID) {
        for group in helperProcessGroups(id) {
            kill(-group, SIGKILL)
            try? FileManager.default.removeItem(at: helperGroupURL(id, group: group))
        }
    }

    /// Bton's MCP server file for the job's helpers.
    func helpersConfigURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).mcp.json") }

    /// The repo's environment the job started with: what the job posts is redacted with the values
    /// its agent saw, even after the config changes or Bton restarts. Removed when the job ends.
    func environmentURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).env.json") }

    func saveEnvironment(_ environment: [String: String], for id: UUID) throws {
        let file = environmentURL(id)
        try JSONEncoder().encode(environment).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Empty when the job started without one; a file that cannot be read fails the post.
    func startedEnvironment(_ id: UUID) throws -> [String: String] {
        let file = environmentURL(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    /// The wrapper writes the agent's exit status here, so it survives a Bton restart.
    func exitURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).exit") }

    /// Held by the Bton instance that runs the job, for the job's lifetime.
    func lockURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).lock") }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
