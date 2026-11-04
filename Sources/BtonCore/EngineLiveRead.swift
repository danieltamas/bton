import Foundation

/// The lists between syncs. A sync reads GitHub, then cleans up and starts jobs, which can take
/// minutes, and nothing else read GitHub meanwhile: what a teammate did waited for the sync's end.
/// `listsChanged` is the cheap question, `readLists` the answer that touches none of the sync's
/// state, so it runs beside a sync.
extension Engine {
    /// Whether any watched repo's open-PR list changed since this was last asked. The first
    /// question about a repo only learns its tag.
    public func listsChanged() async -> Bool {
        guard let config = try? BtonConfig.loadOrCreate(home: home), !config.isPaused else { return false }
        var changed = false
        for repo in config.repos {
            let slug = repo.slug.lowercased()
            // A probe that fails says nothing: the sync's poll is the fallback.
            guard let tag = try? await github.pullListTag(repo: repo.slug, known: pullTags[slug]) else { continue }
            if let known = pullTags[slug], known != tag { changed = true }
            pullTags[slug] = tag
        }
        return changed
    }

    /// The PR and merged lists read now, without the issues, the registry or any dispatch. Nil
    /// when paused, under the rate floor, or while another such read runs.
    public func readLists() async -> Snapshot? {
        guard !readingLists, let config = try? BtonConfig.loadOrCreate(home: home), !config.isPaused else { return nil }
        readingLists = true
        defer { readingLists = false }
        if await rateLimitHold(floor: config.rateFloor) != nil { return nil }
        var snapshot = Snapshot()
        var failures: [String] = []
        for repo in config.repos {
            do {
                let status = Flow.load(try await github.flowFile(repo: repo.slug, branch: repo.branch))
                let read = try await github.openPullRequests(repo: repo.slug)
                let merged = try await github.mergedPullRequests(repo: repo.slug)
                // A repo's lists land together or not at all, as in the sync.
                snapshot.flows[repo.slug] = status
                snapshot.me = read.viewer
                snapshot.defaultBranches[repo.slug] = read.defaultBranch
                snapshot.openPullRequests += read.pullRequests.map { pr in
                    var pr = pr
                    pr.move = status.flow.flatMap { FlowEngine.move(for: pr, flow: $0) }
                    return pr
                }
                snapshot.merged += merged
            } catch {
                failures.append("\(repo.slug): \(error.localizedDescription)")
                snapshot.unread.insert(repo.slug.lowercased())
            }
        }
        snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
        snapshot.listsAt = .now
        return decorated(snapshot)
    }
}
