import SwiftUI

/// The lists' search: a PR number or words from a title or a login. Escape or the cross clears it.
struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.mint : Theme.textTertiary)
            TextField("Search PRs: #367, a title, a login", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onExitCommand { text = "" }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
        .background(Theme.canvas.opacity(0.7), in: Capsule())
        .overlay(Capsule().strokeBorder(focused ? Theme.mint.opacity(0.6) : Theme.hairline, lineWidth: focused ? 1 : 0.5))
        .animation(Motion.snappy, value: focused)
        .padding(.horizontal, 14)
    }
}
