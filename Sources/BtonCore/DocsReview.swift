import Foundation

/// The `docs` tier's review: a policy check that is the same for every repo, so it ships with
/// Bton (`bton docs-review`) instead of being a script every team writes. Pure: the files, the
/// head's tree and the tier's globs in, a verdict out. Any finding is `changes`.
public enum DocsReview {
    public struct File: Sendable, Equatable {
        public let path: String
        public let bytes: Data

        public init(path: String, bytes: Data) {
            self.path = path
            self.bytes = bytes
        }
    }

    public struct Verdict: Sendable, Equatable {
        public let approve: Bool
        public let findings: [String]

        public init(approve: Bool, findings: [String]) {
            self.approve = approve
            self.findings = findings
        }
    }

    static let secretShapes: [(kind: String, pattern: String)] = [
        ("GitHub token", #"ghp_[A-Za-z0-9]{36}"#),
        ("GitHub token", #"github_pat_[A-Za-z0-9_]{20,}"#),
        ("API key", #"sk-[A-Za-z0-9_-]{20,}"#),
        ("AWS key", #"AKIA[0-9A-Z]{16}"#),
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
    ]

    /// Zero-width and bidi characters, the soft hyphen and the BOM: invisible on screen, a
    /// fingerprint or a hidden instruction in a file people read.
    static let invisible: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = [
            Unicode.Scalar(0x200B)!, Unicode.Scalar(0x200C)!, Unicode.Scalar(0x200D)!,
            Unicode.Scalar(0x2060)!, Unicode.Scalar(0xFEFF)!, Unicode.Scalar(0x00AD)!,
        ]
        for value in 0x202A...0x202E { set.insert(Unicode.Scalar(UInt32(value))!) }
        for value in 0x2066...0x2069 { set.insert(Unicode.Scalar(UInt32(value))!) }
        return set
    }()

    public static func review(_ files: [File], tree: Set<String>, allowed: [String]) -> Verdict {
        var findings: [String] = []
        for file in files {
            if !allowed.contains(where: { PathGlob.matches($0, file.path) }) {
                findings.append("\(file.path): not a documentation file under tier.only")
            }
            guard let text = String(data: file.bytes, encoding: .utf8) else {
                findings.append("\(file.path): not UTF-8 text")
                continue
            }
            if text.allSatisfy(\.isWhitespace) {
                findings.append("\(file.path): empty file")
            }
            let lines = text.components(separatedBy: .newlines)
            findings += secrets(in: lines, path: file.path)
            findings += invisibles(in: lines, path: file.path)
            findings += brokenLinks(in: lines, path: file.path, tree: tree)
        }
        return Verdict(approve: findings.isEmpty, findings: findings.map(redacted))
    }

    /// Findings are posted on the PR: a secret-shaped string in a path or a link target is cut.
    static func redacted(_ finding: String) -> String {
        secretShapes.reduce(finding) { text, shape in
            text.replacingOccurrences(of: shape.pattern, with: "[redacted \(shape.kind)]", options: .regularExpression)
        }
    }

    /// The text a review command writes to `$BTON_OUT`: the heading the dispatcher parses, what
    /// the verdict is and is not, then the findings.
    public static func report(_ verdict: Verdict, head: String) -> String {
        var lines = [
            "## Review: \(verdict.approve ? "approve" : "changes") (head \(head))",
            "Policy check by bton docs-review, not a judgment: every changed file is documentation, "
                + "non-empty UTF-8, with no secret-shaped strings, no invisible characters and no broken relative links.",
        ]
        if !verdict.approve {
            lines.append("")
            lines += verdict.findings.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func secrets(in lines: [String], path: String) -> [String] {
        var findings: [String] = []
        for (index, line) in lines.enumerated() {
            for shape in secretShapes where line.range(of: shape.pattern, options: .regularExpression) != nil {
                // The kind, never the match: the finding is posted on the PR.
                findings.append("\(path): line \(index + 1): looks like a secret (\(shape.kind))")
                break
            }
        }
        return findings
    }

    private static func invisibles(in lines: [String], path: String) -> [String] {
        var findings: [String] = []
        for (index, line) in lines.enumerated() {
            if let scalar = line.unicodeScalars.first(where: invisible.contains) {
                let code = String(scalar.value, radix: 16, uppercase: true)
                findings.append("\(path): line \(index + 1): invisible character U+\(String(repeating: "0", count: max(0, 4 - code.count)))\(code)")
            }
        }
        return findings
    }

    /// Relative links whose target is not in the head's tree. Fenced blocks and code spans are
    /// examples, not links, and are blanked first (newlines kept, so line numbers hold);
    /// reference-style links are not checked.
    private static func brokenLinks(in lines: [String], path: String, tree: Set<String>) -> [String] {
        var findings: [String] = []
        let directory = path.split(separator: "/").dropLast().map(String.init)
        for (index, line) in withoutCode(lines).enumerated() {
            for target in destinations(in: line) where !target.isEmpty && !skips(target) {
                guard let resolved = resolve(target, from: directory) else {
                    findings.append("\(path): line \(index + 1): link to \(target) points at no file in the PR's tree")
                    continue
                }
                let isDirectory = resolved.isEmpty ? !tree.isEmpty : tree.contains { $0.hasPrefix(resolved + "/") }
                if !tree.contains(resolved), !isDirectory {
                    findings.append("\(path): line \(index + 1): link to \(target) points at no file in the PR's tree")
                }
            }
        }
        return findings
    }

    /// The lines with fenced blocks and code spans blanked. A fence opens with three or more
    /// backticks (no backtick in its info string, else it is a span on a line) or tildes and
    /// closes with at least as many of the same, alone on a line. A span opens with a backtick
    /// run and closes with the next run of exactly that length, also across lines.
    static func withoutCode(_ lines: [String]) -> [String] {
        var out: [String] = []
        var fence: (marker: Character, length: Int)?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                let run = trimmed.prefix { $0 == open.marker }
                if run.count >= open.length, trimmed.dropFirst(run.count).allSatisfy(\.isWhitespace) { fence = nil }
                out.append("")
                continue
            }
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let run = trimmed.prefix { $0 == marker }
                let info = trimmed.dropFirst(run.count)
                if run.count >= 3, marker == "~" || !info.contains("`") {
                    fence = (marker, run.count)
                    out.append("")
                    continue
                }
            }
            out.append(line)
        }
        return blankSpans(out)
    }

    /// Code spans across the whole text: the characters between matching runs become spaces.
    /// A backslash escapes a backtick outside a span only; inside, it is a character. A span
    /// never leaves its paragraph: a blank line, or a line that opens another block (CommonMark's
    /// paragraph interrupters: heading, block quote, thematic break, list item), ends the search
    /// and the opener was plain text. A heading is one line, so a span opened in it closes there.
    private static func blankSpans(_ lines: [String]) -> [String] {
        var text = Array(lines.joined(separator: "\n"))
        var index = 0
        var lineStart = 0
        while index < text.count {
            if text[index] == "\n" { lineStart = index + 1 }
            if text[index] == "\\" { index += 2; continue }
            guard text[index] == "`" else { index += 1; continue }
            var end = index
            while end < text.count, text[end] == "`" { end += 1 }
            let length = end - index
            var cursor = end
            var close: Int?
            let inHeading = isHeading(text, from: lineStart)
            while cursor < text.count {
                if text[cursor] == "\n", inHeading || endsParagraph(after: cursor, in: text) { break }
                guard text[cursor] == "`" else { cursor += 1; continue }
                var runEnd = cursor
                while runEnd < text.count, text[runEnd] == "`" { runEnd += 1 }
                if runEnd - cursor == length { close = cursor; break }
                cursor = runEnd
            }
            guard let close else { index = end; continue }
            for position in index..<(close + length) where text[position] != "\n" { text[position] = " " }
            index = close + length
        }
        return String(text).components(separatedBy: "\n")
    }

    /// Whether the line starting at `start` is an ATX heading (up to three spaces of indent).
    private static func isHeading(_ text: [Character], from start: Int) -> Bool {
        var cursor = start
        var indent = 0
        while cursor < text.count, text[cursor] == " " { cursor += 1; indent += 1 }
        var end = cursor
        while end < text.count, text[end] != "\n" { end += 1 }
        return indent < 4 && text[cursor..<end].first == "#" && interruptsParagraph(String(text[cursor..<end]))
    }

    /// True when the newline at `index` is followed by the end of the text, a blank line or a
    /// line that interrupts a paragraph.
    private static func endsParagraph(after index: Int, in text: [Character]) -> Bool {
        var cursor = index + 1
        var indent = 0
        while cursor < text.count, text[cursor] == " " || text[cursor] == "\t" { cursor += 1; indent += 1 }
        guard cursor < text.count, text[cursor] != "\n" else { return true }
        var end = cursor
        while end < text.count, text[end] != "\n" { end += 1 }
        return indent < 4 && interruptsParagraph(String(text[cursor..<end]))
    }

    /// CommonMark 4.1, 4.2, 5.1, 5.2: a thematic break, an ATX heading, a block quote or a
    /// bullet (or `1.`/`1)`) list item starts a new block even without a blank line before it.
    static func interruptsParagraph(_ line: String) -> Bool {
        let characters = Array(line)
        guard let first = characters.first else { return false }
        let rest = characters.dropFirst()
        if first == ">" { return true }
        if "-*_".contains(first), characters.filter({ $0 == first }).count >= 3,
           characters.allSatisfy({ $0 == first || $0 == " " || $0 == "\t" }) { return true }
        if first == "#" {
            let hashes = characters.prefix { $0 == "#" }.count
            return hashes <= 6 && (characters.count == hashes || characters[hashes] == " " || characters[hashes] == "\t")
        }
        if "-*+".contains(first) { return rest.isEmpty || rest.first == " " || rest.first == "\t" }
        if first == "1", let marker = rest.first, marker == "." || marker == ")" {
            let after = rest.dropFirst()
            return after.isEmpty || after.first == " " || after.first == "\t"
        }
        return false
    }

    /// The destinations of `[text](destination ...)` on a line: the destination ends at the first
    /// unescaped whitespace or `#`; parentheses balance; `\(` and `\)` are the characters.
    static func destinations(in line: String) -> [String] {
        var found: [String] = []
        let characters = Array(line)
        var index = 0
        while index + 1 < characters.count {
            guard characters[index] == "]", characters[index + 1] == "(", !isEscaped(index, in: characters),
                  opensBracket(before: index, in: characters) else {
                index += 1
                continue
            }
            var cursor = index + 2
            var depth = 0
            var target = ""
            var ended = false
            var quote: Character?
            while cursor < characters.count {
                let character = characters[cursor]
                if character == "\\", cursor + 1 < characters.count {
                    if !ended { target.append(characters[cursor + 1]) }
                    cursor += 2
                    continue
                }
                // A title's quotes: what is inside them is text, parentheses included.
                if let open = quote {
                    if character == open { quote = nil }
                    cursor += 1
                    continue
                }
                if ended, character == "\"" || character == "'" {
                    quote = character
                    cursor += 1
                    continue
                }
                if character == "(" { depth += 1 } else if character == ")" {
                    if depth == 0 { break }
                    depth -= 1
                }
                if !ended, character.isWhitespace || character == "#" { ended = true }
                if !ended { target.append(character) }
                cursor += 1
            }
            if cursor < characters.count { found.append(target) }
            index = cursor + 1
        }
        return found
    }

    /// The `[` that the `]` at `index` closes, brackets nested in between balanced.
    private static func opensBracket(before index: Int, in characters: [Character]) -> Bool {
        var depth = 0
        var cursor = index - 1
        while cursor >= 0 {
            let escaped = isEscaped(cursor, in: characters)
            if !escaped, characters[cursor] == "]" { depth += 1 }
            if !escaped, characters[cursor] == "[" {
                if depth == 0 { return true }
                depth -= 1
            }
            cursor -= 1
        }
        return false
    }

    /// Escaped when an odd number of backslashes precedes it: `\\[` is a backslash, then a bracket.
    private static func isEscaped(_ index: Int, in characters: [Character]) -> Bool {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, characters[cursor] == "\\" { count += 1; cursor -= 1 }
        return count % 2 == 1
    }

    private static func skips(_ target: String) -> Bool {
        let lowered = target.lowercased()
        return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("mailto:")
            || lowered.hasPrefix("<") || lowered.hasPrefix("#")
    }

    /// `target` against the file's directory, `.` and `..` folded; nil when it climbs out of the repo.
    static func resolve(_ target: String, from directory: [String]) -> String? {
        var parts = target.hasPrefix("/") ? [] : directory
        for piece in target.split(separator: "/", omittingEmptySubsequences: true) {
            switch piece {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(piece))
            }
        }
        return parts.joined(separator: "/")
    }
}
