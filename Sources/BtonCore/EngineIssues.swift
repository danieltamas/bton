import Foundation

extension Engine {
    /// Load more never asks for more pages than this (500 issues).
    public static let issuePageCap = 10

    /// What Load more shows at once: the repo's issues to triage after the extra page, and
    /// whether GitHub holds more.
    public struct IssuePage: Sendable {
        public let triage: [TriageIssue]
        public let more: Bool
        /// The read these rows come from: a sync's snapshot from an earlier read does not replace them.
        public let revision: Int
    }

    /// A repo's open issues, as many pages as Load more asked for; a failure keeps the last read
    /// whole and never stops the repo's PR work. Answers whether the read went through. One read
    /// per repo at a time: a caller that finds one in flight waits for its answer, and reads again
    /// only when Load more asked for more pages since that read started.
    @discardableResult
    func readIssues(_ repo: String) async -> Bool {
        let slug = repo.lowercased()
        while let running = issueReads[slug] {
            let ok = await running.task.value
            if running.pages >= max(1, issuePages[slug] ?? 1) { return ok }
        }
        let id = UUID(), pages = max(1, issuePages[slug] ?? 1)
        let task = Task {
            let ok = await self.readIssuePages(repo, pages: pages)
            // Gone before the task ends, so no waiter wakes to a finished read and waits on it again.
            if self.issueReads[slug]?.id == id { self.issueReads[slug] = nil }
            return ok
        }
        issueReads[slug] = (id, pages, task)
        return await task.value
    }

    private func readIssuePages(_ repo: String, pages: Int) async -> Bool {
        let slug = repo.lowercased()
        let revision = (issueRevisions[slug] ?? 0) + 1
        issueRevisions[slug] = revision
        let started = Date.now
        var issues: [OpenIssue] = [], after: String?
        for page in 1...pages {
            do {
                let read = try await github.openIssues(repo: repo, after: after)
                issues += read.issues
                after = read.nextPage
            } catch {
                log("\(repo): issues page \(page) not read: \(error.localizedDescription)")
                return false
            }
            if after == nil { break }
        }
        // One copy per issue, the first, before the rereads: a second copy would outlive a reread that found it closed.
        var seen = Set<Int>()
        issues = issues.filter { seen.insert($0.number).inserted }
        // A failed read keeps the page's copy: the card stays rather than vanishing on a hiccup.
        var whole = Set<Int>()
        for held in IssueIntake.heldByEvents(issues, jobs: jobs.all()) {
            let read: OpenIssue?
            do { read = try await github.openIssue(repo: repo, number: held.number) } catch { continue }
            guard let index = issues.firstIndex(where: { $0.number == held.number }) else { continue }
            // Closed since the page was read: gone from the list like any closed issue.
            if let read { issues[index] = read; whole.insert(held.number) } else { issues.remove(at: index) }
        }
        // A read started later (a Load more during a sync, or the reverse) owns the list now.
        guard issueRevisions[slug] == revision else { return false }
        openIssues[slug] = issues
        wholeIssues[slug] = whole
        // An edit made here after this read began is not in what GitHub answered: it stays on
        // top until a read that started after it; one this read already saw is done with.
        let kept = (labelEdits[slug] ?? []).filter { $0.at > started && $0.at > .now - Self.labelEditTTL }
        labelEdits[slug] = kept.isEmpty ? nil : kept
        for edit in kept { applyLabelEdit(edit, in: slug) }
        issuesReadThisTick.insert(slug)
        lastIssueReads[slug] = (.now, pages)
        if after == nil { issuesMore.remove(slug) } else { issuesMore.insert(slug) }
        return true
    }

    /// A label edit made on this Mac, as the engine keeps it until a read sees it on GitHub.
    public struct LabelEdit: Sendable {
        public let number: Int
        public let add: [String]
        public let remove: [String]
        /// The login the edit took off the issue (a give-back), if any.
        public let unassign: String?
        public let at: Date
    }

    /// An edit the reads never confirm (a repo gone from the config, a read failing for long) is
    /// forgotten after this.
    public static let labelEditTTL: TimeInterval = 600

    /// A label edit this Mac just made on GitHub: the issue shows it at once, and a read that
    /// started before the edit (a sync in flight when the owner pressed) cannot put the old
    /// labels back. The edit is dropped by the first read that started after it.
    public func noteLabelEdit(repo: String, number: Int, add: [String], remove: [String], unassign: String? = nil) {
        let slug = repo.lowercased()
        let edit = LabelEdit(number: number, add: add, remove: remove, unassign: unassign, at: .now)
        labelEdits[slug, default: []].append(edit)
        applyLabelEdit(edit, in: slug)
    }

