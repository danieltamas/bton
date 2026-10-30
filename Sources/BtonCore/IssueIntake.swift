import Foundation

/// An open issue at `stage:ready`: free for anyone to take, or already taken.
public struct ReadyIssue: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String
    public let number: Int
    public let title: String
    public let url: URL
    public let createdAt: Date
    public let labels: [String]
    public let assignees: [String]
    /// The round the issue is in (`IssueIntake.round(of:)`), so the app finds the job of this round.
    public let round: String

    public var priority: String? { IssueTriage.label(withPrefix: IssueTriage.priorityPrefix, in: labels) }
    public var stage: String? { IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: labels) }
    public var isReady: Bool { stage == "ready" }
}

/// What a job needs to take one issue and start working on it, all of it filled in from the flow
/// and the issue's number and labels: no issue text reaches an argv.
public struct IntakePlan: Sendable {
    public let issue: Int
    public let base: String
    /// What an issue must look like on GitHub, right before the claim.
    public let terms: IssueIntake.Terms
    /// Run in the clone while the lease is held, so the issue leaves the search before the lease does.
    public let claim: [[String]]
    /// Run in the clone to make the issue's worktree.
    public let worktree: [String]
    /// The worktree's folder, relative to the clone.
    public let worktreePath: String
    /// The issue is already mine and in progress (a retry): the claim and the worktree are done.
    public var resumes = false
}

/// Taking `stage:ready` issues: the flow's `intake` says how an issue is found, claimed and worked,
/// the agent opens the PR as the repo's own process says, and the PR's moves take over from there.
public enum IssueIntake {
    public static let move = "implement"
    /// The order of the `priority:` labels when the flow names none.
    static let defaultPriority = ["priority:high", "priority:medium", "priority:low"]

    /// The issue's round: the newest comment's time, whoever wrote it. A hand-back ("an open D-n
    /// waits for Dani") and the ruling that answers it both arrive as comments, so an issue that
    /// comes back to ready after one is new work, where the same key would never run again.
    public static func round(of issue: OpenIssue) -> String {
        issue.comments.map(\.createdAt).max().map { String(Int($0.timeIntervalSince1970)) } ?? ""
    }

