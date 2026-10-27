import BtonCore
import Testing
import Foundation

private enum ReleaseData {
    static let repo = "synthetic/project"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var section: [String: Any] {
        ["from": "develop", "to": "main", "who": "owner", "when": ["features_waiting:1"]]
    }

    static func flowData(_ overrides: [String: Any] = [:]) throws -> Data {
        let release = section.merging(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: [
            "version": 1, "base": "develop",
            "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
            "reviews": [:], "fixed": "Fixed:", "moves": [], "dispatch": [:], "release": release
        ])
    }

    static func release(_ overrides: [String: Any] = [:]) throws -> Flow.Release {
        try #require(Flow.load(flowData(overrides)).flow?.release)
    }

    static func standing(_ status: FeatureStatus = .inDevelop, changes: [Int] = [428, 419]) -> FeatureStanding {
        .init(status: status, timeline: [.init(status: status, at: now, number: nil)],
              openIssues: 0, openPullRequests: 0, changes: changes)
    }

    static func report(waiting: Int = 1) throws -> FeatureReport {
        let areas: [[String: Any]] = [
            ["id": "z", "name": "Zeta", "paths": []],
            ["id": "empty", "name": "Empty", "paths": []],
            ["id": "a", "name": "Alpha", "paths": []]
        ]
        var features: [[String: Any]] = []
        for n in 0..<waiting {
            features.append(["id": "feature-\(n)", "name": "Feature \(n)", "summary": "Synthetic",
                             "area": n == 0 ? "z" : "a", "paths": [], "issues": [], "prs": []])
        }
        features.append(["id": "closed", "name": "Closed", "summary": "Synthetic", "area": "z",
                         "closed": "2026-10-20", "paths": [], "issues": [], "prs": []])
        features.append(["id": "building", "name": "Building", "summary": "Synthetic", "area": "a",
                         "paths": [], "issues": [], "prs": []])
        let json = try JSONSerialization.data(withJSONObject: ["version": 1, "areas": areas, "features": features])
        let registry = try JSONDecoder().decode(FeatureRegistry.self, from: json)
        var report = FeatureReport(repo: repo, registry: .ready(registry), hasRelease: true)
        for n in 0..<waiting { report.standings["feature-\(n)"] = standing() }
        report.standings["closed"] = standing()
        report.standings["building"] = standing(.building)
        report.aheadCommits = 10
        report.unreleasedSince = now.addingTimeInterval(-8 * 86_400)
        return report
    }

    static func pr(number: Int = 7, head: String = "develop", base: String = "main",
                   draft: Bool = false, files: [String] = [], author: String = "someone") -> PullRequest {
        var pr = PullRequest(repo: repo, number: number, title: "Synthetic {head} `text`", author: author,
            authorAssociation: "OWNER", url: URL(string: "https://example.invalid/pr/\(number)")!,
            headSha: "pinned-head", headRef: head, baseRef: base, body: "Untrusted text",
            isDraft: draft, labels: [], assignees: [], comments: [], updatedAt: now)
        pr.changedFiles = files
        return pr
    }

    static func job(repo: String = repo, move: String = "release", status: Job.Status = .running) -> Job {
        Job(id: UUID(), key: JobKey(repo: repo, item: "pr-99", move: move, head: "old"),
            agent: nil, startedAt: now, status: status)
    }

    static func candidate(release: Flow.Release, pr: PullRequest = pr(), me: String = "owner",
                          jobs: [Job] = [], prs: [PullRequest]? = nil,
                          startsMoves: Bool = false, pressed: Bool = true) -> DispatchCandidate? {
        Release.candidate(pr: pr, release: release, repo: repo, me: me, jobs: jobs,
                          pullRequests: prs ?? [pr], startsMoves: startsMoves, pressed: pressed)
    }
}

struct ReleaseParsingAcceptanceTests {
    @Test func validPredicates() {
        #expect(ReleasePredicate("ahead_commits:50") == .aheadCommits(50))
        #expect(ReleasePredicate("ahead_days:7") == .aheadDays(7))
        #expect(ReleasePredicate("features_waiting:5") == .featuresWaiting(5))
    }

