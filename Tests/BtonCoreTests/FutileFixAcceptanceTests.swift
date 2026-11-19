@testable import BtonCore
import Foundation
import Testing

@Suite(ProcessBound())
struct FutileFixAcceptanceTests {
    private static let reasons = [
        "no push can clear the review: the review waits for the other developer's approval",
        "no push can clear the review: the tool was not found on this Mac's PATH",
        "no push can clear the review: waiting: the reviewer ran 45 minutes and was stopped"
    ]
    private enum HeadError: Error { case unavailable }

    @Test func constantsMatchTheProtocol() {
        #expect(DispatchPlanner.futileMarker == "## No push can clear this:")
        #expect(DispatchPlanner.noPushCanClear == "no push can clear the review")
    }

    @Test(arguments: ["", "\n", "\n\n \t\n\t "])
    func finalMarkerAllowsTrailingBlankLines(suffix: String) {
        #expect(DispatchPlanner.futileReason(in: "Read the review.\nChecked the branch.\n"
            + "## No push can clear this: the review waits for the other developer's approval" + suffix)
            == "the review waits for the other developer's approval")
    }

    @Test(arguments: ["## No push can clear this: x\nMore text",
                      "Note: ## No push can clear this: x", "## no push can clear this: x",
                      "## No push can clear this:", "## No push can clear this:   ", "", " \t\n\t"])
    func invalidOrNonfinalMarkersAreIgnored(report: String) {
        #expect(DispatchPlanner.futileReason(in: report) == nil)
    }

    @Test(arguments: ["   ", "\t", " \t "])
    func markerAllowsLeadingSpacesAndTabs(prefix: String) {
        #expect(DispatchPlanner.futileReason(in: prefix + "## No push can clear this: x") == "x")
    }

    @Test func longReasonKeepsOnlyFirstTwoHundredCharacters() {
        let first = String(repeating: "a", count: 200)
        #expect(DispatchPlanner.futileReason(in: "## No push can clear this: " + first
            + String(repeating: "b", count: 100)) == first)
    }

    @Test func reasonDropsControlAndInvisibleCharactersButKeepsWords() throws {
        let reason = try #require(DispatchPlanner.futileReason(
            in: "## No push can clear this: before\u{0007} middle\u{202E} after\u{200B} end"))
        for character in ["\u{0007}", "\u{202E}", "\u{200B}"] { #expect(!reason.contains(character)) }
        for word in ["before", "middle", "after", "end"] { #expect(reason.contains(word)) }
    }

    @Test func crlfReportReturnsOneLine() throws {
        let reason = try #require(DispatchPlanner.futileReason(in: "Checked.\r\n## No push can clear this: x\r\n"))
        #expect(reason == "x")
        #expect(reason.rangeOfCharacter(from: .newlines) == nil)
    }

    @Test func unchangedHeadWithFinalMarkerFailsAsFutile() async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: FutileFixture.head,
            report: FutileFixture.report) { FutileFixture.head }
        #expect(outcome.status == .failed)
        #expect(outcome.detail == FutileFixture.detail)
    }

    @Test(arguments: ["Checked the review.", "## No push can clear this: x\nStill working."])
    func unchangedHeadWithoutFinalMarkerKeepsOrdinaryFailure(report: String) async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: FutileFixture.head, report: report) { FutileFixture.head }
        #expect(outcome.status == .failed)
        #expect(outcome.detail?.hasPrefix("ended without pushing") == true)
    }

    @Test func omittedReportKeepsOrdinaryFailure() async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: FutileFixture.head) { FutileFixture.head }
        #expect(outcome.status == .failed)
        #expect(outcome.detail?.hasPrefix("ended without pushing") == true)
    }

    @Test func movedHeadSucceedsDespiteMarker() async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: FutileFixture.head,
            report: FutileFixture.report) { String(repeating: "b", count: 40) }
        #expect(outcome.status == .succeeded)
        #expect(outcome.detail?.contains("no push can clear") != true)
    }

    @Test func unreadableHeadCannotBeHiddenByMarker() async {
        let outcome = await DispatchPlanner.pushOutcome(startedAt: FutileFixture.head,
            report: FutileFixture.report) { throw HeadError.unavailable }
        #expect(outcome.status == .failed)
        #expect(outcome.detail?.hasPrefix("could not confirm the push") == true)
        var job = FutileFixture.job()
        job.status = outcome.status
        job.detail = outcome.detail
        #expect(!job.isFutileFix)
        #expect(job.canRetry(among: [job]))
    }

    @Test func futileFixNeedsNewCommentForRetry() {
        let job = FutileFixture.job()
        #expect(job.isFutileFix)
        #expect(!job.canRetry(among: [job]))
        #expect(job.canRetry(among: [job], commentedSince: true))
    }

    @Test func nonPushJobCannotBeFutile() {
        var job = FutileFixture.job()
        job.pushes = nil
        #expect(!job.isFutileFix)
        #expect(job.canRetry(among: [job]))
    }

    @Test func succeededJobCannotBeFutile() {
        var job = FutileFixture.job()
        job.status = .succeeded
        #expect(!job.isFutileFix)
    }

    @Test func ordinaryNoPushFailureRemainsRetryable() {
        let job = FutileFixture.job(detail: "ended without pushing")
        #expect(!job.isFutileFix)
        #expect(job.canRetry(among: [job]))
    }

    @Test(arguments: [false, true])
    func alreadyRetriedFutileFixCannotRetryAgain(commented: Bool) {
        var job = FutileFixture.job()
        job.retry = true
        #expect(!job.canRetry(among: [job], commentedSince: commented))
    }

    @Test(arguments: [false, true])
    func storeRetryRequiresNewCommentAndPersistsIt(commented: Bool) throws {
        let root = try FutileFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let job = FutileFixture.job()
        try store.save(job)
        let accepted = commented ? try store.requestRetry(job.id, commentedSince: true) : try store.requestRetry(job.id)
        #expect(accepted == commented)
        let reloaded = try JobStore(home: home)
        let saved = try #require(reloaded.all().first { $0.id == job.id })
        #expect((saved.retry == true) == commented)
        if commented { #expect(FutileFixture.select(FutileFixture.candidate(), jobs: [saved]) == [job.key]) }
    }

    @Test func supervisorCannotSteerFutileFixIntoRetry() throws {
        let root = try FutileFixture.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        let store = try JobStore(home: home)
        let job = FutileFixture.job()
        try store.save(job)
        #expect(try !store.requestSteeredRetry(job.id, note: "try again"))
        let reloaded = try JobStore(home: home)
        let saved = try #require(reloaded.all().first { $0.id == job.id })
        #expect(saved.retry != true)
        #expect(saved.steer == nil)
    }

    @Test func selectionBlocksSameKeyButAllowsNewHeadOrReviewRound() {
        let job = FutileFixture.job()
        #expect(FutileFixture.select(FutileFixture.candidate(), jobs: [job]).isEmpty)
        for candidate in [FutileFixture.candidate(head: String(repeating: "b", count: 40)),
                          FutileFixture.candidate(round: "1800000000")] {
            #expect(FutileFixture.select(candidate, jobs: [job]) == [candidate.key])
        }
    }

    @Test func noCommentOrNoEndTimeCannotUnlockRetry() {
        var job = FutileFixture.job()
        #expect(!DispatchPlanner.commentedSince(job, pr: FutileFixture.pr()))
        job.endedAt = nil
        let comment = PullRequestComment(author: "owner", body: "New information", createdAt: FutileFixture.time.addingTimeInterval(1))
        #expect(!DispatchPlanner.commentedSince(job, pr: FutileFixture.pr(comments: [comment])))
    }

    @Test(arguments: [-1.0, 0.0, 1.0], ["owner", "someone-else", "helper[bot]"])
    func onlyStrictlyNewerCommentsUnlockRetry(offset: Double, author: String) {
        let comment = PullRequestComment(author: author, body: "New information", createdAt: FutileFixture.time.addingTimeInterval(offset))
        #expect(DispatchPlanner.commentedSince(FutileFixture.job(), pr: FutileFixture.pr(comments: [comment])) == (offset > 0))
    }

    @Test(arguments: reasons)
    func supervisionGivesOnlyTheFutileNote(detail: String) throws {
        let verdict = try #require(Supervision.knownAnswer(for: FutileFixture.job(detail: detail)))
        #expect(verdict.action == .none)
        #expect(verdict.note == FutileFixture.note)
        #expect(!verdict.note.contains("press Retry"))
        #expect(!verdict.note.contains("on this Mac"))
    }

    @Test(arguments: reasons)
    func watchdogReportsOnlyFailed(detail: String) {
        let job = FutileFixture.job(detail: detail)
        #expect(Watchdog.flags(for: job, among: [job]) == [.failed])
    }

    @Test(arguments: reasons)
    func futileFixHasNoCauseKey(detail: String) { #expect(Cause.key(for: FutileFixture.job(detail: detail)) == nil) }

    @Test(arguments: reasons)
    func futileFixesOnDifferentPRsAreNotRecurring(detail: String) {
        let first = FutileFixture.job(detail: detail)
        let second = FutileFixture.job(item: "pr-8", detail: detail, offset: 60)
        for job in [first, second] { #expect(!Watchdog.flags(for: job, among: [first, second]).contains(.recurring)) }
    }

    @Test func ordinaryNoPushFailureStillEscalatesWithRetryAdvice() throws {
        let verdict = try #require(Supervision.knownAnswer(for: FutileFixture.job(detail: "ended without pushing")))
        #expect(verdict.action == .escalate)
        #expect(verdict.note.contains("press Retry"))
    }

    @Test func fixInstructionIncludesMarkerAndConfiguredFixedHeading() {
        let line = DispatchPlanner.fixLine(fixed: "## Fixed:")
        #expect(line.contains("## No push can clear this:"))
        #expect(line.contains("`## Fixed:`"))
        #expect(line.contains("post no comment"))
    }

    @Test(arguments: [nil, ""] as [String?])
    func fixInstructionWithoutFixedHeadingOmitsCommentAdvice(fixed: String?) {
        let line = DispatchPlanner.fixLine(fixed: fixed)
        #expect(line.contains("## No push can clear this:"))
        #expect(!line.contains("post no comment"))
    }

    @Test func dispatcherPassesMarkerAndPersistsFutileOutcome() async throws {
        let f = try await FutileProcessFixture.make()
        defer { f.remove() }
        let job = try await f.dispatch(move: "fix", pushes: true, report: FutileFixture.report)
        let prompt = try String(contentsOf: f.file("agent-argv"), encoding: .utf8)
        #expect(prompt.contains("Synthetic task"))
        #expect(prompt.contains("## No push can clear this:"))
        #expect(job.status == .failed)
        #expect(job.detail == FutileFixture.detail)
        #expect(job.isFutileFix)
        #expect(!job.canRetry(among: try f.store.all()))
        let verdict = try #require(job.verdict)
        #expect(verdict.action == .none)
        #expect(verdict.note == FutileFixture.note)
    }

    @Test(arguments: ["review", "finish", "fix-ci"])
    func dispatcherOmitsMarkerForNonPushMoves(move: String) async throws {
        let f = try await FutileProcessFixture.make()
        defer { f.remove() }
        _ = try await f.dispatch(move: move, pushes: false, report: "Finished.")
        let prompt = try String(contentsOf: f.file("agent-argv"), encoding: .utf8)
        #expect(prompt.contains("Synthetic task"))
        #expect(!prompt.contains("## No push can clear this:"))
    }

    @Test func dispatcherWithoutMarkerKeepsRetryableFailure() async throws {
        let f = try await FutileProcessFixture.make()
        defer { f.remove() }
        let job = try await f.dispatch(move: "fix", pushes: true, report: "Read the review.\nChecked the branch.\nNo changes made.")
        #expect(job.status == .failed)
        #expect(job.detail?.hasPrefix("ended without pushing") == true)
        #expect(job.canRetry(among: try f.store.all()))
    }

    @Test(arguments: [false, true])
    func engineRetryNeedsASyncWithANewerComment(sync: Bool) async throws {
        let f = try await FutileProcessFixture.make()
        defer { f.remove() }
        let job = FutileFixture.job(head: f.head)
        try f.store.save(job)
        let engine = try Engine(home: f.home, github: GitHubClient(ghPath: f.file("gh").path), log: { _ in })
        if sync {
            let snapshot = await engine.tick(dispatching: false)
            #expect(snapshot.problem == nil)
        }
        #expect(try await engine.retry(job.id) == sync)
        let saved = try #require(try f.store.all().first { $0.id == job.id })
        #expect((saved.retry == true) == sync)
    }
}

private enum FutileFixture {
    static let head = String(repeating: "a", count: 40)
    static let time = Date(timeIntervalSince1970: 1_700_000_000)
    static let detail = "no push can clear the review: the review waits for the other developer's approval"
    static let note = "no Retry until the PR gets a new comment; a new head or a review by someone else starts the fix again"
    static let report = "Read the review.\nChecked the branch.\n## No push can clear this: the review waits for the other developer's approval"

    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("futile-fix-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    static func job(item: String = "pr-7", head: String = FutileFixture.head,
                    detail: String = FutileFixture.detail, offset: TimeInterval = 0) -> Job {
        var job = Job(id: UUID(), key: JobKey(repo: "synthetic/project", item: item, move: "fix", head: head),
            agent: "synthetic", startedAt: time.addingTimeInterval(offset - 1),
            endedAt: time.addingTimeInterval(offset), status: .failed, detail: detail)
        job.pushes = true
        return job
    }

    static func pr(head: String = FutileFixture.head, comments: [PullRequestComment] = []) -> PullRequest {
        PullRequest(repo: "synthetic/project", number: 7, title: "Synthetic", author: "owner", authorAssociation: "OWNER",
            url: URL(string: "https://example.invalid/pr/7")!, headSha: head, headRef: "feature", baseRef: "main",
            body: "", isDraft: false, labels: [], assignees: [], comments: comments, updatedAt: .distantPast)
    }

    static func candidate(head: String = FutileFixture.head, round: String = "", move: String = "fix") -> DispatchCandidate {
        var candidate = DispatchCandidate(target: .pullRequest(pr(head: head)),
            move: Move(name: move, owner: "owner", ownerFromRotation: false, tier: "small", hasDispatch: true),
            key: JobKey(repo: "synthetic/project", item: "pr-7", move: move, head: head, round: round),
            agent: "synthetic", prompt: "Synthetic task", command: nil, postComment: false, timeout: .seconds(30))
        candidate.pushes = true
        return candidate
    }

    static func select(_ candidate: DispatchCandidate, jobs: [Job]) -> [JobKey] {
        DispatchPlanner.select([candidate], jobs: jobs, maxAgents: 2,
            agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])]).map(\.key)
    }
}

