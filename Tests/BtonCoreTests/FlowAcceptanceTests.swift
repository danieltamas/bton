import BtonCore
import Foundation
import Testing

// Synthetic data in the exact envelope printed by `gh api graphql`.
enum FlowFixture {
    static let head = "d67db2a8" + String(repeating: "a", count: 32)
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func data(_ example: String = "team", overrides: [String: Any] = [:]) throws -> Data {
        let data = try Data(contentsOf: root.appendingPathComponent("examples/\(example).flow.json"))
        if overrides.isEmpty { return data }
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: json)
    }

    static func flow(withoutReviewers: Bool = false) throws -> Flow {
        var json = try #require(JSONSerialization.jsonObject(with: data()) as? [String: Any])
        if withoutReviewers { json.removeValue(forKey: "reviewers") }
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: json))
    }

    struct Comment: Sendable {
        var body: String
        var author: String? = "dev-c"
        var hour: Int = 12
    }

    static func graphql(number: Int = 325, author: String? = "dev-b",
                        tier: String = "feature", body: String? = nil, draft: Bool = false,
                        labels: [String] = [], assignees: [String] = ["dev-c"],
                        head: String = head, base: String = "develop", association: String = "OWNER",
                        comments: [Comment] = []) throws -> Data {
        func login(_ value: String?) -> Any {
            value.map { ["login": $0] as Any } ?? NSNull()
        }
        let node: [String: Any] = [
            "number": number, "title": "Synthetic PR", "url": "https://github.com/o/r/pull/\(number)",
            "isDraft": draft, "headRefOid": head, "headRefName": "feat/x", "baseRefName": base,
            "body": body ?? "**Tier:** \(tier)", "updatedAt": "2026-10-19T11:00:00Z",
            "authorAssociation": association, "author": login(author),
            "labels": ["nodes": labels.map { ["name": $0] }],
            "assignees": ["nodes": assignees.map { ["login": $0] }],
            "comments": ["nodes": comments.map { comment -> [String: Any] in
                ["author": login(comment.author), "body": comment.body,
                 "authorAssociation": "MEMBER",
                 "createdAt": String(format: "2026-10-19T%02d:00:00Z", comment.hour)]
            }]
        ]
        return try JSONSerialization.data(withJSONObject: ["data": [
            "viewer": ["login": "lead-dev"], "repository": [
                "defaultBranchRef": ["name": "main"], "pullRequests": ["nodes": [node]]
            ]
        ]])
    }

    static func pr(tier: String = "feature", draft: Bool = false, labels: [String] = [],
                   assignees: [String] = ["dev-c"], number: Int = 325,
                   author: String? = "dev-b", head: String = head, base: String = "develop",
                   association: String = "OWNER", comments: [Comment] = []) throws -> PullRequest {
        let result = try GitHubClient.decodeOpenPullRequests(
            graphql(number: number, author: author, tier: tier, draft: draft, labels: labels,
                    assignees: assignees, head: head, base: base, association: association, comments: comments),
            repo: "o/r")
        return try #require(result.pullRequests.first)
    }
}

