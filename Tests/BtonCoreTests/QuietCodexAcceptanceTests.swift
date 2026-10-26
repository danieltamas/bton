@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct QuietCodexAcceptanceTests {
    private let flags = ["--ignore-user-config", "--disable", "hooks"]
    private let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!

    @Test(arguments: ["codex", "/usr/local/bin/codex"])
    func flagsFollowExecAndPreserveRemainingArguments(executable: String) {
        let tail = ["--sandbox", "workspace-write", "--", "{prompt}", "{session}"]
        #expect(AgentHardening.quietCodex([executable, "exec"] + tail, userConfig: nil)
                == [executable, "exec"] + flags + tail)
    }

    @Test(arguments: [[], ["--", "{prompt}", "{session}"], ["--", "exec"], ["--", "e"]])
    func flagsFollowProgramWhenNoSubcommandPrecedesSeparator(tail: [String]) {
        #expect(AgentHardening.quietCodex(["codex"] + tail, userConfig: nil)
                == ["codex"] + flags + tail)
    }

    @Test(arguments: [
        (["--enable", "hooks", "exec"], ["{prompt}"]),
        (["-m", "synthetic", "e"], ["--", "{prompt}"]),
        (["e"], ["exec", "{prompt}"]),
        (["exec"], ["e", "--", "{prompt}"]),
    ])
    func flagsAndCarriedPairsFollowFirstExecOrAlias(prefix: [String], tail: [String]) {
        let template = ["codex"] + prefix + tail
        let expected = (["codex"] + prefix) + flags + ["-c", "model=\"synthetic\""] + tail
        #expect(AgentHardening.quietCodex(template, userConfig: "model = 'synthetic'") == expected)
    }

    @Test func carriesOnlySafeTopLevelStringsInFileOrder() {
        let config = """
          service_tier = "fast" # synthetic comment
        model_reasoning_effort="low"
          model = "Synthetic_9.1-test"
        """
        #expect(AgentHardening.quietCodex(["codex", "exec", "--", "{prompt}"], userConfig: config)
                == ["codex", "exec"] + flags + [
                    "-c", "service_tier=\"fast\"", "-c", "model_reasoning_effort=\"low\"",
                    "-c", "model=\"Synthetic_9.1-test\"", "--", "{prompt}",
                ])
    }

    @Test(arguments: ["model", "model_reasoning_effort", "service_tier"])
    func acceptsEmptyStringValues(key: String) {
        #expect(AgentHardening.quietCodex(["codex"], userConfig: "\(key) = \"\"")
                == ["codex"] + flags + ["-c", "\(key)=\"\""])
    }

    @Test(arguments: ["model", "model_reasoning_effort", "service_tier"], ["", "\"", "'"])
    func acceptsMatchingQuotedKeysAndStringValues(key: String, keyQuote: String) {
        for valueQuote in ["\"", "'"] {
            for value in ["", "low", "high", "Synthetic_9.1-test"] {
                let config = "\(keyQuote)\(key)\(keyQuote) = \(valueQuote)\(value)\(valueQuote)"
                #expect(AgentHardening.quietCodex(["codex"], userConfig: config)
                        == ["codex"] + flags + ["-c", "\(key)=\"\(value)\""])
            }
        }
    }

    @Test(arguments: ["model", "model_reasoning_effort", "service_tier"], [
        ("\"", "'"), ("'", "\""), ("", "\""), ("\"", ""), ("", "'"), ("'", ""),
    ])
    func rejectsMismatchedKeyOrValueQuotes(key: String, quotes: (String, String)) {
        let (opening, closing) = quotes
        for config in ["\(opening)\(key)\(closing) = \"low\"", "\(key) = \(opening)low\(closing)"] {
            #expect(AgentHardening.quietCodex(["codex"], userConfig: config) == ["codex"] + flags)
        }
    }

    @Test(arguments: ["notify", "approval_policy", "personality", "mcp_servers", "other", "model_extra"])
    func rejectsUnapprovedKeys(key: String) {
        #expect(AgentHardening.quietCodex(["codex"], userConfig: "\(key) = \"synthetic\"")
                == ["codex"] + flags)
    }

    @Test(arguments: ["model", "model_reasoning_effort", "service_tier"], [
        "low", "['low']", "[\"low\"]", "42", "true", "\"two words\"",
        "\"a/b\"", "\"a:b\"", "\"a$\"", "\"a;\"", "\"a\\b\"", "\"a[1]\"", "\"low\" trailing",
    ])
    func rejectsUnquotedArrayAndOddCharacterValues(key: String, value: String) {
        #expect(AgentHardening.quietCodex(["codex"], userConfig: "\(key) = \(value)")
                == ["codex"] + flags)
    }

    @Test(arguments: ["[mcp_servers.synthetic]", "[projects.\"/synthetic/repo\"]", "  [other]"])
    func firstTableCutsOffAllRemainingConfig(table: String) {
        let config = "model = \"synthetic\"\n\(table)\nmodel_reasoning_effort = \"high\"\nservice_tier = \"fast\""
        #expect(AgentHardening.quietCodex(["codex"], userConfig: config)
                == ["codex"] + flags + ["-c", "model=\"synthetic\""])
    }

    @Test(arguments: [nil, "", " \n# synthetic comment\n"] as [String?])
    func absentConfigAddsNoCarriedPairs(config: String?) {
        #expect(AgentHardening.quietCodex(["codex", "exec"], userConfig: config)
                == ["codex", "exec"] + flags)
    }

    @Test func existingIgnoreFlagMakesHardeningIdempotent() {
        let template = ["codex", "exec", "--ignore-user-config", "--", "{prompt}"]
        #expect(AgentHardening.quietCodex(template, userConfig: "model = \"synthetic\"") == template)
        let once = AgentHardening.quietCodex(["codex", "exec", "{prompt}"], userConfig: "model = \"synthetic\"")
        #expect(AgentHardening.quietCodex(once, userConfig: "service_tier = \"fast\"") == once)
        #expect(AgentHardening.hardened(AgentHardening.hardened(["codex", "exec", "{prompt}"]))
                == AgentHardening.hardened(["codex", "exec", "{prompt}"]))
    }

    @Test(arguments: ["codex", "/usr/local/bin/codex"])
    func codexIgnoresClaudeOptionsAndUsesQuietPath(executable: String) {
        let template = [executable, "exec", "--", "{prompt}", "{session}"]
        let expected = AgentHardening.quietCodex(template, userConfig: AgentHardening.codexUserConfig())
        #expect(AgentHardening.hardened(template) == expected)
        #expect(AgentHardening.hardened(template, model: "synthetic-model",
                                      helpersConfig: "/synthetic/helpers.json", scratch: "/synthetic/scratch") == expected)
    }

    @Test(arguments: ["agent", "/usr/bin/claude-wrapper", "codex-wrapper", "/synthetic/codex-wrapper"])
    func otherNonClaudeExecutablesRemainUnchanged(executable: String) {
        let template = [executable, "exec", "--", "{prompt}", "{session}"]
        #expect(AgentHardening.hardened(template, model: "synthetic-model",
                                      helpersConfig: "/synthetic/helpers.json", scratch: "/synthetic/scratch") == template)
    }

    @Test func readOnlyHelperDispatchKeepsOnlySafeCarriedPairs() throws {
        let prompt = "Synthetic review\n--sandbox workspace-write"
        let template = Helpers.readOnly(["codex", "exec", "--sandbox", "workspace-write", "--", "{prompt}"])
        let argv = DispatchPlanner.argv(template, prompt: prompt, session: session)
        #expect(Array(argv.prefix(5)) == ["codex", "exec"] + flags)
        let sandbox = try #require(argv.firstIndex(of: "--sandbox"))
        #expect(sandbox >= 5)
        #expect(Array(argv.dropFirst(sandbox)) == ["--sandbox", "read-only", "--", prompt])
        let carried = Array(argv[5..<sandbox])
        #expect(carried.count.isMultiple(of: 2))
        for (index, argument) in carried.enumerated() {
            if index.isMultiple(of: 2) {
                #expect(argument == "-c")
            } else {
                #expect(argument.range(of: #"^(model|model_reasoning_effort|service_tier)="[A-Za-z0-9._-]*"$"#,
                                       options: .regularExpression) != nil)
            }
        }
    }

    @Test func promptContainingIgnoreFlagIsFilledAfterHardening() {
        let argv = DispatchPlanner.argv(["codex", "exec", "--", "{prompt}"],
                                        prompt: "--ignore-user-config", session: session)
        #expect(Array(argv.prefix(5)) == ["codex", "exec"] + flags)
        #expect(Array(argv.suffix(2)) == ["--", "--ignore-user-config"])
        #expect(argv.filter { $0 == "--ignore-user-config" }.count == 2)
    }
}
