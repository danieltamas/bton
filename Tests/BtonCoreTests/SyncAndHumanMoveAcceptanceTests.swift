@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct SyncAndHumanMoveAcceptanceTests {
    @Test func completionLabelsExcludeReferencesInEarlierAndLaterUnmatchedRules() throws {
        let flow = try SyncHumanFixture.flow("""
        [{"move":"earlier","when":["label:ignored","draft"],"who":"author"},
         {"move":"decide","when":["label:Needs Human","label:ignored","label:turn:lead"],"who":"author"},
         {"move":"later","when":["label:turn:lead","draft"],"who":"author"}]
        """)
        let move = try #require(FlowEngine.move(for: SyncHumanFixture.pr(), flow: flow))
        #expect(move.name == "decide")
        #expect(move.labels == ["Needs Human"])
    }

    @Test func completionLabelsExcludeReferencesInLaterMatchingRule() throws {
        let flow = try SyncHumanFixture.flow("""
        [{"move":"decide","when":["label:Needs Human","label:ignored","label:turn:lead"],"who":"author"},
         {"move":"review","when":["label:ignored"],"who":"author"}]
        """)
        let move = try #require(FlowEngine.move(for: SyncHumanFixture.pr(), flow: flow))
        #expect(move.name == "decide")
        #expect(move.labels == ["Needs Human", "turn:lead"])
    }

    @Test func matchedRuleLabelsPreserveOrderAndVerbatimNames() throws {
        let flow = try SyncHumanFixture.flow("""
        [{"move":"unmatched","when":["label:ignored","draft"],"who":"author"},
         {"move":"human","when":["label:turn:lead","no_review_or_response_newer","label:Needs Human"],"who":"author"},
         {"move":"later","when":["label:ignored"],"who":"author"}]
        """)
        let move = try #require(FlowEngine.move(for: SyncHumanFixture.pr(), flow: flow))
        #expect(move.name == "human")
        #expect(move.labels == ["turn:lead", "Needs Human"])
    }

    @Test func matchedRuleWithoutLabelConditionsHasNoLabels() throws {
        let flow = try SyncHumanFixture.flow("""
        [{"move":"unmatched","when":["label:ignored","draft"],"who":"author"},
         {"move":"human","when":["no_review_or_response_newer"],"who":"author"},
         {"move":"later","when":["label:turn:lead"],"who":"author"}]
        """)
        let move = try #require(FlowEngine.move(for: SyncHumanFixture.pr(), flow: flow))
        #expect(move.name == "human")
        #expect(move.labels.isEmpty)
    }

    @Test func moveInitializerDefaultsLabelsToEmpty() {
        let move = Move(name: "human", owner: "owner", ownerFromRotation: false,
                        tier: "small", hasDispatch: false)
        #expect(move.labels.isEmpty)
    }

    @Test(arguments: ["turn:lead", "Needs Human", "turn:Needs Human"])
    func removeLabelPassesExactArguments(label: String) async throws {
        try await SyncHumanFixture.checkRemoveLabel(label, status: 0)
    }

    @Test func removeLabelThrowsOnNonzeroExit() async throws {
        try await SyncHumanFixture.checkRemoveLabel("turn:Needs Human", status: 23)
    }

    @Test(arguments: [false, true])
    func onReadIncludesEveryRepoAndMatchesReturnedOrder(dispatching: Bool) async throws {
        let fixture = try SyncHumanFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let reads = SyncHumanReads()
        let result = await engine.tick(dispatching: dispatching, onRead: { await reads.append($0) })
        let snapshots = await reads.snapshots
        #expect(snapshots.count == 1)
        let read = try #require(snapshots.first)
        #expect(read.openPullRequests.map(\.id) == ["owner/b#1", "owner/a#1", "owner/a#3"])
        #expect(read.openPullRequests.map(\.id) == result.openPullRequests.map(\.id))
        #expect(Set(read.merged.map(\.id)) == ["owner/a#2", "owner/b#2"])
        #expect(Set(read.flows.keys) == ["owner/a", "owner/b"])
        #expect(read.flows.values.allSatisfy { $0.flow?.base == "main" })
        #expect(read.problem == nil)
        #expect(read.unread.isEmpty)
    }

    @Test(arguments: [false, true])
    func onReadReportsUnreadRepoWithoutHidingReadableRepo(failingRepoFirst: Bool) async throws {
        let fixture = try SyncHumanFixture(failB: true, failingRepoFirst: failingRepoFirst)
        defer { fixture.remove() }
        let reads = SyncHumanReads()
        let engine = try fixture.engine()
        let result = await engine.tick(dispatching: false, onRead: { await reads.append($0) })
        let snapshots = await reads.snapshots
        #expect(snapshots.count == 1)
        let read = try #require(snapshots.first)
        #expect(read.openPullRequests.map(\.id) == ["owner/a#1", "owner/a#3"])
        #expect(read.openPullRequests.map(\.id) == result.openPullRequests.map(\.id))
        #expect(read.merged.map(\.id) == ["owner/a#2"])
        #expect(read.flows["owner/a"]?.flow?.base == "main")
        #expect(read.unread == ["owner/b"])
        #expect(try #require(read.problem).contains("owner/b"))
    }

    @Test func onReadArrivesBeforeActPhaseFailureForMissingCheckout() async throws {
        let fixture = try SyncHumanFixture(missingCheckout: true)
        defer { fixture.remove() }
        // Make dispatcher initialization fail locally, with no lease or remote writes.
        let locks = fixture.home.url.appendingPathComponent("locks")
        try Data().write(to: locks)
        let engine = try fixture.engine()
        let reads = SyncHumanReads()
        let result = await engine.tick(dispatching: true, onRead: { snapshot in
            #expect(snapshot.problem == nil)
            #expect(snapshot.unread.isEmpty)
            #expect(snapshot.openPullRequests.map(\.id) == ["owner/b#1", "owner/a#1", "owner/a#3"])
            #expect(Set(snapshot.merged.map(\.id)) == ["owner/a#2", "owner/b#2"])
            await reads.append(snapshot)
        })
        let snapshots = await reads.snapshots
        #expect(snapshots.count == 1)
        #expect(try #require(result.problem).contains("owner/a"))
        #expect(snapshots.first?.openPullRequests.map(\.id) == result.openPullRequests.map(\.id))
    }

    @Test(arguments: [false, true])
    func mergedQueryFailureDiscardsOpenPRsFromUnreadRepo(failingRepoFirst: Bool) async throws {
        let fixture = try SyncHumanFixture(failBMerged: true, failingRepoFirst: failingRepoFirst)
        defer { fixture.remove() }
        // Prove the open query succeeds and has data before exercising the merged-query failure.
        let open = try await GitHubClient(ghPath: fixture.gh.path).openPullRequests(repo: "owner/b")
        #expect(open.pullRequests.map(\.id) == ["owner/b#1"])
        let reads = SyncHumanReads()
        let engine = try fixture.engine()
        let result = await engine.tick(dispatching: false, onRead: { await reads.append($0) })
        let snapshots = await reads.snapshots
        #expect(snapshots.count == 1)
        let read = try #require(snapshots.first)
        for snapshot in [read, result] {
            #expect(snapshot.unread == ["owner/b"])
            #expect(try #require(snapshot.problem).contains("owner/b"))
            #expect(snapshot.openPullRequests.map(\.id) == ["owner/a#1", "owner/a#3"])
            #expect(snapshot.merged.map(\.id) == ["owner/a#2"])
        }
    }

    @Test func tickWithoutOnReadStillReturnsReadSnapshot() async throws {
        let fixture = try SyncHumanFixture()
        defer { fixture.remove() }
        let engine = try fixture.engine()
        let result = await engine.tick(dispatching: false)
        #expect(result.openPullRequests.map(\.id) == ["owner/b#1", "owner/a#1", "owner/a#3"])
        #expect(Set(result.merged.map(\.id)) == ["owner/a#2", "owner/b#2"])
        #expect(Set(result.flows.keys) == ["owner/a", "owner/b"])
        #expect(result.problem == nil)
        #expect(result.unread.isEmpty)
    }
}

