import BtonCore
import SwiftUI

/// What the editor is open on: a new schedule or a saved one.
enum ScheduleDraft: Identifiable {
    case new
    case existing(ScheduleEntry)

    var id: String {
        switch self {
        case .new: "new"
        case let .existing(entry): "schedule-\(entry.number ?? 0)"
        }
    }

    var entry: ScheduleEntry? {
        if case let .existing(entry) = self { entry } else { nil }
    }
}

/// The Claude models a schedule can pin. A schedule without one runs on whatever the user's
/// ~/.claude/settings.json names, which changes under it; a pinned id does not.
enum ClaudeModel {
    static let choices: [(id: String?, label: String)] = [
        (nil, "Agent's default"),
        ("claude-fable-5-1", "Fable 5.1"),
        ("claude-opus-5-5", "Opus 5.5"),
        ("claude-sonnet-5-5", "Sonnet 5.5"),
        ("claude-haiku-5-5", "Haiku 5.5"),
    ]

    /// A hand-edited id outside the list shows as written.
    static func label(for model: String?) -> String {
        choices.first { $0.id == model }?.label ?? model ?? "Agent's default"
    }
}

private enum IntervalUnit: Int, CaseIterable, Identifiable {
    case minutes = 1, hours = 60, days = 1440
    var id: Self { self }
    var label: String {
        switch self {
        case .minutes: "minutes"
        case .hours: "hours"
        case .days: "days"
        }
    }
}

/// One schedule's form. Settings shows it in a sheet, the menu bar in place of its list; either
/// way it closes through `done` once saved, deleted or cancelled.
struct ScheduleEditor: View {
    @Environment(AppStore.self) private var store
    let entry: ScheduleEntry?
    var compact = false
    let done: () -> Void
    @State private var draft: ScheduleEntry
    @State private var amount: String
    @State private var unit: IntervalUnit
    @State private var timeout: String
    @State private var problem: String?

