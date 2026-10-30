import Foundation

/// Markdown as the blocks a screen draws.
public enum Markdown {
    public struct Block: Sendable {
        public enum Kind: Sendable {
            case heading(Int)
            case paragraph
            case code
            case rule
            case table([[AttributedString]])
        }
        public var kind: Kind
        public var text: AttributedString
        /// How many lists the block sits in; 0 outside a list.
        public var depth = 0
        /// The bullet or number of the list item the block opens; nil for a later block of the item.
        public var marker: String?
        public var quoted = false
    }

    public static func blocks(of markdown: String) -> [Block] {
        let source = hardBreaks(markdown)
        guard let parsed = try? AttributedString(markdown: source, options: .init(allowsExtendedAttributes: true,
                                                                                  interpretedSyntax: .full,
                                                                                  failurePolicy: .returnPartiallyParsedIfPossible))
        else { return [Block(kind: .paragraph, text: AttributedString(markdown))] }
        var blocks: [Block] = []
        var cells: [(row: Int, column: Int, text: AttributedString)] = []
        var tableID: Int?
        // Rows by order of appearance: the parser numbers body rows from 1, the header apart.
        var rowIDs: [Int] = []
        var openedItems: Set<Int> = []
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let text = AttributedString(parsed[range])
            let components = intent?.components ?? []
            if let table = components.first(where: { if case .table = $0.kind { return true } else { return false } }) {
                if tableID != table.identity { flushTable(&cells, into: &blocks); tableID = table.identity; rowIDs = [] }
                var row = 0, column = 0
                for component in components {
                    switch component.kind {
                    case .tableHeaderRow, .tableRow:
                        if !rowIDs.contains(component.identity) { rowIDs.append(component.identity) }
                        row = rowIDs.firstIndex(of: component.identity) ?? 0
                    case .tableCell(let index): column = index
                    default: break
                    }
                }
                cells.append((row, column, text))
                continue
            }
            flushTable(&cells, into: &blocks)
            tableID = nil
            var block = Block(kind: .paragraph, text: text)
            // Innermost first: a list item's own list is the component after it.
            for (index, component) in components.enumerated() {
                switch component.kind {
                case .header(let level): block.kind = .heading(level)
                case .codeBlock: block.kind = .code
                case .thematicBreak: block.kind = .rule
                case .blockQuote: block.quoted = true
                case .orderedList, .unorderedList: block.depth += 1
                case .listItem(let ordinal):
                    // Only the item's first block carries its marker; later paragraphs hang under it.
                    guard block.marker == nil, !openedItems.contains(component.identity) else { break }
                    openedItems.insert(component.identity)
                    if index + 1 < components.count, case .orderedList = components[index + 1].kind {
                        block.marker = "\(ordinal)."
                    } else {
                        block.marker = "•"
                    }
                default: break
                }
            }
            if case .code = block.kind {
                block.text = AttributedString(String(text.characters).trimmingCharacters(in: .newlines))
            }
            blocks.append(block)
        }
        flushTable(&cells, into: &blocks)
        return blocks
    }

    private static func flushTable(_ cells: inout [(row: Int, column: Int, text: AttributedString)], into blocks: inout [Block]) {
        guard !cells.isEmpty else { return }
        let rowCount = (cells.map(\.row).max() ?? 0) + 1
        let columnCount = (cells.map(\.column).max() ?? 0) + 1
        var rows = Array(repeating: Array(repeating: AttributedString(), count: columnCount), count: rowCount)
        for cell in cells { rows[cell.row][cell.column] = cell.text }
        blocks.append(Block(kind: .table(rows), text: AttributedString()))
        cells = []
    }

    /// GitHub breaks a line where an issue's author did; CommonMark joins it. A line followed by
    /// more of its paragraph (not a blank line, not a block start) ends in two spaces so the parser
    /// keeps the break, inside a list item or a quote too; fenced code is left alone.
    public static func hardBreaks(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var fenced = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let fence = trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
            if fence { fenced.toggle() }
            let next = index + 1 < lines.count ? unquoted(lines[index + 1]) : ""
            if !fenced, !fence, !trimmed.isEmpty, !next.isEmpty, !opensBlock(next), !line.hasSuffix("  ") {
                out.append(line + "  ")
            } else {
                out.append(line)
            }
        }
        return out.joined(separator: "\n")
    }

    /// The line without its quote marks and surrounding spaces: what it starts inside the quote.
    private static func unquoted(_ line: String) -> String {
        var rest = Substring(line.trimmingCharacters(in: .whitespaces))
        while rest.hasPrefix(">") { rest = rest.dropFirst().drop { $0 == " " } }
        return String(rest)
    }

    private static func opensBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("```") || line.hasPrefix("~~~")
            || line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") || line.hasPrefix("---") || line.hasPrefix("***") {
            return true
        }
        let digits = line.prefix { $0.isNumber }
        return !digits.isEmpty && (line.dropFirst(digits.count).hasPrefix(". ") || line.dropFirst(digits.count).hasPrefix(") "))
    }
}
