import SwiftUI

/// A small dropdown beside the search box that narrows every list to one repo. A button and a
/// popover rather than a native `Menu`, which shows no pointing hand.
struct RepoFilter: View {
    let repos: [String]
    @Binding var selection: String?
    @State private var open = false

    static func short(_ slug: String) -> String { slug.split(separator: "/").last.map(String.init) ?? slug }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10, weight: .medium))
                if let selection { Text(Self.short(selection)).font(.system(size: 11, weight: .medium)).lineLimit(1) }
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
        .help(selection ?? "Every watched repo")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                row(nil, title: "All repos")
                ForEach(repos, id: \.self) { row($0, title: $0) }
            }
            .padding(6)
        }
    }

    private func row(_ slug: String?, title: String) -> some View {
        Button {
            withAnimation(Motion.spring) { selection = slug }
            open = false
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).opacity(selection == slug ? 1 : 0)
                Text(title).font(.system(size: 12))
                Spacer(minLength: 12)
            }
            .foregroundStyle(selection == slug ? Theme.mint : Theme.textPrimary)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .pointingHandCursor()
    }
}
