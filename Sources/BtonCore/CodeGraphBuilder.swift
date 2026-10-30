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

    /// Memory newer than the graph rebuilds it once the last build is this old: a sync's export
    /// lands in the files at once, the graph's index follows at most this much later.
    public static let memoryRebuildInterval: TimeInterval = 30 * 60

    private let home: BtonHome
    private let runner: ProcessRunner
    /// Whose reports go into the memory; nil exports issues and PRs only.
    private let jobs: JobStore?
    private let log: @Sendable (String) -> Void
    private var running: [String: Task<Void, Never>] = [:]
    /// The last reason a repo's build was skipped, so the log says it once, not every sync.
    private var skipped: [String: String] = [:]
    /// The last reason a repo's memory was not refreshed, said once too.
    private var memoryProblems: [String: String] = [:]

    public init(home: BtonHome, runner: ProcessRunner = ProcessRunner(), jobs: JobStore? = nil,
                log: @escaping @Sendable (String) -> Void) {
        self.home = home
        self.runner = runner
        self.jobs = jobs
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
        running[key] = Task { [runner, log, jobs, slug = repo.slug, environment = repo.environment ?? [:]] in
            do {
                try await Self.build(slug: slug, clone: clone, branch: branch, store: store, python: python, ghPath: ghPath,
                                     jobs: jobs, environment: environment, runner: runner, log: log,
                                     memoryProblem: { await self.memoryNotRefreshed(key, slug: slug, $0) })
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

    private func memoryNotRefreshed(_ key: String, slug: String, _ reason: String?) {
        guard memoryProblems[key] != reason else { return }
        memoryProblems[key] = reason
        if let reason { log("graph \(slug): memory not refreshed: \(reason)") }
    }

    /// The graph is built in a copy of the store and published by a swap, so a build that fails
    /// half-way, or is stopped, leaves the graph every job reads as it was.
    private static func build(slug: String, clone: URL, branch: String, store: URL, python: String, ghPath: String,
                              jobs: JobStore?, environment: [String: String], runner: ProcessRunner,
                              log: @escaping @Sendable (String) -> Void,
                              memoryProblem: @Sendable (String?) async -> Void) async throws {
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
            // The marker travels with its graph: a reader never sees one generation's graph with another's marker.
            try CodeGraph.writeMarker(.init(commit: tip, at: .now, shape: CodeGraph.shape, memoryAt: memory?.updatedAt), in: staging)
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
