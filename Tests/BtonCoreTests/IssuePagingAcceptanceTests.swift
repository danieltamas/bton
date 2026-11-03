@testable import BtonCore
import Foundation
import Testing

enum IssuePagingPayload {
    static let repo = "synthetic/project"

    // Spec-shaped GitHub Issue fields, including fields shared by paging and search.
    static func node(_ number: Int) -> [String: Any] {
        ["__typename": "Issue", "number": number, "title": "Issue \(number)",
         "url": "https://example.invalid/issues/\(number)",
         "createdAt": "2026-10-19T12:00:00Z", "body": "Body \(number)",
         "author": ["login": "teammate"], "authorAssociation": "MEMBER",
         "comments": ["nodes": [[String: Any]]()],
         "labels": ["nodes": [[String: String]]()],
         "assignees": ["nodes": [[String: String]]()]]
    }

    static func page(_ numbers: [Int], next: String? = nil, pageInfo: Bool = true,
                     ready: [Int]? = nil, inProgress: [Int]? = nil) throws -> Data {
        var main: [String: Any] = ["nodes": numbers.map(node)]
        if pageInfo {
            main["pageInfo"] = ["hasNextPage": next != nil, "endCursor": next as Any? ?? NSNull()]
        }
        var repository: [String: Any] = ["issues": main]
        if let ready { repository["ready"] = ["nodes": ready.map(node)] }
        if let inProgress { repository["inProgress"] = ["nodes": inProgress.map(node)] }
        return try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]])
    }
}

