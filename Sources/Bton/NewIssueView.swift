import AppKit
import BtonCore
import SwiftUI

/// One new issue in the making: my messages, one agent turn after each, and the issue once the agent writes it.
@MainActor @Observable final class NewIssueSession {
    struct Turn { var text: String; var round: Int }

    let id = NewIssues.newID()
    var repo: String
    /// With several repos the issue goes nowhere until I pick one: the agent reads that repo, and the issue is filed there.
    var repoChosen: Bool
    var turns: [Turn] = []
    private var nextRound = 1
    var draft = ""
    var title = ""
    var body = ""
    var answers: [Int?] = Array(repeating: nil, count: IssueTriage.questions.count)
    /// The round whose issue text is in `title` and `body`, so a later edit is not overwritten.
    var loadedRound: Int?
    var creating = false
    var problem: String?
    var created: URL?

    init(repo: String, chosen: Bool = true) {
        self.repo = repo
        repoChosen = chosen
    }

    func newRound() -> Int {
        defer { nextRound += 1 }
        return nextRound
    }
}

extension AppStore {
    func job(of session: NewIssueSession, round: Int) -> Job? {
        jobs.first {
            $0.key.move == NewIssues.move && $0.key.repo == session.repo && $0.key.item == "new-\(session.id)"
                && $0.key.head == String(round)
        }
    }

    /// The agent's reply to a round, once its job succeeded.
    func reply(of session: NewIssueSession, round: Int) -> NewIssues.Reply? {
        if let demo = demoReplies[round] { return demo }
        guard let job = job(of: session, round: round), job.status == .succeeded, let text = draftText(of: job) else { return nil }
        return NewIssues.reply(from: text)
    }

    func askAgent(_ session: NewIssueSession) async {
        guard let engine, let last = session.turns.last else { return }
        let turns: [(isOwner: Bool, text: String)] = session.turns.flatMap { turn -> [(isOwner: Bool, text: String)] in
            var parts = [(isOwner: true, text: turn.text)]
            switch reply(of: session, round: turn.round) {
            case let .questions(text): parts.append((false, text))
            case let .ready(title, body):
                // What I changed in the issue is what the agent must start from.
                let current = session.loadedRound == turn.round ? (session.title, session.body) : (title, body)
                parts.append((false, "\(NewIssues.readyMarker)\nTitle: \(current.0)\n\n\(current.1)"))
            case nil: break
            }
            return parts
        }
        await engine.requestCompose(NewIssues.Request(id: session.id, repo: session.repo, turn: last.round,
                                                      conversation: NewIssues.conversation(turns)))
        markStarting(repo: session.repo, item: "new-\(session.id)")
        await refresh()
    }

    func send(_ text: String, in session: NewIssueSession) async {
        session.turns.append(.init(text: text, round: session.newRound()))
        session.draft = ""
        await askAgent(session)
    }

    /// A failed turn asks again as a new round, so it is a job of its own.
    func retryTurn(_ session: NewIssueSession) async {
        guard !session.turns.isEmpty else { return }
        session.turns[session.turns.count - 1].round = session.newRound()
        await askAgent(session)
    }

    /// Creates the issue under my login, with the priority and stage the answers set. The body goes
    /// through a file in Bton's home (0600), never argv.
    func createIssue(from session: NewIssueSession) async {
        guard let github, let verdict = IssueTriage.verdict(session.answers), !session.creating,
              let round = session.turns.last?.round, let job = job(of: session, round: round),
              let output = outputFiles(of: job).first else { return }
        session.creating = true
        session.problem = nil
        defer { session.creating = false }
        do {
            let file = output.appendingPathExtension("issue")
            try Data(session.body.utf8).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            session.created = try await github.createIssue(repo: session.repo, title: session.title, bodyFile: file,
                                                           labels: verdict.labels)
            await refresh()
        } catch {
            session.problem = "Not created: \(error.localizedDescription)"
        }
    }

    var composeBlocked: String? {
        agents[NewIssues.defaultAgent]?.argv.first.map(AgentHardening.isClaude) == true
            ? nil : "A new issue needs a Claude Code agent named \(NewIssues.defaultAgent) (Settings > Agents)"
    }
}

