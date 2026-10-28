@testable import BtonCore
import Foundation
import Testing
import Darwin
struct EnvironmentProbeAcceptanceTests {
    @Test func endpointsRequireExplicitValidPortsAndSortByKey() {
        let endpoints = EnvironmentProbe.endpoints(in: [
            "Z_REDIS": "redis://127.0.0.1:6380",
            "DATABASE_URL": "postgres://user:probe-secret@127.0.0.1:55439/db",
            "HTTP": "http://localhost:8080/path", "NO_PORT": "http://localhost/path",
            "GARBAGE": "not a URL", "ZERO": "redis://localhost:0",
            "TOO_LARGE": "redis://localhost:70000", "NUL": "redis://localhost:6380\0",
            "NO_SCHEME": "//localhost:6380", "NO_HOST": "redis:///db:6380",
            "CUSTOM": "custom://localhost:65535"
        ])
        #expect(endpoints.map(\.key) == ["CUSTOM", "DATABASE_URL", "HTTP", "Z_REDIS"])
        #expect(endpoints.map(\.host) == ["localhost", "127.0.0.1", "localhost", "127.0.0.1"])
        #expect(endpoints.map(\.port) == [65535, 55439, 8080, 6380])
        #expect(EnvironmentProbe.endpoints(in: [:]).isEmpty)
    }
    @Test func holdNamesFirstKeyAndAddressWithoutCredentials() throws {
        let endpoints = EnvironmentProbe.endpoints(in: [
            "Z_REDIS": "redis://localhost:6380",
            "DATABASE_URL": "postgres://user:probe-secret@127.0.0.1:55439/db"
        ])
        #expect(EnvironmentProbe.hold([]) == nil)
        let single = try #require(EnvironmentProbe.hold(Array(endpoints.prefix(1))))
        let multiple = try #require(EnvironmentProbe.hold(Array(endpoints.reversed())))
        for text in [single, multiple] {
            #expect(text.contains("DATABASE_URL"))
            #expect(text.contains("127.0.0.1:55439"))
            #expect(!text.contains("probe-secret"))
            #expect(!text.contains("user"))
            #expect(text.utf8.allSatisfy { $0 < 128 })
        }
        #expect(multiple.contains("1 more"))
    }
    @Test func listeningSocketIsReachable() async throws {
        let socket = try ProbeAcceptanceSocket()
        defer { socket.close() }
        try socket.listen()
        let endpoints = EnvironmentProbe.endpoints(in: ["SERVICE": "tcp://127.0.0.1:\(socket.port)"])
        #expect(endpoints.count == 1)
        let failed = await EnvironmentProbe.unreachable(endpoints, timeout: .seconds(1))
        #expect(failed.isEmpty)
    }
    @Test func closedSocketIsUnreachable() async throws {
        let socket = try ProbeAcceptanceSocket()
        socket.close()
        let endpoints = EnvironmentProbe.endpoints(in: ["SERVICE": "tcp://127.0.0.1:\(socket.port)"])
        #expect(endpoints.count == 1)
        let failed = await EnvironmentProbe.unreachable(endpoints, timeout: .seconds(1))
        #expect(failed == endpoints)
    }
    @Test func anIPv6LiteralResolvesBareAndShowsInBrackets() {
        let endpoints = EnvironmentProbe.endpoints(in: ["SERVICE": "tcp://[::1]:5432"])
        #expect(endpoints.map(\.host) == ["::1"])
        #expect(EnvironmentProbe.hold(endpoints)?.contains("[::1]:5432") == true)
    }
    /// An address that swallows packets (a test network, never routed) is unreachable at the
    /// deadline, and the deadline bounds the wait: a stalled probe never stalls the tick.
    @Test func aSwallowedConnectSettlesAtTheDeadline() async {
        let endpoints = EnvironmentProbe.endpoints(in: ["SERVICE": "tcp://192.0.2.1:9"])
        let clock = ContinuousClock()
        let started = clock.now
        let failed = await EnvironmentProbe.unreachable(endpoints, timeout: .milliseconds(300))
        #expect(failed == endpoints)
        #expect(clock.now - started < .seconds(2))
    }
    @Test func unresolvableNameFailsClosed() async {
        let endpoints = EnvironmentProbe.endpoints(in: ["SERVICE": "tcp://nothing.invalid:5432"])
        #expect(endpoints.count == 1)
        let failed = await EnvironmentProbe.unreachable(endpoints, timeout: .seconds(5))
        #expect(failed == endpoints)
    }
}
@Suite(ProcessBound())
struct EnvironmentProbeEngineAcceptanceTests {
    @Test func pressedPickWaitsForServiceAndRecoversOnSameEngine() async throws {
        let closed = try ProbeAcceptanceSocket()
        let port = closed.port
        closed.close()
        let f = try await ProbeAcceptanceFixture.make(port: port)
        defer { f.remove() }
        let engine = try f.engine()
        let pick = Engine.pick(repo: f.repo, item: "pr-7")
        await engine.runNext(repo: f.repo, item: "pr-7", pressed: true)
        let held = await engine.tick()
        #expect(held.problem == nil)
        let reason = try #require(held.outages[f.repo.lowercased()])
        #expect(reason.contains("DATABASE_URL"))
        #expect(reason.contains("127.0.0.1:\(port)"))
        #expect(!reason.contains("probe-secret"))
        #expect(held.next.contains(pick))
        #expect(held.waiting[pick] == reason)
        #expect(held.jobs.isEmpty)
        let listening = try ProbeAcceptanceSocket(port: port)
        defer { listening.close() }
        try listening.listen()
        try await f.observe(engine, expected: "1")
    }
}
private final class ProbeAcceptanceSocket {
    private var descriptor: Int32
    let port: Int
    init(port: Int = 0) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0, "Create loopback socket")
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { Darwin.close(fd); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { Darwin.close(fd); throw POSIXError(.EINVAL) }
        descriptor = fd
        self.port = Int(UInt16(bigEndian: address.sin_port))
    }
    func listen() throws { try #require(Darwin.listen(descriptor, 32) == 0, "Listen on loopback") }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    deinit { close() }
}
private struct ProbeAcceptanceFixture {
    let root: URL
    let home: BtonHome
    let head: String
    let move: String
    let repo = "synthetic/project"
    var store: JobStore { get throws { try JobStore(home: home) } }
    var key: JobKey { JobKey(repo: repo, item: "pr-7", move: move, head: head) }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func read(_ name: String) throws -> String { try String(contentsOf: file(name), encoding: .utf8) }
    static func make(port: Int) async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("environment-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let remote = root.appendingPathComponent("origin.git").path
            let clone = root.appendingPathComponent("clone").path
            let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
            try home.prepare()
            let bare = home.url.appendingPathComponent("leases.git").path
            for args in [["init", "--bare", "--initial-branch=main", remote],
                ["clone", remote, clone],
                ["-C", clone, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                 "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Synthetic"],
                ["-C", clone, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"],
                ["init", "--bare", bare],
                ["-C", bare, "hash-object", "-w", "-t", "tree", "/dev/null"],
                ["-C", bare, "config", "url.\(remote).insteadOf", "https://github.com/synthetic/project.git"]] {
                let result = try await ProcessRunner().run("/usr/bin/git", args,
                    environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
                try #require(result.status == 0, "Local git setup: \(result.stderr)")
            }
            let result = try await ProcessRunner().run("/usr/bin/git", ["-C", clone, "rev-parse", "HEAD"], timeout: .seconds(10))
            try #require(result.status == 0)
            let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let move = "fix"
            let f = Self(root: root, home: home, head: head, move: move)
            // Observe each check, then hold the job while its saved environment still exists.
            let check1 = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/check-1\"; while [ ! -f \"$OBSERVE/release\" ]; do sleep 0.02; done; [ ! -f \"$OBSERVE/fail\" ]"]
            let check2 = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/check-2\""]
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": [String: String](), "fixed": "Fixed:",
                "moves": [["move": move, "when": ["no_review_or_response_newer"], "who": "author"]],
                "dispatch": ["fix": ["agent": "synthetic", "prompt": "Fix"]],
                "checks": ["beforeSession": [check1, check2], "beforeMerge": [check1, check2]]]
            try JSONSerialization.data(withJSONObject: flow).write(to: f.file("flow"))
            // A small real process stands in for the configured agent.
            let agent = ["/bin/sh", "-c", "printf '%s' \"${BTON_PRESSED-absent}\" > \"$OBSERVE/agent\""]
            var watched = WatchedRepo(slug: f.repo, path: clone)
            watched.startMoves = false
            watched.environment = ["OBSERVE": root.path, "DATABASE_URL": "postgres://user:probe-secret@127.0.0.1:\(port)/db"]
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 2,
                agents: ["synthetic": AgentTemplate(argv: agent)], schedules: []).save(to: home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: home)
            let script = """
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            if [ "$1" = pr ] && [ "$2" = view ]; then
              echo '{"headRefOid":"\(head)","state":"OPEN"}'; exit 0
            fi
            if [ "$1" != api ]; then
              if [ "$2" = list ]; then echo '[]'; fi
              exit 0
            fi
            case "$2" in
              repos/synthetic/project/contents/.bton/flow.json) cat flow ;;
              graphql)
                cat <<'JSON'
            {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":7,"title":"Synthetic","url":"https://example.invalid/pr/7","isDraft":false,"headRefOid":"\(head)","headRefName":"feature","baseRefName":"main","body":"","updatedAt":"2026-10-19T12:00:00Z","mergeable":"MERGEABLE","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}
            JSON
                ;;
              list) echo '[]' ;;
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else echo 'HTTP 404' >&2; exit 1; fi ;;
              repos/synthetic/project/git/commits/*)
                sha="${2##*/}"
                message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "$sha")
                message=${message//\\\\/\\\\\\\\}
                message=${message//\\\"/\\\\\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """
            try script.write(to: f.file("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.file("gh").path)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: { _ in })
    }
    func wait(_ condition: () throws -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(try condition(), "Timed out waiting for the real job boundary")
    }
    func observe(_ engine: Engine, expected: String) async throws {
        let snapshot = await engine.tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.outages.isEmpty)
        let job = try #require(snapshot.jobs.first { $0.key == key })
        defer { try? Data().write(to: file("release")) }
        try await wait { FileManager.default.fileExists(atPath: file("check-1").path) }
        #expect(try read("check-1") == expected)
        try Data().write(to: file("release"))
        try await wait { try store.all().contains { $0.id == job.id && $0.status != .running } }
        let ended = try #require(try store.all().first { $0.id == job.id })
        #expect(ended.status == .succeeded)
        // BTON_PRESSED reaches the checks, never the agent (PressedAcceptanceTests, the fix move).
        #expect(try read("agent") == "absent")
    }
}
