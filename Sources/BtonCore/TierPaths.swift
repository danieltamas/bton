import Foundation

/// gitignore-style globs for `tier.paths`, matched against a path from the repo root:
/// `*` and `?` stay inside one path part, `**` crosses parts, a pattern with a slash is anchored
/// at the root and one without matches at any depth, and a pattern naming a directory matches
/// everything under it. No negation.
public enum PathGlob {
    public static func isValid(_ pattern: String) -> Bool {
        !pattern.isEmpty && !pattern.hasPrefix("!") && !pattern.hasPrefix("#") && !pattern.contains("[") && !pattern.contains("\\") && regex(pattern) != nil
    }

    public static func matches(_ pattern: String, _ path: String) -> Bool {
        guard let regex = regex(pattern) else { return false }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        var glob = pattern
        let anchored = glob.hasPrefix("/") || glob.dropLast().contains("/")
        if glob.hasPrefix("/") { glob.removeFirst() }
        if glob.hasSuffix("/") { glob.removeLast() }
        guard !glob.isEmpty else { return nil }
        var out = anchored ? "^" : "^(?:.*/)?"
        let characters = Array(glob)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" {
                if index + 1 < characters.count, characters[index + 1] == "*" {
                    let slashAfter = index + 2 < characters.count && characters[index + 2] == "/"
                    // `**/` is zero or more directories; a trailing `/**` is everything below.
                    out += slashAfter ? "(?:.*/)?" : ".*"
                    index += slashAfter ? 3 : 2
                } else {
                    out += "[^/]*"
                    index += 1
                }
            } else if character == "?" {
                out += "[^/]"
                index += 1
            } else {
                out += NSRegularExpression.escapedPattern(for: String(character))
                index += 1
            }
        }
        // A directory's pattern covers what is under it.
        out += "(?:/.*)?$"
        return try? NSRegularExpression(pattern: out)
    }
}

/// A PR's tier once its changed files are counted, and the file that raised it.
public struct TierVerdict: Hashable, Sendable {
    public let tier: String
    /// What raised the tier above the PR body's: the first changed file that matched, or the
    /// file count when too many were read. nil when the body's tier stands.
    public let reason: String?
}

extension FlowEngine {
    /// The highest of the body's tier and every `tier.paths` tier a changed file matches, in the
    /// order of `tier.values` (lowest first). A PR whose files were too many to read counts as the
    /// highest tier, so a long change never hides a sensitive path.
    public static func tierVerdict(of pr: PullRequest, rule: TierRule) -> TierVerdict {
        let marked = tier(of: pr.body, rule: rule)
        guard let paths = rule.paths, !paths.isEmpty else { return TierVerdict(tier: marked, reason: nil) }
        let rank = { (tier: String) in rule.values.firstIndex(of: tier) ?? -1 }
        var best = marked
        var reason: String?
        if pr.changedFilesTruncated, let highest = rule.values.last, rank(highest) > rank(best) {
            best = highest
            reason = "more than \(pr.changedFiles.count) changed files"
        }
        for (tier, globs) in paths.sorted(by: { rank($0.key) > rank($1.key) }) where rank(tier) > rank(best) {
            if let file = pr.changedFiles.first(where: { file in globs.contains { PathGlob.matches($0, file) } }) {
                best = tier
                reason = file
                break
            }
        }
        return TierVerdict(tier: best, reason: reason)
    }

    public static func tier(of pr: PullRequest, rule: TierRule) -> String {
        tierVerdict(of: pr, rule: rule).tier
    }
}