    public static func isReady(_ issue: OpenIssue) -> Bool {
        IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: issue.labels) == "ready"
    }

    static func isInProgress(_ issue: OpenIssue) -> Bool {
        IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: issue.labels) == "in-progress"
    }

    /// Every ready issue, taken or not, the most urgent first and then the oldest; then the
    /// the in-progress ones, whoever works them, so two people do not start the same issue; and the
    /// ones this Mac's intake jobs are on (`held`, by number), whatever stage they are in now: the claim
    /// moves an issue out of ready, and an agent that hands the issue back (to spec, say) leaves it
    /// there; either way the job's outcome must not vanish with the label.
    public static func ready(_ issues: [OpenIssue], priority: [String]? = nil, held: Set<Int> = []) -> [ReadyIssue] {
        let order = priority ?? defaultPriority
        return (ordered(issues.filter(isReady), priority: order) + ordered(issues.filter { !isReady($0) && (isInProgress($0) || held.contains($0.number)) }, priority: order))
            .map {
                ReadyIssue(repo: $0.repo, number: $0.number, title: $0.title, url: $0.url, createdAt: $0.createdAt,
                           labels: $0.labels, assignees: $0.assignees, round: round(of: $0))
            }
    }

    /// The issues whose latest intake job on this Mac is running, failed or stopped: a job that
    /// succeeded has opened its PR, which is where the work shows from then on.
    public static func held(by jobs: [Job], repo: String) -> Set<Int> {
        let latest = Dictionary(grouping: jobs.filter { $0.key.move == move && $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame },
                                by: \.key.item).compactMapValues { $0.max { $0.startedAt < $1.startedAt } }
        return Set(latest.values.filter { $0.status != .succeeded }.compactMap { Int($0.key.item.dropFirst("issue-".count)) })
    }

    static func ordered(_ issues: [OpenIssue], priority: [String]) -> [OpenIssue] {
        let rank = { (issue: OpenIssue) -> Int in
            let labels = Set(issue.labels.map { $0.lowercased() })
            return priority.firstIndex { labels.contains($0.lowercased()) } ?? priority.count
        }
        return issues.sorted { (rank($0), $0.createdAt, $0.number) < (rank($1), $1.createdAt, $1.number) }
    }

    // MARK: the search

    /// What `intake.search` asks of an issue, for the terms Bton can check on the issues it has read.
    public struct Terms: Equatable, Sendable {
        var labels: [String] = []
        var withoutLabels: [String] = []
        var unassigned = false

        /// Why an issue (its state, labels and assignees) is not one the search finds, or nil.
        func mismatch(state: String = "OPEN", labels have: [String], assignees: [String]) -> String? {
            let present = Set(have.map { $0.lowercased() })
            if state != "OPEN" { return "the issue is not open" }
            if let missing = labels.first(where: { !present.contains($0) }) { return "it no longer has the label \(missing)" }
            if let found = withoutLabels.first(where: present.contains) { return "it now has the label \(found)" }
            if unassigned, !assignees.isEmpty { return "it is assigned to \(assignees.joined(separator: ", "))" }
            return nil
        }
    }

    /// nil when the search holds a term Bton cannot check against an issue it has read: nothing is
    /// taken then, rather than something the search would have left out.
    public static func terms(_ search: [String], repo: String) -> Terms? {
        var terms = Terms()
        for term in search {
            let lower = term.lowercased()
            switch lower {
            case "is:issue", "is:open": continue
            case "no:assignee": terms.unassigned = true
            case _ where lower.hasPrefix("repo:"):
                guard lower == "repo:{repo}" || lower == "repo:\(repo.lowercased())" else { return nil }
            case _ where lower.hasPrefix("label:") || lower.hasPrefix("-label:"):
                let negated = lower.hasPrefix("-")
                let name = String(lower.dropFirst(negated ? 7 : 6))
                guard !name.isEmpty, !name.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "," }) else { return nil }
                if negated { terms.withoutLabels.append(name) } else { terms.labels.append(name) }
            default: return nil
            }
        }
        return terms
    }

    // MARK: the candidate

    /// The issue to take now, or nil. One at a time per repo, and none while the repo's open PRs
    /// are at a cap: the PR an issue is about to become counts as soon as the job runs. An issue
    /// I retried after its claim is picked up again wherever it stands. `work` is this Mac's choice of
    /// agent, model and effort for the repo. `requested` is an issue the owner pressed Take on: it goes
    /// first, past the caps, but through every other gate. `resumeOnly`: only an issue of mine whose job
    /// is asked to run again, for a repo that does not start its moves.
    public static func candidate(issues: [OpenIssue], intake: Intake, caps: Caps?, pullRequests: [PullRequest], jobs: [Job],
                                 repo: String, base: String, me: String, agents: [String: AgentTemplate],
                                 work: AgentPick? = nil, requested: Int? = nil, resumeOnly: Bool = false) -> DispatchCandidate? {
        guard agents[work?.agent ?? intake.agent] != nil, !base.isEmpty,
              let terms = terms(intake.search, repo: repo),
              !jobs.contains(where: { $0.status == .running && $0.key.move == move && $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame })
        else { return nil }
        // A retry runs under the job's own key: a comment that arrived while the agent worked
        // moved the issue's round on, and must not strand the issue that is already mine.
        let retried = issues.lazy.compactMap { issue -> (OpenIssue, JobKey)? in
            guard issue.assignees.contains(where: { $0.caseInsensitiveCompare(me) == .orderedSame }),
                  let latest = latestJob(for: issue.number, repo: repo, jobs: jobs), DispatchPlanner.isRetry(latest.key, jobs: jobs)
            else { return nil }
            return (issue, latest.key)
        }.first
        if let (issue, key) = retried,
           let made = candidate(for: issue, key: key, intake: intake, terms: terms, repo: repo, base: base, me: me, resumes: true, work: work) {
            return made
        }
        // A repo that does not start its moves still finishes what was already begun, and takes nothing new.
        if resumeOnly { return nil }
        let ran = Set(jobs.filter { $0.retry != true }.map(\.key))
        if let requested,
           let asked = issues.first(where: { $0.number == requested && eligible($0, terms: terms) && !ran.contains(key(repo: repo, number: $0.number, round: round(of: $0))) }) {
            return candidate(for: asked, key: key(repo: repo, number: asked.number, round: round(of: asked)),
                             intake: intake, terms: terms, repo: repo, base: base, me: me, resumes: false, work: work)
        }
        if let caps {
            let mine = pullRequests.filter { $0.author.caseInsensitiveCompare(me) == .orderedSame }.count
            guard mine < caps.openPullRequestsPerDeveloper, pullRequests.count < caps.openPullRequestsTeam else { return nil }
        }
        let taken = ordered(issues.filter { eligible($0, terms: terms) }, priority: intake.priority)
            .first { !ran.contains(key(repo: repo, number: $0.number, round: round(of: $0))) }
        return taken.flatMap {
            candidate(for: $0, key: key(repo: repo, number: $0.number, round: round(of: $0)),
                      intake: intake, terms: terms, repo: repo, base: base, me: me, resumes: false, work: work)
        }
    }

    /// An issue whose text an outsider wrote is not one an agent works from, like a PR's.
    static func eligible(_ issue: OpenIssue, terms: Terms) -> Bool {
        FlowEngine.trustedAssociations.contains(issue.authorAssociation)
            && terms.mismatch(labels: issue.labels, assignees: issue.assignees) == nil
    }

    public static func key(repo: String, number: Int, round: String) -> JobKey {
        JobKey(repo: repo, item: "issue-\(number)", move: move, head: "", round: round)
    }

    /// The issue's newest intake job on this Mac, whatever round it ran under.
    public static func latestJob(for number: Int, repo: String, jobs: [Job]) -> Job? {
        jobs.filter { $0.key.move == move && $0.key.item == "issue-\(number)" && $0.key.repo.caseInsensitiveCompare(repo) == .orderedSame }
            .max { $0.startedAt < $1.startedAt }
    }

    private static func candidate(for issue: OpenIssue, key: JobKey, intake: Intake, terms: Terms, repo: String, base: String, me: String,
                                  resumes: Bool, work: AgentPick?) -> DispatchCandidate? {
        guard let type = type(of: issue.labels, rule: intake.type) else { return nil }
        let values = ["{repo}": repo, "{issue}": String(issue.number), "{base}": base, "{type}": type]
        let filling = { (template: String) in DispatchPlanner.fill(template, values) }
        let plan = IntakePlan(issue: issue.number, base: base, terms: terms, claim: intake.claim.map { $0.map(filling) },
                              worktree: intake.worktree.map(filling), worktreePath: filling(intake.worktreePath), resumes: resumes)
        guard isRelative(plan.worktreePath) else { return nil }
        var made = DispatchCandidate(target: .issue(plan), move: Move(name: move, owner: me, ownerFromRotation: false, tier: "", hasDispatch: true),
                                     key: key, agent: work?.agent ?? intake.agent,
                                     prompt: filling(intake.prompt), command: nil, postComment: false,
                                     timeout: .seconds(60 * (intake.timeoutMinutes ?? 60)))
        made.model = work?.model
        made.effort = work?.effort
        return made
    }

    /// The first of the issue's labels the flow maps to a type, else the default; a word that can
    /// stand in a branch name and an argv.
    static func type(of labels: [String], rule: Intake.IssueType) -> String? {
        let mapped = Dictionary(rule.labels.map { ($0.key.lowercased(), $0.value) }) { first, _ in first }
        let chosen = labels.lazy.compactMap { mapped[$0.lowercased()] }.first ?? rule.default
        return chosen.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) == nil ? nil : chosen
    }

    /// A folder inside the clone: not absolute, no `..`, nothing left unfilled.
    static func isRelative(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("{") && !path.split(separator: "/").contains("..")
    }

    // MARK: right before the claim

    public enum Standing: Equatable, Sendable {
        /// Still free: take it.
        case claim
        /// Already mine and in progress, the retry of a job that got that far.
        case resume
        case refuse(String)
    }

    /// What a fresh read of the issue allows. The sync's read is seconds to minutes old, and
    /// someone may have taken the issue since; a claim over theirs would put two on it.
    public static func standing(of now: IssueNow, plan: IntakePlan, me: String) -> Standing {
        let mine = now.assignees.contains { $0.caseInsensitiveCompare(me) == .orderedSame }
        if plan.resumes {
            if now.state != "OPEN" { return .refuse("the issue is not open") }
            return mine ? .resume : (plan.terms.mismatch(state: now.state, labels: now.labels, assignees: now.assignees).map(Standing.refuse) ?? .claim)
        }
        return plan.terms.mismatch(state: now.state, labels: now.labels, assignees: now.assignees).map(Standing.refuse) ?? .claim
    }
}

