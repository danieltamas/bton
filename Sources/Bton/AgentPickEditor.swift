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

/// One `agent:model effort` setting on this Mac (a hat's, or a repo's work or reviews over it),
/// picked from the agents installed here. `rules` adds a free text, for the reviewer's rules or a
/// hat's playbook; `fallback` says what runs when nothing is picked; `clearTitle` names the button
/// that goes back to it.
struct AgentPickEditor: View {
    @Environment(AppStore.self) private var store
    let title: String
    let symbol: String
    let current: String?
    var fallback = "the flow's agent"
    var clearTitle = "Use the flow's"
    var rules: String?
    var rulesPrompt: String?
    var rulesPlaceholder: String?
    var rulesHeight: CGFloat = 70
    let save: (String, String) throws -> Void

    @State private var editing = false
    @State private var agent = ""
    @State private var model = ""
    @State private var effort = ""
    @State private var rulesText = ""
    @State private var problem: String?
    /// Each configured agent whose program this Mac lacks, by agent name: looked up when the
    /// editor appears and opens, never while it renders (a PATH walk per chip per keystroke).
    @State private var missing: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text("\(title): \(current ?? fallback)")
                    .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                // The pick stands in the file; the job it names fails at start on this Mac.
                if let program = current.flatMap(AgentPick.init).flatMap({ missing[$0.agent] }) {
                    Chip(text: "\(program) not installed", symbol: "exclamationmark.triangle", color: Theme.danger)
                        .help(AppStore.programSearchHint)
                }
                Button(editing ? "Cancel" : "Edit") { editing ? (editing = false) : begin() }
                    .buttonStyle(.plain).pointingHandCursor().font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            if editing {
                // An agent whose program is missing shows, so the owner sees what is configured, but is not picked.
                choices("Agent", values: store.agents.keys.sorted(), selection: $agent, missing: { missing[$0] != nil })
                let models = LocalModels.models(for: agent, template: store.agents[agent])
                if !models.isEmpty { choices("Model", values: models, selection: $model) }
                TextField("model (empty: the agent's own)", text: $model)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(8).background(Theme.core, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                choices("Effort", values: AgentPick.efforts, selection: $effort)
                if let rulesPrompt {
                    GlassEditor(text: $rulesText, monospaced: false, minHeight: rulesHeight)
                        .overlay(alignment: .topLeading) {
                            // Bton's own text shows through an empty editor, so the owner edits from it, not from nothing.
                            if rulesText.isEmpty, let rulesPlaceholder {
                                Text(rulesPlaceholder).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                                    .padding(10).allowsHitTesting(false)
                            }
                        }
                        // The hint is as long as Bton's core; the editor's frame cuts it, the button below gives it whole.
                        .clipped()
                    HStack(alignment: .top, spacing: 8) {
                        Text(rulesPrompt).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                        if rulesText.isEmpty, let rulesPlaceholder {
                            Button("Edit Bton's text") { rulesText = rulesPlaceholder }
                                .buttonStyle(.plain).pointingHandCursor().font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
                        }
                    }
                }
                if let problem { ProblemText(text: problem) }
                HStack(spacing: 8) {
                    PillButton(title: "Save", symbol: "checkmark") { commit() }
                    PillButton(title: clearTitle, symbol: "arrow.uturn.backward") { clear() }
                }
            }
        }
        .animation(Motion.snappy, value: editing)
        .onAppear(perform: lookUpPrograms)
    }

    private func lookUpPrograms() {
        missing = Dictionary(uniqueKeysWithValues: store.agents.keys.compactMap { name in store.missingProgram(of: name).map { (name, $0) } })
    }

    /// A row of buttons: tapping the chosen one again clears it, as a native picker would not.
    /// A value that is `missing` says so, carries the search hint, and can only be deselected.
    private func choices(_ label: String, values: [String], selection: Binding<String>,
                         missing: @escaping (String) -> Bool = { _ in false }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).font(.meta).foregroundStyle(Theme.textTertiary).frame(width: 44, alignment: .leading)
            WrapLayout(spacing: 6) {
                ForEach(values, id: \.self) { value in
                    let gone = missing(value)
                    let picked = selection.wrappedValue == value
                    let off = gone && !picked
                    Button { selection.wrappedValue = picked ? "" : value } label: {
                        Chip(text: gone ? "\(value) not installed" : value, color: picked ? Theme.mint : Theme.neutral,
                             style: picked ? .filled : .outline)
                            .opacity(off ? 0.5 : 1)
                    }
                    .buttonStyle(PressStyle()).pointingHandCursor(!off).disabled(off)
                    .help(gone ? AppStore.programSearchHint : "")
                }
            }
        }
    }

    private func begin() {
        lookUpPrograms()
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
        // A pick this Mac cannot run is refused when it is new; the rules of a pick saved earlier
        // (on another Mac, or before its program went) still save, the pick standing as it was.
        if line != (current ?? ""), let program = missing[agent] {
            problem = "\(agent) runs \(program), which is not installed on this Mac (\(AppStore.programSearchHint)): install it or pick another agent."
            return
        }
        run(line)
    }

    /// Back to the fallback: a hat drops its playbook with its pick (Bton's own is the fallback for
    /// both); a repo's Reviewer keeps its rules, which are not the pick's.
    private func clear() {
        if rulesPlaceholder != nil { rulesText = "" }
        run("")
    }

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
