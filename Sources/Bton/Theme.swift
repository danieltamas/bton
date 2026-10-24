import BtonCore
import SwiftUI

/// Bton's design tokens, from the look chosen under General (`Looks.swift`). Bton always draws
/// dark, so a look has one value per token.
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

    /// One hue per move, the same everywhere a move appears: PR rows, jobs, notifications.
    static func color(forMove name: String) -> Color {
        switch name {
        case "review": Color(hex: 0x7AA2FF)
        case "fix": Color(hex: 0xFFB547)
        case "merge": success
        case "resolve": danger
        case "decide": Color(hex: 0xC792FF)
        case "finish": neutral
        case "schedule": Color(hex: 0x5CC8FF)
        case "supervise": Color(hex: 0xFF8FB1)
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
        case "quick fix": Color(hex: 0x5CC8FF)
        case "high-risk": Color(hex: 0xFF7A59)
        default: Color(hex: 0x7AA2FF)
        }
    }

    static func color(for status: Job.Status) -> Color {
        switch status {
        case .running: Color(hex: 0x4C8DFF)
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
