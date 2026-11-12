import Foundation

/// A PR that a session on this Mac answers itself: the author's own agent watching it (lexito-watch
/// and the like) marks it with `bton watching`, and until the mark runs out Bton starts no agent of
/// its own that works on the PR's branch. That session wrote the PR and holds its context; an agent
/// of Bton's would be a second writer on the same branch, starting from nothing.
///
/// A mark is a file per PR with one line per session holding it: `<runs out, ISO 8601> <holder>`
/// (a line without a holder is the `default` one). The PR is held while any line is live, so one
/// session letting go never ends another's hold. Only this Mac reads it: the moves it holds back are
/// the author's, and those run on the author's Mac.
public struct SessionWatch: Sendable {
    /// The longest a mark may be set for: a session that dies without clearing its mark holds the
    /// PR back at most this long.
    public static let longest: TimeInterval = 6 * 3600
    public static let defaultHolder = "default"

    let directory: URL

    public init(home: BtonHome) {
        directory = home.url.appendingPathComponent("watching", isDirectory: true)
    }

    /// Whether a mark can hold `candidate` back: an agent that works on the branch of a PR of mine.
    public static func holds(_ candidate: DispatchCandidate, me: String) -> Bool {
        guard candidate.writesBranch, let pr = candidate.pr else { return false }
        return pr.author.caseInsensitiveCompare(me) == .orderedSame
    }

    /// A holder name that stays one token on its line.
    public static func isHolderName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9._-]{1,128}/) != nil
    }

    func file(repo: String, number: Int) -> URL {
        directory.appendingPathComponent("\(repo.lowercased().replacingOccurrences(of: "/", with: "__"))__\(number)")
    }

    /// Marks the PR watched by `holder` until `seconds` from now, capped at `longest`. Returns the
    /// time it runs out. Other holders' lines stay.
    @discardableResult
    public func mark(repo: String, number: Int, for seconds: TimeInterval, holder: String = defaultHolder,
                     now: Date = .now) throws -> Date {
        let until = now + min(max(seconds, 0), Self.longest)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try locked(repo: repo, number: number) {
            let others = lines(repo: repo, number: number).filter { Self.holder(of: $0) != holder }
            try write(others + ["\(until.formatted(.iso8601)) \(holder)"], repo: repo, number: number)
        }
        return until
    }

    /// Ends `holder`'s mark; the file goes once no holder is left. Clearing an absent mark does nothing.
    public func clear(repo: String, number: Int, holder: String = defaultHolder) throws {
        try locked(repo: repo, number: number) {
            let rest = lines(repo: repo, number: number).filter { Self.holder(of: $0) != holder }
            if rest.isEmpty {
                do {
                    try FileManager.default.removeItem(at: file(repo: repo, number: number))
                } catch CocoaError.fileNoSuchFile {
                    // Already clear.
                }
            } else {
                try write(rest, repo: repo, number: number)
            }
        }
    }

    /// One writer per PR's mark at a time, across processes: two sessions' read-modify-writes would
    /// otherwise drop each other's lines. Waits for the other writer, which holds it for one write.
    private func locked(repo: String, number: Int, _ body: () throws -> Void) throws {
        let locks = directory.deletingLastPathComponent().appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let path = locks.appendingPathComponent("watching__\(file(repo: repo, number: number).lastPathComponent).lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: path]) }
        try body()
    }

    /// When the last live hold runs out; nil when the PR has none. A mark that cannot be read throws.
    public func until(repo: String, number: Int, at now: Date = .now) throws -> Date? {
        guard let lines = try read(repo: repo, number: number) else { return nil }
        let times = try lines.map { line -> Date in
            guard let date = try? Date(String(line.split(separator: " ").first ?? ""), strategy: .iso8601) else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: file(repo: repo, number: number).path])
            }
            return date
        }
        // An empty mark file was never written whole: unreadable, not absent.
        guard !times.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return times.filter { $0 > now && $0 <= now + Self.longest }.max()
    }

    /// Whether a session holds `pr` now, under the repo's name as Bton knows it or as GitHub names it
    /// in the PR's URL: a renamed repo is still watched under the old name on a Mac whose config
    /// predates the rename, while `gh repo view` in a checkout gives the new one.
    public func isWatched(_ pr: PullRequest, repo: String, at now: Date = .now) -> Bool {
        let parts = pr.url.pathComponents  // ["/", owner, name, "pull", number]
        let canonical = parts.count >= 3 ? "\(parts[1])/\(parts[2])" : repo
        return isWatched(repo: repo, number: pr.number, at: now)
            || (canonical.caseInsensitiveCompare(repo) != .orderedSame && isWatched(repo: canonical, number: pr.number, at: now))
    }

    /// Whether a session holds the PR now. Fails closed: a mark that cannot be read, or a watching
    /// directory that cannot be looked into, counts as held, since a second writer on the branch is
    /// the costlier mistake; a mark past its time, or one set further out than `longest`, does not.
    public func isWatched(repo: String, number: Int, at now: Date = .now) -> Bool {
        do {
            return try until(repo: repo, number: number, at: now) != nil
        } catch {
            return true
        }
    }

    /// The file's lines; nil only when the file is confirmed absent.
    private func read(repo: String, number: Int) throws -> [String]? {
        let data: Data
        do {
            data = try Data(contentsOf: file(repo: repo, number: number))
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// For a rewrite: an unreadable mark is replaced rather than kept.
    private func lines(repo: String, number: Int) -> [String] {
        (try? read(repo: repo, number: number)) ?? []
    }

    private func write(_ lines: [String], repo: String, number: Int) throws {
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file(repo: repo, number: number), options: .atomic)
    }

    private static func holder(of line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : defaultHolder
    }
}
