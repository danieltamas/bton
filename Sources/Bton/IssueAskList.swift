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

    /// Posts my reply as a comment on the issue, from a file beside the draft's output (0600, in
    /// Bton's home), then syncs so the ask clears.
    func postReply(_ text: String, to ask: IssueAsk, draft job: Job) async throws {
        guard let github, let output = outputFiles(of: job).first else { throw CocoaError(.fileNoSuchFile) }
        guard !postedAsks.contains(ask.notice), postingAsks.insert(ask.notice).inserted else { return }
        defer { postingAsks.remove(ask.notice) }
        let file = output.appendingPathExtension("reply")
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await github.commentOnIssue(repo: ask.repo, number: ask.number, bodyFile: file)
        postedAsks.insert(ask.notice)
        await refresh()
    }

    /// The drafted reply: the job's final message.
    func draftText(of job: Job) -> String? {
        guard let url = outputFiles(of: job).first, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }
}

extension Job {
    var isIssueDraft: Bool { key.move == IssueDrafts.move && key.item.hasPrefix("issue-") }
}

/// What the Issues tab lists: questions put to me, then the issues ready for anyone to take.
private enum IssueEntry: Identifiable {
    case ask(IssueAsk)
    case ready(ReadyIssue)

    var number: Int {
        switch self {
        case let .ask(ask): ask.number
        case let .ready(issue): issue.number
        }
    }

    var id: String {
        switch self {
        case let .ask(ask): "ask-\(ask.id)"
        case let .ready(issue): "ready-\(issue.id)"
        }
    }
}

/// Questions put to me on issues, and the issues ready to be taken: Bton drafts a reply, I post it;
/// a Bton on a repo that starts its moves takes the most urgent ready issue on its own.
struct IssueAskList: View {
    @Environment(AppStore.self) private var store
    let asks: [IssueAsk]
    let ready: [ReadyIssue]
    let showRepo: Bool
    let jobs: [Job]
    let schedules: [ScheduleEntry]

    /// An issue with a question for me is one card, the question: its stage card would repeat it, and both
    /// would read the same starting draft. Highest number first.
    private var entries: [IssueEntry] {
        let asked = Set(asks.map { "\($0.repo.lowercased())#\($0.number)" })
        let others = ready.filter { !asked.contains("\($0.repo.lowercased())#\($0.number)") }
        return (asks.map(IssueEntry.ask) + others.map(IssueEntry.ready)).sorted { $0.number > $1.number }
    }

    var body: some View {
        let drafting = jobs.filter { $0.status == .running && $0.isIssueDraft }
        if asks.isEmpty && ready.isEmpty && drafting.isEmpty {
            EmptyState(symbol: "questionmark.bubble", title: store.lastRefresh == nil ? "Reading GitHub" : "Nothing to do here",
                       detail: "A question for you on an open issue, or an issue at stage:ready, shows here.")
        } else {
            RowStack(items: entries) { entry in
                switch entry {
                case let .ask(ask): IssueAskRow(ask: ask, showRepo: showRepo)
                case let .ready(issue): ReadyIssueRow(issue: issue, showRepo: showRepo)
                }
            } header: {
                if !drafting.isEmpty { ActiveStrip(jobs: drafting, schedules: schedules).padding(.bottom, 8) }
            }
        }
    }
}

/// An issue at stage:ready: who has it, or that nobody does and a Bton will take it.
private struct ReadyIssueRow: View {
    @Environment(AppStore.self) private var store
    let issue: ReadyIssue
    let showRepo: Bool

