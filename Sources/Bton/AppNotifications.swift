import BtonCore
import Foundation

extension AppStore {
    /// What the last tick showed, to tell what is new after the next.
    struct Before {
        let moves: Set<String>
        let jobs: [Job]
        let merged: Set<String>
        /// Repos held because a service of theirs did not answer, slugs lowercased.
        let outages: Set<String>
        let first: Bool
    }
}

extension IssueAsk {
    var notice: String { "\(id)#\(commentID)" }
}

extension AppStore {
    /// What changed since the last tick and concerns me: a move now waiting for me, a question on
    /// an issue, a job that failed, my PR merged. Nothing on the first tick, which would replay the whole state.
    func notify(since before: Before) {
        // An outage is a live condition, not history: it is told on the first tick too, once
        // per outage, so a Bton launched while Docker is down says so at once.
        for (slug, hold) in outages where !before.outages.contains(slug) {
            Notifier.post(title: "\(slug) waits · \(hold.prefix { $0 != ":" && $0 != " " })", body: hold, id: "outage-\(slug)")
        }
        // The first read only seeds what was already asked.
        let newAsks = issueAsks.filter { notifiedAsks.insert($0.notice).inserted }
        guard !before.first, let me else { return }
        for pr in humanMovesForMe where !before.moves.contains(pr.id) {
            Notifier.post(title: "\(pr.move?.name ?? "Move") · #\(pr.number)", body: pr.title, id: "move-\(pr.id)")
        }
        for ask in newAsks {
            Notifier.post(title: "Asked · #\(ask.number)", body: ask.title, id: "ask-\(ask.notice)")
        }
        let wasRunning = Set(before.jobs.filter { $0.status == .running }.map(\.id))
        for job in jobs where wasRunning.contains(job.id) && job.status != .running {
            let flags = (job.flags ?? []).compactMap(\.label)
            if let verdict = job.verdict, [.escalate, .propose].contains(verdict.action) {
                Notifier.post(title: "Supervisor \(verdict.action.rawValue) · \(job.key.item)", body: verdict.note, id: "job-\(job.id)")
            } else if job.status == .failed || !flags.isEmpty {
                Notifier.post(title: "Job \(job.status == .failed ? "failed" : "flagged") · \(job.key.item) \(job.key.move)",
                              body: (flags + [job.detail].compactMap { $0 }).joined(separator: " · "), id: "job-\(job.id)")
            }
        }
        for pr in merged where !before.merged.contains(pr.id) && pr.author.caseInsensitiveCompare(me) == .orderedSame {
            Notifier.post(title: "Merged · #\(pr.number)", body: pr.title, id: "merged-\(pr.id)")
        }
    }
}
