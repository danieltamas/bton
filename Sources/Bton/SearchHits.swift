import AppKit
import BtonCore
import SwiftUI

/// What GitHub's issue search found beyond the synced issues, split by the tab it belongs to.
/// Display only: a hit opens on GitHub and starts nothing, because nothing of Bton's state (leases,
/// drafts, asks) was read for it.
struct SearchHits {
    let triage: [OpenIssue]
    let issues: [OpenIssue]

    /// Pending issues go under the Triage tab, every other hit under Issues; a hit the tab's list
    /// already holds (by `repo#number`) is dropped.
    static func split(_ hits: [OpenIssue], triage known: Set<String>, issues knownIssues: Set<String>) -> SearchHits {
        let pending = Set(IssueTriage.pending(hits).map(\.id))
        var seen = Set<String>()
        let fresh = hits.filter { seen.insert($0.key).inserted }
        return SearchHits(triage: fresh.filter { pending.contains($0.key) && !known.contains($0.key) },
                          issues: fresh.filter { !pending.contains($0.key) && !knownIssues.contains($0.key) })
    }
}

private extension OpenIssue {
    /// The same identity the lists use, since issue numbers repeat across repos.
    var key: String { "\(repo)#\(number)" }
}

/// "n more from GitHub" and the hits, under a list's own rows.
struct SearchHitsSection: View {
    let hits: [OpenIssue]
    let showRepo: Bool

    static func footer(_ hits: [OpenIssue], showRepo: Bool) -> AnyView? {
        hits.isEmpty ? nil : AnyView(SearchHitsSection(hits: hits, showRepo: showRepo))
    }

    var body: some View {
        Text("\(hits.count) more from GitHub").font(.meta).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        ForEach(hits, id: \.key) { hit in SearchHitRow(issue: hit, showRepo: showRepo) }
    }
}

/// One hit: number, repo, title; a click opens it on GitHub.
private struct SearchHitRow: View {
    let issue: OpenIssue
    let showRepo: Bool

    var body: some View {
        HoverCard(accent: nil, action: { NSWorkspace.shared.open(issue.url) }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("#\(issue.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    if showRepo { RepoName(repo: issue.repo) }
                    Text("on GitHub").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Text(issue.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
