import BtonCore
import SwiftUI

/// "Star on GitHub", glowing gold in the panel footer until it is done. One click stars Bton
/// through the owner's own `gh`; the yes is remembered, so the offer never comes back.
struct StarOffer: View {
    /// The press is on its way: a spinner, "Starring...", no second press.
    let starring: Bool
    let star: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var stillImage
    @State private var glow = false
    @State private var hovering = false

    private let gold = Color(red: 1.0, green: 0.78, blue: 0.28)

    var body: some View {
        Button(action: star) {
            HStack(spacing: 5) {
                if starring {
                    ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 11, height: 11)
                } else {
                    Image(systemName: "star.fill").font(.system(size: 10.5, weight: .semibold))
                        .offset(x: hovering ? 1.5 : 0, y: hovering ? -1 : 0)
                        .scaleEffect(hovering ? 1.06 : 1)
                }
                Text(starring ? "Starring..." : "Star on GitHub").font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
            }
            .foregroundStyle(gold)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(gold.opacity(hovering ? 0.26 : 0.14)))
            .overlay(Capsule().strokeBorder(gold.opacity(hovering ? 0.95 : glow ? 0.65 : 0.3), lineWidth: 0.75))
            .shadow(color: gold.opacity(hovering ? 0.7 : glow ? 0.5 : 0.15), radius: hovering || glow ? 9 : 3)
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .opacity(starring ? 0.6 : 1)
        .disabled(starring)
        .onHover { over in withAnimation(Motion.snappy) { hovering = over && !starring } }
        .help("Star \(RepoStar.repo) on GitHub with your gh account")
        // The pulse only while the panel shows: a closed panel animates nothing.
        .onChange(of: panelVisible, initial: true) { _, visible in pulse(visible) }
    }

    private func pulse(_ on: Bool) {
        guard on, !reduceMotion, !stillImage else {
            withAnimation(.linear(duration: 0)) { glow = false }
            return
        }
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) { glow = true }
    }
}
