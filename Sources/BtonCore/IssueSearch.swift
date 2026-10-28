import Foundation

/// The lists' search, asked of GitHub: every open issue of a repo, not only the synced page.
public enum IssueSearch {
    /// GitHub's search text for the words: the repo's open issues matching them. Quotes would
    /// start a phrase GitHub may refuse, so they are dropped.
    public static func query(repo: String, text: String) -> String {
        let words = text.replacingOccurrences(of: "\"", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return "repo:\(repo) is:issue is:open \(words)"
    }

    /// The number a search names (`367`, `#367`); nil for words.
    public static func number(in text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        return Int(digits)
    }
}
