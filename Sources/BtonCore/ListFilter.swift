import Foundation

/// One choice of the dropdown beside a tab's search box: a kind of card or a state, narrowing
/// the searched list to the rows of it. Each tab offers the choices its rows can be in, with
/// the count each would show, so a long Issues tab goes to "the ones needing a reply" in a click.
public struct ListFilter: Hashable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let help: String

    public init(id: String, title: String, help: String) {
        self.id = id
        self.title = title
        self.help = help
    }

    // MARK: pull requests

    /// What a PR row can be, read from its move and this Mac's jobs on it.
    public struct PullRequestFacts: Sendable {
        public let moveName: String?
        public let mine: Bool
        public let unassigned: Bool
        public let working: Bool
        public let draft: Bool
        public let conflicting: Bool

        public init(moveName: String?, mine: Bool, unassigned: Bool, working: Bool, draft: Bool, conflicting: Bool) {
            self.moveName = moveName
            self.mine = mine
            self.unassigned = unassigned
            self.working = working
            self.draft = draft
            self.conflicting = conflicting
        }

        public var ids: Set<String> {
            var ids = Set<String>()
            if mine { ids.insert("mine") }
            if unassigned { ids.insert("unassigned") }
            if working { ids.insert("working") }
            if draft { ids.insert("draft") }
            if conflicting { ids.insert("conflicts") }
            if let moveName { ids.insert("move:" + moveName) }
            return ids
        }
    }

    /// The fixed states first, then one per move name the list holds, in the list's order.
    public static func pullRequestFilters(moves: [String]) -> [ListFilter] {
        let fixed = [
            ListFilter(id: "mine", title: "Mine", help: "PRs whose move is yours to make"),
            ListFilter(id: "unassigned", title: "Unassigned", help: "PRs whose move has nobody yet"),
            ListFilter(id: "working", title: "Working", help: "PRs an agent of this Mac works on now"),
            ListFilter(id: "draft", title: "Draft", help: "Draft PRs"),
            ListFilter(id: "conflicts", title: "Conflicts", help: "PRs in conflict with their base"),
        ]
        return fixed + distinct(moves).map {
            ListFilter(id: "move:" + $0, title: $0, help: "PRs whose move is \($0)")
        }
    }

    // MARK: issues

    /// What a row of the Issues tab can be: a question for me in one of its states, or a ready issue.
    public enum IssueState: String, CaseIterable, Sendable {
        case needsReply = "needs-reply", draftReady = "draft-ready", replyPosted = "reply-posted", handedOff = "handed-off"
        case unclaimed, owned, working, failed

        public var filter: ListFilter {
            switch self {
            case .needsReply: ListFilter(id: rawValue, title: "Needs a reply", help: "Questions for you with no reply yet")
            case .draftReady: ListFilter(id: rawValue, title: "Draft ready", help: "Questions whose draft reply waits for you")
            case .replyPosted: ListFilter(id: rawValue, title: "Reply posted", help: "Questions you answered since the last sync")
            case .handedOff: ListFilter(id: rawValue, title: "Handed to me", help: "Issues a teammate or an agent handed to you")
            case .unclaimed: ListFilter(id: rawValue, title: "Unclaimed", help: "Ready issues nobody has yet")
            case .owned: ListFilter(id: rawValue, title: "Has owner", help: "Issues someone is assigned to")
            case .working: ListFilter(id: rawValue, title: "Working", help: "Issues an agent of this Mac works on now")
            case .failed: ListFilter(id: rawValue, title: "Failed", help: "Issues whose last job failed or was stopped")
            }
        }
    }

    public static var issueFilters: [ListFilter] { IssueState.allCases.map(\.filter) }

    /// The states of a question for me, from its draft and decision jobs and whether I posted.
    public static func askStates(posted: Bool, handoff: Bool, draft: Job.Status?, decision: Job.Status?) -> Set<String> {
        var states = Set<String>()
        if handoff { states.insert(IssueState.handedOff.rawValue) }
        if posted || decision == .succeeded {
            states.insert(IssueState.replyPosted.rawValue)
        } else if draft == .succeeded {
            states.insert(IssueState.draftReady.rawValue)
        } else if draft == .running || decision == .running {
            states.insert(IssueState.working.rawValue)
            states.insert(IssueState.needsReply.rawValue)
        } else {
            states.insert(IssueState.needsReply.rawValue)
        }
        if draft == .failed || draft == .cancelled || decision == .failed || decision == .cancelled {
            states.insert(IssueState.failed.rawValue)
        }
        return states
    }

    /// The states of a ready issue, from its assignees and its newest job.
    public static func readyStates(isReady: Bool, assignees: [String], job: Job.Status?) -> Set<String> {
        var states = Set<String>()
        if assignees.isEmpty, isReady { states.insert(IssueState.unclaimed.rawValue) }
        if !assignees.isEmpty { states.insert(IssueState.owned.rawValue) }
        if job == .running { states.insert(IssueState.working.rawValue) }
        if job == .failed || job == .cancelled { states.insert(IssueState.failed.rawValue) }
        return states
    }

    // MARK: triage

    /// One filter per `type:` and `priority:` label the list holds, types first, each in label order.
    public static func triageFilters(labels: [[String]]) -> [ListFilter] {
        let types = distinct(labels.flatMap { $0 }.filter { $0.lowercased().hasPrefix("type:") })
        let priorities = distinct(labels.flatMap { $0 }.filter { $0.lowercased().hasPrefix(IssueTriage.priorityPrefix) })
        return (types + priorities).map { ListFilter(id: "label:" + $0.lowercased(), title: $0, help: "Issues labeled \($0)") }
    }

    public static func triageIds(labels: [String]) -> Set<String> { Set(labels.map { "label:" + $0.lowercased() }) }

    // MARK: jobs

    /// Every status, flagged, then one per move the list holds.
    public static func jobFilters(_ jobs: [Job]) -> [ListFilter] {
        let statuses = [Job.Status.running, .succeeded, .failed, .cancelled].map {
            ListFilter(id: "status:" + $0.rawValue, title: $0.rawValue.capitalized, help: "Jobs \($0.rawValue)")
        }
        let flagged = ListFilter(id: "flagged", title: "Flagged", help: "Jobs the watchdog flagged: timed out, costly, recurring...")
        return statuses + [flagged] + distinct(jobs.map(\.key.move)).map {
            ListFilter(id: "move:" + $0, title: $0, help: "Jobs of the \($0) move")
        }
    }

    public static func jobIds(_ job: Job) -> Set<String> {
        var ids: Set<String> = ["status:" + job.status.rawValue, "move:" + job.key.move]
        if !(job.flags ?? []).isEmpty { ids.insert("flagged") }
        return ids
    }

    // MARK: merged

    public static let mergedFilters = [ListFilter(id: "mine", title: "Mine", help: "PRs you wrote")]

    public static func mergedIds(author: String, me: String?) -> Set<String> {
        me.map { author.caseInsensitiveCompare($0) == .orderedSame } == true ? ["mine"] : []
    }

    // MARK: helpers

    private static func distinct(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0.lowercased()).inserted }
    }
}
