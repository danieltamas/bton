import Foundation

/// A repo's graphify graph, kept under this Mac's Bton home and linked into each checkout as
/// `graphify-out`, the name graphify and its query tools look for. One store per repo: a PR
/// worktree reads the graph of the branch PRs merge into, never rebuilds it (the store is
/// shared by every job, and lexito's is 157 MB).
public enum CodeGraph {
    /// The name in a checkout; graphify writes to it and `graphify-src` finds it.
    public static let linkName = "graphify-out"
    static let markerName = "bton-build.json"

    /// Where the venv is usually made, in the order tried when no path is set.
    static let pythonCandidates = [".venvs/graphifyy-arm64/bin/python", ".local/pipx/venvs/graphifyy/bin/python"]

    /// The Python to run graphify with: the configured one when it is executable, else the first
    /// usual venv under `home` that is. Nil: nothing builds, and Settings says so.
    public static func python(configured: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let files = FileManager.default
        if let configured {
            let path = (configured as NSString).expandingTildeInPath
            return files.isExecutableFile(atPath: path) ? path : nil
        }
        return pythonCandidates.map { home.appendingPathComponent($0).path }.first(where: files.isExecutableFile)
    }

    /// `<home>/graphs/<owner>__<repo>`, lowercased: one directory per repo whatever the case GitHub shows.
    public static func store(for slug: String, home: BtonHome) -> URL {
        let key = slug.lowercased().replacingOccurrences(of: "/", with: "__")
        return home.url.appendingPathComponent("graphs", isDirectory: true).appendingPathComponent(key, isDirectory: true)
    }

    /// Whether the store holds a graph to query.
    public static func isBuilt(_ store: URL) -> Bool {
        FileManager.default.fileExists(atPath: store.appendingPathComponent("graph.json").path)
    }

    /// Whether a repo's graph is there for a job that needs it, and when not, why.
    public enum Readiness: Equatable, Sendable {
        /// The repo does not build one (the switch in Settings > Repos and on the repo's page).
        case off
        /// The switch is on and no Python with graphify was found.
        case missingPython
        /// The switch is on and the first build has not finished.
        case building
        case ready

        /// Why a job that needs the graph waits; nil when it can run.
        public var hold: String? {
            switch self {
            case .off: "the repo builds no code graph yet: turn it on in Settings > Repos or on the repo's page"
            case .missingPython: CodeGraphBuilder.missingPython
            case .building: "the code graph is being built"
            case .ready: nil
            }
        }
    }

    /// graphify's output during a build, in the staging copy of the store, so the page can show
    /// how far the build is; published with the graph as a record of the build.
    static let buildLogName = "bton-build.log"

    /// Where a build in progress stands, from its log so far.
    public struct Progress: Equatable, Sendable {
        public var step: String
        /// Set while graphify reads the files, the one phase it counts.
        public var fraction: Double?
    }

    /// nil when no build is in progress (no staging copy with a log).
    public static func progress(in store: URL) -> Progress? {
        let log = URL(fileURLWithPath: store.path + ".next", isDirectory: true).appendingPathComponent(buildLogName)
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return progress(from: text)
    }

    /// graphify's AST extraction prints `n/m uncached files`; after it, the grouping into
    /// communities and the report take a while with no count.
    static func progress(from text: String) -> Progress {
        var last: (done: Int, total: Int)?
        var grouping = false
        // A count graphify rewrites in place arrives after a carriage return, not a newline.
        for line in text.components(separatedBy: .newlines) {
            if let range = line.range(of: "AST extraction: ") {
                let counts = line[range.upperBound...].prefix { $0.isNumber || $0 == "/" }.split(separator: "/")
                if counts.count == 2, let done = Int(counts[0]), let total = Int(counts[1]), total > 0 {
                    last = (done, total)
                    grouping = false
                }
            } else if last != nil, !line.trimmingCharacters(in: .whitespaces).isEmpty {
                grouping = true
            }
        }
        guard let last else { return Progress(step: "Preparing the tree", fraction: nil) }
        if grouping || last.done == last.total { return Progress(step: "Grouping the code into modules", fraction: nil) }
        return Progress(step: "Reading \(last.done) of \(last.total) files", fraction: Double(last.done) / Double(last.total))
    }

    /// A graph in the store with its build marker counts, whether or not graphify's Python is
    /// still found: the same pair a job's worktree gets linked. A graph moved in from a clone has
    /// no marker until the first build here finishes.
    public static func readiness(of repo: WatchedRepo, python: String?, home: BtonHome) -> Readiness {
        guard repo.buildsGraph else { return .off }
        let store = store(for: repo.slug, home: home)
        if isBuilt(store), marker(in: store) != nil { return .ready }
        return python == nil ? .missingPython : .building
    }

    public enum LinkOutcome: Equatable, Sendable {
        case linked, alreadyLinked
        /// The checkout's own graph moved into the empty store, and the link took its place.
        case moved
        /// Something else has the name; nothing was changed, for this reason.
        case kept(String)
    }

    /// Makes `<checkout>/graphify-out` a link to the store. A graph the checkout already has (a
    /// person's hand-built one, lexito's today) moves into an empty store rather than being lost;
    /// one the store cannot take, a file, or a link elsewhere is left as it is.
    @discardableResult
    public static func link(into checkout: URL, store: URL) throws -> LinkOutcome {
        let files = FileManager.default
        try files.createDirectory(at: store, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = checkout.appendingPathComponent(linkName)
        if let type = try? files.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType {
            switch type {
            case .typeSymbolicLink:
                // Followed to the end: a team's own hook may link the worktree to the clone's
                // graphify-out, which is itself a link to the store.
                let target = try files.destinationOfSymbolicLink(atPath: path.path)
                let same = path.resolvingSymlinksInPath().standardizedFileURL.path == store.resolvingSymlinksInPath().standardizedFileURL.path
                return same ? .alreadyLinked : .kept("\(linkName) links to \(target)")
            case .typeDirectory:
                guard !isBuilt(store) else { return .kept("\(linkName) is a directory and the store already has a graph") }
                for name in try files.contentsOfDirectory(atPath: path.path) {
                    try files.moveItem(at: path.appendingPathComponent(name), to: store.appendingPathComponent(name))
                }
                try files.removeItem(at: path)
                try files.createSymbolicLink(atPath: path.path, withDestinationPath: store.path)
                return .moved
            default:
                return .kept("\(linkName) is a file")
            }
        }
        try files.createSymbolicLink(atPath: path.path, withDestinationPath: store.path)
        return .linked
    }

    /// What the store's graph was built from; written after a successful build only, so a failed
    /// one leaves the previous commit and the next sync tries again.
    public struct Marker: Codable, Equatable, Sendable {
        public var commit: String
        public var at: Date

        public init(commit: String, at: Date) {
            self.commit = commit
            self.at = at
        }
    }

    public static func marker(in store: URL) -> Marker? {
        guard let data = try? Data(contentsOf: store.appendingPathComponent(markerName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Marker.self, from: data)
    }

    public static func writeMarker(_ marker: Marker, in store: URL) throws {
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(marker).write(to: store.appendingPathComponent(markerName), options: .atomic)
    }

    /// The line a Claude job gets with its team instructions: the graph is the base's, not the branch's.
    public static func instructionLine(base: String, marker: Marker) -> String {
        "Code graph: \(linkName)/ in this checkout is graphify's graph of \(base) at \(marker.commit.prefix(8)); "
            + "this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree."
    }
}
