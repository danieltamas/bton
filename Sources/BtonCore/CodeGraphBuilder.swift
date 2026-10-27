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

    private let home: BtonHome
    private let runner: ProcessRunner
    private let log: @Sendable (String) -> Void
    private var running: [String: Task<Void, Never>] = [:]
    /// The last reason a repo's build was skipped, so the log says it once, not every sync.
    private var skipped: [String: String] = [:]

    public init(home: BtonHome, runner: ProcessRunner = ProcessRunner(), log: @escaping @Sendable (String) -> Void) {
        self.home = home
        self.runner = runner
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
        running[key] = Task { [runner, log, slug = repo.slug] in
            do {
                try await Self.build(slug: slug, clone: clone, branch: branch, store: store, python: python, ghPath: ghPath,
                                     runner: runner, log: log)
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

    /// The graph is built in a copy of the store and published by a swap, so a build that fails
    /// half-way, or is stopped, leaves the graph every job reads as it was.
    private static func build(slug: String, clone: URL, branch: String, store: URL, python: String, ghPath: String,
                              runner: ProcessRunner, log: @escaping @Sendable (String) -> Void) async throws {
        let worktree = try await Worktrees.prepare(clone: clone, branch: branch, item: item, ghPath: ghPath, runner: runner)
        // The tree's own commit, not the remote ref: a dispatch fetching beside this build moves the ref.
        let tip = try await Worktrees.head(of: worktree, ghPath: ghPath, runner: runner)
        if CodeGraph.marker(in: store)?.commit == tip, CodeGraph.isBuilt(store) { return }
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
        let started = Date.now
        do {
            let result = try await runner.run("/usr/bin/nice", ["-n", String(niceness), python, "-c", script], in: worktree,
                                              environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: buildTimeout)
            guard result.status == 0, CodeGraph.isBuilt(staging) else {
                let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                throw BuildFailure.exited(result.status, String(stderr.suffix(200)))
            }
            // The marker travels with its graph: a reader never sees one generation's graph with another's marker.
            try CodeGraph.writeMarker(.init(commit: tip, at: .now), in: staging)
            try publish(staging, as: store)
            log("graph \(slug): built at \(tip.prefix(8)) in \(Int(Date.now.timeIntervalSince(started)))s")
        } catch ProcessRunner.Failure.timedOut {
            log("graph \(slug): build timed out after \(Int(buildTimeout.components.seconds / 60)) minutes")
        } catch let BuildFailure.exited(status, stderr) {
            log("graph \(slug): build failed (exit \(status)): \(stderr)")
        }
        try? FileManager.default.removeItem(at: staging)
        // Whatever happened, the tree reads the published graph, like every other checkout.
        if CodeGraph.isBuilt(store) { _ = try point(worktree, at: store) }
    }

    private enum BuildFailure: Error {
        case exited(Int32, String)
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
