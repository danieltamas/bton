import AppKit
import BtonCore
import SwiftUI

extension AppStore {
    /// This Mac's draft for the ask: one job per asking comment, the newest if it ran again.
    func draft(for ask: IssueAsk) -> Job? {
        jobs.first {
            $0.key.move == IssueDrafts.move && $0.key.repo == ask.repo && $0.key.item == "issue-\(ask.number)"
                && $0.key.head == ask.commentID
        }
    }

    /// Why Draft reply cannot start on this Mac, or nil when it can.
    var draftBlocked: String? {
        agents[IssueDrafts.defaultAgent]?.argv.first.map(AgentHardening.isClaude) == true
            ? nil : "Drafts need a Claude Code agent named \(IssueDrafts.defaultAgent) (Settings > Agents)"
    }

    func requestDraft(_ ask: IssueAsk) async {
        guard let engine else { return }
        await engine.requestDraft(ask)
        markStarting(repo: ask.repo, item: "issue-\(ask.number)")
        await refresh()
    }

    /// The drafted reply: the job's final message.
    func draftText(of job: Job) -> String? {
        guard let url = outputFiles(of: job).first, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }
}

/// Questions put to me on issues, above the PRs: Bton drafts a reply, I post it.
struct IssueAskSection: View {
    let asks: [IssueAsk]
    let showRepo: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "Asked on issues", color: Theme.mint).padding(.leading, 4)
            ForEach(asks) { ask in IssueAskRow(ask: ask, showRepo: showRepo) }
        }
        .padding(.bottom, 8)
    }
}

private struct IssueAskRow: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let showRepo: Bool

    var body: some View {
        let job = store.draft(for: ask)
        HoverCard(accent: Theme.mint, action: { NSWorkspace.shared.open(ask.url) }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("#\(ask.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        if showRepo { RepoName(repo: ask.repo) }
                        Chip(text: "issue", color: Theme.neutral, style: .outline)
                    }
                    Text(ask.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        Avatar(login: ask.asker)
                        Text("\(ask.asker) asked").foregroundStyle(Theme.textSecondary)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        RelativeTime(date: ask.askedAt) { "\($0) ago" }.foregroundStyle(Theme.textTertiary)
                    }
                    .font(.meta)
                    if let job, job.status == .succeeded {
                        Text("Draft ready: post it as a comment on the issue. This clears at the next sync after you reply.")
                            .font(.meta).foregroundStyle(Theme.mint).fixedSize(horizontal: false, vertical: true)
                    } else if let job, job.status == .failed || job.status == .cancelled {
                        Text("Draft \(job.status.rawValue)\(job.detail.map { ": \($0)" } ?? ""). A new question starts a new one.")
                            .font(.meta).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                action(job)
            }
        }
        .contextMenu {
            if let job { Button("Watch the Draft") { store.watchingJob = job.id } }
            Button("Open on GitHub") { NSWorkspace.shared.open(ask.url) }
        }
    }

    @ViewBuilder private func action(_ job: Job?) -> some View {
        if let job, job.status == .running {
            Button { withAnimation(Motion.spring) { store.watchingJob = job.id } } label: {
                HStack(spacing: 5) {
                    PulseDot(color: Theme.color(for: .running))
                    Text("Drafting...").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.color(for: .running))
                }
            }
            .buttonStyle(PressStyle())
            .help("Watch the agent draft the reply")
        } else if let job, job.status == .succeeded {
            PillButton(title: "View draft", symbol: "text.bubble") { withAnimation(Motion.spring) { store.readingDraft = ask } }
        } else if job == nil, store.isNext(repo: ask.repo, item: "issue-\(ask.number)") {
            StartingLabel(repo: ask.repo)
        } else if job == nil {
            let blocked = ask.draftable ? store.draftBlocked
                : "Opened by someone without write access to the repo: Bton runs no agent on it"
            PillButton(title: "Draft reply", symbol: "sparkles", disabled: blocked != nil) {
                Task { await store.requestDraft(ask) }
            }
            .help(blocked ?? "An agent reads the issue and the code and drafts your reply; you post it")
        }
    }
}

/// A drafted reply in place of the list: read it, copy it, post it on GitHub yourself.
struct DraftView: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        let job = store.draft(for: ask)
        let text = job.flatMap(store.draftText) ?? "The draft is empty: the agent left no final message."
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reply to #\(ask.number)").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(ask.title).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            ScrollView {
                Text(text)
                    .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            Text("Bton never posts it. Copy it, open the issue and paste it as your comment: the ask clears at the next sync after you reply.")
                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                if copied { Chip(text: "copied", symbol: "checkmark", color: Theme.success).transition(.opacity) }
                Spacer()
                PillButton(title: "Copy", symbol: "doc.on.doc", prominent: false) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    withAnimation(Motion.snappy) { copied = true }
                }
                PillButton(title: "Open on GitHub") { NSWorkspace.shared.open(ask.url) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }
}