    var body: some View {
        let job = store.jobs.first { $0.key.move == IssueIntake.move && $0.key.repo == issue.repo && $0.key.item == "issue-\(issue.number)" }
        // The bar, the stage chip and "Working..." are one color: the issue's stage.
        HoverCard(accent: Theme.color(forStage: stale ? "spec" : issue.stage ?? "in-progress"), action: { NSWorkspace.shared.open(issue.url) }) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text("#\(issue.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                        if showRepo { RepoName(repo: issue.repo) }
                        StageChip(stage: issue.stage ?? "in-progress")
                        PriorityChip(priority: issue.priority)
                        if stale { Chip(text: "no owner", color: Theme.color(forStage: "spec"), style: .dashed) }
                    }
                    Text(issue.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    // One line: a long login truncates, the time never wraps.
                    HStack(spacing: 6) {
                        if let owner = issue.assignees.first {
                            Avatar(login: owner)
                            Text(issue.assignees.joined(separator: ", ") + " has it").foregroundStyle(Theme.textSecondary).lineLimit(1)
                        } else {
                            // Only a ready issue waits for a Bton; one in progress was labeled by whoever works it.
                            Text(issue.isReady ? "Unclaimed" : "Nobody assigned").lineLimit(1)
                                .foregroundStyle(stale ? Theme.color(forStage: "spec") : Theme.textSecondary)
                                .help(issue.isReady ? "The next free Bton, or you with Take, starts it" : "Labeled in progress, but no one is assigned and no Bton job runs it")
                        }
                        Text("·").foregroundStyle(Theme.textTertiary)
                        RelativeTime(date: issue.createdAt) { "opened \($0) ago" }.foregroundStyle(Theme.textTertiary)
                            .lineLimit(1).fixedSize()
                    }
                    .font(.meta)
                    if let job, job.status == .failed || job.status == .cancelled {
                        if handedBack {
                            // The process has the agent unassign itself and move the issue on when it stops on a decision.
                            Text("The agent stopped on a decision and handed the issue back to \(issue.stage ?? "triage"): its report is in Jobs.")
                                .font(.meta).foregroundStyle(Theme.color(forStage: "spec")).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("Bton's job \(job.status.rawValue)\(job.detail.map { ": \($0)" } ?? "").")
                                .font(.meta).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                action(job)
            }
        }
        .contextMenu { Button("Open on GitHub") { NSWorkspace.shared.open(issue.url) } }
    }

    /// The agent ended without a PR and the issue has left ready and in progress with no one on it: it handed the issue back.
    private var handedBack: Bool {
        issue.assignees.isEmpty && issue.stage != "in-progress" && !issue.isReady
    }

    /// In progress means an agent or a person started it and holds it: with no assignee and no job of mine, nobody does.
    private var stale: Bool {
        issue.stage == "in-progress" && issue.assignees.isEmpty
            && !store.jobs.contains { $0.key.move == IssueIntake.move && $0.key.repo == issue.repo && $0.key.item == "issue-\(issue.number)" }
    }

    /// Free and ready, with no job of mine on it: the owner may start it without waiting for a sync that starts moves.
    private var canTake: Bool { issue.isReady && issue.assignees.isEmpty && !store.jobs.contains { $0.key.move == IssueIntake.move && $0.key.repo == issue.repo && $0.key.item == "issue-\(issue.number)" } }

    @ViewBuilder private func action(_ job: Job?) -> some View {
        if let job, job.status == .running {
            Button { withAnimation(Motion.spring) { store.watchingJob = job.id } } label: {
                HStack(spacing: 5) {
                    PulseDot(color: Theme.color(for: .running))
                    Text("Working...").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.color(for: .running))
                }
            }
            .buttonStyle(PressStyle())
            .help("Watch the agent work on the issue")
        } else if store.isNext(repo: issue.repo, item: "issue-\(issue.number)") {
            StartingLabel(repo: issue.repo, reason: store.waitingReason(repo: issue.repo, item: "issue-\(issue.number)"))
        } else if let job, store.canRetry(job) {
            RunNowButton(title: "Retry", symbol: "arrow.clockwise", color: Theme.color(forStage: "spec"),
                         help: "Run the job again: the issue is already yours, so it is not claimed twice") {
                Task { await store.retry(job) }
            }
        } else if canTake {
            RunNowButton(title: "Take", symbol: "hand.raised", color: Theme.mint,
                         help: "Claim the issue and start the agent now, also when this repo does not start its moves") {
                Task { await store.take(issue) }
            }
        }
    }
}

