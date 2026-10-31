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

    /// Bton's decision on the ask, when the repo's flow lets this Mac decide in my place: one job
    /// per asking comment, the newest if it ran again.
    func decision(for ask: IssueAsk) -> Job? {
        jobs.first { $0.key == IssueDecisions.key(for: ask) }
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
    /// Bton's home), sets the labels the draft's last line names, then syncs so the ask clears.
    /// The comment first: a reply that lands without its labels is a smaller wrong than labels
    /// moved on an issue with no word from me.
    func postReply(_ text: String, to ask: IssueAsk, draft job: Job) async throws {
        guard let github, let output = outputFiles(of: job).first else { throw CocoaError(.fileNoSuchFile) }
        guard !postedAsks.contains(ask.notice), postingAsks.insert(ask.notice).inserted else { return }
        defer { postingAsks.remove(ask.notice) }
        let draft = IssueDrafts.split(text)
        let file = output.appendingPathExtension("reply")
        try Data(draft.reply.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try await github.commentOnIssue(repo: ask.repo, number: ask.number, bodyFile: file)
        postedAsks.insert(ask.notice)
        do {
            try await github.editIssueLabels(add: draft.add, remove: draft.remove, repo: ask.repo, number: ask.number)
        } catch {
            await refresh()
            throw DraftLabelsError.notSet(add: draft.add, remove: draft.remove, reason: error.localizedDescription)
        }
        await refresh()
    }

    enum DraftLabelsError: LocalizedError {
        case notSet(add: [String], remove: [String], reason: String)
        var errorDescription: String? {
            if case let .notSet(add, remove, reason) = self {
                "Posted, but the labels were not set (\((add.map { "+" + $0 } + remove.map { "-" + $0 }).joined(separator: " "))): \(reason)"
            } else { nil }
        }
    }

    /// The drafted reply: the job's final message.
    func draftText(of job: Job) -> String? {
        guard let url = outputFiles(of: job).first, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return reply.isEmpty ? nil : reply
    }
}

extension Job {
    /// A job on an issue's thread rather than on a PR: a draft of my reply, or a decision in my place.
    var isIssueDraft: Bool { (key.move == IssueDrafts.move || key.move == IssueDecisions.move) && key.item.hasPrefix("issue-") }
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
    /// What GitHub's search found that the synced list does not hold: display only.
    var hits: [OpenIssue] = []

    /// An issue with a question for me is one card, the question: its stage card would repeat it, and both
    /// would read the same starting draft. Highest number first.
    private var entries: [IssueEntry] {
        let asked = Set(asks.map { "\($0.repo.lowercased())#\($0.number)" })
        let others = ready.filter { !asked.contains("\($0.repo.lowercased())#\($0.number)") }
        return (asks.map(IssueEntry.ask) + others.map(IssueEntry.ready)).sorted { $0.number > $1.number }
    }

    var body: some View {
        let drafting = jobs.filter { $0.status == .running && $0.isIssueDraft }
        if asks.isEmpty && ready.isEmpty && drafting.isEmpty && hits.isEmpty {
            EmptyState(symbol: "questionmark.bubble", title: store.lastRefresh == nil ? "Reading GitHub" : "Nothing to do here",
                       detail: "A question for you on an open issue, or an issue at stage:ready, shows here.")
        } else {
            RowStack(items: entries, footer: SearchHitsSection.footer(hits, showRepo: showRepo)) { entry in
                switch entry {
                case let .ask(ask): IssueAskRow(ask: ask, showRepo: showRepo)
                case let .ready(issue): ReadyIssueRow(issue: issue, showRepo: showRepo)
                }
            } header: {
                // A draft on an issue of the list is that row, working; only a job with no row gets a card.
                let loose = drafting.filter { job in !asks.contains { store.draft(for: $0)?.id == job.id || store.decision(for: $0)?.id == job.id } }
                if !loose.isEmpty { ActiveStrip(jobs: loose, schedules: schedules).padding(.bottom, 8) }
            }
        }
    }
}

/// An issue at stage:ready: who has it, or that nobody does and a Bton will take it.
private struct ReadyIssueRow: View {
    @Environment(AppStore.self) private var store
    let issue: ReadyIssue
    let showRepo: Bool
    @State private var problem: String?

    /// Assigned to me: a stage:ready set here gives the issue back as well.
    private var mine: Bool {
        store.me.map { me in issue.assignees.contains { $0.caseInsensitiveCompare(me) == .orderedSame } } ?? false
    }

    var body: some View {
        // The newest job on the issue, whatever round it ran under: a comment during the run moves the round on.
        let job = IssueIntake.latestJob(for: issue.number, repo: issue.repo, jobs: store.jobs)
        // The bar, the stage chip and "Working..." are one color: the issue's stage.
        let working = job?.status == .running ? job : nil
        HoverCard(accent: Theme.color(forStage: stale ? "spec" : issue.stage ?? "in-progress"),
                  glow: working.map { _ in Theme.color(for: .running) }, action: {
            if let working { withAnimation(Motion.spring) { store.watchingJob = working.id } } else { NSWorkspace.shared.open(issue.url) }
        }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text("#\(issue.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Theme.textTertiary)
                            if showRepo { RepoName(repo: issue.repo) }
                            if stale { Chip(text: "no owner", color: Theme.color(forStage: "spec"), style: .dashed) }
                        }
                        // The labels set themselves here as on the Triage page: the only place an issue past triage shows.
                        IssueLabelRow(issue: TriageIssue(repo: issue.repo, number: issue.number, title: issue.title, url: issue.url,
                                                         createdAt: issue.createdAt, body: "", labels: issue.labels),
                                      report: { problem = $0 }, givesBackOnReady: mine)
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
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 4)
                    // Its natural size, ahead of the text: squeezed, a button wraps letter by letter and stretches the card.
                    action(job).fixedSize().layoutPriority(2)
                }
                if let problem { ProblemText(text: problem) }
                if let job, job.status == .failed || job.status == .cancelled {
                    // The card's full width, and the way to the report the line speaks of.
                    if handedBack {
                        // The process has the agent unassign itself and move the issue on when it stops on a decision.
                        ReportLine(text: "The agent stopped on a decision and handed the issue back to \(issue.stage ?? "triage"): read its report",
                                   symbol: "signpost.right", color: Theme.color(forStage: "spec")) {
                            withAnimation(Motion.spring) { store.watchingJob = job.id }
                        }
                    } else {
                        ReportLine(text: "Bton's job \(job.status.rawValue)\(job.detail.map { ": \($0)" } ?? "")", symbol: "exclamationmark.triangle",
                                   color: Theme.danger) { withAnimation(Motion.spring) { store.watchingJob = job.id } }
                    }
                }
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
        issue.stage == "in-progress" && issue.assignees.isEmpty && IssueIntake.latestJob(for: issue.number, repo: issue.repo, jobs: store.jobs) == nil
    }

    /// Free and ready, with no job of mine on this round of it (an older round's job is spent) and
    /// none running: the owner may start it without waiting for a sync that starts moves.
    private var canTake: Bool {
        issue.isReady && issue.assignees.isEmpty
            && !store.jobs.contains { $0.key == IssueIntake.key(repo: issue.repo, number: issue.number, round: issue.round) }
            && IssueIntake.latestJob(for: issue.number, repo: issue.repo, jobs: store.jobs)?.status != .running
    }

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
            AsyncRunNowButton(title: "Retry", symbol: "arrow.clockwise", color: Theme.color(forStage: "spec"),
                              help: "Run the job again: the issue is already yours, so it is not claimed twice",
                              id: "retry:\(job.id)") { await store.retry(job) }
        } else if canTake {
            AsyncRunNowButton(title: "Take", runningTitle: "Taking...", symbol: "hand.raised", color: Theme.mint,
                              help: "Claim the issue and start the agent now, also when this repo does not start its moves",
                              id: "take:\(issue.repo)#\(issue.number)") { await store.take(issue) }
        }
    }
}

