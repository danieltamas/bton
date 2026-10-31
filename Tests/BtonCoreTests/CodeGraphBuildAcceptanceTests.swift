@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CodeGraphBuildAcceptanceTests {
    @Test func buildsAtTipAndWritesMarker() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.clone.appendingPathComponent("graphify-out").path) == f.store.path)
        let tree = f.clone.appendingPathComponent(".worktrees/bton-graph")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tree.appendingPathComponent("graphify-out").path) == f.store.path)
        #expect(try String(contentsOf: f.root.appendingPathComponent("python-head"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == f.tip)
        let argv = try String(contentsOf: f.root.appendingPathComponent("python-argv"), encoding: .utf8)
        #expect(argv == "-c\nfrom graphify.watch import _rebuild_code; from pathlib import Path; import sys; sys.exit(0 if _rebuild_code(Path('.')) else 1)\n")
        #expect(CodeGraphBuilder.buildTimeout == .seconds(1800))
        #expect(CodeGraphBuilder.niceness == 10)
    }

    @Test func unchangedTipDoesNotRebuild() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == 1)
        let marker = try Data(contentsOf: f.store.appendingPathComponent("bton-build.json"))
        let runs = try f.pythonRuns()
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == runs)
        #expect(try Data(contentsOf: f.store.appendingPathComponent("bton-build.json")) == marker)
    }

    @Test func secondRefreshWhileBuildingStartsNothing() async throws {
        let f = try await GraphFixture.make(python: .sleeps(seconds: 3))
        defer { f.remove() }
        await f.refresh()
        let building = await f.builder.isBuilding(f.repo.slug)
        #expect(building)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == 1)
        #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
        #expect(await f.builder.isBuilding(f.repo.slug) == false)
    }

    @Test func failedBuildKeepsPreviousMarker() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        // A moved base rebuilds once the last build is the base interval old: the first is dated so.
        let built = try #require(CodeGraph.marker(in: f.store))
        try CodeGraph.writeMarker(.init(commit: built.commit, at: built.at - CodeGraphBuilder.baseRebuildInterval,
                                        shape: built.shape, memoryAt: built.memoryAt), in: f.store)
        let first = try Data(contentsOf: f.store.appendingPathComponent("bton-build.json"))
        let nextTip = try await f.commitOnOrigin("second")
        #expect(nextTip != f.tip)
        try f.setPython(.partialThenFails)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try Data(contentsOf: f.store.appendingPathComponent("bton-build.json")) == first)
        #expect(f.log.contains { $0.hasPrefix("graph \(f.repo.slug): build failed") })
        let failedRuns = try f.pythonRuns()
        #expect(failedRuns == 2)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == failedRuns + 1)
        #expect(try Data(contentsOf: f.store.appendingPathComponent("bton-build.json")) == first)
        try f.setPython(.succeeds)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(CodeGraph.marker(in: f.store)?.commit == nextTip)
    }

    @Test func missingPythonLogsOnceAndSkips() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.builder.refresh(repo: f.repo, branch: "main", python: nil, ghPath: f.gh)
        await f.builder.refresh(repo: f.repo, branch: "main", python: nil, ghPath: f.gh)
        await f.builder.waitForBuilds()
        #expect(f.log.filter { $0 == "graph \(f.repo.slug): graphify's Python not found; set it in Settings > Agents" }.count == 1)
        #expect(!CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store) == nil)
        #expect(try f.pythonRuns() == 0)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(CodeGraph.isBuilt(f.store))
    }

    @Test func switchOffBuildsNothing() async throws {
        let f = try await GraphFixture.make(python: .succeeds, codeGraph: false)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == 0)
        #expect(CodeGraph.marker(in: f.store) == nil)
        #expect(!CodeGraph.isBuilt(f.store))
    }

    @Test func engineTickStartsBuilderForSwitchedOnRepos() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        // Reuse the Engine acceptance fixture's GitHub responses, with this test's real clone.
        let responses = try await StartMovesFixture.make()
        defer { responses.remove() }
        let ghURL = f.root.appendingPathComponent("gh")
        try String(contentsOf: responses.root.appendingPathComponent("gh"), encoding: .utf8)
            .write(to: ghURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ghURL.path)
        var config = BtonConfig.initial
        config.repos = [f.repo]
        config.graphifyPython = f.python
        try config.save(to: f.home.configURL)
        try PriceList(models: [:], updatedAt: .now).save(home: f.home)
        let engine = try Engine(home: f.home, github: GitHubClient(ghPath: ghURL.path), log: { _ in })
        let snapshot = await engine.tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.unread.isEmpty)
        #expect(snapshot.jobs.isEmpty)
        await engine.waitForGraphBuilds()
        #expect(CodeGraph.isBuilt(f.store))
        #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
        #expect(try f.pythonRuns() == 1)
    }
}

