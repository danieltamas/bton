import Foundation

/// An open pull request as GitHub reports it. Who acts next is not decided here: the repo's
/// flow derives it (`FlowEngine`), and the app only displays it.
public struct PullRequest: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String
    public let number: Int
    public let title: String
    /// "ghost" for a deleted account, as GitHub shows it.
    public let author: String
    /// OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, NONE…: only the first three are dispatched.
    public let authorAssociation: String
    public let url: URL
    public let headSha: String
    public let headRef: String
    public let baseRef: String
    public let body: String
    public let isDraft: Bool
    public let labels: [String]
    public let assignees: [String]
    /// Oldest first, without Bton's own comments.
    public let comments: [PullRequestComment]
    public let updatedAt: Date
    /// When the head commit was made; nil when GitHub did not say.
    public var headCommittedAt: Date?
    /// The keys of Bton's own marker comments on the PR (`stale-ping fix@<head>`), which are
    /// not in `comments`.
    public var btonMarkers: Set<String> = []
    /// Set once the repo's flow has been evaluated; nil for a repo without a flow.
    public var move: Move?
    /// What this Mac's jobs on the PR cost so far; nil without jobs or while a model has no price.
    public var cost: Decimal?
    /// One of this Mac's jobs is working on it now.
    public var isWorking = false

    public init(repo: String, number: Int, title: String, author: String, authorAssociation: String, url: URL,
                headSha: String, headRef: String, baseRef: String, body: String, isDraft: Bool, labels: [String],
                assignees: [String], comments: [PullRequestComment], updatedAt: Date, move: Move? = nil) {
        self.repo = repo
        self.number = number
        self.title = title
        self.author = author
        self.authorAssociation = authorAssociation
        self.url = url
        self.headSha = headSha
        self.headRef = headRef
        self.baseRef = baseRef
        self.body = body
        self.isDraft = isDraft
        self.labels = labels
        self.assignees = assignees
        self.comments = comments
        self.updatedAt = updatedAt
        self.move = move
    }
}

public struct PullRequestComment: Hashable, Sendable {
    /// nil for a deleted account.
    public let author: String?
    /// GitHub's `authorAssociation` (OWNER, MEMBER, COLLABORATOR, CONTRIBUTOR, NONE…); nil when unknown.
    public let authorAssociation: String?
    public let body: String
    public let createdAt: Date

    public init(author: String?, authorAssociation: String? = nil, body: String, createdAt: Date) {
        self.author = author
        self.authorAssociation = authorAssociation
        self.body = body
        self.createdAt = createdAt
    }
}

/// One tick's read of a repo: who this Mac is, and what is open.
public struct OpenPullRequests: Sendable {
    public let viewer: String
    public let defaultBranch: String
    public let pullRequests: [PullRequest]
    /// The cursor of the next 100 PRs; nil on the last page.
    public var nextPage: String? = nil
}

public struct MergedPullRequest: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String
    public let number: Int
    public let title: String
    public let author: String
    public let url: URL
    public let mergedAt: Date
    /// Sum of every agent session attributed to this PR; nil until the cost reader exists.
    public var totalCost: Decimal?
    /// The branch and the commit that merged: what a leftover worktree must be at to go.
    public var headRef = ""
    public var headSha = ""
}

