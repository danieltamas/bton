import Foundation

/// Bton asked GitHub to run a head's failed workflows again, before the move that answers its red
/// checks: one ask per head, counted whether GitHub took it or not, so a head never gets a second.
public struct CheckRerun: Codable, Hashable, Sendable {
    public let repo: String
    public let number: Int
    public let head: String
    public let at: Date
    /// GitHub took the ask: the head's checks run again, and its move waits for them.
    public let asked: Bool
    /// The checks that had failed on the head when it was asked: one of them green later, on
    /// the same head, is a flake (`Flakes.afterRerun`).
    public let checks: [String]

    public init(repo: String, number: Int, head: String, at: Date, asked: Bool, checks: [String] = []) {
        self.repo = repo
        self.number = number
        self.head = head
        self.at = at
        self.asked = asked
        self.checks = checks
    }
}

/// `~/.bton/reruns.json`, a JSON array of `CheckRerun` records, newest first, 500 at most. Kept
/// on disk, so a restart never asks a head again, and never dropped for its age: a PR left open
/// for a month on one head must not earn a second ask.
public struct CheckRerunStore: Equatable, Sendable {
    public static let file = "reruns.json"
    public static let limit = 500

    public var reruns: [CheckRerun]

    public init(reruns: [CheckRerun] = []) { self.reruns = reruns }

    public static func url(home: BtonHome) -> URL { home.url.appendingPathComponent(file) }

    /// Missing is empty. Unreadable is nil: a head whose record cannot be read is never asked,
    /// or a damaged file would ask every red head again at each sync.
    public static func load(home: BtonHome) -> CheckRerunStore? {
        guard let data = try? Data(contentsOf: url(home: home)) else {
            return FileManager.default.fileExists(atPath: url(home: home).path) ? nil : CheckRerunStore()
        }
        return (try? JSONDecoder().decode([CheckRerun].self, from: data)).map { CheckRerunStore(reruns: $0) }
    }

    public func save(home: BtonHome) throws {
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reruns).write(to: Self.url(home: home), options: .atomic)
    }

    public func pruned(now: Date = .now) -> CheckRerunStore {
        CheckRerunStore(reruns: Array(reruns.sorted { $0.at > $1.at }.prefix(Self.limit)))
    }

    /// The store with these flakes' checks taken off their asks: a check recorded as a flake is
    /// not waited on again, whatever the flake store later drops. The ask itself stays.
    public func settling(_ flakes: [Flake]) -> CheckRerunStore {
        CheckRerunStore(reruns: reruns.map { rerun in
            let settled = Set(flakes.filter { $0.head == rerun.head && $0.repo.caseInsensitiveCompare(rerun.repo) == .orderedSame }.map(\.check))
            return settled.isEmpty ? rerun : CheckRerun(repo: rerun.repo, number: rerun.number, head: rerun.head, at: rerun.at,
                                                       asked: rerun.asked, checks: rerun.checks.filter { !settled.contains($0) })
        })
    }

    public func rerun(repo: String, head: String) -> CheckRerun? {
        reruns.first { $0.head == head && $0.repo.caseInsensitiveCompare(repo) == .orderedSame }
    }
}

public enum CheckReruns {
    /// How long after an ask GitHub may still show the old red run: the move waits that long, then
    /// reads whatever the head says.
    public static let settle: TimeInterval = FlowEngine.registration

    public enum Step: Equatable, Sendable {
        /// Ask GitHub now; the move waits for the new run.
        case ask
        /// Asked moments ago: the red read may still be the old run.
        case wait
        /// The move starts: the head was asked before and is red again, or was never to be asked.
        case start
    }

    /// What a sync does with a candidate that answers its head's red checks. Only a move that
    /// never ran on the head is preceded by a re-run; a person's press starts the agent at once.
    /// `now` is when the head's checks were read: a red read from inside the settle time stays a
    /// wait however long the sync took since.
    public static func step(for key: JobKey, failedChecks: [String], pressed: Bool, jobs: [Job],
                            store: CheckRerunStore?, now: Date = .now) -> Step {
        guard !pressed, !failedChecks.isEmpty, let store else { return .start }
        let onHead = { (job: Job) in
            job.key.repo.caseInsensitiveCompare(key.repo) == .orderedSame && job.key.item == key.item
                && job.key.move == key.move && job.key.head == key.head
        }
        guard !jobs.contains(where: onHead) else { return .start }
        guard let rerun = store.rerun(repo: key.repo, head: key.head) else { return .ask }
        return rerun.asked && now.timeIntervalSince(rerun.at) < settle ? .wait : .start
    }
}