/// The new issue in place of the list: describe it, answer the agent's questions, then check the
/// issue it wrote, score it, and press Create.
struct NewIssueView: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: NewIssueSession
    let close: () -> Void

    var body: some View {
        let last = session.turns.last
        let job = last.flatMap { store.job(of: session, round: $0.round) }
        let reply = last.flatMap { store.reply(of: session, round: $0.round) }
        VStack(spacing: 8) {
            header
            if let url = session.created {
                created(url)
            } else if session.turns.isEmpty {
                start
            } else {
                thread(last: last, job: job, reply: reply)
            }
        }
        .onChange(of: last?.round) { loadIssue(reply, round: last?.round) }
        .onChange(of: reply) { loadIssue(reply, round: last?.round) }
        .onAppear { loadIssue(reply, round: last?.round) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 3) {
                Text("New issue").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                Text(session.repoChosen ? session.repo : "Pick a repo").font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
    }

    private func loadIssue(_ reply: NewIssues.Reply?, round: Int?) {
        guard case let .ready(title, body)? = reply, let round, session.loadedRound != round else { return }
        session.title = title
        session.body = body
        session.loadedRound = round
    }

    // MARK: before the first message

    private var start: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.repos.count > 1 { repoChoice }
            Text(session.repoChosen
                 ? "Say in a few words what you want. The agent reads \(session.repo)'s code, its open issues and what was merged, and asks what is missing."
                 : "The issue is filed in this repo, and the agent reads its code, open issues and merged PRs while you talk.")
                .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            input(placeholder: session.repoChosen ? "What should be built or fixed?" : "Pick a repo first", send: "Start",
                  locked: !session.repoChosen)
            if let blocked = store.composeBlocked { ProblemText(text: blocked).padding(.horizontal, 14) }
            Spacer(minLength: 0)
        }
    }

    private var repoChoice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which repo is this issue for?").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            ForEach(store.repos, id: \.slug) { repo in
                let selected = session.repoChosen && session.repo == repo.slug
                Button {
                    withAnimation(Motion.snappy) {
                        session.repo = repo.slug
                        session.repoChosen = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        Text(repo.slug).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(selected ? Theme.mint : Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 14)
    }

    // MARK: the conversation

    @ViewBuilder private func thread(last: NewIssueSession.Turn?, job: Job?, reply: NewIssues.Reply?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(session.turns.enumerated()), id: \.offset) { index, turn in
                        bubble(turn.text, mine: true)
                        let isLast = index == session.turns.count - 1
                        switch store.reply(of: session, round: turn.round) {
                        case let .questions(text)?: bubble(text, mine: false)
                        case .ready?: bubble(isLast ? "The issue is below. Change what you like, score it, then Create."
                                             : "I wrote the issue.", mine: false)
                        case nil: if isLast { status(job) }
                        }
                    }
                    if case .ready? = reply { issue }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.never)
            .onChange(of: session.turns.count) { withAnimation { proxy.scrollTo("end") } }
            .onChange(of: job?.status) { withAnimation { proxy.scrollTo("end") } }
        }
        if let problem = session.problem { ProblemText(text: problem).padding(.horizontal, 14) }
        if case .ready? = reply { createBar }
        if job?.status != .running, job != nil || store.waitingReason(repo: session.repo, item: "new-\(session.id)") == nil {
            input(placeholder: reply.map { if case .ready = $0 { "Ask for a change..." } else { "Your answers..." } } ?? "Your answers...",
                  send: "Send").disabled(job?.status == .failed || job?.status == .cancelled)
        }
    }

    @ViewBuilder private func status(_ job: Job?) -> some View {
        if let job, job.status == .failed || job.status == .cancelled {
            VStack(alignment: .leading, spacing: 6) {
                ProblemText(text: job.detail ?? "The agent stopped before it answered.")
                PillButton(title: "Try again", symbol: "arrow.clockwise", prominent: false) { Task { await store.retryTurn(session) } }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(job == nil ? (store.waitingReason(repo: session.repo, item: "new-\(session.id)") ?? "Starting the agent...")
                     : "Reading the repo and what is open...")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(mine ? Theme.textPrimary : Theme.textSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mine ? Theme.mint.opacity(0.12) : Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func input(placeholder: String, send: String, locked: Bool = false) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextEditor(text: $session.draft)
                .font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .padding(8)
                .frame(height: 74)
                .disabled(locked)
                .opacity(locked ? 0.5 : 1)
                .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if session.draft.isEmpty {
                        Text(placeholder).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 13).padding(.top, 8).allowsHitTesting(false)
                    }
                }
            PillButton(title: send, symbol: "paperplane",
                       disabled: locked || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.composeBlocked != nil) {
                let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await store.send(text, in: session) }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: the issue

    /// Always in view under the issue, so the score and Create never scroll away.
    private var createBar: some View {
        let verdict = IssueTriage.verdict(session.answers)
        return HStack(spacing: 8) {
            if let verdict {
                Text("Score \(verdict.score) of \(IssueTriage.maxScore) · \(verdict.labels.joined(separator: " + "))")
                    .font(.meta).foregroundStyle(Theme.mint).lineLimit(1)
            } else {
                Text("Answer all three to score it").font(.meta).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            PillButton(title: session.creating ? "Creating..." : "Create issue", symbol: "plus.circle",
                       disabled: verdict == nil || session.creating || session.title.trimmingCharacters(in: .whitespaces).isEmpty
                           || session.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task { await store.createIssue(from: session) }
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private var issue: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: $session.title)
                .textFieldStyle(.plain).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                .padding(8).background(Theme.core, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            TextEditor(text: $session.body)
                .font(.system(size: 11.5)).foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .padding(6).frame(height: 190)
                .background(Theme.core, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text("Priority and stage, scored as in Triage, so the issue is created with both:")
                .font(.meta).foregroundStyle(Theme.textTertiary)
            TriageQuestions(answers: $session.answers)
        }
    }

    private func created(_ url: URL) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.success)
            Text("Issue created").font(.rowTitle).foregroundStyle(Theme.textPrimary)
            Text(url.absoluteString).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            HStack(spacing: 8) {
                PillButton(title: "Open on GitHub", symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(url) }
                PillButton(title: "Done", symbol: "checkmark", action: close)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
