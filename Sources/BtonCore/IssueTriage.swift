import Foundation

/// An open issue that has not reached `stage:ready` yet: it waits for a priority and a stage.
public struct TriageIssue: Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String
    public let number: Int
    public let title: String
    public let url: URL
    public let createdAt: Date
    public let body: String
    public let labels: [String]

    public init(repo: String, number: Int, title: String, url: URL, createdAt: Date, body: String, labels: [String]) {
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.body = body
        self.labels = labels
    }

    public var priority: String? { IssueTriage.label(withPrefix: IssueTriage.priorityPrefix, in: labels) }
    public var stage: String? { IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: labels) }
}

public struct TriageQuestion: Hashable, Sendable {
    public let text: String
    /// What the answer is used for, in a line.
    public let help: String
    public let options: [TriageOption]
}

public struct TriageOption: Hashable, Sendable {
    public let label: String
    /// An example, so the choice is clear without knowing the code.
    public let hint: String
}

/// The result of the answers: a score out of `IssueTriage.maxScore` and the labels it sets.
public struct TriageVerdict: Hashable, Sendable {
    public let score: Int
    public let priority: String
    public let stage: String

    public var labels: [String] { [IssueTriage.priorityPrefix + priority, IssueTriage.stagePrefix + stage] }
}

/// Triage of issues from the menu bar: three fixed questions per issue, answered with a click, so
/// opening an issue never waits on an agent. The answers add up to a score that ranks the issue
/// against every other one, and decide whether it is ready to build:
/// - impact (0-5): how bad the problem is today;
/// - urgency (0-3): how soon it needs doing;
/// - start (0-1 point): a small, clear plan is a quick win. It also sets the stage: only a clear
///   plan is `ready`; an open decision or a high-risk area (docs/TRIAGE.md in lexito) is `spec`;
///   a missing repro stays at `triage`.
public enum IssueTriage {
    public static let priorityPrefix = "priority:"
    public static let stagePrefix = "stage:"
    /// Stages an agent or a PR already owns: not waiting for triage.
    static let settledStages: Set<String> = ["ready", "in-progress", "review"]
    public static let maxScore = 9

    /// An option's points; `stage` is the stage a start option leads to.
    struct Choice { let label: String; let hint: String; let points: Int; let stage: String? }

    static let impact = [
        Choice(label: "Users cannot do something important, or data is lost or wrong",
               hint: "A payment fails, a document disappears, a total is wrong.", points: 5, stage: nil),
        Choice(label: "A main flow is worse, but there is a workaround",
               hint: "A button is broken, but the same thing works from another screen.", points: 3, stage: nil),
        Choice(label: "A small annoyance, or only the team sees it",
               hint: "A typo, a slow admin page, an ugly layout.", points: 1, stage: nil),
        Choice(label: "Nobody would notice if it stayed as it is", hint: "", points: 0, stage: nil),
    ]
    static let urgency = [
        Choice(label: "Right now",
               hint: "It breaks things today, blocks a release, or blocks other work.", points: 3, stage: nil),
        Choice(label: "This month",
               hint: "It should be done soon, but nothing breaks while it waits.", points: 2, stage: nil),
        Choice(label: "No deadline", hint: "Do it when there is time.", points: 0, stage: nil),
    ]
    static let start = [
        Choice(label: "Yes, and it is small",
               hint: "The issue says what to do and when it is done. About one PR.", points: 1, stage: "ready"),
        Choice(label: "Yes, but it is big",
               hint: "It is clear, but it needs splitting into several PRs.", points: 0, stage: "ready"),
        Choice(label: "No, I must decide something first",
               hint: "For example the scope, the price, or which approach to take.", points: 0, stage: "spec"),
        Choice(label: "No, it touches something risky",
               hint: "Login, payments, personal data, a database migration or deleting data: a plan is reviewed first.",
               points: 0, stage: "spec"),
        Choice(label: "No, it needs more information",
               hint: "There are no steps to reproduce it, or it is unclear what is wanted.", points: 0, stage: "triage"),
    ]

    public static let questions = [
        TriageQuestion(text: "How bad is the problem today?",
                       help: "Sets most of the score (0 to 5 points). Think of the person who runs into it.",
                       options: impact.map { TriageOption(label: $0.label, hint: $0.hint) }),
        TriageQuestion(text: "How soon does it need to be done?",
                       help: "Adds 0 to 3 points.",
                       options: urgency.map { TriageOption(label: $0.label, hint: $0.hint) }),
        TriageQuestion(text: "Could someone start building it today?",
                       help: "Decides the stage: only a clear plan becomes ready. A small one adds 1 point.",
                       options: start.map { TriageOption(label: $0.label, hint: $0.hint) }),
    ]

    static func label(withPrefix prefix: String, in labels: [String]) -> String? {
        labels.first { $0.lowercased().hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)).lowercased() }
    }

    /// Open issues still waiting for a stage, those with no priority first, then the oldest.
    public static func pending(_ issues: [OpenIssue]) -> [TriageIssue] {
        issues.compactMap { issue -> TriageIssue? in
            let labels = issue.labels
            guard label(withPrefix: stagePrefix, in: labels).map(settledStages.contains) != true else { return nil }
            return TriageIssue(repo: issue.repo, number: issue.number, title: issue.title, url: issue.url,
                               createdAt: issue.createdAt, body: issue.body, labels: labels)
        }
        .sorted { lhs, rhs in
            (lhs.priority == nil) != (rhs.priority == nil) ? lhs.priority == nil : lhs.createdAt < rhs.createdAt
        }
    }

    /// 6 and over is high, 3 to 5 medium, below that low.
    static func priority(forScore score: Int) -> String { score >= 6 ? "high" : score >= 3 ? "medium" : "low" }

    /// The score and labels the answers (one option index per question) decide; nil until all are answered.
    public static func verdict(_ answers: [Int?]) -> TriageVerdict? {
        guard answers.count == 3, let first = answers[0], let second = answers[1], let third = answers[2],
              impact.indices.contains(first), urgency.indices.contains(second), start.indices.contains(third),
              let stage = start[third].stage
        else { return nil }
        let score = impact[first].points + urgency[second].points + start[third].points
        return TriageVerdict(score: score, priority: priority(forScore: score), stage: stage)
    }

    /// The edit that turns the issue's labels into the verdict's: what to add and what to remove.
    public static func edit(for verdict: TriageVerdict, on issue: TriageIssue) -> (add: [String], remove: [String]) {
        let wanted = Set(verdict.labels.map { $0.lowercased() })
        let remove = issue.labels.filter { label in
            let lower = label.lowercased()
            return (lower.hasPrefix(priorityPrefix) || lower.hasPrefix(stagePrefix)) && !wanted.contains(lower)
        }
        let add = verdict.labels.filter { label in !issue.labels.contains { $0.caseInsensitiveCompare(label) == .orderedSame } }
        return (add, remove)
    }
}

extension GitHubClient {
    /// Sets an issue's labels in one edit.
    public func editIssueLabels(add: [String], remove: [String], repo: String, number: Int) async throws {
        guard !add.isEmpty || !remove.isEmpty else { return }
        _ = try await gh(["issue", "edit", String(number), "--repo", repo]
                         + (add.isEmpty ? [] : ["--add-label", add.joined(separator: ",")])
                         + (remove.isEmpty ? [] : ["--remove-label", remove.joined(separator: ",")]))
    }
}
