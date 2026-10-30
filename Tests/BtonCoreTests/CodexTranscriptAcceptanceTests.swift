import Foundation
import Testing
@testable import BtonCore

struct CodexTranscriptAcceptanceTests {
    private let fixture = """
    2026-10-30T13:10:34Z bton: agent starts
    ignored preamble
    OpenAI Codex v0.160.0
    --------
    model: gpt-6-astra
    user

      Review this change.

    2026-10-30T13:10:39.439320Z ERROR codex_core::worker: ignored trace
    codex
    ## Review

    Keep **Markdown** as written.
    exec
    /bin/zsh -lc 'git status --short' in /Users/x/wt
     succeeded in 322ms:

     M README.md

    exec
    /bin/zsh -lc 'git show missing' in /Users/x/wt
     exited 1 in 10ms:
    fatal: unknown revision
    thinking
    private reasoning must not be displayed
    tokens used
    1234
    user
    Drop this later prompt.
    codex

    """

    private func parse(_ text: String, limit: Int = 400) -> [SessionTranscript.Entry] {
        CodexTranscript.entries(in: Data(text.utf8), limit: limit)
    }

    @Test func parsesKindsTextCommandsAndExitStatus() {
        let entries = parse(fixture)
        #expect(entries.map(\.kind) == [
            .prompt, .text, .tool(name: "exec"), .result(isError: false),
            .tool(name: "exec"), .result(isError: true), .thinking
        ])
        #expect(entries.map(\.text) == [
            "Review this change.", "## Review\n\nKeep **Markdown** as written.",
            "git status --short", "M README.md", "git show missing",
            "fatal: unknown revision", ""
        ])
        #expect(entries.map(\.id) == Array(0..<7))
    }

    @Test func requiresBannerBeforeFirstExactMarker() {
        #expect(parse("2026-10-30T13:10:34Z bton: agent starts").isEmpty)
        #expect(parse("user\nOther agent\ncodex\nAnswer").isEmpty)
        #expect(parse("user\nOpenAI Codex v0.160.0\ncodex\nAnswer").isEmpty)
        let entries = parse("OpenAI Codex v0.160.0\ncodex\nA user says exec\n codex\nexec suffix\ntokens used\n12")
        #expect(entries.map(\.text) == ["A user says exec\n codex\nexec suffix"])
    }

    @Test func usesFirstNonemptyPromptAndDropsTraceLevels() {
        let traces = ["ERROR", "WARN", "INFO", "DEBUG"].map {
            "2026-10-30T13:10:39.439320Z \($0) codex_core::worker: trace"
        }.joined(separator: "\n")
        let entries = parse("OpenAI Codex v0.160.0\nuser\n  \nuser\nFirst\nuser\nLater\ncodex\nBefore\n\(traces)\nAfter")
        #expect(entries.map(\.kind) == [.prompt, .text])
        #expect(entries.map(\.text) == ["First", "Before\nAfter"])
    }

    @Test func incompleteExecStillProducesResultAndCapsOutputByCharacters() {
        let output = String(repeating: "é", count: 6_001)
        let entries = parse("OpenAI Codex v0.160.0\nexec\n/bin/zsh -lc 'printf output' in /Users/x/wt\n\(output)")
        #expect(entries.map(\.kind) == [.tool(name: "exec"), .result(isError: false)])
        #expect(entries.first?.text == "printf output")
        #expect(entries.last?.text == String(output.prefix(6_000)))
    }

    @Test func newestLimitRenumbersEntries() {
        let entries = parse(fixture, limit: 3)
        #expect(entries.map(\.kind) == [.tool(name: "exec"), .result(isError: true), .thinking])
        #expect(entries.map(\.id) == [0, 1, 2])
        #expect(parse(fixture, limit: 0).isEmpty)
    }

    @Test func publicFileReaderUsesDefaultLimit() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "OpenAI Codex v0.160.0\n" + (0..<405).map { "codex\nMessage \($0)\n" }.joined()
        try Data(text.utf8).write(to: url)
        let entries = CodexTranscript.entries(ofLog: url)
        #expect(entries.count == 400)
        #expect(entries.first?.text == "Message 5")
        #expect(entries.last?.text == "Message 404")
        #expect(entries.map(\.id) == Array(0..<400))
        #expect(CodexTranscript.entries(ofLog: url, limit: 1).map(\.text) == ["Message 404"])
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: realLogPath),
                   "Real Codex job log is absent"))
    func realLogFirst3000Lines() throws {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: Self.realLogPath))
        defer { try? handle.close() }
        var data = Data()
        var lines = 0
        while lines < 3_000, let byte = try handle.read(upToCount: 1), !byte.isEmpty {
            data.append(byte)
            if byte[0] == 10 { lines += 1 }
        }
        let entries = CodexTranscript.entries(in: data, limit: .max)
        #expect(entries.first?.kind == .prompt)
        #expect(entries.contains { $0.kind == .text })
        #expect(entries.contains { $0.kind == .tool(name: "exec") })
    }

    private static let realLogPath = "/Users/danime/.bton/jobs/D0F8B159-C614-4AC5-98B3-60D88AD40EE1.log"
}
