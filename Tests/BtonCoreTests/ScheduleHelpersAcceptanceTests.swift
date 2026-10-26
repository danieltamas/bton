@testable import BtonCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private struct HelpersFixture {
    let root: URL
    let jobs: JobStore
    let job = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-helpers-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        jobs = try JobStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path]))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func script(_ body: String, name: String = "synthetic-helper") throws -> String {
        let url = root.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func ask(_ argv: [String], question: String = "Synthetic question\nSecond line", agent: String = "helper",
             allowed: [String] = ["helper"], configured: Bool = true,
             timeout: Duration = .seconds(10), resolves: Bool = true) async -> Helpers.AskResult {
        await Helpers.ask(agent: agent, question: question, allowed: allowed,
            agents: configured ? [agent: AgentTemplate(argv: argv)] : [:], cwd: root,
            job: job, jobs: jobs, timeout: timeout, resolve: { resolves ? $0 : nil })
    }

    func log(agent: String = "helper", question: String = "Synthetic question") throws -> String {
        let text = try String(contentsOf: jobs.logURL(job), encoding: .utf8)
        #expect(text.contains(agent))
        #expect(text.contains(question))
        return text
    }

    static func entry(_ helpers: [String]?, primary: String = "primary") -> ScheduleEntry {
        ScheduleEntry(name: "Synthetic check", everyMinutes: 10, enabled: true,
            repo: "synthetic/widget", agent: primary, prompt: "Inspect synthetic widget", number: 7,
            model: nil, helpers: helpers)
    }

    static func object(_ text: String) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    static func canonical(_ path: String) throws -> String {
        let pointer = try #require(realpath(path, nil))
        defer { free(pointer) }
        return String(cString: pointer)
    }

    static func values(_ flag: String, _ argv: [String]) -> [String] {
        guard let index = argv.firstIndex(of: flag) else { return [] }
        return Array(argv.dropFirst(index + 1).prefix(while: { !$0.hasPrefix("--") && $0 != "-p" }))
    }
}

private actor AskCalls {
    var calls: [[String]] = []
    func record(_ agent: String, _ question: String) { calls.append([agent, question]) }
}

