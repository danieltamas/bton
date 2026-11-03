@testable import BtonCore
import Foundation
import Testing

private enum FlakesFixture {
    static let now = WatchdogFixture.now
    static func pr(head: String = "same-head", checks: [CheckResult]) -> PullRequest {
        var pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: head, headRef: "feature", baseRef: "main", body: "", isDraft: false,
            labels: [], assignees: [], comments: [], updatedAt: now)
        pr.checks = checks
        return pr
    }
    static func flake(_ check: String = "gate", head: String = "same-head", age: TimeInterval = 0,
                      repo: String = "synthetic/project") -> Flake {
        Flake(repo: repo, check: check, number: 7, head: head, at: now.addingTimeInterval(-age))
    }
    // The spec does not name a collection initializer or a JSON envelope. These persistence
    // cases use a JSON array of Flake records in flakes.json; clarify if a wrapper is intended.
    static func store(_ records: [Flake], home: BtonHome) throws -> FlakeStore {
        try FileManager.default.createDirectory(at: home.url, withIntermediateDirectories: true)
        try JSONEncoder().encode(records).write(to: home.url.appendingPathComponent("flakes.json"))
        return FlakeStore.load(home: home)
    }
    static func home() -> BtonHome {
        BtonHome(environment: ["BTON_HOME": FileManager.default.temporaryDirectory
            .appendingPathComponent("flakes-\(UUID())").path])
    }
}

@Suite(ProcessBound())
struct FlakesAcceptanceTests {
    @Test(arguments: [
        (CheckResult.State.failure, CheckResult.State.success, "same-head", true),
        (.success, .failure, "same-head", false), (.failure, .success, "new-head", false),
        (.pending, .success, "same-head", false)
    ])
    func onlyFailureToSuccessOnTheSameHeadIsAFlake(before: CheckResult.State, after: CheckResult.State,
                                                   head: String, flips: Bool) {
        let records = Flakes.flips(previous: ["same-head": ["gate": before]],
            pullRequests: [FlakesFixture.pr(head: head, checks: [.init(name: "gate", state: after)])],
            repo: "synthetic/project", now: FlakesFixture.now)
        #expect(records == (flips ? [FlakesFixture.flake()] : []))
    }

    @Test func checkMissingFromPreviousTickDoesNotFlipAndStatesRetainHeadAndName() {
        let pr = FlakesFixture.pr(checks: [.init(name: "gate", state: .success), .init(name: "build", state: .failure)])
        #expect(Flakes.flips(previous: ["same-head": [:]], pullRequests: [pr],
            repo: pr.repo, now: FlakesFixture.now).isEmpty)
        #expect(Flakes.states([pr]) == ["same-head": ["gate": .success, "build": .failure]])
    }

    @Test func knownCountsDistinctHeadsOfThisRepoWithinFourteenDays() throws {
        let home = FlakesFixture.home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let store = try FlakesFixture.store([FlakesFixture.flake(), FlakesFixture.flake(),
            FlakesFixture.flake(head: "second"), FlakesFixture.flake(head: "old", age: 14 * 86400 + 1),
            FlakesFixture.flake(head: "other", repo: "other/repo"), FlakesFixture.flake("single")], home: home)
        let known = Flakes.known(store, repo: "synthetic/project", now: FlakesFixture.now)
        #expect(known == ["gate": 2, "single": 1])
    }

    @Test func labelReplacesDisallowedCharactersAndCutsNameToFortyThreeCharacters() {
        #expect(Flakes.label(for: "Gate: macOS (arm64)/test_1.swift") == "flaky:Gate- macOS -arm64-/test_1.swift")
        #expect(Flakes.label(for: String(repeating: "x", count: 60)) == "flaky:" + String(repeating: "x", count: 43))
    }

    @Test func adviceNamesOnlyFlakyRedChecksAndOtherwiseIsAbsent() {
        #expect(Flakes.line(redChecks: ["gate", "other", "single"], known: ["gate": 2, "other": 3, "single": 1, "green": 9])
            == "Check gate turned red then green on the same commit 2 times in 14 days (and other, 3): rerun the failed run before changing code (`gh run rerun <id> --failed`); change code only for a failure you reproduce.")
        #expect(Flakes.line(redChecks: ["single", "unknown"], known: ["single": 1, "green": 3]) == nil)
        #expect(Flakes.line(redChecks: [], known: ["gate": 2]) == nil)
    }

    @Test func storeSurvivesSaveAndLoadAndMissingOrUnreadableFileLoadsEmpty() throws {
        let home = FlakesFixture.home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        #expect(Flakes.known(FlakeStore.load(home: home), repo: "synthetic/project", now: FlakesFixture.now).isEmpty)
        let store = try FlakesFixture.store([FlakesFixture.flake(), FlakesFixture.flake(head: "second")], home: home)
        try store.save(home: home)
        #expect(Flakes.known(FlakeStore.load(home: home), repo: "synthetic/project", now: FlakesFixture.now) == ["gate": 2])
        try Data("not JSON".utf8).write(to: home.url.appendingPathComponent("flakes.json"))
        #expect(Flakes.known(FlakeStore.load(home: home), repo: "synthetic/project", now: FlakesFixture.now).isEmpty)
    }

    @Test func pruningKeepsThirtyDaysAndNewestFiveHundredRecords() throws {
        let home = FlakesFixture.home()
        defer { try? FileManager.default.removeItem(at: home.url) }
        let records = (0..<501).map { FlakesFixture.flake("check-\($0)", head: "head-\($0)", age: Double($0)) }
            + [FlakesFixture.flake("expired", age: 30 * 86400 + 1), FlakesFixture.flake("retained", age: 20 * 86400)]
        let pruned = try FlakesFixture.store(records.reversed(), home: home).pruned(now: FlakesFixture.now)
        try pruned.save(home: home)
        let saved = try JSONDecoder().decode([Flake].self, from: Data(contentsOf: home.url.appendingPathComponent("flakes.json")))
        #expect(saved.map(\.check) == (0..<500).map { "check-\($0)" })
        let aged = try FlakesFixture.store([FlakesFixture.flake("retained", age: 20 * 86400),
            FlakesFixture.flake("expired", age: 30 * 86400 + 1)], home: home).pruned(now: FlakesFixture.now)
        try aged.save(home: home)
        #expect(try JSONDecoder().decode([Flake].self, from: Data(contentsOf: home.url.appendingPathComponent("flakes.json")))
            .map(\.check) == ["retained"])
    }
}
