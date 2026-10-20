@testable import BtonCore
import Foundation
import Testing

struct SubagentCostAcceptanceTests {
    @Test func claudeIncludesEverySubagentAndIgnoresMetadata() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("parent.jsonl")
        let subagents = directory.appendingPathComponent("parent/subagents")
        let repeated = claudeLine(model: "synthetic-sonnet", id: "child-a", input: 10,
                                  cacheRead: 20, cacheWrite: 30, output: 4, sidechain: true)
        try write([claudeLine(model: "synthetic-sonnet", id: "parent", input: 100,
                             cacheRead: 200, cacheWrite: 300, output: 40)], to: file)
        try write([repeated, repeated], to: subagents.appendingPathComponent("agent-a.jsonl"))
        try write([claudeLine(model: "synthetic-sonnet", id: "child-b", input: 1,
                             cacheRead: 2, cacheWrite: 3, output: 5, sidechain: true)],
                  to: subagents.appendingPathComponent("agent-b.jsonl"))
        try write([claudeLine(model: "synthetic-opus", id: "child-c", input: 7,
                             cacheRead: 8, cacheWrite: 9, output: 10, sidechain: true)],
                  to: subagents.appendingPathComponent("agent-c.jsonl"))
        try write([claudeLine(model: "metadata-must-not-count", id: "metadata", input: 999)],
                  to: subagents.appendingPathComponent("agent-x.meta.json"))
        #expect(try ClaudeSessions.usage(ofSessionFile: file) == [
            "synthetic-sonnet": TokenUsage(input: 111, cacheRead: 222, cacheWrite: 333, output: 49),
            "synthetic-opus": TokenUsage(input: 7, cacheRead: 8, cacheWrite: 9, output: 10)
        ])
    }

    @Test func claudeWithoutSubagentsCountsRepeatedAssistantOnce() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("standalone.jsonl")
        let line = claudeLine(model: "synthetic-sonnet", id: "same-message", input: 11,
                              cacheRead: 12, cacheWrite: 13, output: 14)
        try write([line, line, line], to: file)
        #expect(try ClaudeSessions.usage(ofSessionFile: file) == [
            "synthetic-sonnet": TokenUsage(input: 11, cacheRead: 12, cacheWrite: 13, output: 14)
        ])
    }

    @Test func codexFiltersBySessionStartAndWorktreeBoundaryAndAddsSessions() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("sessions")
        let worktree = directory.appendingPathComponent("worktree").path
        let start = date("2026-10-19T09:00:00.000Z")
        let end = date("2026-10-19T10:00:00.000Z")
        let cases: [(String, String, Date, Bool)] = [
            ("at-start", worktree, start, true),
            ("nested", worktree + "/sub/deeper", start.addingTimeInterval(60), true),
            ("at-end", worktree, end, true),
            ("sibling", worktree + "-other", start, false),
            ("elsewhere", directory.appendingPathComponent("elsewhere").path, start, false),
            ("before", worktree, start.addingTimeInterval(-1), false),
            ("after", worktree, end.addingTimeInterval(1), false)
        ]
        for (id, cwd, timestamp, included) in cases {
            // Even excluded sessions have an event inside the window: ownership uses session_meta.
            let tokens = included ? 100 : 90_000
            try codexSession(root: root, id: id, cwd: cwd, started: timestamp, rows: [
                turn(model: "gpt-6.1-sol", cwd: worktree),
                tokenCount(input: tokens, cached: included ? 60 : 0, cacheWrite: 7, output: 5)
            ])
        }
        #expect(CodexSessions.usage(inWorktree: worktree, from: start, to: end, sessionsRoot: root) == [
            "gpt-6.1-sol": TokenUsage(input: 120, cacheRead: 180, cacheWrite: 21, output: 15)
        ])
    }

    @Test func codexUsesRunningTotalsAndAttributesGrowthToTheCurrentModel() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("sessions")
        let worktree = directory.appendingPathComponent("worktree").path
        let start = date("2026-10-19T23:03:23.134Z")
        let first = tokenCount(input: 1_000, cached: 600, cacheWrite: 20, output: 50)
        let last = tokenCount(input: 1_500, cached: 700, cacheWrite: 27, output: 80)
        try codexSession(root: root, id: "model-switch", cwd: worktree, started: start, rows: [
            turn(model: "gpt-6.1-sol", cwd: worktree), first, first,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#,
            "malformed JSON",
            #"{"type":"response_item","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":999999}}}}"#,
            #"{"type":"event_msg","payload":{"type":"other","info":{"total_token_usage":{"input_tokens":999999}}}}"#,
            turn(model: "synthetic-codex-second", cwd: worktree), last, last,
            #"{"type":"event_msg","payload":{"type":"token_count","info":null}}"#
        ])
        #expect(CodexSessions.usage(inWorktree: worktree, from: start, to: start.addingTimeInterval(60),
                                   sessionsRoot: root) == [
            "gpt-6.1-sol": TokenUsage(input: 400, cacheRead: 600, cacheWrite: 20, output: 50),
            "synthetic-codex-second": TokenUsage(input: 400, cacheRead: 100, cacheWrite: 7, output: 30)
        ])
    }

    @Test func codexFindsLocalMidnightSessionsAcrossBothDayFolders() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("sessions")
        let worktree = directory.appendingPathComponent("worktree").path
        let calendar = Calendar.current
        let midnight = calendar.startOfDay(for: date("2026-10-20T12:00:00.000Z"))
        let nextMidnight = try #require(calendar.date(byAdding: .day, value: 1, to: midnight))
        let start = midnight.addingTimeInterval(1)
        let end = nextMidnight.addingTimeInterval(60)
        for (id, timestamp) in [("just-after-midnight", start), ("next-day", nextMidnight.addingTimeInterval(1))] {
            try codexSession(root: root, id: id, cwd: worktree, started: timestamp, rows: [
                turn(model: "gpt-6.1-sol", cwd: worktree),
                tokenCount(input: 100, cached: 30, cacheWrite: 2, output: 9)
            ])
        }
        #expect(CodexSessions.usage(inWorktree: worktree, from: start, to: end, sessionsRoot: root) == [
            "gpt-6.1-sol": TokenUsage(input: 140, cacheRead: 60, cacheWrite: 4, output: 18)
        ])
    }

    @Test func codexMissingSessionsRootReturnsEmptyUsage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let start = date("2026-10-19T23:03:23.134Z")
        #expect(CodexSessions.usage(inWorktree: directory.path, from: start, to: start.addingTimeInterval(60),
                                   sessionsRoot: directory.appendingPathComponent("missing")).isEmpty)
    }

    @Test func mergedClaudeAndCodexUsagePricesEachModelAndRequiresCodexPrice() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("parent.jsonl")
        try write([claudeLine(model: "synthetic-claude", id: "parent", input: 1_000_000)], to: file)
        try write([claudeLine(model: "synthetic-child", id: "child", output: 200_000, sidechain: true)],
                  to: directory.appendingPathComponent("parent/subagents/agent-child.jsonl"))
        let root = directory.appendingPathComponent("sessions")
        let start = date("2026-10-19T23:03:23.134Z")
        try codexSession(root: root, id: "delegated", cwd: directory.path, started: start, rows: [
            turn(model: "synthetic-codex", cwd: directory.path),
            tokenCount(input: 1_000_000, cached: 600_000, cacheWrite: 100_000, output: 50_000)
        ])
        var merged = try ClaudeSessions.usage(ofSessionFile: file)
        merged.merge(CodexSessions.usage(inWorktree: directory.path, from: start,
                                         to: start.addingTimeInterval(60), sessionsRoot: root), uniquingKeysWith: +)
        #expect(merged == [
            "synthetic-claude": TokenUsage(input: 1_000_000),
            "synthetic-child": TokenUsage(output: 200_000),
            "synthetic-codex": TokenUsage(input: 400_000, cacheRead: 600_000, cacheWrite: 100_000, output: 50_000)
        ])
        var prices = PriceList(models: [
            "synthetic-claude": ModelPrice(input: 3, cacheRead: 1, cacheWrite: 4, output: 15),
            "synthetic-child": ModelPrice(input: 5, cacheRead: 2, cacheWrite: 6, output: 10),
            "synthetic-codex": ModelPrice(input: 5, cacheRead: 1, cacheWrite: 6, output: 20)
        ])
        // Claude: 3 + 2; Codex: 2 + 0.60 + 0.60 + 1 = 4.20; total $9.20.
        #expect(PriceList.cost(of: merged, prices: prices) == Decimal(string: "9.20")!)
        prices.models.removeValue(forKey: "synthetic-codex")
        #expect(PriceList.cost(of: merged, prices: prices) == nil)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func write(_ rows: [String], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (rows.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)!
    }

    private func claudeLine(model: String, id: String, input: Int = 0, cacheRead: Int = 0,
                            cacheWrite: Int = 0, output: Int = 0, sidechain: Bool = false) -> String {
        "{\"type\":\"assistant\",\"isSidechain\":\(sidechain),\"requestId\":\"request-\(id)\",\"message\":{\"id\":\"\(id)\",\"model\":\"\(model)\",\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":\(cacheRead),\"cache_creation_input_tokens\":\(cacheWrite),\"output_tokens\":\(output)}}}"
    }

    private func turn(model: String, cwd: String) -> String {
        json(["timestamp": "2026-10-19T09:30:00.000Z", "type": "turn_context",
              "payload": ["cwd": cwd, "model": model]])
    }

    private func tokenCount(input: Int, cached: Int, cacheWrite: Int, output: Int) -> String {
        json(["timestamp": "2026-10-19T09:30:00.000Z", "type": "event_msg",
              "payload": ["type": "token_count", "info": ["total_token_usage": [
                "input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": cacheWrite,
                "output_tokens": output, "reasoning_output_tokens": 10, "total_tokens": input + output
              ]]]])
    }

    private func codexSession(root: URL, id: String, cwd: String, started: Date, rows: [String]) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent(formatter.string(from: started))
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let file = folder.appendingPathComponent("rollout-\(formatter.string(from: started))-\(id).jsonl")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: started)
        let meta = json(["timestamp": timestamp, "type": "session_meta", "payload": [
            "id": id, "timestamp": timestamp, "cwd": cwd, "originator": "codex_exec"
        ]])
        try write([meta] + rows, to: file)
    }

    private func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }
}