@Suite(ProcessBound())
struct ScheduleHelpersAcceptanceTests {
    @Test func helpersCodableDefaultsRoundTripsAndIsMutable() throws {
        let legacy = Data(#"{"name":"Synthetic check","everyMinutes":10,"enabled":true}"#.utf8)
        #expect(try JSONDecoder().decode(ScheduleEntry.self, from: legacy).helpers == nil)
        #expect(ScheduleEntry(name: "Synthetic", everyMinutes: 10, enabled: true).helpers == nil)
        var entry = HelpersFixture.entry(nil)
        for names: [String]? in [nil, [], ["codex", "second agent"]] {
            entry.helpers = names
            let encoded = try JSONEncoder().encode(entry)
            let object = try HelpersFixture.object(String(decoding: encoded, as: UTF8.self))
            if let names { #expect(object["helpers"] as? [String] == names) }
            #expect(try JSONDecoder().decode(ScheduleEntry.self, from: encoded).helpers == names)
        }
    }

    @Test func helperValidationAcceptsClaudeAndPreservesLegacyCalls() {
        let agents = ["primary": AgentTemplate(argv: ["/synthetic/bin/claude", "{prompt}"]),
                      "codex": AgentTemplate(argv: ["/synthetic/helper", "{prompt}"])]
        #expect(HelpersFixture.entry(["codex"]).problem(among: [], agents: agents, resolve: { $0 }) == nil)
        for names: [String]? in [nil, []] {
            let entry = HelpersFixture.entry(names, primary: "codex")
            #expect(entry.problem(among: [], agents: agents) == nil)
            #expect(entry.problem(among: [], agents: agents, resolve: { _ in nil }) == nil)
        }
    }

    @Test func helperValidationRejectsEveryInvalidBoundary() throws {
        var agents = ["primary": AgentTemplate(argv: ["/synthetic/claude"])]
        for name in ["codex", "two", "three", "four"] {
            agents[name] = AgentTemplate(argv: ["/synthetic/\(name)-program"])
        }
        for (names, offending) in [(["codex", "two", "three", "four"], ""),
                                    (["codex", "codex"], "codex"), (["primary"], "primary"),
                                    (["unknown"], "unknown")] {
            let problem = try #require(HelpersFixture.entry(names).problem(among: [], agents: agents, resolve: { $0 }))
            if !offending.isEmpty { #expect(problem.contains(offending)) }
        }
        #expect(HelpersFixture.entry(["codex", "two", "three"]).problem(among: [], agents: agents, resolve: { $0 }) == nil)
        let missing = try #require(HelpersFixture.entry(["codex"]).problem(among: [], agents: agents, resolve: { _ in nil }))
        #expect(missing.contains("codex-program"))
        agents["primary"] = AgentTemplate(argv: ["/synthetic/claude-wrapper"])
        #expect(HelpersFixture.entry(["codex"]).problem(among: [], agents: agents, resolve: { $0 }) != nil)
    }

    @Test func usablePreservesOrderAndSeparatesUnknownAndUninstalledNames() {
        let agents = ["one": AgentTemplate(argv: ["/synthetic/one"]),
                      "two": AgentTemplate(argv: ["/synthetic/two"]),
                      "three": AgentTemplate(argv: ["/synthetic/three"])]
        let result = Helpers.usable(["three", "unknown", "two", "one"], agents: agents,
                                   resolve: { $0 == "/synthetic/two" ? nil : $0 })
        #expect(result.usable == ["three", "one"])
        #expect(result.missing == ["unknown", "two"])
        let empty = Helpers.usable([], agents: agents, resolve: { $0 })
        #expect(empty.usable.isEmpty && empty.missing.isEmpty)
    }

    @Test func serverConfigPreservesEveryFieldAndExactArgument() throws {
        let job = UUID()
        let home = URL(fileURLWithPath: "/synthetic/home with \"quotes\"")
        let cwd = URL(fileURLWithPath: "/synthetic/working directory")
        let server = "/synthetic/server with \"quotes\""
        let names = ["codex", "other \"agent\""]
        let data = Helpers.serverConfig(server: server, job: job, home: home, cwd: cwd, helpers: names)
        let top = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(top.keys) == ["mcpServers"])
        let servers = try #require(top["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["bton"])
        let bton = try #require(servers["bton"] as? [String: Any])
        #expect(Set(bton.keys) == ["type", "command", "args", "env"])
        #expect(bton["type"] as? String == "stdio")
        #expect(bton["command"] as? String == server)
        #expect(bton["args"] as? [String] == ["ask-server", "--job", job.uuidString,
            "--cwd", cwd.path, "--helper", names[0], "--helper", names[1]])
        #expect(bton["env"] as? [String: String] == ["BTON_HOME": home.path])
    }

