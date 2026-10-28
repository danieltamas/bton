import SwiftUI

/// The lists' search: a PR number or words from a title or a login. Escape or the cross clears it.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search PRs: #367, a title, a login"
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                .foregroundStyle(focused ? Theme.mint : Theme.textTertiary)
            TextField(prompt, text: $text)
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
                .pointingHandCursor()
                .help("Clear the search")
            }
        }
        .fieldCapsule(active: focused)
        .animation(Motion.snappy, value: focused)
        .padding(.horizontal, 14)
    }
}

/// The one capsule every field on a search row wears: the search box, the repo filter and the
/// status dropdown, at the same height with the same stroke, so a row of them reads as one line.
struct FieldCapsule: ViewModifier {
    static let height: CGFloat = 30
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 11)
            .frame(height: Self.height)
            .background(Theme.canvas.opacity(0.7), in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Theme.mint.opacity(0.6) : Theme.hairline, lineWidth: active ? 1 : 0.5))
            .contentShape(Capsule())
    }
}

extension View {
    /// Mint stroke while `active` (focused, or holding a choice).
    func fieldCapsule(active: Bool) -> some View { modifier(FieldCapsule(active: active)) }
}
