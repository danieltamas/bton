import AppKit
import BtonCore
import SwiftUI

extension AppStore {
    /// Asks GitHub for the search text in each shown repo, 400 ms after the last keystroke; a
    /// cancelled search (the text changed) writes nothing, a failed one leaves the hits empty.
    func searchIssues(_ text: String, repos: [String]) async {
        let query = SearchQuery(text)
        // The last query's hits never sit under the new text.
        searchHits = []
        guard !query.isEmpty, let github else { return }
        do {
            try await Task.sleep(for: .milliseconds(400))
            var hits: [OpenIssue] = []
            for repo in repos { hits += try await github.searchIssues(repo: repo, text: query.text) }
            guard !Task.isCancelled else { return }
            searchHits = hits
        } catch is CancellationError {
        } catch {
            searchHits = []
        }
    }

    /// Sets the issue's priority and stage from the answers, then syncs so it leaves the tab when it is ready.
    func applyTriage(_ verdict: TriageVerdict, to issue: TriageIssue) async throws {
        try await editLabels(IssueTriage.edit(for: verdict, on: issue), on: issue)
    }
}

/// Open issues that are not ready yet, with no agent in the way: a click opens one with three
/// questions, and the answers set its priority and stage.
struct TriageList: View {
    @Environment(AppStore.self) private var store
    let issues: [TriageIssue]
    let showRepo: Bool
    /// The repos the list covers (the repo filter); GitHub has more issues of one of them when
    /// `store.issuesMore` names it.
    var repos: [String] = []
    /// What GitHub's search found that the synced list does not hold: display only.
    var hits: [OpenIssue] = []
    let newIssue: () -> Void

    private var more: RowStackMore? {
        let waiting = repos.filter { store.issuesMore.contains($0.lowercased()) }
        guard !waiting.isEmpty else { return nil }
        return RowStackMore(id: "more:\(waiting.map { $0.lowercased() }.sorted().joined(separator: ","))", title: "Load more from GitHub",
                            loading: waiting.contains { store.issuesLoading.contains($0.lowercased()) },
                            action: { await store.loadMoreIssues(repos: waiting) })
    }

    var body: some View {
        Group {
            // A page of settled issues still has Load more under it: the pending ones may be on the next.
            if issues.isEmpty && store.newIssues.isEmpty && hits.isEmpty && more == nil {
                EmptyState(symbol: "checklist", title: store.lastRefresh == nil ? "Reading GitHub" : "Nothing to triage",
                           detail: "Open issues that are not stage:ready, in progress or in review show here.")
            } else {
                // The drafts are the first rows of the list, so they scroll with it and never cover an issue.
                RowStack(items: issues, more: more, footer: SearchHitsSection.footer(hits, showRepo: showRepo),
                         row: { issue in TriageRow(issue: issue, showRepo: showRepo) }) {
                    ForEach(store.newIssues, id: \.id) { inProgress($0) }
                }
            }
        }
        .floatingAction(title: "New issue", symbol: "plus", action: newIssue)
    }

