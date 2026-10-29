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
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
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
