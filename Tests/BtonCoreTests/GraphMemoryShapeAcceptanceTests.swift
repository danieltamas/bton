@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct GraphMemoryShapeAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_793_365_500)
    private static let repo = "synthetic/repo"

    @Test func redactKeepsUserNamePasswordButHidesFullURL() {
        let url = "postgres://lexito:lexito@127.0.0.1:5432/lexito_master"
        let environment = ["DATABASE_URL": url]
        let text = "the lexito app; lexito.ro"
        #expect(DispatchPlanner.redact(text, environment: environment) == text)
        #expect(DispatchPlanner.redact("connect to \(url) now", environment: environment)
                == "connect to [DATABASE_URL] now")
    }

    @Test func redactHidesDistinctURLPasswordStandingAlone() {
        let environment = ["DATABASE_URL": "postgres://lexito:hunter22@127.0.0.1/app"]
        #expect(DispatchPlanner.redact("hunter22 and hunter22", environment: environment)
                == "[DATABASE_URL] and [DATABASE_URL]")
    }

    @Test func stateSinceRequiresCurrentShape() {
        let legacy = GraphMemory.State(updatedAt: Self.now, issues: 1, pullRequests: 0)
        #expect(legacy.shape == nil)
        #expect(legacy.jobsAt == nil)
        #expect(legacy.since == nil)
        let current = GraphMemory.State(updatedAt: Self.now, issues: 1, pullRequests: 0,
                                        jobsAt: Self.now, shape: GraphMemory.shape)
        #expect(current.since == Self.now)
        let old = GraphMemory.State(updatedAt: Self.now, issues: 1, pullRequests: 0,
                                    shape: GraphMemory.shape - 1)
        #expect(old.since == nil)
    }

    @Test func exportSavesCurrentShape() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        _ = try Self.export(jobs: [], into: store)
        #expect(GraphMemory.state(in: store)?.shape == GraphMemory.shape)
    }

    @Test func exportOldShapeRendersJobsBeforeWatermark() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        _ = try Self.export(jobs: [], into: store)
        try Self.rewriteState(shape: GraphMemory.shape - 1, into: store)
        let job = Self.job()
        #expect(job.endedAt! < Self.now)
        _ = try Self.export(jobs: [job], into: store)
        let file = store.appendingPathComponent("memory/jobs/pr-2.md")
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(try Self.read(file).contains("Accepted the design"))
        #expect(GraphMemory.state(in: store)?.shape == GraphMemory.shape)
    }

    @Test func exportCurrentShapeSkipsJobsBeforeWatermark() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        _ = try Self.export(jobs: [], into: store)
        try Self.rewriteState(shape: GraphMemory.shape, into: store)
        #expect(try Self.export(jobs: [Self.job()], into: store) == .unchanged)
        #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("memory/jobs/pr-2.md").path))
    }

    @Test func exportLogsThreeSecretIssuesInOneLine() throws {
        let store = try Self.temp()
        defer { Self.remove(store) }
        var lines: [String] = []
        _ = try GraphMemory.export(items: .init(issues: (1...3).map {
            Self.issue(number: $0, body: "Token supersecret99")
        }), jobs: [], reports: { _ in nil }, repo: Self.repo,
            environment: ["TOKEN": "supersecret99"], into: store, now: Self.now,
            log: { lines.append($0) })
        #expect(lines.count == 1)
        let line = try #require(lines.first)
        #expect(line.contains("3 not written"))
        for number in 1...3 {
            #expect(line.contains("issue #\(number)"))
            #expect(!FileManager.default.fileExists(atPath: store.appendingPathComponent("memory/issues/\(number).md").path))
        }
        #expect(lines.allSatisfy { !$0.contains("supersecret99") })
    }

    private static func issue(number: Int = 1, body: String = "B") -> GraphMemory.Issue {
        .init(number: number, title: "T", state: "OPEN", createdAt: now.addingTimeInterval(-86400),
              updatedAt: now.addingTimeInterval(-60), closedAt: nil, author: "dani", body: body,
              labels: ["stage:ready"], comments: [IssueComment(id: "5", author: "bogdan", authorAssociation: nil,
                  body: "## Decision: ship it\n\nbecause", createdAt: now, url: nil)])
    }

    private static func job() -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: "pr-2", move: "review", head: "abcdef012345"),
            agent: "synthetic", startedAt: now.addingTimeInterval(-120), endedAt: now.addingTimeInterval(-60),
            status: .succeeded, cost: Decimal(1))
    }

    private static func export(jobs: [Job], into store: URL) throws -> GraphMemory.Outcome {
        try GraphMemory.export(items: .init(issues: [issue()]), jobs: jobs,
            reports: { _ in "Accepted the design" }, repo: repo, environment: [:],
            into: store, now: now, log: { _ in })
    }

    private static func rewriteState(shape: Int, into store: URL) throws {
        let file = store.appendingPathComponent("memory/bton-memory.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["shape"] = shape
        json["jobsAt"] = ISO8601DateFormatter().string(from: now)
        try JSONSerialization.data(withJSONObject: json).write(to: file, options: .atomic)
        let state = try #require(GraphMemory.state(in: store))
        #expect(state.shape == shape)
        #expect(state.jobsAt == now)
    }

    private static func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-memory-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
    private static func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
}
