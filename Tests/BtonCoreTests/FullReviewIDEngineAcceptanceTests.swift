@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FullReviewIDEngineAcceptanceTests {
    @Test func ownShortApprovalRunsOnceMorePostsWholeIDAndThenStops() async throws {
        let f = try await FullReviewIDEngineFixture.make(reviewer: "owner")
        defer { f.start.remove() }
        let store = try JobStore(home: f.start.home)
        let original = JobKey(repo: f.start.repo, item: "pr-7", move: "review", head: f.head)
        let old = Job(id: UUID(), key: original, agent: "command", startedAt: .now.addingTimeInterval(-60), status: .succeeded)
        try store.save(old)
        let engine = try f.start.engine()
        let first = await engine.tick()
        #expect(first.problem == nil)
        let repairs = first.jobs.filter { $0.id != old.id }
        #expect(repairs.count == 1)
        let repair = try #require(repairs.first)
        #expect(repair.key == JobKey(repo: f.start.repo, item: "pr-7", move: "review", head: f.head, round: "+short-id"))
        try await f.finished(repair.id)
        #expect(store.all().first { $0.id == repair.id }?.status == .succeeded)
        let posted = try f.posted()
        #expect(posted == "## Review: approve (head \(f.head))\nKeep this short reference: \(f.head.prefix(8))")
        // Feed the actual outbound body back through the fake GitHub response.
        try f.start.editPR { node in
            node["comments"] = ["nodes": [FullReviewIDEngineFixture.comment(posted, author: "owner")]]
        }
        let second = await engine.tick()
        #expect(second.problem == nil)
        #expect(second.openPullRequests.first?.move?.name == "merge")
        #expect(second.jobs.filter { $0.key.move == "review" }.count == 2)
        #expect(Set(second.jobs.map(\.id)) == Set([old.id, repair.id]))
        #expect(try f.postCount() == 1)
    }

    @Test func shortApprovalLogsOncePerHeadAndTextAndListReadsStaySilent() async throws {
        let f = try await FullReviewIDEngineFixture.make(reviewer: "teammate")
        defer { f.start.remove() }
        let log = MoveLog()
        let engine = try f.start.engine(log: { log.append($0) })
        let line = "\(f.start.repo)#7: the approval of \(f.head.prefix(8)) does not count: it names 8 of the 40 digits of the commit's id"
        let initial = try #require(await engine.readLists())
        #expect(initial.openPullRequests.first?.move?.name == "review")
        #expect(!log.all.contains(line))
        for _ in 0..<2 {
            let synced = await engine.tick()
            #expect(synced.problem == nil)
            #expect(synced.openPullRequests.first?.move?.name == "review")
            #expect(synced.openPullRequests.first?.move?.owner == "teammate")
            #expect(synced.jobs.isEmpty)
            #expect(log.all.filter { $0 == line }.count == 1)
            let before = log.all
            _ = try #require(await engine.readLists())
            #expect(log.all.filter { $0 == line }.count == 1)
            #expect(log.all.filter { $0.contains("the approval of") } == before.filter { $0.contains("the approval of") })
        }
    }

    // Threat 5: a valid short claim must not bypass the live-head read before posting.
    @Test func headMovingDuringReviewCannotPostApproval() async throws {
        let f = try await FullReviewIDEngineFixture.make(reviewer: "owner", movesHead: true)
        defer { f.start.remove() }
        let engine = try f.start.engine()
        let synced = await engine.tick()
        #expect(synced.problem == nil)
        let job = try #require(synced.jobs.first)
        try await f.finished(job.id)
        let ended = try #require(try JobStore(home: f.start.home).all().first { $0.id == job.id })
        #expect(ended.status == .failed)
        #expect((ended.detail ?? "").contains("head moved"))
        let posted = (try? f.posted()) ?? ""
        #expect(!posted.hasPrefix("## Review: approve"))
    }
}

// Uses the existing real engine/dispatcher fixtures' value types, but builds isolated Git
// repositories instead of their shared templates (whose git invocations inherit user config).
struct FullReviewIDEngineFixture {
    let start: StartMovesFixture
    let head: String

