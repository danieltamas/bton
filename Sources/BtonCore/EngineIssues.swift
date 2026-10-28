import Foundation

extension Engine {
    /// Load more never asks for more pages than this (500 issues).
    public static let issuePageCap = 10

    /// A repo's open issues, as many pages as Load more asked for; a failure keeps the last read
    /// whole and never stops the repo's PR work.
    func readIssues(_ repo: String) async {
        let slug = repo.lowercased()
        var issues: [OpenIssue] = [], after: String?
        for page in 1...max(1, issuePages[slug] ?? 1) {
            do {
                let read = try await github.openIssues(repo: repo, after: after)
                issues += read.issues
                after = read.nextPage
            } catch {
                log("\(repo): issues page \(page) not read: \(error.localizedDescription)")
                return
            }
            if after == nil { break }
        }
        var seen = Set<Int>()
        openIssues[slug] = issues.filter { seen.insert($0.number).inserted }
        issuesReadThisTick.insert(slug)
        if after == nil { issuesMore.remove(slug) } else { issuesMore.insert(slug) }
    }

    /// Load more: the next sync reads one page more of the repo's issues, and keeps doing so.
    public func loadMoreIssues(repo: String) {
        let slug = repo.lowercased()
        issuePages[slug] = min(Self.issuePageCap, (issuePages[slug] ?? 1) + 1)
    }

    func issueAsks(in repos: [WatchedRepo], me: String?) -> [IssueAsk] {
        guard let me else { return [] }
        return IssueAsks.asks(repos.flatMap { openIssues[$0.slug.lowercased()] ?? [] }, me: me)
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
                         model: String) -> [DispatchCandidate] {
        guard issuesReadThisTick.contains(repo.lowercased()) else { return [] }
        let issues = openIssues[repo.lowercased()] ?? []
        let all = jobs.all()
        let ran = Set(all.map(\.key))
        // A draft I pressed Retry on asks again, as long as its comment is still the ask.
        for ask in IssueAsks.asks(issues, me: me)
        where DispatchPlanner.isRetry(IssueDrafts.key(for: ask), jobs: all) && !draftRequests.contains(where: { $0.id == ask.id }) {
            draftRequests.append(ask)
        }
        var made: [DispatchCandidate] = []
        draftRequests.removeAll { ask in
            guard ask.repo.caseInsensitiveCompare(repo) == .orderedSame else { return false }
            guard let issue = issues.first(where: { $0.number == ask.number }),
                  let candidate = IssueDrafts.candidate(ask: ask, issue: issue, agents: agents, defaultBranch: defaultBranch, me: me, model: model),
                  !ran.contains(candidate.key) || DispatchPlanner.isRetry(candidate.key, jobs: all) else { return true }
            made.append(candidate)
            return false
        }
        return made
    }

    /// Asks the agent for the next turn of a new issue, first in line at the next sync.
    public func requestCompose(_ request: NewIssues.Request) {
        composeRequests.removeAll { $0.key == request.key }
        composeRequests.append(request)
        runNext(repo: request.repo, item: request.key.item)
    }

    /// The turns this repo's requests ask for. A turn that already ran ends its request; one whose
    /// issues were not read this tick waits for a read, so the agent never works from a stale list.
    func composeCandidates(repo: String, defaultBranch: String, me: String, agents: [String: AgentTemplate],
                           merged: [MergedPullRequest],
                           clone: URL, codeGraph: Bool, model: String) -> [DispatchCandidate] {
        guard issuesReadThisTick.contains(repo.lowercased()) else { return [] }
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