private struct IssueAskRow: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let showRepo: Bool

    var body: some View {
        let job = store.draft(for: ask)
        let decision = store.decision(for: ask)
        let working = [job, decision].compactMap { $0 }.first { $0.status == .running }
        HoverCard(accent: Theme.color(forStage: "spec"), glow: working.map { _ in Theme.color(for: .running) }, action: {
            if let working { withAnimation(Motion.spring) { store.watchingJob = working.id } } else { NSWorkspace.shared.open(ask.url) }
        }) {
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
                    } else if let decision, decision.status == .succeeded, decision.detail == nil {
                        Text("Bton decided this in your place; the comment on the issue says what. This clears when the next sync reads it.")
                            .font(.meta).foregroundStyle(Theme.success).fixedSize(horizontal: false, vertical: true)
                    } else if let decision, decision.status == .succeeded, let detail = decision.detail {
                        Text("Bton \(detail).")
                            .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    } else if let decision, decision.status == .failed || decision.status == .cancelled {
                        Text("Decision \(decision.status.rawValue)\(decision.detail.map { ": \($0)" } ?? "").")
                            .font(.meta).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
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
                // Its natural size, ahead of the text: squeezed, a button wraps letter by letter and stretches the card.
                action(job, decision: decision).fixedSize().layoutPriority(2)
            }
        }
        // Amber, hatched: an existing issue that waits for your reply, not a ready one or a new draft.
        .hatched(Theme.color(forStage: "spec"))
        .contextMenu {
            if let job { Button("Watch the Draft") { store.watchingJob = job.id } }
            if let decision { Button("Watch the Decision") { store.watchingJob = decision.id } }
            Button("Open on GitHub") { NSWorkspace.shared.open(ask.url) }
        }
    }

    /// Bton's own decision comes first: while it runs or once it is posted there is nothing to draft,
    /// and a failed one gets its Retry; Draft reply stays for the asks the flow leaves to me.
    @ViewBuilder private func action(_ job: Job?, decision: Job?) -> some View {
        if let decision, decision.status == .running {
            Button { withAnimation(Motion.spring) { store.watchingJob = decision.id } } label: {
                HStack(spacing: 5) {
                    PulseDot(color: Theme.color(for: .running))
                    Text("Deciding...").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.color(for: .running))
                }
            }
            .buttonStyle(PressStyle())
            .help("Watch Bton decide in your place")
        } else if let decision, decision.status == .succeeded, decision.detail == nil {
            PillButton(title: "Decided", symbol: "checkmark.seal", prominent: false) { NSWorkspace.shared.open(ask.url) }
                .help("Read the decision on GitHub")
        } else if let job, job.status == .running {
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
        } else if let decision, store.canRetry(decision) {
            AsyncPillButton(title: "Retry decision", symbol: "arrow.clockwise", id: "retry:\(decision.id)") { await store.retry(decision) }
                .help("Decide again, on the same question")
        } else if let job {
            if store.canRetry(job) {
                AsyncPillButton(title: "Retry draft", symbol: "arrow.clockwise", disabled: store.draftBlocked != nil,
                                id: "retry:\(job.id)") { await store.retry(job) }
                .help(store.draftBlocked ?? "Draft the reply again, on the same question")
            }
        } else {
            let blocked = ask.draftable ? store.draftBlocked
                : "Opened by someone without write access to the repo: Bton runs no agent on it"
            AsyncPillButton(title: "Draft reply", symbol: "sparkles", disabled: blocked != nil,
                            id: "draft:\(ask.id)") { await store.requestDraft(ask) }
            .help(blocked ?? "An agent reads the issue and the code and drafts your reply; you post it")
        }
    }
}

