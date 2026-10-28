@testable import BtonCore
import Foundation
import Testing

/// A store with a graph in it, as a finished build leaves one.
enum RegistryGateFixture {
    static func buildGraph(repo: String, home: BtonHome) throws {
        let store = CodeGraph.store(for: repo, home: home)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.appendingPathComponent("graph.json"))
        try CodeGraph.writeMarker(CodeGraph.Marker(commit: "abc", at: .now), in: store)
    }
}

/// The registry job draws its areas from the code graph, so it waits for one (2026-10-28).
struct RegistryGateTests {
    private func home() throws -> (home: BtonHome, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (BtonHome(environment: ["BTON_HOME": root.path]), root)
    }

    @Test func readinessFollowsTheSwitchThePythonAndTheStore() throws {
        let (home, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        var repo = WatchedRepo(slug: "owner/repo", path: root.path)
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/python3", home: home) == .off)
        repo.codeGraph = true
        #expect(CodeGraph.readiness(of: repo, python: nil, home: home) == .missingPython)
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/python3", home: home) == .building)
        // A graph moved in from a clone, no build here yet: the worktree would not get it linked.
        let store = CodeGraph.store(for: repo.slug, home: home)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: store.appendingPathComponent("graph.json"))
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/python3", home: home) == .building)
        try RegistryGateFixture.buildGraph(repo: repo.slug, home: home)
        #expect(CodeGraph.readiness(of: repo, python: nil, home: home) == .ready)
        #expect(CodeGraph.readiness(of: repo, python: "/usr/bin/python3", home: home) == .ready)
    }

    @Test func progressFollowsTheExtractionCountThenTheGrouping() throws {
        #expect(CodeGraph.progress(from: "") == .init(step: "Preparing the tree", fraction: nil))
        #expect(CodeGraph.progress(from: "[graphify watch] starting\n") == .init(step: "Preparing the tree", fraction: nil))
        let reading = "  AST extraction: 100/1930 uncached files (5%) [10 workers]\n  AST extraction: 400/1930 uncached files (20%) [10 workers]\n"
        let half = try #require(CodeGraph.progress(from: reading).fraction)
        #expect(abs(half - 400.0 / 1930) < 0.001)
        #expect(CodeGraph.progress(from: reading).step == "Reading 400 of 1930 files")
        #expect(CodeGraph.progress(from: reading + "  AST extraction: 1930/1930 uncached files (100%)\n").fraction == nil)
        let grouping = CodeGraph.progress(from: reading + "  warning: 1 file had syntax errors\n")
        #expect(grouping == .init(step: "Grouping the code into modules", fraction: nil))
        #expect(CodeGraph.progress(from: "AST extraction: 0/0 files\n").fraction == nil)
        #expect(CodeGraph.progress(from: "  AST extraction: 1/10 files\r  AST extraction: 2/10 files").step == "Reading 2 of 10 files")
        let (home, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodeGraph.store(for: "owner/repo", home: home)
        #expect(CodeGraph.progress(in: store) == nil)
        let staging = URL(fileURLWithPath: store.path + ".next", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(reading.utf8).write(to: staging.appendingPathComponent("bton-build.log"))
        #expect(CodeGraph.progress(in: store)?.step == "Reading 400 of 1930 files")
    }

    @Test func onlyReadyRunsAndEveryHoldNamesWhereToFixIt() {
        #expect(CodeGraph.Readiness.ready.hold == nil)
        #expect(CodeGraph.Readiness.off.hold?.contains("Settings > Repos") == true)
        #expect(CodeGraph.Readiness.missingPython.hold?.contains("Settings > Agents") == true)
        #expect(CodeGraph.Readiness.building.hold?.contains("built") == true)
    }

    @Test func theOpenRegistryPRIsMineOnThePrefixedBranch() {
        func pr(author: String, head: String, repo: String = "Owner/Repo") -> PullRequest {
            PullRequest(repo: repo, number: 9, title: "features: 1 added, 2 linked", author: author, authorAssociation: "OWNER",
                        url: URL(string: "https://example.invalid/pr/9")!, headSha: "s", headRef: head, baseRef: "main",
                        body: "", isDraft: false, labels: [], assignees: [], comments: [], updatedAt: .now)
        }
        let prs = [pr(author: "me", head: "feature"), pr(author: "other", head: "bton/features-20261028-0757"),
                   pr(author: "me", head: "bton/features-20261028-0757", repo: "owner/other"), pr(author: "Me", head: "bton/features-20261028-0757")]
        #expect(FeatureJob.openPullRequest(prs, repo: "owner/repo", me: "me")?.author == "Me")
        #expect(FeatureJob.openPullRequest(Array(prs.prefix(3)), repo: "owner/repo", me: "me") == nil)
    }
}

@Suite(ProcessBound())
struct RegistryGateEngineTests {
    /// A press before the graph is built stays in line with the reason and starts nothing;
    /// once the graph is there, the same press starts the job.
    @Test func pressedRegistryWaitsForTheGraphThenStarts() async throws {
        let f = try await StartMovesFixture.make(startMoves: false)
        defer { f.remove() }
        var config = try JSONDecoder().decode(BtonConfig.self, from: Data(contentsOf: f.home.configURL))
        config.repos[0].work = "synthetic"
        try config.save(to: f.home.configURL)
        let engine = try f.engine()
        await engine.runNext(repo: f.repo, item: "features", pressed: true)
        let off = await engine.tick()
        #expect(off.problem == nil)
        #expect(!off.jobs.contains { $0.key.move == "features" })
        let pick = "\(f.repo.lowercased())#features"
        #expect(off.next.contains(pick))
        #expect(off.waiting[pick]?.contains("code graph") == true)

        config.repos[0].codeGraph = true
        try config.save(to: f.home.configURL)
        let building = await engine.tick()
        #expect(!building.jobs.contains { $0.key.move == "features" })
        #expect(building.next.contains(pick))
        #expect(building.waiting[pick] != nil)

        try RegistryGateFixture.buildGraph(repo: f.repo, home: f.home)
        let ready = await engine.tick()
        #expect(ready.problem == nil)
        let started = ready.jobs.filter { $0.key.move == "features" }
        #expect(started.count == 1)
        #expect(started.first?.pressed == true)
        #expect(!ready.next.contains(pick))
        try await f.waitForJobs()
    }
}

/// The store is ready at planning but the tree already has a `graphify-out` of its own: a job
/// that needs the graph fails instead of running without it, where another job goes on.
struct RegistryGateDispatchTests {
    @Test(ProcessBound(), arguments: [false, true])
    func unlinkableGraphFailsOnlyTheJobThatNeedsIt(needsGraph: Bool) async throws {
        let f = try await GraphDispatchFixture.make(occupiedDirectory: false)
        defer { f.graph.remove() }
        let job = try await f.run(needsGraph: needsGraph)
        #expect(job.status == (needsGraph ? .failed : .succeeded), Comment(rawValue: job.detail ?? ""))
        #expect((job.detail?.contains("code graph") ?? false) == needsGraph)
    }
}
