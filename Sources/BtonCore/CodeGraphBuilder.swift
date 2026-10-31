import Foundation

/// Builds each repo's code graph after a sync: at most one build per repo at a time, only when
/// the branch PRs merge into moved since the last one. graphify's own code rebuild (no LLM) runs
/// in `.worktrees/bton-graph`, detached at that tip, with `graphify-out` linked to the store.
public actor CodeGraphBuilder {
    /// A full code rebuild of lexito takes minutes; Bton's sources take 2.5 s.
    public static let buildTimeout: Duration = .seconds(1800)
    public static let niceness = 10
    /// graphify's CLI has no build command: the code rebuild is a function of its `watch` module.
    public static let script = "from graphify.watch import _rebuild_code; from pathlib import Path; import sys; "
        + "sys.exit(0 if _rebuild_code(Path('.')) else 1)"
    static let item = "graph"
    static let missingPython = "graphify's Python not found; set it in Settings > Agents"

    /// A moved base rebuilds the graph once the last build is this old: a graph a few merges
    /// behind serves an agent as well (the marker names its commit), a rebuild per merge did not.
    public static let baseRebuildInterval: TimeInterval = 15 * 60
    /// Memory newer than the graph rebuilds it once the last build is this old: a sync's export
    /// lands in the files at once, the graph's index follows at most this much later.
    public static let memoryRebuildInterval: TimeInterval = 30 * 60
    /// The communities get names from the model this often, in the build that follows: a
    /// rebuild keeps the names it can match and names the rest after their biggest node.
    public static let labelInterval: TimeInterval = 24 * 60 * 60
    /// `graphify label` on lexito (49,500 nodes, 3,707 communities): 12 minutes, claude -p with
    /// haiku naming 100 communities a call, four calls at a time.
    public static let labelTimeout: Duration = .seconds(2400)
    /// The model `claude -p` names communities with: a name per community, nothing to reason about.
    public static let labelModel = "haiku"

    private let home: BtonHome
    private let runner: ProcessRunner
    /// Where the claude CLI is when `graphify label` runs, looked up then: nil skips the names.
    private let claude: @Sendable () -> String?
    /// Whose reports go into the memory; nil exports issues and PRs only.
    private let jobs: JobStore?
    private let log: @Sendable (String) -> Void
    private var running: [String: Task<Void, Never>] = [:]
    /// The last reason a repo's build was skipped, so the log says it once, not every sync.
    private var skipped: [String: String] = [:]
    /// The last reason a repo's memory was not refreshed, said once too.
    private var memoryProblems: [String: String] = [:]
    /// The last reason a repo's communities were not named, said once too.
    private var labelProblems: [String: String] = [:]
    /// One grammar check per Python a session, which every build with that Python awaits: a
    /// second repo's build does not start while the first is still installing the grammar.
    private var grammarChecks: [String: Task<Void, Never>] = [:]

    public init(home: BtonHome, runner: ProcessRunner = ProcessRunner(), jobs: JobStore? = nil,
                claude: @escaping @Sendable () -> String? = { Executables.resolve("claude") },
                log: @escaping @Sendable (String) -> Void) {
        self.home = home
        self.runner = runner
        self.jobs = jobs
        self.claude = claude
        self.log = log
    }

    public func isBuilding(_ slug: String) -> Bool { running[slug.lowercased()] != nil }

    /// Awaits every build in flight.
    public func waitForBuilds() async {
        for task in running.values { await task.value }
    }

    /// Returns at once; the build, when one is due, runs on its own and logs how it ended.
    public func refresh(repo: WatchedRepo, branch: String, python: String?, ghPath: String) {
        let key = repo.slug.lowercased()
        guard repo.buildsGraph, let path = repo.path, running[key] == nil else { return }
        guard let python else { return skip(key, slug: repo.slug, Self.missingPython) }
        skipped[key] = nil
        let clone = URL(fileURLWithPath: path, isDirectory: true)
        let store = CodeGraph.store(for: repo.slug, home: home)
        running[key] = Task { [runner, log, jobs, claude, slug = repo.slug, environment = repo.environment ?? [:]] in
            do {
                await self.checkSQLGrammar(python: python, slug: slug)
                try await Self.build(slug: slug, clone: clone, branch: branch, store: store, python: python, ghPath: ghPath,
                                     jobs: jobs, environment: environment, claude: claude, runner: runner, log: log,
                                     memoryProblem: { await self.memoryNotRefreshed(key, slug: slug, $0) },
                                     labelProblem: { await self.notLabeled(key, slug: slug, $0) })
            } catch {
                log("graph \(slug): build failed: \(error.localizedDescription)")
            }
            await self.finished(key)
        }
    }

    private func finished(_ key: String) { running[key] = nil }

    private func skip(_ key: String, slug: String, _ reason: String) {
        guard skipped[key] != reason else { return }
        skipped[key] = reason
        log("graph \(slug): \(reason)")
    }

    /// graphify without its SQL grammar skips every `.sql` file with a warning per build. Once a
    /// session, before the first build with a Python: the grammar is probed, added to a venv Bton
    /// made itself, and for any other Python the log names the command once.
    private func checkSQLGrammar(python: String, slug: String) async {
        if let check = grammarChecks[python] { return await check.value }
        let check = Task { await self.probeSQLGrammar(python: python, slug: slug) }
        grammarChecks[python] = check
        await check.value
    }

    private func probeSQLGrammar(python: String, slug: String) async {
        let probe = try? await runner.run(python, ["-c", CodeGraph.sqlGrammarProbe], timeout: .seconds(60))
        guard probe?.status != 0 else { return }
        guard let step = CodeGraph.sqlGrammarInstallStep(python: python) else {
            log("graph \(slug): graphify at \(python) has no SQL grammar, .sql files stay out of the graph; "
                + "add it with: \(python) -m pip install '\(CodeGraph.installPackage)' (uv pip install --python for a uv venv)")
            return
        }
        log("graph \(slug): adding graphify's SQL grammar to ~/\(CodeGraph.installVenv)")
        do {
            let result = try await runner.run(step[0], Array(step.dropFirst()), timeout: .seconds(600))
            guard result.status == 0 else {
                log("graph \(slug): SQL grammar not installed (exit \(result.status)): \(String(result.stderr.suffix(200)))")
                return
            }
            log("graph \(slug): SQL grammar installed; .sql files join the graph at the next build")
        } catch {
            log("graph \(slug): SQL grammar not installed: \(error.localizedDescription)")
        }
    }

    private func memoryNotRefreshed(_ key: String, slug: String, _ reason: String?) {
        guard memoryProblems[key] != reason else { return }
        memoryProblems[key] = reason
        if let reason { log("graph \(slug): memory not refreshed: \(reason)") }
    }

    private func notLabeled(_ key: String, slug: String, _ reason: String?) {
        guard labelProblems[key] != reason else { return }
        labelProblems[key] = reason
        if let reason { log("graph \(slug): communities not named: \(reason)") }
    }

    /// The graph is built in a copy of the store and published by a swap, so a build that fails
    /// half-way, or is stopped, leaves the graph every job reads as it was.
    private static func build(slug: String, clone: URL, branch: String, store: URL, python: String, ghPath: String,
                              jobs: JobStore?, environment: [String: String], claude: @Sendable () -> String?,
                              runner: ProcessRunner, log: @escaping @Sendable (String) -> Void,
                              memoryProblem: @Sendable (String?) async -> Void,
                              labelProblem: @Sendable (String?) async -> Void) async throws {
        let worktree = try await Worktrees.prepare(clone: clone, branch: branch, item: item, ghPath: ghPath, runner: runner)
        // The tree's own commit, not the remote ref: a dispatch fetching beside this build moves the ref.
        let tip = try await Worktrees.head(of: worktree, ghPath: ghPath, runner: runner)
        // Every sync: what changed on GitHub since the last one goes into the memory's files now,
        // whether or not the graph is rebuilt, so a job's query lands on the current file.
        let memory = await refreshMemory(slug: slug, store: store, ghPath: ghPath, jobs: jobs, environment: environment,
                                         log: log, problem: memoryProblem)
        guard let reason = GraphMemory.rebuildReason(marker: CodeGraph.marker(in: store), built: CodeGraph.isBuilt(store),
                                                     tip: tip, memory: memory, now: .now) else { return }
        switch try CodeGraph.link(into: clone, store: store) {
        case .moved: log("graph \(slug): moved \(clone.path)/\(CodeGraph.linkName) into \(store.path)")
        case let .kept(reason): log("graph \(slug): \(clone.path): \(reason)")
        case .linked, .alreadyLinked: break
        }
        let staging = try stage(store)
        guard try point(worktree, at: staging) else {
            log("graph \(slug): not built: \(worktree.path)/\(CodeGraph.linkName) is a file or directory of the tree")
            return
        }
        // graphify reads the memory as files of the tree, a real copy (a link would be one entry).
        try GraphMemory.copy(into: worktree, store: store)
        let started = Date.now
        let buildLog = try BuildLog(at: staging.appendingPathComponent(CodeGraph.buildLogName))
        do {
            let result = try await runner.run("/usr/bin/nice", ["-n", String(niceness), python, "-c", script], in: worktree,
                                              environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: buildTimeout,
                                              output: { buildLog.append($0) })
            guard result.status == 0, CodeGraph.isBuilt(staging) else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BuildFailure.exited(result.status, String(stderr.suffix(200)))
            }
            let previous = CodeGraph.marker(in: store)
            var labeledAt = previous?.labeledAt, labelTriedAt = previous?.labelTriedAt
            let labelsExist = FileManager.default.fileExists(atPath: staging.appendingPathComponent(CodeGraph.labelsName).path)
            if let why = CodeGraph.labelReason(marker: previous, labelsExist: labelsExist, now: .now) {
                switch await label(slug: slug, staging: staging, store: store, python: python, claude: claude(), reason: why,
                                   runner: runner, buildLog: buildLog, log: log, problem: labelProblem) {
                case let .named(at): labeledAt = at; labelTriedAt = at
                case let .failed(at): labelTriedAt = at
                case .skipped: break
                }
            }
            // The marker travels with its graph: a reader never sees one generation's graph with another's marker.
            try CodeGraph.writeMarker(.init(commit: tip, at: .now, shape: CodeGraph.shape, memoryAt: memory?.updatedAt,
                                            labeledAt: labeledAt, labelTriedAt: labelTriedAt), in: staging)
            try publish(staging, as: store)
            log("graph \(slug): built at \(tip.prefix(8)) in \(Int(Date.now.timeIntervalSince(started)))s (\(reason))")
        } catch ProcessRunner.Failure.timedOut {
            log("graph \(slug): build timed out after \(Int(buildTimeout.components.seconds / 60)) minutes")
        } catch let BuildFailure.exited(status, stderr) {
            log("graph \(slug): build failed (exit \(status)): \(stderr)")
        }
        try? FileManager.default.removeItem(at: staging)
        // Whatever happened, the tree reads the published graph, like every other checkout.
        if CodeGraph.isBuilt(store) { _ = try point(worktree, at: store) }
    }

    /// `graphify label` on the staging graph: claude -p names every community, and graphify
    /// rewrites graph.json, the report and the page with the names. Run from a directory that
    /// holds only a link to the staging, so claude reads no checkout's instructions, and its
    /// output goes to the build log. A run that fails counts as tried: the next one waits the
    /// interval (a 15-minute rebuild cadence must not repeat a 12-minute failure every time);
    /// a skip for a missing tool costs nothing and does not.
    private enum Labeling {
        case named(Date), failed(Date), skipped
    }

    private static func label(slug: String, staging: URL, store: URL, python: String, claude: String?, reason: String,
                              runner: ProcessRunner, buildLog: BuildLog, log: @escaping @Sendable (String) -> Void,
                              problem: @Sendable (String?) async -> Void) async -> Labeling {
        guard let claude else {
            await problem("the claude CLI is not on PATH")
            return .skipped
        }
        let cli = CodeGraph.cli(python: python)
        guard FileManager.default.isExecutableFile(atPath: cli) else {
            await problem("graphify's CLI not found at \(cli)")
            return .skipped
        }
        await problem(nil)
        let files = FileManager.default
        let room = URL(fileURLWithPath: store.path + ".label", isDirectory: true)
        defer { try? files.removeItem(at: room) }
        let started = Date.now
        do {
            try? files.removeItem(at: room)
            try files.createDirectory(at: room, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try files.createSymbolicLink(atPath: room.appendingPathComponent(CodeGraph.linkName).path, withDestinationPath: staging.path)
            buildLog.append(Data("\n\(CodeGraph.namingLine) (\(reason))\n".utf8))
            // The model goes on the command line: graphify's labeler reads no model from the
            // environment (its extraction does), and claude -p without one runs the account's default.
            let result = try await runner.run("/usr/bin/nice", ["-n", String(niceness), cli, "label", "--backend=claude-cli", "--model=\(labelModel)"],
                                              in: room, environment: ["GIT_TERMINAL_PROMPT": "0", "PATH": Executables.searchPath(for: claude)],
                                              timeout: labelTimeout, output: { buildLog.append($0) })
            guard result.status == 0 else {
                log("graph \(slug): communities not named (exit \(result.status)): \(String(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200)))")
                return .failed(started)
            }
            log("graph \(slug): communities named in \(Int(Date.now.timeIntervalSince(started)))s (\(reason))")
            return .named(started)
        } catch ProcessRunner.Failure.timedOut {
            log("graph \(slug): naming the communities timed out after \(Int(labelTimeout.components.seconds / 60)) minutes")
        } catch {
            log("graph \(slug): communities not named: \(error.localizedDescription)")
        }
        return .failed(started)
    }

    /// GitHub's changes since the state's time into the store's memory, with this Mac's job
    /// reports; a read that fails keeps the previous files and time (the agent is told how far
    /// the memory goes) and is said once. Returns how far the memory goes now.
    private static func refreshMemory(slug: String, store: URL, ghPath: String, jobs: JobStore?, environment: [String: String],
                                      log: @escaping @Sendable (String) -> Void,
                                      problem: @Sendable (String?) async -> Void) async -> GraphMemory.State? {
        let since = GraphMemory.state(in: store)?.since
        do {
            let items = try await GitHubClient(ghPath: ghPath).memoryItems(repo: slug, since: since, now: .now)
            let outcome = try GraphMemory.export(items: items, jobs: jobs?.all() ?? [], reports: { id in
                jobs.flatMap { report(at: $0.outputURL(id)) }
            }, repo: slug, environment: environment, into: store, now: .now, log: { log("graph \(slug): \($0)") })
            if case let .written(files) = outcome {
                log("graph \(slug): memory refreshed: \(files) files for \(items.issues.count) issues and \(items.pullRequests.count) PRs changed")
            }
            await problem(nil)
        } catch {
            await problem(error.localizedDescription)
        }
        return GraphMemory.state(in: store)
    }

    /// The agent's final message, as the session page shows it.
    private static func report(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data.prefix(16_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private enum BuildFailure: Error {
        case exited(Int32, String)
    }

    /// graphify's output as it comes, both pipes into one file the page reads for the progress.
    private final class BuildLog: Sendable {
        private let handle: FileHandle
        private let lock = NSLock()

        init(at url: URL) throws {
            try Data().write(to: url)
            handle = try FileHandle(forWritingTo: url)
        }

        func append(_ data: Data) {
            lock.withLock { try? handle.write(contentsOf: data) }
        }

        deinit { try? handle.close() }
    }

    /// A fresh copy of the store beside it (a clone on APFS, so no slower for a large one), for
    /// the build to write into; graphify's cache and memory come along.
    private static func stage(_ store: URL) throws -> URL {
        let files = FileManager.default
        let staging = URL(fileURLWithPath: store.path + ".next", isDirectory: true)
        try? files.removeItem(at: staging)
        if files.fileExists(atPath: store.path) {
            try files.copyItem(at: store, to: staging)
        } else {
            try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return staging
    }

    /// The staging takes the store's name in one rename, so there is no moment without a store
    /// (a job linking its worktree then would make an empty one in the way) and no moment with
    /// half of one; every checkout's link points at the name and sees the new graph at once.
    private static func publish(_ staging: URL, as store: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: store.path) {
            _ = try files.replaceItemAt(store, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: store)
        }
    }

    /// Makes the build tree's `graphify-out` a link to `target`, replacing a link of ours. False
    /// when the tree has a file or directory of its own there: the build would write elsewhere.
    private static func point(_ worktree: URL, at target: URL) throws -> Bool {
        let files = FileManager.default
        let path = worktree.appendingPathComponent(CodeGraph.linkName)
        if let type = try? files.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType {
            guard type == .typeSymbolicLink else { return false }
            try files.removeItem(at: path)
        }
        return try CodeGraph.link(into: worktree, store: target) == .linked
    }
}
