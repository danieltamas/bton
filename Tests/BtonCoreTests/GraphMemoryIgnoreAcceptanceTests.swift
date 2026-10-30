@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct GraphMemoryIgnoreAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_793_365_500)
    private static let repo = "synthetic/repo"

    @Test func copyCreatesGraphifyIgnore() async throws {
        let root = try Self.temp()
        defer { Self.remove(root) }
        let tree = try await Self.worktree(in: root)
        let store = root.appendingPathComponent("store")
        #expect(try Self.export(into: store, now: Self.now) == .written(files: 3))
        try GraphMemory.copy(into: tree, store: store)
        #expect(GraphMemory.ignoreName == ".graphifyignore")
        let lines = try Self.read(tree.appendingPathComponent(GraphMemory.ignoreName)).split(separator: "\n")
        #expect(lines == ["!memory"])
        #expect(try Data(contentsOf: tree.appendingPathComponent("memory/issues/1.md"))
                == Data(contentsOf: store.appendingPathComponent("memory/issues/1.md")))
    }

    @Test func copyPreservesIgnoreWithoutTrailingNewlineAndDoesNotDuplicate() async throws {
        let root = try Self.temp()
        defer { Self.remove(root) }
        let tree = try await Self.worktree(in: root)
        let store = root.appendingPathComponent("store")
        _ = try Self.export(into: store, now: Self.now)
        let ignore = tree.appendingPathComponent(GraphMemory.ignoreName)
        try Self.write("node_modules/", to: ignore)
        try GraphMemory.copy(into: tree, store: store)
        #expect(try Self.read(ignore).split(separator: "\n") == ["node_modules/", "!memory"])
        try GraphMemory.copy(into: tree, store: store)
        #expect(try Self.read(ignore).split(separator: "\n") == ["node_modules/", "!memory"])
    }

    @Test func copyIntoWorktreeKeepsStatusCleanAndExcludesAllNames() async throws {
        let root = try Self.temp()
        defer { Self.remove(root) }
        let tree = try await Self.worktree(in: root)
        let store = root.appendingPathComponent("store")
        _ = try Self.export(into: store, now: Self.now)
        try GraphMemory.copy(into: tree, store: store)
        #expect(try await GraphFixture.git(["status", "--porcelain"], in: tree) == "")
        let gitDir = try await GraphFixture.git(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: tree)
        let exclude = try Self.read(URL(fileURLWithPath: gitDir).appendingPathComponent("info/exclude"))
        for name in ["memory", "graphify-out", ".graphifyignore"] {
            #expect(exclude.split(separator: "\n").filter { $0 == Substring(name) }.count == 1)
        }
    }

    @Test func exportDatesRecordsRatherThanSyncAndLeavesBytesUnchanged() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        #expect(try Self.export(into: store, now: Self.now) == .written(files: 3))
        let issue = store.appendingPathComponent("memory/issues/1.md")
        let pr = store.appendingPathComponent("memory/prs/2.md")
        let issueBefore = try Data(contentsOf: issue)
        let prBefore = try Data(contentsOf: pr)
        let later = Self.now.addingTimeInterval(3600)
        #expect(try Self.export(into: store, now: later) == .unchanged)
        #expect(try Data(contentsOf: issue) == issueBefore)
        #expect(try Data(contentsOf: pr) == prBefore)
        for file in [issue, pr] {
            let text = try Self.read(file)
            #expect(text.contains("As of \(Self.minute(Self.now))."))
            #expect(!text.contains("As of \(Self.minute(later))."))
        }
    }

    @Test func exportDatesJobsByEndedRun() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        let end = Self.now.addingTimeInterval(-300)
        let job = Job(id: UUID(), key: JobKey(repo: Self.repo, item: "pr-2", move: "review", head: "abcdef012345"),
                      agent: "synthetic", startedAt: Self.now.addingTimeInterval(-600), endedAt: end, status: .succeeded)
        #expect(try GraphMemory.export(items: .init(), jobs: [job], reports: { _ in nil }, repo: Self.repo,
            environment: [:], into: store, now: Self.now.addingTimeInterval(3600), log: { _ in }) == .written(files: 2))
        let text = try Self.read(store.appendingPathComponent("memory/jobs/pr-2.md"))
        let paragraphs = text.components(separatedBy: "\n\n")
        #expect(paragraphs.count >= 2)
        #expect(paragraphs.dropFirst().first == "As of \(Self.minute(end)).")
    }

    private static func items() -> GraphMemory.Items {
        .init(issues: [.init(number: 1, title: "T", state: "OPEN", createdAt: now.addingTimeInterval(-86400),
            updatedAt: now, closedAt: nil, author: "dani", body: "B", labels: [], comments: [])],
            pullRequests: [.init(number: 2, title: "P", state: "MERGED", createdAt: now.addingTimeInterval(-86400),
                updatedAt: now, mergedAt: now, baseRef: "develop", headRef: "fix/x", author: "dani",
                body: "B", files: ["a.ts"], reviews: [], comments: [])])
    }

    private static func export(into store: URL, now: Date) throws -> GraphMemory.Outcome {
        try GraphMemory.export(items: items(), jobs: [], reports: { _ in nil }, repo: repo,
                               environment: [:], into: store, now: now, log: { _ in })
    }

    private static func worktree(in root: URL) async throws -> URL {
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try await GraphFixture.git(["init"], in: repo)
        try await GraphFixture.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                                    "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Seed"], in: repo)
        let tree = root.appendingPathComponent("tree")
        try await GraphFixture.git(["worktree", "add", "-b", "memory-test", tree.path], in: repo)
        return tree
    }

    private static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-memory-ignore-\(UUID())")
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
}