    private func applyLabelEdit(_ edit: LabelEdit, in slug: String) {
        guard let index = openIssues[slug]?.firstIndex(where: { $0.number == edit.number }) else { return }
        let issue = openIssues[slug]![index]
        let assignees = issue.assignees.filter { assignee in
            edit.unassign.map { $0.caseInsensitiveCompare(assignee) != .orderedSame } ?? true
        }
        openIssues[slug]![index] = issue.with(labels: RepoLabels.apply((add: edit.add, remove: edit.remove), to: issue.labels),
                                              assignees: assignees, stateChangedAt: edit.at)
    }

    /// Load more: the next sync reads one page more of the repo's issues, and keeps doing so.
    public func loadMoreIssues(repo: String) {
        let slug = repo.lowercased()
        issuePages[slug] = min(Self.issuePageCap, (issuePages[slug] ?? 1) + 1)
    }

    /// Load more, pressed: the extra page is read now, not at the next sync, and the rows to
    /// show come back. Nil when the read failed: the last list stands and the next sync reads
    /// the extra page again.
    public func readMoreIssues(repo: String) async -> IssuePage? {
        loadMoreIssues(repo: repo)
        guard await readIssues(repo) else { return nil }
        let slug = repo.lowercased()
        return IssuePage(triage: IssueTriage.pending(openIssues[slug] ?? []), more: issuesMore.contains(slug),
                         revision: issueRevisions[slug] ?? 0)
    }

    /// `flows` as read this tick: a repo's Decisions table makes its open rows for me asks too.
    func issueAsks(in repos: [WatchedRepo], me: String?, flows: [String: FlowStatus]) -> [IssueAsk] {
        guard let me else { return [] }
        return repos.flatMap { repo in
            IssueAsks.asks(openIssues[repo.slug.lowercased()] ?? [], me: me, table: flows[repo.slug]?.flow?.decide?.table)
        }.sorted { $0.askedAt > $1.askedAt }
    }

    /// Drafts the owner's reply to an ask at the next sync, first in line.
    public func requestDraft(_ ask: IssueAsk) {
        draftRequests.removeAll { $0.id == ask.id }
        draftRequests.append(ask)
        runNext(repo: ask.repo, item: "issue-\(ask.number)")
    }

    /// The draft jobs this repo's requests ask for, from the issues as read this tick. A request
    /// whose ask is gone or changed, or whose draft already ran, ends here; one whose issues were
    /// not read this tick waits for a read, rather than start on a thread that may be answered.
    func draftCandidates(repo: String, defaultBranch: String, me: String, agents: [String: AgentTemplate],
                         model: String, table: Flow.DecisionTable?) -> [DispatchCandidate] {
        guard issuesReadThisTick.contains(repo.lowercased()) else { return [] }
        let issues = openIssues[repo.lowercased()] ?? []
        let all = jobs.all()
        let ran = Set(all.map(\.key))
        // A draft I pressed Retry on asks again, as long as its comment is still the ask.
        for ask in IssueAsks.asks(issues, me: me, table: table)
        where DispatchPlanner.isRetry(IssueDrafts.key(for: ask), jobs: all) && !draftRequests.contains(where: { $0.id == ask.id }) {
            draftRequests.append(ask)
        }
        var made: [DispatchCandidate] = []
        draftRequests.removeAll { ask in
            guard ask.repo.caseInsensitiveCompare(repo) == .orderedSame else { return false }
            guard let issue = issues.first(where: { $0.number == ask.number }),
                  let candidate = IssueDrafts.candidate(ask: ask, issue: issue, agents: agents, defaultBranch: defaultBranch,
                                                        me: me, model: model, table: table),
                  !ran.contains(candidate.key) || DispatchPlanner.isRetry(candidate.key, jobs: all) else { return true }
            made.append(candidate)
            return false
        }
        return made
    }

