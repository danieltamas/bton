import AppKit
import BtonCore
import SwiftUI

/// The issue read in full, in place of the draft that answers it: its body as GitHub draws it,
/// then every comment the sync read, oldest first. Back returns to the draft.
struct IssueView: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let close: () -> Void

    var body: some View {
        // The store's copy grows with the sync; a newer ask on the issue keeps the opened one's.
        let entries = (store.issueAsks.first { $0.id == ask.id && $0.commentID == ask.commentID } ?? ask).thread
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the reply", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(ask.number) \(ask.title)").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    if let opened = entries.first(where: { $0.id == "body" }) {
                        HStack(spacing: 4) {
                            Text(opened.author ?? "ghost").font(.meta.weight(.medium)).foregroundStyle(Theme.textSecondary)
                            RelativeTime(date: opened.createdAt) { "opened it \($0) ago" }.font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                    }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.right", help: "Open the issue on GitHub", size: 24) { NSWorkspace.shared.open(ask.url) }
            }
            .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        if entry.id == "body" {
                            MarkdownView(text: entry.body, tone: Theme.textPrimary)
                                .padding(12)
                                .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            ThreadEntry(entry: entry, accented: entry.id == ask.commentID)
                        }
                    }
                    if entries.count > 1 {
                        Text("\(entries.count - 1) \(entries.count == 2 ? "comment" : "comments") read; a longer thread is whole on GitHub.")
                            .font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
    }
}

/// One comment of an issue's thread: who, when, and the comment drawn as GitHub draws it.
struct ThreadEntry: View {
    let entry: IssueComment
    var accented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(entry.author ?? "ghost").font(.meta.weight(.medium)).foregroundStyle(Theme.textSecondary)
                Text(entry.id == "body" ? "opened it" : "·").font(.meta).foregroundStyle(Theme.textTertiary)
                RelativeTime(date: entry.createdAt) { "\($0) ago" }.font(.meta).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 4)
            Bubble(text: entry.body, accented: accented)
        }
    }
}
