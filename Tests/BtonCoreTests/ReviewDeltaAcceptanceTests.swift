@testable import BtonCore
import Foundation
import Testing

struct ReviewDeltaAcceptanceTests {
    fileprivate static let now = Date(timeIntervalSince1970: 1793235723)
    fileprivate static let table = #"""
    | ID | Severity | Location | Finding and evidence |
    | --- | --- | --- | --- |
    | R1 | P1 | Sources/A.swift:12 | Crash when nil |
    | R2 | P3 | docs/B.md | Typo \| wording |
    """#
    private static let findings: [PREvidence.Finding] = [
        .init(id: "R1", severity: "P1", location: "Sources/A.swift:12", text: "Crash when nil"),
        .init(id: "R2", severity: "P3", location: "docs/B.md", text: #"Typo \| wording"#)]

    private static func flow() throws -> Flow {
        let object: [String: Any] = ["version": 1, "base": "main",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": ["small": [["heading": "## Review:"]]],
            "decision": ["heading": "## Decision:", "move": "decide", "by": ["lead"]],
            "fixed": "Fixed:", "moves": [], "dispatch": [:]]
        return try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private static func pr(comments: [PullRequestComment] = []) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "dev",
            authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/7")!,
            headSha: String(repeating: "b", count: 40), headRef: "feature", baseRef: "main",
            body: "Hello", isDraft: false, labels: [], assignees: [], comments: comments, updatedAt: now)
    }

    private static func previous(delta: PREvidence.Delta?, findings: [PREvidence.Finding] = ReviewDeltaAcceptanceTests.findings)
        -> PREvidence.PreviousReview {
        .init(review: Review(heading: "## Review:", verdict: .changes, head: "aaaaaaa",
            author: "rev", createdAt: now), findings: findings, delta: delta)
    }

    private static func packet(_ previous: PREvidence.PreviousReview?) -> String {
        PREvidence.text(pr: pr(), local: .init(), receipts: [], previous: previous,
            reviewHeadings: ["## Review:"], now: now)
    }

    // a
    @Test func parsesPostedFindings() {
        #expect(PREvidence.findings(in: "## Review: changes (head aaaaaaa)\n\n" + Self.table) == Self.findings)
        #expect(PREvidence.findings(in: "| ID | Severity | Location | Finding |\n| --- | --- | --- | --- |\n| None | | | | ").isEmpty)
        #expect(PREvidence.findings(in: "No findings table here.").isEmpty)
    }

    // b
    @Test func latestReviewExcludesDecisionsAndUntrustedComments() throws {
        let flow = try Self.flow()
        let older = PullRequestComment(author: "rev", authorAssociation: "MEMBER",
            body: "## Review: changes (head aaaaaaa)\n\n| ID | Severity | Location | Finding |\n| None | | | |",
            createdAt: Self.now.addingTimeInterval(-2))
        let newer = PullRequestComment(author: "rev", authorAssociation: "MEMBER",
            body: "## Review: approve (head bbbbbbb)\n\n" + Self.table,
            createdAt: Self.now.addingTimeInterval(-1))
        let decision = PullRequestComment(author: "lead", authorAssociation: "MEMBER",
            body: "## Decision: approve (head bbbbbbb)", createdAt: Self.now)
        let previous = try #require(PREvidence.previousReview(pr: Self.pr(comments: [decision, newer, older]), flow: flow))
        #expect(previous.review.head == "bbbbbbb")
        #expect(previous.review.heading == "## Review:")
        #expect(previous.review.verdict == .approve)
        #expect(previous.review.createdAt == newer.createdAt)
        #expect(previous.findings == Self.findings)
        #expect(PREvidence.previousReview(pr: Self.pr(comments: [decision]), flow: flow) == nil)
        let untrusted = PullRequestComment(author: "outsider", authorAssociation: "NONE",
            body: newer.body, createdAt: Self.now)
        #expect(PREvidence.previousReview(pr: Self.pr(comments: [untrusted]), flow: flow) == nil)
    }

    @Test func sameTimestampFindingsMatchSelectedReviewIdentity() throws {
        let flow = try Self.flow()
        let identities: [(String, String, String, String, String)] = [
            ("rev", "MEMBER", "## Review:", "changes", "aaaaaaa"),
            ("other", "MEMBER", "## Review:", "changes", "aaaaaaa"),
            ("rev", "MEMBER", "## Review:", "approve", "aaaaaaa"),
            ("rev", "MEMBER", "## Review:", "changes", "bbbbbbb"),
            ("lead", "MEMBER", "## Decision:", "approve", "bbbbbbb"),
            ("rev", "NONE", "## Review:", "changes", "aaaaaaa")]
        let comments = identities.enumerated().map { index, identity in
            PullRequestComment(author: identity.0, authorAssociation: identity.1,
                body: "\(identity.2) \(identity.3) (head \(identity.4))\n\n"
                    + "| ID | Severity | Location | Finding |\n| --- | --- | --- | --- |\n"
                    + "| F\(index) | P2 | file.swift | Identity \(index) |", createdAt: Self.now)
        }
        // Exercise every possible first comment, in both directions, without assuming a tie winner.
        for ordered in [comments, Array(comments.reversed())] {
            for offset in ordered.indices {
                let rotated = Array(ordered[offset...]) + Array(ordered[..<offset])
                let selected = try #require(PREvidence.previousReview(pr: Self.pr(comments: rotated), flow: flow))
                let index = try #require(identities.firstIndex {
                    $0.1 == "MEMBER" && $0.0 == selected.review.author
                        && $0.2 == selected.review.heading && $0.3 == selected.review.verdict.rawValue
                        && $0.4 == selected.review.head
                })
                #expect(selected.review.createdAt == Self.now)
                #expect(selected.review.heading == "## Review:")
                #expect(selected.findings == [.init(id: "F\(index)", severity: "P2",
                    location: "file.swift", text: "Identity \(index)")])
            }
        }
    }

    @Test(ProcessBound()) func failedDiffForcesFullReview() async throws {
        let f = try await ReviewDeltaFixture.make()
        defer { f.remove() }
        _ = try await ReviewDeltaFixture.git(["config", "diff.algorithm", "invalid-bton-algorithm"], in: f.clone)
        let probe = try await ProcessRunner().run("/usr/bin/git",
            ["diff", "--numstat", "-z", f.reviewed, "HEAD"], in: f.clone,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(30))
        try #require(probe.status != 0, "The fixture must actually fail git diff")
        let delta = await PREvidence.delta(worktree: f.clone, base: "main", reviewed: f.reviewed,
            ghPath: f.gh.path, runner: ProcessRunner())
        #expect(delta.reviewed == f.reviewed)
        #expect(delta.isAncestor)
        #expect(delta.baseContextChanged == false)
        #expect(delta.problem?.contains("git diff") == true)
        #expect(!delta.scopeIsDelta)
        let packet = Self.packet(Self.previous(delta: delta))
        #expect(packet.contains("scope: full"))
        #expect(!packet.contains("scope: delta"))
        #expect(packet.contains("### Changed since the reviewed head\n\nunavailable\n"))
        for id in ["R1", "R2"] {
            #expect(packet.components(separatedBy: "\n").contains {
                $0.hasPrefix("| \(id) |") && $0.hasSuffix("| unknown |")
            })
        }
    }

    @Test func previousReviewBudgetPreservesDiscussion() throws {
        let oversized = String(repeating: "x", count: PREvidence.cellLimit + 100)
        let changes: [PREvidence.Change] = (0..<100).map {
            .init(path: "file-\($0)-" + String(repeating: "p", count: 100), added: 1, deleted: 0)
        }
        let delta = PREvidence.Delta(reviewed: String(repeating: "a", count: 40), isAncestor: true,
            commitsSince: 2, baseContextChanged: false, changed: changes)
        let newest = PullRequestComment(author: "dev", authorAssociation: "MEMBER",
            body: "Newest discussion sentinel", createdAt: Self.now)
        for largeCells in [true, false] {
            let findings: [PREvidence.Finding] = (0..<51).map {
                .init(id: "F\($0)", severity: largeCells ? oversized : "P2",
                    location: largeCells ? oversized : "a", text: largeCells ? oversized : "b")
            }
            let packet = PREvidence.text(pr: Self.pr(comments: [newest]), local: .init(), receipts: [],
                previous: Self.previous(delta: delta, findings: findings), reviewHeadings: ["## Review:"], now: Self.now)
            let start = try #require(packet.range(of: "## Previous review\n\n"))
            let end = try #require(packet.range(of: "\n## Discussion", range: start.upperBound..<packet.endIndex))
            let section = String(packet[start.upperBound..<end.lowerBound])
            #expect(section.count <= PREvidence.previousLimit)
            let listingStart = try #require(section.range(of: "### Changed since the reviewed head\n\n"))
            let listingEnd = try #require(section.range(of: "\n### Findings as posted"))
            let listing = String(section[listingStart.upperBound..<listingEnd.lowerBound])
            #expect(listing.count <= PREvidence.previousChangedCharacterLimit)
            let fileRows = listing.components(separatedBy: "\n").filter { $0.hasPrefix("1\t0\t") }
            #expect(!fileRows.isEmpty && fileRows.count < changes.count)
            #expect(listing.contains("\(changes.count - fileRows.count) more files not listed\n"))
            let rows = section.components(separatedBy: "\n").filter { $0.hasPrefix("| F") }
            #expect(!rows.isEmpty && rows.count <= PREvidence.findingLimit)
            #expect(section.contains("\(findings.count - rows.count) more findings not listed\n"))
            if largeCells {
                let cut = String(oversized.prefix(PREvidence.cellLimit)) + " [cut by Bton]"
                #expect(rows.allSatisfy { $0.contains("| \(cut) | \(cut) | \(cut) |") })
                #expect(!section.contains(oversized))
            } else {
                #expect(rows.count == PREvidence.findingLimit)
                #expect(section.contains("1 more findings not listed\n"))
            }
            let discussion = String(packet[end.upperBound...])
            #expect(discussion.contains("Hello"))
            #expect(discussion.contains("Newest discussion sentinel"))
            #expect(packet.count <= 24_000)
        }
    }

    // c
    @Test(ProcessBound()) func computesDeltaFromRealGitHistory() async throws {
        let f = try await ReviewDeltaFixture.make()
        defer { f.remove() }
        let delta = await PREvidence.delta(worktree: f.clone, base: "main", reviewed: f.reviewed,
            ghPath: f.gh.path, runner: ProcessRunner())
        #expect(delta.reviewed == f.reviewed)
        #expect(delta.isAncestor)
        #expect(delta.commitsSince == 2)
        #expect(delta.baseContextChanged == false)
        #expect(delta.changed.contains { $0.path == "later.txt" })
        #expect(delta.scopeIsDelta)
        let unknown = await PREvidence.delta(worktree: f.clone, base: "main",
            reviewed: String(repeating: "0", count: 40), ghPath: f.gh.path, runner: ProcessRunner())
        #expect(unknown.reviewed == nil)
        #expect(!unknown.scopeIsDelta)
        #expect(unknown.problem == nil)

        _ = try await ReviewDeltaFixture.git(["checkout", "-b", "main-advanced", f.baseTip], in: f.clone)
        try "base advance\n".write(to: f.clone.appendingPathComponent("base-later.txt"), atomically: true, encoding: .utf8)
        _ = try await ReviewDeltaFixture.git(["add", "."], in: f.clone)
        try await ReviewDeltaFixture.commit("Advance main", in: f.clone)
        let other = try await ReviewDeltaFixture.git(["rev-parse", "HEAD"], in: f.clone)
        _ = try await ReviewDeltaFixture.git(["push", "origin", "HEAD:refs/heads/main"], in: f.clone)
        _ = try await ReviewDeltaFixture.git(["fetch", "origin"], in: f.clone)
        _ = try await ReviewDeltaFixture.git(["checkout", "feature"], in: f.clone)
        let divergent = await PREvidence.delta(worktree: f.clone, base: "main", reviewed: other,
            ghPath: f.gh.path, runner: ProcessRunner())
        #expect(divergent.reviewed == other)
        #expect(!divergent.isAncestor)
        #expect(!divergent.scopeIsDelta)
        _ = try await ReviewDeltaFixture.git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
            "-c", "commit.gpgsign=false", "merge", "--no-edit", "origin/main"], in: f.clone)
        let merged = await PREvidence.delta(worktree: f.clone, base: "main", reviewed: f.reviewed,
            ghPath: f.gh.path, runner: ProcessRunner())
        #expect(merged.baseContextChanged == true)
        #expect(!merged.scopeIsDelta)
    }

    // d
    @Test func packetStatesReviewScopeAndFindingLocations() throws {
        #expect(Self.packet(nil).contains("## Previous review\n\nnone"))
        let delta = PREvidence.Delta(reviewed: String(repeating: "a", count: 40), isAncestor: true,
            commitsSince: 2, baseContextChanged: false,
            changed: [.init(path: "Sources/A.swift", added: 1, deleted: 0)])
        let packet = Self.packet(Self.previous(delta: delta))
        for value in ["- ## Review: changes (head aaaaaaa) by rev at 2026-10-29T01:02:03Z",
                      "an ancestor of HEAD, 2 commits since", "base context: unchanged", "scope: delta",
                      "| R1 | P1 | Sources/A.swift:12 | Crash when nil | yes |"] {
            #expect(packet.contains(value), "Missing: \(value)")
        }
        let rows = packet.components(separatedBy: "\n")
        #expect(rows.contains { $0.hasPrefix("| R2 |") && $0.hasSuffix("| no |") })
        let checks = try #require(packet.range(of: "## Checks passed on this head"))
        let previous = try #require(packet.range(of: "## Previous review"))
        let discussion = try #require(packet.range(of: "## Discussion"))
        #expect(checks.lowerBound < previous.lowerBound && previous.lowerBound < discussion.lowerBound)
        let unavailable = Self.packet(Self.previous(delta: .init()))
        #expect(unavailable.contains("reviewed head: not in this checkout"))
        #expect(unavailable.contains("scope: full"))
        let unknownRows = unavailable.components(separatedBy: "\n")
        for id in ["R1", "R2"] {
            #expect(unknownRows.contains { $0.hasPrefix("| \(id) |") && $0.hasSuffix("| unknown |") })
        }
        let changed = try #require(unavailable.components(separatedBy: "### Changed since the reviewed head\n").last)
        #expect(changed.components(separatedBy: "### Findings as posted")[0]
            .trimmingCharacters(in: .whitespacesAndNewlines) == "unavailable")
        var rebased = delta
        rebased.baseContextChanged = true
        let full = Self.packet(Self.previous(delta: rebased))
        #expect(full.contains("changed: the PR was rebased or merged its base"))
        #expect(full.contains("scope: full"))
    }

    // e
    @Test func findingCannotInjectDiscussionHeading() {
        let finding = PREvidence.Finding(id: "R1", severity: "P1", location: "Sources/A.swift:12",
            text: "Before\n## Discussion\nAfter")
        let packet = Self.packet(Self.previous(delta: nil, findings: [finding]))
        let lines = packet.components(separatedBy: "\n")
        #expect(lines.filter { $0.hasPrefix("## Discussion") } == ["## Discussion"])
        #expect(lines.contains { $0.hasPrefix("| R1 |") && $0.contains("## Discussion") && $0.hasSuffix("| unknown |") })
    }

    // f
    @Test(ProcessBound()) func dispatcherIncludesPreviousReviewDelta() async throws {
        let f = try await ReviewDeltaFixture.make()
        defer { f.remove() }
        let job = try await f.dispatch(flow: Self.flow())
        #expect(job.status == .succeeded, Comment(rawValue: job.detail ?? ""))
        let packet = try String(contentsOf: f.root.appendingPathComponent("scratch-copy/pr-evidence.md"), encoding: .utf8)
        #expect(packet.contains("## Previous review"))
        #expect(packet.contains("scope: delta"))
        #expect(packet.contains("| R1 |"))
    }

    // g
    @Test func playbookUsesPreviousReviewScope() {
        #expect(PRPlaybook.version == 8)
        #expect(PRPlaybook.text(for: "review").contains("Previous review"))
        #expect(PRPlaybook.text(for: "review").contains("scope"))
    }
}

// Private copy of EvidenceFixture, with two commits since the reviewed head.
private struct ReviewDeltaFixture {
    let root: URL
    let clone: URL
    let head: String
    let reviewed: String
    let baseTip: String
    var gh: URL { root.appendingPathComponent("gh") }
    var home: BtonHome { BtonHome(environment: ["BTON_HOME": root.appendingPathComponent("home").path]) }

    static func make() async throws -> Self {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pr-evidence-\(UUID())")
        let clone = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        do {
            _ = try await git(["init", "--bare", "--initial-branch=main", root.appendingPathComponent("origin.git").path], in: root)
            _ = try await git(["clone", root.appendingPathComponent("origin.git").path, clone.path], in: root)
            try "old\n".write(to: clone.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            _ = try await git(["add", "."], in: clone)
            try await commit("Base", in: clone)
            let baseTip = try await git(["rev-parse", "HEAD"], in: clone)
            _ = try await git(["push", "origin", "HEAD:refs/heads/main"], in: clone)
            _ = try await git(["update-ref", "refs/remotes/origin/main", baseTip], in: clone)
            _ = try await git(["checkout", "-b", "feature"], in: clone)
            try "one\ntwo\n".write(to: clone.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
            try "new\n".write(to: clone.appendingPathComponent("original.txt"), atomically: true, encoding: .utf8)
            _ = try await git(["add", "."], in: clone)
            try await commit("PR changes", in: clone)
            let reviewed = try await git(["rev-parse", "HEAD"], in: clone)
            try "later\n".write(to: clone.appendingPathComponent("later.txt"), atomically: true, encoding: .utf8)
            _ = try await git(["add", "."], in: clone)
            try await commit("Later change", in: clone)
            _ = try await git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
                "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "Follow-up"], in: clone)
            let head = try await git(["rev-parse", "HEAD"], in: clone)
            _ = try await git(["push", "origin", "HEAD:refs/pull/7/head"], in: clone)
            let f = Self(root: root, clone: clone, head: head, reviewed: reviewed, baseTip: baseTip)
            // Same local-ref GitHub stand-in as the lease fixture; no network or credentials.
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' "HEAD_VALUE"
              exit 0
            fi
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
            """#.replacingOccurrences(of: "HEAD_VALUE", with: head)
            try executable(script, at: f.gh)
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func dispatch(flow: Flow) async throws -> Job {
        let agent = root.appendingPathComponent("codex")
        let script = """
        #!/bin/sh
        set -eu
        printf '%s\\n' "$@" > '\(root.appendingPathComponent("agent-argv").path)'
        dir=$(printf '%s\\n' "$@" | sed -n 's/^Your scratch directory is \\(.*\\): the data files.*/\\1/p' | head -1)
        if [ -n "$dir" ]; then cp -R "$dir" '\(root.appendingPathComponent("scratch-copy").path)'; fi
        exit 0
        """
        try Self.executable(script, at: agent)
        let github = GitHubClient(ghPath: gh.path)
        let remote = root.appendingPathComponent("origin.git").path
        let leases = try LeaseStore(home: home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
        let jobs = try JobStore(home: home)
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: jobs, home: home, log: { _ in })
        let pr = PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic PR", author: "owner",
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/7")!, headSha: head,
            headRef: "feature", baseRef: "main", body: "Hello", isDraft: false, labels: [], assignees: [], comments: [PullRequestComment(author: "rev", authorAssociation: "MEMBER",
                body: "## Review: changes (head \(reviewed))\n\n" + ReviewDeltaAcceptanceTests.table,
                createdAt: ReviewDeltaAcceptanceTests.now)], updatedAt: .now)
        var candidate = DispatchCandidate(target: .pullRequest(pr),
            move: Move(name: "review", owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: pr.repo, item: "pr-7", move: "review", head: head), agent: "codex",
            prompt: "Synthetic task", command: nil, postComment: false, timeout: .seconds(30))
        candidate.skipsChecks = true
        // Keep scratch present in both cases so supervision exclusion cannot pass merely
        // because the fake agent had no scratch directory to copy.
        candidate.attachments = ["control.txt": "fixture"]
        let outcome = await dispatcher.dispatch(candidate, clone: clone, flow: flow,
            agents: ["codex": AgentTemplate(argv: [agent.path, "exec", "--", "{prompt}"])])
        guard case .started = outcome else { throw DispatchError.worktree("Evidence fixture did not start: \(outcome)") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let job = jobs.all().first(where: { $0.status != .running }),
               !FileManager.default.fileExists(atPath: jobs.lockURL(job.id).path) {
                let control = root.appendingPathComponent("scratch-copy/control.txt")
                #expect(try String(contentsOf: control, encoding: .utf8) == "fixture")
                return job
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        for job in jobs.all() { await dispatcher.stop(job.id) }
        throw DispatchError.worktree("Evidence fixture did not finish")
    }

    private static func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func commit(_ message: String, in directory: URL) async throws {
        _ = try await git(["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "-m", message], in: directory)
    }

    @discardableResult
    static func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git", arguments, in: directory,
            environment: ["GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            timeout: .seconds(30))
        try #require(result.status == 0, "git \(arguments): \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