    @Test func instructionsNameHelpersToolAndRequireFinalDisclosure() {
        #expect(Helpers.tool == "mcp__bton__ask")
        #expect(Helpers.instructions([]) == "")
        let text = Helpers.instructions(["codex", "synthetic-helper"])
        for name in ["codex", "synthetic-helper", "mcp__bton__ask"] { #expect(text.contains(name)) }
        let lower = text.lowercased()
        for word in ["final", "agent", "why"] { #expect(lower.contains(word)) }
    }

    @Test func refusedAndInvalidQuestionsNeverExecuteAndAreLogged() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("touch marker; printf 'should not run'")
        for (allowed, configured, question) in [([], true, "Forbidden question"),
            (["helper"], false, "Unknown question"), (["helper"], true, ""),
            (["helper"], true, " \t\n "), (["helper"], true, String(repeating: "x", count: 20_001))] {
            let result = await fixture.ask([program, "{prompt}"], question: question,
                                           allowed: allowed, configured: configured)
            #expect(result.isError)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("marker").path))
            let log = try String(contentsOf: fixture.jobs.logURL(fixture.job), encoding: .utf8)
            #expect(log.contains("helper"))
            let firstLine = String(question.prefix(while: { $0 != "\n" }))
            if !firstLine.trimmingCharacters(in: .whitespaces).isEmpty { #expect(log.contains(firstLine)) }
        }
    }

    @Test func missingExecutableFailsQuicklyAndIsLogged() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let start = ContinuousClock.now
        let result = await fixture.ask(["/synthetic/not-installed", "{prompt}"], timeout: .seconds(30), resolves: false)
        #expect(start.duration(to: .now) < .seconds(3))
        #expect(result.isError)
        #expect(result.text.lowercased().contains("not installed"))
        _ = try fixture.log()
    }

    @Test func helperReceivesExactArgvCwdEnvironmentAndImmediateStdinEOF() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("""
        [ "$#" -eq 2 ] || exit 11
        [ "$2" = 'literal argument' ] || exit 12
        printf '%s' "$1" > received
        pwd -P > working-directory
        printf '%s' "$BTON_HELPER" > environment
        if IFS= read -r line; then exit 13; fi
        printf '  Synthetic answer \\n '
        """)
        let question = "spaces 'single' \"double\" $(touch injected); end\nsecond line"
        let result = await fixture.ask([program, "{prompt}", "literal argument"], question: question)
        #expect(result == Helpers.AskResult(text: "Synthetic answer", isError: false))
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("received")) == Data(question.utf8))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("environment"), encoding: .utf8) == "1")
        let actual = try String(contentsOf: fixture.root.appendingPathComponent("working-directory"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let actualPath = try HelpersFixture.canonical(actual)
        let expectedPath = try HelpersFixture.canonical(fixture.root.path)
        #expect(actualPath == expectedPath)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("injected").path))
        let log = try fixture.log(question: String(question.split(separator: "\n")[0]))
        #expect(log.contains("Synthetic answer"))
    }

    @Test func claudeHelperIsHardenedCannotDelegateAndRecordsFreshSessions() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf '%s\\n' \"$@\" > arguments; printf 'Claude answer'", name: "claude")
        var sessions: [String] = []
        for _ in 0..<2 {
            let result = await fixture.ask([program, "--session-id", "{session}", "-p", "{prompt}"])
            #expect(!result.isError)
            let argv = try String(contentsOf: fixture.root.appendingPathComponent("arguments"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            let source = try #require(argv.firstIndex(of: "--setting-sources"))
            #expect(argv[source + 1] == "user")
            #expect(argv.contains("--strict-mcp-config"))
            #expect(!argv.contains { $0.hasPrefix("--mcp-config") })
            let index = try #require(argv.firstIndex(of: "--session-id"))
            let session = argv[index + 1]
            let uuid = try #require(UUID(uuidString: session))
            #expect(uuid.uuidString.lowercased() == session)
            sessions.append(session)
        }
        #expect(Set(sessions).count == 2)
        let recorded = try String(contentsOf: fixture.jobs.helperSessionsURL(fixture.job), encoding: .utf8)
        #expect(recorded == sessions.joined(separator: "\n") + "\n")
        #expect(try fixture.log().contains("Claude answer"))
    }

    @Test func defaultResolverRunsAbsoluteSyntheticProgramAndFillsNonClaudeSession() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("[ \"$#\" -eq 2 ] || exit 14; printf '%s' \"$2\"")
        let result = await Helpers.ask(agent: "helper", question: "Synthetic question",
            allowed: ["helper"], agents: ["helper": AgentTemplate(argv: [program, "{prompt}", "{session}"])],
            cwd: fixture.root, job: fixture.job, jobs: fixture.jobs, timeout: .seconds(5))
        #expect(!result.isError)
        let session = try #require(UUID(uuidString: result.text))
        #expect(result.text == session.uuidString.lowercased())
        #expect(try fixture.log().contains(result.text))
    }

    @Test func questionAndOutputLimitsIncludeExactBoundary() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf '%s' \"$1\"")
        let boundary = String(repeating: "a", count: 20_000)
        let exact = await fixture.ask([program, "{prompt}"], question: boundary)
        #expect(exact == Helpers.AskResult(text: boundary, isError: false))
        let large = try fixture.script("i=0; while [ \"$i\" -lt 20001 ]; do printf a; i=$((i + 1)); done", name: "large-output")
        let cut = await fixture.ask([large])
        #expect(!cut.isError)
        #expect(String(cut.text.prefix(20_000)) == boundary)
        let notice = String(cut.text.dropFirst(20_000))
        #expect(notice.hasPrefix("\n"))
        #expect(notice.lowercased().contains("cut") || notice.lowercased().contains("truncat"))
    }

    @Test func nonzeroExitReportsStatusStderrTailAndLogsFailure() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("i=0; while [ \"$i\" -lt 25000 ]; do printf x >&2; i=$((i + 1)); done; printf '\\nSynthetic stderr tail\\n' >&2; exit 23")
        let result = await fixture.ask([program])
        #expect(result.isError)
        #expect(result.text.contains("23"))
        #expect(result.text.contains("Synthetic stderr tail"))
        let log = try fixture.log()
        #expect(log.contains("23"))
        #expect(log.contains("Synthetic stderr tail"))
    }

    @Test func timeoutStopsWholeProcessGroupAndLogsFailure() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("sleep 30 &\nchild=$!\nprintf '%s' \"$child\" > child-pid\nwait")
        let start = ContinuousClock.now
        // Allow the script to record its child PID under full-suite parallel load.
        let result = await fixture.ask([program], timeout: .seconds(4))
        #expect(start.duration(to: .now) < .seconds(8))
        #expect(result.isError)
        let pidText = try String(contentsOf: fixture.root.appendingPathComponent("child-pid"), encoding: .utf8)
        let pid = try #require(Int32(pidText))
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let probe = kill(pid, 0)
        let probeError = errno
        #expect(probe == -1 && probeError == ESRCH)
        let log = try fixture.log().lowercased()
        #expect(log.contains("timeout") || log.contains("timed out"))
    }

    @Test func askServerInitializeNotificationsPingAndIds() async throws {
        let server = AskServer(helpers: ["codex"]) { _, _ in Helpers.AskResult(text: "unused", isError: false) }
        let initialize = try #require(await server.respond(to: #"{"jsonrpc":"2.0","id":42,"method":"initialize","params":{"protocolVersion":"synthetic-version"}}"#))
        let reply = try HelpersFixture.object(initialize)
        #expect(reply["jsonrpc"] as? String == "2.0")
        #expect(reply["id"] as? Int == 42)
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "synthetic-version")
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] is [String: Any])
        let info = try #require(result["serverInfo"] as? [String: Any])
        #expect(info["name"] as? String == "bton")
        let defaultInit = try #require(await server.respond(to: #"{"id":1,"method":"initialize"}"#))
        #expect(try #require(HelpersFixture.object(defaultInit)["result"] as? [String: Any])["protocolVersion"] is String)
        for line in [#"{"method":"notifications/initialized"}"#, #"{"method":"ping"}"#,
                     #"{"method":"unknown"}"#, #"{"method":"tools/call","params":{"name":"ask","arguments":{"agent":"codex","question":"Synthetic"}}}"#] {
            #expect(await server.respond(to: line) == nil)
        }
        let ping = try #require(await server.respond(to: #"{"jsonrpc":"2.0","id":"string id","method":"ping"}"#))
        let pong = try HelpersFixture.object(ping)
        #expect(pong["jsonrpc"] as? String == "2.0")
        #expect(pong["id"] as? String == "string id")
        #expect((pong["result"] as? [String: Any])?.isEmpty == true)
    }

    @Test func askServerListsExactlyOneConstrainedToolOrNone() async throws {
        for names in [["codex", "second agent"], []] {
            let server = AskServer(helpers: names) { _, _ in Helpers.AskResult(text: "unused", isError: false) }
            let line = try #require(await server.respond(to: #"{"id":1,"method":"tools/list"}"#))
            let result = try #require(HelpersFixture.object(line)["result"] as? [String: Any])
            let tools = try #require(result["tools"] as? [[String: Any]])
            #expect(tools.count == (names.isEmpty ? 0 : 1))
            if names.isEmpty { continue }
            let tool = try #require(tools.first)
            #expect(tool["name"] as? String == "ask")
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect(Set(try #require(schema["required"] as? [String])) == ["agent", "question"])
            let properties = try #require(schema["properties"] as? [String: [String: Any]])
            #expect(properties["agent"]?["enum"] as? [String] == names)
            #expect(properties["question"]?["type"] as? String == "string")
        }
    }

    @Test func askServerCallsOnceMirrorsResultAndRefusesWithoutCalling() async throws {
        let calls = AskCalls()
        for isError in [false, true] {
            let server = AskServer(helpers: ["codex"]) { agent, question in
                await calls.record(agent, question)
                return Helpers.AskResult(text: "Synthetic \"answer\"\nnext", isError: isError)
            }
            let line = try #require(await server.respond(to: #"{"jsonrpc":"2.0","id":"call","method":"tools/call","params":{"name":"ask","arguments":{"agent":"codex","question":"Synthetic question"}}}"#))
            let reply = try HelpersFixture.object(line)
            #expect(reply["id"] as? String == "call")
            #expect(reply["jsonrpc"] as? String == "2.0")
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == isError)
            let content = try #require(result["content"] as? [[String: String]])
            #expect(content == [["type": "text", "text": "Synthetic \"answer\"\nnext"]])
        }
        let recorded = await calls.calls
        #expect(recorded == Array(repeating: ["codex", "Synthetic question"], count: 2))
        for (names, tool, agent) in [(["codex"], "ask", "forbidden"), (["codex"], "unknown", "codex"), ([], "ask", "codex")] {
            let server = AskServer(helpers: names) { agent, question in
                await calls.record(agent, question)
                return Helpers.AskResult(text: "must not run", isError: false)
            }
            let request: [String: Any] = ["id": 2, "method": "tools/call", "params": [
                "name": tool, "arguments": ["agent": agent, "question": "Synthetic question"]]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let line = try #require(await server.respond(to: text))
            let result = try #require(HelpersFixture.object(line)["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
        }
        #expect(await calls.calls == recorded)
    }

    @Test func askServerRejectsInvalidArgumentsMethodsAndMalformedJSON() async throws {
        let calls = AskCalls()
        let server = AskServer(helpers: ["codex"]) { agent, question in
            await calls.record(agent, question)
            return Helpers.AskResult(text: "must not run", isError: false)
        }
        let invalidArguments: [Any] = [[:], ["agent": "codex"], ["question": "Synthetic"],
            ["agent": 3, "question": "Synthetic"], ["agent": "codex", "question": false], NSNull()]
        for arguments in invalidArguments {
            let request: [String: Any] = ["id": "bad args", "method": "tools/call",
                "params": ["name": "ask", "arguments": arguments]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
            let line = try #require(await server.respond(to: text))
            let reply = try HelpersFixture.object(line)
            #expect(reply["id"] as? String == "bad args")
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == -32602)
        }
        for (request, code) in [(#"{"id":17,"method":"unknown"}"#, -32601), ("not JSON", -32700)] {
            let line = try #require(await server.respond(to: request))
            let reply = try HelpersFixture.object(line)
            #expect(reply["jsonrpc"] as? String == "2.0")
            #expect((reply["error"] as? [String: Any])?["code"] as? Int == code)
            if code == -32700 { #expect(reply["id"] is NSNull) }
            else { #expect(reply["id"] as? Int == 17) }
        }
        #expect(await calls.calls.isEmpty)
    }

    @Test func helperConfigHardeningMergesPermissionsKeepsSandboxAndIsIdempotent() throws {
        let config = "/synthetic/bton config \"quoted\".json"
        let own = "/synthetic/own config.json"
        let template = ["/synthetic/claude", "--mcp-config", own, "--settings",
            #"{"permissions":{"allow":["Read","mcp__bton__ask"]},"sandbox":{"enabled":false,"failIfUnavailable":false,"allowUnsandboxedCommands":true}}"#,
            "-p", "{prompt}"]
        let once = AgentHardening.hardened(template, model: nil, helpersConfig: config)
        let configs = HelpersFixture.values("--mcp-config", once)
        #expect(configs.contains(own))
        #expect(configs.filter { $0 == config }.count == 1)
        let settingsText = try #require(HelpersFixture.values("--settings", once).first)
        let settings = try HelpersFixture.object(settingsText)
        let permissions = try #require(settings["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.contains("Read"))
        #expect(allow.filter { $0 == "mcp__bton__ask" }.count == 1)
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        #expect(AgentHardening.hardened(once, model: nil, helpersConfig: config) == once)
        let fresh = AgentHardening.hardened(["claude", "-p", "{prompt}"], model: nil, helpersConfig: config)
        let freshSettings = try HelpersFixture.object(try #require(HelpersFixture.values("--settings", fresh).first))
        #expect(((freshSettings["permissions"] as? [String: Any])?["allow"] as? [String])?.filter { $0 == "mcp__bton__ask" }.count == 1)
        for ignored: String? in [nil, "relative/config.json"] {
            #expect(AgentHardening.hardened(template, model: nil, helpersConfig: ignored) == AgentHardening.hardened(template))
        }
        let other = ["/synthetic/helper", "{prompt}", "{session}"]
        #expect(AgentHardening.hardened(other, model: nil, helpersConfig: config) == other)
        let session = UUID()
        #expect(DispatchPlanner.argv(other, prompt: "Synthetic task", session: session, model: nil, helpersConfig: config)
            == [other[0], "Synthetic task", session.uuidString.lowercased()])
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: session, model: nil, helpersConfig: "relative.json")
            == DispatchPlanner.argv(template, prompt: "Synthetic task", session: session))
        let dispatched = DispatchPlanner.argv(template, prompt: "Synthetic task", session: session,
                                               model: nil, helpersConfig: config)
        #expect(dispatched == once.map { $0 == "{prompt}" ? "Synthetic task" : $0 })
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: session, model: nil, helpersConfig: nil)
            == DispatchPlanner.argv(template, prompt: "Synthetic task", session: session))
    }

    @Test func scheduledCandidatesCarryHelpersAndPullRequestCandidatesHaveNone() throws {
        for names: [String]? in [nil, [], ["codex", "second"]] {
            let candidates = DispatchPlanner.scheduled([HelpersFixture.entry(names)], jobs: [],
                repo: "synthetic/widget", defaultBranch: "main", me: "octo")
            #expect(candidates.count == 1)
            #expect(try #require(candidates.first).helpers == (names ?? []))
        }
        let json = #"""
        {"version":1,"base":"main","tier":{"marker":"Tier:","values":["feature"],"default":"feature"},
         "reviews":{"feature":[{"heading":"## Review:"}]},"fixed":"## Fixed:",
         "moves":[{"move":"review","when":["no_review_or_response_newer"],"who":"author"}],
         "dispatch":{"review":{"agent":"claude","prompt":"Synthetic review.","timeoutMinutes":5}},
         "checks":{"beforeSession":[],"beforeMerge":[]},"caps":{"openPullRequestsPerDeveloper":2,"openPullRequestsTeam":6},
         "stale":{"pingHours":24,"escalateHours":48,"escalateTo":"octo"}}
        """#
        let flow = try JSONDecoder().decode(Flow.self, from: Data(json.utf8))
        let pr = PullRequest(repo: "synthetic/widget", number: 12, title: "Synthetic PR", author: "octo",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pull/12")!,
            headSha: String(repeating: "a", count: 40), headRef: "synthetic", baseRef: "main",
            body: "Tier: feature", isDraft: false, labels: [], assignees: ["octo"], comments: [], updatedAt: .now)
        let candidates = DispatchPlanner.candidates([pr], flow: flow, me: "octo", repo: "synthetic/widget")
        #expect(candidates.count == 1)
        #expect(try #require(candidates.first).helpers == [])
    }
}

private actor HelperCompletion {
    var result: Helpers.AskResult?
    func record(_ value: Helpers.AskResult) { result = value }
}

extension ScheduleHelpersAcceptanceTests {
    @Test func claudeHelperOverridesEveryUnsafePermissionFlagAndKeepsQuestionIntact() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf '%s\\0' \"$@\" > arguments; printf answer", name: "claude")
        let question = "Synthetic 'question'\n--permission-mode bypassPermissions"
        let result = await fixture.ask([program, "--permission-mode", "bypassPermissions",
            "--permission-mode=acceptEdits", "--dangerously-skip-permissions",
            "--permission-mode", "default", "--allow-dangerously-skip-permissions", "-p", "{prompt}"],
            question: question)
        #expect(!result.isError)
        let argv = try Data(contentsOf: fixture.root.appendingPathComponent("arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(argv.filter { $0 == question }.count == 1)
        #expect(argv.filter { $0 == "--permission-mode" }.count == 1)
        let mode = try #require(argv.firstIndex(of: "--permission-mode"))
        #expect(argv[mode + 1] == "plan")
        #expect(!argv.contains { $0.hasPrefix("--permission-mode=") })
        for removed in ["bypassPermissions", "acceptEdits", "default", "--dangerously-skip-permissions",
                        "--allow-dangerously-skip-permissions"] {
            #expect(!argv.contains(removed))
        }
        let denied = HelpersFixture.values("--disallowedTools", argv)
        for tool in ["Bash", "Edit", "Write", "NotebookEdit",
                     "Bash(gh api:*)", "Bash(gh pr merge:*)", "Bash(gh -R:*)", "Bash(gh --repo:*)",
                     "Bash(gh auth:*)", "Bash(gh secret:*)", "Bash(gh variable:*)", "Bash(gh alias:*)",
                     "Bash(gh extension:*)", "Bash(gh repo delete:*)", "Bash(gh repo edit:*)",
                     "Bash(gh repo rename:*)", "Bash(gh repo archive:*)", "Bash(gh ruleset:*)",
                     "Bash(gh workflow:*)", "Bash(gh run rerun:*)", "Bash(gh run cancel:*)",
                     "Bash(gh run delete:*)", "Bash(gh release:*)", "Bash(gh cache delete:*)",
                     "Bash(gh ssh-key:*)", "Bash(gh gpg-key:*)"] {
            #expect(denied.contains(tool))
        }
    }

    @Test func codexHelperOverridesEveryUnsafeSandboxFlagBeforePreservedSeparator() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf '%s\\0' \"$@\" > arguments; printf answer", name: "codex")
        let question = "Synthetic question\n--sandbox danger-full-access"
        for separator in [[], ["--"]] {
            let result = await fixture.ask([program, "exec", "--sandbox", "workspace-write",
                "--sandbox=danger-full-access", "-s", "workspace-write", "--full-auto",
                "--dangerously-bypass-approvals-and-sandbox", "--yolo"] + separator + ["{prompt}"],
                question: question)
            #expect(!result.isError)
            let argv = try Data(contentsOf: fixture.root.appendingPathComponent("arguments"))
                .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            #expect(argv.filter { $0 == question }.count == 1)
            #expect(argv.filter { $0 == "--sandbox" }.count == 1)
            let sandbox = try #require(argv.firstIndex(of: "--sandbox"))
            let prompt = try #require(argv.firstIndex(of: question))
            #expect(argv[sandbox + 1] == "read-only")
            #expect(sandbox + 1 < prompt)
            #expect(!argv.contains { $0.hasPrefix("--sandbox=") })
            for removed in ["-s", "workspace-write", "danger-full-access", "--full-auto",
                            "--dangerously-bypass-approvals-and-sandbox", "--yolo"] {
                #expect(!argv.contains(removed))
            }
            #expect(argv.filter { $0 == "--" }.count == separator.count)
            if !separator.isEmpty {
                let boundary = try #require(argv.firstIndex(of: "--"))
                #expect(sandbox + 1 < boundary)
                #expect(boundary + 1 == prompt)
            }
        }
    }

    @Test func otherHelperPreservesPermissionAndSandboxArgumentsExactly() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf '%s\\0' \"$@\" > arguments; printf answer")
        let question = "Synthetic question\nwith spaces"
        let template = ["--permission-mode", "bypassPermissions", "--permission-mode=acceptEdits",
            "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--sandbox",
            "workspace-write", "--sandbox=danger-full-access", "-s", "workspace-write", "--full-auto",
            "--dangerously-bypass-approvals-and-sandbox", "--yolo", "--", "{prompt}", "{session}"]
        let result = await fixture.ask([program] + template, question: question)
        #expect(!result.isError)
        let argv = try Data(contentsOf: fixture.root.appendingPathComponent("arguments"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        #expect(Array(argv.dropLast()) == template.dropLast().map { $0 == "{prompt}" ? question : $0 })
        let session = try #require(argv.last)
        #expect(UUID(uuidString: session) != nil)
    }

    @Test func stopHelpersKillsRegisteredGroupAndChildAndCompletesAskPromptly() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("sleep 30 &\nchild=$!\nprintf '%s' \"$child\" > child-pid\nwait")
        let completion = HelperCompletion()
        let task = Task {
            await completion.record(await fixture.ask([program], timeout: .seconds(30)))
        }
        defer { fixture.jobs.stopHelpers(fixture.job); task.cancel() }
        var groups: [Int32] = []
        let childFile = fixture.root.appendingPathComponent("child-pid")
        let startupDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < startupDeadline {
            groups = fixture.jobs.helperProcessGroups(fixture.job)
            if groups.count == 1, FileManager.default.fileExists(atPath: childFile.path),
               (try? String(contentsOf: childFile, encoding: .utf8).isEmpty) == false { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(groups.count == 1, "Helper process group was not registered within 15 seconds")
        try #require(
            (try? String(contentsOf: childFile, encoding: .utf8).isEmpty) == false,
            "Helper did not write a nonempty child-pid file within 15 seconds")
        let pid = try #require(Int32(try String(contentsOf: childFile, encoding: .utf8)))
        defer { if kill(pid, 0) == 0 { _ = kill(pid, SIGKILL) } }
        if let group = groups.first { #expect(getpgid(pid) == group) }
        let start = ContinuousClock.now
        fixture.jobs.stopHelpers(fixture.job)
        #expect(fixture.jobs.helperProcessGroups(fixture.job).isEmpty)
        var result: Helpers.AskResult?
        for _ in 0..<150 {
            result = await completion.result
            if result != nil, kill(pid, 0) == -1, errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(start.duration(to: .now) < .seconds(4))
        #expect(try #require(result).isError)
        let probe = kill(pid, 0)
        let probeError = errno
        #expect(probe == -1 && probeError == ESRCH)
        #expect(fixture.jobs.helperProcessGroups(fixture.job).isEmpty)
    }

    @Test func completedQuickHelperLeavesNoRegisteredProcessGroups() async throws {
        let fixture = try HelpersFixture()
        defer { fixture.remove() }
        let program = try fixture.script("printf answer")
        let result = await fixture.ask([program])
        #expect(!result.isError)
        #expect(fixture.jobs.helperProcessGroups(fixture.job).isEmpty)
    }
}
