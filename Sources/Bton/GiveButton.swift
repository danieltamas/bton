import BtonCore
import SwiftUI

/// Give to: a PR of mine whose review waits on a teammate goes to another of the flow's
/// reviewers, picked from a popover. A button, so the pointing hand shows, not a native Menu.
struct GiveButton: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let move: Move
    let targets: [String]
    @State private var open = false

    var body: some View {
        let giving = store.taking.contains(pr.id)
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrowshape.turn.up.right").font(.system(size: 9, weight: .semibold))
                Text(giving ? "Giving..." : "Give to").lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.textTertiary)
            }
            .font(.meta.weight(.medium)).foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.core, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.wash.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .disabled(giving)
        .help("Hand the \(move.name) of #\(pr.number) to another reviewer; \(move.owner ?? "nobody") has not started it")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(targets, id: \.self) { login in
                    Button {
                        open = false
                        Task { await store.give(pr, to: login) }
                    } label: {
                        HStack(spacing: 8) {
                            Avatar(login: login)
                            Text(login).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle(scale: 0.98))
                }
            }
            .padding(6)
            .frame(width: 220)
        }
    }
}

extension AppStore {
    /// The row shows the new owner as soon as GitHub has it, the sync following in the background:
    /// a full sync can wait minutes behind a graph build or a check, and "Giving..." must not wait
    /// with it. A refusal names why and changes nothing.
    func give(_ pr: PullRequest, to login: String) async {
        guard let engine, taking.insert(pr.id).inserted else { return }
        defer { taking.remove(pr.id) }
        takeProblems[pr.id] = nil
        do {
            try await engine.give(repo: pr.repo, number: pr.number, to: login)
        } catch {
            takeProblems[pr.id] = "Not given: \(error.localizedDescription)"
            Task { await refresh() }
            return
        }
        showOwner(login, of: pr)
        Task { await refresh() }
    }
}
