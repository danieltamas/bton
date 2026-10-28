import BtonCore
import SwiftUI

/// Take it: a teammate's `assignee` or `reviewer` move becomes mine, in one press. A review owned
/// through GitHub's review requests reads "Review here": nothing is assigned.
struct TakeButton: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let move: Move

    var body: some View {
        let taking = store.taking.contains(pr.id)
        let asReviewer = store.flows[pr.repo]?.flow.map { FlowEngine.ownerKind(for: pr, flow: $0) == "reviewer" } ?? false
        let review = asReviewer && move.name == "review"
        RunNowButton(title: taking ? (review ? "Starting..." : "Taking...") : (review ? "Review here" : "Take it"),
                     symbol: review ? "eye" : "hand.raised", color: Theme.color(forMove: move.name),
                     help: asReviewer
                         ? "Ask GitHub for your review on #\(pr.number) and run its \(move.name) here; the assignee stays"
                         : "Assign #\(pr.number) to you alone on GitHub and start its \(move.name) here",
                     disabled: taking) {
            Task { await store.take(pr, from: move.owner) }
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
        // Until the refresh shows the PR as mine, or the row would offer Take it again.
        await refresh()
        taking.remove(pr.id)
    }
}
