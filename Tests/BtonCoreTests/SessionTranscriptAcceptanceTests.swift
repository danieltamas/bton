@testable import BtonCore
import Foundation
import Testing

private enum SessionTranscriptFixture {
    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func expect(_ entries: [SessionTranscript.Entry], kinds: [SessionTranscript.Entry.Kind], texts: [String]) {
        #expect(entries.map(\.id) == Array(0..<texts.count))
        #expect(entries.map(\.kind) == kinds)
        #expect(entries.map(\.text) == texts)
    }

    static let conversation = #"""
    {"type":"user","message":{"content":"First prompt"}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"First answer"},{"type":"thinking","thinking":"Private reasoning"},{"type":"tool_use","name":"Bash","input":{"command":"pwd"}}]}}
    {"type":"user","message":{"content":[{"type":"tool_result","content":"/synthetic"}]}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"Last answer"}]}}
    """#
}

@Suite(ProcessBound())
struct SessionTranscriptAcceptanceTests {
    @Test func skipsMalformedLinesOtherRecordTypesAndMissingMessageObjects() {
        let json = #"""
        not JSON
        {"type":"attachment","message":{"content":"Ignored attachment"}}
        {"type":"queue-operation","message":{"content":"Ignored queue"}}
        {"type":"api-request","message":{"content":[{"type":"text","text":"Ignored request"}]}}
        {"type":"last-prompt","message":{"content":"Ignored last prompt"}}
        {"type":"user"}
        {"type":"assistant","message":"Not an object"}
        {"type":"user","message":null}
        []
        {broken
        {"type":"user","message":{"content":"Actual prompt"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Actual answer"}]}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.prompt, .text], texts: ["Actual prompt", "Actual answer"])
    }

    @Test func onlyFirstStringUserMessageBecomesPrompt() {
        let json = #"""
        {"type":"assistant","message":{"content":"Ignored assistant string"}}
        {"type":"user","message":{"content":[{"type":"text","text":"Array before prompt"}]}}
        {"type":"user","message":{"content":"  First prompt\nwith spacing  "}}
        {"type":"user","message":{"content":"Later user string"}}
        {"type":"assistant","message":{"content":"Later assistant string"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"Answer"}]}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.text, .prompt, .text],
                                        texts: ["Array before prompt", "  First prompt\nwith spacing  ", "Answer"])
    }

    @Test func emptyFirstPromptStillPreventsLaterStringPrompts() {
        let json = #"""
        {"type":"user","message":{"content":""}}
        {"type":"user","message":{"content":"Must not replace empty prompt"}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.prompt], texts: [""])
    }

    @Test func arrayBlocksKeepOrderSkipEmptyTextAndHideThinkingContent() {
        let json = #"""
        {"type":"assistant","message":{"content":[{"type":"text","text":"Before"},{"type":"text","text":""},{"type":"thinking","thinking":"Must stay hidden"},{"type":"unknown","text":"Ignored"},{"type":"text","text":" \n "},{"type":"thinking"}]}}
        {"type":"user","message":{"content":[{"type":"text","text":"User array text"},{"type":"tool_use","name":"Read","input":{"file_path":"/synthetic/file"}}]}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.text, .thinking, .text, .thinking, .text, .tool(name: "Read")],
                                        texts: ["Before", "", " \n ", "", "User array text", "/synthetic/file"])
    }

    @Test func toolInputsUseFirstNonEmptyPreferredFieldInSpecifiedOrder() {
        // Each message is one JSONL line; every candidate has lower-priority competitors.
        let blocks = [
            #"{"type":"tool_use","name":"Inspect","input":{"command":"cmd","file_path":"file","pattern":"pat","url":"link","query":"ask","description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"command":"","file_path":"file","pattern":"pat","url":"link","query":"ask","description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"command":"","file_path":"","pattern":"pat","url":"link","query":"ask","description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"command":"","file_path":"","pattern":"","url":"link","query":"ask","description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"query":"ask","description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"description":"desc","prompt":"instruction"}}"#,
            #"{"type":"tool_use","name":"Inspect","input":{"prompt":"instruction"}}"#
        ]
        let line = #"{"type":"assistant","message":{"content":["# + blocks.joined(separator: ",") + "]}}"
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(line), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: Array(repeating: .tool(name: "Inspect"), count: 7),
                                        texts: ["cmd", "file", "pat", "link", "ask", "desc", "instruction"])
    }

    @Test func toolDefaultsNameAndFallsBackToStringOrEmptyInputSummary() {
        let json = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","input":{"custom":"Fallback","count":3}},{"type":"tool_use","name":"NoStrings","input":{"count":3,"enabled":true}},{"type":"tool_use","input":{}},{"type":"tool_use"}]}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.tool(name: "tool"), .tool(name: "NoStrings"),
                                                         .tool(name: "tool"), .tool(name: "tool")],
                                        texts: ["Fallback", "", "", ""])
    }

    @Test func toolResultsPreserveStringsJoinArrayTextAndDefaultErrorFlag() {
        let json = #"""
        {"type":"user","message":{"content":[{"type":"tool_result","content":"line one\nline two"},{"type":"tool_result","is_error":true,"content":[{"type":"text","text":"Failed"},{"type":"image","source":{}},{"type":"text","text":""},{"type":"text","text":"Details"}]},{"type":"tool_result","is_error":false,"content":[]},{"type":"tool_result","content":""}]}}
        """#
        let entries = SessionTranscript.entries(in: SessionTranscriptFixture.data(json), limit: 100)
        SessionTranscriptFixture.expect(entries, kinds: [.result(isError: false), .result(isError: true),
                                                         .result(isError: false), .result(isError: false)],
                                        texts: ["line one\nline two", "Failed\n\nDetails", "", ""])
    }

    @Test func limitsKeepNewestEntriesAndRenumberIdsAfterCut() {
        let data = SessionTranscriptFixture.data(SessionTranscriptFixture.conversation)
        for limit in [0, 1, 3, 6, 20] {
            let kinds: [SessionTranscript.Entry.Kind] = [.prompt, .text, .thinking, .tool(name: "Bash"),
                                                        .result(isError: false), .text]
            let texts = ["First prompt", "First answer", "", "pwd", "/synthetic", "Last answer"]
            let entries = SessionTranscript.entries(in: data, limit: limit)
            SessionTranscriptFixture.expect(entries, kinds: Array(kinds.suffix(limit)), texts: Array(texts.suffix(limit)))
        }
        #expect(SessionTranscript.entries(in: Data(), limit: 10).isEmpty)
    }

    @Test func fileEntryPointReadsTranscriptAndAppliesLimit() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        try SessionTranscriptFixture.data(SessionTranscriptFixture.conversation).write(to: file)
        let entries = SessionTranscript.entries(ofSessionFile: file, limit: 2)
        SessionTranscriptFixture.expect(entries, kinds: [.result(isError: false), .text], texts: ["/synthetic", "Last answer"])
    }

    @Test func missingAndUnreadableFilesReturnNoEntries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-transcript-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SessionTranscript.entries(ofSessionFile: root.appendingPathComponent("missing.jsonl"), limit: 10).isEmpty)
        // A directory cannot be read as transcript data, even when tests run with elevated privileges.
        #expect(SessionTranscript.entries(ofSessionFile: root, limit: 10).isEmpty)
    }
}