// Shared only by these graph acceptance tests. Initial Git repositories come from the
// existing cached fixtures; every test owns its copy, executable, store, and processes.
struct GraphFixture {
    enum PythonBehavior {
        case succeeds, sleeps(seconds: Int), partialThenFails
    }

    let base: SupervisionRunFixture
    let repo: WatchedRepo
    let tip: String
    let builder: CodeGraphBuilder
    let messages: GraphMessages
    var root: URL { base.leases.root }
    var clone: URL { base.clone }
    var home: BtonHome { base.home }
    var store: URL { CodeGraph.store(for: repo.slug, home: home) }
    var python: String { root.appendingPathComponent("python").path }
    var gh: String { "/usr/bin/true" }
    var log: [String] { messages.lines }

    static func make(python: PythonBehavior, codeGraph: Bool = true, claude: String? = "/usr/bin/true") async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            var repo = WatchedRepo(slug: base.leases.repo, path: base.clone.path)
            repo.codeGraph = codeGraph
            let tip = try await git(["rev-parse", "HEAD"], in: base.clone)
            let messages = GraphMessages()
            // A claude that exists on every Mac: the naming step reaches the graphify CLI check, not PATH.
            let builder = CodeGraphBuilder(home: base.home, claude: { claude }, log: { messages.append($0) })
            let f = Self(base: base, repo: repo, tip: tip, builder: builder, messages: messages)
            try f.setPython(python)
            return f
        } catch {
            try? FileManager.default.removeItem(at: base.leases.root)
            throw error
        }
    }

    func refresh() async {
        await builder.refresh(repo: repo, branch: "main", python: python, ghPath: gh)
    }

    func setPython(_ behavior: PythonBehavior) throws {
        let action: String
        switch behavior {
        case .succeeds: action = "printf '%s\\n' '{}' > graphify-out/graph.json"
        case let .sleeps(seconds): action = "sleep \(seconds)\nprintf '%s\\n' '{}' > graphify-out/graph.json"
        case .partialThenFails: action = "printf '%s' '{partial' > graphify-out/graph.json\necho 'synthetic partial build failure' >&2\nexit 1"
        }
        let script = """
        #!/bin/sh
        set -eu
        # The SQL grammar probe, once a session before the first build: this Python has it.
        [ "${2:-}" = '\(CodeGraph.sqlGrammarProbe)' ] && exit 0
        printf 'run\\n' >> '\(root.appendingPathComponent("python-runs").path)'
        printf '%s\\n' "$@" > '\(root.appendingPathComponent("python-argv").path)'
        /usr/bin/git rev-parse HEAD > '\(root.appendingPathComponent("python-head").path)'
        \(action)
        """
        try script.write(toFile: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: python)
    }

    func pythonRuns() throws -> Int {
        let file = root.appendingPathComponent("python-runs")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").count
    }

    @discardableResult
    func commitOnOrigin(_ message: String) async throws -> String {
        try await Self.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message], in: clone)
        try await Self.git(["push", "origin", "HEAD:refs/heads/main"], in: clone)
        return try await Self.git(["rev-parse", "HEAD"], in: clone)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(30))
        try #require(result.status == 0, "git \(arguments): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

final class GraphMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ line: String) { lock.lock(); defer { lock.unlock() }; storage.append(line) }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}
