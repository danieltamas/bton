@testable import BtonCore
import Foundation
import Testing

private enum TeamInstructionsFixture {
    enum Failure: Error, Equatable { case unreadable }
    static let session = UUID(uuidString: "ABCDEF12-1234-1234-1234-123456789ABC")!

    static func expand(_ files: [String: String]) async throws -> String? {
        try await TeamInstructions.expand { path in
            #expect(!path.hasPrefix("/"))
            #expect(!path.hasPrefix("~"))
            #expect(!path.contains(".."))
            return files[path]
        }
    }

    static func systemPrompt(_ argv: [String]) throws -> String {
        #expect(argv.filter { $0 == "--append-system-prompt" }.count == 1)
        let index = try #require(argv.firstIndex(of: "--append-system-prompt"))
        return try #require(argv.dropFirst(index + 1).first)
    }

    static func git(_ arguments: [String], in directory: URL) async throws {
        let result = try await ProcessRunner().run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1",
                          "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(10))
        #expect(result.status == 0, "git \(arguments): \(result.stderr)")
        _ = try #require(result.status == 0)
    }
}

struct TeamInstructionsAcceptanceTests {
    @Test func absentClaudeFileReturnsNil() async throws {
        let result = try await TeamInstructionsFixture.expand(["AGENTS.md": "Synthetic unused guidance"])
        #expect(result == nil)
    }

    @Test func importsExpandRecursivelyRelativeToTheirImporter() async throws {
        let files = [
            "CLAUDE.md": "Start\n@docs/a.md\nInline @AGENTS.md end\n\t@AGENTS.md",
            "docs/a.md": "A @b.md\n@../x.md",
            "docs/b.md": "B",
            "x.md": "X",
            "AGENTS.md": "Synthetic team guidance",
        ]
        let result = try await TeamInstructionsFixture.expand(files)
        #expect(result == "Start\nA B\nX\nInline Synthetic team guidance end\n\tSynthetic team guidance")
    }

    @Test func missingImportsAndAtSignsInsideWordsStayLiteral() async throws {
        let text = "@missing.md\ndev@example.com foo@bar\n@present.md"
        let result = try await TeamInstructions.expand { path in
            #expect(["CLAUDE.md", "missing.md", "present.md"].contains(path))
            return ["CLAUDE.md": text, "example.com": "Wrong", "bar": "Wrong",
                    "present.md": "Present"][path]
        }
        #expect(result == "@missing.md\ndev@example.com foo@bar\nPresent")
    }

    @Test func fencedImportsStayLiteralAndImportsResumeAfterFence() async throws {
        let text = "```markdown\n@hidden.md\n```\n@visible.md\n  ```\n@hidden.md\n  ```"
        let result = try await TeamInstructions.expand { path in
            #expect(path != "hidden.md")
            return ["CLAUDE.md": text, "hidden.md": "Wrong", "visible.md": "Visible"][path]
        }
        #expect(result == "```markdown\n@hidden.md\n```\nVisible\n  ```\n@hidden.md\n  ```")
    }

    @Test func unsafeImportsStayLiteralWithoutReadingOutsideRepository() async throws {
        let text = "@/etc/passwd @~/x @../outside.md @docs/a.md"
        let result = try await TeamInstructions.expand { path in
            #expect(["CLAUDE.md", "docs/a.md", "x.md"].contains(path))
            #expect(!path.hasPrefix("/"))
            #expect(!path.hasPrefix("~"))
            #expect(!path.contains(".."))
            return ["CLAUDE.md": text,
                    "docs/a.md": "@../../outside.md @../x.md", "x.md": "Inside"][path]
        }
        #expect(result == "@/etc/passwd @~/x @../outside.md @../../outside.md Inside")
    }

    @Test func cyclicImportsTerminateWithRepeatedImportLiteral() async throws {
        let result = try await TeamInstructionsFixture.expand([
            "CLAUDE.md": "@a.md", "a.md": "A @b.md", "b.md": "B @a.md",
        ])
        #expect(result == "A B @a.md")
    }

    @Test func sixthImportLevelStaysLiteral() async throws {
        let files = ["CLAUDE.md": "@one.md", "one.md": "1 @two.md", "two.md": "2 @three.md",
                     "three.md": "3 @four.md", "four.md": "4 @five.md",
                     "five.md": "5 @six.md", "six.md": "6"]
        let result = try await TeamInstructions.expand { path in
            #expect(path != "six.md")
            return files[path]
        }
        #expect(result == "1 2 3 4 5 @six.md")
    }

    @Test func exactlyTwoHundredThousandUTF8BytesAreAccepted() async throws {
        let text = String(repeating: "é", count: 100_000)
        #expect(text.utf8.count == 200_000)
        let result = try await TeamInstructionsFixture.expand(["CLAUDE.md": text])
        #expect(result == text)
    }

    @Test func expandedResultOverUTF8ByteLimitThrows() async {
        let files = ["CLAUDE.md": "@part.md @part.md",
                     "part.md": String(repeating: "é", count: 50_000)]
        do {
            _ = try await TeamInstructionsFixture.expand(files)
            Issue.record("An expanded result over 200,000 UTF-8 bytes must throw")
        } catch {}
    }

