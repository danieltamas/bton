import AppKit
import BtonCore
import SwiftUI

/// A repo's module map in a window of its own, one per repo, brought back when it is open
/// already: the directories as circles sized by their code, the calls and imports between
/// them as lines (`ModuleMap`). Drawn in a Canvas from the graph's JSON, no web view.
@MainActor
enum ModuleMapWindow {
    static let help = "Open this repo's module map: its directories sized by their code, linked by calls and imports"
    private static var windows: [String: NSWindow] = [:]
    private static var closers: [String: any NSObjectProtocol] = [:]

    static func open(_ graph: CodeGraph.StoredGraph) {
        let window = windows[graph.slug] ?? make(graph)
        windows[graph.slug] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func make(_ graph: CodeGraph.StoredGraph) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Modules of \(graph.slug)"
        window.isReleasedWhenClosed = false
        // The screen reaches the window only weakly (through `MapView`), so the close below lets it go.
        window.contentView = NSHostingView(rootView: ModuleMapScreen(store: graph.url, view: MapView(window: window)))
        window.center()
        // The frame outlives the window: the next open comes back where it was left.
        window.setFrameAutosaveName("modules-\(graph.slug)")
        closers[graph.slug] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            Task { @MainActor in
                windows[graph.slug] = nil
                if let closer = closers.removeValue(forKey: graph.slug) { NotificationCenter.default.removeObserver(closer) }
            }
        }
        return window
    }
}

/// The map with its header (what it is of, how fine) and the panel for the picked module.
private struct ModuleMapScreen: View {
    let store: URL
    @State private var budget = ModuleMap.defaultBudget
    @State private var map: ModuleMap.Map?
    @State private var points: [String: ModuleMap.Point] = [:]
    @State private var problem: String?
    @State private var selected: String?
    @State private var view: MapView

    static let panelWidth: CGFloat = 300

