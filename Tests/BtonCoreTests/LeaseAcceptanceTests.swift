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
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-lease-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func store(homeName: String = UUID().uuidString, ttl: Duration = .seconds(900),
               remoteURL: @escaping @Sendable (String) -> String = { "https://github.com/\($0).git" }) throws -> LeaseStore {
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(homeName).path],
                            homeDirectory: root)
        return try LeaseStore(home: home, holder: "bton-test", ttl: ttl,
                              github: GitHubClient(), remoteURL: remoteURL)
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

// Swift defer cannot await; keep the async equivalent around every test body.
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

private func concurrentClaims(_ stores: [LeaseStore], fixture: LeaseFixture) async -> [ClaimResult] {
    await withTaskGroup(of: ClaimResult.self, returning: [ClaimResult].self) { group in
        for store in stores {
            group.addTask {
                // A thrown claim is fail-closed: it holds no lease.
                do { return try await store.claim(fixture.item, in: fixture.repo) }
                catch { return .notClaimed(holder: nil) }
            }
        }
        var results: [ClaimResult] = []
        for await result in group { results.append(result) }
        return results
    }
}

private func winners(_ results: [ClaimResult]) -> [Lease] {
    results.compactMap { result in
        if case let .claimed(lease) = result { return lease }
        return nil
    }
}

private func expectHeld(_ store: LeaseStore, fixture: LeaseFixture, job: UUID) async throws {
    let state = try await store.state(of: fixture.item, in: fixture.repo)
    guard case let .held(record) = state else {
        Issue.record("Expected a held lease, got \(state)")
        return
    }
    #expect(record.job == job)
    #expect(!record.released)
}

