import BtonCore
import SwiftUI

/// Bton's design tokens, from the look chosen under General (`Looks.swift`).
@MainActor
enum Theme {
    private static var palette: Palette { Appearance.shared.look.palette }

    // Canvas and surfaces
    static var canvas: Color { palette.canvas }
    static var canvasLift: Color { palette.canvasLift }
    static var shell: Color { palette.shell }
    static var hairline: Color { palette.hairline }
    static var core: Color { palette.core }
    static var coreHover: Color { palette.coreHover }
    static var highlight: Color { palette.highlight }
    static var finish: Finish { palette.finish }
    static var lit: Bool { palette.lit }
    static var scheme: ColorScheme { palette.scheme }
    static var wash: Color { palette.wash }
    static var paneInner: Color { palette.paneInner }
    static var paneEdge: Color { palette.paneEdge }
    static var paneShade: Color { palette.paneShade }

    // Text
    static var textPrimary: Color { palette.textPrimary }
    static var textSecondary: Color { palette.textSecondary }
    static var textTertiary: Color { palette.textTertiary }

    // Brand
    static var mint: Color { palette.mint }
    static var blue: Color { palette.blue }
    static var brand: LinearGradient { palette.brand }

    // Signals
    static var unassigned: Color { palette.unassigned }
    static var danger: Color { palette.danger }
    static var success: Color { palette.success }
    static var neutral: Color { palette.neutral }

    /// A hue as the dark looks show it, and its deeper partner on a light canvas, where the
    /// bright one would wash out.
    static func hue(_ dark: UInt32, light: UInt32) -> Color {
        Color(hex: scheme == .light ? light : dark)
    }

    /// One hue per move, the same everywhere a move appears: PR rows, jobs, notifications.
    static func color(forMove name: String) -> Color {
        switch name {
        case "review": hue(0x7AA2FF, light: 0x456DD3)
        case "fix": hue(0xFFB547, light: 0x9E6801)
        case "merge": success
        case "resolve": danger
        case "decide": hue(0xC792FF, light: 0x8E51C7)
        case "finish": neutral
        case "schedule": hue(0x5CC8FF, light: 0x047EAD)
        case "supervise": hue(0xFF8FB1, light: 0xBB436E)
        case "draft": mint
        default: neutral
        }
    }

    nonisolated static func symbol(forMove name: String) -> String {
        switch name {
        case "review": "eye"
        case "fix": "wrench.adjustable"
        case "merge": "arrow.triangle.merge"
        case "resolve": "arrow.triangle.branch"
        case "decide": "signpost.right"
        case "finish": "pencil.line"
        case "schedule": "clock.arrow.circlepath"
        case "supervise": "binoculars"
        case "draft": "text.bubble"
        default: "circle.dashed"
        }
    }

    static func color(forTier tier: String) -> Color {
        switch tier {
        case "quick fix": hue(0x5CC8FF, light: 0x047EAD)
        case "high-risk": hue(0xFF7A59, light: 0xCB390D)
        default: hue(0x7AA2FF, light: 0x456DD3)
        }
    }

    /// One hue per priority, so the urgent ones read at a glance; none is neutral.
    static func color(forPriority priority: String?) -> Color {
        switch priority {
        case "high": hue(0xFF7A59, light: 0xCB390D)
        case "medium": hue(0xFFB547, light: 0x9E6801)
        case "low": hue(0x5CC8FF, light: 0x047EAD)
        default: neutral
        }
    }

    /// One hue per stage of an issue's life: ready is Bton's mint, work under way is the running blue,
    /// a PR in review is the review hue, a plan to settle is amber, and triage waits uncolored.
    static func color(forStage stage: String?) -> Color {
        switch stage {
        case "ready": mint
        case "in-progress": hue(0x4C8DFF, light: 0x2A6DE1)
        case "review": hue(0x7AA2FF, light: 0x456DD3)
        case "spec": hue(0xFFB547, light: 0x9E6801)
        default: neutral
        }
    }

    /// A label's hue: the priority and stage hues Bton draws everywhere, GitHub's own colour for
    /// any other label, neutral when GitHub gave none.
    static func color(forLabel name: String, hex: String) -> Color {
        switch RepoLabels.family(of: name) {
        case IssueTriage.priorityPrefix: return color(forPriority: String(name.dropFirst(IssueTriage.priorityPrefix.count)).lowercased())
        case IssueTriage.stagePrefix: return color(forStage: String(name.dropFirst(IssueTriage.stagePrefix.count)).lowercased())
        default:
            guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return neutral }
            return Color(hex: value)
        }
    }

    static func color(for status: Job.Status) -> Color {
        switch status {
        case .running: hue(0x4C8DFF, light: 0x2A6DE1)
        case .succeeded: success
        case .failed: danger
        case .cancelled: neutral
        }
    }

    nonisolated static func symbol(for status: Job.Status) -> String {
        switch status {
        case .running: "bolt.fill"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        case .cancelled: "stop.fill"
        }
    }

    static func color(for flow: FlowStatus?) -> Color {
        switch flow {
        case .ready?: success
        case .unsupported?: unassigned
        case .invalid?: danger
        case .some(.none), nil: neutral
        }
    }
}

/// Spring curves with mass: nothing in Bton snaps or eases linearly.
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)
}

enum Radius {
    static let card: CGFloat = 16
    static let bezel: CGFloat = 3
    static let control: CGFloat = 10
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Font {
    static let eyebrow = Font.system(size: 9.5, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    static let meta = Font.system(size: 11)
    static let statValue = Font.system(size: 26, weight: .semibold, design: .rounded)
    static let statSmall = Font.system(size: 17, weight: .semibold, design: .rounded)
}

/// The canvas every Bton surface sits on, with the icon's two lights bleeding in from the top
/// in a look that has them.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.canvas
            if Theme.lit {
                RadialGradient(colors: [Theme.blue.opacity(0.22), .clear], center: .init(x: 0.1, y: -0.05),
                               startRadius: 0, endRadius: 260)
                RadialGradient(colors: [Theme.mint.opacity(0.12), .clear], center: .init(x: 0.95, y: 0.02),
                               startRadius: 0, endRadius: 220)
            }
        }
        .ignoresSafeArea()
    }
}
