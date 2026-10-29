import SwiftUI

/// The panel's bottom row: the status of the owner's branches (or when GitHub is read next),
/// Restart and Quit, and, until Bton is starred, the Star on GitHub offer on the left.
struct PanelFooter: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack(spacing: 10) {
            // The offer keeps its width, the status beside it truncates first, and the row keeps
            // its height: the capsule is taller than the status line and draws over the padding.
            if store.starOffer {
                AsyncPress(id: "star", action: { await store.starRepo() }) { running, press in
                    StarOffer(starring: running || store.demoStarring, star: press)
                }
                .fixedSize().layoutPriority(1).frame(height: 12)
            }
            if store.local.reports.isEmpty {
                Text("Checks GitHub every \(store.pollEvery)")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            } else {
                BranchSummary()
            }
            Spacer()
            AppControls()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.canvas.opacity(0.6))
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }
}
