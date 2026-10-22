import AppKit
import SwiftUI

/// The double bezel: a glass shell holding a machined core, with concentric corners. Every
/// card in Bton sits in one, so nothing lies flat on the canvas.
struct Bezel<Content: View>: View {
    var radius: CGFloat = Radius.card
    var fill: Color = Theme.core
    var glow: Color?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius - Radius.bezel, style: .continuous))
            .overlay {
                // The core's top edge catches the light; the sides fade out.
                RoundedRectangle(cornerRadius: radius - Radius.bezel, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Theme.highlight, .clear, .clear],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .padding(Radius.bezel)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.shell)
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    }
                    .shadow(color: (glow ?? .black).opacity(glow == nil ? 0.35 : 0.25), radius: 18, y: 8)
            }
    }
}

/// A small capsule label. `filled` is for what is mine or needs me; `tinted` for the rest.
/// `{clone}`, `{base}` and `{repo}`, filled from the repo a job works in prompts and agent argv
/// alike; hovering one says what it becomes.
struct RepoPlaceholderChips: View {
    var body: some View {
        ForEach([("{clone}", "The repo's checkout on this Mac"), ("{base}", "The branch PRs merge into"),
                 ("{repo}", "The repo's owner/name")], id: \.0) { name, meaning in
            Chip(text: name, color: Theme.neutral, style: .outline).help(meaning)
        }
    }
}

struct Chip: View {
    enum Style { case filled, tinted, outline, dashed }

    let text: String
    var symbol: String?
    var color: Color = Theme.neutral
    var style: Style = .tinted

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8.5, weight: .semibold)) }
            Text(text).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
        }
        // A control's label never wraps or truncates: the content around it yields instead.
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .foregroundStyle(style == .filled ? Theme.canvas : color)
        .background {
            switch style {
            case .filled: Capsule().fill(color)
            case .tinted: Capsule().fill(color.opacity(0.14))
            case .outline: Capsule().strokeBorder(color.opacity(0.45), lineWidth: 0.75)
            case .dashed: Capsule().strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 0.9, dash: [2.5, 2]))
            }
        }
    }
}

/// A microscopic uppercase label above a value or section.
struct Eyebrow: View {
    let text: String
    var color: Color = Theme.textTertiary

    var body: some View {
        Text(text.uppercased()).font(.eyebrow).tracking(1.4).foregroundStyle(color)
    }
}

/// Whether the menu bar panel is on screen. Perpetual motion pauses while it is not: a hidden
/// panel would otherwise redraw at the display's rate.
extension EnvironmentValues {
    @Entry var panelVisible = true
    /// Drawn once into an image (the README's screenshots): `ImageRenderer` draws no scroll
    /// view's content and runs no appear animation, so lists lay out flat and fully shown.
    @Entry var stillImage = false
}

/// A dot that breathes while something runs. The breath is a Core Animation loop, run by the
/// window server: a SwiftUI timeline would re-render and re-lay out the whole panel every frame
/// for each dot. It stops while the panel is hidden.
struct PulseDot: View {
    @Environment(\.panelVisible) private var panelVisible
    @Environment(\.stillImage) private var stillImage
    let color: Color
    var pulsing = true

    var body: some View {
        // ImageRenderer draws no AppKit view.
        if stillImage {
            Circle().fill(color).frame(width: 6, height: 6)
        } else {
            PulseLayer(color: NSColor(color), pulsing: pulsing && panelVisible).frame(width: 6, height: 6)
        }
    }
}

private struct PulseLayer: NSViewRepresentable {
    let color: NSColor
    let pulsing: Bool

    func makeNSView(context: Context) -> PulseView { PulseView() }
    func updateNSView(_ view: PulseView, context: Context) { view.show(color: color, pulsing: pulsing) }
}

final class PulseView: NSView {
    private let dot = CALayer()
    private let halo = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        clipsToBounds = false
        layer?.masksToBounds = false
        for circle in [halo, dot] {
            circle.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
            circle.cornerRadius = 3
            layer?.addSublayer(circle)
        }
        halo.opacity = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for circle in [halo, dot] { circle.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        CATransaction.commit()
    }

    func show(color: NSColor, pulsing: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.backgroundColor = color.cgColor
        halo.backgroundColor = color.withAlphaComponent(0.45).cgColor
        CATransaction.commit()
        guard pulsing != (halo.animation(forKey: "breath") != nil) else { return }
        if pulsing { halo.add(Self.breath, forKey: "breath") } else { halo.removeAnimation(forKey: "breath") }
    }

    private static var breath: CAAnimation {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.6
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let breath = CAAnimationGroup()
        breath.animations = [grow, fade]
        breath.duration = 1.4
        breath.timingFunction = CAMediaTimingFunction(name: .easeOut)
        breath.repeatCount = .infinity
        return breath
    }
}

/// A move or schedule asked to run now that has not started yet: it waits for its repo or the
/// next sync, and the row says so instead of keeping its button.
struct StartingLabel: View {
    let repo: String

    var body: some View {
        HStack(spacing: 5) {
            PulseDot(color: Theme.mint, pulsing: true)
            Text("starting").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.mint).lineLimit(1)
        }
        .help("Starts at the next sync with a free agent slot in \(repo), once no other job holds it")
    }
}

