import BtonCore
import Foundation
import SwiftUI

/// The models this Mac's agents offer: Claude's aliases, and codex's own list from its cache.
enum LocalModels {
    static func models(for agent: String?, template: AgentTemplate?) -> [String] {
        guard let program = template?.argv.first else { return [] }
        if AgentHardening.isClaude(program) { return ["sonnet", "opus", "haiku"] }
        guard AgentHardening.isCodex(program) else { return [] }
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        guard let data = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")),
              let cache = try? JSONDecoder().decode(CodexCache.self, from: data) else { return [] }
        return cache.models.filter { $0.visibility == "list" }.map(\.slug).filter(ScheduleEntry.isValidModel)
    }

    private struct CodexCache: Decodable {
        struct Model: Decodable { let slug: String; let visibility: String? }
        let models: [Model]
    }
}

/// One `agent:model effort` setting of a repo on this Mac (its work or its reviews), picked from
/// the agents installed here. `rules` adds a free text, for the reviewer's rules.
struct AgentPickEditor: View {
    @Environment(AppStore.self) private var store
    let title: String
    let symbol: String
    let current: String?
    var rules: String?
    var rulesPrompt: String?
    let save: (String, String) throws -> Void

    @State private var editing = false
    @State private var agent = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var rulesText = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text("\(title): \(current ?? "the flow's agent")")
                    .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                Button(editing ? "Cancel" : "Edit") { editing ? (editing = false) : begin() }
                    .buttonStyle(.plain).pointingHandCursor().font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            if editing {
                choices("Agent", values: store.agents.keys.sorted(), selection: $agent)
                let models = LocalModels.models(for: agent, template: store.agents[agent])
                if !models.isEmpty { choices("Model", values: models, selection: $model) }
                TextField("model (empty: the agent's own)", text: $model)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(8).background(Theme.core, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                choices("Effort", values: AgentPick.efforts, selection: $effort)
                if let rulesPrompt {
                    GlassEditor(text: $rulesText, monospaced: false, minHeight: 70)
                    Text(rulesPrompt).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                }
                if let problem { ProblemText(text: problem) }
                HStack(spacing: 8) {
                    PillButton(title: "Save", symbol: "checkmark") { commit() }
                    PillButton(title: "Use the flow's", symbol: "arrow.uturn.backward") { clear() }
                }
            }
        }
        .animation(Motion.snappy, value: editing)
    }

    /// A row of buttons: tapping the chosen one again clears it, as a native picker would not.
    private func choices(_ label: String, values: [String], selection: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.meta).foregroundStyle(Theme.textTertiary).frame(width: 44, alignment: .leading)
            WrapLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    Button { selection.wrappedValue = selection.wrappedValue == value ? "" : value } label: {
                        Chip(text: value, color: selection.wrappedValue == value ? Theme.mint : Theme.neutral,
                             style: selection.wrappedValue == value ? .filled : .outline)
                    }
                    .buttonStyle(PressStyle()).pointingHandCursor()
                }
            }
        }
    }

    private func begin() {
        let pick = current.flatMap(AgentPick.init)
        agent = pick?.agent ?? ""
        model = pick?.model ?? ""
        effort = pick?.effort ?? ""
        rulesText = rules ?? ""
        problem = nil
        editing = true
    }

    private func commit() {
        let line = [agent + (model.isEmpty ? "" : ":" + model), effort].filter { !$0.isEmpty }.joined(separator: " ")
        run(line)
    }

    private func clear() { run("") }

    private func run(_ line: String) {
        do {
            try save(line, rulesText)
            problem = nil
            editing = false
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// Children in rows that wrap at the width they are given, so a long list of choices never widens its pane.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, placed.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}
