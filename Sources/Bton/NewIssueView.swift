import AppKit
import BtonCore
import SwiftUI

/// One new issue in the making: my messages, one agent turn after each, and the issue once the agent writes it.
@MainActor @Observable final class NewIssueSession {
    struct Turn: Codable, Equatable {
        var text: String
        var round: Int
        /// When I sent it: how long the agent has been wanted, before its job exists. nil in files from before.
        var sent: Date? = Date()
    }

    /// What survives a restart: the conversation and my edits. The agent's replies are in its jobs.
    struct Snapshot: Codable, Equatable {
        var id: String
        var repo: String
        var repoChosen: Bool
        var turns: [Turn]
        var nextRound: Int
        var draft: String
        var title: String
        var body: String
        var answers: [Int?]
        var loadedRound: Int?
    }

    let id: String
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
        id = NewIssues.newID()
        self.repo = repo
        repoChosen = chosen
    }

    init(_ saved: Snapshot) {
        id = saved.id
        repo = saved.repo
        repoChosen = saved.repoChosen
        turns = saved.turns
        nextRound = saved.nextRound
        draft = saved.draft
        title = saved.title
        body = saved.body
        answers = saved.answers
        loadedRound = saved.loadedRound
    }

    var snapshot: Snapshot {
        Snapshot(id: id, repo: repo, repoChosen: repoChosen, turns: turns, nextRound: nextRound, draft: draft,
                 title: title, body: body, answers: answers, loadedRound: loadedRound)
    }

    func newRound() -> Int {
        defer { nextRound += 1 }
        return nextRound
    }
}

extension AppStore {
    private var newIssuesFolder: URL { home.url.appendingPathComponent("new-issues", isDirectory: true) }

