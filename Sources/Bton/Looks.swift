import AppKit
import Observation
import SwiftUI

/// The looks Bton can wear, chosen under General. Each one is a palette and a finish; the
/// meaning of a colour (a move's hue, a status) is the same in every look.
enum Look: String, CaseIterable, Identifiable {
    case bton
    case solidGlass
    case solidGlassLight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bton: "Bton"
        case .solidGlass: "Solid Glass"
        case .solidGlassLight: "Solid Glass Light"
        }
    }

    var palette: Palette {
        switch self {
        case .bton: .bton
        case .solidGlass: .solidGlass
        case .solidGlassLight: .solidGlassLight
        }
    }
}

/// How a card is made.
enum Finish {
    /// A glass shell holding a machined core.
    case bezel
    /// One thick pane of smoky glass, its finish at the edge.
    case pane
}

struct Palette {
    let scheme: ColorScheme
    let canvas, canvasLift, shell, hairline, core, coreHover, highlight: Color
    /// What a control or a hover is tinted with: toward the text, so it shows on the canvas.
    let wash: Color
    let textPrimary, textSecondary, textTertiary: Color
    let mint, blue: Color
    /// What asks to be pressed and the marks that stand for Bton.
    let brand: LinearGradient
    let unassigned, danger, success, neutral: Color
    /// The icon's two lights bleed into the canvas; off, the canvas is even.
    let lit: Bool
    let finish: Finish
    /// A pane's second line inside its edge, its hairline outside, and the shadow it stands on.
    let paneInner, paneEdge, paneShade: Color

    /// Taken from the app icon: a deep navy canvas lit by its blue-to-mint tube.
    static let bton = Palette(
        scheme: .dark,
        canvas: Color(hex: 0x070B12), canvasLift: Color(hex: 0x0C1320), shell: .white.opacity(0.035),
        hairline: .white.opacity(0.075), core: Color(hex: 0x101826), coreHover: Color(hex: 0x141E2F),
        highlight: .white.opacity(0.11), wash: .white,
        textPrimary: .white.opacity(0.94), textSecondary: .white.opacity(0.58), textTertiary: .white.opacity(0.36),
        mint: Color(hex: 0x4FE3C1), blue: Color(hex: 0x3A7BF0),
        brand: LinearGradient(colors: [Color(hex: 0x3A7BF0), Color(hex: 0x2A9BEA), Color(hex: 0x4FE3C1)],
                              startPoint: .bottomLeading, endPoint: .topTrailing),
        unassigned: Color(hex: 0xFF9F43), danger: Color(hex: 0xFF6B6B), success: Color(hex: 0x3EE0A8),
        neutral: Color(hex: 0x8A97AD), lit: true, finish: .bezel,
        paneInner: .white.opacity(0.04), paneEdge: .white.opacity(0.06), paneShade: .black.opacity(0.45)
    )

    /// Solid Glass (deeplethe/solid-glass), its dark panes: a neutral grey page with no light of
    /// its own, panes that are solid from afar and glass only at their edges, near-white ink for
    /// what asks to be pressed, and hue kept for what a colour means. Its oklch tokens in sRGB.
    static let solidGlass = Palette(
        scheme: .dark,
        canvas: Color(hex: 0x0D0D0D), canvasLift: Color(hex: 0x141414), shell: .clear,
        hairline: .white.opacity(0.11), core: Color(hex: 0x1D1D1D), coreHover: Color(hex: 0x242424),
        highlight: .white.opacity(0.16), wash: .white,
        textPrimary: Color(hex: 0xFAFAFA), textSecondary: Color(hex: 0xA4A4A4), textTertiary: .white.opacity(0.42),
        mint: Color(hex: 0x54D2A4), blue: Color(hex: 0x449DF0),
        brand: LinearGradient(colors: [Color(hex: 0xEBEBEB)], startPoint: .top, endPoint: .bottom),
        unassigned: Color(hex: 0xF79C40), danger: Color(hex: 0xFF6467), success: Color(hex: 0x4AC777),
        neutral: Color(hex: 0x868686), lit: false, finish: .pane,
        paneInner: .white.opacity(0.04), paneEdge: .white.opacity(0.06), paneShade: .black.opacity(0.45)
    )

    /// The same panes in daylight: smoked white glass on a cool grey page, lit white along the
    /// top, shaded in a dark blue-grey, and near-black ink for what asks to be pressed.
    static let solidGlassLight = Palette(
        scheme: .light,
        canvas: Color(hex: 0xE4E6EB), canvasLift: Color(hex: 0xDBDEE3), shell: .clear,
        hairline: Color(hex: 0x292E38, opacity: 0.13), core: Color(hex: 0xEFF1F5), coreHover: Color(hex: 0xF6F7FA),
        highlight: .white.opacity(0.9), wash: Color(hex: 0x292E38),
        textPrimary: Color(hex: 0x0D0D0D), textSecondary: Color(hex: 0x5B5B5B), textTertiary: Color(hex: 0x868686),
        mint: Color(hex: 0x008760), blue: Color(hex: 0x0078CC),
        brand: LinearGradient(colors: [Color(hex: 0x161616)], startPoint: .top, endPoint: .bottom),
        unassigned: Color(hex: 0xD87400), danger: Color(hex: 0xE7000B), success: Color(hex: 0x0A924B),
        neutral: Color(hex: 0x6F7278), lit: false, finish: .pane,
        paneInner: .white.opacity(0.35), paneEdge: Color(hex: 0x3B4253, opacity: 0.14),
        paneShade: Color(hex: 0x1F2D4C, opacity: 0.14)
    )
}

/// The look this Mac chose, kept across launches. Every view that reads a `Theme` token reads
/// it through here, so a new choice redraws them all.
@MainActor
@Observable
final class Appearance {
    static let shared = Appearance()

    /// Set directly only for drawing that must not touch the saved choice (the README's screenshots).
    var look: Look {
        didSet { applyToApp() }
    }

    private static let key = "look"

    private init() {
        look = UserDefaults.standard.string(forKey: Self.key).flatMap(Look.init) ?? .bton
        applyToApp()
    }

    /// AppKit draws a text field's placeholder and its other controls from the window's
    /// appearance, which the menu bar panel does not take from SwiftUI's colour scheme: a light
    /// look left the search placeholder white on a white pane.
    private func applyToApp() {
        NSApplication.shared.appearance = NSAppearance(named: look.palette.scheme == .light ? .aqua : .darkAqua)
    }

    func choose(_ look: Look) {
        self.look = look
        UserDefaults.standard.set(look.rawValue, forKey: Self.key)
    }
}
