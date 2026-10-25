@testable import BtonCore
import Foundation
import Testing

struct GitHubReviewMirrorAcceptanceTests {
    @Test(arguments: ["review", "decide"], ["approve", "changes", "blocked"])
    func mirrorsVerdictAfterCommentWithFullStartedHead(move: String, verdict: String) async throws {
        let f = try await ReviewMirrorFixture.make()
        defer { f.remove() }
        let summary = "\(move == "decide" ? "## Decision:" : "## Review:") \(verdict) (head \(f.head.prefix(8)))"
            + " --method DELETE -f event=APPROVE ; $(touch \(f.root.path)/injected) `echo injected` 'quoted' \"double\""
        let job = try await f.run(move: move, message: summary + "\n\nDetailed review stays in the comment.")
        #expect(job.status == .succeeded)
        #expect(job.review?.head == f.head)
        let calls = try f.calls()
        let comment = try #require(calls.firstIndex { $0.starts(with: ["pr", "comment"]) })
        let mirror = try #require(calls.firstIndex { $0.contains("repos/synthetic/project/pulls/7/reviews") })
        #expect(comment < mirror)
        #expect(calls.filter { $0.contains("repos/synthetic/project/pulls/7/reviews") }.count == 1)
        #expect(calls[mirror] == ["api", "--method", "POST", "repos/synthetic/project/pulls/7/reviews",
            "-f", "commit_id=\(f.head)", "-f", "event=\(verdict == "approve" ? "APPROVE" : "REQUEST_CHANGES")",
            "-f", "body=\(summary)"])
        #expect(try f.text("posted-comment") == summary + "\n\nDetailed review stays in the comment.")
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("injected").path))
        if move == "decide" {
            let clear = try #require(calls.firstIndex { $0.contains("--remove-label") })
            #expect(mirror < clear)
            #expect(calls[clear] == ["pr", "edit", "7", "--repo", "synthetic/project", "--remove-label", "turn:lead"])
        }
    }

    @Test func mirrorFailureIsNotedButDecisionSucceedsAndClearsLabel() async throws {
        let f = try await ReviewMirrorFixture.make(reviewFails: true)
        defer { f.remove() }
        let job = try await f.run(move: "decide", message: "## Decision: blocked (head \(f.head.prefix(8)))\nNeeds changes.")
        #expect(job.status == .succeeded)
        let calls = try f.calls()
        let comment = try #require(calls.firstIndex { $0.starts(with: ["pr", "comment"]) })
        let review = try #require(calls.firstIndex { $0.contains("repos/synthetic/project/pulls/7/reviews") })
        let clear = try #require(calls.firstIndex { $0.contains("--remove-label") })
        #expect(comment < review && review < clear)
        let log = try String(contentsOf: f.store.logURL(job.id), encoding: .utf8)
        #expect(log.contains("could not file the GitHub review"))
        #expect(log.contains("Cannot review your own pull request"))
    }

    @Test func redactedHeadStillMirrorsValidatedVerdictAndPostedSummary() async throws {
        let f = try await ReviewMirrorFixture.make()
        defer { f.remove() }
        let shortHead = String(f.head.prefix(8))
        let job = try await f.run(move: "decide", message: "## Decision: approve (head \(shortHead))\nReady.",
            environment: ["BUILD_REVISION": shortHead])
        #expect(job.status == .succeeded)
        let posted = try f.text("posted-comment")
        let summary = String(posted.prefix { !$0.isNewline })
        #expect(summary == "## Decision: approve (head [BUILD_REVISION])")
        let calls = try f.calls()
        let mirrors = calls.filter { $0.contains("repos/synthetic/project/pulls/7/reviews") }
        #expect(mirrors.count == 1, "Redaction must not silently suppress a validated verdict")
        if let mirror = mirrors.first {
            #expect(mirror == ["api", "--method", "POST", "repos/synthetic/project/pulls/7/reviews",
                "-f", "commit_id=\(f.head)", "-f", "event=APPROVE", "-f", "body=\(summary)"])
        }
    }

    @Test func commentFailureFailsJobWithoutReviewOrLabelClearing() async throws {
        let f = try await ReviewMirrorFixture.make(commentFails: true)
        defer { f.remove() }
        let job = try await f.run(move: "decide", message: "## Decision: approve (head \(f.head.prefix(8)))\nReady.")
        #expect(job.status == .failed)
        #expect(job.detail?.hasPrefix("posting the review failed") == true)
        let calls = try f.calls()
        #expect(calls.filter { $0.starts(with: ["pr", "comment"]) }.count == 1)
        #expect(!calls.contains { $0.contains("repos/synthetic/project/pulls/7/reviews") })
        #expect(!calls.contains { $0.contains("--remove-label") })
    }
}

