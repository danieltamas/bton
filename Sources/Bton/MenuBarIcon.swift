import AppKit
import Observation
import SwiftUI

/// The menu bar glyph: the menu bar shows a still image, so SwiftUI animations never run there.
/// At rest it is the template icon, which follows the menu bar's light or dark look. An agent at
/// work turns it blue with an arc beside it, drawn once: a frame redraws the status item on every
/// display, and an agent works for most of the day. A finished sync sends one mint ripple out of
/// it, the only drawing done frame by frame; a sync that failed leaves it orange until the next good one.
@MainActor @Observable
final class MenuBarIcon {
    enum Mode: Equatable { case idle, working, problem }

    private(set) var image: NSImage = .btonTemplate
    @ObservationIgnored private var mode: Mode = .idle
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var frame = 0
    @ObservationIgnored private var rippleUntil = 0

    private static let size = NSSize(width: 22, height: 22)
    private static let fps = 15.0
    private static let rippleFrames = 14
    private static let working = NSColor(Theme.color(for: .running))
    private static let synced = NSColor(Theme.mint)
    private static let problem = NSColor(Theme.unassigned)

    /// After every sync: the new mode, and a ripple when the sync went through.
    func update(mode: Mode, synced: Bool) {
        self.mode = mode
        if synced { rippleUntil = frame + Self.rippleFrames }
        draw()
        if frame < rippleUntil { startTimer() }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / Self.fps, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The common mode keeps it turning while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        frame += 1
        draw()
        if frame >= rippleUntil {
            timer?.invalidate()
            timer = nil
        }
    }

    private func draw() {
        let rippling = frame < rippleUntil
        guard mode != .idle || rippling else {
            image = .btonTemplate
            return
        }
        let color = switch mode {
        case .working: Self.working
        case .problem: Self.problem
        case .idle: Self.synced
        }
        let ripple = rippling ? CGFloat(Self.rippleFrames - (rippleUntil - frame)) / CGFloat(Self.rippleFrames) : nil
        let mode = mode, rippleColor = Self.synced
        image = NSImage(size: Self.size, flipped: false) { rect in
            let glyph = NSRect(x: 4, y: 4, width: 14, height: 14)
            NSImage.btonTemplate.draw(in: glyph)
            color.set()
            glyph.fill(using: .sourceAtop)
            let center = NSPoint(x: rect.midX, y: rect.midY)
            if mode == .working {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: 9.5, startAngle: 20, endAngle: 130)
                arc.lineWidth = 1.6
                arc.lineCapStyle = .round
                color.setStroke()
                arc.stroke()
            }
            if let ripple {
                let ring = NSBezierPath(ovalIn: NSRect(x: center.x - 6 - 4.5 * ripple, y: center.y - 6 - 4.5 * ripple,
                                                      width: 12 + 9 * ripple, height: 12 + 9 * ripple))
                ring.lineWidth = 1.4
                rippleColor.withAlphaComponent(1 - ripple).setStroke()
                ring.stroke()
            }
            return true
        }
    }
}