@Suite(ProcessBound())
struct IssuePagingAcceptanceTests {
    @Test func anOlderConfigDecodesAndTheInitialConfigOmitsTheRateFloor() throws {
        let data = Data(#"{"repos":[],"pollSeconds":60,"maxAgents":1,"agents":{},"schedules":[]}"#.utf8)
        let config = try JSONDecoder().decode(BtonConfig.self, from: data)
        #expect(config.rateLimitFloor == nil)
        let initial = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(BtonConfig.initial)) as? [String: Any])
        #expect(initial["rateLimitFloor"] == nil)
    }

    @Test(arguments: [0, 450])
    func anExplicitRateFloorDecodes(floor: Int) throws {
        let data = Data("{\"repos\":[],\"pollSeconds\":60,\"maxAgents\":1,\"agents\":{},\"schedules\":[],\"rateLimitFloor\":\(floor)}".utf8)
        #expect(try JSONDecoder().decode(BtonConfig.self, from: data).rateLimitFloor == floor)
    }

    @Test(arguments: [false, true])
    func rateLimitReadsBothQuotasAndUsesTheLaterReset(coreResetsLast: Bool) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try f.rateLimit(core: 5000, graphql: 4900,
                        coreReset: coreResetsLast ? 1_800_000_000 : 1_799_999_000,
                        graphqlReset: coreResetsLast ? 1_799_999_000 : 1_800_000_000)
        let quota = try await GitHubClient(ghPath: f.file("gh").path).rateLimit()
        #expect(quota.core == 5000)
        #expect(quota.graphql == 4900)
        #expect(quota.resetsAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test(arguments: [(120, 4900), (5000, 120)])
    func eitherQuotaBelowTheDefaultFloorHoldsBeforeAnyRepoRead(core: Int, graphql: Int) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try f.rateLimit(core: core, graphql: graphql)
        let store = try JobStore(home: f.home)
        let running = Job(id: UUID(), key: JobKey(repo: IssuePagingPayload.repo, item: "pr-7", move: "review", head: "abc12345"),
                          agent: "claude", startedAt: Date(timeIntervalSince1970: 1_799_990_000), status: .running)
        try store.save(running)
        let engine = try f.engine()
        let snapshot = await engine.tick()
        let problem = try #require(snapshot.problem)
        #expect(problem.hasPrefix("GitHub rate limit: core \(core), graphql \(graphql) left; reading again after "))
        let localTime = DateFormatter()
        localTime.locale = Locale(identifier: "en_US_POSIX")
        localTime.timeZone = .current
        localTime.dateFormat = "HH:mm"
        #expect(problem.contains(localTime.string(from: Date(timeIntervalSince1970: 1_800_000_000))))
        #expect(!FileManager.default.fileExists(atPath: f.file("repo-read").path))
        #expect(snapshot.triage.isEmpty)
        #expect(snapshot.openPullRequests.isEmpty)
        #expect(snapshot.flows.isEmpty)
        #expect(snapshot.jobs.first { $0.id == running.id }?.status == .running)
        #expect(store.all() == [running])
    }

    @Test(arguments: [(5000, 4900), (300, 300)])
    func quotasAtOrAboveTheFloorReadIssuesAsBefore(core: Int, graphql: Int) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try f.rateLimit(core: core, graphql: graphql)
        let snapshot = await (try f.engine()).tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.triage.map(\.number) == [1])
        #expect(snapshot.defaultBranches[IssuePagingPayload.repo] == "main")
    }

    @Test func aZeroRateFloorDisablesTheHoldEvenWithNoQuotaLeft() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try f.setRateFloor(0)
        try f.rateLimit(core: 0, graphql: 0)
        let snapshot = await (try f.engine()).tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.triage.map(\.number) == [1])
    }

    @Test func anExplicitRateFloorOverridesTheDefault() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try f.setRateFloor(450)
        try f.rateLimit(core: 400, graphql: 4900)
        let snapshot = await (try f.engine()).tick(dispatching: false)
        #expect(snapshot.problem?.hasPrefix("GitHub rate limit:") == true)
        #expect(!FileManager.default.fileExists(atPath: f.file("repo-read").path))
    }

    @Test(arguments: ["not JSON", "gh error"])
    func anUnreadableRateLimitDoesNotHoldTheTick(answer: String) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        try Data("not JSON".utf8).write(to: f.file("rate-limit.json"))
        if answer == "gh error" { try Data().write(to: f.file("fail-rate-limit")) }
        let snapshot = await (try f.engine()).tick(dispatching: false)
        #expect(snapshot.problem == nil)
        #expect(snapshot.triage.map(\.number) == [1])
    }

    @Test func aRateHoldEndsWhenBothQuotasRecover() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        try f.rateLimit(core: 120, graphql: 4900)
        #expect(await engine.tick(dispatching: false).problem?.hasPrefix("GitHub rate limit:") == true)
        try f.rateLimit(core: 5000, graphql: 4900)
        let recovered = await engine.tick(dispatching: false)
        #expect(recovered.problem == nil)
        #expect(recovered.triage.map(\.number) == [1])
    }

    @Test func labelTimelineEventsDecodeAndStateChangedAtIncludesAssignmentEvents() throws {
        var node = IssuePagingPayload.node(7)
        node["timelineItems"] = ["nodes": [
            ["__typename": "LabeledEvent", "createdAt": "2026-10-19T12:00:03Z", "label": ["name": "stage:in-progress"]],
            ["__typename": "AssignedEvent", "createdAt": "2026-10-19T12:05:00Z"],
            ["__typename": "UnlabeledEvent", "createdAt": "2026-10-19T12:00:00Z", "label": ["name": "stage:ready"]]
        ]]
        let data = try JSONSerialization.data(withJSONObject: ["data": ["repository": ["issues": ["nodes": [node]]]]])
        let issue = try #require(GitHubClient.decodeOpenIssues(data, repo: IssuePagingPayload.repo).issues.first)
        let at = try #require(ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z"))
        #expect(Set(issue.labelEvents) == Set([
            LabelEvent(kind: .removed, label: "stage:ready", at: at),
            LabelEvent(kind: .added, label: "stage:in-progress", at: at.addingTimeInterval(3))
        ]))
        #expect(issue.stateChangedAt == at.addingTimeInterval(300))
        #expect(try GitHubClient.decodeOpenIssues(IssuePagingPayload.page([8]), repo: IssuePagingPayload.repo)
            .issues.first?.labelEvents == [])
    }

    @Test func theIssueQueryReadsLabelNamesAndTimesFromTheLastThirtyTimelineEvents() {
        let query = GitHubClient.openIssuesQuery.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        #expect(query.contains("timelineItems(last: 30"))
        for fragment in ["ASSIGNED_EVENT", "UNASSIGNED_EVENT", "LABELED_EVENT", "UNLABELED_EVENT",
                         "... on LabeledEvent", "... on UnlabeledEvent", "createdAt", "label { name }"] {
            #expect(query.contains(fragment), Comment(rawValue: fragment))
        }
    }

    @Test func decodeNextCursorOnlyWhenAnotherPageExists() throws {
        let next = try GitHubClient.decodeOpenIssues(IssuePagingPayload.page([1], next: "C2"), repo: "o/r")
        #expect(next.nextPage == "C2")
        // A stale endCursor must not imply that another page exists.
        let last = try JSONSerialization.data(withJSONObject: ["data": ["repository": ["issues": [
            "nodes": [IssuePagingPayload.node(1)], "pageInfo": ["hasNextPage": false, "endCursor": "C2"]
        ]]]])
        #expect(try GitHubClient.decodeOpenIssues(last, repo: "o/r").nextPage == nil)
        #expect(try GitHubClient.decodeOpenIssues(
            IssuePagingPayload.page([1], pageInfo: false), repo: "o/r").nextPage == nil)
    }

    @Test func decodeMissingSupplementalConnectionsAndDeduplicateByNumber() throws {
        let main = try GitHubClient.decodeOpenIssues(IssuePagingPayload.page([3, 1]), repo: "o/r")
        #expect(main.issues.map(\.number) == [3, 1])
        #expect(main.issues.allSatisfy { $0.repo == "o/r" })
        let combined = try GitHubClient.decodeOpenIssues(
            IssuePagingPayload.page([3, 1], ready: [1, 2], inProgress: [2, 4, 3]), repo: "o/r")
        #expect(combined.issues.map(\.number) == [3, 1, 2, 4])
    }

    @Test func openIssuesQueryPagesMainConnectionAndIncludesStagesOnlyOnFirstPage() throws {
        let query = GitHubClient.openIssuesQuery.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for fragment in ["$after: String", "$firstPage: Boolean!", "after: $after",
                         "pageInfo { hasNextPage endCursor }"] {
            #expect(query.contains(fragment))
        }
        for alias in ["ready", "inProgress"] {
            let pattern = "\(alias):\\s*issues\\([^)]*\\)\\s*@include\\(if:\\s*\\$firstPage\\)"
            #expect(try NSRegularExpression(pattern: pattern).firstMatch(
                in: query, range: NSRange(query.startIndex..., in: query)) != nil)
        }
    }

    @Test func searchQueryTrimsTextAndDropsQuotes() {
        #expect(IssueSearch.query(repo: "o/r", text: "  login \"bug\" ") == "repo:o/r is:issue is:open login bug")
    }

    @Test(arguments: [("#367", Optional(367)), ("367", Optional(367)), ("3 67", nil), ("", nil)])
    func searchNumberRecognizesOnlyNumericQueries(text: String, expected: Int?) {
        #expect(IssueSearch.number(in: text) == expected)
    }

    @Test func decodeSearchPreservesIssueOrderAndSkipsOtherNodeTypes() throws {
        let data = try JSONSerialization.data(withJSONObject: ["data": ["search": ["nodes": [
            IssuePagingPayload.node(9), ["__typename": "PullRequest", "number": 88],
            IssuePagingPayload.node(2)
        ]]]])
        let hits = try GitHubClient.decodeIssueSearch(data, repo: "o/r")
        #expect(hits.map(\.number) == [9, 2])
        #expect(hits.map(\.title) == ["Issue 9", "Issue 2"])
        #expect(hits.map(\.body) == ["Body 9", "Body 2"])
        #expect(hits.allSatisfy { $0.repo == "o/r" && $0.author == "teammate" })
    }

    @Test func decodeMissingIssueReturnsNil() throws {
        let data = Data(#"{"data":{"repository":{"issue":null}}}"#.utf8)
        #expect(try GitHubClient.decodeIssue(data, repo: "o/r") == nil)
    }

    @Test func aTurnSentStartsFromTheLastReadWithoutGitHubWhileItIsFresh() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let request = NewIssues.Request(id: "123456789", repo: IssuePagingPayload.repo, turn: 1, conversation: "## Owner\n\nexport csv")
        // Nothing read yet: the turn needs the full sync.
        await engine.requestCompose(request)
        #expect(await engine.composeTick() == nil)
        let full = await engine.tick(dispatching: false)
        #expect(full.problem == nil)
        try f.clearCalls()
        // Read a moment ago: the turn's tick shows the same lists and asks GitHub for nothing.
        let quick = try #require(await engine.composeTick())
        #expect(quick.problem == nil)
        #expect(quick.triage.map(\.number) == full.triage.map(\.number))
        #expect(quick.flows.keys.sorted() == full.flows.keys.sorted())
        #expect(quick.me == full.me)
        #expect(try String(contentsOf: f.file("call-count"), encoding: .utf8) == "0")
        // Load more asked for since: the list the agent would get is short by a page, so the full sync reads it.
        await engine.loadMoreIssues(repo: IssuePagingPayload.repo)
        #expect(await engine.composeTick() == nil)
    }

    @Test func aTurnIsMadeOnlyFromAFreshIssueList() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let request = NewIssues.Request(id: "123456789", repo: IssuePagingPayload.repo, turn: 1, conversation: "## Owner\n\nexport csv")
        let agents = ["claude": AgentTemplate(argv: ["/usr/local/bin/claude", "-p"])]
        await engine.requestCompose(request)
        let clone = f.root
        // A stale list makes no turn and keeps the request for the sync that reads a fresh one.
        let stale = await engine.composeCandidates(repo: IssuePagingPayload.repo, defaultBranch: "main", me: "me", agents: agents,
                                                   merged: [], issuesFresh: false, clone: clone, codeGraph: false, model: "m")
        #expect(stale.isEmpty)
        let made = await engine.composeCandidates(repo: IssuePagingPayload.repo, defaultBranch: "main", me: "me", agents: agents,
                                                  merged: [], issuesFresh: true, clone: clone, codeGraph: false, model: "m")
        #expect(made.map(\.key) == [request.key])
    }

    @Test func noTurnWaitingMeansNoQuickTick() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        _ = await engine.tick(dispatching: false)
        #expect(await engine.composeTick() == nil)
    }

    @Test func aReadIsFreshUnderOnePollWithEveryWantedPage() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = now.addingTimeInterval(-100), stale = now.addingTimeInterval(-300)
        #expect(Engine.isFresh(read: fresh, issues: fresh, pages: 1, wanted: 1, now: now, maxAge: 300))
        #expect(!Engine.isFresh(read: stale, issues: fresh, pages: 1, wanted: 1, now: now, maxAge: 300))
        #expect(!Engine.isFresh(read: fresh, issues: stale, pages: 1, wanted: 1, now: now, maxAge: 300))
        #expect(!Engine.isFresh(read: fresh, issues: fresh, pages: 1, wanted: 2, now: now, maxAge: 300))
        #expect(Engine.isFresh(read: fresh, issues: fresh, pages: 3, wanted: 2, now: now, maxAge: 300))
    }

    @Test func loadMoreReadsBothPagesAndClearsMoreWhenLastPageArrives() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let first = await engine.tick(dispatching: false)
        #expect(first.problem == nil)
        #expect(first.triage.map(\.number) == [1])
        #expect(first.issuesMore == [IssuePagingPayload.repo])
        try f.clearCalls()
        await engine.loadMoreIssues(repo: IssuePagingPayload.repo)
        let second = await engine.tick(dispatching: false)
        #expect(second.problem == nil)
        #expect(Set(second.triage.map(\.number)) == [1, 2])
        #expect(second.triage.count == 2)
        #expect(second.issuesMore.isEmpty)
        try f.expectTwoPageCalls()
    }

    @Test func failedSecondPageKeepsPreviousListWholeAndMoreAvailable() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let first = await engine.tick(dispatching: false)
        #expect(first.triage.map(\.number) == [1])
        #expect(first.issuesMore == [IssuePagingPayload.repo])
        // A successful reread of page 1 must not replace the prior list if page 2 fails.
        try IssuePagingPayload.page([99], next: "C2").write(to: f.file("page-1.json"))
        try Data().write(to: f.file("fail-page-2"))
        try f.clearCalls()
        await engine.loadMoreIssues(repo: IssuePagingPayload.repo)
        let failed = await engine.tick(dispatching: false)
        #expect(failed.problem == nil)
        #expect(failed.triage == first.triage)
        #expect(failed.issuesMore == [IssuePagingPayload.repo])
        try f.expectTwoPageCalls()
    }

    @Test func loadMoreInFlightIsSharedBySyncAndSurvivesNextTick() async throws {
        try await pagingRace(loadMoreFirst: true)
    }

    @Test func syncInFlightIsFollowedByReadWithLoadMorePageCount() async throws {
        try await pagingRace(loadMoreFirst: false)
    }

    private func pagingRace(loadMoreFirst: Bool) async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.release(); f.remove() }
        let engine = try f.engine()
        let completion = IssuePagingCompletion()
        try f.hold()
        let work = Task {
            do {
                let repo = IssuePagingPayload.repo
                let first = Task { () -> Engine.IssuePage? in
                    if loadMoreFirst { return await engine.readMoreIssues(repo: repo) }
                    #expect(await engine.readIssues(repo))
                    return nil
                }
                defer { first.cancel() }
                try await f.waitBlocked(1)
                let second = Task { () -> Engine.IssuePage? in
                    await completion.started()
                    if !loadMoreFirst { return await engine.readMoreIssues(repo: repo) }
                    #expect(await engine.readIssues(repo))
                    return nil
                }
                defer { second.cancel() }
                // Let the second caller enter the engine while GitHub is still held.
                while !(await completion.secondStarted) { try await Task.sleep(for: .milliseconds(10)) }
                try await Task.sleep(for: .milliseconds(100))
                f.release()
                let firstPage = await first.value
                let secondPage = await second.value
                let page = try #require(loadMoreFirst ? firstPage : secondPage)
                #expect(Set(page.triage.map(\.number)) == [1, 2])
                #expect(page.triage.count == 2)
                #expect(!page.more)
                #expect(await engine.issuePages[repo] == 2)
                if loadMoreFirst {
                    try f.expectTwoPageCalls()
                    let snapshot = await engine.tick(dispatching: false)
                    #expect(Set(snapshot.triage.map(\.number)) == [1, 2])
                    #expect(snapshot.triage.count == 2)
                    #expect(snapshot.issuesMore.isEmpty)
                } else {
                    #expect(try String(contentsOf: f.file("call-count"), encoding: .utf8) == "3")
                    for n in 1...3 {
                        let args = try String(contentsOf: f.file("call-\(n)"), encoding: .utf8)
                            .components(separatedBy: "\n")
                        #expect(args.contains(n == 3 ? "firstPage=false" : "firstPage=true"))
                        #expect(args.contains("after=C2") == (n == 3))
                        if n < 3 { #expect(!args.contains { $0.hasPrefix("after=") }) }
                    }
                }
            } catch { Issue.record(error) }
            await completion.finish()
        }
        defer { work.cancel() }
        let deadline = ContinuousClock.now + .seconds(20)
        while !(await completion.done), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await completion.done, "Issue paging race exceeded its 20 second budget")
    }

    @Test func loadMoreNeverExceedsIssuePageCap() async throws {
        let f = try IssuePagingEngineFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        #expect(Engine.issuePageCap == 10)
        for _ in 0..<(Engine.issuePageCap + 5) {
            await engine.loadMoreIssues(repo: IssuePagingPayload.repo)
        }
        let pages = await engine.issuePages
        #expect(pages[IssuePagingPayload.repo] == Engine.issuePageCap)
    }
}

