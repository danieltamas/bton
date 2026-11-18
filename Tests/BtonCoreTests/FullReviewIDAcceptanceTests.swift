@testable import BtonCore
import Foundation
import Testing

// Expected values come from Parts 1 to 3, not from the matching implementation.
enum FullReviewIDFixture {
    static let head = "abcdef1234567890abcdef1234567890abcdef12"
    static let carried = "cdefab1234567890cdefab1234567890cdefab12"
    static let other = "fedcba1234567890fedcba1234567890fedcba12"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func flow(rounds: Bool = false) throws -> Flow {
        var moves: [[String: Any]] = [
            ["move": "review", "when": ["no_review_or_response_newer"], "who": "assignee"],
            ["move": "merge", "when": ["approved_current_head"], "who": "author"],
            ["move": "fix", "when": ["latest_review_changes_or_blocked"], "who": "author"]]
        if rounds {
            moves.insert(["move": "decide", "when": ["label:turn:lead"], "who": "me"], at: 0)
            moves.append(["move": "fix-ci", "when": ["checks_red:gate"], "who": "author"])
        }
        let json: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:", "notByAuthor": true]]],
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["author"]],
            "fixed": "## Fixed:", "moves": moves,
            "dispatch": ["review": ["agent": "synthetic", "prompt": "Review", "post": "comment"]]]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func comment(_ id: String, verdict: String = "approve", author: String = "me",
                        second: Int = 0, heading: String = "## Review:",
                        association: String = "MEMBER") -> PullRequestComment {
        .init(author: author, authorAssociation: association, body: "\(heading) \(verdict) (head \(id))",
              createdAt: now.addingTimeInterval(Double(second)))
    }

    static func pr(_ comments: [PullRequestComment] = [], head: String = head) -> PullRequest {
        .init(repo: "synthetic/project", number: 7, title: "Full ID acceptance", author: "author",
              authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
              headSha: head, headRef: "feature", baseRef: "main", body: "Tier: small", isDraft: false,
              labels: [], assignees: ["me"], comments: comments, updatedAt: .distantPast)
    }

    // Every fixture git invocation, including reads, carries an isolated config and identity.
    static let gitEnvironment = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_COUNT": "3", "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Synthetic",
        "GIT_CONFIG_KEY_1": "user.email", "GIT_CONFIG_VALUE_1": "synthetic@example.invalid",
        "GIT_CONFIG_KEY_2": "commit.gpgsign", "GIT_CONFIG_VALUE_2": "false"]

    @discardableResult static func git(_ args: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", args, in: directory,
            environment: gitEnvironment, timeout: .seconds(30))
        try #require(result.status == 0, "git \(args): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@Suite(ProcessBound())
struct FullReviewIDAcceptanceTests {
    private typealias F = FullReviewIDFixture