@Suite(ProcessBound(), .serialized, .enabled(if: ProcessInfo.processInfo.environment["BTON_SANDBOX"] != nil))
struct LeaseAcceptanceTests {
    // Spike regression: independent bare repos must race through GitHub's custom-ref CAS.
    @Test(.timeLimit(.minutes(10)))
    func twentyIndependentClaimsHaveExactlyOneWinner() async throws {
        try await withLeaseFixture { fixture in
            let stores = try (0..<20).map { _ in try fixture.store() }
            let results = await concurrentClaims(stores, fixture: fixture)
            #expect(results.count == 20)
            let leases = winners(results)
            #expect(leases.count == 1)
            let winner = try #require(leases.first)
            #expect(winner.repo == fixture.repo)
            #expect(winner.item == fixture.item)
            try await expectHeld(fixture.store(), fixture: fixture, job: winner.record.job)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func nonHolderCannotRecoverLeaseAndStaleRenewalLoses() async throws {
        try await withLeaseFixture { fixture in
            let a = try fixture.store(), b = try fixture.store()
            let original = try claimedLease(try await a.claim(fixture.item, in: fixture.repo))
            await expectLeaseError(.notHolder) {
                _ = try await b.current(fixture.item, in: fixture.repo, job: UUID())
            }
            let current = try await a.current(fixture.item, in: fixture.repo, job: original.record.job)
            #expect(current == original)
            // Ensure ISO 8601 second precision cannot hide the new expiration.
            try await Task.sleep(for: .seconds(1.1))
            let renewed = try await a.renew(original)
            #expect(renewed.sha != original.sha)
            #expect(renewed.record.expires > original.record.expires)
            #expect(renewed.record.job == original.record.job)
            await expectLeaseError(.lost) { _ = try await a.renew(original) }
            try await expectHeld(b, fixture: fixture, job: original.record.job)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func expiredLeaseHasExactlyOneTakeover() async throws {
        try await withLeaseFixture { fixture in
            let a = try fixture.store(ttl: .seconds(2))
            let original = try claimedLease(try await a.claim(fixture.item, in: fixture.repo))
            try await Task.sleep(for: .seconds(4))
            let stores = try [fixture.store(), fixture.store()]
            let results = await concurrentClaims(stores, fixture: fixture)
            let leases = winners(results)
            #expect(results.count == 2)
            #expect(leases.count == 1)
            let winner = try #require(leases.first)
            #expect(winner.record.job != original.record.job)
            await expectLeaseError(.lost) { _ = try await a.renew(original) }
            try await expectHeld(fixture.store(), fixture: fixture, job: winner.record.job)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func lateReleaseCannotOverwriteReleasedLeaseTakeover() async throws {
        try await withLeaseFixture { fixture in
            let a = try fixture.store()
            let original = try claimedLease(try await a.claim(fixture.item, in: fixture.repo))
            try await a.release(original)
            let state = try await a.state(of: fixture.item, in: fixture.repo)
            if case let .free(record) = state {
                #expect(record.released)
                #expect(record.job == original.record.job)
            } else {
                Issue.record("Release must leave a free, released record")
            }
            await expectLeaseError(.notHolder) {
                _ = try await a.current(fixture.item, in: fixture.repo, job: original.record.job)
            }
            let results = await concurrentClaims(try [fixture.store(), fixture.store()], fixture: fixture)
            let leases = winners(results)
            #expect(results.count == 2)
            #expect(leases.count == 1)
            let winner = try #require(leases.first)
            #expect(winner.record.job != original.record.job)
            await expectLeaseError(.lost) { try await a.release(original) }
            try await expectHeld(fixture.store(), fixture: fixture, job: winner.record.job)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func networkFailureNeverReportsClaimed() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store(remoteURL: { _ in "https://github.invalid/x/y.git" })
            do {
                let result = try await store.claim(fixture.item, in: fixture.repo)
                if case .claimed = result { Issue.record("A failed push must never report a held lease") }
            } catch {
                // Throwing is an allowed fail-closed outcome.
            }
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func sharedHomeLocalLockNeverAllowsTwoWinners() async throws {
        try await withLeaseFixture { fixture in
            let stores = try [fixture.store(homeName: "shared"), fixture.store(homeName: "shared")]
            let results = await concurrentClaims(stores, fixture: fixture)
            #expect(results.count == 2)
            #expect(winners(results).count <= 1)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func neverClaimedItemIsAbsentAndHasNoCurrentHolder() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store()
            #expect(try await store.state(of: fixture.item, in: fixture.repo) == .absent)
            await expectLeaseError(.notHolder) {
                _ = try await store.current(fixture.item, in: fixture.repo, job: UUID())
            }
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func secondClaimWithNewJobIsNotAnotherSuccess() async throws {
        try await withLeaseFixture { fixture in
            let store = try fixture.store()
            let original = try claimedLease(try await store.claim(fixture.item, in: fixture.repo))
            let newJob = UUID()
            let result = try await store.claim(fixture.item, in: fixture.repo, job: newJob)
            guard case let .notClaimed(holder) = result else {
                Issue.record("Claiming a held item again must not succeed")
                return
            }
            let record = try #require(holder)
            #expect(record.job == original.record.job)
            #expect(record.job != newJob)
            try await expectHeld(fixture.store(), fixture: fixture, job: original.record.job)
        }
    }
}

@Suite(ProcessBound())
struct LeaseValueAcceptanceTests {
    @Test(.timeLimit(.minutes(10)))
    func leaseItemParsing() throws {
        for (text, kind, number) in [("pr-304", "pr", 304), ("issue-212", "issue", 212)] {
            let item = try #require(LeaseItem(text))
            #expect(item.kind == kind)
            #expect(item.number == number)
            #expect(item.description == text)
            #expect(item.ref == "refs/bton/leases/\(text)")
        }
        for text in ["PR-1", "pr-", "pr-x", "../x", ""] {
            #expect(LeaseItem(text) == nil, "Invalid lease item: \(text)")
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func leaseRecordISO8601RoundTripAndFreeBoundaries() throws {
        let job = UUID(uuidString: "EA0E1600-364D-4CEF-8F65-8DBBC43D0FEF")!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let expires = try #require(ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
        for released in [false, true] {
            let json = """
            {"holder":"bton-test","host":"test-mac","job":"\(job.uuidString)","expires":"2026-10-19T12:00:00Z","released":\(released)}
            """
            let record = try decoder.decode(LeaseRecord.self, from: Data(json.utf8))
            #expect(record.holder == "bton-test")
            #expect(record.host == "test-mac")
            #expect(record.job == job)
            #expect(record.expires == expires)
            #expect(record.released == released)
            #expect(record.isFree(at: expires.addingTimeInterval(-1)) == released)
            #expect(record.isFree(at: expires))
            #expect(record.isFree(at: expires.addingTimeInterval(1)))
            let encoded = try encoder.encode(record)
            #expect(try decoder.decode(LeaseRecord.self, from: encoded) == record)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            let dateString = try #require(object["expires"] as? String)
            #expect(ISO8601DateFormatter().date(from: dateString) == expires)
        }
    }
}
