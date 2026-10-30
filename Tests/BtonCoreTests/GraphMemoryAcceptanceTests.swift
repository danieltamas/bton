@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct GraphMemoryAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_793_365_500) // Whole seconds survive ISO encoding.
    private static let repo = "synthetic/repo"

    @Test func renderIssueKeepsDecisionHeadingVerbatim() {
        let text = GraphMemory.render(Self.issue(), asOf: Self.now)
        #expect(text.hasPrefix("# #1 T\n"))
        #expect(text.contains("As of \(Self.minute(Self.now)). State: OPEN. Labels: stage:ready."))
        #expect(text.contains("\n## Decision: ship it\n\nbecause"))
    }

    @Test func exportWritesFourKindsAndState() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        let job = Job(id: UUID(), key: JobKey(repo: Self.repo, item: "pr-2", move: "review", head: "abcdef012345"),
                      agent: "synthetic", startedAt: Self.now, status: .succeeded, cost: Decimal(1))
        let result = try GraphMemory.export(items: Self.items(), jobs: [job], reports: { id in
            id == job.id ? "Accepted the design" : nil
        }, repo: Self.repo, environment: [:], into: store, now: Self.now, log: { _ in })
        #expect(result == .written(files: 4))
        for path in ["issues/1.md", "prs/2.md", "jobs/pr-2.md", "INDEX.md"] {
            #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("memory/" + path).path))
        }
        #expect(try Self.read(store.appendingPathComponent("memory/jobs/pr-2.md")).contains("Accepted the design"))
        let state = try #require(GraphMemory.state(in: store))
        #expect(state.updatedAt == Self.now)
        #expect(state.issues == 1)
        #expect(state.pullRequests == 1)
    }

    @Test func exportUnchangedRewritesNothing() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        _ = try Self.export(Self.items(), into: store)
        let file = store.appendingPathComponent("memory/issues/1.md")
        // A sentinel avoids relying on the filesystem clock's timestamp resolution.
        let sentinel = Self.now.addingTimeInterval(-86400)
        try FileManager.default.setAttributes([.modificationDate: sentinel], ofItemAtPath: file.path)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        #expect(try Self.export(Self.items(), into: store) == .unchanged)
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date == before)
    }

    @Test func exportSkipsBodyWithEnvironmentValue() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        var lines: [String] = []
        _ = try GraphMemory.export(items: .init(issues: [Self.issue(body: "Token supersecret99")]), jobs: [],
            reports: { _ in nil }, repo: Self.repo, environment: ["TOKEN": "supersecret99"],
            into: store, now: Self.now, log: { lines.append($0) })
        #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("memory/issues/1.md").path))
        #expect(lines.filter { $0.contains("issue #1") }.count == 1)
        #expect(!lines.joined().contains("supersecret99"))
        #expect(!lines.joined().contains("Token "))
    }

    @Test func memoryItemsReadsBothSidesAndStopsAtSince() async throws {
        let root = try Self.temp()
        defer { Self.remove(root) }
        let gh = root.appendingPathComponent("gh")
        // Both sides advertise another page; the cutoff, rather than pageInfo, must stop them.
        let json = Self.response.replacingOccurrences(of: "\"hasNextPage\":false,\"endCursor\":null",
                                                      with: "\"hasNextPage\":true,\"endCursor\":\"next\"")
        let script = """
        #!/bin/sh
        set -eu
        printf 'call\\n' >> "${0%/*}/calls"
        printf '%s\\n' "$@" >> "${0%/*}/argv"
        cat <<'JSON'
        \(json)
        JSON
        """
        try script.write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let items = try await GitHubClient(ghPath: gh.path).memoryItems(repo: Self.repo,
            since: Self.now, now: Self.now)
        #expect(items.issues.count == 1)
        #expect(items.pullRequests.count == 1)
        #expect(items.issues.first?.comments.first?.body == "## Decision: ship it\n\nbecause")
        #expect(items.pullRequests.first?.reviews.first?.state == "APPROVED")
        #expect(items.pullRequests.first?.reviews.first?.body == "## Review: approve")
        let argv = try Self.read(root.appendingPathComponent("argv"))
        #expect(argv.contains("-F\nissues=true\n"))
        #expect(argv.contains("-F\nprs=true\n"))
        #expect(try Self.read(root.appendingPathComponent("calls")).split(separator: "\n").count == 1)
    }

    @Test func decodeMemoryItemsToleratesAbsentConnection() throws {
        let json = """
        {"data":{"repository":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}
        """
        let decoded = try GitHubClient.decodeMemoryItems(Data(json.utf8))
        #expect(decoded.items.pullRequests.isEmpty)
        #expect(decoded.prsNext == nil)
    }

    @Test func rebuildReasonOrder() {
        let now = Self.now
        let memory = GraphMemory.State(updatedAt: now, issues: 1, pullRequests: 0)
        let old = now.addingTimeInterval(-3600)
        func marker(_ commit: String = "tip", shape: Int? = CodeGraph.shape,
                    age: TimeInterval = 31 * 60, memoryAt: Date? = old) -> CodeGraph.Marker {
            .init(commit: commit, at: now.addingTimeInterval(-age), shape: shape, memoryAt: memoryAt)
        }
        let cases: [(CodeGraph.Marker?, Bool, GraphMemory.State?, String?)] = [
            (nil, true, memory, "no graph"),
            (marker("other", shape: nil), false, memory, "no graph"),
            (marker("other", shape: nil), true, memory, "base moved to tip"),
            (marker(shape: nil), true, memory, "graph shape"),
            (marker(), true, memory, "memory newer than the graph"),
            (marker(memoryAt: nil), true, memory, "memory newer than the graph"),
            (marker(age: 5 * 60), true, memory, nil),
            (marker(memoryAt: now), true, memory, nil),
            (marker(), true, nil, nil)
        ]
        for (marker, built, memory, expected) in cases {
            let reason = GraphMemory.rebuildReason(marker: marker, built: built, tip: "tip", memory: memory, now: now)
            if let expected { #expect(reason?.hasPrefix(expected) == true) }
            else { #expect(reason == nil) }
        }
        #expect(CodeGraph.shape == 4) // Raised twice on 2026-10-30: the redaction rule, then graphify's ignore file in the build tree.
        #expect(CodeGraphBuilder.memoryRebuildInterval == 30 * 60)
    }

    @Test func markerDecodesWithoutNewFields() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        try Data(#"{"commit":"abc","at":"2026-10-30T10:00:00Z"}"#.utf8)
            .write(to: store.appendingPathComponent("bton-build.json"))
        let marker = try #require(CodeGraph.marker(in: store))
        #expect(marker.commit == "abc")
        #expect(marker.shape == nil)
        #expect(marker.memoryAt == nil)
    }

    @Test func instructionLineNamesMemoryWhenPresent() {
        let marker = CodeGraph.Marker(commit: "abcdef012345", at: Self.now,
                                      shape: CodeGraph.shape, memoryAt: Self.now)
        let line = CodeGraph.instructionLine(base: "develop", marker: marker)
        #expect(line.contains("memory/ beside it"))
        #expect(line.contains(Self.minute(Self.now)))
        #expect(CodeGraph.instructionLine(base: "develop", marker: marker, template: "M {memory}") == "M \(Self.minute(Self.now))")
        let plain = CodeGraph.Marker(commit: "abcdef012345", at: Self.now)
        let expected = CodeGraph.defaultInstruction.replacingOccurrences(of: "{base}", with: "develop")
            .replacingOccurrences(of: "{commit}", with: "abcdef01")
            .replacingOccurrences(of: "{graph}", with: "graphify-out")
        #expect(CodeGraph.instructionLine(base: "develop", marker: plain) == expected)
    }

    @Test func linkIntoWorktreeKeepsStatusClean() async throws {
        let root = try Self.temp()
        defer { Self.remove(root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await GraphFixture.git(["init"], in: repo)
        try await GraphFixture.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Seed"], in: repo)
        let tree = root.appendingPathComponent("tree")
        try await GraphFixture.git(["worktree", "add", "-b", "memory-test", tree.path], in: repo)
        let store = root.appendingPathComponent("store")
        try Self.write("Memory", to: store.appendingPathComponent("memory/x.md"))
        try GraphMemory.link(into: tree, store: store)
        try GraphMemory.link(into: tree, store: store)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tree.appendingPathComponent("memory").path)
                == store.appendingPathComponent("memory").path)
        #expect(try await GraphFixture.git(["status", "--porcelain"], in: tree) == "")
        // Git reads info/exclude from the common directory only, never from .git/worktrees/<name>.
        let gitDir = try await GraphFixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: tree)
        let exclude = try Self.read(URL(fileURLWithPath: gitDir).appendingPathComponent("info/exclude"))
        #expect(exclude.split(separator: "\n").filter { $0 == "memory" }.count == 1)
        #expect(exclude.split(separator: "\n").filter { $0 == "graphify-out" }.count == 1)
    }

    @Test func buildCopiesMemoryAndMarksShape() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        try Self.write("# Decision", to: f.store.appendingPathComponent("memory/issues/1.md"))
        try Self.state(Self.now, into: f.store)
        await f.refresh()
        await f.builder.waitForBuilds()
        let tree = f.clone.appendingPathComponent(".worktrees/bton-graph")
        let file = tree.appendingPathComponent("memory/issues/1.md")
        #expect(try Self.read(file) == "# Decision")
        #expect(try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true)
        #expect(try tree.appendingPathComponent("memory").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == false)
        #expect(try await GraphFixture.git(["status", "--porcelain"], in: tree) == "")
        let marker = try #require(CodeGraph.marker(in: f.store))
        #expect(marker.shape == CodeGraph.shape)
        #expect(marker.memoryAt == Self.now)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(f.log.filter { $0.hasPrefix("graph \(f.repo.slug): memory not refreshed:") }.count == 1)
    }

    @Test func oldShapeRebuildsAtSameTip() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        let marker = try #require(CodeGraph.marker(in: f.store))
        let runs = try f.pythonRuns()
        try Self.save(CodeGraph.Marker(commit: marker.commit, at: marker.at), into: f.store)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == runs + 1)
        #expect(CodeGraph.marker(in: f.store)?.shape == CodeGraph.shape)
        #expect(CodeGraph.marker(in: f.store)?.commit == marker.commit)
    }

    @Test func memoryNewerRebuildsAfterInterval() async throws {
        let f = try await GraphFixture.make(python: .succeeds)
        defer { f.remove() }
        await f.refresh()
        await f.builder.waitForBuilds()
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
        let runs = try f.pythonRuns()
        try Self.state(now, into: f.store)
        try Self.save(.init(commit: f.tip, at: now.addingTimeInterval(-31 * 60),
                            shape: CodeGraph.shape, memoryAt: now.addingTimeInterval(-3600)), into: f.store)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == runs + 1)
        // Keep memory newer so this checks the cooldown, not equality after the build.
        try Self.save(.init(commit: f.tip, at: now, shape: CodeGraph.shape,
                            memoryAt: now.addingTimeInterval(-3600)), into: f.store)
        await f.refresh()
        await f.builder.waitForBuilds()
        #expect(try f.pythonRuns() == runs + 1)
    }

    private static func issue(body: String = "B") -> GraphMemory.Issue {
        .init(number: 1, title: "T", state: "OPEN", createdAt: now.addingTimeInterval(-86400),
              updatedAt: now.addingTimeInterval(-60), closedAt: nil, author: "dani", body: body,
              labels: ["stage:ready"], comments: [IssueComment(id: "5", author: "bogdan", authorAssociation: nil,
                  body: "## Decision: ship it\n\nbecause", createdAt: now, url: nil)])
    }

    private static func items() -> GraphMemory.Items {
        .init(issues: [issue()], pullRequests: [.init(number: 2, title: "P", state: "MERGED",
            createdAt: now.addingTimeInterval(-86400), updatedAt: now, mergedAt: now,
            baseRef: "develop", headRef: "fix/x", author: "dani", body: "B", files: ["a.ts"],
            reviews: [.init(author: "bogdan", state: "APPROVED", body: "## Review: approve", submittedAt: now)], comments: [])])
    }

    private static func export(_ items: GraphMemory.Items, into store: URL) throws -> GraphMemory.Outcome {
        try GraphMemory.export(items: items, jobs: [], reports: { _ in nil }, repo: repo,
                               environment: [:], into: store, now: now, log: { _ in })
    }

    private static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-memory-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    private static func minute(_ date: Date) -> String {
        String(ISO8601DateFormatter().string(from: date).prefix(16)) + "Z"
    }
    private static func state(_ date: Date, into store: URL) throws {
        try saveJSON(GraphMemory.State(updatedAt: date, issues: 1, pullRequests: 0),
                     to: store.appendingPathComponent("memory/bton-memory.json"))
    }
    private static func save(_ marker: CodeGraph.Marker, into store: URL) throws {
        try saveJSON(marker, to: store.appendingPathComponent("bton-build.json"))
    }
    private static func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static let response = #"""
    {"data":{"repository":{
      "issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":1,"title":"T","state":"OPEN","createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-30T12:00:00Z","closedAt":null,"author":{"login":"dani"},"body":"B","labels":{"nodes":[{"name":"stage:ready"}]},"comments":{"nodes":[{"databaseId":5,"author":{"login":"bogdan"},"body":"## Decision: ship it\n\nbecause","createdAt":"2026-10-30T12:00:00Z"}]}}]},
      "pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":2,"title":"P","state":"MERGED","createdAt":"2026-10-01T10:00:00Z","updatedAt":"2026-10-30T12:00:00Z","mergedAt":"2026-10-30T12:00:00Z","baseRefName":"develop","headRefName":"fix/x","author":{"login":"dani"},"body":"B","files":{"nodes":[{"path":"a.ts"}]},"reviews":{"nodes":[{"author":{"login":"bogdan"},"state":"APPROVED","body":"## Review: approve","submittedAt":"2026-10-30T12:00:00Z"}]},"comments":{"nodes":[]}}]}
    }}}
    """#
}
