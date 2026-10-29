@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct CheckCacheAcceptanceTests {
    @Test func a_decodingAndValidation() throws {
        let data = try CacheAcceptanceFixture.flowData()
        guard case let .ready(flow) = Flow.load(data) else {
            Issue.record("A valid cache must load"); return
        }
        let cache = try #require(flow.checks?.cache)
        #expect(cache.key == ["lock.txt"])
        #expect(cache.paths == ["deps"])
        guard case .invalid = Flow.load(try CacheAcceptanceFixture.flowData(keys: [])) else {
            Issue.record("Empty cache keys must be invalid"); return
        }
        guard case let .invalid(message) = Flow.load(try CacheAcceptanceFixture.flowData(paths: ["../x"])) else {
            Issue.record("A cache path outside the repo must be invalid"); return
        }
        #expect(message == "checks.cache: ../x must be a relative path inside the repo")
    }

    @Test func b_key() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        for dir in [first, second] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: dir.appendingPathComponent("lock.txt"))
        }
        let flow = try JSONDecoder().decode(Flow.self, from: CacheAcceptanceFixture.flowData())
        let cache = try #require(flow.checks?.cache)
        let present = CheckCache.key(for: cache, in: first)
        // SHA-256("abc"), truncated to the contract's first sixteen hex digits.
        #expect(present == "ba7816bf8f01cfea")
        #expect(CheckCache.key(for: cache, in: second) == present)
        try Data("abd".utf8).write(to: second.appendingPathComponent("lock.txt"))
        #expect(CheckCache.key(for: cache, in: second) != present)
        try FileManager.default.removeItem(at: second.appendingPathComponent("lock.txt"))
        let missing = CheckCache.key(for: cache, in: second)
        #expect(missing != present)
        #expect(CheckCache.key(for: cache, in: second) == missing)
        try FileManager.default.removeItem(at: first.appendingPathComponent("lock.txt"))
        #expect(CheckCache.key(for: cache, in: first) == missing)
    }

    @Test func c_dispatcherRealProcesses() async throws {
        let f = try await CacheAcceptanceFixture.make()
        defer { f.remove() }
        let firstHead = try await f.commitPR(7)
        let first = try await f.run(number: 7, head: firstHead)
        #expect(first.status == .succeeded)
        let key = try f.cacheKey()
        #expect(f.text(f.cached(key).appendingPathComponent("deps/x")) == "built\n")
        #expect(f.notes(first).contains("cache: saved deps for key \(key)"))
        let secondHead = try await f.commitPR(8)
        #expect(secondHead != firstHead)
        let second = try await f.run(number: 8, head: secondHead)
        #expect(second.status == .succeeded)
        #expect(f.text(f.builds) == "built\n")
        #expect(f.notes(second).contains("cache: restored deps for key \(key)"))
        let worktree = URL(fileURLWithPath: try #require(second.worktree))
        #expect(f.text(worktree.appendingPathComponent("deps/x")) == "built\n")
    }

    @Test func d_failingCheckSavesNothingAndChecksFalseTouchesNeitherDirection() async throws {
        let f = try await CacheAcceptanceFixture.make()
        defer { f.remove() }
        let failedHead = try await f.commitPR(7)
        let failed = try await f.run(number: 7, head: failedHead,
            check: "mkdir deps && echo failed > deps/x; exit 1")
        #expect(failed.status == .failed)
        let key = try f.cacheKey()
        #expect(!f.exists(f.cached(key)))
        #expect(!f.notes(failed).contains("cache: saved"))

        // A cold skipped job creates deps in its agent: an accidental save is observable.
        let coldHead = try await f.commitPR(8)
        let cold = try await f.run(number: 8, head: coldHead, skip: true,
            action: "test ! -d deps && mkdir deps && echo agent > deps/x")
        #expect(cold.status == .succeeded)
        #expect(!f.exists(f.cached(key)))
        #expect(!f.notes(cold).contains("cache:"))

        // A warm skipped job must not restore, overwrite, or save any configured path.
        let cachedDeps = f.cached(key).appendingPathComponent("deps")
        try FileManager.default.createDirectory(at: cachedDeps, withIntermediateDirectories: true)
        try "cached\n".write(to: cachedDeps.appendingPathComponent("x"), atomically: true, encoding: .utf8)
        let warmHead = try await f.commitPR(9)
        let warm = try await f.run(number: 9, head: warmHead, skip: true,
            action: "test ! -d deps && mkdir deps && echo agent > deps/x")
        #expect(warm.status == .succeeded)
        #expect(f.text(cachedDeps.appendingPathComponent("x")) == "cached\n")
        #expect(!f.notes(warm).contains("cache:"))
        #expect(!f.exists(f.builds))
    }

    @Test func e_symlinkedParentAndKeyAreSkippedAndNestedPathRestores() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let worktree = root.appendingPathComponent("worktree")
        let outside = root.appendingPathComponent("outside")
        let fresh = root.appendingPathComponent("fresh")
        for directory in [worktree, outside, fresh] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path])
        let repo = "synthetic/project"
        let cacheRoot = home.url.appendingPathComponent("cache/\(repo)")
        let notes = CacheAcceptanceNotes()
        let flow = try JSONDecoder().decode(Flow.self,
            from: CacheAcceptanceFixture.flowData(paths: ["build/deps"]))
        let cache = try #require(flow.checks?.cache)
        try fm.createSymbolicLink(at: worktree.appendingPathComponent("build"), withDestinationURL: outside)

        let seeded = cacheRoot.appendingPathComponent("restore-key/build/deps")
        try fm.createDirectory(at: seeded, withIntermediateDirectories: true)
        try Data("cached".utf8).write(to: seeded.appendingPathComponent("x"))
        await CheckCache.restore(cache, key: "restore-key", into: worktree, home: home, repo: repo,
                                 note: { notes.append($0) })
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(notes.values.isEmpty)

        let outsideDeps = outside.appendingPathComponent("deps")
        try fm.createDirectory(at: outsideDeps, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideDeps.appendingPathComponent("x"))
        await CheckCache.save(cache, key: "save-key", from: worktree, home: home, repo: repo,
                              note: { notes.append($0) })
        #expect(!fm.fileExists(atPath: cacheRoot.appendingPathComponent("save-key").path))
        #expect(notes.values.isEmpty)

        let missingKey = CheckCache.key(for: cache, in: worktree)
        let outsideLock = outside.appendingPathComponent("lock.txt")
        try Data("abc".utf8).write(to: outsideLock)
        try fm.createSymbolicLink(at: worktree.appendingPathComponent("lock.txt"), withDestinationURL: outsideLock)
        #expect(CheckCache.key(for: cache, in: worktree) == missingKey)

        let nestedFlow = try JSONDecoder().decode(Flow.self,
            from: CacheAcceptanceFixture.flowData(paths: [".build/checkouts"]))
        let nested = try #require(nestedFlow.checks?.cache)
        let source = worktree.appendingPathComponent(".build/checkouts")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("nested dependency".utf8).write(to: source.appendingPathComponent("x"))
        let nestedKey = CheckCache.key(for: nested, in: fresh)
        await CheckCache.save(nested, key: nestedKey, from: worktree, home: home, repo: repo,
                              note: { notes.append($0) })
        #expect(try Data(contentsOf: cacheRoot.appendingPathComponent("\(nestedKey)/.build/checkouts/x"))
                == Data("nested dependency".utf8))
        #expect(!fm.fileExists(atPath: fresh.appendingPathComponent(".build").path))
        await CheckCache.restore(nested, key: nestedKey, into: fresh, home: home, repo: repo,
                                 note: { notes.append($0) })
        #expect(try Data(contentsOf: fresh.appendingPathComponent(".build/checkouts/x"))
                == Data("nested dependency".utf8))
        #expect(notes.values == ["cache: saved .build/checkouts for key \(nestedKey)",
                                 "cache: restored .build/checkouts for key \(nestedKey)"])
    }
}

