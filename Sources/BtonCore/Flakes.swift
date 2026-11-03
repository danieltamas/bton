import Foundation

/// A CI check that gave two verdicts on one commit: read as `failure` on one tick and `success`
/// on a later one, with no push between. Bton records it, labels the PR and tells the fix move
/// to rerun before it changes code. Nothing here softens a check: `checks not green` stays a
/// refusal on a flaky check too.
public struct Flake: Codable, Hashable, Sendable {
    public let repo: String
    public let check: String
    public let number: Int
    public let head: String
    public let at: Date

    public init(repo: String, check: String, number: Int, head: String, at: Date) {
        self.repo = repo
        self.check = check
        self.number = number
        self.head = head
        self.at = at
    }
}

/// `~/.bton/flakes.json`, a JSON array of `Flake` records: the flakes seen, newest first, 30 days
/// and 500 records at most.
public struct FlakeStore: Equatable, Sendable {
    public static let file = "flakes.json"
    public static let keep: TimeInterval = 30 * 86400
    public static let limit = 500

    public var flakes: [Flake]

    public init(flakes: [Flake] = []) { self.flakes = flakes }

    public static func url(home: BtonHome) -> URL { home.url.appendingPathComponent(file) }

    /// Missing or unreadable is empty: a flake record never stops a tick.
    public static func load(home: BtonHome) -> FlakeStore {
        guard let data = try? Data(contentsOf: url(home: home)),
              let flakes = try? JSONDecoder().decode([Flake].self, from: data) else { return FlakeStore() }
        return FlakeStore(flakes: flakes)
    }

    public func save(home: BtonHome) throws {
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(flakes).write(to: Self.url(home: home), options: .atomic)
    }

    /// Newest first, nothing older than `keep`, at most `limit`.
    public func pruned(now: Date = .now) -> FlakeStore {
        let since = now.addingTimeInterval(-Self.keep)
        return FlakeStore(flakes: Array(flakes.filter { $0.at >= since }.sorted { $0.at > $1.at }.prefix(Self.limit)))
    }
}

public enum Flakes {
    /// A flip counts as a repeat for this long.
    public static let window: TimeInterval = 14 * 86400
    /// Distinct heads a check flipped on before it is called flaky.
    public static let flakyHeads = 2
    public static let labelPrefix = "flaky:"
    /// Characters of the check name kept in the label: the whole label stays under GitHub's 50.
    public static let labelNameLimit = 43
    public static let labelDescription = "a check that turned red then green on the same commit"

    /// What the engine keeps between ticks: head sha to check name to state.
    public static func states(_ pullRequests: [PullRequest]) -> [String: [String: CheckResult.State]] {
        Dictionary(pullRequests.map { pr in (pr.headSha, Dictionary(pr.checks.map { ($0.name, $0.state) }) { first, _ in first }) }) { first, _ in first }
    }

    /// Every check now `success` that `previous` read as `failure` on the same head: one flake each.
    public static func flips(previous: [String: [String: CheckResult.State]], pullRequests: [PullRequest],
                             repo: String, now: Date) -> [Flake] {
        pullRequests.flatMap { pr -> [Flake] in
            guard let before = previous[pr.headSha] else { return [] }
            return pr.checks.filter { $0.state == .success && before[$0.name] == .failure }
                .map { Flake(repo: repo, check: $0.name, number: pr.number, head: pr.headSha, at: now) }
        }
    }

    /// Check name to the distinct heads it flipped on within `window`.
    public static func known(_ store: FlakeStore, repo: String, now: Date = .now) -> [String: Int] {
        let since = now.addingTimeInterval(-window)
        var heads: [String: Set<String>] = [:]
        for flake in store.flakes where flake.at >= since && flake.repo.caseInsensitiveCompare(repo) == .orderedSame {
            heads[flake.check, default: []].insert(flake.head)
        }
        return heads.mapValues(\.count)
    }

    public static func isFlaky(_ check: String, known: [String: Int]) -> Bool { (known[check] ?? 0) >= flakyHeads }

    /// `flaky:<check>`, the name cut to `labelNameLimit`, with the characters a label cannot carry replaced.
    public static func label(for check: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./ "))
        let cleaned = String(String.UnicodeScalarView(check.unicodeScalars.map { allowed.contains($0) ? $0 : "-" }))
        return labelPrefix + cleaned.prefix(labelNameLimit)
    }

    /// What a fix agent is told when a red check it is sent to fix is a known flake; nil when none is.
    public static func line(redChecks: [String], known: [String: Int]) -> String? {
        let flaky = redChecks.filter { isFlaky($0, known: known) }
        guard let first = flaky.first else { return nil }
        let rest = flaky.dropFirst().map { "\($0), \(known[$0] ?? 0)" }
        let others = rest.isEmpty ? "" : " (and " + rest.joined(separator: "; ") + ")"
        return "Check \(first) turned red then green on the same commit \(known[first] ?? 0) times in 14 days\(others): "
            + "rerun the failed run before changing code (`gh run rerun <id> --failed`); change code only for a failure you reproduce."
    }
}