    @Test(arguments: ["unknown:1", "ahead_commits:0", "ahead_commits:-1", "ahead_commits:x",
                      "ahead_days:0", "ahead_days:-7", "ahead_days:1.5", "features_waiting:0",
                      "features_waiting:-2", "features_waiting:no", "ahead_days", "ahead_days:1:2", ""])
    func invalidPredicate(text: String) { #expect(ReleasePredicate(text) == nil) }

    @Test func validBlockers() {
        #expect(ReleaseBlocker("release_pr_open") == .releasePROpen)
        #expect(ReleaseBlocker("pr_in_review_on_paths:migrations/**") == .prInReviewOnPaths("migrations/**"))
    }

    @Test(arguments: ["unknown", "release_pr_open:1", "pr_in_review_on_paths:",
                      "pr_in_review_on_paths:!migrations/**", ""])
    func invalidBlocker(text: String) { #expect(ReleaseBlocker(text) == nil) }
}

struct ReleaseFlowAcceptanceTests {
    @Test(arguments: ["unknown:1", "ahead_commits:0", "ahead_days:-1", "features_waiting:no"])
    func invalidWhen(entry: String) throws {
        guard case let .invalid(reason) = Flow.load(try ReleaseData.flowData(["when": [entry]])) else {
            Issue.record("Invalid predicate must invalidate the flow"); return
        }
        #expect(reason == "release.when: \(entry) is not a predicate")
    }

    @Test(arguments: ["unknown", "pr_in_review_on_paths:", "pr_in_review_on_paths:!migrations/**"])
    func invalidBlockedBy(entry: String) throws {
        guard case let .invalid(reason) = Flow.load(try ReleaseData.flowData(["blockedBy": [entry]])) else {
            Issue.record("Invalid blocker must invalidate the flow"); return
        }
        #expect(reason == "release.blockedBy: \(entry) is not a blocker")
    }

    @Test(arguments: [0, -1])
    func timeoutMustBePositive(minutes: Int) throws {
        guard case let .invalid(reason) = Flow.load(try ReleaseData.flowData(["timeoutMinutes": minutes])) else {
            Issue.record("Nonpositive timeout must invalidate the flow"); return
        }
        #expect(reason == "release.timeoutMinutes must be positive")
    }

    @Test func validReleaseLoads() throws {
        let release = try ReleaseData.release(["blockedBy": ["release_pr_open", "pr_in_review_on_paths:migrations/**"],
                                               "checks": [["bash", "scripts/check.sh"]], "timeoutMinutes": 1])
        #expect(release.from == "develop")
        #expect(release.to == "main")
        #expect(release.checks == [["bash", "scripts/check.sh"]])
    }
}

struct ReleaseStandingAcceptanceTests {
    @Test func oldestExactBranchPairRegardlessOfAuthor() throws {
        let release = try ReleaseData.release()
        let prs = [ReleaseData.pr(number: 20), ReleaseData.pr(number: 2, head: "feature"),
                   ReleaseData.pr(number: 1, base: "other"), ReleaseData.pr(number: 8, author: "another")]
        #expect(Release.pullRequest(prs, release: release)?.number == 8)
        #expect(Release.pullRequest(Array(prs.dropFirst().dropLast()), release: release) == nil)
    }

    @Test func standingPrecedence() throws {
        let release = try ReleaseData.release(["blockedBy": ["pr_in_review_on_paths:migrations/**"]])
        let report = try ReleaseData.report()
        let blocker = ReleaseData.pr(number: 9, head: "fix", base: "develop", files: ["migrations/001.sql"])
        #expect(Release.standing(release: release, report: report, pullRequests: [], now: ReleaseData.now)
                == .due("1 features waiting"))
        #expect(Release.standing(release: release, report: report, pullRequests: [blocker], now: ReleaseData.now)
                == .blocked("PR #9 touches migrations/**"))
        #expect(Release.standing(release: release, report: report, pullRequests: [blocker, ReleaseData.pr()], now: ReleaseData.now)
                == .open(number: 7, due: true))
        #expect(Release.standing(release: release, report: try ReleaseData.report(waiting: 0),
                                pullRequests: [ReleaseData.pr()], now: ReleaseData.now) == .open(number: 7, due: false))
        #expect(Release.standing(release: release, report: try ReleaseData.report(waiting: 0),
                                pullRequests: [], now: ReleaseData.now) == .waiting)
    }

    @Test func missingRegistryAndFailedFactsAreUnknown() throws {
        let release = try ReleaseData.release()
        let missing = FeatureReport(repo: ReleaseData.repo, registry: .none, hasRelease: true)
        var failed = try ReleaseData.report()
        failed.problem = "Could not read facts"
        for report in [nil, missing, failed] {
            #expect(Release.standing(release: release, report: report, pullRequests: [], now: ReleaseData.now) == .unknown)
        }
    }

    @Test(arguments: [9, 10, 11])
    func commitThreshold(count: Int) throws {
        var report = try ReleaseData.report()
        report.aheadCommits = count
        let release = try ReleaseData.release(["when": ["ahead_commits:10"]])
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now)
                == (count >= 10 ? "\(count) commits ahead" : nil))
    }

    @Test(arguments: [7 * 86_400 - 1, 7 * 86_400, 8 * 86_400])
    func daysUseUnreleasedSince(seconds: Int) throws {
        var report = try ReleaseData.report()
        report.unreleasedSince = ReleaseData.now.addingTimeInterval(-Double(seconds))
        report.lastRelease = ReleaseData.now.addingTimeInterval(-100 * 86_400)
        let release = try ReleaseData.release(["when": ["ahead_days:7"]])
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now)
                == (seconds >= 7 * 86_400 ? "\(seconds / 86_400) days ahead" : nil))
        report.unreleasedSince = nil
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now) == nil)
    }

    @Test(arguments: [4, 5, 6])
    func featureThreshold(count: Int) throws {
        let report = try ReleaseData.report(waiting: count)
        let release = try ReleaseData.release(["when": ["features_waiting:5"]])
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now)
                == (count >= 5 ? "\(count) features waiting" : nil))
    }

    @Test func firstMatchAndThirdPredicateReason() throws {
        var report = try ReleaseData.report(waiting: 5)
        report.unreleasedSince = ReleaseData.now.addingTimeInterval(-86_400)
        let release = try ReleaseData.release(["when": ["ahead_commits:50", "ahead_days:7", "features_waiting:5"]])
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now) == "5 features waiting")
        report.aheadCommits = 50
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now) == "50 commits ahead")
        report.aheadCommits = nil
        #expect(Release.dueReason(release: release, report: report, now: ReleaseData.now) == "5 features waiting")
    }

    @Test func blockerFiltersAndAnchoredGlob() throws {
        let release = try ReleaseData.release(["blockedBy": ["release_pr_open", "pr_in_review_on_paths:migrations/**"]])
        let ignored = [ReleaseData.pr(files: ["migrations/001.sql"]),
            ReleaseData.pr(number: 8, head: "fix", base: "develop", draft: true, files: ["migrations/001.sql"]),
            ReleaseData.pr(number: 9, head: "fix", base: "other", files: ["migrations/001.sql"]),
            ReleaseData.pr(number: 10, head: "fix", base: "develop", files: ["src/migrations/001.sql"])]
        #expect(Release.blockedReason(release: release, pullRequests: ignored) == nil)
        let blocker = ReleaseData.pr(number: 11, head: "fix", base: "develop", files: ["migrations/nested/001.sql"])
        #expect(Release.blockedReason(release: release, pullRequests: ignored + [blocker]) == "PR #11 touches migrations/**")
    }
}