private struct IssueAskRow: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let showRepo: Bool

    var body: some View {
        let job = store.draft(for: ask)
        HoverCard(accent: Theme.color(forStage: "spec"), action: { NSWorkspace.shared.open(ask.url) }) {
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
                    // One line: a long login truncates, the time never wraps.
                    HStack(spacing: 6) {
                        Avatar(login: ask.asker)
                        Text("\(ask.asker) \(ask.handoff ? "handed off" : "asked")").foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Text("·").foregroundStyle(Theme.textTertiary)
                        RelativeTime(date: ask.askedAt) { "\($0) ago" }.foregroundStyle(Theme.textTertiary).lineLimit(1).fixedSize()
                    }
                    .font(.meta)
                    if store.postedAsks.contains(ask.notice) {
                        Text("Reply posted. This clears when the next sync reads it.")
                            .font(.meta).foregroundStyle(Theme.success).fixedSize(horizontal: false, vertical: true)
                    } else if let job, job.status == .succeeded {
                        Text("Draft ready: read it, edit it if you like, and post it from View draft.")
                            .font(.meta).foregroundStyle(Theme.mint).fixedSize(horizontal: false, vertical: true)
                    } else if let job, job.status == .failed || job.status == .cancelled {
                        Text("Draft \(job.status.rawValue)\(job.detail.map { ": \($0)" } ?? "").")
                            .font(.meta).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                action(job)
            }
        }
        // Amber, hatched: an existing issue that waits for your reply, not a ready one or a new draft.
        .hatched(Theme.color(forStage: "spec"))
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
        } else if store.isNext(repo: ask.repo, item: "issue-\(ask.number)") {
            StartingLabel(repo: ask.repo)
        } else if let job {
            if store.canRetry(job) {
                PillButton(title: "Retry draft", symbol: "arrow.clockwise", disabled: store.draftBlocked != nil) {
                    Task { await store.retry(job) }
                }
                .help(store.draftBlocked ?? "Draft the reply again, on the same question")
            }
        } else {
            let blocked = ask.draftable ? store.draftBlocked
                : "Opened by someone without write access to the repo: Bton runs no agent on it"
            PillButton(title: "Draft reply", symbol: "sparkles", disabled: blocked != nil) {
                Task { await store.requestDraft(ask) }
            }
            .help(blocked ?? "An agent reads the issue and the code and drafts your reply; you post it")
        }
    }
}

/// A drafted reply in place of the list: read it, edit it, and post it as my comment, or copy it.
struct DraftView: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let close: () -> Void
    @State private var text = ""
    @State private var copied = false
    /// Post reply asks once more before it writes on GitHub under my name.
    @State private var confirming = false
    @State private var problem: String?

    var body: some View {
        let job = store.draft(for: ask)
        let posted = store.postedAsks.contains(ask.notice)
        let posting = store.postingAsks.contains(ask.notice)
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reply to #\(ask.number)").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(ask.title).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.right", help: "Open the issue on GitHub", size: 24) { NSWorkspace.shared.open(ask.url) }
            }
            .padding(.horizontal, 14)
            TextEditor(text: $text)
                .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(8)
                .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.horizontal, 14)
                .disabled(posting || posted)
            if let problem { ProblemText(text: problem).padding(.horizontal, 14) }
            Text(posted ? "Posted as your comment. The ask clears when the next sync reads it."
                 : "Edit it here if you like. Post reply comments on the issue as \(store.me ?? "you"); Bton posts nothing on its own.")
                .font(.meta).foregroundStyle(posted ? Theme.success : Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
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
                if confirming {
                    PillButton(title: "Cancel", symbol: "xmark", prominent: false) { withAnimation(Motion.snappy) { confirming = false } }
                }
                PillButton(title: posted ? "Posted" : posting ? "Posting..." : confirming ? "Post as \(store.me ?? "me")" : "Post reply",
                           symbol: posted ? "checkmark" : "paperplane",
                           disabled: posted || posting || job == nil || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    if confirming { post(job) } else { withAnimation(Motion.snappy) { confirming = true } }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .onAppear { text = store.draftEdits[ask.notice] ?? job.flatMap(store.draftText) ?? "" }
        .onChange(of: text) { store.draftEdits[ask.notice] = text }
    }

    private func post(_ job: Job?) {
        guard let job else { return }
        problem = nil
        Task {
            do {
                try await store.postReply(text, to: ask, draft: job)
            } catch {
                problem = "Not posted: \(error.localizedDescription)"
            }
            confirming = false
        }
    }
}
