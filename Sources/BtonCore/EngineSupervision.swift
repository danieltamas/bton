import Foundation

extension Engine {
    /// How much of a flagged job's log and output the supervisor is shown.
    static let supervisorLogLimit = 3000

    /// Acts once on each supervisor's answer. A retry is asked on the flagged job first, with its
    /// note, so a restart between the two saves repeats nothing and loses nothing.
    func applyVerdicts() {
        let all = jobs.all()
        if !restoredRetries {
            restoredRetries = true
            restoreRetries(all)
        }
        for var job in all where job.key.move == Supervision.move && job.status == .succeeded {
            guard var verdict = job.verdict, verdict.applied != true else { continue }
            if verdict.action == .retry, let flagged = all.first(where: { $0.id == job.supervises }) {
                // Not saved: the next tick asks again rather than marking a retry that never was.
                guard let outcome = retry(flagged, steeredBy: verdict.note) else { continue }
                verdict.outcome = outcome
            }
            verdict.applied = true
            job.verdict = verdict
            do {
                try jobs.save(job)
            } catch {
                log("\(job.key): supervisor verdict not saved: \(error.localizedDescription)")
            }
        }
    }

    /// The flagged move first in line again, its note saved on the flagged job; nil when that save failed.
    private func retry(_ flagged: Job, steeredBy note: String) -> String? {
        // A command has no prompt for the note to steer: it would run unchanged, with the same limit.
        if flagged.agent == nil, flagged.flags?.contains(.timedOut) == true {
            return "not retried: a command that timed out runs again unchanged, with the same time limit; "
                + "raise the move's timeoutMinutes or speed up the command, then press Retry"
        }
        do {
            guard try jobs.requestSteeredRetry(flagged.id, note: note) else { return "not retried: the job can no longer be retried" }
        } catch {
            log("\(flagged.key): supervisor retry not saved: \(error.localizedDescription)")
            return nil
        }
        // The owner's press stands for the same head: a retry of a pressed merge is pressed too, or the repo's
        // checks that guard a person's decision would fail it at once.
        runNext(repo: flagged.key.repo, item: flagged.key.item, pressed: flagged.pressed == true)
        ask(flagged.key)
        log("\(flagged.key): supervisor retry")
        return "retried"
    }

    /// After a restart, the run-next picks are gone: a steered retry that has not run yet, asked
    /// within the supervision window, goes back in line.
    private func restoreRetries(_ all: [Job]) {
        for job in all where job.key.move == Supervision.move && job.verdict?.outcome == "retried"
            && (job.endedAt ?? .distantPast) >= Date.now.addingTimeInterval(-Supervision.window) {
            guard let flagged = all.first(where: { $0.id == job.supervises }), flagged.steer != nil,
                  !all.contains(where: { $0.key.repo == flagged.key.repo && $0.key.item == flagged.key.item
                      && $0.key.move == flagged.key.move && $0.startedAt > flagged.startedAt }) else { continue }
            runNext(repo: flagged.key.repo, item: flagged.key.item)
            ask(flagged.key)
        }
    }

    /// The end of a job's log and of its final output.
    nonisolated func supervisorLog(_ job: Job) -> String {
        let read = { (url: URL) in
            String(((try? String(contentsOf: url, encoding: .utf8)) ?? "").suffix(Self.supervisorLogLimit))
        }
        return "log:\n" + read(jobs.logURL(job.id)) + "\n\noutput:\n" + read(jobs.outputURL(job.id))
    }
}
