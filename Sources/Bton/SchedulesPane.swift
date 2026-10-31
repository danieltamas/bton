import BtonCore
import SwiftUI

/// This Mac's schedules: an agent with the owner's own prompt, in one watched repo, every so
/// often. Each run gets a fresh worktree of the branch PRs merge into and shows under Jobs. New and
/// existing schedules open in a sheet over the list.
struct SchedulesPane: View {
    @Environment(AppStore.self) private var store
    @State private var editing: ScheduleDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .bottom) {
                PaneHeader(pane: .schedules, title: "Schedules",
                           detail: "Run an agent on a timer, in a clean worktree of the branch PRs merge into.")
                Spacer(minLength: 12)
                PillButton(title: "New schedule", symbol: "plus") { editing = .new() }
            }
            if store.schedules.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "No schedules yet",
                           detail: "A PR queue drain every hour, a weekly triage: any prompt, on a timer.")
                    .frame(height: 260)
            } else {
                VStack(spacing: 6) {
                    ForEach(Array(store.schedules.enumerated()), id: \.element.id) { index, entry in
                        ScheduleRow(entry: entry, last: store.lastJob(of: entry)) { editing = .existing(entry) }
                            .riseIn(index)
                    }
                }
            }
        }
        .sheet(item: $editing) { draft in
            ScheduleEditor(entry: draft.entry) { editing = nil }
                .padding(24)
                .frame(width: 540)
                .background(Theme.canvasLift)
                .environment(store)
                .preferredColorScheme(Theme.scheme)
        }
    }
}
