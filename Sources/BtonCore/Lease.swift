import Foundation
import SystemConfiguration

/// What a lease is for: `pr-304`, `issue-212`.
public struct LeaseItem: Hashable, Sendable, CustomStringConvertible {
    public let kind: String
    public let number: Int

    public init?(_ text: String) {
        guard let match = text.wholeMatch(of: /([a-z]+)-([0-9]{1,9})/), let number = Int(match.2) else { return nil }
        kind = String(match.1)
        self.number = number
    }

    public var description: String { "\(kind)-\(number)" }
    public var ref: String { "refs/bton/leases/\(self)" }
}

/// The lease commit's message.
public struct LeaseRecord: Codable, Hashable, Sendable {
    public let holder: String
    public let host: String
    public let job: UUID
    public let expires: Date
    public let released: Bool
    /// The dispatch key the job works on. A free lease that names the key a claimer wants means
    /// that work already ran on some Mac, so it is not run again.
    public let key: String?
    /// Keys of earlier jobs on this item, newest last: `key` alone forgets one as soon as the next
    /// move takes the lease.
    public let done: [String]?

    static let doneLimit = 32

    public init(holder: String, host: String, job: UUID, expires: Date, released: Bool, key: String? = nil,
                done: [String]? = nil) {
        self.holder = holder
        self.host = host
        self.job = job
        self.expires = expires
        self.released = released
        self.key = key
        self.done = done
    }

    /// Whether a job already ran `key` on this item, on any Mac.
    public func hasRun(_ key: String) -> Bool { self.key == key || done?.contains(key) == true }

    /// What the next record carries forward: this one's key joins `done`.
    var history: [String]? {
        let all = (done ?? []) + (key.map { [$0] } ?? [])
        return all.isEmpty ? nil : Array(all.suffix(Self.doneLimit))
    }

    public func isFree(at date: Date) -> Bool { released || expires <= date }
}

/// A lease this store wrote. `sha` is the commit it last pushed: the next write expects it.
public struct Lease: Hashable, Sendable {
    public let repo: String
    public let item: LeaseItem
    public let sha: String
    public let record: LeaseRecord

    /// Work starts only on a live lease: one whose write landed after its own expiry may
    /// already be someone else's.
    public func isLive(at date: Date = .now) -> Bool { !record.isFree(at: date) }
}

public enum LeaseState: Hashable, Sendable {
    case absent
    case held(LeaseRecord)
    case free(LeaseRecord)
}

public enum ClaimResult: Hashable, Sendable {
    case claimed(Lease)
    /// `holder` is nil when it is unknown: another local claim was running, or the ref moved again.
    case notClaimed(holder: LeaseRecord?)
}

public enum LeaseError: Error, Equatable, LocalizedError {
    /// The ref moved since our last write.
    case lost
    /// The live lease names another job, or is released.
    case notHolder
    /// git or gh failed or timed out. The lease counts as not held.
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .lost: "The lease was taken over or changed by someone else."
        case .notHolder: "This job does not hold the lease."
        case let .failed(reason): "Lease check failed: \(reason)"
        }
    }
}

/// One lease per piece of work across the team's Macs. Every write is a
/// `git push --force-with-lease` naming the ref's expected sha, which GitHub checks under its ref
/// lock: of two writers expecting the same value, one wins.
public struct LeaseStore: Sendable {
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let git = "/usr/bin/git"

    let home: BtonHome
    let holder: String
    let host: String
    let ttl: Duration
    let github: GitHubClient
    let remoteURL: @Sendable (String) -> String
    private let runner = ProcessRunner()

    /// This Mac's Bonjour name (`Dani.local`), set in Sharing. `ProcessInfo.hostName` asks DNS,
    /// which answers differently as networks and VPNs come and go, so a claim and its release
    /// from two processes could name two hosts and the release would be refused.
    public static var thisMac: String {
        SCDynamicStoreCopyLocalHostName(nil).map { "\($0 as String).local" } ?? ProcessInfo.processInfo.hostName
    }