private struct FutileProcessFixture {
    let root: URL
    let head: String
    var home: BtonHome { BtonHome(environment: ["BTON_HOME": file("home").path]) }
    var store: JobStore { get throws { try JobStore(home: home) } }
    func file(_ name: String) -> URL { root.appendingPathComponent(name) }
    func remove() { try? FileManager.default.removeItem(at: root) }

    static func make() async throws -> Self {
        let root = try FutileFixture.root()
        do {
            let remote = root.appendingPathComponent("origin.git").path
            let clone = root.appendingPathComponent("clone").path
            for args in [["init", "--bare", "--initial-branch=main", remote], ["clone", remote, clone],
                         ["-C", clone, "commit", "--allow-empty", "-m", "Synthetic"],
                         ["-C", clone, "push", "origin", "HEAD:refs/heads/main", "HEAD:refs/pull/7/head"]] {
                _ = try await git(args)
            }
            let head = try await git(["-C", clone, "rev-parse", "HEAD"])
            let f = Self(root: root, head: head)
            try f.home.prepare()
            let flow: [String: Any] = ["version": 1, "base": "main",
                "tier": ["marker": "Tier:", "values": ["small"], "default": "small"],
                "reviews": [String: String](), "fixed": "## Fixed:",
                "moves": [["move": "fix", "when": ["no_review_or_response_newer"], "who": "author"]],
                "dispatch": ["fix": ["agent": "synthetic", "prompt": "Synthetic task"]]]
            try JSONSerialization.data(withJSONObject: flow).write(to: f.file("flow"))
            var watched = WatchedRepo(slug: "synthetic/project", path: clone)
            watched.startMoves = false
            watched.environment = [:]
            try BtonConfig(repos: [watched], pollSeconds: 60, maxAgents: 2,
                agents: ["synthetic": AgentTemplate(argv: ["/usr/bin/true"])], schedules: []).save(to: f.home.configURL)
            try PriceList(models: [:], updatedAt: .now).save(home: f.home)
            let script = #"""
            #!/bin/sh
            set -eu
            cd "${0%/*}"
            export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
            git() { /usr/bin/git -c user.name=Synthetic -c user.email=synthetic@example.invalid -c commit.gpgsign=false "$@"; }
            if [ "${1-}" = pr ] && [ "${2-}" = view ]; then
              printf '{"headRefOid":"%s","state":"OPEN"}' 'HEAD_VALUE'; exit 0
            fi
            if [ "${1-}" != api ]; then
              if [ "${2-}" = list ]; then echo '[]'; fi
              exit 0
            fi
            case "$2" in
              repos/synthetic/project/contents/.bton/flow.json) cat flow ;;
              graphql) cat <<'JSON'
            {"data":{"viewer":{"login":"owner"},"repository":{"defaultBranchRef":{"name":"main"},"pullRequests":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"number":7,"title":"Synthetic","url":"https://example.invalid/pr/7","isDraft":false,"headRefOid":"HEAD_VALUE","headRefName":"feature","baseRefName":"main","body":"","updatedAt":"2023-11-14T22:13:21Z","mergeable":"MERGEABLE","authorAssociation":"OWNER","author":{"login":"owner"},"labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"nodes":[{"author":{"login":"someone-else"},"authorAssociation":"MEMBER","body":"New information","createdAt":"2023-11-14T22:13:21Z"}]}}]}}}}
            JSON
                ;;
              repos/synthetic/project/git/ref/*)
                ref="refs/${2#repos/synthetic/project/git/ref/}"
                if sha=$(git --git-dir=origin.git rev-parse --verify "$ref" 2>/dev/null); then
                  printf '{"object":{"sha":"%s"}}' "$sha"
                else echo 'HTTP 404' >&2; exit 1; fi ;;
              repos/synthetic/project/git/commits/*)
                message=$(git --git-dir=origin.git show -s --format=%s "${2##*/}")
                message=${message//\\/\\\\}
                message=${message//\"/\\\"}
                printf '{"message":"%s"}' "$message" ;;
              *) exit 2 ;;
            esac
            """#.replacingOccurrences(of: "HEAD_VALUE", with: head)
            try executable(script, at: f.file("gh"))
            return f
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func dispatch(move: String, pushes: Bool, report: String) async throws -> Job {
        try report.write(to: file("report"), atomically: true, encoding: .utf8)
        try Self.executable("""
        #!/bin/sh
        set -eu
        printf '%s\\n' "$@" > '\(file("agent-argv").path)'
        cat '\(file("report").path)'
        """, at: file("agent"))
        let github = GitHubClient(ghPath: file("gh").path)
        let remote = file("origin.git").path
        let leases = try LeaseStore(home: home, holder: "synthetic", host: "fixture", github: github, remoteURL: { _ in remote })
        let jobs = try store
        let dispatcher = Dispatcher(github: github, leases: leases, jobs: jobs, home: home, log: { _ in })
        var candidate = FutileFixture.candidate(head: head, move: move)
        candidate.pushes = pushes
        candidate.skipsChecks = true
        let outcome = await dispatcher.dispatch(candidate, clone: file("clone"), flow: nil,
            agents: ["synthetic": AgentTemplate(argv: [file("agent").path, "{prompt}"])])
        guard case .started = outcome else { throw DispatchError.worktree("Futile fixture did not start: \(outcome)") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if let job = jobs.all().first(where: { $0.status != .running }),
               !FileManager.default.fileExists(atPath: jobs.lockURL(job.id).path) { return job }
            try await Task.sleep(for: .milliseconds(25))
        }
        for job in jobs.all() { await dispatcher.stop(job.id) }
        throw DispatchError.worktree("Futile fixture did not finish")
    }

    private static func executable(_ text: String, at url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private static func git(_ arguments: [String]) async throws -> String {
        let result = try await ProcessRunner().run("/usr/bin/git",
            ["-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid", "-c", "commit.gpgsign=false"] + arguments,
            environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"], timeout: .seconds(30))
        try #require(result.status == 0, "Local git setup: \(result.stderr)")
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