    /// The decide jobs of the asks this repo's owner is away from: one per asking comment, when the
    /// repo starts its moves, from the issues as read this tick. An ask already decided (or being
    /// decided) waits for the sync that reads the decision and clears it; a failed one runs again on Retry.
    /// An issue Bton already ruled on `IssueDecisions.maxRulings` times since a person last spoke
    /// gets no further decide: its ask stays in Waiting on you, for the owner or whoever comes.
    func decideCandidates(repo: String, flow: Flow, defaultBranch: String, me: String, agents: [String: AgentTemplate]) -> [DispatchCandidate] {
        guard flow.decide != nil, issuesReadThisTick.contains(repo.lowercased()) else { return [] }
        let issues = openIssues[repo.lowercased()] ?? []
        let all = jobs.all()
        let ran = Set(all.filter { $0.retry != true }.map(\.key))
        return IssueAsks.asks(issues, me: me, table: flow.decide?.table).compactMap { ask in
            guard let issue = issues.first(where: { $0.number == ask.number }),
                  IssueDecisions.rulingsSinceHuman(issue: issue, me: me, jobs: all) < flow.maxRulings,
                  let candidate = IssueDecisions.candidate(ask: ask, issue: issue, flow: flow, agents: agents, defaultBranch: defaultBranch, me: me),
                  !ran.contains(candidate.key) else { return nil }
            return candidate
        }
    }

    /// The repo's next issue move (triage, stage, restage), when the repo starts its moves and
    /// its issues were read this tick: one new per sync, after the PRs, the intake and the decisions.
    /// A rule that asks whether a person demoted the issue reads its label events, which a page of
    /// 50 cuts to the oldest few: the issue it picks is read again on its own and the pick made
    /// again, until the pick stands on a whole read (or `wholeReadsPerPick` reads are spent and
    /// nothing starts this sync).
    func issueMoveCandidates(repo: String, flow: Flow, pullRequests: [PullRequest], me: String,
                             agents: [String: AgentTemplate]) async -> [DispatchCandidate] {
        let slug = repo.lowercased()
        guard flow.issues?.isEmpty == false, issuesReadThisTick.contains(slug) else { return [] }
        var reads = 0
        while true {
            guard let candidate = IssueMoves.candidate(issues: openIssues[slug] ?? [], flow: flow, pullRequests: pullRequests,
                                                       jobs: jobs.all(), repo: repo, me: me, agents: agents, ranElsewhere: issueMovesRanElsewhere),
                  let plan = candidate.issueMove else { return [] }
            guard IssueMoves.readsLabelEvents(plan.when), !(wholeIssues[slug] ?? []).contains(plan.number) else { return [candidate] }
            guard reads < Self.wholeReadsPerPick, await readWhole(plan.number, in: repo) else { return [] }
            reads += 1
        }
    }

    static let wholeReadsPerPick = 5

    /// The issue read on its own, in place of its page copy: its label events and state change
    /// whole. False when the read failed; a closed issue leaves the list.
    func readWhole(_ number: Int, in repo: String) async -> Bool {
        let slug = repo.lowercased()
        let whole: OpenIssue?
        do { whole = try await github.openIssue(repo: repo, number: number) } catch {
            log("\(repo)#\(number): not read on its own: \(error.localizedDescription)")
            return false
        }
        guard var issues = openIssues[slug], let index = issues.firstIndex(where: { $0.number == number }) else { return false }
        if let whole { issues[index] = whole } else { issues.remove(at: index) }
        openIssues[slug] = issues
        wholeIssues[slug, default: []].insert(number)
        return true
    }

    /// Asks the agent for the next turn of a new issue, first in line at the next sync.
    public func requestCompose(_ request: NewIssues.Request) {
        composeRequests.removeAll { $0.key == request.key }
        composeRequests.append(request)
        runNext(repo: request.repo, item: request.key.item)
    }

    /// The turns this repo's requests ask for. A turn that already ran ends its request; one whose
    /// issues are not fresh (`issuesFresh`: read this sync, or kept from one under a poll old)
    /// waits for a read, so the agent never works from a stale list.
    func composeCandidates(repo: String, defaultBranch: String, me: String, agents: [String: AgentTemplate],
                           merged: [MergedPullRequest], issuesFresh: Bool,
                           clone: URL, codeGraph: Bool, model: String) -> [DispatchCandidate] {
        guard issuesFresh else { return [] }
        let issues = openIssues[repo.lowercased()] ?? []
        let all = jobs.all()
        let ran = Set(all.map(\.key))
        let codeMap = codeGraph ? NewIssues.codeMap(inClone: clone) : nil
        var made: [DispatchCandidate] = []
        composeRequests.removeAll { request in
            guard request.repo.caseInsensitiveCompare(repo) == .orderedSame else { return false }
            guard let candidate = NewIssues.candidate(request, issues: issues, merged: merged, codeMap: codeMap, agents: agents,
                                                      defaultBranch: defaultBranch, me: me, model: model),
                  !ran.contains(candidate.key) || DispatchPlanner.isRetry(candidate.key, jobs: all) else { return true }
            made.append(candidate)
            return false
        }
        return made
    }
}
