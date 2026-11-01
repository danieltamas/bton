import Foundation

/// GitHub closes an issue when a PR whose body says `Fixes #n` (or `closes`, `resolves`, their
/// forms) merges into the default branch. A repo whose flow names labels under `keepOpen`
/// (`verify:prod`: the change counts as done only once someone checked it live) keeps such an
/// issue open: before the merge command, Bton turns the keyword before that issue's number into
/// `Refs`, which links and closes nothing. Other issues, and the `#n` itself, stay as written, so
/// the PR still names the issue it is for.
public enum KeepOpen {
    /// A closing keyword, an optional colon, any whitespace (a line break too), then `#n`, `owner/repo#n` or the issue's URL
    /// in this repo. Word-bounded: `prefixes #3` closes nothing.
    static func pattern(repo: String) -> NSRegularExpression {
        let escaped = NSRegularExpression.escapedPattern(for: repo)
        let reference = "(?:https://github\\.com/\(escaped)/issues/|\(escaped)#|#)(\\d+)\\b"
        // Never fails: the only variable part is escaped.
        return try! NSRegularExpression(pattern: "\\b(close[sd]?|fix(?:e[sd])?|resolve[sd]?)(:?\\s*)\(reference)",
                                        options: .caseInsensitive)
    }

    /// The issues of `repo` the body would close on merge.
    public static func references(in body: String, repo: String) -> Set<Int> {
        let matches = pattern(repo: repo).matches(in: body, range: NSRange(body.startIndex..., in: body))
        return Set(matches.compactMap { Range($0.range(at: 3), in: body).flatMap { Int(body[$0]) } })
    }

    /// The body with `Refs` in place of the closing keyword before each of `issues`; the rest,
    /// including the reference itself, as it was.
    public static func neutralised(_ body: String, keeping issues: Set<Int>, repo: String) -> String {
        var out = ""
        var cursor = body.startIndex
        for match in pattern(repo: repo).matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let whole = Range(match.range, in: body), let keyword = Range(match.range(at: 1), in: body),
                  let number = Range(match.range(at: 3), in: body), let issue = Int(body[number]), issues.contains(issue)
            else { continue }
            out += body[cursor..<keyword.lowerBound]
            out += "Refs"
            out += body[keyword.upperBound..<whole.upperBound]
            cursor = whole.upperBound
        }
        out += body[cursor...]
        return out
    }
}
