import Foundation

/// The repo's development memory beside its code graph: its issues, PRs with their reviews and
/// decisions, and Bton's job reports, as Markdown files under `<store>/memory`. graphify maps them
/// with the code, so an agent asks the graph what was decided or tried before instead of
/// re-reading GitHub, and the file a query lands on is the one refreshed at the last sync.
public enum GraphMemory {
    /// `<store>/memory`; also the name of the link in a job's tree and of the copy in the build tree.
    public static let folderName = "memory"
    /// Inside the folder: how far the memory goes.
    public static let stateName = "bton-memory.json"
    /// The first export reaches this far back; later ones take what changed since the state's time.
    public static let firstReach: TimeInterval = 180 * 24 * 3_600
    /// A report longer than this is cut: the agent asks the job's session for the rest.
    static let reportLimit = 4_000
    /// What the files hold and which text is kept out of them. A state written under another
    /// shape makes the next refresh export everything again: what an older rule left out comes in,
    /// nothing to press. Raised whenever a renderer or the write rule changes.
    public static let shape = 3
    /// graphify honours the repository's `info/exclude`, the file that hides `memory` from git, so
    /// the build tree says in graphify's own ignore file that the folder is wanted after all
    /// (last match wins, measured 2026-10-30: 0 memory documents detected without the line, 799 with).
    public static let ignoreName = ".graphifyignore"
    static let ignoreLine = "!" + folderName

    public struct State: Codable, Equatable, Sendable {
        /// The newest `updatedAt` exported; nil before the first export.
        public var updatedAt: Date?
        /// `GraphMemory.shape` when written; a state without one is from before the rule.
        public var shape: Int?
        public var issues: Int
        public var pullRequests: Int
        /// The newest job end exported; the items with a later run are rendered again, the rest
        /// are not read (every job's report would be hundreds of files per sync).
        public var jobsAt: Date?

        public init(updatedAt: Date?, issues: Int, pullRequests: Int, jobsAt: Date? = nil, shape: Int? = nil) {
            self.updatedAt = updatedAt
            self.issues = issues
            self.pullRequests = pullRequests
            self.jobsAt = jobsAt
            self.shape = shape
        }

        /// Where the next refresh reads from: the state's time, or everything when the state was
        /// written under another shape.
        public var since: Date? { shape == GraphMemory.shape ? updatedAt : nil }
    }

    public struct Issue: Sendable, Equatable {
        public let number: Int
        public let title: String
        /// OPEN or CLOSED, as GitHub says.
        public let state: String
        public let createdAt: Date
        public let updatedAt: Date
        public let closedAt: Date?
        public let author: String?
        public let body: String
        public let labels: [String]
        public let comments: [IssueComment]

        public init(number: Int, title: String, state: String, createdAt: Date, updatedAt: Date, closedAt: Date?,
                    author: String?, body: String, labels: [String], comments: [IssueComment]) {
            self.number = number
            self.title = title
            self.state = state
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.closedAt = closedAt
            self.author = author
            self.body = body
            self.labels = labels
            self.comments = comments
        }
    }

    public struct Review: Sendable, Equatable {
        public let author: String?
        public let state: String
        public let body: String
        public let submittedAt: Date?

        public init(author: String?, state: String, body: String, submittedAt: Date?) {
            self.author = author
            self.state = state
            self.body = body
            self.submittedAt = submittedAt
        }
    }

    public struct PullRequestRecord: Sendable, Equatable {
        public let number: Int
        public let title: String
        /// OPEN, MERGED or CLOSED.
        public let state: String
        public let createdAt: Date
        public let updatedAt: Date
        public let mergedAt: Date?
        public let baseRef: String
        public let headRef: String
        public let author: String?
        public let body: String
        public let files: [String]
        public let reviews: [Review]
        public let comments: [IssueComment]

        public init(number: Int, title: String, state: String, createdAt: Date, updatedAt: Date, mergedAt: Date?,
                    baseRef: String, headRef: String, author: String?, body: String, files: [String],
                    reviews: [Review], comments: [IssueComment]) {
            self.number = number
            self.title = title
            self.state = state
            self.createdAt = createdAt
            self.updatedAt = updatedAt
            self.mergedAt = mergedAt
            self.baseRef = baseRef
            self.headRef = headRef
            self.author = author
            self.body = body
            self.files = files
            self.reviews = reviews
            self.comments = comments
        }
    }

    public struct Items: Sendable, Equatable {
        public var issues: [Issue]
        public var pullRequests: [PullRequestRecord]

        public init(issues: [Issue] = [], pullRequests: [PullRequestRecord] = []) {
            self.issues = issues
            self.pullRequests = pullRequests
        }

