@testable import BtonCore
import Foundation
import Testing

private struct GraphToolFixture {
    let root: URL
    let jobs: JobStore
    let job = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-graph-tool-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        jobs = try JobStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path]))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func script(_ body: String) throws -> String {
        let url = root.appendingPathComponent("synthetic-graphify-src")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func graphEntry(_ kind: String = "directory") throws {
        let url = root.appendingPathComponent("graphify-out")
        switch kind {
        case "file": try Data().write(to: url)
        case "symlink":
            // A dangling symlink is still an entry, as the contract requires.
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "missing-store")
        default: try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    func run(_ program: String?, question: String = "Where is auth?\nSecond line") async -> Helpers.AskResult {
        await Helpers.graph(question: question, cwd: root, job: job, jobs: jobs,
            timeout: .seconds(10), resolve: { name in
                #expect(name == "graphify-src")
                return program
            })
    }

    func expectNotes(question: String, failed: Bool) throws {
        let log = try String(contentsOf: jobs.logURL(job), encoding: .utf8)
        let firstLine = String(question.prefix(while: { $0 != "\n" }))
        let start = try #require(log.range(of: "graph: " + firstLine))
        let pattern = "graph \(failed ? "failed" : "answered") after [0-9]+s"
        let finish = try #require(log.range(of: pattern, options: .regularExpression, range: start.upperBound..<log.endIndex))
        #expect(start.lowerBound < finish.lowerBound)
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func reply(_ server: AskServer, method: String = "tools/call", params: [String: Any] = [:]) async throws -> [String: Any] {
        let request: [String: Any] = ["jsonrpc": "2.0", "id": "graph-test", "method": method, "params": params]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let line = try #require(await server.respond(to: text))
        let reply = try object(line)
        #expect(reply["jsonrpc"] as? String == "2.0")
        #expect(reply["id"] as? String == "graph-test")
        return reply
    }

    static func expectResult(_ reply: [String: Any], text: String, isError: Bool) throws {
        #expect(reply["error"] == nil)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == isError)
        #expect(result["content"] as? [[String: String]] == [["type": "text", "text": text]])
    }
}

private actor GraphToolCalls {
    var values: [[String]] = []
    func record(_ values: [String]) { self.values.append(values) }
}

struct GraphToolAcceptanceTests {
    @Test func toolNamesAreStable() {
        #expect(Helpers.graphTool == "mcp__bton__graph")
        #expect(Helpers.tool == "mcp__bton__ask")
    }

    @Test func toolListCoversAllCapabilitiesAndGraphSchema() async throws {
        for helpers in [[], ["codex"]] as [[String]] {
            for enabled in [false, true] {
                let graph: (@Sendable (String) async -> Helpers.AskResult)? = enabled
                    ? { @Sendable _ in Helpers.AskResult(text: "unused", isError: false) } : nil
                let server = AskServer(helpers: helpers, graph: graph) { _, _ in
                    Helpers.AskResult(text: "unused", isError: false)
                }
                let reply = try await GraphToolFixture.reply(server, method: "tools/list")
                let result = try #require(reply["result"] as? [String: Any])
                let tools = try #require(result["tools"] as? [[String: Any]])
                let expected = (helpers.isEmpty ? [] : ["ask"]) + (enabled ? ["graph"] : [])
                #expect(tools.compactMap { $0["name"] as? String } == expected)
                if enabled {
                    let tool = try #require(tools.last)
                    let schema = try #require(tool["inputSchema"] as? [String: Any])
                    #expect(schema["type"] as? String == "object")
                    #expect(schema["required"] as? [String] == ["question"])
                    let properties = try #require(schema["properties"] as? [String: [String: Any]])
                    #expect(Set(properties.keys) == ["question"])
                    #expect(properties["question"]?["type"] as? String == "string")
                }
            }
        }
    }

    @Test func graphCallsMirrorResultsAndAskStillRoutesSeparately() async throws {
        let calls = GraphToolCalls()
        let question = "Where is 'auth'?\nSecond line"
        for isError in [false, true] {
            let answer = "Synthetic \"answer\"\nnext"
            let server = AskServer(helpers: ["codex"], graph: { question in
                await calls.record(["graph", question])
                return Helpers.AskResult(text: answer, isError: isError)
            }) { agent, question in
                await calls.record(["ask", agent, question])
                return Helpers.AskResult(text: "ask answer", isError: false)
            }
            let graph = try await GraphToolFixture.reply(server, params: ["name": "graph", "arguments": ["question": question]])
            try GraphToolFixture.expectResult(graph, text: answer, isError: isError)
            let ask = try await GraphToolFixture.reply(server, params: ["name": "ask", "arguments": ["agent": "codex", "question": question]])
            try GraphToolFixture.expectResult(ask, text: "ask answer", isError: false)
        }
        #expect(await calls.values == Array(repeating: [["graph", question], ["ask", "codex", question]], count: 2).flatMap { $0 })
    }

    @Test func graphInvalidArgumentsNeverInvokeEitherClosure() async throws {
        let calls = GraphToolCalls()
        let server = AskServer(helpers: ["codex"], graph: { question in
            await calls.record(["graph", question])
            return Helpers.AskResult(text: "must not run", isError: false)
        }) { agent, question in
            await calls.record([agent, question])
            return Helpers.AskResult(text: "must not run", isError: false)
        }
        for arguments: Any in [[:], ["question": 7], ["question": false], ["question": NSNull()], NSNull(), []] {
            let reply = try await GraphToolFixture.reply(server, params: ["name": "graph", "arguments": arguments])
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        let missing = try await GraphToolFixture.reply(server, params: ["name": "graph"])
        #expect((missing["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(await calls.values.isEmpty)
    }

    @Test func absentGraphIsUnknownAndLegacyInitializerCompiles() async throws {
        let calls = GraphToolCalls()
        let server = AskServer(helpers: ["codex"]) { agent, question in
            await calls.record([agent, question])
            return Helpers.AskResult(text: "legacy ask", isError: false)
        }
        let reply = try await GraphToolFixture.reply(server, params: ["name": "graph", "arguments": ["question": "auth"]])
        try GraphToolFixture.expectResult(reply, text: "unknown tool", isError: true)
        #expect(await calls.values.isEmpty)
        let ask = try await GraphToolFixture.reply(server, params: ["name": "ask", "arguments": ["agent": "codex", "question": "auth"]])
        try GraphToolFixture.expectResult(ask, text: "legacy ask", isError: false)
        #expect(await calls.values == [["codex", "auth"]])
    }

    @Test func serverConfigAppendsGraphAfterHelpersAndPreservesLegacyDefault() throws {
        let job = UUID()
        let home = URL(fileURLWithPath: "/synthetic/home with spaces")
        let cwd = URL(fileURLWithPath: "/synthetic/checkout")
        for helpers in [[], ["codex", "second helper"]] as [[String]] {
            let base = ["ask-server", "--job", job.uuidString, "--cwd", cwd.path]
                + helpers.flatMap { ["--helper", $0] }
            let legacy = Helpers.serverConfig(server: "/synthetic/bton", job: job, home: home, cwd: cwd, helpers: helpers)
            for enabled in [false, true] {
                let data = Helpers.serverConfig(server: "/synthetic/bton", job: job, home: home, cwd: cwd, helpers: helpers, graph: enabled)
                let top = try GraphToolFixture.object(String(decoding: data, as: UTF8.self))
                let servers = try #require(top["mcpServers"] as? [String: [String: Any]])
                let bton = try #require(servers["bton"])
                #expect(bton["args"] as? [String] == base + (enabled ? ["--graph"] : []))
                #expect(bton["command"] as? String == "/synthetic/bton")
                #expect(bton["type"] as? String == "stdio")
                #expect(bton["env"] as? [String: String] == ["BTON_HOME": home.path])
                if !enabled {
                    let old = try GraphToolFixture.object(String(decoding: legacy, as: UTF8.self))
                    #expect(NSDictionary(dictionary: top).isEqual(to: old))
                }
            }
        }
    }

    @Test(ProcessBound(), arguments: ["file", "directory", "symlink"])
    func graphRunsExactSingleArgumentInCheckout(kind: String) async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        try f.graphEntry(kind)
        let program = try f.script("""
        [ "$#" -eq 1 ] || exit 11
        printf '%s' "$1" > received
        [ -e synthetic-graphify-src ] || exit 12
        printf '  answer: %s \\n' "$1"
        """)
        let question = "auth 'quoted' $(touch injected); *\nSecond line"
        let result = await f.run(program, question: question)
        #expect(result == Helpers.AskResult(text: "answer: " + question, isError: false))
        #expect(try Data(contentsOf: f.root.appendingPathComponent("received")) == Data(question.utf8))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("injected").path))
        try f.expectNotes(question: question, failed: false)
    }

    @Test func missingGraphPrecedesMissingExecutable() async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        let question = "Missing graph"
        let result = await f.run(nil, question: question)
        #expect(result == Helpers.AskResult(text: "no code graph is linked in this checkout", isError: true))
        try f.expectNotes(question: question, failed: true)
    }

    @Test func missingExecutableIsReportedAndLogged() async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        try f.graphEntry()
        let question = "Missing executable"
        let result = await f.run(nil, question: question)
        #expect(result == Helpers.AskResult(text: "graphify-src is not installed on this Mac", isError: true))
        try f.expectNotes(question: question, failed: true)
    }

    @Test(ProcessBound(), arguments: ["", " \t\n ", String(repeating: "x", count: 20_001)])
    func invalidQuestionDoesNotExecute(question: String) async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        try f.graphEntry()
        let program = try f.script("touch executed; printf unexpected")
        let result = await f.run(program, question: question)
        #expect(result == Helpers.AskResult(text: "the question must be 1 to 20000 characters", isError: true))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("executed").path))
        try f.expectNotes(question: question, failed: true)
    }

    @Test(ProcessBound()) func questionAndAnswerExactLimitAndTruncation() async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        try f.graphEntry()
        let boundary = String(repeating: "a", count: 20_000)
        let echo = try f.script("printf '%s' \"$1\"")
        #expect(await f.run(echo, question: boundary) == Helpers.AskResult(text: boundary, isError: false))
        try f.expectNotes(question: boundary, failed: false)
        let large = try f.script("i=0; while [ \"$i\" -lt 20001 ]; do printf a; i=$((i + 1)); done")
        let question = "Large answer"
        #expect(await f.run(large, question: question) == Helpers.AskResult(
            text: boundary + "\n[answer cut at 20000 characters]", isError: false))
        try f.expectNotes(question: question, failed: false)
    }

    @Test(ProcessBound()) func nonzeroExitIncludesStatusAndStderrTail() async throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        try f.graphEntry()
        let program = try f.script("i=0; while [ \"$i\" -lt 25000 ]; do printf x >&2; i=$((i + 1)); done; printf '\\nSynthetic stderr tail\\n' >&2; exit 23")
        let question = "Failure question\nSecond line"
        let result = await f.run(program, question: question)
        #expect(result.isError)
        #expect(result.text.hasPrefix("graphify-src exited 23:"))
        #expect(result.text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("Synthetic stderr tail"))
        try f.expectNotes(question: question, failed: true)
    }

    @Test func instructionLinePreservesDefaultAndCustomTemplatesWithOptionalTool() {
        let marker = CodeGraph.Marker(commit: "0123456789ab", at: .now)
        let suffix = " Ask it with the mcp__bton__graph tool (question: what you look for); this session has no shell."
        let defaultLine = "Code graph: graphify-out/ in this checkout is graphify's graph of develop at 01234567; this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree."
        for (template, expected): (String?, String) in [
            (nil, defaultLine), ("Inspect {graph} on {base} at {commit}.", "Inspect graphify-out on develop at 01234567.")
        ] {
            #expect(CodeGraph.instructionLine(base: "develop", marker: marker, template: template) == expected)
            #expect(CodeGraph.instructionLine(base: "develop", marker: marker, template: template, tool: nil) == expected)
            #expect(CodeGraph.instructionLine(base: "develop", marker: marker, template: template, tool: "mcp__bton__graph") == expected + suffix)
        }
    }

    @Test func transcriptCountsBashAndGraphToolsButNotAskOrLs() throws {
        let f = try GraphToolFixture()
        defer { f.remove() }
        let file = f.root.appendingPathComponent("claude.jsonl")
        let transcript = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"graphify-src auth"}},{"type":"tool_use","name":"mcp__bton__graph","input":{"question":"auth"}},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"graphify-src callers"}},{"type":"tool_use","name":"mcp__bton__graph","input":{}},{"type":"tool_use","name":"mcp__bton__ask","input":{"agent":"codex","question":"graphify-src auth"}}]}}
        """#
        try transcript.write(to: file, atomically: true, encoding: .utf8)
        #expect(GraphUse.queries(inClaudeSessionFile: file) == 4)
    }
}