    /// The name this Mac's leases carry: `thisMac` the first time, kept in `host` so the app and
    /// every CLI process name the same host even after a rename or a failed lookup. It is written
    /// whole beside the file and linked into place, so the first writer wins and nobody reads half
    /// a name; a name file that cannot be read fails rather than fall back to another name.
    public static func host(in home: BtonHome) throws -> String {
        let file = home.url.appendingPathComponent("host")
        if let name = try savedHost(file) { return name }
        try home.prepare()
        let draft = home.url.appendingPathComponent("host.\(UUID().uuidString)")
        try Data((thisMac + "\n").utf8).write(to: draft)
        defer { try? FileManager.default.removeItem(at: draft) }
        _ = Darwin.link(draft.path, file.path)
        guard let name = try savedHost(file) else { throw LeaseError.failed("\(file.path) could not be written") }
        return name
    }

    private static func savedHost(_ file: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let name = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LeaseError.failed("\(file.path) is empty") }
        return name
    }

    public init(home: BtonHome, holder: String, host: String? = nil,
                ttl: Duration = .seconds(900), github: GitHubClient,
                remoteURL: @escaping @Sendable (String) -> String = { "https://github.com/\($0).git" }) throws {
        try home.prepare()
        try FileManager.default.createDirectory(at: home.url.appendingPathComponent("locks"),
                                                withIntermediateDirectories: true)
        self.home = home
        self.holder = holder
        self.host = try host ?? Self.host(in: home)
        self.ttl = ttl
        self.github = github
        self.remoteURL = remoteURL
    }

    /// `rerun` claims a free lease even though its key already ran: the owner retried it.
    public func claim(_ item: LeaseItem, in repo: String, job: UUID = UUID(), key: String? = nil,
                      rerun: Bool = false) async throws -> ClaimResult {
        try await failingClosed {
            // A second local claim of the same item loses here, without a push.
            guard let lock = LocalLock(home.url.appendingPathComponent("locks/\(repo.replacingOccurrences(of: "/", with: "__"))__\(item).lock"))
            else { return .notClaimed(holder: nil) }
            defer { lock.release() }
            if let lease = try await writeFresh(job: job, key: key, done: nil, item: item, repo: repo, expecting: nil) {
                return .claimed(lease)
            }
            guard let (observed, current) = try await read(item, in: repo) else { return .notClaimed(holder: nil) }
            guard current.isFree(at: .now), rerun || key.map(current.hasRun) != true else { return .notClaimed(holder: current) }
            guard let lease = try await writeFresh(job: job, key: key, done: current.history, item: item, repo: repo,
                                                   expecting: observed) else { return .notClaimed(holder: nil) }
            return .claimed(lease)
        }
    }

    public func renew(_ lease: Lease) async throws -> Lease {
        try await failingClosed {
            guard let renewed = try await writeFresh(job: lease.record.job, key: lease.record.key, done: lease.record.done,
                                                     item: lease.item, repo: lease.repo, expecting: lease.sha)
            else { throw LeaseError.lost }
            return renewed
        }
    }

    /// `ran: false` gives back a lease whose job never started: its key stays claimable without a rerun.
    public func release(_ lease: Lease, ran: Bool = true) async throws {
        try await failingClosed {
            let released = LeaseRecord(holder: lease.record.holder, host: lease.record.host, job: lease.record.job,
                                       expires: lease.record.expires, released: true, key: ran ? lease.record.key : nil,
                                       done: lease.record.done)
            guard try await write(released, item: lease.item, repo: lease.repo, expecting: lease.sha) != nil
            else { throw LeaseError.lost }
        }
    }

    public func state(of item: LeaseItem, in repo: String) async throws -> LeaseState {
        try await failingClosed {
            guard let (_, record) = try await read(item, in: repo) else { return .absent }
            return record.isFree(at: .now) ? .free(record) : .held(record)
        }
    }

    /// The live lease of `job`, for a process that did not claim it itself (the CLI's renew and
    /// release). `anyHost` is for a job this Mac's own store and lock already prove is its own,
    /// whatever name its lease was written under.
    public func current(_ item: LeaseItem, in repo: String, job: UUID, anyHost: Bool = false) async throws -> Lease {
        try await failingClosed {
            guard let (sha, record) = try await read(item, in: repo), record.job == job, !record.released,
                  record.holder.caseInsensitiveCompare(holder) == .orderedSame, anyHost || record.host.caseInsensitiveCompare(host) == .orderedSame
            else { throw LeaseError.notHolder }
            return Lease(repo: repo, item: item, sha: sha, record: record)
        }
    }

    // MARK: git and gh

    /// Writes a new unreleased record. A write that lands late (a Mac asleep mid-push) can return
    /// a lease already past `expires`; the dispatcher checks `isLive` before starting work.
    private func writeFresh(job: UUID, key: String?, done: [String]?, item: LeaseItem, repo: String,
                            expecting expected: String?) async throws -> Lease? {
        let record = LeaseRecord(holder: holder, host: host, job: job, expires: .now + ttl.timeInterval,
                                 released: false, key: key, done: done)
        guard let (sha, written) = try await write(record, item: item, repo: repo, expecting: expected) else { return nil }
        return Lease(repo: repo, item: item, sha: sha, record: written)
    }

    /// Pushes a new commit carrying `record`. Returns its sha and the record as readers will decode
    /// it (`expires` keeps milliseconds) when GitHub applied it, nil when the ref no longer had the
    /// expected value (nil expected: the ref must not exist).
    private func write(_ record: LeaseRecord, item: LeaseItem, repo: String,
                       expecting expected: String?) async throws -> (sha: String, record: LeaseRecord)? {
        let repository = try await leaseRepository()
        let json = try Self.encoder.encode(record)
        let written = try Self.decoder.decode(LeaseRecord.self, from: json)
        // The record, then a nonce: two writes of the same record are still two commits, so a push
        // is never "up to date" and always goes through the server's check of the expected sha.
        let message = String(decoding: json, as: UTF8.self) + "\n\n" + UUID().uuidString
        let commit = try await git(["-C", repository.path, "-c", "user.name=Bton", "-c", "user.email=bton@localhost",
                                    "commit-tree", Self.emptyTree, "-m", message])
        let sha = String(decoding: commit.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard commit.status == 0, !sha.isEmpty else { throw LeaseError.failed("git commit-tree: \(commit.stderr)") }
        // Two refusals are not the CAS losing, and are retried with backoff (the server checks the
        // expected sha under its ref lock on every attempt): "stale info", git's own check against
        // an advertised ref that can lag the real one for seconds, and a "remote rejected" for any
        // reason but the lock (seen: "(failed)" with the ref still at the expected sha). The API
        // can lag too, so only a create on a ref it already shows is a plain loss, answered at
        // once, since every tick's claim of a held lease is one.
        for attempt in 1...5 {
            let push = try await git(["-C", repository.path, "-c", "credential.helper=",
                                      "-c", "credential.helper=!\(github.ghPath) auth git-credential",
                                      "push", "--porcelain", "--force-with-lease=\(item.ref):\(expected ?? "")",
                                      remoteURL(repo), "\(sha):\(item.ref)"], timeout: .seconds(30))
            // Porcelain: "<flag>\t<src>:<dst>\t<summary>". "!" is a rejection; anything without our
            // line, and "=" (up to date: the server checked nothing), is an error.
            let line = String(decoding: push.stdout, as: UTF8.self).split(separator: "\n")
                .first { $0.contains("\t\(sha):\(item.ref)\t") }
            switch line?.first {
            case "!" where attempt < 5 && (line?.hasSuffix("(stale info)") == true
                                            || line?.contains("[remote rejected]") == true && line?.contains("cannot lock ref") == false):
                let current = try await refSha(item, in: repo)
                if current == sha { return (sha, written) }
                if expected == nil, current != nil { return nil }
                try await Task.sleep(for: .seconds(attempt))
            case "!": return nil
            case let flag? where push.status == 0 && " +*".contains(flag): return (sha, written)
            // Up to date with a commit only this write made: an earlier attempt landed after all.
            case "=" where attempt > 1 && push.status == 0: return (sha, written)
            default: throw LeaseError.failed("git push exited \(push.status): \(push.stderr.prefix(300))")
            }
        }
        return nil
    }

    /// The lease ref's sha as the API returns it; nil when there is no lease.
    private func refSha(_ item: LeaseItem, in repo: String) async throws -> String? {
        struct Ref: Decodable { struct Object: Decodable { let sha: String }; let object: Object }
        guard let refData = try await github.get("repos/\(repo)/git/ref/\(item.ref.dropFirst("refs/".count))") else { return nil }
        return try JSONDecoder().decode(Ref.self, from: refData).object.sha
    }

    private func read(_ item: LeaseItem, in repo: String) async throws -> (sha: String, record: LeaseRecord)? {
        struct Commit: Decodable { let message: String }
        guard let sha = try await refSha(item, in: repo) else { return nil }
        guard let commitData = try await github.get("repos/\(repo)/git/commits/\(sha)") else {
            throw LeaseError.failed("lease commit \(sha) not found")
        }
        let message = try JSONDecoder().decode(Commit.self, from: commitData).message
        let record = String(message.prefix { !$0.isNewline })
        return (sha, try Self.decoder.decode(LeaseRecord.self, from: Data(record.utf8)))
    }

    /// A bare repo that only holds lease commits. Made under a temporary name and renamed into
    /// place, so two processes starting at once never see a half-made one.
    private func leaseRepository() async throws -> URL {
        let target = home.url.appendingPathComponent("leases.git", isDirectory: true)
        if FileManager.default.fileExists(atPath: target.appendingPathComponent("HEAD").path) { return target }
        let staging = home.url.appendingPathComponent("leases.git.\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for arguments in [["init", "-q", "--bare", staging.path],
                          ["-C", staging.path, "hash-object", "-w", "-t", "tree", "/dev/null"]] {
            let result = try await git(arguments)
            guard result.status == 0 else { throw LeaseError.failed("git \(arguments[0]): \(result.stderr)") }
        }
        do {
            try FileManager.default.moveItem(at: staging, to: target)
        } catch where FileManager.default.fileExists(atPath: target.appendingPathComponent("HEAD").path) {
            // Another process won the rename; its repo is as good as ours.
        }
        return target
    }

    private func git(_ arguments: [String], timeout: Duration = .seconds(15)) async throws -> ProcessOutput {
        try await runner.run(Self.git, arguments, environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: timeout)
    }

    /// Any failure other than a lease outcome is reported as `failed`: the caller treats the lease as not held.
    private func failingClosed<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let error as LeaseError {
            throw error
        } catch {
            throw LeaseError.failed(error.localizedDescription)
        }
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    // Fractional seconds, so two writes of one job in the same second are still distinct commits.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(fractional))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = (try? Date(text, strategy: fractional)) ?? (try? Date(text, strategy: .iso8601)) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "expires: \(text)"))
        }
        return decoder
    }()
}

/// A non-blocking `flock`: nil when another process (or task) on this Mac holds it.
final class LocalLock: Sendable {
    let descriptor: Int32

    init?(_ url: URL) {
        // Close-on-exec: a child (an agent) that inherited it would hold it after Bton exits.
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return nil }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        self.descriptor = descriptor
    }

    func release() { close(descriptor) }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
