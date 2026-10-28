@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct ReviewerOwnerAcceptanceTests {
    @Test func firstRequestedReviewerOwnsMoveRegardlessOfAssignees() throws {
        let flow = try ReviewerOwnerFixture.flow()
        var pr = ReviewerOwnerFixture.pr(assignees: ["someoneElse"])
        pr.requestedReviewers = ["teammate", "second"]
        let resolved = FlowEngine.resolve("reviewer", pr: pr, flow: flow)
        #expect(resolved.owner == "teammate")
        #expect(!resolved.fromRotation)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == "teammate")
        #expect(!move.ownerFromRotation)
        #expect(FlowEngine.ownerKind(for: pr, flow: flow) == "reviewer")
    }

    @Test(arguments: 320...325)
    func missingRequestsUseSameRotationAsUnassignedRule(number: Int) throws {
        let reviewers = ["lead-dev", "dev-b", "dev-c"]
        let flow = try ReviewerOwnerFixture.flow(reviewers: reviewers)
        let assignedFlow = try ReviewerOwnerFixture.flow(who: "assignee", reviewers: reviewers)
        let expected = ["lead-dev", "dev-c"][number % 2]
        let unassigned = try FlowFixture.pr(assignees: [], number: number, author: "DEV-B")
        let assigneePick = try #require(FlowEngine.move(for: unassigned, flow: assignedFlow))
        #expect(assigneePick.owner == expected)
        for assignees in [[], ["someoneElse"], ["DEV-B", "another"]] {
            let pr = try FlowFixture.pr(assignees: assignees, number: number, author: "DEV-B")
            #expect(pr.requestedReviewers.isEmpty)
            let resolved = FlowEngine.resolve("reviewer", pr: pr, flow: flow)
            #expect(resolved.owner == expected)
            #expect(resolved.fromRotation)
            let move = try #require(FlowEngine.move(for: pr, flow: flow))
            #expect(move.owner == expected)
            #expect(move.owner == assigneePick.owner)
            #expect(move.ownerFromRotation)
        }
    }

    @Test(arguments: [[], ["AUTHOR"]])
    func missingRequestsWithoutEligibleRotationHaveNoOwner(reviewers: [String]) throws {
        let flow = try ReviewerOwnerFixture.flow(reviewers: reviewers)
        let pr = ReviewerOwnerFixture.pr(assignees: ["someoneElse"])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.owner == nil)
        #expect(!move.ownerFromRotation)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "someoneElse"))
    }

    @Test func takeoverSimulatesReviewRequestAndPreservesInput() throws {
        let flow = try ReviewerOwnerFixture.flow()
        var pr = ReviewerOwnerFixture.pr(assignees: ["someoneElse"])
        pr.requestedReviewers = ["teammate", "second"]
        let taken = try #require(FlowEngine.takeover(of: pr, flow: flow, me: "viewer"))
        #expect(taken.owner == "viewer")
        #expect(taken.name == "review")
        #expect(taken.hasDispatch)
        var requested = pr
        requested.requestedReviewers = ["viewer"]
        #expect(FlowEngine.isDispatchable(taken, pr: requested, flow: flow, me: "viewer"))
        #expect(pr.requestedReviewers == ["teammate", "second"])
        #expect(pr.assignees == ["someoneElse"])
        #expect(requested.assignees == ["someoneElse"])
    }

    @Test(arguments: ["Reviewer", "teammate"])
    func takeoverRequiresExactReviewerKeyword(who: String) throws {
        var pr = ReviewerOwnerFixture.pr()
        pr.requestedReviewers = ["teammate"]
        #expect(try FlowEngine.takeover(of: pr, flow: ReviewerOwnerFixture.flow(who: who), me: "viewer") == nil)
    }

    @Test func requestedAuthorCannotDispatchIndependentReview() throws {
        let flow = try ReviewerOwnerFixture.flow(notByAuthor: true)
        var pr = ReviewerOwnerFixture.pr(assignees: ["someoneElse"], author: "AUTHOR")
        pr.requestedReviewers = ["author"]
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.owner == "author")
        #expect(move.ownerWroteIt)
        #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "author"))
    }

    @Test(arguments: [[], ["VIEWER"], ["teammate"], ["teammate", "ViEwEr"], ["zeta", "VIEWER", "alpha", "beta"]])
    func requestReviewMakesOneCallRemovingOnlyOtherLoginsInOrder(others: [String]) async throws {
        let f = try await ReviewerOwnerFixture.make()
        defer { f.remove() }
        try await f.github.requestReview("viewer", replacing: others, repo: f.repo, number: 7)
        let remaining = others.filter { $0.caseInsensitiveCompare("viewer") != .orderedSame }
        let expected = ["pr", "edit", "7", "--repo", f.repo, "--add-reviewer", "viewer"]
            + (remaining.isEmpty ? [] : ["--remove-reviewer", remaining.joined(separator: ",")])
        #expect(try f.calls() == [expected])
    }

    @Test func decodesUserReviewRequestsInOrderIgnoringTeams() throws {
        let requests: [[String: Any]] = [
            ["requestedReviewer": ["login": "a"]],
            // Team t projects as an empty object: the query selects login only on User.
            ["requestedReviewer": [String: String]()],
            ["requestedReviewer": ["login": "b"]]
        ]
        let data = try reviewerPayload(requests: requests)
        let pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "o/r").pullRequests.first)
        #expect(pr.requestedReviewers == ["a", "b"])
    }

    @Test func missingReviewRequestsDecodeAsEmpty() throws {
        let data = try FlowFixture.graphql()
        let pr = try #require(GitHubClient.decodeOpenPullRequests(data, repo: "o/r").pullRequests.first)
        #expect(pr.requestedReviewers == [])
    }

    @Test func engineTakeRequestsReviewUnderLeaseWithoutAssigning() async throws {
        let f = try await ReviewerOwnerFixture.make()
        defer { f.remove() }
        let engine = try f.engine()
        let taken = try await engine.take(repo: f.repo, number: 7, from: "teammate")
        #expect(taken.name == "review")
        #expect(taken.owner == "viewer")
        #expect(taken.hasDispatch)
        #expect(try f.writes() == [["pr", "edit", "7", "--repo", f.repo,
            "--add-reviewer", "viewer", "--remove-reviewer", "teammate"]])
        #expect(try !f.calls().contains { $0.contains("--add-assignee") || $0.contains("--remove-assignee") })
        #expect(try f.readText("assigned-under-lease") == "yes")
        try await f.expectReleased()
        #expect(await engine.tick(dispatching: false).next == ["\(f.repo)#pr-7"])
    }
}

