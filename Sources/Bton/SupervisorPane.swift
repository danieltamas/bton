import BtonCore
import SwiftUI

/// Settings > Supervisor: the agent that looks at each job the watchdog flags, once, and either
/// retries it with a note or tells the owner. It never writes to GitHub.
struct SupervisorPane: View {
    @Environment(AppStore.self) private var store
    @State private var prompt = ""
    @State private var problem: String?
    @State private var saved = false

    private static let budgets: [Decimal] = [2, 5, 10, 20]
    private static let timeouts = [5, 10, 15, 30]

    var body: some View {
        let settings = store.supervisor ?? SupervisorSettings(enabled: false)
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .supervisor, title: "Supervisor",
                       detail: "An agent that looks at each flagged job once: it retries it with a note, or tells you.")
            SettingsCard(title: "Supervise flagged jobs",
                         detail: "Failed, timed out, lease lost or far costlier than usual. Each PR head is looked at once; a retried job is never looked at again.") {
                HStack {
                    Toggle("Start the supervisor on flagged jobs", isOn: Binding(get: { settings.enabled },
                                                                                  set: { on in save { try store.setSupervisor(enabled: on) } }))
                        .toggleStyle(.switch).tint(Theme.mint)
                        .pointingHandCursor()
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    spend(budget: settings.dailyBudget ?? Supervision.defaultBudget)
                }
            }
            SettingsCard(title: "Agent", detail: "Claude only, with no shell, edits or web: it reads the job's log and the code, nothing more.") {
                HStack(spacing: 10) {
                    MenuField(title: settings.agent ?? Supervision.defaultAgent, options: claudeAgents) { agent in
                        save { try store.setSupervisor { $0.agent = agent == Supervision.defaultAgent ? nil : agent } }
                    }
                    MenuField(title: ClaudeModel.label(for: settings.model), options: ClaudeModel.choices.map(\.label)) { label in
                        save { try store.setSupervisor { $0.model = ClaudeModel.choices.first { $0.label == label }?.id } }
                    }
                }
            }
            SettingsCard(title: "Daily budget", detail: "No supervisor starts once today's supervise jobs cost this much.") {
                HStack(spacing: 6) {
                    ForEach(Self.budgets, id: \.self) { budget in
                        SegmentChip(title: "$\(budget)", selected: (settings.dailyBudget ?? Supervision.defaultBudget) == budget) {
                            save { try store.setSupervisor { $0.dailyBudget = budget == Supervision.defaultBudget ? nil : budget } }
                        }
                    }
                }
            }
            SettingsCard(title: "Time limit", detail: "A supervise job is stopped after this long.") {
                HStack(spacing: 6) {
                    ForEach(Self.timeouts, id: \.self) { minutes in
                        SegmentChip(title: "\(minutes) min", selected: (settings.timeoutMinutes ?? Supervision.defaultTimeoutMinutes) == minutes) {
                            save { try store.setSupervisor { $0.timeoutMinutes = minutes == Supervision.defaultTimeoutMinutes ? nil : minutes } }
                        }
                    }
                }
            }
            SettingsCard(title: "Prompt", detail: "Bton adds the flagged job's details and the end of its log after it. The verdict line it must end with is in the default.") {
                VStack(alignment: .trailing, spacing: 10) {
                    GlassEditor(text: $prompt, minHeight: 200)
                    HStack(spacing: 8) {
                        if saved { Chip(text: "saved", symbol: "checkmark", color: Theme.success).transition(.opacity) }
                        PillButton(title: "Reset to default", symbol: "arrow.uturn.backward", prominent: false,
                                   disabled: prompt == Supervision.defaultPrompt && settings.prompt == nil) {
                            prompt = Supervision.defaultPrompt
                            savePrompt()
                        }
                        PillButton(title: "Save prompt", symbol: "checkmark",
                                   disabled: prompt == (settings.prompt ?? Supervision.defaultPrompt), action: savePrompt)
                    }
                }
            }
            if let problem { ProblemText(text: problem) }
        }
        .animation(Motion.spring, value: saved)
        .onAppear { prompt = settings.prompt ?? Supervision.defaultPrompt }
    }

    private var claudeAgents: [String] {
        store.agents.filter { $0.value.argv.first.map(AgentHardening.isClaude) == true }.keys.sorted()
    }

    @ViewBuilder private func spend(budget: Decimal) -> some View {
        if let spent = Supervision.spentToday(store.jobs, now: .now) {
            Text(verbatim: "$\(spent.formatted(.number.precision(.fractionLength(2)))) of $\(budget) today")
                .font(.meta.monospacedDigit()).foregroundStyle(Theme.textTertiary)
        } else {
            Text("Today's spend is unknown: a supervise job has no price")
                .font(.meta).foregroundStyle(Theme.danger.opacity(0.85))
                .help("Add its model's price in Settings > Prices; until then no supervisor starts.")
        }
    }

    /// The prompt as saved, so the editor shows what the next supervisor gets, and a brief "saved".
    private func savePrompt() {
        save { try store.setSupervisorPrompt(prompt) }
        guard problem == nil else { return }
        prompt = store.supervisor?.prompt ?? Supervision.defaultPrompt
        saved = true
        Task { try? await Task.sleep(for: .seconds(1.6)); saved = false }
    }

    private func save(_ change: () throws -> Void) {
        do {
            try withAnimation(Motion.spring) { try change() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The supervisor's settings in `config.json`.
extension AppStore {
    func setSupervisor(enabled: Bool) throws {
        try setSupervisor { $0.enabled = enabled }
    }

    /// An empty prompt or the default is stored as nil, so a later default reaches it.
    func setSupervisorPrompt(_ prompt: String) throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        try setSupervisor { $0.prompt = trimmed.isEmpty || trimmed == Supervision.defaultPrompt ? nil : trimmed }
    }

    func setSupervisor(_ change: (inout SupervisorSettings) -> Void) throws {
        try update { config in
            var settings = config.supervisor ?? SupervisorSettings(enabled: false)
            change(&settings)
            config.supervisor = settings
        }
    }
}