/// A drafted reply in place of the list: the reply as it will read on GitHub, to post as my
/// comment or copy; Edit opens it as text with bold, italic, strike and underline at hand. The
/// issue it answers is behind View issue.
struct DraftView: View {
    @Environment(AppStore.self) private var store
    let ask: IssueAsk
    let close: () -> Void
    @State private var text = ""
    @State private var editing = false
    @State private var editor = MarkdownEditing()
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
                PillButton(title: "View issue", symbol: "doc.text", prominent: false) {
                    withAnimation(Motion.spring) { store.viewingIssue = ask }
                }
                // An icon, not a fourth pill in the footer: four pills are wider than the panel.
                if !posted && !posting, let job, store.canRunAgain(job) {
                    AsyncIconButton(symbol: "arrow.clockwise", help: "Draft again: another reply on the same question; this one and your edits of it go",
                                    size: 24, id: "again:\(job.id)") {
                        await store.draftAgain(job, for: ask)
                        close()
                    }
                }
                IconButton(symbol: "arrow.up.right", help: "Open the issue on GitHub", size: 24) { NSWorkspace.shared.open(ask.url) }
            }
            .padding(.horizontal, 14)
            Group {
                if editing {
                    MarkdownEditor(text: $text, editing: editor)
                } else if text.isEmpty {
                    Text(job == nil ? "No draft yet." : job?.status == .running ? "Bton is drafting the reply..." : "The draft is empty.")
                        .font(.meta).foregroundStyle(Theme.textTertiary).padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    // A click anywhere on the drawn reply opens it for editing, as does Edit.
                    ScrollView {
                        MarkdownView(text: text, tone: Theme.textPrimary).padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { if !posted && !posting { withAnimation(Motion.snappy) { editing = true } } }
                    }
                    .scrollIndicators(.never)
                    .help(posted ? "" : "Click to edit the reply")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 14)
            if let problem { ProblemText(text: problem).padding(.horizontal, 14) }
            let labels = IssueDrafts.split(text)
            let moves = (labels.add.map { "+" + $0 } + labels.remove.map { "-" + $0 }).joined(separator: " ")
            let stale = IssueDrafts.leavesToDo(text)
            Text(posted ? "Posted as your comment. The ask clears when the next sync reads it."
                 : stale ? "This draft leaves you a to do: it is from before Bton set labels on Post. Draft again ends it with the labels instead."
                 : moves.isEmpty ? "Post reply comments on the issue as \(store.me ?? "you"); Bton posts nothing on its own."
                 : "Post reply comments on the issue as \(store.me ?? "you") and sets its labels \(moves); the last line stays here.")
                .font(.meta).foregroundStyle(posted ? Theme.success : stale ? Theme.danger : Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
            HStack(spacing: 8) {
                if editing {
                    ForEach(MarkdownEditing.Style.allCases, id: \.self) { style in
                        IconButton(symbol: style.symbol, help: style.help, size: 24) { editor.toggle(style) }
                    }
                } else if copied {
                    Chip(text: "copied", symbol: "checkmark", color: Theme.success).transition(.opacity)
                }
                Spacer()
                // The confirmation keeps two pills, Cancel and Post as me: four pills are wider
                // than the panel, and a footer that cannot shrink pushes the whole page out of it.
                if !posted && !posting && !confirming {
                    PillButton(title: editing ? "Done" : "Edit", symbol: editing ? "checkmark" : "pencil", prominent: false) {
                        withAnimation(Motion.snappy) { editing.toggle() }
                    }
                }
                if !editing {
                    if !confirming {
                        PillButton(title: "Copy", symbol: "doc.on.doc", prominent: false) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            withAnimation(Motion.snappy) { copied = true }
                        }
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
                // The labels error says the reply went up; the prefix is for a reply that did not.
                problem = error is AppStore.DraftLabelsError ? error.localizedDescription : "Not posted: \(error.localizedDescription)"
            }
            confirming = false
        }
    }
}