    init(store: URL, view: MapView) {
        self.store = store
        _view = State(initialValue: view)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                ZStack {
                    Theme.canvas
                    if let map {
                        MapCanvas(map: map, points: points, selected: $selected, view: view)
                        if map.modules.isEmpty {
                            Text("No code symbols in this graph: it indexed documents only, or nothing yet.")
                                .font(.meta).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    if map == nil { loading }
                }
            }
            Divider()
            ModulePanel(map: map, selected: selected, onPick: { selected = $0 })
                .frame(width: Self.panelWidth)
        }
        .background(Theme.canvas)
        .task(id: budget) { await load() }
        .onAppear { view.install(panelWidth: Self.panelWidth) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let map {
                Text("\(map.modules.count) modules, \(map.symbols.formatted()) symbols in \(map.files.formatted()) files")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textPrimary)
                if let commit = map.commit {
                    Text("built from \(commit.prefix(8))").font(.meta).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer()
            ForEach(Array(zip(ModuleMap.budgets, ["Coarse", "Medium", "Fine"])), id: \.0) { value, title in
                PillButton(title: title, symbol: "circle.grid.2x2", prominent: budget == value) { budget = value }
                    .help("About \(value) modules")
            }
            IconButton(symbol: "arrow.counterclockwise", help: "Fit the map in the window", size: 24) { view.reset() }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var loading: some View {
        VStack(spacing: 10) {
            if let problem {
                ProblemText(text: problem).frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.small)
                Text("Reading the graph").font(.meta).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func load() async {
        let store = store, budget = budget
        do {
            let built = try await Task.detached(priority: .userInitiated) { () throws -> (ModuleMap.Map, [String: ModuleMap.Point]) in
                let map = try ModuleMap.read(store: store, budget: budget)
                return (map, ModuleMap.layout(map))
            }.value
            // A budget changed while this read ran: the newer load publishes, this one does not.
            guard !Task.isCancelled else { return }
            map = built.0
            points = built.1
            if let selected, !built.0.modules.contains(where: { $0.path == selected }) { self.selected = nil }
        } catch {
            problem = "The graph could not be read: \(error.localizedDescription)"
        }
    }
}

/// Where the map is looked at: zoom and pan, changed by drag, pinch and the scroll wheel
/// (the wheel through a window monitor, so the panel beside the map keeps scrolling its list).
@MainActor @Observable
final class MapView {
    var scale: CGFloat = 1
    var offset: CGSize = .zero
    private weak var window: NSWindow?
    private var monitor: Any?
    private var observers: [any NSObjectProtocol] = []

    init(window: NSWindow?) { self.window = window }

    func reset() { scale = 1; offset = .zero }

    func zoom(by factor: CGFloat, at point: CGPoint) {
        let next = min(8, max(0.4, scale * factor))
        let f = next / scale
        offset = CGSize(width: point.x - (point.x - offset.width) * f, height: point.y - (point.y - offset.height) * f)
        scale = next
    }

    /// The monitor lives while the window is open: `onAppear` and `onDisappear` fire once for a
    /// content view that stays in a window kept for its next open, so the window's own close and
    /// key notifications take the monitor down and put it back.
    func install(panelWidth: CGFloat) {
        guard observers.isEmpty, let window else { return }
        let center = NotificationCenter.default
        // A closed window is let go (`ModuleMapWindow` drops it), so its observers go with the monitor.
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.remove()
                self?.observers.forEach(center.removeObserver)
                self?.observers = []
            }
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.arm(panelWidth: panelWidth) }
        })
        arm(panelWidth: panelWidth)
    }

    private func arm(panelWidth: CGFloat) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let window = self.window, event.window === window, let content = window.contentView else { return event }
            let location = content.convert(event.locationInWindow, from: nil)
            guard location.x < content.bounds.width - panelWidth else { return event }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            // The canvas has its origin at the top left; the window's is at the bottom left.
            let point = CGPoint(x: location.x, y: content.bounds.height - location.y - MapCanvas.top)
            self.zoom(by: exp(delta * 0.004), at: point)
            return nil
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The circles and lines. A click picks a module, a drag pans, a pinch zooms; the hovered
/// module and its links come forward.
private struct MapCanvas: View {
    let map: ModuleMap.Map
    let points: [String: ModuleMap.Point]
    @Binding var selected: String?
    let view: MapView
    @State private var hovered: String?
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?

    /// The header's height, which the scroll-wheel monitor takes off the window's y.
    static let top: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas(rendersAsynchronously: false) { context, _ in
                draw(in: &context, size: size)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location): hovered = module(at: location, size: size)
                case .ended: hovered = nil
                }
            }
            .pointingHandCursor(hovered != nil)
            .onTapGesture { location in
                let hit = module(at: location, size: size)
                selected = hit == selected ? nil : hit
            }
            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                let start = dragStart ?? view.offset
                dragStart = start
                view.offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }.onEnded { _ in dragStart = nil })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                let start = pinchStart ?? view.scale
                pinchStart = start
                let center = CGPoint(x: value.startLocation.x, y: value.startLocation.y)
                view.zoom(by: start * value.magnification / view.scale, at: center)
            }.onEnded { _ in pinchStart = nil })
        }
    }

    // MARK: Geometry

    /// The square the layout fills, the largest that fits, centred in the canvas.
    private func side(_ size: CGSize) -> CGFloat { min(size.width, size.height) }

    /// By the layout's own radius, so circles the forces kept apart stay apart on screen.
    private func radius(_ module: ModuleMap.Module, size: CGSize) -> CGFloat {
        ModuleMap.radius(of: module, in: map) * side(size) * view.scale
    }

    private func center(_ path: String, size: CGSize) -> CGPoint? {
        guard let p = points[path] else { return nil }
        let s = side(size)
        let inset = CGPoint(x: (size.width - s) / 2, y: (size.height - s) / 2)
        return CGPoint(x: (inset.x + p.x * s) * view.scale + view.offset.width,
                       y: (inset.y + p.y * s) * view.scale + view.offset.height)
    }

    private func module(at location: CGPoint, size: CGSize) -> String? {
        var best: (String, CGFloat)?
        for module in map.modules {
            guard let c = center(module.path, size: size) else { continue }
            let d = hypot(c.x - location.x, c.y - location.y)
            if d <= radius(module, size: size) + 3, best.map({ d < $0.1 }) ?? true { best = (module.path, d) }
        }
        return best?.0
    }

    /// Links drawn once per pair, both directions summed.
    private var pairs: [(a: String, b: String, weight: Int)] {
        var merged: [String: (String, String, Int)] = [:]
        for link in map.links {
            let key = link.from < link.to ? link.from + "\u{1}" + link.to : link.to + "\u{1}" + link.from
            if let present = merged[key] { merged[key] = (present.0, present.1, present.2 + link.weight) } else { merged[key] = (link.from, link.to, link.weight) }
        }
        return merged.values.map { (a: $0.0, b: $0.1, weight: $0.2) }.sorted { $0.weight < $1.weight }
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let focus = hovered ?? selected
        let maxWeight = Double(map.links.map(\.weight).max() ?? 1)
        for pair in pairs {
            guard let a = center(pair.a, size: size), let b = center(pair.b, size: size) else { continue }
            let touches = focus == pair.a || focus == pair.b
            let width = 0.6 + 4 * (Double(pair.weight) / maxWeight).squareRoot()
            var line = Path()
            line.move(to: a)
            line.addLine(to: b)
            context.stroke(line, with: .color(Theme.textSecondary.opacity(touches ? 0.75 : focus == nil ? 0.22 : 0.08)),
                           lineWidth: width * (touches ? 1.3 : 1))
        }
        let groups = Array(Set(map.modules.map(\.group))).sorted()
        for module in map.modules {
            guard let c = center(module.path, size: size) else { continue }
            let r = radius(module, size: size)
            let color = Self.hue(groups.firstIndex(of: module.group) ?? 0)
            let dim = focus != nil && focus != module.path && !linked(module.path, to: focus!)
            let circle = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            context.fill(circle, with: .color(color.opacity(dim ? 0.25 : 0.85)))
            if module.path == selected {
                context.stroke(circle, with: .color(Theme.textPrimary), lineWidth: 2)
            } else if module.path == hovered {
                context.stroke(circle, with: .color(Theme.textPrimary.opacity(0.7)), lineWidth: 1.5)
            }
            let label = Text(ModuleMap.label(of: module, in: map))
                .font(.system(size: max(9, min(12, 9 + r / 8)), weight: .medium))
                .foregroundColor(Theme.textPrimary.opacity(dim ? 0.35 : 0.95))
            let at = CGPoint(x: c.x, y: c.y + r + 9)
            // A dark halo keeps the name legible over a line or a neighbour's circle.
            var halo = context
            halo.addFilter(.shadow(color: Theme.canvas.opacity(0.9), radius: 2))
            halo.draw(label, at: at, anchor: .center)
            context.draw(label, at: at, anchor: .center)
        }
    }

    private func linked(_ path: String, to other: String) -> Bool {
        map.links.contains { ($0.from == path && $0.to == other) || ($0.to == path && $0.from == other) }
    }

    /// One hue per top-level directory, so gateway, admin and landing read as regions.
    static func hue(_ index: Int) -> Color {
        let hues: [Double] = [0.56, 0.08, 0.33, 0.78, 0.13, 0.47, 0.92, 0.65, 0.02, 0.25]
        return Color(hue: hues[index % hues.count], saturation: 0.55, brightness: 0.85)
    }
}
