import Foundation

extension Engine {
    /// Why the repo's jobs wait this tick: a service its environment names (`DATABASE_URL`,
    /// a Redis) did not answer the probe. Nil when every service answers, or the environment
    /// names none. Probed once per repo and tick, before anything of the repo is taken or planned.
    func environmentHold(of repo: WatchedRepo) async -> String? {
        let endpoints = EnvironmentProbe.endpoints(in: repo.environment ?? [:])
        guard !endpoints.isEmpty else { return nil }
        return EnvironmentProbe.hold(await EnvironmentProbe.unreachable(endpoints))
    }

    /// The repo's candidates from `first` on that need the environment leave `pending`, the
    /// registry job included: the environment is the repo's on this Mac, and a held tick costs
    /// nothing, while a check against a dead database costs its whole timeout. The text-only jobs
    /// stay and start. Each other run-next pick of the repo keeps its place with the hold as its
    /// reason, as a pick waiting for the code graph does. A held build of an issue I already
    /// claimed says so on the issue (`noticeHeldBuilds`).
    func holdPending(_ repo: WatchedRepo, hold: String, me: String,
              pending: inout [(candidate: DispatchCandidate, clone: URL, flow: Flow?)], from first: Int) async {
        let textOnly = pending[first...].filter(\.candidate.textOnly)
        let held = pending[first...].filter { !$0.candidate.textOnly }.map(\.candidate)
        pending.removeSubrange(first...)
        pending += textOnly
        let starting = Set(textOnly.map { Self.pick(repo: $0.candidate.key.repo, item: $0.candidate.key.item) })
        let prefix = repo.slug.lowercased() + "#"
        for pick in next where pick.hasPrefix(prefix) && !starting.contains(pick) { deferred[pick] = hold }
        await noticeHeldBuilds(held, me: me)
    }

    /// Takes this tick's holds for the repos judged in it, logging each hold that starts or
    /// lifts: a hold can last days, and a notification alone is missed. A repo not judged this
    /// tick (its read failed, a quick tick did not probe it) keeps its last hold while it is
    /// still in `known`. Returns the holds to show.
    func settleOutages(_ now: [String: String], judged: Set<String>, known: Set<String>) -> [String: String] {
        var settled = outages.filter { !judged.contains($0.key) && known.contains($0.key) }
        for slug in judged.sorted() {
            switch (outages[slug], now[slug]) {
            case (nil, let hold?): log("\(slug): jobs held, only text jobs start: \(hold)")
            case (_?, nil): log("\(slug): the hold lifted, its jobs start again")
            default: break
            }
            if let hold = now[slug] { settled[slug] = hold }
        }
        outages = settled
        return settled
    }

    /// The resumes of issues I claimed that a hold keeps from starting: each says on its issue,
    /// once per waiting build, that the claim is not abandoned. A teammate reads the issue, not
    /// this Mac's log; a claim that sits silent for days reads as taken and dropped. Checked
    /// against the issue's comments before the first post of each build, so a restarted Bton does
    /// not post again, and against the issue as it is now (open, mine, in progress); a failed read
    /// or post is tried again on the next held tick.
    private func noticeHeldBuilds(_ held: [DispatchCandidate], me: String) async {
        for candidate in held {
            guard candidate.key.move == IssueIntake.move, case let .issue(plan) = candidate.target, plan.resumes,
                  let job = IssueIntake.latestJob(for: plan.issue, repo: candidate.key.repo, jobs: jobs.all()),
                  !heldNoticed.contains(job.id) else { continue }
            let marker = "\(IssueIntake.heldMarker) \(job.id.uuidString)"
            // The app and a `bton watch` on the same home both tick: the read and the post run under
            // one lock per build, and the one that finds it taken leaves it for the next tick, where
            // the comment the other posted is read back.
            let locks = home.url.appendingPathComponent("locks", isDirectory: true)
            try? FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            guard let lock = LocalLock(locks.appendingPathComponent("held-\(job.id.uuidString).lock")) else { continue }
            defer { lock.release() }
            do {
                let said = try await github.issueComments(repo: candidate.key.repo, number: plan.issue).contains { comment in
                    comment.author?.caseInsensitiveCompare(me) == .orderedSame && BtonMarker.keys(in: comment.body).contains(marker)
                }
                // Read live right before saying it stays claimed: the sync's copy may be minutes old, and
                // an issue closed, unassigned from me or moved on since is not mine to speak for.
                let now = try await github.issueNow(repo: candidate.key.repo, number: plan.issue)
                guard now.state == "OPEN", now.assignees.contains(where: { $0.caseInsensitiveCompare(me) == .orderedSame }),
                      IssueTriage.label(withPrefix: IssueTriage.stagePrefix, in: now.labels) == IssueIntake.inProgressStage
                else { continue }
                if !said {
                    try await github.commentOnIssue(repo: candidate.key.repo, number: plan.issue,
                                                    body: IssueIntake.heldComment(login: me, job: job.id))
                    log("\(candidate.key.repo)#\(plan.issue): said on the issue that its build waits for the hold")
                }
                heldNoticed.insert(job.id)
            } catch {
                log("\(candidate.key.repo)#\(plan.issue): could not say on the issue that its build waits: \(error.localizedDescription)")
            }
        }
    }
}
