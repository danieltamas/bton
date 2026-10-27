import BtonCore
import Foundation
import Testing

private struct LeaseFixture: Sendable {
    let root: URL
    let repo: String
    let item: LeaseItem
    let ghPath: String

    init() throws {
        repo = try #require(ProcessInfo.processInfo.environment["BTON_SANDBOX"])
        item = try #require(LeaseItem("pr-\(Int.random(in: 1_000_000...9_999_999))"))
        ghPath = try #require(["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: FileManager.default.isExecutableFile))
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-lease-regression-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func store(holder: String = "bton-test", host: String = "lease-regression-host") throws -> LeaseStore {
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(UUID().uuidString).path],
                            homeDirectory: root)
        return try LeaseStore(home: home, holder: holder, host: host, github: GitHubClient())
    }

    func cleanup() async {
        // An unstructured detached task also attempts cleanup if the test was cancelled.
        await Task.detached {
            do {
                let result = try await ProcessRunner().run(
                    ghPath, ["api", "-X", "DELETE", "repos/\(repo)/git/refs/bton/leases/\(item)"],
                    timeout: .seconds(20))
                let missing = result.stderr.contains("HTTP 404") || result.stderr.contains("HTTP 422")
                #expect(result.status == 0 || missing, "Lease ref cleanup failed: \(result.stderr)")
            } catch {
                Issue.record("Lease ref cleanup failed: \(error)")
            }
            try? FileManager.default.removeItem(at: root)
        }.value
    }
}

private func withLeaseFixture(_ body: (LeaseFixture) async throws -> Void) async throws {
    let fixture = try LeaseFixture()
    do {
        try await body(fixture)
    } catch {
        await fixture.cleanup()
        throw error
    }
    await fixture.cleanup()
}

private func claimedLease(_ result: ClaimResult) throws -> Lease {
    guard case let .claimed(lease) = result else {
        Issue.record("Fixture claim must win before exercising lease operations")
        throw LeaseError.failed("Fixture claim did not win")
    }
    return lease
}

private func expectLeaseError(_ expected: LeaseError,
                              _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected LeaseError.\(expected)")
    } catch let error as LeaseError {
        #expect(error == expected)
    } catch {
        Issue.record("Expected LeaseError.\(expected), got \(error)")
    }
}

@Suite(ProcessBound(), .serialized, .enabled(if: ProcessInfo.processInfo.environment["BTON_SANDBOX"] != nil))
struct LeaseRegressionTests {
    @Test(.timeLimit(.minutes(10)))
    func concurrentReleaseOfSameLeaseHasExactlyOneSuccess() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store()
            let lease = try claimedLease(try await store.claim(fixture.item, in: fixture.repo))
            let results = try await withThrowingTaskGroup(of: Bool.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            try await store.release(lease)
                            return true
                        } catch LeaseError.lost {
                            return false
                        }
                    }
                }
                var results: [Bool] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(results.count == 2)
            #expect(results.filter { $0 }.count == 1)
            #expect(results.filter { !$0 }.count == 1)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func concurrentRenewOfSameLeaseHasExactlyOneSuccess() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store()
            let lease = try claimedLease(try await store.claim(fixture.item, in: fixture.repo))
            let results = try await withThrowingTaskGroup(of: Lease?.self) { group in
                for _ in 0..<2 {
                    group.addTask {
                        do {
                            return try await store.renew(lease)
                        } catch LeaseError.lost {
                            return nil
                        }
                    }
                }
                var results: [Lease?] = []
                for try await result in group { results.append(result) }
                return results
            }
            #expect(results.count == 2)
            let renewed = results.compactMap { $0 }
            #expect(renewed.count == 1)
            #expect(results.filter { $0 == nil }.count == 1)
            let winner = try #require(renewed.first)
            #expect(winner.record.job == lease.record.job)
            #expect(!winner.record.released)
            let state = try await store.state(of: fixture.item, in: fixture.repo)
            guard case let .held(record) = state else {
                Issue.record("Expected a held lease after renewal, got \(state)")
                return
            }
            #expect(record.job == lease.record.job)
            #expect(!record.released)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func currentRequiresHolderAndHostEvenWithRealJob() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store()
            let lease = try claimedLease(try await store.claim(fixture.item, in: fixture.repo))
            let otherHolder = try fixture.store(holder: "other-bton-test")
            let otherHost = try fixture.store(host: "other-lease-regression-host")
            await expectLeaseError(.notHolder) {
                _ = try await otherHolder.current(fixture.item, in: fixture.repo, job: lease.record.job)
            }
            await expectLeaseError(.notHolder) {
                _ = try await otherHost.current(fixture.item, in: fixture.repo, job: lease.record.job)
            }
            let current = try await store.current(fixture.item, in: fixture.repo, job: lease.record.job)
            #expect(current == lease)
        }
    }
}

@Suite struct LeaseHistoryStartTests {
    @Test func lastStartReadsMinuteHeadsOfOneMove() {
        let record = LeaseRecord(holder: "owner", host: "mac", job: UUID(), expires: .now, released: false,
                                 key: "acme/app#features features@m29880105",
                                 done: ["acme/app#features features@m29880000", "acme/app#nightly nightly@m29880200",
                                        "acme/app#42 review@abc123def456"])
        #expect(record.lastStart(of: "features") == Date(timeIntervalSince1970: 29_880_105 * 60))
        #expect(record.lastStart(of: "features", includingKey: false) == Date(timeIntervalSince1970: 29_880_000 * 60))
        #expect(record.lastStart(of: "nightly") == Date(timeIntervalSince1970: 29_880_200 * 60))
        #expect(record.lastStart(of: "review") == nil)
        #expect(LeaseRecord(holder: "owner", host: "mac", job: UUID(), expires: .now, released: true).lastStart(of: "features") == nil)
    }
}
