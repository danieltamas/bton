import AppKit
import BtonCore
import SwiftUI

extension AppStore {
    /// Sets the issue's priority and stage from the answers, then syncs so it leaves the tab when it is ready.
    func applyTriage(_ verdict: TriageVerdict, to issue: TriageIssue) async throws {
        guard let github else { throw CocoaError(.fileNoSuchFile) }
        let edit = IssueTriage.edit(for: verdict, on: issue)
        try await github.editIssueLabels(add: edit.add, remove: edit.remove, repo: issue.repo, number: issue.number)
        await refresh()
    }
}

/// Open issues that are not ready yet, with no agent in the way: a click opens one with three
/// questions, and the answers set its priority and stage.
struct TriageList: View {
    @Environment(AppStore.self) private var store
    let issues: [TriageIssue]
    let showRepo: Bool
    let newIssue: () -> Void

    var body: some View {
        Group {
            if issues.isEmpty {
                EmptyState(symbol: "checklist", title: store.lastRefresh == nil ? "Reading GitHub" : "Nothing to triage",
                           detail: "Open issues that are not stage:ready, in progress or in review show here.")
            } else {
                RowStack(items: issues) { issue in
                    TriageRow(issue: issue, showRepo: showRepo)
                }
            }
        }
        .floatingAction(title: "New issue", symbol: "plus", action: newIssue)
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
                    Chip(text: issue.priority.map { "priority \($0)" } ?? "no priority",
                         color: issue.priority == nil ? Theme.danger : Theme.neutral, style: .outline)
                    Chip(text: issue.stage ?? "no stage", color: Theme.neutral, style: .outline)
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
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                    .keyboardShortcut(.cancelAction)
                VStack(alignment: .leading, spacing: 3) {
                    Text("#\(issue.number) \(issue.title)").font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(2)
                    Text(([issue.priority.map { "priority \($0)" }, issue.stage.map { "stage \($0)" }].compactMap { $0 })
                        .joined(separator: " · ").nonEmpty ?? "No priority or stage yet")
                        .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                IconButton(symbol: "arrow.up.right", help: "Open the issue on GitHub", size: 24) { NSWorkspace.shared.open(issue.url) }
            }
            .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(issue.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(900))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    TriageQuestions(answers: $answers)
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            if let problem { ProblemText(text: problem).padding(.horizontal, 14) }
            HStack(spacing: 8) {
                if let verdict {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Score \(verdict.score) of \(IssueTriage.maxScore)")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.mint)
                        Text(verdict.labels.joined(separator: " + ")).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                } else {
                    Text("Answer all three to score it").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                PillButton(title: applying ? "Applying..." : "Apply", symbol: "checkmark", disabled: verdict == nil || applying) {
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
                close()
            } catch {
                problem = "Labels not set: \(error.localizedDescription)"
            }
            applying = false
        }
    }
}

/// The three scored questions, answered with a click; shared by triage and a new issue.
struct TriageQuestions: View {
    @Binding var answers: [Int?]

    var body: some View {
        ForEach(Array(IssueTriage.questions.enumerated()), id: \.offset) { index, question in
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(question.text)").font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Text(question.help).font(.meta).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(question.options.enumerated()), id: \.offset) { choice, option in
                    Button { withAnimation(Motion.snappy) { answers[index] = choice } } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: answers[index] == choice ? "largecircle.fill.circle" : "circle")
                                .padding(.top, 1)
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
                        .foregroundStyle(answers[index] == choice ? Theme.mint : Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
            }
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