struct ReleaseNotesAcceptanceTests {
    @Test(arguments: [0, 1, 2])
    func titleCountsOnlyIncludedFeatures(count: Int) throws {
        #expect(try ReleaseNotes.title(release: ReleaseData.release(), report: ReleaseData.report(waiting: count))
                == "Release develop -> main: \(count) feature\(count == 1 ? "" : "s")")
    }

    @Test func bodyOrderNumbersExclusionsAndFooter() throws {
        let body = ReleaseNotes.body(report: try ReleaseData.report(waiting: 2))
        #expect(body.split(separator: "\n").map(String.init) == """
        Release notes
        ## Zeta
        - Feature 0 (#419, #428)
        ## Alpha
        - Feature 1 (#419, #428)
        Opened by Bton.
        """.split(separator: "\n").map(String.init))
        #expect(!body.contains("Empty"))
        #expect(!body.contains("Closed"))
        #expect(!body.contains("Building"))
    }

    @Test func zeroFeatures() throws {
        let body = ReleaseNotes.body(report: try ReleaseData.report(waiting: 0))
        #expect(body.split(separator: "\n").map(String.init) == ["Release notes", "No registry features in this release.", "Opened by Bton."])
    }

    @Test func untrustedNamesAreVerbatimBodyText() throws {
        let json = #"{"version":1,"areas":[{"id":"a","name":"Area `name` {head}","paths":[]}],"features":[{"id":"f","name":"Keep {head} `literal`","summary":"Synthetic","area":"a","paths":[],"issues":[],"prs":[]}]}"#
        let registry = try JSONDecoder().decode(FeatureRegistry.self, from: Data(json.utf8))
        var report = FeatureReport(repo: ReleaseData.repo, registry: .ready(registry), hasRelease: true)
        report.standings["f"] = ReleaseData.standing()
        let body = ReleaseNotes.body(report: report)
        #expect(body.contains("## Area `name` {head}"))
        #expect(body.contains("- Keep {head} `literal` (#419, #428)"))
    }
}

struct ReleaseCandidateAcceptanceTests {
    @Test(arguments: ["default", "merge-commit", "fast-forward"])
    func shapeAndPinnedArgv(merge: String) throws {
        var fields: [String: Any] = ["checks": [["bash", "scripts/release.sh"]], "timeoutMinutes": 3]
        if merge != "default" { fields["merge"] = merge }
        let candidate = try #require(ReleaseData.candidate(release: ReleaseData.release(fields), me: "OWNER"))
        guard case let .pullRequest(pr) = candidate.target else { Issue.record("Expected PR target"); return }
        #expect(pr.number == 7)
        #expect(candidate.move.name == "release")
        #expect(candidate.move.owner == "OWNER")
        #expect(!candidate.move.ownerFromRotation)
        #expect(candidate.move.tier == "")
        #expect(candidate.move.hasDispatch)
        #expect(candidate.key == JobKey(repo: ReleaseData.repo, item: "pr-7", move: "release", head: "pinned-head"))
        #expect(candidate.agent == nil)
        #expect(!candidate.postComment)
        #expect(candidate.timeout == .seconds(180))
        #expect(candidate.checks == [["bash", "scripts/release.sh"]])
        #expect(candidate.commandBase == "main")
        #expect(candidate.pressed)
        let expected = merge == "fast-forward"
            ? ["git", "push", "origin", "pinned-head:refs/heads/main"]
            : ["gh", "pr", "merge", "7", "--repo", ReleaseData.repo, "--merge", "--match-head-commit", "pinned-head"]
        #expect(candidate.command == expected)
    }

    @Test func defaultsAndEmptyChecks() throws {
        let candidate = try #require(ReleaseData.candidate(release: ReleaseData.release()))
        #expect(Release.move == "release")
        #expect(Release.item == "release")
        #expect(Release.defaultTimeoutMinutes == 40)
        #expect(candidate.timeout == .seconds(2_400))
        #expect(candidate.checks?.isEmpty ?? true)
        let empty = try #require(ReleaseData.candidate(release: ReleaseData.release(["checks": [[String]]()])))
        #expect(empty.checks?.isEmpty ?? true)
    }

    @Test func ownerPressAndRunningJobAdmission() throws {
        let release = try ReleaseData.release(["blockedBy": ["release_pr_open"]])
        #expect(ReleaseData.candidate(release: release) != nil)
        #expect(ReleaseData.candidate(release: release, me: "other") == nil)
        #expect(ReleaseData.candidate(release: release, pr: ReleaseData.pr(draft: true)) == nil)
        #expect(ReleaseData.candidate(release: release, pressed: false) == nil)
        #expect(ReleaseData.candidate(release: release, jobs: [ReleaseData.job()]) == nil)
        #expect(ReleaseData.candidate(release: release, jobs: [ReleaseData.job(repo: "other/repo")]) != nil)
        #expect(ReleaseData.candidate(release: release, jobs: [ReleaseData.job(move: "review")]) != nil)
        #expect(ReleaseData.candidate(release: release, jobs: [ReleaseData.job(status: .failed)]) != nil)
    }

    @Test func pressDoesNotBypassPathBlocker() throws {
        let release = try ReleaseData.release(["blockedBy": ["pr_in_review_on_paths:migrations/**"]])
        let blocker = ReleaseData.pr(number: 8, head: "fix", base: "develop", files: ["migrations/a.sql"])
        #expect(ReleaseData.candidate(release: release, prs: [ReleaseData.pr(), blocker]) == nil)
    }

    // The named candidate interface has no report/standing input. Automatic due-only admission
    // needs engine coverage with registry facts; this suite pins the independent press gates.
}

@Suite(ProcessBound())
struct ReleaseEngineAcceptanceTests {
    @Test func pressedOpenBypassesWhenEvenWithoutRegistry() async throws {
        let f = try await StartMovesFixture.make(startMoves: false)
        defer { f.remove() }
        let flow = String(decoding: try ReleaseData.flowData(["merge": "merge-commit"]), as: UTF8.self)
        let gh = f.root.appendingPathComponent("gh")
        let old = try String(contentsOf: gh, encoding: .utf8)
        let intercept = """
        if [ "$1" = pr ] && [ "$2" = create ]; then
          printf '%s\\n' "$@" >> "${0%/*}/release-argv"
          while [ "$#" -gt 0 ]; do
            if [ "$1" = --body-file ]; then
              shift
              head -n 1 "$1" > "${0%/*}/release-body-first-line"
              cp "$1" "${0%/*}/release-body"
              break
            fi
            shift
          done
          echo 'https://example.invalid/pr/8'
          exit 0
        fi
        case "$2" in
          repos/synthetic/project/contents/.bton/flow.json)
            cat <<'JSON'
        \(flow)
        JSON
            exit 0 ;;
        esac
        """
        try old.replacingOccurrences(of: "case \"$2\" in", with: intercept + "\ncase \"$2\" in")
            .write(to: gh, atomically: true, encoding: .utf8)
        let engine = try f.engine()
        let before = await engine.tick(dispatching: false)
        let report = try #require(before.features[f.repo])
        guard case .none = report.registry else { Issue.record("Fixture must have no registry"); return }
        #expect(report.release == .unknown)
        #expect(before.openPullRequests.contains { $0.number == 7 && $0.headRef == "feature" })
        await engine.runNext(repo: f.repo, item: "release", pressed: true)
        _ = await engine.tick()
        let args = try String(contentsOf: f.root.appendingPathComponent("release-argv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(args.filter { $0 == "create" }.count == 1)
        let base = try #require(args.firstIndex(of: "--base"))
        let head = try #require(args.firstIndex(of: "--head"))
        let bodyFile = try #require(args.firstIndex(of: "--body-file"))
        #expect(args.dropFirst(base + 1).first == "main")
        #expect(args.dropFirst(head + 1).first == "develop")
        #expect(args.dropFirst(bodyFile + 1).first?.isEmpty == false)
        let firstLine = try String(contentsOf: f.root.appendingPathComponent("release-body-first-line"), encoding: .utf8)
        #expect(firstLine == "Release notes\n")
        try await f.waitForJobs()
        // This fixture case covers opening only, not a subsequent release PR listing, automatic
        // due-only merge, headRefusal, lease contention, or dispatcher check execution/failure.
    }
}
