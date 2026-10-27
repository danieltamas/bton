@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FeatureReportAcceptanceTests {
    @Test func unreadableRegistryNeverBlocksTheRepo() async throws {
        let f = try await StartMovesFixture.make(startMoves: true)
        defer { f.remove() }
        let snapshot = try await f.engine().tick()
        #expect(snapshot.problem == nil)
        #expect(snapshot.unread.isEmpty)
        #expect(snapshot.openPullRequests.count == 1)
        let report = try #require(snapshot.features[f.repo])
        #expect(report.problem != nil)
        #expect(snapshot.jobs.map(\.key) == [f.key("fix")])
        try await f.waitForJobs()
    }

    @Test func registryOnTheDefaultBranchIsReported() async throws {
        let f = try await FeatureEngineFixture.make()
        defer { f.base.remove() }
        let snapshot = try await f.base.engine().tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.unread.isEmpty)
        #expect(snapshot.openPullRequests.count == 1)
        let report = try #require(snapshot.features[f.base.repo])
        guard case let .ready(registry) = report.registry else { Issue.record("Expected ready registry"); return }
        #expect(registry.feature("filing-dedupe") != nil)
        #expect(report.repo == f.base.repo)
        #expect(report.standings["filing-dedupe"]?.status == .live)
        #expect(report.hasRelease == false)
        #expect(report.lastRelease == nil)
        #expect(report.readAt != nil)
        #expect(report.problem == nil)
        let calls = try f.calls()
        #expect(calls.contains("repos/synthetic/project/contents/.bton/features.json"))
        #expect(!calls.contains("ref=feature"))
    }

    @Test func factsAreNotReadAgainWithinTenMinutes() async throws {
        let f = try await FeatureEngineFixture.make()
        defer { f.base.remove() }
        let engine = try f.base.engine()
        let first = await engine.tick(dispatching: false)
        let second = await engine.tick(dispatching: false)
        #expect(Engine.factsEvery == 600)
        #expect(first.features[f.base.repo]?.standings["filing-dedupe"]?.status == .live)
        #expect(second.features[f.base.repo]?.standings == first.features[f.base.repo]?.standings)
        #expect(try f.factsCalls() == 1)
    }

    @Test func invalidRegistryIsReportedAsInvalid() async throws {
        let invalid = FeatureAcceptanceData.specExample.replacingOccurrences(of: "\"area\": \"whatsapp-intake\"", with: "\"area\": \"missing\"")
        let f = try await FeatureEngineFixture.make(registry: invalid)
        defer { f.base.remove() }
        let snapshot = try await f.base.engine().tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.openPullRequests.count == 1)
        let report = try #require(snapshot.features[f.base.repo])
        guard case let .invalid(reason) = report.registry else { Issue.record("Expected invalid, never empty"); return }
        #expect(reason.lowercased().contains("area"))
        #expect(try f.factsCalls() == 0)
    }

    @Test func registryChangeRereadsFactsWithinTenMinutes() async throws {
        let f = try await FeatureEngineFixture.make()
        defer { f.base.remove() }
        let engine = try f.base.engine()
        _ = await engine.tick(dispatching: false)
        let changed = FeatureAcceptanceData.specExample.replacingOccurrences(of: "Filing dedupe", with: "Renamed dedupe")
        try changed.write(to: f.base.root.appendingPathComponent("features.json"), atomically: true, encoding: .utf8)
        let second = await engine.tick(dispatching: false)
        guard case let .ready(registry) = second.features[f.base.repo]?.registry else {
            Issue.record("Changed registry must remain ready"); return
        }
        #expect(registry.feature("filing-dedupe")?.name == "Renamed dedupe")
        #expect(try f.factsCalls() == 2)
    }

    @Test func failedFactsReadKeepsLastStanding() async throws {
        let f = try await FeatureEngineFixture.make()
        defer { f.base.remove() }
        let engine = try f.base.engine()
        let first = await engine.tick(dispatching: false)
        let changed = FeatureAcceptanceData.specExample.replacingOccurrences(of: "Filing dedupe", with: "Renamed dedupe")
        try changed.write(to: f.base.root.appendingPathComponent("features.json"), atomically: true, encoding: .utf8)
        try Data().write(to: f.base.root.appendingPathComponent("fail-facts"))
        let failed = await engine.tick(dispatching: false)
        let report = try #require(failed.features[f.base.repo])
        #expect(report.problem != nil)
        #expect(report.standings == first.features[f.base.repo]?.standings)
        #expect(failed.problem == nil)
        #expect(failed.unread.isEmpty)
        #expect(failed.openPullRequests.count == 1)
    }
}

