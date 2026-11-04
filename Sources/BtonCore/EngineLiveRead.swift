import Foundation

/// The lists between syncs. A sync reads GitHub, then cleans up and starts jobs, which can take
/// minutes, and nothing else read GitHub meanwhile: what a teammate did waited for the sync's end.
/// `listsChanged` is the cheap question, `readLists` the answer that touches none of the sync's
/// state, so it runs beside a sync.
extension Engine {
    /// Whether any watched repo's open-PR list differs from the one `readLists` last read. A change
    /// stays pending until its repo is read, so a read that was skipped or failed is asked for again
    /// at the next question; a repo never read counts as changed.
    public func listsChanged() async -> Bool {
        guard let config = try? BtonConfig.loadOrCreate(home: home), !config.isPaused else { return false }
        // A repo no longer watched keeps no change pending.
        let watched = Set(config.repos.map { $0.slug.lowercased() })
        pendingTags = pendingTags.filter { watched.contains($0.key) }
        for repo in config.repos {
            let slug = repo.slug.lowercased()
            // A probe that fails says nothing: the sync's poll is the fallback.
            guard let tag = try? await github.pullListTag(repo: repo.slug, known: pullTags[slug]) else { continue }
            if tag != pullTags[slug] { pendingTags[slug] = tag }
        }
        return !pendingTags.isEmpty
    }

    /// The PR and merged lists read now, without the issues, the registry or any dispatch. Nil
    /// when paused (also if the switch is flipped meanwhile), under the rate floor, or while
    /// another such read runs. `listsAt` is when its requests began, not when they ended.
    public func readLists() async -> Snapshot? {
        guard !readingLists, let config = try? BtonConfig.loadOrCreate(home: home), !config.isPaused else { return nil }
        readingLists = true
        defer { readingLists = false }
        if await rateLimitHold(floor: config.rateFloor) != nil { return nil }
        var snapshot = Snapshot()
        snapshot.listsAt = .now
        var failures: [String] = []
        var read: [String] = []
        for repo in config.repos {
            if (try? BtonConfig.loadOrCreate(home: home))?.isPaused == true { return nil }
            do {
                let status = Flow.load(try await github.flowFile(repo: repo.slug, branch: repo.branch))
                let open = try await github.openPullRequests(repo: repo.slug)
                let merged = try await github.mergedPullRequests(repo: repo.slug)
                // A repo's lists land together or not at all, as in the sync.
                snapshot.flows[repo.slug] = status
                snapshot.me = open.viewer
                snapshot.defaultBranches[repo.slug] = open.defaultBranch
                snapshot.openPullRequests += open.pullRequests.map { pr in
                    var pr = pr
                    pr.move = status.flow.flatMap { FlowEngine.move(for: pr, flow: $0) }
                    return pr
                }
                snapshot.merged += merged
                read.append(repo.slug.lowercased())
            } catch {
                failures.append("\(repo.slug): \(error.localizedDescription)")
                snapshot.unread.insert(repo.slug.lowercased())
            }
        }
        if (try? BtonConfig.loadOrCreate(home: home))?.isPaused == true { return nil }
        for slug in read {
            if let tag = pendingTags.removeValue(forKey: slug) { pullTags[slug] = tag }
        }
        snapshot.problem = failures.isEmpty ? nil : failures.joined(separator: "\n")
        return decorated(snapshot)
    }
}
