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

    private static func build(slug: String, clone: URL, branch: String, store: URL, python: String, ghPath: String,
                              runner: ProcessRunner, log: @escaping @Sendable (String) -> Void) async throws {
        let worktree = try await Worktrees.prepare(clone: clone, branch: branch, item: item, ghPath: ghPath, runner: runner)
        let tip = try await Worktrees.tip(of: branch, clone: clone, ghPath: ghPath, runner: runner)
        if CodeGraph.marker(in: store)?.commit == tip, CodeGraph.isBuilt(store) { return }
        for checkout in [clone, worktree] {
            switch try CodeGraph.link(into: checkout, store: store) {
            case .moved: log("graph \(slug): moved \(checkout.path)/\(CodeGraph.linkName) into \(store.path)")
            case let .kept(reason): log("graph \(slug): \(checkout.path): \(reason)")
            case .linked, .alreadyLinked: break
            }
        }
        let started = Date.now
        let result: ProcessOutput
        do {
            result = try await runner.run("/usr/bin/nice", ["-n", String(niceness), python, "-c", script], in: worktree,
                                          environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: buildTimeout)
        } catch ProcessRunner.Failure.timedOut {
            log("graph \(slug): build timed out after \(Int(buildTimeout.components.seconds / 60)) minutes")
            return
        }
        guard result.status == 0, CodeGraph.isBuilt(store) else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            log("graph \(slug): build failed (exit \(result.status)): \(stderr.suffix(200))")
            return
        }
        try CodeGraph.writeMarker(.init(commit: tip, at: .now), in: store)
        log("graph \(slug): built at \(tip.prefix(8)) in \(Int(Date.now.timeIntervalSince(started)))s")
    }
}