        /// The newest change among the items; nil when there are none.
        public var newest: Date? {
            (issues.map(\.updatedAt) + pullRequests.map(\.updatedAt)).max()
        }
    }

    public struct JobRun: Sendable, Equatable {
        public let move: String
        public let agent: String?
        public let status: String
        public let startedAt: Date
        public let cost: Decimal?
        public let head: String
        public let report: String?

        public init(move: String, agent: String?, status: String, startedAt: Date, cost: Decimal?, head: String, report: String?) {
            self.move = move
            self.agent = agent
            self.status = status
            self.startedAt = startedAt
            self.cost = cost
            self.head = head
            self.report = report
        }
    }

    public enum Outcome: Equatable, Sendable {
        case unchanged
        case written(files: Int)
    }

    public static func folder(in store: URL) -> URL { store.appendingPathComponent(folderName, isDirectory: true) }

    public static func state(in store: URL) -> State? {
        guard let data = try? Data(contentsOf: folder(in: store).appendingPathComponent(stateName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(State.self, from: data)
    }

    static func writeState(_ state: State, in store: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: folder(in: store).appendingPathComponent(stateName), options: .atomic)
    }

    // MARK: rendering

    /// ISO 8601 to the minute, the precision the instruction line and the files share.
    public static func minute(_ date: Date) -> String {
        String(date.formatted(.iso8601).prefix(16)) + "Z"
    }

    private static func time(_ date: Date) -> String { date.formatted(.iso8601) }

    public static func render(_ issue: Issue, asOf: Date) -> String {
        var parts = ["# #\(issue.number) \(issue.title)",
                     "As of \(minute(asOf)). State: \(issue.state).\(labels(issue.labels))",
                     "## \(issue.author ?? "ghost") opened it, \(time(issue.createdAt))\n\n\(issue.body)"]
        parts += issue.comments.map { "## \($0.author ?? "ghost"), \(time($0.createdAt))\n\n\($0.body)" }
        return parts.joined(separator: "\n\n") + "\n"
    }

    public static func render(_ pr: PullRequestRecord, asOf: Date) -> String {
        let state = pr.state == "MERGED" ? "MERGED into \(pr.baseRef) from \(pr.headRef)" : "\(pr.state), \(pr.headRef) into \(pr.baseRef)"
        var parts = ["# #\(pr.number) \(pr.title)",
                     "As of \(minute(asOf)). State: \(state)." + (pr.mergedAt.map { " Merged \(time($0))." } ?? ""),
                     "## \(pr.author ?? "ghost") opened it, \(time(pr.createdAt))\n\n\(pr.body)"]
        if !pr.files.isEmpty { parts.append("Files:\n" + pr.files.map { "- \($0)" }.joined(separator: "\n")) }
        // Reviews and comments in one timeline: a `## Decision:` comment answers the review before it.
        let reviews = pr.reviews.map { (at: $0.submittedAt ?? .distantPast,
                                        text: "## \($0.author ?? "ghost") reviewed: \($0.state), \($0.submittedAt.map(time) ?? "no time")\n\n\($0.body)") }
        let comments = pr.comments.map { (at: $0.createdAt, text: "## \($0.author ?? "ghost"), \(time($0.createdAt))\n\n\($0.body)") }
        parts += (reviews + comments).sorted { $0.at < $1.at }.map(\.text)
        return parts.joined(separator: "\n\n") + "\n"
    }

    public static func render(item: String, runs: [JobRun], asOf: Date) -> String {
        var parts = ["# Bton jobs on \(item)", "As of \(minute(asOf))."]
        for run in runs.sorted(by: { $0.startedAt > $1.startedAt }) {
            let cost = run.cost.map { "$\($0.formatted(.number.precision(.fractionLength(2))))" } ?? "no cost"
            var text = "## \(run.move) by \(run.agent ?? "command"), \(time(run.startedAt)), \(run.status), \(cost), head \(run.head.prefix(8))"
            if let report = run.report?.trimmingCharacters(in: .whitespacesAndNewlines), !report.isEmpty {
                text += "\n\n" + String(report.prefix(reportLimit))
            }
            parts.append(text)
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    private static func labels(_ names: [String]) -> String {
        names.isEmpty ? "" : " Labels: \(names.joined(separator: ", "))."
    }

    // MARK: export

    /// Writes the items and this Mac's job reports under `<store>/memory`. A file is dated by its
    /// record's own time, never the sync's, so a file whose bytes did not change is left alone
    /// and graphify's cache still covers it (measured: the sync's minute rewrote 100 files a sync); a body that would carry a
    /// value of the repo's environment is not written at all. The state's time becomes the newest
    /// change exported; with no items it stays, so a quiet sync advances nothing.
    public static func export(items: Items, jobs: [Job], reports: (UUID) -> String?, repo: String,
                              environment: [String: String], into store: URL, now: Date,
                              log: (String) -> Void) throws -> Outcome {
        let files = FileManager.default
        let root = folder(in: store)
        for sub in ["issues", "prs", "jobs"] {
            try files.createDirectory(at: root.appendingPathComponent(sub, isDirectory: true), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
        var written = 0
        var kept: [String] = []
        func put(_ text: String, at url: URL, kind: String) throws {
            guard DispatchPlanner.redact(text, environment: environment) == text else {
                kept.append(kind)
                return
            }
            let data = Data(text.utf8)
            if let old = try? Data(contentsOf: url), old == data { return }
            try data.write(to: url, options: .atomic)
            written += 1
        }
        for issue in items.issues {
            try put(render(issue, asOf: issue.updatedAt), at: root.appendingPathComponent("issues/\(issue.number).md"), kind: "issue #\(issue.number)")
        }
        for pr in items.pullRequests {
            try put(render(pr, asOf: pr.updatedAt), at: root.appendingPathComponent("prs/\(pr.number).md"), kind: "PR #\(pr.number)")
        }
        var state = state(in: store) ?? State(updatedAt: nil, issues: 0, pullRequests: 0)
        let jobsSince = state.shape == shape ? state.jobsAt : nil
        let ended = jobs.filter { $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame && $0.status != .running }
        let fresh = Set(ended.filter { ($0.endedAt ?? $0.startedAt) > (jobsSince ?? .distantPast) }.map(\.key.item))
        let runs = Dictionary(grouping: ended.filter { fresh.contains($0.key.item) }, by: \.key.item)
        for (item, group) in runs where !item.isEmpty && !item.contains("/") && !item.hasPrefix(".") {
            let text = render(item: item, runs: group.map {
                JobRun(move: $0.key.move, agent: $0.agent, status: $0.status.rawValue, startedAt: $0.startedAt,
                       cost: $0.cost, head: $0.key.head, report: reports($0.id))
            }, asOf: group.map { $0.endedAt ?? $0.startedAt }.max() ?? now)
            try put(text, at: root.appendingPathComponent("jobs/\(item).md"), kind: "jobs on \(item)")
        }
        if !kept.isEmpty {
            log("memory: \(kept.count) not written, their text carries a value of the repo's environment: \(kept.prefix(5).joined(separator: ", "))\(kept.count > 5 ? ", ..." : "")")
        }
        state.shape = shape
        if let newest = items.newest, newest > (state.updatedAt ?? .distantPast) { state.updatedAt = newest }
        if let newest = ended.compactMap({ $0.endedAt ?? $0.startedAt }).max(), newest > (state.jobsAt ?? .distantPast) { state.jobsAt = newest }
        state.issues = count(root.appendingPathComponent("issues"))
        state.pullRequests = count(root.appendingPathComponent("prs"))
        try put(index(root), at: root.appendingPathComponent("INDEX.md"), kind: "index")
        if written > 0 || !items.issues.isEmpty || !items.pullRequests.isEmpty || !fresh.isEmpty { try writeState(state, in: store) }
        return written == 0 ? .unchanged : .written(files: written)
    }

    private static func count(_ directory: URL) -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".md") }.count
    }

    /// One line per file with its title and date: the hub graphify's communities form around.
    static func index(_ root: URL) -> String {
        var lines = ["# Memory of this repo", ""]
        for sub in ["issues", "prs", "jobs"] {
            let directory = root.appendingPathComponent(sub)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
                .filter { $0.hasSuffix(".md") }
                .sorted { (Int($0.dropLast(3)) ?? 0, $0) < (Int($1.dropLast(3)) ?? 0, $1) }
            for name in names {
                guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
                let head = text.split(separator: "\n", maxSplits: 2).map(String.init)
                let title = head.first.map { $0.hasPrefix("# ") ? String($0.dropFirst(2)) : $0 } ?? name
                let asOf = head.dropFirst().first.flatMap { $0.hasPrefix("As of ") ? String($0.dropFirst(6).prefix(10)) : nil } ?? ""
                lines.append("- memory/\(sub)/\(name): \(title)" + (asOf.isEmpty ? "" : " (updated \(asOf))"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: in a tree

    /// `memory` in a job's tree is a link to the store's folder, as `graphify-out` is to the graph:
    /// `graphify-src` resolves a file of the graph against the tree that holds `graphify-out`.
    public static func link(into worktree: URL, store: URL) throws {
        let files = FileManager.default
        let target = folder(in: store)
        try files.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = worktree.appendingPathComponent(folderName)
        if let type = try? files.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType {
            // A tree with its own `memory` (a repo's folder of that name) keeps it; the graph then
            // names files the tree has, which is the better answer anyway.
            guard type == .typeSymbolicLink else { return }
            try files.removeItem(at: path)
        }
        try files.createSymbolicLink(atPath: path.path, withDestinationPath: target.path)
        try exclude(in: worktree)
    }

    /// The build tree gets a real copy: graphify reads the files, and a link would be mapped as one entry.
    public static func copy(into worktree: URL, store: URL) throws {
        let files = FileManager.default
        let path = worktree.appendingPathComponent(folderName)
        if files.fileExists(atPath: path.path) || (try? files.destinationOfSymbolicLink(atPath: path.path)) != nil {
            try files.removeItem(at: path)
        }
        let source = folder(in: store)
        if files.fileExists(atPath: source.path) {
            try files.copyItem(at: source, to: path)
            try? files.removeItem(at: path.appendingPathComponent(stateName))
        }
        let ignore = worktree.appendingPathComponent(ignoreName)
        let text = (try? String(contentsOf: ignore, encoding: .utf8)) ?? ""
        if !text.components(separatedBy: "\n").contains(ignoreLine) {
            let joined = text.isEmpty || text.hasSuffix("\n") ? text + ignoreLine + "\n" : text + "\n" + ignoreLine + "\n"
            try joined.write(to: ignore, atomically: true, encoding: .utf8)
        }
        try exclude(in: worktree)
    }

    /// Git never sees the link, the copy or graphify's ignore file: the names go into the
    /// repository's `info/exclude`, once, so status stays clean and no agent commits them. Git reads that file from the common
    /// directory only (measured: one under `.git/worktrees/<name>/info` is ignored), so a linked
    /// worktree's `.git` file is followed to its `gitdir`, and that directory's `commondir` to the
    /// clone's `.git`; every worktree of the clone then shares the two lines.
    static func exclude(in worktree: URL) throws {
        let files = FileManager.default
        let dotGit = worktree.appendingPathComponent(".git")
        var gitDirectory = dotGit
        func resolve(_ named: String, from base: URL) -> URL {
            named.hasPrefix("/") ? URL(fileURLWithPath: named, isDirectory: true) : base.appendingPathComponent(named, isDirectory: true)
        }
        if let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir: ") {
            gitDirectory = resolve(text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines), from: worktree)
        }
        if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
            gitDirectory = resolve(common.trimmingCharacters(in: .whitespacesAndNewlines), from: gitDirectory).standardizedFileURL
        }
        var isDirectory: ObjCBool = false
        guard files.fileExists(atPath: gitDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let info = gitDirectory.appendingPathComponent("info", isDirectory: true)
        try files.createDirectory(at: info, withIntermediateDirectories: true)
        let file = info.appendingPathComponent("exclude")
        var lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        var changed = false
        for name in [folderName, CodeGraph.linkName, ignoreName] where !lines.contains(name) && !lines.contains("/\(name)") {
            if lines.last == "" { lines.removeLast() }
            lines.append(name)
            lines.append("")
            changed = true
        }
        if changed { try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8) }
    }

    // MARK: when to rebuild

    /// Why the graph is rebuilt now, nil when the one in the store still serves: no graph, the base
    /// moved once the last build is `baseRebuildInterval` old (lexito's base moves two to five
    /// times an hour and a rebuild reads the whole tree for two minutes: one per merge was three
    /// hours of CPU a day for a graph the marker dates anyway), a Bton with a new shape of graph
    /// (an upgrade rebuilds on its own, no press), or memory newer than the graph once the last
    /// build is old enough that rebuilding is not a build per comment. In that order, so the
    /// message names the first cause.
    public static func rebuildReason(marker: CodeGraph.Marker?, built: Bool, tip: String, memory: State?, now: Date) -> String? {
        guard built, let marker else { return "no graph" }
        let age = now.timeIntervalSince(marker.at)
        if marker.commit != tip, age >= CodeGraphBuilder.baseRebuildInterval { return "base moved to \(tip.prefix(8))" }
        if marker.shape != CodeGraph.shape { return "graph shape \(marker.shape.map(String.init) ?? "none") is not \(CodeGraph.shape)" }
        if let updated = memory?.updatedAt, updated > (marker.memoryAt ?? .distantPast), age >= CodeGraphBuilder.memoryRebuildInterval {
            return "memory newer than the graph"
        }
        return nil
    }
}
