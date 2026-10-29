import AppKit
import BtonCore
import SwiftUI

extension AppStore {
    /// I logged the agent in again: its waiting jobs start at this sync.
    func markLoggedIn(_ agent: String) async {
        try? await engine?.markLoggedIn(agent)
        await refresh()
    }

    /// How to log the agent's CLI in again, from its program.
    func loginHint(for agent: String) -> String {
        let program = agents[agent]?.argv.first ?? agent
        let name = URL(fileURLWithPath: program).lastPathComponent
        if AgentHardening.isClaude(program) { return "run \(name), then type /login" }
        return name == "codex" ? "run codex login" : "log \(name) in again"
    }
}

/// An agent whose login expired: one notice instead of every queued job failing the same way.
struct LoginNotice: View {
    @Environment(AppStore.self) private var store
    let agent: String

    var body: some View {
        let reason = store.jobs.first { $0.agent == agent && $0.flags?.contains(.loggedOut) == true }?.detail
        Bezel(radius: 13, fill: Theme.danger.opacity(0.10)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.exclamationmark").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(agent) is logged out, so its jobs wait. In Terminal, \(store.loginHint(for: agent)).")
                            .font(.meta).foregroundStyle(Theme.textPrimary)
                        if let reason {
                            Text(reason).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    Spacer()
                    PillButton(title: "Open Terminal", symbol: "terminal", prominent: false) {
                        if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                            NSWorkspace.shared.openApplication(at: terminal, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    AsyncPillButton(title: "I've logged in", runningTitle: "Checking...", symbol: "checkmark",
                                    id: "login:\(agent)") { await store.markLoggedIn(agent) }
                        .help("Its jobs start again at this sync; if it is still logged out, the next one fails and this comes back")
                }
            }
            .padding(10)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}