    @Test(arguments: 1...18)
    func onlyWholeApprovalsAuthorizeTheHead(scenario: Int) throws {
        let h = F.head, c = F.carried
        let h8 = String(h.prefix(8))
        var pr = F.pr()
        var expected = "review"
        switch scenario {
        case 1: pr.comments = [F.comment(h)]; expected = "merge"
        case 2: pr.comments = [F.comment(h.uppercased())]; expected = "merge"
        case 3: pr = F.pr([F.comment(h)], head: h.uppercased()); expected = "merge"
        case 4: pr.comments = [F.comment(String(h.prefix(39)))]
        case 5: pr.comments = [F.comment(h8)]
        case 6: pr.comments = [F.comment(h), F.comment(h8, second: 1)]
        case 7: pr.comments = [F.comment(h8, verdict: "changes")]; expected = "fix"
        case 8: pr.comments = [F.comment(String(h.prefix(7)), verdict: "blocked")]; expected = "fix"
        case 9:
            pr.comments = [F.comment(h8, verdict: "changes"), F.comment(h, second: 1)]; expected = "merge"
        case 10:
            pr.comments = [F.comment(h), F.comment(h8, verdict: "changes", second: 1)]; expected = "fix"
        case 11:
            pr.comments = [F.comment(h8), F.comment(h8, verdict: "addressed", author: "author",
                second: 1, heading: "## Fixed:")]
        case 12...14:
            pr.carriedHeads = [c]
            pr.comments = [F.comment(scenario == 12 ? c : String(c.prefix(8)),
                                     verdict: scenario == 14 ? "changes" : "approve")]
            expected = scenario == 12 ? "merge" : scenario == 14 ? "fix" : "review"
        case 15: pr.comments = [F.comment(F.other)]
        default:
            pr.comments = [F.comment(scenario == 16 ? h : h8, verdict: scenario == 18 ? "changes" : "approve",
                                     author: "author", heading: "## Decision:")]
            expected = scenario == 16 ? "merge" : scenario == 18 ? "fix" : "review"
        }
        let flow = try F.flow()
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == expected)
        if scenario == 6 {
            let reviews = FlowEngine.reviews(of: pr, flow: flow)
            #expect(reviews.count == 2)
            #expect(reviews.last?.head == h8)
        }
    }

    @Test(arguments: [7, 8, 12, 20, 39])
    func everyShortApprovalRemainsAReviewButCannotMerge(length: Int) throws {
        let id = String(F.head.prefix(length))
        let pr = F.pr([F.comment(id.uppercased())])
        let flow = try F.flow()
        #expect(FlowEngine.reviews(of: pr, flow: flow).last?.head == id)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
        #expect(FlowEngine.review(fromFirstLine: "## Review: approve (head \(id.uppercased()))",
            headings: ["## Review:"])?.head == id)
    }

    @Test(arguments: 1...12)
    func postedReviewExpandsOnlyTheFirstLineDigits(scenario: Int) {
        let h = F.head, h8 = String(F.head.prefix(8)), h12 = String(F.head.prefix(12))
        let message: String
        let expected: String?
        switch scenario {
        case 1:
            message = "## Review: approve (head \(h8))\nFindings\n  "
            expected = "## Review: approve (head \(h))\nFindings"
        case 2:
            message = "## Review: approve (head \(h8.uppercased()))"
            expected = "## Review: approve (head \(h))"
        case 3:
            message = "## Review: changes (head \(h12); high-risk: x)\nSee (head \(h12))"
            expected = "## Review: changes (head \(h); high-risk: x)\nSee (head \(h12))"
        case 4:
            message = "## Review: approve (head `\(h8)`)"
            expected = "## Review: approve (head `\(h)`)"
        case 5:
            message = "## Review: approve (head \(h.prefix(39)))"
            expected = "## Review: approve (head \(h))"
        case 6: message = "## Review: approve (head \(h))\nBody"; expected = message
        case 7: message = "## Review: approve (head \(h.uppercased()))"; expected = message
        case 8: message = "## Review: approve (head \(F.other.prefix(8)))"; expected = nil
        case 9: message = "## Review: approve (head \(F.other))"; expected = nil
        case 10: message = "## Review: approve (head \(h)a)"; expected = nil
        case 11: message = "\n## Review: approve (head \(h8))"; expected = nil
        default:
            // Threat 4 specifically names a seven-digit agent claim.
            message = "## Review: approve (head \(h.prefix(7)))"
            expected = "## Review: approve (head \(h))"
        }
        for startedHead in [h, h.uppercased()] {
            #expect(DispatchPlanner.reviewComment(fromFinalMessage: message,
                headings: ["## Review:"], head: startedHead) == expected)
        }
    }

    @Test func resolvableShortAndUppercaseIDsCannotCreateADelta() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("full-id-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin.git"), clone = root.appendingPathComponent("clone")
        try await F.git(["init", "--bare", "--initial-branch=main", origin.path], in: root)
        try await F.git(["clone", origin.path, clone.path], in: root)
        try await F.git(["commit", "--allow-empty", "-m", "Base"], in: clone)
        try await F.git(["push", "origin", "main"], in: clone)
        try await F.git(["checkout", "-b", "feature"], in: clone)
        try await F.git(["commit", "--allow-empty", "-m", "Reviewed"], in: clone)
        let x = try await F.git(["rev-parse", "HEAD"], in: clone)
        try await F.git(["commit", "--allow-empty", "-m", "Later"], in: clone)
        let short = String(x.prefix(12))
        #expect(try await F.git(["rev-parse", "--verify", short], in: clone) == x)
        for reviewed in [short, x.uppercased(), "", String(x.prefix(39)), x + "a", "not-a-commit"] {
            let delta = await PREvidence.delta(worktree: clone, base: "main", reviewed: reviewed,
                ghPath: "/usr/bin/false", runner: ProcessRunner())
            #expect(delta.reviewed == nil)
            #expect(delta.problem == nil)
            #expect(!delta.scopeIsDelta)
        }
        let delta = await PREvidence.delta(worktree: clone, base: "main", reviewed: x,
            ghPath: "/usr/bin/false", runner: ProcessRunner())
        #expect(delta.reviewed == x)
        #expect(delta.isAncestor)
    }

    @Test(arguments: [7, 12, 40])
    func emptyDeltaExplainsShortIDInsteadOfMissingObject(length: Int) {
        let review = Review(heading: "## Review:", verdict: .approve, head: String(F.head.prefix(length)),
                            author: "me", createdAt: F.now)
        let packet = PREvidence.text(pr: F.pr(), local: .init(), receipts: [],
            previous: .init(review: review, findings: [], delta: .init()), reviewHeadings: ["## Review:"], now: F.now)
        let expected = length == 40 ? "- reviewed head: not in this checkout" :
            "- reviewed head: unknown: the review names \(length) of the 40 digits of a commit id"
        #expect(packet.components(separatedBy: "\n").contains(expected))
        #expect(packet.contains("scope: full"))
        if length < 40 { #expect(!packet.contains("not in this checkout")) }
    }
}
