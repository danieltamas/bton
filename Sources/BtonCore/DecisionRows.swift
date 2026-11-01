import CryptoKit
import Foundation

/// The Decisions table a repo's process keeps in an issue body, one markdown row per choice
/// (`| D-n | decision | ... | who | date |`), read for the rows that still wait on a person. The
/// first cell is the row's id and the last two are Who and Date, whatever the columns between.
public enum DecisionRows {
    public struct Row: Hashable, Sendable {
        public let id: String
        /// The whole line, the revision the ask is keyed on: an edited row is a new ask.
        public let text: String
    }

    static let defaultOpen = ["open"]

    /// The rows open for `me`: the Date cell, with `*` and spaces gone, is empty or starts with one
    /// of the table's open words, and the Who cell names `me`, or a name the table maps to `me`, as
    /// a whole word. The date is read first, so "Bogdan, Dani | 2026-10-30" is decided.
    public static func open(in body: String, for me: String, table: Flow.DecisionTable) -> [Row] {
        let names = [me] + (table.names ?? [:]).filter { $0.value.caseInsensitiveCompare(me) == .orderedSame }.map(\.key)
        let open = (table.open ?? defaultOpen).map { $0.lowercased() }.filter { !$0.isEmpty }
        return body.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n").compactMap { line -> Row? in
            let cells = self.cells(of: String(line))
            guard cells.count >= 3, let id = rowID(cells[0]) else { return nil }
            let date = cells[cells.count - 1].replacingOccurrences(of: "*", with: "").replacingOccurrences(of: " ", with: "").lowercased()
            guard date.isEmpty || open.contains(where: { date.hasPrefix($0) }) else { return nil }
            guard names.contains(where: { whoCell(cells[cells.count - 2], names: $0) }) else { return nil }
            return Row(id: id, text: String(line))
        }
    }

    /// The ask's key head for these rows, the same on every Mac: `rows-` and twelve hex digits of
    /// the rows' text, so an edit to one of them is a new ask and a comment is not.
    public static func revision(_ rows: [Row]) -> String {
        let digest = SHA256.hash(data: Data(rows.map(\.text).joined(separator: "\n").utf8))
        return "rows-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The cells of a markdown table row, trimmed; empty for a line that is not one. A `\|` and a
    /// pipe inside a code span are text, not a cell boundary: a date cell "2026-10-30 (Dani \| open)"
    /// stays one decided cell.
    static func cells(of line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return [] }
        let kept: Character = "\u{1}"
        var masked = ""
        var span = 0
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let character = trimmed[index]
            if character == "\\", span == 0, trimmed.index(after: index) < trimmed.endIndex, trimmed[trimmed.index(after: index)] == "|" {
                masked.append(kept)
                index = trimmed.index(index, offsetBy: 2)
                continue
            }
            if character == "`" {
                var end = index
                while end < trimmed.endIndex, trimmed[end] == "`" { end = trimmed.index(after: end) }
                let run = trimmed.distance(from: index, to: end)
                if span == 0 { span = run } else if span == run { span = 0 }
                masked.append(contentsOf: trimmed[index..<end])
                index = end
                continue
            }
            masked.append(character == "|" && span > 0 ? kept : character)
            index = trimmed.index(after: index)
        }
        var cells = masked.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: String(kept), with: "|").trimmingCharacters(in: .whitespaces) }
        cells.removeFirst()
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    /// `D-12` from a first cell, bold or in code too; nil for the header (`D-n`, `ID`) and the rule.
    static func rowID(_ cell: String) -> String? {
        let bare = cell.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").uppercased()
        return bare.wholeMatch(of: /D-[0-9]+/) != nil ? bare : nil
    }

    static func whoCell(_ cell: String, names name: String) -> Bool {
        let pattern = "(?i)(?<![A-Za-z0-9_-])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z0-9_-])"
        return cell.range(of: pattern, options: .regularExpression) != nil
    }
}