    /// A new issue I left to look at something else: it is kept until I discard it or create it. A click reopens it.
    @ViewBuilder private func inProgress(_ session: NewIssueSession) -> some View {
        Group {
            let said = session.turns.first?.text ?? session.draft
            HoverCard(accent: Theme.mint, action: { withAnimation(Motion.spring) { store.composing = session } }) {
                VStack(alignment: .leading, spacing: 5) {
                    Eyebrow(text: "New issue in progress", color: Theme.mint)
                    Text(said.nonEmpty ?? "Not started").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    status(of: session)
                }
                .padding(.trailing, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            // Hatched with a dashed edge: it is a draft, not an issue on GitHub yet.
            .hatched(Theme.mint)
            .overlay(alignment: .topTrailing) {
                IconButton(symbol: "trash", help: "Discard this new issue", size: 24) {
                    withAnimation(Motion.spring) { store.forget(session) }
                }
                .padding(10)
            }
        }
    }

    @ViewBuilder private func status(of session: NewIssueSession) -> some View {
        if let turn = session.turns.last {
            if session.created != nil {
                Text("Created").font(.meta).foregroundStyle(Theme.success)
            } else if store.reply(of: session, round: turn.round) != nil {
                Text("The agent has replied: open it to answer").font(.meta).foregroundStyle(Theme.mint)
            } else if let job = store.job(of: session, round: turn.round) {
                switch job.status {
                case .failed, .cancelled:
                    Text("The agent stopped before it answered: open it to try again").font(.meta).foregroundStyle(Theme.danger)
                default:
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("The agent is working · \(NewIssueView.elapsed(since: job.startedAt, now: context.date))")
                            .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(NewIssueView.waiting(session, store: store, now: context.date))
                        .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
            }
        } else {
            Text("Not sent to the agent yet").font(.meta).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct TriageRow: View {
    @Environment(AppStore.self) private var store
    let issue: TriageIssue
    let showRepo: Bool

    var body: some View {
        HoverCard(accent: Theme.mint, action: { withAnimation(Motion.spring) { store.triaging = issue } }) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("#\(issue.number)").font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    if showRepo { RepoName(repo: issue.repo) }
                    PriorityChip(priority: issue.priority)
                    StageChip(stage: issue.stage)
                }
                Text(issue.title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                RelativeTime(date: issue.createdAt) { "opened \($0) ago" }.font(.meta).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contextMenu { Button("Open on GitHub") { NSWorkspace.shared.open(issue.url) } }
    }
}

/// One issue and its three questions in place of the list.
struct TriageView: View {
    @Environment(AppStore.self) private var store
    let issue: TriageIssue
    let close: () -> Void
    @State private var answers: [Int?]
    @State private var applying = false
    @State private var problem: String?

    /// `answered` pre-fills the answers: the README's screenshot shows a finished triage.
    init(issue: TriageIssue, answered: [Int?] = [], close: @escaping () -> Void) {
        self.issue = issue
        self.close = close
        _answers = State(initialValue: answered.isEmpty ? Array(repeating: nil, count: IssueTriage.questions.count) : answered)
    }

    var body: some View {
        let verdict = IssueTriage.verdict(answers)
        let editing = applying || store.labelEdits[issue.id] != nil
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(issue.number) \(issue.title)").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    IssueLabelRow(issue: issue) { problem = $0 }
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.right", help: "Open the issue on GitHub", size: 24) { NSWorkspace.shared.open(issue.url) }
            }
            .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    MarkdownView(text: issue.body, tone: Theme.textPrimary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            if let problem { ProblemText(text: problem).padding(.horizontal, 14) }
            TriageSteps(answers: $answers) {
                PillButton(title: applying ? "Applying..." : "Apply", symbol: "checkmark", disabled: verdict == nil || editing) {
                    if let verdict { apply(verdict) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func apply(_ verdict: TriageVerdict) {
        applying = true
        problem = nil
        Task {
            do {
                try await store.applyTriage(verdict, to: issue)
                if store.triaging?.id == issue.id { close() }
            } catch {
                problem = "Labels not set: \(error.localizedDescription)"
            }
            applying = false
        }
    }
}

/// The three scored questions as steps under the issue: a numbered circle each, filled once it
/// is answered. A click opens the question and its options over the step; a choice closes it,
/// and a click on an answered step opens it again to change the answer. The issue's text keeps
/// the screen. One row: the steps and the next question on the left, the score above the
/// screen's action on the right. Shared by triage and a new issue.
struct TriageSteps<Action: View>: View {
    @Binding var answers: [Int?]
    @ViewBuilder let action: () -> Action
    @State private var open: Int?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(Array(IssueTriage.questions.enumerated()), id: \.offset) { index, question in
                        if index > 0 {
                            Rectangle().fill(answers[index - 1] != nil ? Theme.mint : Theme.hairline).frame(width: 18, height: 1)
                        }
                        step(index, question: question)
                    }
                }
                if let next = answers.firstIndex(where: { $0 == nil }) {
                    Text(IssueTriage.questions[next].text).font(.meta).foregroundStyle(Theme.textTertiary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 8) {
                if let verdict = IssueTriage.verdict(answers) {
                    Text("Score \(verdict.score) of \(IssueTriage.maxScore)")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                    HStack(spacing: 6) {
                        PriorityChip(priority: verdict.priority)
                        StageChip(stage: verdict.stage)
                    }
                }
                action()
            }
        }
    }

    /// The first unanswered step is the one to take next; the chosen option names an answered one.
    private func step(_ index: Int, question: TriageQuestion) -> some View {
        let answer = answers[index]
        let next = answer == nil && answers.prefix(index).allSatisfy { $0 != nil }
        return Button { open = open == index ? nil : index } label: {
            ZStack {
                Circle().fill(answer != nil ? Theme.mint : Theme.core)
                Circle().strokeBorder(answer != nil || next ? Theme.mint : Theme.hairline, lineWidth: next ? 1.5 : 1)
                if answer != nil {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.canvas)
                } else {
                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(next ? Theme.mint : Theme.textSecondary)
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(answer.map { "\(question.text) \(question.options[$0].label)" } ?? question.text)
        .popover(isPresented: Binding(get: { open == index }, set: { open = $0 ? index : nil }), arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(question.text)").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(question.help).font(.meta).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { choice, option in
                    Button {
                        withAnimation(Motion.snappy) { answers[index] = choice }
                        open = nil
                    } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: answer == choice ? "largecircle.fill.circle" : "circle").padding(.top, 1)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.label).fixedSize(horizontal: false, vertical: true)
                                if !option.hint.isEmpty {
                                    Text(option.hint).font(.meta).foregroundStyle(Theme.textTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(answer == choice ? Theme.mint : Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }
            .padding(12)
            .frame(width: 320)
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