@Suite(ProcessBound())
struct FlowAcceptanceTests {
    @Test func absentShiftCapsKeepTheExistingDefaults() throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: ["caps": [:]])).flow)
        #expect(flow.issuesPerDay == 20)
        #expect(flow.issueCooldown == 6 * 3600)
        #expect(flow.maxRulings == 2)
        #expect(IssueDecisions.maxRulings == 2)
        #expect(flow.costPerJob == nil)
        #expect(try FlowFixture.flow().issuesPerDay == 20)
        #expect(try FlowFixture.flow().issueCooldown == 6 * 3600)
    }

    @Test func capsWithOnlyTheNewKeysDecodeWithoutPRLimits() throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "caps": ["issuesPerDay": 2, "issueCooldownHours": 1.5, "costPerJob": 1.25]
        ])).flow)
        #expect(flow.caps?.openPullRequestsPerDeveloper == nil)
        #expect(flow.caps?.openPullRequestsTeam == nil)
        #expect(flow.issuesPerDay == 2)
        #expect(flow.issueCooldown == 5400)
        #expect(flow.costPerJob == Decimal(string: "1.25"))
    }

    @Test func aFlowCanChooseOneRulingInsteadOfTheDefaultTwo() throws {
        // No existing engine fixture drives decideCandidates. Per Part A2, cover the accessor
        // here; enforcing the limit since the last human comment in Engine is not exercised.
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "decide": ["by": ["lead-dev"], "maxRulings": 1]
        ])).flow)
        #expect(flow.maxRulings == 1)
        #expect(flow.decide?.maxRulings == 1)
    }

    @Test(arguments: [
        ("caps", "issuesPerDay", 0.0), ("caps", "issuesPerDay", -1.0),
        ("caps", "issueCooldownHours", 0.0), ("caps", "issueCooldownHours", -0.5),
        ("decide", "maxRulings", 0.0), ("decide", "maxRulings", -1.0)
    ])
    func nonpositiveShiftLimitsAreInvalidAndNameTheKey(section: String, key: String, value: Double) throws {
        var settings: [String: Any] = [key: value]
        if section == "decide" { settings["by"] = ["lead-dev"] }
        guard case let .invalid(message) = Flow.load(try FlowFixture.data(overrides: [section: settings])) else {
            Issue.record("\(key): \(value) must make the flow invalid"); return
        }
        #expect(message.contains(key), Comment(rawValue: message))
    }

    @Test(arguments: ["failure", "pending", "success", "missing"])
    func checksRedSelectsFixOnlyForAFailedCheck(scenario: String) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "moves": [["move": "fix", "when": ["checks_red"], "who": "author"]]
        ])).flow)
        var pr = try FlowFixture.pr()
        pr.changedFilesTruncated = false
        pr.checksTruncated = false
        pr.checks = []
        if let state = CheckResult.State(rawValue: scenario) {
            pr.checks = [CheckResult(name: "gate", state: state),
                         CheckResult(name: "green", state: .success), CheckResult(name: "waiting", state: .pending)]
        }
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == (scenario == "failure" ? "fix" : nil))
    }

    @Test(arguments: ["gate", "lint", "other", "pending", "missing"])
    func namedChecksRedRequiresOneOfItsNamedChecksToFail(scenario: String) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "moves": [["move": "fix", "when": ["checks_red:gate,lint"], "who": "author"]]
        ])).flow)
        var pr = try FlowFixture.pr()
        pr.changedFilesTruncated = false
        pr.checksTruncated = false
        pr.checks = scenario == "missing" ? [] : [CheckResult(
            name: scenario == "pending" ? "gate" : scenario,
            state: scenario == "pending" ? .pending : .failure)]
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == (["gate", "lint"].contains(scenario) ? "fix" : nil))
    }

    @Test(arguments: ["checks_red", "checks_red:gate"], ["checks truncated", "files truncated", "workflow"])
    func checksRedNeverUsesAnUnreadableRollup(predicate: String, unreadable: String) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "moves": [["move": "fix", "when": [predicate], "who": "author"]]
        ])).flow)
        var pr = try FlowFixture.pr()
        pr.checks = [CheckResult(name: "gate", state: .failure)]
        pr.checksTruncated = unreadable == "checks truncated"
        pr.changedFilesTruncated = unreadable == "files truncated"
        pr.changedFiles = unreadable == "workflow" ? [".github/workflows/gate.yml"] : []
        #expect(FlowEngine.move(for: pr, flow: flow) == nil)
    }

    @Test(arguments: [false, true])
    func redChecksPlaceholderContainsOnlyFailedHeadCheckNames(hasFailures: Bool) throws {
        let flow = try #require(Flow.load(FlowFixture.data(overrides: [
            "moves": [["move": "fix", "when": ["no_review_or_response_newer"], "who": "author"]],
            "dispatch": ["fix": ["agent": "claude", "prompt": "{red_checks}"]]
        ])).flow)
        var pr = try FlowFixture.pr()
        pr.checks = [CheckResult(name: "green", state: .success), CheckResult(name: "waiting", state: .pending)]
        if hasFailures { pr.checks += [CheckResult(name: "gate", state: .failure), CheckResult(name: "lint", state: .failure)] }
        let candidate = try #require(DispatchPlanner.candidates([pr], flow: flow, me: pr.author, repo: pr.repo).first)
        let prompt = try #require(candidate.prompt)
        let names = prompt.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        #expect(Set(names) == (hasFailures ? ["gate", "lint"] : []))
        if !hasFailures { #expect(prompt.isEmpty) }
    }

    @Test(arguments: ["team", "sandbox"])
    func examplesLoad(example: String) throws {
        guard case let .ready(flow) = Flow.load(try FlowFixture.data(example)) else {
            Issue.record("Example must load as ready"); return
        }
        #expect(flow.version == 1)
        #expect(flow.base == (example == "team" ? "develop" : "main"))
        if example == "team" {
            #expect(flow.moves.map(\.move) == ["decide", "finish", "resolve", "review", "merge", "decide", "fix"])
            #expect(flow.tier.marker == "Tier:")
            #expect(flow.tier.values == ["docs", "quick fix", "feature", "high-risk"])
            #expect(flow.tier.defaultTier == "feature")
            #expect(Set(flow.dispatch.keys) == Set(["review", "fix", "resolve", "merge"]))
            #expect(flow.dispatch["resolve"]?.checks == RuleChecks.none)
        }
    }

    @Test func loadStatuses() {
        guard case .none = Flow.load(nil) else { Issue.record("Missing flow must be none"); return }
        guard case .unsupported(version: 2) = Flow.load(Data(#"{"version":2}"#.utf8)) else {
            Issue.record("Unknown version must be unsupported"); return
        }
        guard case let .invalid(message) = Flow.load(Data(#"{"version":1}"#.utf8)) else {
            Issue.record("Incomplete v1 must be invalid"); return
        }
        #expect(!message.isEmpty)
    }

    @Test(arguments: 1...6)
    func whoseMove(row: Int) throws {
        let comments: [FlowFixture.Comment]
        switch row {
        case 4: comments = [.init(body: "## Review: approve (head d67db2a8)")]
        case 5: comments = [.init(body: "## Review: changes (head d67db2a8)", hour: 12),
                            .init(body: "## Review: blocked (head d67db2a8)", hour: 13)]
        case 6: comments = [.init(body: "## Review: changes needed (head d67db2a8)")]
        default: comments = []
        }
        // Row 1 also matches draft/no-review: ordered rules must select decide first.
        let pr = try FlowFixture.pr(draft: row <= 2, labels: row == 1 ? ["turn:lead"] : [], comments: comments)
        let move = try #require(FlowEngine.move(for: pr, flow: FlowFixture.flow()))
        #expect(move.name == ["decide", "finish", "review", "merge", "decide", "fix"][row - 1])
        #expect(move.owner == ["lead-dev", "dev-b", "dev-c", "dev-b", "lead-dev", "dev-b"][row - 1])
        #expect(move.tier == "feature")
        #expect(move.hasDispatch == [false, false, true, true, false, true][row - 1])
    }

    @Test(arguments: [
        ("quick fix", "## Independent review:", "dev-b", "merge", "dev-b", 1),
        ("feature", "## Review:", "dev-b", "review", "dev-c", 0),
        ("high-risk", "## Review:", "dev-b", "review", "dev-c", 0),
        ("feature", "## Independent review:", "dev-c", "review", "dev-c", 0)
    ])
    func tierControlsCounting(tier: String, heading: String, author: String,
                              name: String, owner: String, count: Int) throws {
        let flow = try FlowFixture.flow()
        let pr = try FlowFixture.pr(tier: tier, comments: [.init(body: "\(heading) approve (head d67db2a8)", author: author)])
        #expect(FlowEngine.reviews(of: pr, flow: flow).count == count)
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == name)
        #expect(move.owner == owner)
    }

    @Test(arguments: [
        ("## Review: changes needed (head abc1234)", "changes", "abc1234"),
        ("## Review: changes needed", "", ""),
        ("## Review (head abc1234)", "", ""),
        ("## Review: approve with nits (head 17784c62)", "approve", "17784c62"),
        ("## Independent review: approve (head 1d7d8b35; high-risk: waiting)", "approve", "1d7d8b35"),
        ("## Fixed: rebased (head `94836b2b`)", "", ""),
        ("## Review: approve (head `94836b2b`)", "approve", "94836b2b"),
        ("## Review: approve (head abc123)", "", ""),
        ("## Review: blocked (head abc1234)", "blocked", "abc1234"),
        ("## Review: APPROVE (head ABC1234)", "approve", "ABC1234"),
        ("## Review: approved (head abc1234)", "", ""),
        ("## Review: approve (head xyz1234)", "", ""),
        ("## Review: approve (head " + String(repeating: "a", count: 41) + ")", "", "")
    ])
    func headingParsing(line: String, verdict: String, head: String) {
        let review = FlowEngine.review(fromFirstLine: line, headings: ["## Review:", "## Independent review:"])
        if verdict.isEmpty { #expect(review == nil) } else {
            #expect(review?.verdict.rawValue == verdict)
            // Head matching is case insensitive; the spec does not require preserving casing.
            #expect(review?.head.lowercased() == head.lowercased())
            #expect(review?.heading == (line.hasPrefix("## Independent") ? "## Independent review:" : "## Review:"))
        }
    }

    @Test(arguments: [
        ("**Tier:** quick fix | feature | high-risk", "feature"),
        ("**Tier:** quick fix", "quick fix"), ("Tier: quick fix.", "quick fix"),
        ("**Tier: High-risk** (migration, PII).", "high-risk"), ("No tier line", "feature"),
        ("Tier: unknown\nTier: quick fix", "feature"),
        ("Tier: high-risk\nTier: quick fix", "high-risk"),
        ("Tier: quick fixes", "feature"), ("TIER: QUICK FIX", "quick fix")
    ])
    func tierParsing(body: String, expected: String) throws {
        #expect(FlowEngine.tier(of: body, rule: try FlowFixture.flow().tier) == expected)
    }

    @Test(arguments: ["push", "fixed", "second changes", "second blocked", "first blocked", "case head"])
    func reviewHistory(scenario: String) throws {
        let flow = try FlowFixture.flow()
        var comments = [FlowFixture.Comment(body: "## Review: changes (head d67db2a8)", hour: 12)]
        var head = FlowFixture.head
        var expected = "review"
        switch scenario {
        case "push":
            comments = [.init(body: "## Review: approve (head abc1234)")]
        case "fixed": comments.append(.init(body: "## Fixed: rebased (head `d67db2a8`)", hour: 13))
        case "second changes", "second blocked":
            comments.append(.init(body: "## Review: \(scenario == "second changes" ? "changes" : "blocked") (head d67db2a8)", hour: 13))
            expected = "decide"
        case "first blocked":
            comments = [.init(body: "## Review: blocked (head d67db2a8)")]; expected = "fix"
        default:
            comments = [.init(body: "## Review: approve (head D67DB2A8)")]
            head = FlowFixture.head.uppercased(); expected = "merge"
        }
        // Reverse API order so latest means creation time, not array position.
        let pr = try FlowFixture.pr(head: head, comments: Array(comments.reversed()))
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == expected)
        let reviews = FlowEngine.reviews(of: pr, flow: flow)
        #expect(reviews.map(\.createdAt) == reviews.map(\.createdAt).sorted())
    }

    @Test(arguments: 320...325)
    func rotation(number: Int) throws {
        let flow = try FlowFixture.flow()
        let pr = try FlowFixture.pr(assignees: [], number: number, author: "DEV-B")
        let expected = ["lead-dev", "dev-c"][number % 2]
        for _ in 0..<3 {
            let move = try #require(FlowEngine.move(for: pr, flow: flow))
            #expect(move.name == "review")
            #expect(move.owner == expected)
            #expect(move.ownerFromRotation)
        }
    }

    @Test func missingRotationAndExplicitAssignee() throws {
        let flow = try FlowFixture.flow(withoutReviewers: true)
        #expect(flow.reviewers == nil)
        let pr = try FlowFixture.pr(assignees: [])
        let move = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(move.name == "review")
        #expect(move.owner == nil)
        #expect(!move.ownerFromRotation)
        for login in ["lead-dev", "dev-b", "dev-c", "anyone"] {
            #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: login))
        }
        let assigned = try FlowFixture.pr(assignees: ["humanChoice", "another"])
        let assignedMove = try #require(FlowEngine.move(for: assigned, flow: FlowFixture.flow()))
        #expect(assignedMove.owner == "humanChoice")
        #expect(!assignedMove.ownerFromRotation)
    }

    @Test(arguments: ["review", "fix", "merge", "decide", "finish"])
    func dispatchGates(name: String) throws {
        let flow = try FlowFixture.flow()
        let comments: [FlowFixture.Comment] = name == "fix" || name == "merge"
            ? [.init(body: "## Review: \(name == "fix" ? "changes" : "approve") (head d67db2a8)")] : []
        for association in ["OWNER", "MEMBER", "COLLABORATOR", "CONTRIBUTOR", "NONE"] {
            for base in ["develop", "main"] {
                let pr = try FlowFixture.pr(draft: name == "finish", labels: name == "decide" ? ["turn:lead"] : [],
                                            base: base, association: association, comments: comments)
                let move = try #require(FlowEngine.move(for: pr, flow: flow))
                #expect(move.name == name)
                let owner = try #require(move.owner)
                #expect(move.isMine(owner.uppercased()))
                #expect(!move.isMine("someoneElse"))
                let allowed = ["review", "fix", "merge"].contains(name) && base == "develop"
                    && ["OWNER", "MEMBER", "COLLABORATOR"].contains(association)
                #expect(FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: owner.uppercased()) == allowed)
                #expect(!FlowEngine.isDispatchable(move, pr: pr, flow: flow, me: "someoneElse"))
            }
        }
    }

    @Test func botMarkersAndNonFirstLinesNeverCount() throws {
        let flow = try FlowFixture.flow()
        let pr = try FlowFixture.pr(comments: [
            .init(body: "## Review: approve (head d67db2a8)\n<!-- bton:fail key -->"),
            .init(body: "<!-- bton:stale key -->\n## Review: approve (head d67db2a8)"),
            .init(body: "Context\n## Review: approve (head d67db2a8)")
        ])
        #expect(pr.comments.count == 1)
        #expect(FlowEngine.reviews(of: pr, flow: flow).isEmpty)
        #expect(FlowEngine.move(for: pr, flow: flow)?.name == "review")
    }

    @Test func nullAuthorsDecode() throws {
        let pr = try FlowFixture.pr(author: nil, comments: [.init(body: "A deleted user's comment", author: nil)])
        #expect(pr.author == "ghost")
        #expect(pr.comments.count == 1)
        #expect(pr.comments.first?.author == nil)
    }
}