    static func supervision() async throws -> SupervisionRunFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("full-id-engine-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            let origin = root.appendingPathComponent("origin.git"), clone = root.appendingPathComponent("clone")
            try await FullReviewIDFixture.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
            try await FullReviewIDFixture.git(["clone", origin.path, clone.path], in: root)
            try await FullReviewIDFixture.git(["commit", "--allow-empty", "-m", "Synthetic"], in: clone)
            try await FullReviewIDFixture.git(["push", "origin", "HEAD:refs/heads/main"], in: clone)
            try Data().write(to: root.appendingPathComponent("gh-calls"))
            let script = #"""
            #!/bin/sh
            set -eu
            export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_COUNT=3
            export GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=Synthetic
            export GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=synthetic@example.invalid
            export GIT_CONFIG_KEY_2=commit.gpgsign GIT_CONFIG_VALUE_2=false
            cd "${0%/*}"
            printf '%s\n' "$*" >> gh-calls
            case "$2" in
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(/usr/bin/git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else
                  echo 'HTTP 404' >&2; exit 1
                fi ;;
              repos/synthetic/project/git/commits/*)
                sha="${2##*/}"
                message=$(/usr/bin/git --git-dir=origin.git show -s --format=%s "$sha")
                message=${message//\\/\\\\}
                message=${message//\"/\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """#
            try script.write(to: root.appendingPathComponent("gh"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("gh").path)
            return SupervisionRunFixture(leases: RetryLeaseFixture(root: root, item: try #require(LeaseItem("pr-7"))),
                home: BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("dispatcher").path]), clone: clone)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    static func make(reviewer: String, movesHead: Bool = false) async throws -> Self {
        let base = try await supervision()
        let root = base.leases.root
        do {
            let head = try await FullReviewIDFixture.git(["rev-parse", "HEAD"], in: base.clone)
            try await FullReviewIDFixture.git(["push", "origin", "HEAD:refs/pull/7/head"], in: base.clone)
            let home = BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("engine").path])
            try home.prepare()
            let start = StartMovesFixture(leases: base.leases, home: home)
            let bare = home.url.appendingPathComponent("leases.git")
            try await FullReviewIDFixture.git(["init", "--bare", bare.path], in: root)
            try await FullReviewIDFixture.git(["-C", bare.path, "hash-object", "-w", "-t", "tree", "/dev/null"], in: root)
            try await FullReviewIDFixture.git(["-C", bare.path, "config",
                "url.\(root.appendingPathComponent("origin.git").path).insteadOf", "https://github.com/synthetic/project.git"], in: root)
            var watched = WatchedRepo(slug: start.repo, path: base.clone.path)
            watched.startMoves = true
            watched.environment = ["OBSERVE": root.path]
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 1, agents: [:], schedules: []).save(to: home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: home)
            try head.write(to: root.appendingPathComponent("live-head"), atomically: true, encoding: .utf8)
            let moveHead = movesHead ? "printf '%s' '\(FullReviewIDFixture.other)' > \"$OBSERVE/live-head\"; " : ""
            let command = moveHead + "printf '%s\\n%s' '## Review: approve (head \(head.prefix(8)))' 'Keep this short reference: \(head.prefix(8))' > \"$BTON_OUT\""
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": ["small": [["heading": "## Review:", "notByAuthor": true]]], "fixed": "## Fixed:",
                "moves": [["move": "review", "when": ["no_review_or_response_newer"], "who": "assignee"],
                          ["move": "merge", "when": ["approved_current_head"], "who": "author"],
                          ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"]],
                "dispatch": ["review": ["command": ["/bin/sh", "-c", command], "post": "comment", "checks": false]]]
            // Keep the envelope on one line so StartMovesFixture.editPR can replay the posted text.
            let node: [String: Any] = ["number": 7, "title": "Synthetic", "url": "https://example.invalid/pr/7",
                "isDraft": false, "headRefOid": head, "headRefName": "feature", "baseRefName": "main",
                "body": "Tier: small", "updatedAt": "2026-10-19T12:00:00Z", "mergeable": "MERGEABLE",
                "authorAssociation": "MEMBER", "author": ["login": "author"], "labels": ["nodes": []],
                "assignees": ["nodes": [["login": reviewer]]],
                "comments": ["nodes": [comment("## Review: approve (head \(head.prefix(8)))", author: reviewer)]]]
            let payload: [String: Any] = ["data": ["viewer": ["login": "owner"], "repository": [
                "defaultBranchRef": ["name": "main"], "pullRequests": [
                    "pageInfo": ["hasNextPage": false, "endCursor": NSNull()], "nodes": [node]]]]]
            let page = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let flowText = String(decoding: try JSONSerialization.data(withJSONObject: flow), as: UTF8.self)
            let cases = """
              repos/synthetic/project/contents/.bton/flow.json)
                cat <<'JSON'
            \(flowText)
            JSON
                ;;
              graphql)
                cat <<'JSON'
            \(page)
            JSON
                ;;
              list) echo '[]' ;;
            """
            let handler = #"""
            if [ "$1" = pr ] && [ "$2" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN","comments":[]}' "$(cat live-head)"
              exit 0
            fi
            if [ "$1" = pr ] && [ "$2" = comment ]; then
              while [ $# -gt 0 ]; do
                if [ "$1" = --body-file ]; then cp "$2" posted; fi
                shift
              done
              printf 'post\n' >> posts
              exit 0
            fi
            case "$*" in *repos/synthetic/project/pulls/7/reviews*) exit 0 ;; esac
            """#
            let gh = root.appendingPathComponent("gh")
            let old = try String(contentsOf: gh, encoding: .utf8)
            try old.replacingOccurrences(of: "case \"$2\" in", with: handler + "\ncase \"$2\" in\n" + cases)
                .write(to: gh, atomically: true, encoding: .utf8)
            return Self(start: start, head: head)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    static func comment(_ body: String, author: String) -> [String: Any] {
        ["author": ["login": author], "authorAssociation": "MEMBER", "body": body,
         "createdAt": "2026-10-19T12:00:00Z"]
    }

    func posted() throws -> String { try String(contentsOf: start.root.appendingPathComponent("posted"), encoding: .utf8) }
    func postCount() throws -> Int {
        try String(contentsOf: start.root.appendingPathComponent("posts"), encoding: .utf8).split(separator: "\n").count
    }
    func finished(_ id: UUID) async throws {
        let store = try JobStore(home: start.home)
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if store.all().contains(where: { $0.id == id && $0.status != .running }),
               !FileManager.default.fileExists(atPath: store.lockURL(id).path) { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw DispatchError.worktree("Review did not finish within sixty seconds")
    }
}
