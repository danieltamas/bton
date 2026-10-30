import BtonCore
import SwiftUI

/// An issue body or comment drawn as GitHub shows it: headings, paragraphs, lists, quotes,
/// fenced code, tables and rules as blocks; bold, code spans and links inline. Foundation
/// parses the Markdown; the blocks are read off its presentation intents.
struct MarkdownView: View {
    let text: String
    /// The colour of running text: comments read in secondary, the one the screen is about in primary.
    var tone: Color = Theme.textSecondary

    /// The last texts parsed: a screen's body is evaluated far more often than its text changes.
    @MainActor private static var parsed: [String: [Markdown.Block]] = [:]

    @MainActor private static func blocks(of text: String) -> [Markdown.Block] {
        if let cached = parsed[text] { return cached }
        if parsed.count >= 200 { parsed.removeAll(keepingCapacity: true) }
        let blocks = Markdown.blocks(of: text)
        parsed[text] = blocks
        return blocks
    }

    var body: some View {
        let blocks = Self.blocks(of: text)
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(of: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(of block: Markdown.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            inList(block) {
                Text(styled(block.text))
                    .font(.system(size: level == 1 ? 15 : level == 2 ? 13.5 : 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.top, level <= 2 ? 6 : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .paragraph:
            inList(block) {
                Text(Self.task(styled(block.text))).font(.system(size: 11.5)).foregroundStyle(tone)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .code:
            inList(block) {
                ScrollView(.horizontal) {
                    Text(String(block.text.characters)).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.canvasLift, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        case .rule:
            inList(block) { Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 2) }
        case .table(let rows):
            table(rows)
        }
    }

    /// A list item hangs under its bullet or number, indented by its depth, and its later blocks
    /// hang under its text; a quoted block carries a bar at its left.
    @ViewBuilder private func inList(_ block: Markdown.Block, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 0) {
            if block.quoted {
                RoundedRectangle(cornerRadius: 1).fill(Theme.mint.opacity(0.6)).frame(width: 2).padding(.trailing, 8)
            }
            if block.depth > 0 {
                Text(block.marker ?? "").font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                    .frame(minWidth: 16, alignment: .trailing).padding(.trailing, 6)
            }
            content()
        }
        .padding(.leading, CGFloat(max(block.depth - 1, 0)) * 16)
    }

    private func table(_ rows: [[AttributedString]]) -> some View {
        let columns = rows.map(\.count).max() ?? 0
        // A column is as wide as its longest cell asks, so "#" and "Who" stay narrow and the
        // text column takes the rest; a long cell wraps within the pane.
        let longest = (0..<columns).map { column in rows.map { $0.count > column ? $0[column].characters.count : 0 }.max() ?? 0 }
        // The grid takes the pane's width and its cells wrap: inside a horizontal scroll a row
        // is measured one line tall whatever its cells wrap to, and the rows draw over each other.
        return Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { column in
                            Text(column < row.count ? styled(row[column]) : AttributedString())
                                .font(.system(size: 11, weight: index == 0 ? .semibold : .regular))
                                .foregroundStyle(index == 0 ? Theme.textPrimary : tone)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: CGFloat(longest[column]) * 6.6 + 12, alignment: .leading)
                                .padding(.vertical, 4)
                                .textSelection(.enabled)
                        }
                    }
                    if index < rows.count - 1 { Divider().overlay(Theme.hairline) }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.canvasLift.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Code spans in mint and monospaced, links in blue; bold, italic and strike come through
    /// the intents. `<ins>` and `<u>`, which GitHub underlines and Markdown has no mark for, are
    /// underlined here and their tags dropped.
    private func styled(_ text: AttributedString) -> AttributedString {
        var text = Self.underlined(text)
        for run in text.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                text[run.range].foregroundColor = Theme.mint
                text[run.range].font = .system(size: 10.5, design: .monospaced)
            }
            if run.link != nil {
                text[run.range].foregroundColor = Theme.blue
                text[run.range].underlineStyle = .single
            }
        }
        return text
    }

    /// A task list item, `[ ]` or `[x]` first, gets its box drawn.
    private static func task(_ text: AttributedString) -> AttributedString {
        let string = String(text.characters)
        let done = string.hasPrefix("[x] ") || string.hasPrefix("[X] ")
        guard done || string.hasPrefix("[ ] "), let end = text.characters.index(text.startIndex, offsetBy: 3, limitedBy: text.endIndex) else { return text }
        var text = text
        text.replaceSubrange(text.startIndex..<end, with: AttributedString(done ? "\u{2611}" : "\u{2610}"))
        return text
    }

    private static func underlined(_ text: AttributedString) -> AttributedString {
        var text = text
        for tag in ["ins", "u"] {
            while let open = text.range(of: "<\(tag)>"), let close = text[open.upperBound...].range(of: "</\(tag)>") {
                text[open.upperBound..<close.lowerBound].underlineStyle = .single
                text.removeSubrange(close)
                text.removeSubrange(open)
            }
        }
        return text
    }
}
