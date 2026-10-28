import BtonCore
import SwiftUI

/// The agents this Mac may start unattended, each an argv with `{prompt}` and `{session}` filled
/// per job. Which tools run unattended is this Mac owner's call, so these never come from a repo.
struct AgentsPane: View {
    @Environment(AppStore.self) private var store
    @State private var adding = false
    @State private var problem: String?

    /// Read-only, so a helper reviews and never edits the tree the asking agent works in.
    static let codex = ["codex", "exec", "--sandbox", "read-only", "--skip-git-repo-check", "--", "{prompt}"]

    /// Offered once codex is installed and no agent runs it yet.
    private var canAddCodex: Bool {
        store.agents["codex"] == nil && !store.agents.values.contains { $0.argv.first == "codex" }
            && Executables.resolve("codex") != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                PaneHeader(pane: .agents, title: "Agents",
                           detail: "The command each agent runs. One argument per line, never through a shell.")
                Spacer()
                if canAddCodex {
                    PillButton(title: "Add codex", symbol: "plus", prominent: false) {
                        do { try store.saveAgent("codex", argv: Self.codex, replacing: nil) } catch { problem = error.localizedDescription }
                    }
                    .help("Codex answers in the job's checkout and cannot change it; a schedule's Claude can ask it")
                }
                if !adding { PillButton(title: "New agent", symbol: "plus") { withAnimation(Motion.spring) { adding = true } } }
            }
            if let problem { ProblemText(text: problem) }
            if adding {
                AgentCard(name: "", argv: [], isNew: true) { withAnimation(Motion.spring) { adding = false } }
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            ForEach(Array(store.agents.keys.sorted().enumerated()), id: \.element) { index, name in
                AgentCard(name: name, argv: store.agents[name]?.argv ?? [], isNew: false) {}.riseIn(index)
            }
            SettingsCard(title: "Drafts and new issues",
                         detail: "The Claude model that drafts replies to issue questions and writes new issues. Not your Claude default, which may be the dearest model.") {
                MenuField(title: ClaudeModel.label(for: store.draftModel), options: ClaudeModel.choices.compactMap { $0.id == nil ? nil : $0.label }) { label in
                    do { try store.update { $0.draftModel = ClaudeModel.choices.first { $0.label == label }?.id } } catch { problem = error.localizedDescription }
                }
            }
            SettingsCard(title: "Code graphs",
                         detail: "graphify maps a repo's code into modules and their links. For a repo with \"Build a code graph for agents\" on (Repos), Bton rebuilds the graph after a sync when the branch moved, keeps it under ~/.bton/graphs and links it into every checkout an agent gets; the registry job draws its areas from it. The Python that has graphify installed: empty looks in ~/.venvs/graphifyy-arm64 and ~/.local/pipx/venvs/graphifyy.") {
                GraphifyPythonField()
            }
            if store.agents.isEmpty && !adding {
                EmptyState(symbol: "cpu", title: "No agents", detail: "Without one, Bton starts nothing on this Mac.")
                    .frame(height: 220)
            }
        }
    }
}

private struct AgentCard: View {
    @Environment(AppStore.self) private var store
    let original: String
    let originalArgv: [String]
    let isNew: Bool
    let done: () -> Void
    @State private var name: String
    @State private var lines: String
    @State private var problem: String?
    @State private var saved = false

    init(name: String, argv: [String], isNew: Bool, done: @escaping () -> Void) {
        original = name
        originalArgv = argv
        self.isNew = isNew
        self.done = done
        _name = State(initialValue: name)
        _lines = State(initialValue: argv.joined(separator: "\n"))
    }

    private var argv: [String] {
        lines.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    private var dirty: Bool { isNew || name != original || argv != originalArgv }

    var body: some View {
        Bezel(glow: isNew ? Theme.mint : nil) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    GlyphDisc(symbol: "cpu", color: SettingsPane.agents.color, size: 30)
                    GlassField(placeholder: "name, e.g. codex", text: $name, monospaced: true).frame(width: 200)
                    let users = store.schedules.filter { $0.agent == original }.count
                    if users > 0 { Chip(text: "\(users) schedule\(users == 1 ? "" : "s")", color: Theme.color(forMove: "schedule")) }
                    if !isNew, let program = originalArgv.first, Executables.resolve(program) == nil {
                        Chip(text: "\(program) not installed", symbol: "exclamationmark.triangle", color: Theme.danger)
                            .help("Bton looks for it on PATH and in ~/.local/bin, /opt/homebrew/bin and /usr/local/bin")
                    }
                    Spacer()
                    if saved { Chip(text: "saved", symbol: "checkmark", color: Theme.success).transition(.opacity) }
                    if !isNew {
                        IconButton(symbol: "trash", help: "Remove \(original)", tint: Theme.danger) {
                            do { try store.removeAgent(original) } catch { problem = error.localizedDescription }
                        }
                    }
                }
                GlassEditor(text: $lines, monospaced: true, minHeight: 130)
                HStack(spacing: 6) {
                    Text("Placeholders").font(.meta).foregroundStyle(Theme.textTertiary)
                    Chip(text: "{prompt}", color: Theme.mint, style: .outline)
                    Chip(text: "{session}", color: Theme.mint, style: .outline)
                    RepoPlaceholderChips()
                }
                // The buttons get a row of their own: a longer placeholder list never squeezes them.
                HStack(spacing: 8) {
                    Spacer()
                    if isNew { PillButton(title: "Cancel", symbol: "xmark", prominent: false, action: done) }
                    PillButton(title: isNew ? "Add agent" : "Save", symbol: "checkmark", disabled: !dirty, action: save)
                }
                if let problem { ProblemText(text: problem) }
            }
            .padding(16)
        }
        .animation(Motion.spring, value: problem)
        .animation(Motion.spring, value: saved)
    }

    private func save() {
        do {
            try store.saveAgent(name.trimmingCharacters(in: .whitespaces), argv: argv, replacing: isNew ? nil : original)
            problem = nil
            saved = true
            done()
            Task { try? await Task.sleep(for: .seconds(1.6)); saved = false }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The graphify Python path, saved when the field is left or Return is pressed.
private struct GraphifyPythonField: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                GlassField(placeholder: "~/.venvs/graphifyy-arm64/bin/python", text: $text, monospaced: true)
                    .onSubmit(save)
                if CodeGraph.python(configured: store.graphifyPython) == nil {
                    Chip(text: "not found", symbol: "exclamationmark.triangle", color: Theme.danger)
                } else {
                    Chip(text: "found", symbol: "checkmark", color: Theme.success)
                }
            }
            if let problem { ProblemText(text: problem) }
        }
        .onAppear { text = store.graphifyPython ?? "" }
        .onDisappear(perform: save)
    }

    private func save() {
        do { try store.setGraphifyPython(text); problem = nil } catch { problem = error.localizedDescription }
    }
}
