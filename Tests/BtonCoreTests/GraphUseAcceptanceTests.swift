import BtonCore
import Foundation
import Testing

struct GraphUseAcceptanceTests {
    @Test(arguments: [
        "graphify-src \"where is auth?\"",
        "/Users/x/.local/bin/graphify-src \"callers\"",
        "grep graphify-src somefile",
        "graphify explain auth", "graphify query auth", "graphify path a b", "graphify affected auth"
    ])
    func recognizesQueries(command: String) {
        #expect(GraphUse.isQuery(command))
    }

    @Test(arguments: [
        "graphify", "ls graphify-out", "cat graphify-out/GRAPH_REPORT.md",
        "notgraphify-srcx", "graphify querying auth", "echo graphify"
    ])
    func rejectsCommandsWithoutAQuery(command: String) {
        #expect(!GraphUse.isQuery(command))
    }

    @Test func claudeCountsEachBashQueryBlock() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude.jsonl")
        let transcript = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"graphify-src \"auth\""}},{"type":"tool_use","name":"Bash","input":{"command":"graphify path a b"}},{"type":"tool_use","name":"Bash","input":{"command":"ls graphify-out"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"command":"graphify-src auth"}},{"type":"text","text":"graphify query auth"}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"/Users/x/.local/bin/graphify-src auth"}}]}}
        """#
        try transcript.write(to: file, atomically: true, encoding: .utf8)
        #expect(GraphUse.queries(inClaudeSessionFile: file) == 3)
    }

    @Test func claudeReadableWithoutQueriesIsZero() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("claude.jsonl")
        let transcript = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"command":"graphify-src auth"}},{"type":"tool_use","name":"Bash","input":{"command":"cat graphify-out/GRAPH_REPORT.md"}}]}}"#
        try transcript.write(to: file, atomically: true, encoding: .utf8)
        #expect(GraphUse.queries(inClaudeSessionFile: file) == 0)
    }

    @Test func claudeMissingOrUnreadableIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GraphUse.queries(inClaudeSessionFile: root.appendingPathComponent("missing.jsonl")) == nil)
        #expect(GraphUse.queries(inClaudeSessionFile: root) == nil)
    }

    @Test func codexCountsExecFragmentsAndShellCalls() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = #"""
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({cmd:\"graphify-src auth\"}); await tools.exec_command({cmd:\"ls graphify-out\"}); await tools.exec_command({cmd:\"graphify affected auth\"});"}}
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"graphify query auth && graphify path a b\"]}"}}
        {"type":"response_item","payload":{"type":"custom_tool_call","name":"other","input":"cmd:\"graphify-src auth\""}}
        {"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"cat graphify-out/GRAPH_REPORT.md\"]}"}}
        """#
        try codexSession(root: root, id: "queries", cwd: "/tmp/project", started: start, transcript: transcript)
        #expect(GraphUse.queries(inCodexWorktree: "/tmp/project", from: start, to: end, sessionsRoot: root) == 3)
    }

    @Test func codexSelectsSessionStartsAndWorktreeBoundaries() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"cmd:\"graphify-src auth\""}}"#
        let cases: [(String, String, Date)] = [
            ("start", "/tmp/project", start),
            ("nested", "/tmp/project/sub/deeper", start.addingTimeInterval(60)),
            ("end", "/tmp/project", end),
            ("sibling", "/tmp/project-other", start),
            ("elsewhere", "/tmp/elsewhere", start),
            ("before", "/tmp/project", start.addingTimeInterval(-1)),
            ("after", "/tmp/project", end.addingTimeInterval(1))
        ]
        for (id, cwd, started) in cases {
            try codexSession(root: root, id: id, cwd: cwd, started: started, transcript: transcript)
        }
        #expect(GraphUse.queries(inCodexWorktree: "/tmp/project", from: start, to: end, sessionsRoot: root) == 3)
    }

    @Test func codexSessionWithoutQueriesIsZero() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"cmd:\"ls graphify-out\""}}"#
        try codexSession(root: root, id: "no-query", cwd: "/tmp/project", started: start, transcript: transcript)
        #expect(GraphUse.queries(inCodexWorktree: "/tmp/project", from: start, to: end, sessionsRoot: root) == 0)
    }

    @Test func codexWithoutMatchingSessionIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transcript = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"cmd:\"graphify-src auth\""}}"#
        try codexSession(root: root, id: "sibling", cwd: "/tmp/project-other", started: start, transcript: transcript)
        try codexSession(root: root, id: "old", cwd: "/tmp/project", started: start.addingTimeInterval(-1), transcript: transcript)
        #expect(GraphUse.queries(inCodexWorktree: "/tmp/project", from: start, to: end, sessionsRoot: root) == nil)
        #expect(GraphUse.queries(inCodexWorktree: "/tmp/project", from: start, to: end,
            sessionsRoot: root.appendingPathComponent("missing")) == nil)
    }

    private var start: Date { ISO8601DateFormatter().date(from: "2026-10-19T09:00:00Z")! }
    private var end: Date { start.addingTimeInterval(3_600) }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func codexSession(root: URL, id: String, cwd: String, started: Date, transcript: String) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy/MM/dd"
        let folder = root.appendingPathComponent(formatter.string(from: started))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = iso.string(from: started)
        let meta: [String: Any] = ["timestamp": timestamp, "type": "session_meta", "payload": [
            "id": id, "timestamp": timestamp, "cwd": cwd, "originator": "codex_exec"
        ]]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys])
        let line = String(decoding: data, as: UTF8.self)
        try (line + "\n" + transcript + "\n").write(to: folder.appendingPathComponent("rollout-\(id).jsonl"),
            atomically: true, encoding: .utf8)
    }
}