/// An issue as GitHub says it is now.
public struct IssueNow: Equatable, Sendable {
    public let state: String
    public let labels: [String]
    public let assignees: [String]

    public init(state: String, labels: [String], assignees: [String]) {
        self.state = state
        self.labels = labels
        self.assignees = assignees
    }
}

/// The PR an issue's branch became, if it did.
public struct BranchPullRequest: Equatable, Sendable {
    public let number: Int
    public let isDraft: Bool
}

extension GitHubClient {
    /// The newest open PR whose head is `branch`, nil when there is none.
    public func openPullRequest(repo: String, branch: String) async throws -> BranchPullRequest? {
        try Self.decodeBranchPullRequest(try await gh(["pr", "list", "--repo", repo, "--head", branch, "--state", "open",
                                                       "--json", "number,isDraft"]))
    }

    static func decodeBranchPullRequest(_ data: Data) throws -> BranchPullRequest? {
        struct Row: Decodable { let number: Int, isDraft: Bool }
        return try JSONDecoder().decode([Row].self, from: data).max { $0.number < $1.number }
            .map { BranchPullRequest(number: $0.number, isDraft: $0.isDraft) }
    }

    public func issueNow(repo: String, number: Int) async throws -> IssueNow {
        try Self.decodeIssueNow(try await gh(["issue", "view", String(number), "--repo", repo, "--json", "state,labels,assignees"]))
    }

    /// The issue's comments as they are now, oldest first.
    public func issueComments(repo: String, number: Int) async throws -> [IssueComment] {
        try IssueDecisions.decodeComments(try await gh(["issue", "view", String(number), "--repo", repo, "--json", "comments"]))
    }

    /// The issue's state, labels, body and comments as they are now.
    public func issueLive(repo: String, number: Int) async throws -> IssueDecisions.Live {
        try IssueDecisions.decodeLive(try await gh(["issue", "view", String(number), "--repo", repo, "--json", "state,labels,body,comments"]))
    }

    static func decodeIssueNow(_ data: Data) throws -> IssueNow {
        struct Name: Decodable { let name: String }
        struct Login: Decodable { let login: String }
        struct Row: Decodable { let state: String, labels: [Name], assignees: [Login] }
        let row = try JSONDecoder().decode(Row.self, from: data)
        return IssueNow(state: row.state, labels: row.labels.map(\.name), assignees: row.assignees.map(\.login))
    }
}
