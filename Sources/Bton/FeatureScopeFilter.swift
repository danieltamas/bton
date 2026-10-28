import BtonCore
import SwiftUI

/// The status dropdown beside the repo page's search box: any status, or one of them with its
/// count. A button and a popover rather than a native `Menu`, which shows no pointing hand; a
/// chosen status clears from the cross beside it.
struct FeatureScopeFilter: View {
    let report: FeatureReport
    @Binding var selection: FeatureFilter?
    @State private var open = false

    var body: some View {
        HStack(spacing: 6) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .medium))
                    if let selection {
                        Text("\(selection.rawValue) \(FeaturePage.count(selection, report: report))")
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                    }
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 7.5, weight: .semibold))
                }
                .foregroundStyle(selection == nil ? Theme.textTertiary : Theme.mint)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.canvas.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(selection == nil ? Theme.hairline : Theme.mint.opacity(0.6), lineWidth: selection == nil ? 0.5 : 1))
                .contentShape(Capsule())
            }
            .buttonStyle(PressStyle())
            .pointingHandCursor()
            .help(selection.map(Self.help) ?? "Every status")
            .accessibilityValue(selection?.rawValue ?? "any status")
            if selection != nil {
                Button { withAnimation(Motion.snappy) { selection = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help("Show every status")
                .accessibilityLabel("Show every status")
            }
        }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                row(nil, title: "Any status", count: nil)
                ForEach(FeatureFilter.allCases, id: \.self) { item in
                    row(item, title: item.rawValue, count: FeaturePage.count(item, report: report))
                }
            }
            .padding(6)
            .frame(width: 170)
        }
    }

    private static func help(_ item: FeatureFilter) -> String {
        item == .retired ? "Only the features the registry retired" : "Only the features \(item.rawValue)"
    }

    private func row(_ item: FeatureFilter?, title: String, count: Int?) -> some View {
        Button {
            withAnimation(Motion.snappy) { selection = item }
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).opacity(selection == item ? 1 : 0)
                    .accessibilityHidden(true)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 12)
                if let count {
                    Text("\(count)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(selection == item ? Theme.mint : Theme.textTertiary)
                }
            }
            .foregroundStyle(selection == item ? Theme.mint : Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
        .accessibilityAddTraits(selection == item ? .isSelected : [])
    }
}