private func reviewerPayload(requests: [[String: Any]]) throws -> Data {
    var object = try #require(JSONSerialization.jsonObject(with: FlowFixture.graphql()) as? [String: Any])
    var data = try #require(object["data"] as? [String: Any])
    var repository = try #require(data["repository"] as? [String: Any])
    var connection = try #require(repository["pullRequests"] as? [String: Any])
    var nodes = try #require(connection["nodes"] as? [[String: Any]])
    nodes[0]["reviewRequests"] = ["nodes": requests]
    connection["nodes"] = nodes
    repository["pullRequests"] = connection
    data["repository"] = repository
    object["data"] = data
    return try JSONSerialization.data(withJSONObject: object)
}

private struct ReviewerOwnerFixture {
    let root: URL
    let home: BtonHome
    let repo = "synthetic/project"
    var item: LeaseItem { LeaseItem("pr-7")! }
    var github: GitHubClient { GitHubClient(ghPath: root.appendingPathComponent("gh").path) }

    static func flow(who: String = "reviewer", reviewers: [String] = [], dispatch: Bool = true,
                     moves: Bool = true, notByAuthor: Bool = true) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: flowData(who: who, reviewers: reviewers,
            dispatch: dispatch, moves: moves, notByAuthor: notByAuthor))
    }

    static func flowData(who: String = "reviewer", reviewers: [String] = [], dispatch: Bool = true,
                         moves: Bool = true, notByAuthor: Bool = true) throws -> Data {
        let object: [String: Any] = ["version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["feature", "small"], "default": "feature"],
            "reviews": ["feature": [["heading": "## Review:", "notByAuthor": notByAuthor]]],
            "fixed": "## Fixed:", "reviewers": reviewers,
            "moves": moves ? [["move": "review", "when": ["no_review_or_response_newer"],
                                "who": ["feature": who, "small": "assignee"]]] : [],
            "dispatch": dispatch ? ["review": ["agent": "synthetic", "prompt": "Review"]] : [:]]
        return try JSONSerialization.data(withJSONObject: object)
    }

    static func pr(assignees: [String] = ["teammate"], author: String = "author", base: String = "develop",
                   association: String = "MEMBER", tier: String = "feature") -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: author,
            authorAssociation: association, url: URL(string: "https://example.invalid/pr/7")!,
            headSha: String(repeating: "a", count: 40), headRef: "feature", baseRef: base,
            body: "Tier: \(tier)", isDraft: false, labels: [], assignees: assignees, comments: [],
            updatedAt: Date(timeIntervalSince1970: 1_792_411_200))
    }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-takeover-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
        let f = Self(root: root, home: home)
        do {
            try home.prepare()
            let remote = root.appendingPathComponent("origin.git").path
            let bare = home.url.appendingPathComponent("leases.git").path
            for args in [["init", "--bare", remote], ["init", "--bare", bare],
                         ["-C", bare, "hash-object", "-w", "-t", "tree", "/dev/null"],
                         ["-C", bare, "config", "url.\(remote).insteadOf", "https://github.com/\(f.repo).git"]] {
                _ = try await f.git(args)
            }
            var watched = WatchedRepo(slug: f.repo, path: root.path)
            watched.branch = "develop"
            watched.startMoves = false
            #expect(!watched.startsMoves)
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 0, agents: [:], schedules: [])
                .save(to: home.configURL)
            try f.writeFlow()
            var requested = pr(assignees: ["someoneElse"])
            requested.requestedReviewers = ["teammate"]
            try f.writePRs([requested])
            try f.installGH()
            return f
        } catch { f.remove(); throw error }
    }

    func engine() throws -> Engine {
        try text("require-lease", "1")
        return try Engine(home: home, github: github, log: { _ in })
    }
    func store(_ holder: String) throws -> LeaseStore {
        let remote = root.appendingPathComponent("origin.git").path
        return try LeaseStore(home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent(holder).path]),
            holder: holder, host: holder, github: github, remoteURL: { _ in remote })
    }
    func text(_ name: String, _ value: String) throws {
        try value.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    func readText(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func writeFlow(who: String = "reviewer", reviewers: [String] = []) throws {
        try Self.flowData(who: who, reviewers: reviewers).write(to: root.appendingPathComponent("flow"))
    }
    func writePRs(_ prs: [PullRequest]) throws {
        let nodes: [[String: Any]] = prs.map { pr in
            ["number": pr.number, "title": pr.title, "url": pr.url.absoluteString, "isDraft": pr.isDraft,
             "headRefOid": pr.headSha, "headRefName": pr.headRef, "baseRefName": pr.baseRef,
             "body": pr.body, "updatedAt": "2026-10-26T12:00:00Z", "authorAssociation": pr.authorAssociation,
             "author": ["login": pr.author], "labels": ["nodes": []],
             "assignees": ["nodes": pr.assignees.map { ["login": $0] }],
             "reviewRequests": ["nodes": pr.requestedReviewers.map {
                 ["requestedReviewer": ["login": $0]]
             }], "comments": ["nodes": []]]
        }
        let object: [String: Any] = ["data": ["viewer": ["login": "viewer"], "repository": [
            "defaultBranchRef": ["name": "main"], "pullRequests": ["nodes": nodes,
                "pageInfo": ["hasNextPage": false, "endCursor": NSNull()]]]]]
        try JSONSerialization.data(withJSONObject: object).write(to: root.appendingPathComponent("prs"))
    }

    func installGH() throws {
        let script = #"""
        #!/bin/bash
        set -eu
        cd "${0%/*}"
        printf '%s\0' "$@" >> argv
        printf '\0' >> argv
        if [ "${1-}" = pr ] && [ "${2-}" = edit ]; then
          if [ -f require-lease ]; then
            message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s refs/bton/leases/pr-7)
            case "$message" in *'"released":false'*) printf yes > assigned-under-lease ;; *) exit 91 ;; esac
          fi
          if [ -f fail-assign ]; then echo 'assignment sentinel' >&2; exit 43; fi
          exit 0
        fi
        case "${2-}" in
          repos/synthetic/project/contents/.bton/flow.json?ref=develop)
            if [ -f fail-flow ]; then echo 'fresh flow failed' >&2; exit 41; fi
            cat flow ;;
          graphql)
            if [ -f fail-prs ]; then echo 'fresh prs failed' >&2; exit 41; fi
            cat prs ;;
          user) echo viewer ;;
          repos/synthetic/project/git/ref/*)
            if [ -f fail-lease ]; then echo 'lease offline' >&2; exit 42; fi
            ref="refs/${2#repos/synthetic/project/git/ref/}"
            if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
              printf '{"object":{"sha":"%s"}}' "$sha"
            else echo 'HTTP 404' >&2; exit 1; fi ;;
          repos/synthetic/project/git/commits/*)
            message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "${2##*/}")
            message=${message//\\/\\\\}
            message=${message//\"/\\\"}
            printf '{"message":"%s"}' "$message" ;;
          list) echo '[]' ;;
          *) echo 'unexpected gh call' >&2; exit 97 ;;
        esac
        """#
        try text("gh", script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("gh").path)
    }

    func calls() throws -> [[String]] {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("argv").path) else { return [] }
        let bytes = try Data(contentsOf: root.appendingPathComponent("argv"))
        var calls: [[String]] = [], current: [String] = []
        for arg in bytes.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            if arg.isEmpty { calls.append(current); current = [] }
            else { current.append(String(decoding: arg, as: UTF8.self)) }
        }
        return calls
    }
    func writes() throws -> [[String]] { try calls().filter { $0.first != "api" || $0.contains("--method") || $0.contains("-X") } }
    func git(_ args: [String]) async throws -> ProcessOutput {
        let result = try await ProcessRunner().run("/usr/bin/git", args,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(120))
        try #require(result.status == 0, "Local Git fixture: \(result.stderr)")
        return result
    }
    func expectReleased() async throws {
        guard case let .free(record) = try await store("observer").state(of: item, in: repo) else {
            Issue.record("Take must release the PR lease"); return
        }
        #expect(record.released)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