private struct ReviewMirrorFixture {
    let base: SupervisionRunFixture
    let store: JobStore
    let dispatcher: Dispatcher
    let head: String
    var root: URL { base.leases.root }

    static func make(commentFails: Bool = false, reviewFails: Bool = false) async throws -> Self {
        let base = try await SupervisionRunFixture.make()
        let root = base.leases.root
        let gh = root.appendingPathComponent("gh")
        let original = try String(contentsOf: gh, encoding: .utf8)
        // NUL-delimited arguments and an empty argument between calls preserve spaces, quotes,
        // shell syntax and newlines, unlike the shared fixture's human-readable $* log.
        let handler = """
        printf '%s\\0' "$@" >> "$(dirname "$0")/mirror-argv"
        printf '\\0' >> "$(dirname "$0")/mirror-argv"
        if [ "${1-}" = pr ] && [ "${2-}" = comment ]; then
          cp "$7" "$(dirname "$0")/posted-comment"
          if [ \(commentFails ? "1" : "0") = 1 ]; then echo 'comment offline' >&2; exit 1; fi
          touch "$(dirname "$0")/comment-succeeded"
          exit 0
        fi
        case "$*" in
          *repos/synthetic/project/pulls/7/reviews*)
            test -f "$(dirname "$0")/comment-succeeded" || exit 9
            if [ \(reviewFails ? "1" : "0") = 1 ]; then
              echo 'Cannot review your own pull request' >&2; exit 1
            fi
            exit 0 ;;
        esac
        if [ "${1-}" != api ]; then exit 0; fi
        """
        try original.replacingOccurrences(of: "set -eu", with: "set -eu\n" + handler)
            .write(to: gh, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: gh.path)
        let result = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path, "rev-parse", "HEAD"], timeout: .seconds(20))
        try #require(result.status == 0)
        let head = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let push = try await ProcessRunner().run("/usr/bin/git", ["-C", base.clone.path, "push", "origin", "HEAD:refs/pull/7/head"], timeout: .seconds(20))
        try #require(push.status == 0)
        let github = GitHubClient(ghPath: gh.path)
        let store = try JobStore(home: base.home)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: base.home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
        return Self(base: base, store: store,
            dispatcher: Dispatcher(github: github, leases: leases, jobs: store, log: { _ in }), head: head)
    }

    func run(move: String, message: String, environment: [String: String] = [:]) async throws -> Job {
        let final = root.appendingPathComponent("final")
        try message.write(to: final, atomically: true, encoding: .utf8)
        let agent = root.appendingPathComponent("review-agent")
        try "#!/bin/sh\ncat '\(final.path)'\n".write(to: agent, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: agent.path)
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:"]]], "fixed": "## Fixed:", "moves": [], "dispatch": [:],
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["owner"]]]
        let flow = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
        let pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!, headSha: head,
            headRef: "feature", baseRef: "main", body: "", isDraft: false, labels: ["turn:lead"],
            assignees: [], comments: [], updatedAt: .now)
        var candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true, labels: ["turn:lead"]),
            key: JobKey(repo: pr.repo, item: "pr-7", move: move, head: head), agent: "synthetic", prompt: "TASK",
            command: nil, postComment: true, timeout: .seconds(30))
        candidate.skipsChecks = true
        let outcome = await dispatcher.dispatch(candidate, clone: base.clone, flow: flow,
            agents: ["synthetic": AgentTemplate(argv: [agent.path])], environment: environment)
        guard case .started = outcome else { throw DispatchError.worktree("Acceptance job did not start") }
        for _ in 0..<2400 {
            if let job = store.all().first(where: { $0.status != .running }),
               !FileManager.default.fileExists(atPath: store.lockURL(job.id).path) { return job }
            try await Task.sleep(for: .milliseconds(25))
        }
        for job in store.all() { await dispatcher.stop(job.id) }
        throw DispatchError.worktree("Acceptance job did not finish in sixty seconds")
    }

    func calls() throws -> [[String]] {
        let data = try Data(contentsOf: root.appendingPathComponent("mirror-argv"))
        var calls: [[String]] = []
        var current: [String] = []
        for argument in data.split(separator: 0, omittingEmptySubsequences: false).dropLast() {
            if argument.isEmpty { calls.append(current); current = [] }
            else { current.append(String(decoding: argument, as: UTF8.self)) }
        }
        return calls
    }
    func text(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func remove() { try? FileManager.default.removeItem(at: root) }
}
