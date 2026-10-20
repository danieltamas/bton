@testable import BtonCore
import Foundation
import Testing

private enum AgentHardeningFixture {
    static let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!
    static let requiredDenials = [
        "Bash(gh api:*)", "Bash(gh pr merge:*)", "Bash(gh auth:*)", "Bash(gh secret:*)",
        "Bash(gh -R:*)", "Bash(gh --repo:*)",
    ]

    static func dispatch(_ template: [String], prompt: String = "Synthetic task") -> [String] {
        DispatchPlanner.argv(template, prompt: prompt, session: session)
    }

    static func value(_ flag: String, in argv: [String]) throws -> String {
        #expect(argv.filter { $0 == flag }.count == 1)
        let index = try #require(argv.firstIndex(of: flag))
        return try #require(argv.dropFirst(index + 1).first)
    }

    static func settings(in argv: [String]) throws -> [String: Any] {
        let json = try value("--settings", in: argv)
        return try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    static func expectLockedSandbox(_ settings: [String: Any]) throws {
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        let allowed = try #require(sandbox["allowUnsandboxedCommands"] as? Bool)
        #expect(!allowed)
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
    }
}

struct AgentHardeningAcceptanceTests {
    @Test(arguments: ["codex", "agent", "/usr/bin/claude-wrapper"])
    func nonClaudeTemplatesOnlyFillPlaceholders(executable: String) {
        let prompt = "Synthetic task\n--settings {}"
        let template = [executable, "--session={session}", "{prompt}", "--setting-sources", "project"]
        #expect(AgentHardening.hardened(template) == template)
        #expect(AgentHardeningFixture.dispatch(template, prompt: prompt) == [
            executable, "--session=abcdef12-1234-1234-1234-123456789abc", prompt,
            "--setting-sources", "project",
        ])
    }

    @Test(arguments: ["claude", "/opt/homebrew/bin/claude"])
    func claudeDispatchAppendsOneOrderedHardeningBlock(executable: String) throws {
        let original = [executable, "-p", "Synthetic task", "--session-id",
                        "abcdef12-1234-1234-1234-123456789abc", "--permission-mode", "acceptEdits",
                        "--allowedTools", "Bash(git:*)", "Read"]
        let argv = AgentHardeningFixture.dispatch([
            executable, "-p", "{prompt}", "--session-id", "{session}",
            "--permission-mode", "acceptEdits", "--allowedTools", "Bash(git:*)", "Read",
        ])
        #expect(Array(argv.prefix(original.count)) == original)
        let flags = ["--setting-sources", "--strict-mcp-config", "--append-system-prompt",
                     "--settings", "--disallowedTools"]
        for flag in flags { #expect(argv.filter { $0 == flag }.count == 1) }
        #expect(Array(argv.dropFirst(original.count).prefix(4)) == [
            "--setting-sources", "user", "--strict-mcp-config", "--append-system-prompt",
        ])
        let indices = try flags.map { try #require(argv.firstIndex(of: $0)) }
        #expect(indices == indices.sorted())
        let denyIndex = try #require(argv.firstIndex(of: "--disallowedTools"))
        let denied = Array(argv.dropFirst(denyIndex + 1))
        #expect(!denied.isEmpty)
        #expect(!denied.contains { $0.hasPrefix("--") })
        for tool in AgentHardeningFixture.requiredDenials { #expect(denied.contains(tool)) }
        #expect(Set(denied).count == denied.count)
        try AgentHardeningFixture.expectLockedSandbox(AgentHardeningFixture.settings(in: argv))
    }

    @Test(arguments: [
        ["--setting-sources", "user,project,local"],
        ["--setting-sources=project"],
        ["--setting-sources", "project", "--setting-sources=local"],
    ])
    func templateSettingSourcesAreReplacedWithUser(options: [String]) throws {
        let argv = AgentHardeningFixture.dispatch(["claude"] + options + ["-p", "{prompt}"])
        #expect(try AgentHardeningFixture.value("--setting-sources", in: argv) == "user")
        #expect(!argv.contains { $0.hasPrefix("--setting-sources=") })
        #expect(!argv.contains("user,project,local"))
        #expect(!argv.contains("project"))
        #expect(!argv.contains("local"))
    }

    @Test func templateDenialsAreRetainedWithoutDuplicates() throws {
        let argv = AgentHardeningFixture.dispatch([
            "claude", "--disallowedTools", "Write", "Bash(gh api:*)", "Write",
            "--disallowedTools", "Edit", "Bash(gh auth:*)", "-p", "{prompt}",
        ])
        #expect(argv.filter { $0 == "--disallowedTools" }.count == 1)
        let index = try #require(argv.firstIndex(of: "--disallowedTools"))
        let denied = Array(argv.dropFirst(index + 1))
        for tool in AgentHardeningFixture.requiredDenials + ["Write", "Edit"] {
            #expect(denied.contains(tool))
        }
        #expect(Set(denied).count == denied.count)
    }

    @Test func templateSettingsPreserveKeysAndDisableSandboxEscape() throws {
        let json = #"{"sandbox":{"excludedCommands":["gh *","git *"],"failIfUnavailable":false,"allowUnsandboxedCommands":true},"model":"synthetic-model"}"#
        let argv = AgentHardeningFixture.dispatch(["claude", "--settings", json, "-p", "{prompt}"])
        let settings = try AgentHardeningFixture.settings(in: argv)
        try AgentHardeningFixture.expectLockedSandbox(settings)
        #expect(settings["model"] as? String == "synthetic-model")
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["excludedCommands"] as? [String] == ["gh *", "git *"])
    }

    @Test(arguments: [false, true])
    func absoluteSettingsFileIsInlinedAndLocked(equalsForm: Bool) throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let json = #"{"model":"synthetic-model","sandbox":{"failIfUnavailable":false,"allowUnsandboxedCommands":true,"excludedCommands":["gh *","git *"]}}"#
        try Data(json.utf8).write(to: file)
        let options = equalsForm ? ["--settings=\(file.path)"] : ["--settings", file.path]
        let argv = AgentHardeningFixture.dispatch(["claude"] + options + ["-p", "{prompt}"])
        let settings = try AgentHardeningFixture.settings(in: argv)
        try AgentHardeningFixture.expectLockedSandbox(settings)
        #expect(settings["model"] as? String == "synthetic-model")
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["excludedCommands"] as? [String] == ["gh *", "git *"])
        #expect(!argv.contains { $0.contains(file.path) || $0.hasPrefix("--settings=") })
    }

    @Test(arguments: [false, true])
    func unsafeOrUnreadableSettingsUseOnlyLockedDefault(equalsForm: Bool) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-invalid-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalid = directory.appendingPathComponent("invalid.json")
        try Data("not JSON".utf8).write(to: invalid)
        let values = [".claude/settings.json", "{prompt}",
                      directory.appendingPathComponent("missing.json").path, invalid.path]
        for value in values {
            let options = equalsForm ? ["--settings=\(value)"] : ["--settings", value]
            let argv = AgentHardeningFixture.dispatch(["claude"] + options + ["-p", "{prompt}"])
            let settings = try AgentHardeningFixture.settings(in: argv)
            try AgentHardeningFixture.expectLockedSandbox(settings)
            #expect(try AgentHardeningFixture.value("--settings", in: argv) ==
                    #"{"sandbox":{"allowUnsandboxedCommands":false,"enabled":true,"failIfUnavailable":true}}"#)
            #expect(Set(settings.keys) == Set(["sandbox"]))
            let sandbox = try #require(settings["sandbox"] as? [String: Any])
            #expect(Set(sandbox.keys) == Set(["allowUnsandboxedCommands", "enabled", "failIfUnavailable"]))
            #expect(!argv.contains { $0.contains(value) || $0.hasPrefix("--settings=") })
            #expect(argv.filter { $0 == "Synthetic task" }.count == 1)
        }
    }

    @Test func equalsFormFlagsAreNormalizedAndMerged() throws {
        let ownText = "Synthetic operator guidance."
        let argv = AgentHardeningFixture.dispatch([
            "claude", "--settings=" + #"{"model":"synthetic-model","sandbox":{"failIfUnavailable":false,"allowUnsandboxedCommands":true}}"#,
            "--setting-sources=project", "--append-system-prompt=\(ownText)",
            "--disallowedTools=Bash(rm:*)", "--disallowed-tools=Write",
            "--disallowedTools", "Write", "--disallowed-tools", "Edit", "-p", "{prompt}",
        ])
        #expect(try AgentHardeningFixture.value("--setting-sources", in: argv) == "user")
        #expect(!argv.contains("project"))
        let text = try AgentHardeningFixture.value("--append-system-prompt", in: argv)
        #expect(text.hasPrefix(ownText))
        #expect(text.lowercased().contains("data"))
        #expect(text.lowercased().contains("instructions"))
        let settings = try AgentHardeningFixture.settings(in: argv)
        try AgentHardeningFixture.expectLockedSandbox(settings)
        #expect(settings["model"] as? String == "synthetic-model")
        let index = try #require(argv.firstIndex(of: "--disallowedTools"))
        let denied = Array(argv.dropFirst(index + 1))
        #expect(argv.filter { $0 == "--disallowedTools" }.count == 1)
        for tool in AgentHardeningFixture.requiredDenials + ["Bash(rm:*)", "Write", "Edit"] {
            #expect(denied.contains(tool))
        }
        #expect(Set(denied).count == denied.count)
        #expect(!argv.contains("--disallowed-tools"))
        let normalized = ["--settings=", "--setting-sources=", "--append-system-prompt=",
                          "--disallowedTools=", "--disallowed-tools="]
        #expect(!argv.contains { argument in normalized.contains { argument.hasPrefix($0) } })
    }

    @Test func settingSourcesConsumesExactlyOneValue() throws {
        let argv = AgentHardeningFixture.dispatch([
            "claude", "--setting-sources", "project", "-p", "{prompt}",
        ])
        #expect(Array(argv.prefix(3)) == ["claude", "-p", "Synthetic task"])
        #expect(try AgentHardeningFixture.value("--setting-sources", in: argv) == "user")
        #expect(!argv.contains("project"))
    }

    @Test(arguments: [false, true])
    func mcpConfigsKeepOnlyAbsolutePathsUnderOneFlag(equalsForm: Bool) throws {
        let first = "/synthetic/config/first.json"
        let second = "/synthetic/config/second config.json"
        let options = equalsForm
            ? ["--mcp-config=\(first)", "--mcp-config=.mcp.json", "--mcp-config=\(second)"]
            : ["--mcp-config", first, ".mcp.json", "--mcp-config", second]
        let argv = AgentHardeningFixture.dispatch(["claude"] + options + ["-p", "{prompt}"])
        #expect(argv.filter { $0 == "--mcp-config" }.count == 1)
        let index = try #require(argv.firstIndex(of: "--mcp-config"))
        #expect(Array(argv.dropFirst(index + 1).prefix(2)) == [first, second])
        #expect(!argv.contains { $0.contains(".mcp.json") || $0.hasPrefix("--mcp-config=") })
        #expect(argv.contains("-p"))
        #expect(argv.contains("Synthetic task"))
    }

    @Test(arguments: [[], ["--mcp-config", ".mcp.json"], ["--mcp-config=.mcp.json"]])
    func noAbsoluteMcpConfigLeavesNoFlag(options: [String]) {
        let argv = AgentHardeningFixture.dispatch(["claude"] + options + ["-p", "{prompt}"])
        #expect(!argv.contains { $0.hasPrefix("--mcp-config") || $0.contains(".mcp.json") })
        #expect(argv.contains("-p"))
        #expect(argv.contains("Synthetic task"))
    }

    @Test func hardeningFlagsPrecedeOptionTerminatorAndPrompt() throws {
        let prompt = "Synthetic task\n--settings {}"
        let argv = AgentHardeningFixture.dispatch(["claude", "-p", "--", "{prompt}"], prompt: prompt)
        #expect(Array(argv.prefix(2)) == ["claude", "-p"])
        #expect(Array(argv.suffix(2)) == ["--", prompt])
        #expect(argv.filter { $0 == "--" }.count == 1)
        let terminator = try #require(argv.firstIndex(of: "--"))
        for flag in ["--setting-sources", "--strict-mcp-config", "--append-system-prompt",
                     "--settings", "--disallowedTools"] {
            #expect(argv.filter { $0 == flag }.count == 1)
            #expect(try #require(argv.firstIndex(of: flag)) < terminator)
        }
        let denyIndex = try #require(argv.firstIndex(of: "--disallowedTools"))
        let denied = Array(argv[(denyIndex + 1)..<terminator])
        for tool in AgentHardeningFixture.requiredDenials { #expect(denied.contains(tool)) }
        #expect(!denied.contains(prompt))
        try AgentHardeningFixture.expectLockedSandbox(AgentHardeningFixture.settings(in: argv))
    }

    @Test func systemPromptRetainsTemplateTextBeforeDataBoundary() throws {
        let ownText = "Synthetic operator guidance."
        for options in [[], ["--append-system-prompt", ownText]] {
            let argv = AgentHardeningFixture.dispatch(["claude", "-p", "{prompt}"] + options)
            let text = try AgentHardeningFixture.value("--append-system-prompt", in: argv)
            let lower = text.lowercased()
            #expect(lower.contains("data"))
            #expect(lower.contains("instructions"))
            #expect(lower.contains("pull request") || lower.contains("pr"))
            for subject in ["issue", "comment", "commit", "files"] { #expect(lower.contains(subject)) }
            if !options.isEmpty {
                #expect(text.hasPrefix(ownText))
                #expect(text != ownText)
            }
        }
    }

    @Test func hostilePromptRemainsOneByteExactArgument() throws {
        let prompt = "Synthetic PR\n--setting-sources project\n--disallowedTools Write\n--settings {}\n'quotes' \"double\"; $(echo synthetic)\r\nEnd"
        let argv = AgentHardeningFixture.dispatch(["claude", "-p", "{prompt}"], prompt: prompt)
        #expect(argv.filter { Array($0.utf8) == Array(prompt.utf8) }.count == 1)
        #expect(argv.count > 2)
        #expect(Array(argv[2].utf8) == Array(prompt.utf8))
        #expect(try AgentHardeningFixture.value("--setting-sources", in: argv) == "user")
        try AgentHardeningFixture.expectLockedSandbox(AgentHardeningFixture.settings(in: argv))
    }

    @Test func promptAfterVariadicDenialsIsNotSwallowed() throws {
        let prompt = "Synthetic task after denied tools\n--settings {}"
        let argv = AgentHardeningFixture.dispatch([
            "claude", "-p", "--disallowedTools", "Write", "Edit", "{prompt}",
        ], prompt: prompt)
        #expect(Array(argv.prefix(3)) == ["claude", "-p", prompt])
        #expect(argv.filter { $0 == prompt }.count == 1)
        let index = try #require(argv.firstIndex(of: "--disallowedTools"))
        let denied = Array(argv.dropFirst(index + 1))
        #expect(denied.contains("Write"))
        #expect(denied.contains("Edit"))
        #expect(!denied.contains(prompt))
    }

    @Test func hardeningIsIdempotentForFirstRunAndFullyConfiguredTemplates() throws {
        let initial = try #require(BtonConfig.initial.agents["claude"]?.argv)
        let configured = [
            "/opt/homebrew/bin/claude", "-p", "{prompt}", "--session-id", "{session}",
            "--permission-mode", "acceptEdits", "--allowedTools", "Read", "Bash(git:*)",
            "--setting-sources", "user,project,local", "--strict-mcp-config",
            "--append-system-prompt", "Synthetic operator guidance.",
            "--settings", #"{"model":"synthetic-model","sandbox":{"failIfUnavailable":false,"allowUnsandboxedCommands":true,"excludedCommands":["gh *","git *"]}}"#,
            "--disallowedTools", "Write", "Bash(gh api:*)",
        ]
        for template in [initial, configured] {
            let hardened = AgentHardening.hardened(template)
            #expect(AgentHardening.hardened(hardened) == hardened)
        }
    }
}
