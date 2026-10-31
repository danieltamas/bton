import BtonCore
import Foundation
import Observation

/// Which PRs each schedule's agent works on, read from its Claude session: the one it is on now
/// while it runs, every one it acted on once it ended.
@MainActor
@Observable
final class ScheduleWork {
    /// The PR each running schedule's agent works on now, read every few seconds.
    private(set) var current: [UUID: Int] = [:]
    /// Every PR an ended schedule job acted on, first one first. Read once: it no longer changes.
    private(set) var worked: [UUID: [Int]] = [:]

    /// Off the main actor: a session file can be large. A running job's tail only is read, and
    /// ended jobs a page at a time, newest first.
    func read(_ jobs: [Job]) async {
        let schedules = jobs.filter { $0.agent != nil && !$0.key.item.hasPrefix("pr-") }
        let running = schedules.filter { $0.status == .running }.map { ($0.id, $0.worktree) }
        let ended = schedules.filter { $0.status != .running && worked[$0.id] == nil }.prefix(25).map { ($0.id, $0.worktree) }
        guard !running.isEmpty || !current.isEmpty || !ended.isEmpty else { return }
        let (now, done) = await Task.detached {
            let now = Dictionary(uniqueKeysWithValues: running.compactMap { id, worktree in
                ClaudeSessions.sessionFile(id: id, worktree: worktree).flatMap { SessionTranscript.currentPullRequest(ofSessionFile: $0) }.map { (id, $0) }
            })
            // A running job's file may not be there yet: it is read again on the next pass. An
            // ended job's never comes (a codex agent, a transcript gone): it is recorded as none,
            // or the same lookups would run again every pass, for good.
            let done = Dictionary(uniqueKeysWithValues: ended.map { id, worktree in
                (id, ClaudeSessions.sessionFile(id: id, worktree: worktree).map(SessionTranscript.pullRequests(ofSessionFile:)) ?? [])
            })
            return (now, done)
        }.value
        if now != current { current = now }
        if !done.isEmpty { worked.merge(done) { $1 } }
    }

    /// The PRs a schedule job is on or was on, for search.
    func numbers(of job: Job) -> [Int] {
        job.status == .running ? current[job.id].map { [$0] } ?? [] : worked[job.id] ?? []
    }

    /// "on #367" while it runs, "#367, #369" once it ended; nil before it acted on a PR.
    func summary(of job: Job) -> String? {
        if job.status == .running { return current[job.id].map { "on #\($0)" } }
        guard let numbers = worked[job.id], !numbers.isEmpty else { return nil }
        let shown = numbers.prefix(6).map { "#\($0)" }.joined(separator: ", ")
        return numbers.count > 6 ? "\(shown) +\(numbers.count - 6)" : shown
    }
}