/// Follows its window's occlusion: a menu bar panel's views stay alive after it closes.
struct WindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = { shown in if visible != shown { visible = shown } }
    }
}

final class VisibilityView: NSView {
    var onChange: ((Bool) -> Void)?
    private var token: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let token { NotificationCenter.default.removeObserver(token) }
        token = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.report() }
            }
        }
        report()
    }

    /// After the current update: AppKit can move the view while SwiftUI lays it out.
    private func report() {
        let shown = window?.occlusionState.contains(.visible) ?? false
        DispatchQueue.main.async { [weak self] in self?.onChange?(shown) }
    }
}

/// A move or status glyph in its own tinted disc.
struct GlyphDisc: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

/// The physical press: everything clickable sinks a little under the pointer.
struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
            .pointingHandCursor()
    }
}

extension View {
    /// The hand over anything clickable. Set on every move, since the window's own cursor
    /// rects would take it back; nothing to undo when the view goes away mid-hover.
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active: NSCursor.pointingHand.set()
            case .ended: NSCursor.arrow.set()
            }
        }
    }
}

/// A round, light-weight icon button for toolbars and rows.
struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 26
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(hovering ? Theme.textPrimary : tint)
                .frame(width: size, height: size)
                .background(Color.white.opacity(hovering ? 0.10 : 0.05), in: Circle())
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(help)
    }
}

/// A pill button with its trailing icon in a disc of its own, flush with the right edge.
struct PillButton: View {
    let title: String
    var symbol = "arrow.up.right"
    var prominent = true
    var disabled = false
    let action: () -> Void
    /// Also off when a parent says `.disabled(...)`: it looks off either way.
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background((prominent ? Theme.canvas : Color.white).opacity(prominent ? 0.18 : 0.08), in: Circle())
                    .offset(x: hovering ? 1.5 : 0, y: hovering ? -1 : 0)
                    .scaleEffect(hovering ? 1.06 : 1)
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .foregroundStyle(prominent ? Theme.canvas : Theme.textPrimary)
            .background {
                if prominent { Capsule().fill(Theme.brand) } else { Capsule().fill(Color.white.opacity(0.07)) }
            }
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0.25 : 0.08), lineWidth: 0.5))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(PressStyle(scale: 0.97))
        .opacity(disabled || !isEnabled ? 0.4 : 1)
        .disabled(disabled)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering && isEnabled && !disabled } }
    }
}

/// A calm empty list: a glyph in a lit ring, one line, one hint.
struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.brand)
                .frame(width: 54, height: 54)
                .background(Circle().fill(Theme.core))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [Theme.mint.opacity(0.5), Theme.blue.opacity(0.1)],
                                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75))
                .shadow(color: Theme.mint.opacity(0.18), radius: 16)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if let detail {
                    Text(detail).font(.meta).foregroundStyle(Theme.textTertiary).multilineTextAlignment(.center)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rows rise into place, one after another, the first time a list shows.
struct RiseIn: ViewModifier {
    let index: Int
    @Environment(\.stillImage) private var stillImage
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown || stillImage ? 1 : 0)
            .offset(y: shown || stillImage ? 0 : 10)
            .onAppear {
                withAnimation(Motion.spring.delay(Double(min(index, 10)) * 0.035)) { shown = true }
            }
    }
}

extension View {
    func riseIn(_ index: Int) -> some View { modifier(RiseIn(index: index)) }
}

/// A card that lifts its core on hover and opens something on click.
struct HoverCard<Content: View>: View {
    var accent: Color?
    let action: (() -> Void)?
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        Bezel(fill: hovering ? Theme.coreHover : Theme.core) {
            HStack(spacing: 0) {
                if let accent {
                    Capsule().fill(accent.gradient).frame(width: 3).padding(.vertical, 10).padding(.leading, 6)
                        .shadow(color: accent.opacity(0.6), radius: 4)
                }
                content.padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .scaleEffect(hovering && action != nil ? 1.006 : 1)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .pointingHandCursor(action != nil)
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
    }
}

/// Restart and Quit, side by side wherever Bton can be closed from.
struct AppControls: View {
    var body: some View {
        HStack(spacing: 14) {
            control("Restart", symbol: "arrow.clockwise", help: "Quit Bton and open it again") { NSApp.relaunch() }
            control("Quit", symbol: "power", help: "Quit Bton: no move is checked or started until it runs again") {
                NSApp.terminate(nil)
            }
        }
    }

    private func control(_ title: String, symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .medium))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Theme.textSecondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// How far a date is from now, in days, hours and minutes, redrawn once a minute. SwiftUI's
/// relative style counts seconds under an hour, so every row with a date redraws every second.
struct RelativeTime: View {
    let date: Date
    var format: (String) -> String = { $0 }

    var body: some View {
        TimelineView(.everyMinute) { context in Text(format(Self.text(date, now: context.date))) }
    }

    static func text(_ date: Date, now: Date) -> String {
        let seconds = abs(now.timeIntervalSince(date))
        return seconds < 60 ? "under a minute" : formatter.string(from: seconds) ?? ""
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.unitsStyle = .short
        return formatter
    }()
}