    init(entry: ScheduleEntry?, compact: Bool = false, done: @escaping () -> Void) {
        self.entry = entry
        self.compact = compact
        self.done = done
        let start = entry ?? ScheduleEntry(name: "", everyMinutes: 60, enabled: true, agent: "claude")
        _draft = State(initialValue: start)
        let unit = IntervalUnit.allCases.last { start.everyMinutes % $0.rawValue == 0 } ?? .minutes
        _unit = State(initialValue: unit)
        _amount = State(initialValue: String(start.everyMinutes / unit.rawValue))
        _timeout = State(initialValue: String(start.timeoutMinutes ?? 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Eyebrow(text: entry == nil ? "New schedule" : "Edit schedule", color: Theme.color(forMove: "schedule"))
                    Text(entry?.name ?? "Run an agent on a timer").font(.system(size: compact ? 15 : 18, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                Spacer()
                IconButton(symbol: "xmark", help: "Close without saving", action: done)
                    .keyboardShortcut(.cancelAction)
            }
            field("Name") { GlassField(placeholder: "PR queue", text: $draft.name) }
            HStack(alignment: .top, spacing: 10) {
                field("Repo") {
                    menu(draft.repo.map(shortName) ?? "Choose...", options: store.repos.filter { $0.path != nil }.map(\.slug)) { draft.repo = $0 }
                }
                field("Agent") {
                    menu(draft.agent ?? "Choose...", options: store.agents.keys.sorted()) { draft.agent = $0 }
                }
                if pinsModel {
                    field("Model") {
                        menu(ClaudeModel.label(for: draft.model), options: ClaudeModel.choices.map(\.label)) { label in
                            draft.model = ClaudeModel.choices.first { $0.label == label }?.id
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                field("Every") {
                    HStack(spacing: 6) {
                        GlassField(placeholder: "1", text: $amount).frame(width: 52)
                        menu(unit.label, options: IntervalUnit.allCases.map(\.label)) { label in
                            unit = IntervalUnit.allCases.first { $0.label == label } ?? .minutes
                        }
                    }
                }
                field("Time limit") {
                    HStack(spacing: 6) {
                        GlassField(placeholder: "60", text: $timeout).frame(width: 52)
                        Text("min").font(.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
                .fixedSize()
            }
            if pinsModel, !helperChoices.isEmpty {
                field("Second opinion") {
                    HStack(spacing: 6) {
                        ForEach(helperChoices, id: \.self) { name in helperToggle(name) }
                        Spacer(minLength: 0)
                    }
                    Text("The agent may ask these when a task is hard. Each ask and its answer is kept in the job's log.")
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                }
            }
            field("Prompt") {
                GlassEditor(text: Binding(get: { draft.prompt ?? "" }, set: { draft.prompt = $0 }), minHeight: compact ? 120 : 180)
                    .overlay(alignment: .topLeading) {
                        if (draft.prompt ?? "").isEmpty {
                            Text("What the agent does on each run. It starts in a fresh worktree of the branch PRs merge into.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 13).padding(.vertical, 8).allowsHitTesting(false)
                        }
                    }
                HStack(spacing: 6) {
                    Text("Placeholders").font(.meta).foregroundStyle(Theme.textTertiary)
                    RepoPlaceholderChips()
                }
            }
            HStack(spacing: 18) {
                Toggle("On", isOn: enabled)
                Toggle("Only when a PR changed", isOn: Binding(get: { draft.onlyOnChange == true },
                                                               set: { draft.onlyOnChange = $0 ? true : nil }))
                    .help("Skips a run when no PR in the repo was opened, updated or merged since the last successful run started")
            }
            .toggleStyle(.switch).controlSize(.small).tint(Theme.color(forMove: "schedule"))
            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            if let problem { ProblemText(text: problem) }
            HStack(spacing: 8) {
                if let entry {
                    IconButton(symbol: "trash", help: "Delete \(entry.name)", tint: Theme.danger) {
                        do {
                            try store.removeSchedule(entry.number)
                            done()
                        } catch {
                            problem = error.localizedDescription
                        }
                    }
                }
                Spacer()
                PillButton(title: "Cancel", symbol: "xmark", prominent: false, action: done)
                PillButton(title: entry == nil ? "Create" : "Save", symbol: "checkmark", action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .animation(Motion.spring, value: problem)
    }

    /// Only Claude takes `--model`; any other agent runs its template as written.
    private var pinsModel: Bool {
        draft.agent.flatMap { store.agents[$0]?.argv.first }.map(AgentHardening.isClaude) ?? false
    }

    /// Every other agent; one whose program is missing shows, but cannot be picked.
    private var helperChoices: [String] {
        store.agents.keys.sorted().filter { $0 != draft.agent }
    }

    private func helperToggle(_ name: String) -> some View {
        let picked = draft.helpers?.contains(name) == true
        let installed = store.agents[name]?.argv.first.flatMap(Executables.resolve) != nil
        return Button {
            var helpers = draft.helpers ?? []
            if picked { helpers.removeAll { $0 == name } } else { helpers.append(name) }
            draft.helpers = helpers.isEmpty ? nil : helpers
        } label: {
            Chip(text: installed ? name : "\(name) not installed", symbol: picked ? "checkmark" : "plus",
                 color: installed ? Theme.mint : Theme.neutral, style: picked ? .tinted : .outline)
        }
        .buttonStyle(.plain)
        .disabled(!installed && !picked)
        .help(installed ? "Let the agent ask \(name)" : "Install its program first")
    }

    private var current: ScheduleEntry? {
        entry.flatMap { entry in store.schedules.first { $0.number == entry.number } }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { current?.enabled ?? draft.enabled }, set: { on in
            if let current { try? store.setSchedule(current.number, enabled: on) } else { draft.enabled = on }
        })
    }

    private func shortName(_ slug: String) -> String {
        slug.split(separator: "/").last.map(String.init) ?? slug
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: label)
            content()
        }
    }

    private func menu(_ title: String, options: [String], pick: @escaping (String) -> Void) -> some View {
        MenuField(title: title, options: options, pick: pick)
    }

    private func save() {
        // Bounded before multiplying: a huge number of days would overflow Int.
        guard let count = Int(amount.trimmingCharacters(in: .whitespaces)), count > 0,
              count <= ScheduleEntry.everyMinutesRange.upperBound else {
            problem = "Run it every 5 minutes to 7 days."
            return
        }
        guard let limit = Int(timeout.trimmingCharacters(in: .whitespaces)) else {
            problem = "Enter the time limit in whole minutes."
            return
        }
        var next = draft
        if !pinsModel { next.model = nil; next.helpers = nil }
        next.helpers = next.helpers?.filter { $0 != next.agent }
        // The on/off switch of a saved schedule writes through at once, also from the list, so
        // the stored value wins over the one this editor opened with.
        next.enabled = current?.enabled ?? draft.enabled
        next.everyMinutes = count * unit.rawValue
        next.timeoutMinutes = limit
        do {
            try store.saveSchedule(next)
            done()
        } catch {
            problem = error.localizedDescription
        }
    }
}
