import SwiftUI

/// A choice as a pill with a chevron that opens a list in a popover, the way the New issue screen
/// picks its repo and its type: a button, so the pointing hand shows, not a native Picker.
/// `pending` outlines the pill in mint until a choice is made.
struct SelectorPill: View {
    struct Option: Identifiable {
        let id: String
        let text: String
    }

    let text: String
    var pending = false
    let options: [Option]
    let selected: String?
    let choose: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Text(text).foregroundStyle(pending ? Theme.mint : Theme.textSecondary).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .font(.meta)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.core, in: Capsule())
            .overlay(Capsule().strokeBorder(pending ? Theme.mint.opacity(0.6) : Theme.wash.opacity(0.08), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle())
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(options) { option in
                        Button {
                            choose(option.id)
                            open = false
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                                    .opacity(selected == option.id ? 1 : 0)
                                Text(option.text).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressStyle(scale: 0.98))
                    }
                }
                .padding(6)
            }
            .frame(width: 260)
            .frame(maxHeight: 260)
        }
    }
}