    /// New issues left open when Bton last quit.
    func loadNewIssues() {
        let files = (try? FileManager.default.contentsOfDirectory(at: newIssuesFolder, includingPropertiesForKeys: nil)) ?? []
        let saved = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(NewIssueSession.Snapshot.self, from: Data(contentsOf: $0)) }
        newIssues = saved.sorted { $0.id < $1.id }.map(NewIssueSession.init)
    }

    /// A turn that was sent but never reached an agent before the last quit (the request lives in memory) is sent again.
    func resumeNewIssues() async {
        for session in newIssues {
            guard let turn = session.turns.last, job(of: session, round: turn.round) == nil,
                  reply(of: session, round: turn.round) == nil else { continue }
            await askAgent(session)
        }
    }

    func persist(_ session: NewIssueSession) {
        guard newIssues.contains(where: { $0.id == session.id }) else { return }
        let file = newIssuesFolder.appendingPathComponent("\(session.id).json")
        // Created is final: a restart must never offer the same issue to create twice.
        if session.created != nil || (session.turns.isEmpty && session.draft.isEmpty) {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? FileManager.default.createDirectory(at: newIssuesFolder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(session.snapshot).write(to: file, options: .atomic)
    }

    /// Created or discarded: it is gone from the list and from disk.
    func forget(_ session: NewIssueSession) {
        newIssues.removeAll { $0.id == session.id }
        if composing?.id == session.id { composing = nil }
        try? FileManager.default.removeItem(at: newIssuesFolder.appendingPathComponent("\(session.id).json"))
    }

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
        // The agent's own notes from the earlier turns: it does not read the repo again to learn them.
        let notes = session.turns.dropLast().compactMap { turn in
            job(of: session, round: turn.round).flatMap(draftText(of:)).flatMap(NewIssues.notes(from:))
        }.joined(separator: "\n\n")
        await engine.requestCompose(NewIssues.Request(id: session.id, repo: session.repo, turn: last.round,
                                                      conversation: NewIssues.conversation(turns), notes: notes))
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
            // Whatever view is on screen: a restart must never offer this issue to create twice.
            persist(session)
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
    @Environment(\.openSettings) private var openSettingsWindow
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
        .onChange(of: session.snapshot) { store.persist(session) }
        .onChange(of: session.created) { store.persist(session) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 3) {
                Text("New issue").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                if session.turns.isEmpty && session.created == nil {
                    RepoSelector(session: session)
                } else {
                    Text(session.repo).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
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
                if let job {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("The agent is \(session.turns.count > 1 ? "working on your answers" : "reading the repo and what is open") · \(Self.elapsed(since: job.startedAt, now: context.date))")
                            .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.waiting(session, store: store, now: context.date))
                            .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }

    /// Before the agent's job exists: the sync that starts it reads GitHub first, which takes seconds.
    static func waiting(_ session: NewIssueSession, store: AppStore, now: Date) -> String {
        let reason = store.waitingReason(repo: session.repo, item: "new-\(session.id)") ?? "Starting the agent"
        guard let sent = session.turns.last?.sent else { return reason }
        return "\(reason) · \(elapsed(since: sent, now: now))"
    }

    static func elapsed(since start: Date, now: Date) -> String {
        Duration.seconds(max(0, Int(now.timeIntervalSince(start)))).formatted(.time(pattern: .minuteSecond))
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
        let voice = store.voice
        let someoneRecording = voice.recorder.phase != .idle || voice.recorder.starting
        let busy = someoneRecording && voice.owner == session.id
        return VStack(alignment: .trailing, spacing: 6) {
            if busy {
                VoiceStrip(recorder: voice.recorder, heard: voice.heard) { dictate() }
                    .onExitCommand { voice.cancel() }
            } else {
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
            }
            if let problem = voice.problem { ProblemText(text: problem) }
            HStack(spacing: 8) {
                if !busy {
                    let model = store.voiceSettings?.model ?? .defaultModel
                    let usable = store.voiceSettings?.enabled == true && (store.isDemo || store.voice.downloaded.contains(model))
                    if usable && !store.isDemo && (store.voice.preparing[model] != nil || someoneRecording) {
                        ProgressView().controlSize(.small).frame(width: 30, height: 30)
                            .help(someoneRecording ? "Another new issue is being dictated" : "Loading the voice model: you can record when it is done")
                    } else {
                        IconButton(symbol: "mic", help: usable ? "Dictate: click to record, click Stop to transcribe" : "Set up voice input",
                                   size: 30) { usable ? dictate() : setUpVoice() }
                            .disabled(locked)
                    }
                }
                PillButton(title: send, symbol: "paperplane",
                           disabled: locked || busy || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                               || store.composeBlocked != nil) {
                    let text = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await store.send(text, in: session) }
                }
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .task {
            if !store.isDemo, let settings = store.voiceSettings, settings.enabled { await store.voice.prepare(settings.model ?? .defaultModel) }
        }
    }

    /// Voice is off until Settings > Voice says otherwise: the mic then leads there.
    private func setUpVoice() {
        store.settingsPane = .voice
        NSApp.activate()
        openSettingsWindow()
    }

    /// The mic and the strip's Stop: starts a recording, or ends it and appends the words to the draft.
    private func dictate() {
        guard let settings = store.voiceSettings else { return }
        let session = session
        Task {
            await store.voice.toggle(settings: settings, owner: session.id) { text in
                session.draft = Voice.appending(text, to: session.draft)
                store.persist(session)
            }
        }
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

/// The repo the issue goes in, as a dropdown under the title: the repos Bton watches, in a list that
/// scrolls, so ten of them take one line. Until one is picked the field is outlined and the input waits.
private struct RepoSelector: View {
    @Environment(AppStore.self) private var store
    @Bindable var session: NewIssueSession
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(session.repoChosen ? session.repo : "Choose a repo...")
                    .foregroundStyle(session.repoChosen ? Theme.textSecondary : Theme.mint).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.meta)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.core, in: Capsule())
            .overlay(Capsule().strokeBorder(session.repoChosen ? Theme.wash.opacity(0.08) : Theme.mint.opacity(0.6), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.repos.map(\.slug).sorted { $0.lowercased() < $1.lowercased() }, id: \.self) { slug in
                        Button {
                            session.repo = slug
                            session.repoChosen = true
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .opacity(session.repoChosen && session.repo == slug ? 1 : 0)
                                Text(slug).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                }
                .padding(6)
            }
            .frame(width: 260)
            .frame(maxHeight: 260)
        }
    }
}