private actor SyncHumanReads {
    var snapshots: [Engine.Snapshot] = []
    func append(_ snapshot: Engine.Snapshot) { snapshots.append(snapshot) }
}

private struct SyncHumanFixture {
    let root: URL
    let home: BtonHome
    let gh: URL

    static func flow(_ moves: String) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: Data(flowJSON(moves).utf8))
    }

    static func flowJSON(_ moves: String = "[]") -> String {
        """
        {"version":1,"base":"main","tier":{"marker":"Tier:","values":["small"],"default":"small"},"reviews":{},"fixed":"Fixed:","moves":\(moves),"dispatch":{}}
        """
    }

    static func pr() -> PullRequest {
        PullRequest(repo: "owner/a", number: 1, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/1")!,
            headSha: "synthetic-head", headRef: "feat/x", baseRef: "main", body: "",
            isDraft: false, labels: ["ignored", "Needs Human", "turn:lead"], assignees: [],
            comments: [], updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    init(failB: Bool = false, failBMerged: Bool = false, failingRepoFirst: Bool = false, missingCheckout: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-sync-human-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path])
        gh = root.appendingPathComponent("gh")
        let repos = failingRepoFirst ? ["owner/b", "owner/a"] : ["owner/a", "owner/b"]
        let missing = root.appendingPathComponent("missing-checkout").path
        #expect(!FileManager.default.fileExists(atPath: missing))
        try BtonConfig(repos: repos.map {
            WatchedRepo(slug: $0, path: missingCheckout && $0 == "owner/a" ? missing : nil)
        }, pollSeconds: 60, maxAgents: 0, agents: [:], schedules: []).save(to: home.configURL)
        // Prevent the act phase from fetching the public price feed.
        try PriceList(models: [:], updatedAt: .now).save(home: home)
        let script = """
        #!/bin/sh
        repo=
        for arg in "$@"; do
            case "$arg" in
                repos/owner/a/*|owner/a|name=a) repo=owner/a ;;
                repos/owner/b/*|owner/b|name=b) repo=owner/b ;;
            esac
        done
        case "$repo" in owner/a|owner/b) ;; *) exit 90 ;; esac
        if [ "\(failB ? "yes" : "no")" = yes ] && [ "$repo" = owner/b ]; then
            echo 'Synthetic read failure for owner/b' >&2
            exit 1
        fi
        case "$1:$2" in
            api:repos/*/contents/.bton/flow.json)
                cat <<'JSON'
        \(Self.flowJSON())
        JSON
                ;;
            api:graphql)
                day=19
                if [ "$repo" = owner/b ]; then day=20; fi
                cat <<JSON
        {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":1,"title":"Synthetic open","url":"https://example.invalid/pr/1","isDraft":false,"headRefOid":"synthetic-open","headRefName":"feat/x","baseRefName":"main","body":"","updatedAt":"2026-10-${day}T12:00:00Z","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}}]}}}}
        JSON
                ;;
            pr:list)
                if [ "\(failBMerged ? "yes" : "no")" = yes ] && [ "$repo" = owner/b ]; then
                    echo 'Synthetic merged read failure for owner/b' >&2
                    exit 1
                fi
                echo '[{"number":2,"title":"Synthetic merged","author":{"login":"owner"},"url":"https://example.invalid/pr/2","mergedAt":"2026-10-19T12:00:00Z","headRefName":"feat/merged","headRefOid":"synthetic-merged"}]'
                ;;
            *) echo 'Unexpected synthetic gh invocation' >&2; exit 91 ;;
        esac
        """
        // Add an older PR before the newer one in the wire response to test sorting within a repo too.
        let older = """
        {"number":3,"title":"Synthetic older","url":"https://example.invalid/pr/3","isDraft":false,"headRefOid":"synthetic-older","headRefName":"feat/older","baseRefName":"main","body":"","updatedAt":"2026-10-18T12:00:00Z","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[]}},
        """
        // Only owner/a has the extra PR; keep the shell substitution as a single JSON fragment.
        let final = script.replacingOccurrences(of: "day=19", with: "extra='\(older)'\n        day=19")
            .replacingOccurrences(of: "then day=20; fi", with: "then day=20; extra=; fi")
            .replacingOccurrences(of: "\"nodes\":[{\"number\":1", with: "\"nodes\":[$extra{\"number\":1")
        try Self.writeScript(final, to: gh)
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: gh.path), log: { _ in })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    static func writeScript(_ script: String, to url: URL) throws {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func checkRemoveLabel(_ label: String, status: Int) async throws {
        let fixture = try Self()
        defer { fixture.remove() }
        let arguments = fixture.root.appendingPathComponent("arguments")
        try writeScript("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(arguments.path)'
        exit \(status)
        """, to: fixture.gh)
        var threw = false
        do {
            try await GitHubClient(ghPath: fixture.gh.path).removeLabel(label, repo: "owner/a", number: 17)
        } catch { threw = true }
        #expect(threw == (status != 0))
        let recorded = try String(contentsOf: arguments, encoding: .utf8)
        #expect(recorded == ["pr", "edit", "17", "--repo", "owner/a", "--remove-label", label]
            .joined(separator: "\n") + "\n")
    }
}