/// An agent this Mac starts on a timer (Settings → Schedules): the owner's own prompt in one
/// watched repo, in a clean worktree of its default branch. An entry without repo, agent or
/// prompt (the skeleton's "Poll GitHub") runs nothing.
public struct ScheduleEntry: Identifiable, Hashable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var everyMinutes: Int
    public var enabled: Bool
    public var lastRun: Date?
    public var repo: String?
    public var agent: String?
    public var prompt: String?
    /// The lease item's number (`schedule-<number>`), fixed when the entry is created.
    public var number: Int?
    public var timeoutMinutes: Int?
    /// Runs only when one of the repo's PRs was opened, updated or merged since the last
    /// successful run started, so a queue with nothing new costs nothing.
    public var onlyOnChange: Bool?
    /// The model every run uses (`--model`); nil leaves it to the agent's template.
    public var model: String?
    /// Other agents the run's Claude may ask through Bton's `ask` tool.
    public var helpers: [String]?

    public init(name: String, everyMinutes: Int, enabled: Bool, lastRun: Date? = nil, repo: String? = nil,
                agent: String? = nil, prompt: String? = nil, number: Int? = nil, timeoutMinutes: Int? = nil,
                onlyOnChange: Bool? = nil, model: String? = nil, helpers: [String]? = nil) {
        self.name = name
        self.everyMinutes = everyMinutes
        self.enabled = enabled
        self.lastRun = lastRun
        self.repo = repo
        self.agent = agent
        self.prompt = prompt
        self.number = number
        self.timeoutMinutes = timeoutMinutes
        self.onlyOnChange = onlyOnChange
        self.model = model
        self.helpers = helpers
    }

    /// A model name as `claude --model` and `codex --model` take it, never a flag or shell text.
    public static func isValidModel(_ model: String) -> Bool {
        model.count <= 100 && model.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\[\]-]*/) != nil
    }

    public static let everyMinutesRange = 5...10_080
    public static let timeoutMinutesRange = 1...480

    public func nextRun(after now: Date) -> Date {
        guard let lastRun else { return now }
        return max(now, lastRun.addingTimeInterval(TimeInterval(everyMinutes * 60)))
    }

    /// The lease item and job item; nil while the entry has nothing to run.
    public var item: String? {
        guard repo != nil, agent != nil, prompt?.isEmpty == false, let number else { return nil }
        return "schedule-\(number)"
    }

    /// What keeps the entry from saving, in the words the Schedules pane shows; nil when it can.
    /// `resolve` finds a program on this Mac, so a helper that is not installed is refused here
    /// instead of failing every run.
    public func problem(among others: [ScheduleEntry], agents: [String: AgentTemplate],
                        resolve: (String) -> String? = { Executables.resolve($0) }) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the schedule a name." }
        if others.contains(where: { $0.number != number && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return "Another schedule is called \(name)."
        }
        if !Self.everyMinutesRange.contains(everyMinutes) { return "Run it every 5 minutes to 7 days." }
        if repo == nil { return "Choose the repo it runs in." }
        guard let agent, agents[agent] != nil else { return "Choose an agent from Settings → Agents." }
        if let model, !Self.isValidModel(model) { return "The model name has a character the agent would not accept." }
        if let problem = helpersProblem(agents: agents, resolve: resolve) { return problem }
        if prompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true { return "Write the prompt." }
        if let timeoutMinutes, !Self.timeoutMinutesRange.contains(timeoutMinutes) { return "The time limit is 1 to 480 minutes." }
        return nil
    }

    private func helpersProblem(agents: [String: AgentTemplate], resolve: (String) -> String?) -> String? {
        guard let helpers, !helpers.isEmpty else { return nil }
        guard let agent, agents[agent]?.argv.first.map(AgentHardening.isClaude) == true else {
            return "Only a Claude agent can ask other agents."
        }
        if helpers.count > 3 { return "Pick up to three agents to ask." }
        var seen = Set<String>()
        for helper in helpers {
            if !seen.insert(helper).inserted { return "\(helper) is listed twice." }
            if helper == agent { return "\(helper) already runs the schedule." }
            guard let program = agents[helper]?.argv.first else { return "\(helper) is not an agent in Settings → Agents." }
            if resolve(program) == nil { return "\(helper) needs \(program), which is not installed on this Mac." }
        }
        return nil
    }

    /// A lease item number no other entry uses.
    public static func newNumber(avoiding others: [ScheduleEntry]) -> Int {
        let used = Set(others.compactMap(\.number))
        var number: Int
        repeat { number = Int.random(in: 1...999_999_999) } while used.contains(number)
        return number
    }
}
