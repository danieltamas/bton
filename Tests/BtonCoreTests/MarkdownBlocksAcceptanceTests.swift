import Foundation
@testable import BtonCore
import Testing

struct MarkdownBlocksAcceptanceTests {
    private func chars(_ b: Markdown.Block) -> String { String(b.text.characters) }

    @Test func headingsKeepTheirLevelsAndText() throws {
        let blocks = Markdown.blocks(of: "# A\n## B\n### C")
        try #require(blocks.count == 3)
        for (index, block) in blocks.enumerated() {
            guard case .heading(let level) = block.kind else {
                Issue.record("Expected a heading")
                continue
            }
            #expect(level == index + 1)
            #expect(chars(block) == ["A", "B", "C"][index])
        }
    }

    @Test func blankLineSeparatesPlainParagraphs() throws {
        let blocks = Markdown.blocks(of: "first\n\nsecond")
        try #require(blocks.count == 2)
        #expect(blocks.map { chars($0) } == ["first", "second"])
        for block in blocks {
            guard case .paragraph = block.kind else {
                Issue.record("Expected a paragraph")
                continue
            }
            #expect(block.depth == 0)
            #expect(block.marker == nil)
            #expect(!block.quoted)
        }
    }

    @Test func singleNewlineStaysInsideOneParagraph() throws {
        let blocks = Markdown.blocks(of: "first line\nsecond line")
        try #require(blocks.count == 1)
        guard case .paragraph = blocks[0].kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(chars(blocks[0]).contains("first line\nsecond line"))
    }

    @Test func hardBreaksAddsSpacesOnlyBeforeTheParagraphContinues() {
        #expect(Markdown.hardBreaks("first line\nsecond line") == "first line  \nsecond line")
    }

    @Test func hardBreaksLeavesFencedCodeUntouched() {
        let source = "```swift\nlet x = 1\nlet y = 2\n```"
        #expect(Markdown.hardBreaks(source) == source)
    }

    @Test(arguments: ["- item", "## Heading"])
    func hardBreaksLeavesLinesBeforeBlockStartsAlone(next: String) {
        let source = "before\n" + next
        #expect(Markdown.hardBreaks(source) == source)
    }

    @Test func hardBreaksNormalizesCRLF() {
        #expect(Markdown.hardBreaks("first\r\nsecond") == "first  \nsecond")
    }

    @Test func unorderedItemsAreMarkedParagraphs() throws {
        let blocks = Markdown.blocks(of: "- one\n- two")
        try #require(blocks.count == 2)
        #expect(blocks.map { chars($0) } == ["one", "two"])
        for block in blocks {
            guard case .paragraph = block.kind else {
                Issue.record("Expected a paragraph")
                continue
            }
            #expect(block.depth == 1)
            #expect(block.marker == "•")
        }
    }

    @Test func orderedItemsKeepTheirNumbers() throws {
        let blocks = Markdown.blocks(of: "1. one\n2. two")
        try #require(blocks.count == 2)
        #expect(blocks.map(\.marker) == ["1.", "2."])
        #expect(blocks.map(\.depth) == [1, 1])
    }

    @Test func nestedItemHasItsOwnDepthAndBullet() throws {
        let blocks = Markdown.blocks(of: "- a\n  - b")
        try #require(blocks.count == 2)
        #expect(chars(blocks[1]) == "b")
        #expect(blocks[1].depth == 2)
        #expect(blocks[1].marker == "•")
    }

    @Test func continuationParagraphKeepsDepthWithoutRepeatingMarker() throws {
        let blocks = Markdown.blocks(of: "- item text\n\n  continuation paragraph")
        try #require(blocks.count == 2)
        #expect(blocks.map { chars($0) } == ["item text", "continuation paragraph"])
        #expect(blocks.map(\.marker) == ["•", nil])
        #expect(blocks.map(\.depth) == [1, 1])
    }

    @Test func fencedCodeHasNoTrailingNewline() throws {
        let blocks = Markdown.blocks(of: "```swift\nlet x = 1\n```")
        try #require(blocks.count == 1)
        guard case .code = blocks[0].kind else {
            Issue.record("Expected code")
            return
        }
        #expect(chars(blocks[0]) == "let x = 1")
    }

    @Test func blockquoteMarksItsParagraph() throws {
        let block = try #require(Markdown.blocks(of: "> quoted").first)
        guard case .paragraph = block.kind else {
            Issue.record("Expected a paragraph")
            return
        }
        #expect(block.quoted)
        #expect(chars(block) == "quoted")
    }

    @Test func thematicBreakBecomesARule() throws {
        let blocks = Markdown.blocks(of: "before\n\n---\n\nafter")
        try #require(blocks.count == 3)
        guard case .rule = blocks[1].kind else {
            Issue.record("Expected a rule between paragraphs")
            return
        }
    }

    @Test func tableKeepsHeaderAndBodyWithoutSeparatorRow() throws {
        let source = "| # | Decision | Who |\n|---|----------|-----|\n| D-1 | Keep it | lee |\n| D-2 | Drop it | dani |"
        let blocks = Markdown.blocks(of: source)
        try #require(blocks.count == 1)
        guard case .table(let rows) = blocks[0].kind else {
            Issue.record("Expected a table")
            return
        }
        try #require(rows.count == 3)
        try #require(rows.allSatisfy { $0.count == 3 })
        #expect(String(rows[0][1].characters) == "Decision")
        #expect(String(rows[1][0].characters) == "D-1")
        #expect(String(rows[2][2].characters) == "dani")
    }

    @Test func inlineCodeKeepsItsPresentationIntent() throws {
        let block = try #require(Markdown.blocks(of: "use `code` and **bold**").first)
        #expect(block.text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.code) == true
                && String(block.text[run.range].characters) == "code"
        })
    }

    @Test func inlineBoldKeepsItsPresentationIntent() throws {
        let block = try #require(Markdown.blocks(of: "use `code` and **bold**").first)
        #expect(block.text.runs.contains { run in
            run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
                && String(block.text[run.range].characters) == "bold"
        })
    }

    @Test func linkKeepsItsURL() throws {
        let block = try #require(Markdown.blocks(of: "[GitHub](https://github.com)").first)
        #expect(block.text.runs.contains { $0.link == URL(string: "https://github.com") })
    }

    @Test func emptyInputHasNoNonemptyText() {
        let blocks = Markdown.blocks(of: "")
        #expect(blocks.allSatisfy { String($0.text.characters).isEmpty })
    }

    @Test func unclosedMarkupStillProducesABlock() {
        #expect(!Markdown.blocks(of: "**unclosed").isEmpty)
    }
}
