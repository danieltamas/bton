import BtonCore
import SwiftUI

/// Settings > Agents > Hats: the four roles Bton's agents play, each with the agent that runs it on
/// this Mac and the operating defaults it works by. A repo card's Issue work and Reviewer sit over
/// the coder's and the reviewer's pick for that repo alone.
struct HatsSettings: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Hat.allCases, id: \.self) { hat in
                let settings = store.hats[hat.rawValue]
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Chip(text: hat.rawValue, color: Theme.color(forMove: hat.moves.first ?? ""))
                        Text(hat.detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text("Moves: " + hat.moves.joined(separator: ", ")).font(.meta).foregroundStyle(Theme.textTertiary)
                    AgentPickEditor(title: "Runs as", symbol: Theme.symbol(forMove: hat.moves.first ?? ""), current: settings?.pick,
                                    fallback: "the flow's agent", clearTitle: "Use Bton's",
                                    rules: settings?.playbook,
                                    rulesPrompt: "Playbook: the operating defaults this hat works by, read before the flow's prompt. Empty uses Bton's own, shown above. One line that is a path (/... or ~/...) reads a file at each start, a skill file for one. The move's own procedure (the review table, the fix report) stays Bton's.",
                                    rulesPlaceholder: PRPlaybook.core, rulesHeight: 220) { line, playbook in
                        try store.setHat(hat, pick: line, playbook: playbook)
                    }
                    if settings?.playbook.flatMap(Hats.file(in:)) != nil {
                        Chip(text: "playbook from a file", symbol: "doc.text", color: Theme.neutral, style: .outline)
                    }
                }
            }
        }
    }
}
