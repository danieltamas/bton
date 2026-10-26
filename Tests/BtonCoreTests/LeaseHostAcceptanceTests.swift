@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct LeaseHostAcceptanceTests {
    @Test func defaultHostMatchesBonjourNameAcrossRepeatedCalls() async throws {
        let output = try await ProcessRunner().run("/usr/sbin/scutil", ["--get", "LocalHostName"],
                                                   timeout: .seconds(20))
        try #require(output.status == 0, "scutil: \(output.stderr)")
        let localHostName = String(decoding: output.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(!localHostName.isEmpty)
        let expected = localHostName + ".local"
        for _ in 0..<10 {
            #expect(LeaseStore.thisMac == expected)
        }
    }

    @Test func separatelyConstructedDefaultStoresRecoverAndReleaseSameJob() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = try store(fixture, homeName: "claim")
        let job = UUID()
        let lease = try RetryLeaseFixture.claimed(await first.claim(fixture.item, in: fixture.repo, job: job))
        #expect(lease.record.host == LeaseStore.thisMac)

        let second = try store(fixture, homeName: "release")
        let recovered = try await second.current(fixture.item, in: fixture.repo, job: job)
        #expect(recovered == lease)
        try await second.release(recovered)
        guard case let .free(record) = try await first.state(of: fixture.item, in: fixture.repo) else {
            Issue.record("The second store must release the first store's lease")
            return
        }
        #expect(record.job == job)
        #expect(record.host == lease.record.host)
        #expect(record.released)
    }

    @Test func sameHolderOnAnotherHostCannotRecoverLeaseForRelease() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try store(fixture, homeName: "owner")
        let lease = try RetryLeaseFixture.claimed(await owner.claim(fixture.item, in: fixture.repo))
        let remote = fixture.root.appendingPathComponent("origin.git").path
        let otherMac = try LeaseStore(
            home: BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("other-mac").path]),
            holder: "same-login", host: lease.record.host + ".other-mac",
            github: GitHubClient(ghPath: fixture.root.appendingPathComponent("gh").path),
            remoteURL: { _ in remote })
        await #expect(throws: LeaseError.notHolder) {
            let recovered = try await otherMac.current(fixture.item, in: fixture.repo, job: lease.record.job)
            try await otherMac.release(recovered)
        }
        #expect(try await owner.current(fixture.item, in: fixture.repo, job: lease.record.job) == lease)
        #expect(try await owner.state(of: fixture.item, in: fixture.repo) == .held(lease.record))
    }

    @Test func savedHostSurvivesRenameAndSecondStoreReleasesLease() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let home = BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("saved").path])
        try home.prepare()
        let saved = LeaseStore.thisMac + ".before-rename"
        let file = home.url.appendingPathComponent("host")
        try (saved + "\n").write(to: file, atomically: true, encoding: .utf8)
        let first = try store(fixture, homeName: "saved")
        #expect(first.host == saved)
        let lease = try RetryLeaseFixture.claimed(await first.claim(fixture.item, in: fixture.repo))
        #expect(lease.record.host == saved)
        let second = try store(fixture, homeName: "saved")
        #expect(second.host == saved)
        let recovered = try await second.current(fixture.item, in: fixture.repo, job: lease.record.job)
        try await second.release(recovered)
        guard case let .free(record) = try await first.state(of: fixture.item, in: fixture.repo) else {
            Issue.record("The saved host must allow release after a rename")
            return
        }
        #expect(record.released)
        #expect(record.host == saved)
        #expect(try String(contentsOf: file, encoding: .utf8) == saved + "\n")
    }

    @Test func firstDefaultStorePersistsHostForSecondStore() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let home = BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("fresh").path])
        let file = home.url.appendingPathComponent("host")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let expected = LeaseStore.thisMac
        let first = try store(fixture, homeName: "fresh")
        #expect(first.host == expected)
        #expect(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        let second = try store(fixture, homeName: "fresh")
        #expect(second.host == first.host)
        #expect(try LeaseStore.host(in: home) == expected)
    }

    @Test func concurrentFirstHostCallsAgreeAndLeaveOneFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-host-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("host").path))
        let expected = LeaseStore.thisMac
        let names = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<16 { group.addTask { try LeaseStore.host(in: home) } }
            var names: [String] = []
            for try await name in group { names.append(name) }
            return names
        }
        #expect(names.count == 16)
        #expect(Set(names) == [expected])
        #expect(try String(contentsOf: root.appendingPathComponent("host"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == expected)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
        #expect(files.map(\.lastPathComponent) == ["host"])
    }

    @Test func anyHostOnlyRelaxesHostAndStillRequiresHolderJobAndUnreleasedLease() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try fixture.store("owner")
        let lease = try RetryLeaseFixture.claimed(await owner.claim(fixture.item, in: fixture.repo))
        let remote = fixture.root.appendingPathComponent("origin.git").path
        let github = GitHubClient(ghPath: fixture.root.appendingPathComponent("gh").path)
        let home = BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("renamed").path])
        let renamed = try LeaseStore(home: home, holder: "owner", host: "renamed.local",
                                    github: github, remoteURL: { _ in remote })
        #expect(try await renamed.current(fixture.item, in: fixture.repo, job: lease.record.job, anyHost: true) == lease)
        await #expect(throws: LeaseError.notHolder) {
            try await renamed.current(fixture.item, in: fixture.repo, job: lease.record.job, anyHost: false)
        }
        let other = try LeaseStore(home: home, holder: "someone-else", host: "renamed.local",
                                  github: github, remoteURL: { _ in remote })
        for anyHost in [false, true] {
            await #expect(throws: LeaseError.notHolder) {
                try await other.current(fixture.item, in: fixture.repo, job: lease.record.job, anyHost: anyHost)
            }
            await #expect(throws: LeaseError.notHolder) {
                try await renamed.current(fixture.item, in: fixture.repo, job: UUID(), anyHost: anyHost)
            }
        }
        try await owner.release(lease)
        await #expect(throws: LeaseError.notHolder) {
            try await renamed.current(fixture.item, in: fixture.repo, job: lease.record.job, anyHost: true)
        }
    }

    @Test func dispatcherAdoptsAndRenewsRunningJobWithOldHost() async throws {
        let fixture = try await RetryLeaseFixture.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let old = try fixture.store("owner")
        let id = UUID()
        let lease = try RetryLeaseFixture.claimed(await old.claim(fixture.item, in: fixture.repo, job: id))
        let remote = fixture.root.appendingPathComponent("origin.git").path
        let home = BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent("restart").path])
        let github = GitHubClient(ghPath: fixture.root.appendingPathComponent("gh").path)
        let leases = try LeaseStore(home: home, holder: "owner", github: github, remoteURL: { _ in remote })
        try #require(leases.host != lease.record.host)
        let jobs = try JobStore(home: home)
        let process = Process()
        let (exits, exited) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { _ in exited.finish() }
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let job = Job(id: id, key: JobKey(repo: fixture.repo, item: fixture.item.description, move: "fix", head: "head"),
                      agent: nil, pid: process.processIdentifier, startedAt: .now, status: .running)
        try jobs.save(job)
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: jobs, log: { _ in })
        await dispatcher.adopt()
        let adopted = try #require(jobs.all().first { $0.id == id })
        #expect(adopted.status == .running)
        #expect(adopted.detail == nil)
        #expect(process.isRunning)
        let renewed = try await leases.current(fixture.item, in: fixture.repo, job: id, anyHost: true)
        #expect(renewed.sha != lease.sha)
        #expect(renewed.record.expires > lease.record.expires)
        #expect(renewed.record.job == id)
        process.terminate()
        for await _ in exits {}
        await dispatcher.stop(id)
        for _ in 0..<200 {
            if jobs.all().first(where: { $0.id == id })?.status != .running { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Adopted job did not finish before cleanup")
    }

    private func store(_ fixture: RetryLeaseFixture, homeName: String) throws -> LeaseStore {
        let remote = fixture.root.appendingPathComponent("origin.git").path
        return try LeaseStore(
            home: BtonHome(environment: ["BTON_HOME": fixture.root.appendingPathComponent(homeName).path]),
            holder: "same-login", github: GitHubClient(ghPath: fixture.root.appendingPathComponent("gh").path),
            remoteURL: { _ in remote })
    }
}