    @Test func readErrorsPropagateUnchanged() async {
        do {
            _ = try await TeamInstructions.expand { path in
                if path == "CLAUDE.md" { return "@unreadable.md" }
                throw TeamInstructionsFixture.Failure.unreadable
            }
            Issue.record("An imported file's read error must propagate")
        } catch {
            #expect(error as? TeamInstructionsFixture.Failure == .unreadable)
        }
    }

    @Test(arguments: ["claude", "/opt/homebrew/bin/claude"])
    func claudeSystemPromptStartsWithUnsubstitutedTeamInstructions(executable: String) throws {
        let template = [executable, "-p", "{prompt}", "--session-id", "{session}"]
        let instructions = "Synthetic team guidance: {prompt} and {session}."
        let baseline = DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session)
        let argv = DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session,
                                        instructions: instructions)
        let text = try TeamInstructionsFixture.systemPrompt(argv)
        let ownText = try TeamInstructionsFixture.systemPrompt(baseline)
        #expect(text.hasPrefix(instructions))
        #expect(text.dropFirst(instructions.count).hasSuffix(ownText))
        #expect(ownText.lowercased().contains("data"))
        #expect(ownText.lowercased().contains("instructions"))
        #expect(argv.contains("Synthetic task"))
        #expect(argv.contains(TeamInstructionsFixture.session.uuidString.lowercased()))
    }

    @Test func nilInstructionsPreserveThreeArgumentDispatch() {
        let template = ["claude", "-p", "{prompt}"]
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session,
                                    instructions: nil)
            == DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session))
    }

    @Test func nonClaudeTemplateIgnoresTeamInstructions() {
        let template = ["synthetic-agent", "{prompt}", "--session={session}"]
        let baseline = DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session)
        #expect(DispatchPlanner.argv(template, prompt: "Synthetic task", session: TeamInstructionsFixture.session,
                                    instructions: "Synthetic guidance {prompt} {session}") == baseline)
    }

    @Test func gitEnvironmentRewritesSSHAndResetsCredentialsBeforeGitHubHelper() throws {
        let environment = Dispatcher.gitOverHTTPS(ghPath: "/opt/homebrew/bin/gh")
        let count = try #require(environment["GIT_CONFIG_COUNT"].flatMap(Int.init))
        #expect(count >= 4)
        #expect(environment.keys.filter { $0.hasPrefix("GIT_CONFIG_KEY_") }.count == count)
        #expect(environment.keys.filter { $0.hasPrefix("GIT_CONFIG_VALUE_") }.count == count)
        var rewrites: [String] = []
        var helpers: [String] = []
        for index in 0..<count {
            let key = try #require(environment["GIT_CONFIG_KEY_\(index)"])
            let value = try #require(environment["GIT_CONFIG_VALUE_\(index)"])
            if key == "url.https://github.com/.insteadOf" { rewrites.append(value) }
            if key == "credential.https://github.com.helper" { helpers.append(value) }
        }
        #expect(Set(rewrites) == Set(["git@github.com:", "ssh://git@github.com/"]))
        #expect(helpers == ["", "!/opt/homebrew/bin/gh auth git-credential"])
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    }

    @Test(.timeLimit(.minutes(1))) func readsInstructionsFromBaseTreeInsteadOfCheckout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-team-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await TeamInstructionsFixture.git(["init", "--initial-branch=main"], in: root)
        try Data("Synthetic repository\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try await TeamInstructionsFixture.git(["add", "README.md"], in: root)
        let identity = ["-c", "user.name=Synthetic Tester", "-c", "user.email=synthetic@example.invalid",
                        "-c", "commit.gpgsign=false", "commit", "-m"]
        try await TeamInstructionsFixture.git(identity + ["Synthetic empty instructions tree"], in: root)
        try await TeamInstructionsFixture.git(["update-ref", "refs/remotes/origin/without-instructions", "HEAD"], in: root)
        try Data("@AGENTS.md\n".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        try Data("Synthetic reviewed team guidance\n".utf8).write(to: root.appendingPathComponent("AGENTS.md"))
        try await TeamInstructionsFixture.git(["add", "CLAUDE.md", "AGENTS.md"], in: root)
        try await TeamInstructionsFixture.git(identity + ["Synthetic reviewed instructions"], in: root)
        try await TeamInstructionsFixture.git(["update-ref", "refs/remotes/origin/main", "HEAD"], in: root)
        try Data("Synthetic checkout-only guidance".utf8).write(to: root.appendingPathComponent("CLAUDE.md"))
        try Data("Synthetic checkout-only imported text".utf8).write(to: root.appendingPathComponent("AGENTS.md"))

        let result = try await TeamInstructions.read(clone: root, base: "main", runner: ProcessRunner())
        let text = try #require(result)
        #expect(text.contains("Synthetic reviewed team guidance"))
        #expect(text.contains("main"))
        #expect(!text.contains("checkout-only"))
        let missing = try await TeamInstructions.read(clone: root, base: "without-instructions", runner: ProcessRunner())
        #expect(missing == nil)
        for base in ["-x", "a..b"] {
            do {
                _ = try await TeamInstructions.read(clone: root, base: base, runner: ProcessRunner())
                Issue.record("Invalid base \(base) must throw")
            } catch {}
        }
    }
}