private struct FeatureEngineFixture {
    let base: StartMovesFixture

    static func make(registry: String = FeatureAcceptanceData.specExample) async throws -> Self {
        let base = try await StartMovesFixture.make()
        do {
            // The watched clone is StartMovesFixture.root. Add real local Git facts there.
            try await FeatureHistoryFixture.git(["init", "--initial-branch=main"], in: base.root)
            try await FeatureHistoryFixture.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                "commit", "--allow-empty", "-m", "Released feature"], in: base.root, day: 19)
            let sha = try await FeatureHistoryFixture.git(["rev-parse", "HEAD"], in: base.root)
            try await FeatureHistoryFixture.git(["update-ref", "refs/remotes/origin/main", sha], in: base.root)
            try registry.write(to: base.root.appendingPathComponent("features.json"), atomically: true, encoding: .utf8)
            // Chosen engine payload: both linked PRs merged into main at the clone's HEAD.
            let facts = """
            {"data":{"repository":{
              "n402":{"__typename":"Issue","number":402,"state":"OPEN","createdAt":"2026-10-01T10:00:00Z",
                "labels":{"nodes":[{"name":"stage:ready"}]},"timelineItems":{"nodes":[]}},
              "n428":{"__typename":"PullRequest","number":428,"state":"MERGED","createdAt":"2026-10-10T10:00:00Z",
                "mergedAt":"2026-10-19T12:00:00Z","baseRefName":"main","mergeCommit":{"oid":"\(sha)"}},
              "n419":{"__typename":"PullRequest","number":419,"state":"MERGED","createdAt":"2026-10-09T10:00:00Z",
                "mergedAt":"2026-10-19T12:00:00Z","baseRefName":"main","mergeCommit":{"oid":"\(sha)"}}
            }}}
            """
            let gh = base.root.appendingPathComponent("gh")
            let old = try String(contentsOf: gh, encoding: .utf8)
            // Intercept only the facts query. Leave the existing graphql PR case untouched.
            let cases = """
            case "$2" in
              graphql)
                case "$*" in
                  *issueOrPullRequest*)
                    printf 'facts-query\\n' >> "${0%/*}/gh-calls"
                    test ! -f "${0%/*}/fail-facts" || exit 2
                    cat <<'JSON'
            \(facts)
            JSON
                    exit 0 ;;
                esac ;;
            esac
            case "$2" in
              repos/synthetic/project/contents/.bton/features.json|repos/synthetic/project/contents/.bton/features.json\\?ref=main)
                cat "${0%/*}/features.json"; exit 0 ;;
            esac
            """
            let logged = old.replacingOccurrences(of: "set -eu", with:
                "set -eu\nprintf '%s\\n' \"$*\" >> \"${0%/*}/gh-calls\"")
            try logged.replacingOccurrences(of: "case \"$2\" in", with: cases + "\ncase \"$2\" in")
                .write(to: gh, atomically: true, encoding: .utf8)
            try Data().write(to: base.root.appendingPathComponent("gh-calls"))
            return Self(base: base)
        } catch { base.remove(); throw error }
    }

    func calls() throws -> String {
        try String(contentsOf: base.root.appendingPathComponent("gh-calls"), encoding: .utf8)
    }

    func factsCalls() throws -> Int {
        // Grep the per-query log marker, rather than counting the three aliases in a query.
        try calls().split(separator: "\n").filter { $0 == "facts-query" }.count
    }
}
