import BtonCore
import SwiftUI

/// Take it: a teammate's `assignee` move becomes mine. The first press asks again, naming whose it
/// is, since the second reassigns the PR on GitHub.
struct TakeButton: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let move: Move
    @State private var confirming = false

    var body: some View {
        let taking = store.taking.contains(pr.id)
        HStack(spacing: 4) {
            if confirming, !taking {
                RunNowButton(title: "Cancel", symbol: "xmark", color: Theme.neutral, help: "Leave it with \(move.owner ?? "the flow")") {
                    withAnimation(Motion.snappy) { confirming = false }
                }
            }
            RunNowButton(title: taking ? "Taking..." : confirming ? move.owner.map { "Take from \($0)" } ?? "Take it" : "Take it",
                         symbol: "hand.raised", color: Theme.color(forMove: move.name),
                         help: "Assign #\(pr.number) to you alone on GitHub and start its \(move.name) here") {
                guard !taking else { return }
                if confirming {
                    confirming = false
                    Task { await store.take(pr, from: move.owner) }
                } else {
                    withAnimation(Motion.snappy) { confirming = true }
                }
            }
        }
    }
}

extension AppStore {
    /// The row shows starting once the PR is mine; a refusal names why and changes nothing.
    func take(_ pr: PullRequest, from owner: String?) async {
        guard let engine, taking.insert(pr.id).inserted else { return }
        takeProblems[pr.id] = nil
        do {
            _ = try await engine.take(repo: pr.repo, number: pr.number, from: owner)
            markStarting(repo: pr.repo, item: "pr-\(pr.number)")
        } catch {
            takeProblems[pr.id] = "Not taken: \(error.localizedDescription)"
        }
        taking.remove(pr.id)
        await refresh()
    }
}
