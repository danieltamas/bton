import AppKit
import BtonCore
import SwiftUI

/// A red check on the PR's head, whatever move the flow gives it: a red head under a review or
/// a fix still has to go green before it merges, and its pill names only the move. The chip
/// opens a way to run the failed workflows again, for a failure that was the runner's.
struct RedChecksChip: View {
    @Environment(AppStore.self) private var store
    let pr: PullRequest
    let red: [String]
    @State private var open = false
    @State private var problem: String?
    /// The workflows a press of Re-run asked GitHub for, on this popover.
    @State private var rerun: [String]?

    var body: some View {
        Button { open = true } label: {
            Chip(text: "\(red.joined(separator: ", ")) red", symbol: "xmark.octagon.fill", color: Theme.danger, style: .outline)
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
        .help("A check failed on this head")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Red on #\(pr.number)").font(.rowTitle).foregroundStyle(Theme.textPrimary)
                Text(rerun != nil
                     ? "Asked GitHub to run \(rerun!.joined(separator: ", ")) again on this head. The row clears once a sync reads it green."
                     : "\(red.joined(separator: ", ")) failed on this head. Re-run it when the failure was the runner's, or fix what it found and push.")
                    .font(.meta).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    PillButton(title: "Open on GitHub", prominent: false) { NSWorkspace.shared.open(pr.url) }
                    if rerun == nil {
                        AsyncPillButton(title: "Re-run \(red.joined(separator: ", "))", runningTitle: "Asking GitHub...",
                                        symbol: "arrow.clockwise", id: "rerun:\(pr.repo)#\(pr.number):\(pr.headSha)") {
                            problem = nil
                            do { rerun = try await store.rerunRedChecks(on: pr) } catch { problem = error.localizedDescription }
                        }
                        .help("Runs the failed workflow on this exact commit again; nothing else changes")
                    }
                }
                if let problem { ProblemText(text: problem) }
            }
            .padding(14)
            .frame(width: 340, alignment: .leading)
        }
    }
}