struct IssuePagingEngineFixture {
    let root: URL
    let home: BtonHome
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    static func make() throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("issue-paging-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
        let f = Self(root: root, home: home)
        do {
            try home.prepare()
            var watched = WatchedRepo(slug: IssuePagingPayload.repo, path: nil)
            watched.startMoves = false
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 1,
                           agents: [:], schedules: []).save(to: home.configURL)
            try IssuePagingPayload.page([1], next: "C2").write(to: f.file("page-1.json"))
            try IssuePagingPayload.page([2]).write(to: f.file("page-2.json"))
            try f.rateLimit(core: 5000, graphql: 4900)
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            if [ "$1" = api ] && [ "$2" = rate_limit ]; then
              if [ -f fail-rate-limit ]; then echo 'quota unavailable' >&2; exit 1; fi
              cat rate-limit.json
              exit 0
            fi
            touch repo-read
            if [ "$1" = pr ] && [ "$2" = list ]; then echo '[]'; exit 0; fi
            if [ "$1" = api ] && [ "$2" = graphql ]; then
              case "$*" in
                *'issues('*)
                  count=0
                  if [ -f call-count ]; then count=$(cat call-count); fi
                  count=$((count + 1))
                  printf '%s' "$count" > call-count
                  printf '%s\n' "$@" > "call-$count"
                  touch "blocked-$count"
                  while [ -f hold ]; do sleep 0.05; done
                  after=
                  for argument in "$@"; do
                    case "$argument" in after=*) after=${argument#after=} ;; esac
                  done
                  if [ -n "$after" ]; then
                    if [ -f fail-page-2 ]; then echo 'page two unavailable' >&2; exit 1; fi
                    cat page-2.json
                  else cat page-1.json; fi
                  exit 0 ;;
              esac
              echo '{"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}'
              exit 0
            fi
            echo 'HTTP 404' >&2
            exit 1
            """#
            try script.write(to: f.file("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.file("gh").path)
            return f
        } catch { f.remove(); throw error }
    }

    func engine() throws -> Engine {
        try Engine(home: home, github: GitHubClient(ghPath: file("gh").path), log: { _ in })
    }

    func rateLimit(core: Int, graphql: Int, coreReset: Int = 1_799_999_000, graphqlReset: Int = 1_800_000_000) throws {
        try JSONSerialization.data(withJSONObject: ["resources": [
            "core": ["remaining": core, "reset": coreReset],
            "graphql": ["remaining": graphql, "reset": graphqlReset]
        ]]).write(to: file("rate-limit.json"))
    }

    func setRateFloor(_ floor: Int) throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.configURL)) as? [String: Any])
        json["rateLimitFloor"] = floor
        try JSONSerialization.data(withJSONObject: json).write(to: home.configURL)
    }

    func hold() throws { try Data().write(to: file("hold")) }
    func release() { try? FileManager.default.removeItem(at: file("hold")) }
    func waitBlocked(_ n: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: file("blocked-\(n)").path),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let blocked = FileManager.default.fileExists(atPath: file("blocked-\(n)").path)
        #expect(blocked, "GitHub did not reach the hold within 5 seconds")
        try #require(blocked)
    }

    func clearCalls() throws { try Data("0".utf8).write(to: file("call-count")) }

    func expectTwoPageCalls() throws {
        #expect(try String(contentsOf: file("call-count"), encoding: .utf8) == "2")
        let first = try String(contentsOf: file("call-1"), encoding: .utf8).components(separatedBy: "\n")
        let second = try String(contentsOf: file("call-2"), encoding: .utf8).components(separatedBy: "\n")
        #expect(first.contains("firstPage=true"))
        #expect(second.contains("firstPage=false"))
        #expect(!first.contains { $0.hasPrefix("after=") })
        #expect(second.contains("after=C2"))
        for (arguments, variable) in [(first, "firstPage=true"), (second, "firstPage=false")] {
            let index = try #require(arguments.firstIndex(of: variable))
            #expect(index > 0 && arguments[index - 1] == "-F")
        }
        let cursor = try #require(second.firstIndex(of: "after=C2"))
        #expect(cursor > 0 && second[cursor - 1] == "-f")
    }
}

private actor IssuePagingCompletion {
    var secondStarted = false
    var done = false
    func started() { secondStarted = true }
    func finish() { done = true }
}
