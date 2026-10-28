import Foundation

extension Engine {
    /// The release this tick, for the Bton of `release.who`: opens the PR when the release is due
    /// (or pressed) and none is open, or plans the merge of the open one. Opening is one `gh`
    /// call, no job: a second Mac of the same login is refused by GitHub and logs it.
    func planRelease(_ read: (repo: WatchedRepo, flow: Flow?, viewer: String, defaultBranch: String,
                              pullRequests: [PullRequest], merged: [MergedPullRequest])) async -> DispatchCandidate? {
        guard let release = read.flow?.release, release.who.caseInsensitiveCompare(read.viewer) == .orderedSame else { return nil }
        let slug = read.repo.slug
        let pick = Self.pick(repo: slug, item: Release.item)
        let pressed = next.contains(pick)
        guard let report = featureStates[slug.lowercased()]?.report, let standing = report.release else { return nil }
        if let pr = Release.pullRequest(read.pullRequests, release: release) {
            let due = standing == .open(number: pr.number, due: true)
            guard let made = Release.candidate(pr: pr, release: release, repo: slug, me: read.viewer, jobs: jobs.all(),
                                               pullRequests: read.pullRequests, startsMoves: read.repo.startsMoves && due,
                                               pressed: pressed) else { return nil }
            // The press lands on the PR's item, where the dispatch loop clears it.
            if pressed {
                next.removeAll { $0 == pick }
                pressedPicks.remove(pick)
                runNext(repo: slug, item: made.key.item, pressed: true)
            }
            return made
        }
        guard pressed || (read.repo.startsMoves && { if case .due = standing { true } else { false } }()),
              Release.blockedReason(release: release, pullRequests: read.pullRequests) == nil else { return nil }
        next.removeAll { $0 == pick }
        pressedPicks.remove(pick)
        await openRelease(release, repo: slug, report: report)
        return nil
    }

    private func openRelease(_ release: Flow.Release, repo: String, report: FeatureReport) async {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bton-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try ReleaseNotes.body(report: report).write(to: file, atomically: true, encoding: .utf8)
            try await github.createPullRequest(repo: repo, base: release.to, head: release.from,
                                               title: ReleaseNotes.title(release: release, report: report), bodyFile: file)
            log("\(repo): opened the release PR \(release.from) -> \(release.to)")
        } catch {
            log("\(repo): release: could not open the PR: \(error.localizedDescription)")
        }
    }
}
