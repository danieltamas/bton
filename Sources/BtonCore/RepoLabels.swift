import Foundation

/// A label of a repo as GitHub defines it: its name, its colour as GitHub's six hex digits, and
/// what it is for.
public struct RepoLabel: Codable, Hashable, Sendable {
    public let name: String
    public let color: String
    public let description: String

    public init(name: String, color: String, description: String = "") {
        self.name = name
        self.color = color
        self.description = description
    }

    /// `stage:` for `stage:ready`, nil for a label with no colon: the family whose members an issue
    /// holds one of at a time.
    public var family: String? { RepoLabels.family(of: name) }
}

/// The labels of each repo, read from GitHub once a day and kept in `$BTON_HOME/labels.json`, so
/// the Triage tab's picker opens at once and GitHub is asked only when the day has passed. Also
/// the rules of setting a label from the tab: a label of a family (`stage:`, `priority:`, any
/// `<prefix>:`) replaces the family's label the issue holds, in one edit.
public struct RepoLabels: Codable, Sendable {
    /// One repo's labels and when GitHub gave them.
    public struct Entry: Codable, Sendable {
        public var labels: [RepoLabel]
        public var fetchedAt: Date

        public init(labels: [RepoLabel], fetchedAt: Date) {
            self.labels = labels
            self.fetchedAt = fetchedAt
        }
    }

    /// How long an entry serves before GitHub is asked again.
    public static let maxAge: TimeInterval = 24 * 3_600
    /// A repo's labels beyond this count are not read: `gh label list` serves 30 by default.
    public static let limit = 500

    /// By repo slug, lowercased.
    public var repos: [String: Entry]

    public init(repos: [String: Entry] = [:]) {
        self.repos = repos
    }

    /// The labels on record for `repo` if GitHub gave them within `maxAge` of `now`; nil when they
    /// are missing or a day old.
    public func fresh(_ repo: String, now: Date) -> [RepoLabel]? {
        guard let entry = repos[repo.lowercased()], now.timeIntervalSince(entry.fetchedAt) < Self.maxAge,
              entry.fetchedAt <= now
        else { return nil }
        return entry.labels
    }

    /// The text through the first colon, lowercased (`stage:`), or nil for a label without one.
    public static func family(of label: String) -> String? {
        guard let colon = label.firstIndex(of: ":"), colon > label.startIndex else { return nil }
        return String(label[...colon]).lowercased()
    }

    /// The other labels of `label`'s family, in the repo's order: what a click on a family label
    /// offers in its place. Empty for a label with no family.
    public static func alternatives(to label: String, in labels: [RepoLabel]) -> [RepoLabel] {
        guard let family = family(of: label) else { return [] }
        return labels.filter { $0.family == family && $0.name.caseInsensitiveCompare(label) != .orderedSame }
    }

    /// The repo's labels an issue does not hold yet: what the `+` offers.
    public static func available(in labels: [RepoLabel], on issueLabels: [String]) -> [RepoLabel] {
        labels.filter { label in !issueLabels.contains { $0.caseInsensitiveCompare(label.name) == .orderedSame } }
    }

    /// The one edit that puts `label` on an issue holding `issueLabels`: the label is added and,
    /// when it has a family, the family's label the issue holds is removed with it, so the issue
    /// never holds two stages. Nothing to do when the issue holds it already.
    public static func edit(adding label: String, to issueLabels: [String]) -> (add: [String], remove: [String]) {
        guard !issueLabels.contains(where: { $0.caseInsensitiveCompare(label) == .orderedSame }) else { return ([], []) }
        let family = family(of: label)
        let remove = issueLabels.filter { family != nil && Self.family(of: $0) == family }
        return ([label], remove)
    }

    /// `issueLabels` after an edit, in the order GitHub will list them back: the kept ones first.
    public static func apply(_ edit: (add: [String], remove: [String]), to issueLabels: [String]) -> [String] {
        issueLabels.filter { label in !edit.remove.contains { $0.caseInsensitiveCompare(label) == .orderedSame } } + edit.add
    }

    // MARK: the file

    public static func url(home: BtonHome) -> URL { home.url.appendingPathComponent("labels.json") }

    private static let coding: (JSONDecoder, JSONEncoder) = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return (decoder, encoder)
    }()

    public static func load(home: BtonHome) -> RepoLabels {
        (try? coding.0.decode(RepoLabels.self, from: Data(contentsOf: url(home: home)))) ?? RepoLabels()
    }

    private static let writing = NSLock()

    /// Records `labels` as `repo`'s, read at `now`, written whole and atomically.
    public static func remember(_ labels: [RepoLabel], repo: String, now: Date, home: BtonHome) throws {
        writing.lock()
        defer { writing.unlock() }
        var all = load(home: home)
        all.repos[repo.lowercased()] = Entry(labels: labels, fetchedAt: now)
        try home.prepare()
        try coding.1.encode(all).write(to: url(home: home), options: .atomic)
    }

    /// The output of `gh label list --json name,color,description`, in the repo's order. A label
    /// `gh` cannot take as one name (a comma in it: `--add-label` splits there) is left out, since
    /// the tab could not set it.
    public static func decode(_ data: Data) throws -> [RepoLabel] {
        struct Row: Decodable { let name: String; let color: String?; let description: String? }
        return try JSONDecoder().decode([Row].self, from: data)
            .filter { WatchedRepo.isLabelName($0.name) }
            .map { RepoLabel(name: $0.name, color: $0.color ?? "", description: $0.description ?? "") }
    }
}

extension GitHubClient {
    /// The repo's labels from GitHub, in the repo's order.
    public func repoLabels(repo: String) async throws -> [RepoLabel] {
        try RepoLabels.decode(try await gh(["label", "list", "--repo", repo, "--json", "name,color,description",
                                            "--limit", String(RepoLabels.limit)]))
    }
}
