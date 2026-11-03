@testable import BtonCore
import Testing
import Foundation

@Suite(ProcessBound())
struct StaleReviewAcceptanceTests {
    private enum HeadLookupError: Error { case unavailable }
    private static let oldHead = "abcdef1" + String(repeating: "a", count: 33)
    private static let newHead = "1234567" + String(repeating: "b", count: 33)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let handoverNow = Date(timeIntervalSince1970: 1_792_411_200)

    @Test func staleWithoutHandoverKeyDefaultsToTwelveHours() throws {
        let flow = try Self.handoverFlow()
        #expect(flow.stale?.handOverHours == nil)
        #expect(flow.handOverHours == 12)
    }

    @Test func explicitFractionalHandoverHoursDecodeAndControlEligibility() throws {
        let flow = try Self.handoverFlow(hours: 2.5)
        #expect(flow.stale?.handOverHours == 2.5)
        #expect(flow.handOverHours == 2.5)
        #expect(FlowEngine.handover(of: try Self.handoverPR(age: 2), flow: flow, me: "me", now: Self.handoverNow) == nil)
        #expect(FlowEngine.handover(of: try Self.handoverPR(age: 3), flow: flow, me: "me", now: Self.handoverNow)?.owner == "me")
    }

    @Test func flowWithoutStaleDisablesHandover() throws {
        let flow = try Self.handoverFlow(withStale: false)
        let pr = try Self.handoverPR()
        #expect(flow.handOverHours == nil)
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
        #expect(DispatchPlanner.handoverCandidate(pr, flow: flow, me: "me", repo: pr.repo, now: Self.handoverNow) == nil)
    }

    @Test(arguments: [0.0, -1.0])
    func nonpositiveHandoverHoursMakeFlowInvalid(hours: Double) throws {
        guard case let .invalid(message) = Flow.load(try Self.handoverData(hours: hours)) else {
            Issue.record("Nonpositive stale.handOverHours must be invalid"); return
        }
        #expect(message.contains("stale.handOverHours"))
    }

    @Test(arguments: ["assignee", "reviewer"], [false, true])
    func quietReviewBecomesMyDispatchableMove(who: String, rotation: Bool) throws {
        let flow = try Self.handoverFlow(who: who)
        let pr = try Self.handoverPR(who: who, owner: rotation ? nil : "manual-owner")
        let before = try #require(FlowEngine.move(for: pr, flow: flow))
        #expect(before.owner == (rotation ? "teammate" : "manual-owner"))
        #expect(before.ownerFromRotation == rotation)
        let move = try #require(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow))
        #expect(move.name == "review")
        #expect(move.owner == "me")
        #expect(move.hasDispatch)
        var mine = pr
        if who == "reviewer" { mine.requestedReviewers = ["me"] } else { mine.assignees = ["me"] }
        #expect(FlowEngine.isDispatchable(move, pr: mine, flow: flow, me: "me"))
    }

    @Test(arguments: [11.0, 12.0])
    func reviewMustBeOlderThanHandoverThreshold(age: Double) throws {
        let flow = try Self.handoverFlow()
        let pr = try Self.handoverPR(age: age)
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
        #expect(DispatchPlanner.handoverCandidate(pr, flow: flow, me: "me", repo: pr.repo, now: Self.handoverNow) == nil)
    }

