import Foundation

/// What went wrong with an ended job, read from its status, detail and cost: the Jobs row and the
/// notification show it, and a flagged job is what the supervisor looks at.
public enum JobFlag: String, Codable, Sendable, CaseIterable {
    case timedOut, leaseLost, noVerdict, postFailed, agentFailed, failed, repeated, costly
}

/// The deterministic half of supervision: no model, the same flags for the same jobs every time.
public enum Watchdog {
    /// A job counts as costly from this much, and only against this many succeeded runs of its move.
    static let costFloor: Decimal = 1
    static let costSamples = 5
    static let costWindow = 20
    static let costFactor: Decimal = 3

    public static func flags(for job: Job, among jobs: [Job]) -> [JobFlag] {
        guard job.status == .failed || job.status == .succeeded else { return [] }
        var flags: [JobFlag] = []
        if job.status == .failed {
            flags.append(failure(job.detail))
            let others = jobs.filter { $0.id != job.id && $0.key == job.key && $0.status == .failed }
            if !others.isEmpty { flags.append(.repeated) }
        }
        if isCostly(job, among: jobs) { flags.append(.costly) }
        return flags
    }

    private static func failure(_ detail: String?) -> JobFlag {
        guard let detail else { return .failed }
        if detail == "timed out" { return .timedOut }
        if detail.hasPrefix("lease lost") { return .leaseLost }
        if detail.hasPrefix("final message names no") { return .noVerdict }
        if detail.hasPrefix("posting the review failed") || detail.hasPrefix("decision posted; remove") { return .postFailed }
        if detail.hasPrefix("agent exited") { return .agentFailed }
        return .failed
    }

    private static func isCostly(_ job: Job, among jobs: [Job]) -> Bool {
        guard let cost = job.cost, cost >= costFloor else { return false }
        let costs = jobs.filter {
            $0.id != job.id && $0.status == .succeeded && $0.key.move == job.key.move
                && $0.key.repo.caseInsensitiveCompare(job.key.repo) == .orderedSame
        }
        .sorted { $0.startedAt > $1.startedAt }
        .compactMap(\.cost)
        .prefix(costWindow)
        .sorted()
        guard costs.count >= costSamples else { return false }
        let middle = costs.count / 2
        let median = costs.count.isMultiple(of: 2) ? (costs[middle - 1] + costs[middle]) / 2 : costs[middle]
        return cost > median * costFactor
    }
}
