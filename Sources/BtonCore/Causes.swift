import Foundation

/// Why a job failed, as a key Bton can count: read from the structured detail Bton wrote itself,
/// never from an agent's or gh's text. The same key on two items of a repo is a setup problem
/// (a check that fails on every PR, an agent that never pushes), not two jobs' bad luck.
public enum Cause {
    /// A failure older than this no longer counts as a repeat.
    public static let window: TimeInterval = 14 * 86400

    /// The job's cause key, or nil for a job that did not fail or whose detail Bton did not write.
    /// The prefix decides: `agent exited 1 after: check x` is an agent exit.
    public static func key(for job: Job) -> String? {
        guard job.status == .failed, let detail = job.detail else { return nil }
        if detail.hasPrefix("check "), let argv = backticked(detail) { return "check:" + argv }
        if detail.hasPrefix("posting the check failure failed: check "), let argv = backticked(detail) { return "check:" + argv }
        if detail.hasPrefix("checks not green: ") { return "red:" + redChecks(detail).joined(separator: ",") }
        if detail.hasPrefix("timed out") || detail.hasSuffix(" minutes and was stopped") { return "timeout" }
        if detail.hasPrefix(DispatchPlanner.endedWithoutPushing) { return "no-push" }
        if detail.hasPrefix("agent exited ") {
            let code = detail.dropFirst("agent exited ".count).prefix { $0.isNumber }
            return code.isEmpty ? "agent-exit" : "agent-exit:" + code
        }
        if detail.hasPrefix("lease lost") { return "lease-lost" }
        if detail.hasPrefix("posting the review failed") { return "post-failed" }
        if detail.hasPrefix("proves nothing: ") { return "proves-nothing" }
        if detail.hasPrefix("proof still red: ") { return "proof-red" }
        if detail.hasPrefix("proof: ") { return "proof-failed" }
        if detail.hasPrefix("environment: ") { return "environment" }
        return nil
    }

    /// The other items of the repo whose jobs failed with the same cause within `window` before
    /// `now`, sorted. The job's own item never counts: a cause that fails three times on one PR is
    /// the `repeated` flag's, not a repeat across items.
    public static func repeats(of job: Job, among jobs: [Job], now: Date = .now) -> [String] {
        guard let key = key(for: job) else { return [] }
        let since = now.addingTimeInterval(-window)
        let items = jobs.filter { other in
            other.id != job.id && other.key.repo.caseInsensitiveCompare(job.key.repo) == .orderedSame
                && other.key.item != job.key.item && (since...now).contains(other.endedAt ?? .distantPast) && Self.key(for: other) == key
        }.map(\.key.item)
        return Array(Set(items)).sorted()
    }

    /// The text of the first backtick span, where the check runner logs the argv.
    private static func backticked(_ text: String) -> String? {
        let parts = text.split(separator: "`", omittingEmptySubsequences: false)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// The check names in `checks not green: gate failure, lint pending; nothing was run`: each
    /// entry's text before its last space, the count of unread checks dropped.
    private static func redChecks(_ detail: String) -> [String] {
        let list = detail.dropFirst("checks not green: ".count).split(separator: ";").first ?? ""
        return list.split(separator: ",").compactMap { entry -> String? in
            let entry = entry.trimmingCharacters(in: .whitespaces)
            guard entry != "more checks than were read", let space = entry.lastIndex(of: " ") else { return nil }
            return String(entry[..<space])
        }.sorted()
    }
}