private final class CacheAcceptanceNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String] = []
    func append(_ value: String) { lock.lock(); defer { lock.unlock() }; strings.append(value) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return strings }
}

private struct CacheAcceptanceFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    var root: URL { base.leases.root }
    var builds: URL { root.appendingPathComponent("builds") }
    static let repo = "synthetic/project"
    static let build = "test -d deps || (mkdir deps && echo built > deps/x && echo built >> \"$BUILDS\")"

    static func flowData(keys: [String] = ["lock.txt"], paths: [String] = ["deps"],
                         check: String = build, skip: Bool = false) throws -> Data {
        var rule: [String: Any] = ["agent": "synthetic", "prompt": "TASK", "timeoutMinutes": 1]
        if skip { rule["checks"] = false }
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:"]]], "fixed": "Fixed:",
            "moves": [["move": "review", "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": ["review": rule],
            "checks": ["beforeSession": [["/bin/sh", "-c", check]], "beforeMerge": [],
                       "cache": ["key": keys, "paths": paths]]]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func make() async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        do {
            let gh = base.leases.root.appendingPathComponent("gh")
            let original = try String(contentsOf: gh, encoding: .utf8)
            let handler = """
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              cat "$(dirname "$0")/answer"
              exit 0
            fi
            if [ "${1-}" != api ]; then exit 0; fi
            """
            try original.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler)
                .write(to: gh, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
            let github = GitHubClient(ghPath: gh.path)
            let remote = base.leases.root.appendingPathComponent("origin.git").path
            let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture",
                github: github, remoteURL: { _ in remote })
            let store = try JobStore(home: base.home)
            return Self(base: base, store: store,
                dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }))
        } catch {
            try? FileManager.default.removeItem(at: base.leases.root)
            throw error
        }
    }

    func commitPR(_ number: Int) async throws -> String {
        try "abc".write(to: base.clone.appendingPathComponent("lock.txt"), atomically: true, encoding: .utf8)
        // Change the tree as well as the head so tree receipts cannot bypass the check.
        try "PR \(number)\n".write(to: base.clone.appendingPathComponent("pr-marker"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "lock.txt", "pr-marker"])
        _ = try await git(["-c", "user.name=Synthetic", "-c", "user.email=test@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", "PR \(number)"])
        _ = try await git(["push", "origin", "HEAD:refs/pull/\(number)/head"])
        return try await git(["rev-parse", "HEAD"])
    }

    func run(number: Int, head: String, check: String = build, skip: Bool = false,
             action: String = "echo done") async throws -> Job {
        try "{\"headRefOid\":\"\(head)\",\"state\":\"OPEN\"}"
            .write(to: root.appendingPathComponent("answer"), atomically: true, encoding: .utf8)
        let flow = try JSONDecoder().decode(Flow.self, from: Self.flowData(check: check, skip: skip))
        let pr = PullRequest(repo: Self.repo, number: number, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/\(number)")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: .now)
        let candidate = try #require(DispatchPlanner.candidates([pr], flow: flow, me: "owner", repo: pr.repo).first)
        #expect(candidate.skipsChecks == skip)
        let before = Set(store.all().map(\.id))
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
                agents: ["synthetic": AgentTemplate(argv: ["/bin/sh", "-c", action])],
                environment: ["BUILDS": builds.path])
            switch outcome {
            case .started:
                let id = try #require(store.all().first { !before.contains($0.id) }?.id)
                return try await finished(id)
            case .busy:
                try await Task.sleep(for: .milliseconds(20))
            default:
                throw DispatchError.worktree("Cache acceptance dispatch refused: \(outcome)")
            }
        }
        throw DispatchError.worktree("Cache acceptance dispatch remained busy")
    }

    func finished(_ id: UUID) async throws -> Job {
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let job = store.all().first(where: { $0.id == id && $0.status != .running }),
               !exists(store.lockURL(id)) { return job }
            try await Task.sleep(for: .milliseconds(20))
        }
        await dispatcher.stop(id)
        throw DispatchError.worktree("Cache acceptance job exceeded sixty seconds")
    }

    func git(_ args: [String]) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path] + args, timeout: .seconds(60))
        try #require(result.status == 0, "Git fixture: \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func cacheKey() throws -> String {
        let flow = try JSONDecoder().decode(Flow.self, from: Self.flowData())
        return CheckCache.key(for: try #require(flow.checks?.cache), in: base.clone)
    }
    func cached(_ key: String) -> URL {
        base.home.url.appendingPathComponent("cache/\(Self.repo.lowercased())/\(key)")
    }
    // JobStore.note persists notes in the job log in this checkout; Job has no notes property.
    func notes(_ job: Job) -> String { text(store.logURL(job.id)) }
    func text(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
