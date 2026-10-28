import BtonCore
import SwiftUI

/// The page's rows: each area with its features, sub-features under their parent. An area
/// folds to one line of status counts.
struct FeatureTree: View {
    let page: FeaturePage
    let open: (FeaturePage.Row) -> Void
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(page.areas) { area in
                    areaHeader(area)
                    if !collapsed.contains(area.id) {
                        ForEach(area.rows) { row in
                            FeatureRow(row: row) { open(row) }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
    }

    private func areaHeader(_ area: FeaturePage.AreaRows) -> some View {
        let folded = collapsed.contains(area.id)
        return Button {
            withAnimation(Motion.snappy) {
                if folded { collapsed.remove(area.id) } else { collapsed.insert(area.id) }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(folded ? -90 : 0))
                    .foregroundStyle(Theme.textTertiary)
                Eyebrow(text: area.area.name, color: Theme.textSecondary)
                if area.rows.isEmpty {
                    Text("no features yet").font(.meta).foregroundStyle(Theme.textTertiary)
                } else if folded {
                    ForEach(FeatureStatus.allCases, id: \.self) { status in
                        if let count = area.counts[status], count > 0 {
                            Chip(text: "\(count) \(status.rawValue)", color: FeatureStatusChip.color(status))
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 8).padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(folded ? "Show the area's features" : "Fold the area")
    }
}

/// One feature: its name, status, how long it has been there, and what is still open on it.
private struct FeatureRow: View {
    let row: FeaturePage.Row
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if row.depth > 0 {
                Branch().stroke(Theme.hairline, lineWidth: 1).frame(width: 10, height: 14)
                    .padding(.leading, CGFloat(row.depth - 1) * 14)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(row.feature.name).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    if let since = row.standing.since {
                        RelativeTime(date: since) { "\($0) \(row.standing.status.rawValue)" }
                    }
                    if row.standing.openIssues > 0 { Text("\(row.standing.openIssues) open issue\(row.standing.openIssues == 1 ? "" : "s")") }
                    if row.standing.openPullRequests > 0 { Text("\(row.standing.openPullRequests) open PR\(row.standing.openPullRequests == 1 ? "" : "s")") }
                }
                .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            // A retired feature reads as past: dimmed, its chip in the same grey.
            .opacity(row.standing.status == .retired ? 0.55 : 1)
            Spacer(minLength: 6)
            FeatureStatusChip(status: row.standing.status)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: open)
        .pointingHandCursor()
    }

    /// The elbow that hangs a sub-feature under its parent.
    private struct Branch: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX + 0.5, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX + 0.5, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}