    @Test func authorsMacNeverTakesHandoverEvenWhenAuthorReviewIsAllowed() throws {
        let flow = try Self.handoverFlow(notByAuthor: false)
        let pr = try Self.handoverPR(author: "mE")
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "me") != nil)
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test func loginOutsideReviewersNeverTakesHandover() throws {
        let flow = try Self.handoverFlow(reviewers: ["dev-b", "teammate", "another"])
        let pr = try Self.handoverPR()
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "me") != nil)
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test(arguments: ["assignee", "reviewer"])
    func reviewAlreadyOwnedByMeIsNotAHandover(who: String) throws {
        let flow = try Self.handoverFlow(who: who)
        let pr = try Self.handoverPR(who: who, owner: "mE")
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test func otherMoveIsNotAHandoverEvenWhenTakeoverWouldDispatchIt() throws {
        let flow = try Self.handoverFlow(move: "fix")
        let pr = try Self.handoverPR()
        #expect(FlowEngine.takeover(of: pr, flow: flow, me: "me")?.name == "fix")
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test(arguments: ["author", "teammate", "Assignee", "Reviewer"])
    func handoverRequiresAnAssigneeOrReviewerOwningField(who: String) throws {
        let flow = try Self.handoverFlow(who: who)
        #expect(FlowEngine.handover(of: try Self.handoverPR(), flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test(arguments: ["no dispatch", "wrong base", "untrusted", "pending checks"])
    func handoverMustBeDispatchableAfterTakingOwnership(reason: String) throws {
        let flow = try Self.handoverFlow(dispatch: reason != "no dispatch")
        var pr = try Self.handoverPR(base: reason == "wrong base" ? "main" : "develop",
            association: reason == "untrusted" ? "CONTRIBUTOR" : "MEMBER")
        if reason == "pending checks" { pr.checks = [CheckResult(name: "ci", state: .pending)] }
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test(arguments: ["head", "comment"])
    func recentHeadOrHumanCommentRestartsHandoverClock(clock: String) throws {
        let flow = try Self.handoverFlow()
        var pr = try Self.handoverPR(age: 30)
        let recent = Self.handoverNow.addingTimeInterval(-11 * 3600)
        if clock == "head" { pr.headCommittedAt = recent }
        else { pr.comments = [PullRequestComment(author: "teammate", body: "I will review this.", createdAt: recent)] }
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    @Test func missingStalenessClockNeverUsesUpdatedAtForHandover() throws {
        let flow = try Self.handoverFlow()
        let pr = try Self.handoverPR(age: nil)
        #expect(FlowEngine.handover(of: pr, flow: flow, me: "me", now: Self.handoverNow) == nil)
    }

    // Neither TakeoverAcceptanceTests nor DispatchAcceptanceTests has a runnable Dispatcher
    // fixture recording comments and assignment. These pure tests do not cover the Dispatcher's
    // under-lease cancellation, takeover comment and marker, or starting the review job.
    @Test(arguments: ["assignee", "reviewer"])
    func handoverCandidateUsesReviewDispatchAndCarriesPreviousOwner(who: String) throws {
        let flow = try Self.handoverFlow(who: who)
        let pr = try Self.handoverPR(who: who)
        let candidate = try #require(DispatchPlanner.handoverCandidate(pr, flow: flow, me: "me",
            repo: "synthetic/handover", now: Self.handoverNow))
        let plan: HandoverPlan = try #require(candidate.handover)
        #expect(plan.from == "teammate")
        #expect(plan.kind == who)
        #expect(plan.hours == 13)
        #expect(candidate.move.name == "review")
        #expect(candidate.move.owner == "me")
        #expect(candidate.key.repo == "synthetic/handover")
        #expect(candidate.key.item == "pr-325")
        #expect(candidate.key.move == "review")
        #expect(candidate.key.head == pr.headSha)
        #expect(candidate.agent == "handover-agent")
        #expect(candidate.prompt == "Review synthetic/handover#325 at \(pr.headSha)")
        #expect(candidate.command == nil)
        #expect(candidate.postComment)
        #expect(candidate.timeout == .seconds(17 * 60))
        #expect(candidate.skipsChecks)
        #expect(candidate.helpers == ["handover-helper"])
        #expect(candidate.second == "second-agent")
        #expect(candidate.secondPrompt == "Second 325")
    }

    @Test func runningJobOnPRBlocksHandoverSelection() throws {
        let flow = try Self.handoverFlow()
        let pr = try Self.handoverPR()
        let candidate = try #require(DispatchPlanner.handoverCandidate(pr, flow: flow, me: "me", repo: pr.repo, now: Self.handoverNow))
        let key = JobKey(repo: pr.repo, item: "pr-325", move: "fix", head: "earlier-head")
        let running = Job(id: UUID(), key: key, agent: "handover-agent", startedAt: Self.handoverNow, status: .running)
        let agents = ["handover-agent": AgentTemplate(argv: ["synthetic-agent"]),
                      "second-agent": AgentTemplate(argv: ["synthetic-second"])]
        #expect(DispatchPlanner.select([candidate], jobs: [], maxAgents: 2, agents: agents).map(\.key) == [candidate.key])
        #expect(DispatchPlanner.select([candidate], jobs: [running], maxAgents: 2, agents: agents).isEmpty)
    }

    private static func handoverData(who: String = "assignee", reviewers: [String] = ["dev-b", "ME", "teammate"],
                                     withStale: Bool = true, hours: Double? = nil, move: String = "review",
                                     dispatch: Bool = true, notByAuthor: Bool = true) throws -> Data {
        var object = try #require(JSONSerialization.jsonObject(with: FlowFixture.data()) as? [String: Any])
        object["reviewers"] = reviewers
        object["reviews"] = ["feature": [["heading": "## Review:", "notByAuthor": notByAuthor]]]
        object["moves"] = [["move": move, "when": ["no_review_or_response_newer"], "who": who]]
        object["dispatch"] = dispatch ? [move: ["agent": "handover-agent", "prompt": "Review {repo}#{number} at {head}",
            "post": "comment", "timeoutMinutes": 17, "checks": false, "helpers": ["handover-helper"],
            "second": ["agent": "second-agent", "prompt": "Second {number}"]]] : [:]
        if withStale {
            var stale: [String: Any] = ["pingHours": 24, "escalateHours": 48, "escalateTo": "lead-dev"]
            if let hours { stale["handOverHours"] = hours }
            object["stale"] = stale
        } else { object.removeValue(forKey: "stale") }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func handoverFlow(who: String = "assignee", reviewers: [String] = ["dev-b", "ME", "teammate"],
                                     withStale: Bool = true, hours: Double? = nil, move: String = "review",
                                     dispatch: Bool = true, notByAuthor: Bool = true) throws -> Flow {
        try JSONDecoder().decode(Flow.self, from: handoverData(who: who, reviewers: reviewers,
            withStale: withStale, hours: hours, move: move, dispatch: dispatch, notByAuthor: notByAuthor))
    }

    private static func handoverPR(who: String = "assignee", owner: String? = "teammate", author: String = "dev-b",
                                   age: Double? = 13, base: String = "develop", association: String = "MEMBER") throws -> PullRequest {
        var pr = try FlowFixture.pr(assignees: who == "assignee" ? owner.map { [$0] } ?? [] : ["unrelated-assignee"],
            author: author, base: base, association: association)
        if who == "reviewer" { pr.requestedReviewers = owner.map { [$0] } ?? [] }
        pr.headCommittedAt = age.map { handoverNow.addingTimeInterval(-$0 * 3600) }
        return pr
    }

    @Test func unchangedHeadAllowsPosting() async {
        let detail = await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.oldHead }
        #expect(detail == nil)
    }

    @Test func movedHeadDropsReviewWithShortHeads() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.newHead })
        #expect(detail.hasPrefix("head moved from "))
        #expect(detail.contains("head moved from abcdef1 to 1234567"))
        #expect(!detail.contains(Self.oldHead))
        #expect(!detail.contains(Self.newHead))
        #expect(detail.hasSuffix("nothing posted"))
    }

    @Test func unconfirmedHeadDropsReview() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) {
            throw HeadLookupError.unavailable
        })
        #expect(detail.hasPrefix("could not confirm the head before posting"))
        #expect(detail.hasSuffix("nothing posted"))
        let job = Self.job(status: .failed, detail: detail)
        #expect(job.canRetry(among: [job]))
    }

    @Test func movedHeadFailureNeedsNoSupervisorAndOffersRetry() async throws {
        let detail = try #require(await DispatchPlanner.staleReviewDetail(reviewedHead: Self.oldHead) { Self.newHead })
        let job = Self.job(status: .failed, detail: detail)
        let verdict = try #require(Supervision.knownAnswer(for: job))
        #expect(verdict.action == .none)
        #expect(Watchdog.flags(for: job, among: [job]).contains(.failed))
        #expect(job.canRetry(among: [job]))
    }

    @Test func staleRunningReviewsKeepInputOrderAndMatchRepoIgnoringCase() {
        let first = Self.job(repo: "Synthetic/Project", number: 739)
        let second = Self.job()
        let current = Self.job(head: Self.newHead)
        let jobs = [first, current, second]
        let prs = [Self.pr(number: 738), Self.pr(number: 739)]
        #expect(Engine.staleReviews(jobs, pullRequests: prs).map(\.id) == [first.id, second.id])
    }

    @Test func missingPRAndWrongRepoOrNumberDoNotEstablishStaleness() {
        let job = Self.job()
        #expect(Engine.staleReviews([job], pullRequests: []).isEmpty)
        #expect(Engine.staleReviews([job], pullRequests: [Self.pr(repo: "other/project")]).isEmpty)
        #expect(Engine.staleReviews([job], pullRequests: [Self.pr(number: 739)]).isEmpty)
    }

    @Test func onlyPRReviewsAreDropped() {
        let fix = Self.job(review: false)
        let issue = Self.job(item: "issue-738")
        #expect(Engine.staleReviews([fix, issue], pullRequests: [Self.pr()]).isEmpty)
    }

    @Test(arguments: [Job.Status.succeeded, .failed, .cancelled])
    func finishedJobsAreNotDropped(status: Job.Status) {
        let review = Self.job(status: status)
        let fix = Self.job(status: status, review: false)
        #expect(Engine.staleReviews([review, fix], pullRequests: [Self.pr()]).isEmpty)
    }

    private static func job(repo: String = "synthetic/project", number: Int = 738,
                            item: String? = nil, head: String = oldHead,
                            status: Job.Status = .running, detail: String? = nil,
                            review: Bool = true) -> Job {
        let key = JobKey(repo: repo, item: item ?? "pr-\(number)", move: review ? "review" : "fix", head: head)
        var job = Job(id: UUID(), key: key, agent: "codex", startedAt: now,
                      endedAt: status == .running ? nil : now.addingTimeInterval(1),
                      status: status, detail: detail, retry: nil)
        if review {
            job.review = ReviewTarget(number: number, head: head, headings: ["## Review:"], clearLabels: nil)
        }
        return job
    }

    private static func pr(repo: String = "synthetic/project", number: Int = 738) -> PullRequest {
        PullRequest(repo: repo, number: number, title: "Synthetic PR", author: "owner",
                    authorAssociation: "MEMBER", url: URL(string: "https://example.invalid/pr/\(number)")!,
                    headSha: newHead, headRef: "feature", baseRef: "main", body: "Tier: feature", isDraft: false,
                    labels: [], assignees: [], comments: [], updatedAt: now)
    }
}
