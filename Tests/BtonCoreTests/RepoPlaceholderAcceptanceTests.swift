@testable import BtonCore
import Foundation
import Testing

private enum RepoPlaceholderFixture {
    static let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!

    static func values() throws -> [String: String] {
        try DispatchPlanner.repoValues(repo: "acme/widget", base: "develop",
                                       clone: URL(fileURLWithPath: "/tmp/x/../acme widget"))
    }

    static func value(_ flag: String, in argv: [String]) throws -> String {
        #expect(argv.filter { $0 == flag }.count == 1)
        let index = try #require(argv.firstIndex(of: flag))
        return try #require(argv.dropFirst(index + 1).first)
    }
}

struct RepoPlaceholderAcceptanceTests {
    @Test func repoValuesContainExactlyConfiguredRepoBranchAndStandardizedClone() throws {
        let values = try RepoPlaceholderFixture.values()
        #expect(values == ["{repo}": "acme/widget", "{base}": "develop", "{clone}": "/tmp/acme widget"])
    }

    @Test(arguments: ["-x", "a..b", ""])
    func invalidBaseBranchThrows(base: String) {
        do {
            _ = try DispatchPlanner.repoValues(repo: "acme/widget", base: base,
                                               clone: URL(fileURLWithPath: "/tmp/acme widget"))
            Issue.record("An invalid base branch must throw")
        } catch {}
    }

    @Test(arguments: ["\"", "\\", "\n", "\r", "\t", "\u{01}", "\u{7F}"])
    func clonePathsWithQuotesBackslashesOrControlCharactersThrow(character: String) {
        do {
            _ = try DispatchPlanner.repoValues(repo: "acme/widget", base: "develop",
                                               clone: URL(fileURLWithPath: "/tmp/acme\(character)widget"))
            Issue.record("A clone path containing a quote, backslash or control character must throw")
        } catch {}
    }

    @Test func fillReplacesEveryOccurrenceAndPreservesUnknownTokens() throws {
        let template = "{repo} {clone} {base}; {repo} {clone} {base}; {unknown}"
        let filled = DispatchPlanner.fill(template, try RepoPlaceholderFixture.values())
        #expect(filled == "acme/widget /tmp/acme widget develop; acme/widget /tmp/acme widget develop; {unknown}")
    }

    @Test func claudeArgvFillsEmbeddedRepoValuesAndKeepsSettingsValid() throws {
        let template = [
            "claude", "-p", "{prompt}", "--session-id", "{session}",
            "--append-system-prompt", "Work on {repo} at {clone}, base={base}; again {clone}.",
            "--allowedTools", "Bash(bash {clone}/scripts/wt merge:*)",
            "--settings", #"{"sandbox":{"excludedCommands":["bash {clone}/scripts/wt merge *"]}}"#,
        ]
        let argv = DispatchPlanner.argv(template, prompt: "Synthetic task", session: RepoPlaceholderFixture.session,
                                        values: try RepoPlaceholderFixture.values())
        let systemPrompt = try RepoPlaceholderFixture.value("--append-system-prompt", in: argv)
        #expect(systemPrompt.contains("Work on acme/widget at /tmp/acme widget, base=develop; again /tmp/acme widget."))
        #expect(try RepoPlaceholderFixture.value("--allowedTools", in: argv)
            == "Bash(bash /tmp/acme widget/scripts/wt merge:*)")
        let json = try RepoPlaceholderFixture.value("--settings", in: argv)
        let settings = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let sandbox = try #require(settings["sandbox"] as? [String: Any])
        #expect(sandbox["excludedCommands"] as? [String] == ["bash /tmp/acme widget/scripts/wt merge *"])
        #expect(!argv.contains { $0.contains("{clone}") || $0.contains("{base}") || $0.contains("{repo}") })
    }

    @Test func argvPreservesPromptVerbatimWithoutFillingItsRepoTokens() throws {
        let prompt = "{clone}\nSynthetic task for {repo} on {base}: \"quoted\" \\ text"
        let argv = DispatchPlanner.argv(["claude", "-p", "{prompt}"], prompt: prompt,
                                        session: RepoPlaceholderFixture.session,
                                        values: try RepoPlaceholderFixture.values())
        let actual = try RepoPlaceholderFixture.value("-p", in: argv)
        #expect(Array(actual.utf8) == Array(prompt.utf8))
        #expect(argv.filter { $0 == prompt }.count == 1)
    }

    @Test(arguments: ["claude", "codex"])
    func emptyValuesPreserveCallWithoutValues(executable: String) {
        let template = [executable, "-p", "{prompt}", "--session-id", "{session}", "-C", "{clone}"]
        let baseline = DispatchPlanner.argv(template, prompt: "Synthetic task", session: RepoPlaceholderFixture.session)
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: RepoPlaceholderFixture.session,
                                    values: [:]) == baseline)
    }

    @Test func nonClaudeArgvFillsRepoValuesInEveryElement() throws {
        let template = ["codex", "exec", "{prompt}", "-C", "{clone}", "--repo={repo}", "--base={base}"]
        let argv = DispatchPlanner.argv(template, prompt: "{clone}", session: RepoPlaceholderFixture.session,
                                        values: try RepoPlaceholderFixture.values())
        #expect(argv == ["codex", "exec", "{clone}", "-C", "/tmp/acme widget", "--repo=acme/widget", "--base=develop"])
    }

    @Test func schedulePromptIsFilledByCallerWithConfiguredRepoValues() throws {
        let prompt = "cd {clone} && git switch {base} for {repo}"
        let filled = DispatchPlanner.fill(prompt, try RepoPlaceholderFixture.values())
        #expect(filled == "cd /tmp/acme widget && git switch develop for acme/widget")
    }
}
