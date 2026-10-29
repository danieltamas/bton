import Foundation

/// Two reviewers' final messages become the one review Bton posts: the first's heading, the
/// stricter verdict, both findings tables merged by location, and the second's notes as data.
/// A second that gave no verdict makes the review `blocked`: a judgment the flow asked for is
/// missing, which the playbook calls blocked, never approved by default.
public enum ReviewMerge {
    /// Largest body posted (GitHub refuses a comment over 65_536 characters).
    static let limit = 60_000
    /// Characters of the second reviewer's notes kept.
    static let notesLimit = 4_000

    public struct Table: Hashable, Sendable {
        public let heading: String
        public let verdict: Verdict
        public let findings: [PREvidence.Finding]
        /// What follows the table (or the first line when there is none), trimmed.
        public let notes: String
    }

    /// The message as a review: nil when its first line names no heading of `headings` for `head`.
    public static func table(of message: String, headings: [String], head: String) -> Table? {
        guard let body = DispatchPlanner.reviewComment(fromFinalMessage: message, headings: headings, head: head),
              let review = FlowEngine.review(fromFirstLine: FlowEngine.firstLine(of: body), headings: headings) else { return nil }
        let lines = body.components(separatedBy: "\n")
        let rest = lines.dropFirst()
        // The notes are what is neither the table nor the lines before it.
        var notes: [String] = []
        var inTable = false
        var tableSeen = false
        for line in rest {
            let isRow = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
            if isRow, !tableSeen { inTable = true }
            if inTable, !isRow { inTable = false; tableSeen = true }
            if !inTable, tableSeen { notes.append(line) }
            else if !inTable, !tableSeen, !line.trimmingCharacters(in: .whitespaces).isEmpty { notes.append(line) }
        }
        return Table(heading: review.heading, verdict: review.verdict, findings: PREvidence.findings(in: body),
                     notes: notes.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The posted body. nil when `first` is no review (the job fails as it would without a second).
    public static func merged(first: String, second: String?, reason: String?, headings: [String], head: String, agent: String) -> String? {
        guard let primary = table(of: first, headings: headings, head: head) else { return nil }
        let secondary = second.flatMap { table(of: $0, headings: headings, head: head) }
        var rows = primary.findings.map(row)
        // Against the first's locations only: two findings of the second's own at one place both stay.
        let keys = Set(primary.findings.map { key(of: $0.location) })
        var duplicates = 0
        for finding in secondary?.findings ?? [] {
            guard !keys.contains(key(of: finding.location)) else { duplicates += 1; continue }
            rows.append(row(PREvidence.Finding(id: "S-" + finding.id, severity: finding.severity, location: finding.location, text: finding.text)))
        }
        let verdict: Verdict
        let standing: String
        var notes = ""
        if let secondary {
            verdict = stricter(primary.verdict, secondary.verdict)
            standing = "Second reviewer (\(agent)): \(secondary.verdict.rawValue), \(secondary.findings.count) findings, "
                + "\(duplicates) duplicate(s) of the first reviewer's dropped"
            if !secondary.notes.isEmpty {
                var quoted = PREvidence.lines(String(secondary.notes.prefix(notesLimit))).map { "    " + $0 }
                if secondary.notes.count > notesLimit { quoted.append("    [truncated by Bton: \(secondary.notes.count) characters]") }
                notes = "\n### Second reviewer's notes\n\n" + quoted.joined(separator: "\n") + "\n"
            }
        } else {
            // No judgment where the flow asked for one: blocked, never approved by default.
            verdict = .blocked
            let why = second == nil ? (reason ?? "did not run") : "final message names no review heading for the current head"
            standing = "Second reviewer (\(agent)): no result: \(PREvidence.inline(why))"
        }
        func body(rows listed: ArraySlice<String>, notes: String) -> String {
            var text = "\(primary.heading) \(verdict.rawValue) (head \(head))\n\n"
                + "| ID | Severity | Location | Finding and evidence |\n| --- | --- | --- | --- |\n"
            text += (listed.isEmpty ? ["| None | | | |"] : Array(listed)).joined(separator: "\n") + "\n"
            if listed.count < rows.count { text += "\(rows.count - listed.count) more findings not listed\n" }
            if !primary.notes.isEmpty { text += "\n" + primary.notes + "\n" }
            return text + "\n" + standing + "\n" + notes
        }
        let full = body(rows: rows[...], notes: notes)
        if full.count <= limit { return full }
        // The notes go first, then the second's rows from the end: the first's table always stays.
        var kept = rows.count
        var text = body(rows: rows[..<kept], notes: "")
        while text.count > limit, kept > primary.findings.count {
            kept -= 1
            text = body(rows: rows[..<kept], notes: "")
        }
        // A first review itself over the limit: cut, as a last resort, with the verdict line intact.
        let cut = "\n[cut by Bton at \(limit) characters]\n"
        return text.count <= limit ? text : String(text.prefix(limit - cut.count)) + cut
    }

    private static func stricter(_ a: Verdict, _ b: Verdict) -> Verdict {
        let order: [Verdict] = [.approve, .changes, .blocked]
        return order.firstIndex(of: a)! >= order.firstIndex(of: b)! ? a : b
    }

    /// The location's path and line, backticks off, lowercased: what makes two rows one finding.
    static func key(of location: String) -> String {
        String(location.prefix { $0 != " " }).trimmingCharacters(in: CharacterSet(charactersIn: "`")).lowercased()
    }

    private static func row(_ finding: PREvidence.Finding) -> String {
        "| \(cell(finding.id)) | \(cell(finding.severity)) | \(cell(finding.location)) | \(cell(finding.text)) |"
    }

    /// A cell as posted: a pipe the reviewer escaped stays one escaped pipe, a line break or tab
    /// becomes its escape, so a row stays one row and a heading in a finding stays in its cell.
    private static func cell(_ text: String) -> String {
        var out = ""
        for scalar in text.replacingOccurrences(of: "\\|", with: "|").unicodeScalars {
            switch scalar {
            case "|": out += "\\|"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{2028}", "\u{2029}", "\u{0}"..."\u{1F}", "\u{7F}"..."\u{9F}": out += " "
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}
