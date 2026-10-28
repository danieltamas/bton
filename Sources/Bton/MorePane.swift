import AppKit
import BtonCore
import SwiftUI

/// One of the owner's other open source tools, as the More apps pane shows it: the same card
/// MacMax shows, so the two apps point at each other the same way.
struct MoreApp: Identifiable {
    enum Kind { case menuBar, terminal }

    let name: String
    /// The file in Support/MoreApps, copied into the bundle by scripts/bundle.sh.
    let icon: String
    /// The icon fills its square, so it is inset and rounded to sit beside the macOS-shaped ones.
    var fullBleed = false
    let kind: Kind
    let platform: String
    let pitch: String
    let detail: String
    /// Shown once the repo has a release (`MoreAppReleases`): a command that fails is worse than none.
    let install: String
    /// `owner/name` on GitHub.
    let repo: String
    var site: URL?
    let dark: UInt32
    let light: UInt32

    var id: String { name }
    var repoURL: URL { URL(string: "https://github.com/\(repo)")! }
    @MainActor var hue: Color { Theme.hue(dark, light: light) }

    static let all: [MoreApp] = [
        MoreApp(name: "MacMax", icon: "macmax", kind: .menuBar, platform: "macOS",
                pitch: "Why is my Mac slow? One answer, from the menu bar.",
                detail: "Shows what is using your Mac, checks it on a schedule, and tells you what to close, what to clean and whether your VPN is really on.",
                install: "brew install --cask danieltamas/tap/macmax",
                repo: "danieltamas/macmax", dark: 0xFFB547, light: 0x9E6801),
        MoreApp(name: "RMJ", icon: "rmj", kind: .menuBar, platform: "macOS",
                pitch: "Run My Job: your builds and tests, on your boxes.",
                detail: "Sends the builds and test suites your agents start to the Linux boxes on your tailnet, and shows every run in one place.",
                install: "brew install --cask danieltamas/tap/rmj",
                repo: "danieltamas/runmyjob", dark: 0x5AA9FF, light: 0x1F6FD1),
        MoreApp(name: "Axon", icon: "axon", kind: .terminal, platform: "macOS and Linux",
                pitch: "Your coding agents, on one bus.",
                detail: "Lets Claude Code, Codex, OpenCode and Hermes see and talk to each other, and shows what each one does and costs. Bton's agents register on it.",
                install: "brew install danieltamas/tap/axon",
                repo: "danieltamas/axon", dark: 0x4ADE80, light: 0x15803D),
        MoreApp(name: "Run.dev", icon: "rundev", fullBleed: true, kind: .terminal, platform: "macOS and Linux",
                pitch: "Every local service, one dashboard.",
                detail: "One binary starts and watches the services of all your projects from a terminal dashboard, with no config files to babysit.",
                install: "curl -fsSL https://getrun.dev/install.sh | bash",
                repo: "danieltamas/run.dev", site: URL(string: "https://getrun.dev")!,
                dark: 0x45C8D4, light: 0x0A7C93),
        MoreApp(name: "Cloak", icon: "cloak", fullBleed: true, kind: .terminal, platform: "CLI and VS Code",
                pitch: "Keep .env secrets away from AI agents.",
                detail: "Agents see sandbox values, you see the real ones, and your app still runs with real credentials. Encrypted vault, Touch ID.",
                install: "curl -fsSL https://getcloak.dev/install.sh | sh",
                repo: "danieltamas/cloak", site: URL(string: "https://getcloak.dev")!,
                dark: 0x5B9BFF, light: 0x2457C5),
    ]
}

struct MorePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .more, title: "More apps",
                       detail: "Other open source tools from the maker of Bton, for a Mac that runs coding agents. All MIT, all free.")
            group("In the menu bar", .menuBar)
            group("In the terminal", .terminal)
        }
        .onAppear { MoreAppReleases.shared.refresh() }
    }

    private func group(_ title: String, _ kind: MoreApp.Kind) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow(text: title).padding(.leading, 4)
            ForEach(MoreApp.all.filter { $0.kind == kind }) { MoreAppCard(app: $0) }
        }
    }
}

/// Which of the apps have a release, asked of GitHub when the pane opens and kept across launches:
/// a label built into this Bton would say "In development" long after the app shipped.
@MainActor @Observable
final class MoreAppReleases {
    static let shared = MoreAppReleases()
    private static let key = "MoreAppReleases"

    /// By `MoreApp.repo`; an app not in it has not been answered yet.
    private(set) var states: [String: ReleaseLookup.State]
    private var lastAttempt: Date?

    init() {
        states = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: ReleaseLookup.State].self, from: $0) } ?? [:]
    }

    /// Asks once per opening, at most every 15 minutes; a failed ask keeps the last answer.
    func refresh(now: Date = .now) {
        if let lastAttempt, now >= lastAttempt, now.timeIntervalSince(lastAttempt) < ReleaseCheck.interval { return }
        lastAttempt = now
        for app in MoreApp.all {
            Task {
                guard let state = try? await ReleaseLookup.latest(of: app.repo) else { return }
                states[app.repo] = state
                UserDefaults.standard.set(try? JSONEncoder().encode(states), forKey: Self.key)
            }
        }
    }
}

private struct MoreAppCard: View {
    let app: MoreApp
    private var state: ReleaseLookup.State? { MoreAppReleases.shared.states[app.repo] }

    var body: some View {
        Bezel(glow: app.hue) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    MoreAppIcon(app: app, size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(app.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                            Chip(text: app.platform, color: app.hue)
                            switch state {
                            case let .released(tag): Chip(text: tag, color: app.hue, style: .outline)
                            case .none?: Chip(text: "In development", color: Theme.textTertiary, style: .dashed)
                            case nil: EmptyView()
                            }
                            Spacer(minLength: 8)
                            if let site = app.site { LinkChip(title: "Website", url: site) }
                            LinkChip(title: "GitHub", url: app.repoURL)
                        }
                        Text(app.pitch).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        Text(app.detail).font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // Full width, so a curl line reads whole instead of cut in the middle. Shown until
                // GitHub says there is no release: a published app is the common case.
                if state != ReleaseLookup.State.none {
                    InstallLine(command: app.install)
                } else {
                    Text("No release yet: watch the repository for the first one.").font(.meta).foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 66)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A small outlined link that opens in the browser; the arrow says it leaves the app.
private struct LinkChip: View {
    let title: String
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Chip(text: title, symbol: "arrow.up.right", color: hovering ? Theme.textPrimary : Theme.textSecondary, style: .outline)
                .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { hovering in withAnimation(Motion.snappy) { self.hovering = hovering } }
        .help(url.absoluteString)
    }
}

/// The install command in a well, with a copy button that answers the press.
private struct InstallLine: View {
    let command: String

    var body: some View {
        HStack(spacing: 6) {
            Text("$").font(.system(size: 11.5, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.textTertiary)
            Text(command).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 6)
            CopyButton(text: command, help: "Copy the install command")
        }
        .padding(.leading, 10).padding(.trailing, 3).padding(.vertical, 3)
        .background(Theme.wash.opacity(0.05), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// The app's own icon from the bundle, or a glyph in its hue when the bundle has none (`swift run`).
private struct MoreAppIcon: View {
    let app: MoreApp
    let size: CGFloat

    /// Read once per icon: the lookup reads the disk and must not run on every redraw.
    @MainActor private static var cache: [String: NSImage?] = [:]

    var body: some View {
        if let image = Self.image(app.icon) {
            let inset = app.fullBleed ? size * 0.1 : 0
            let corner = (size - inset * 2) * 0.225
            Image(nsImage: image).resizable().interpolation(.high)
                .clipShape(RoundedRectangle(cornerRadius: app.fullBleed ? corner : 0, style: .continuous))
                .padding(inset)
                .frame(width: size, height: size)
                .shadow(color: app.hue.opacity(0.35), radius: 10, y: 4)
        } else {
            GlyphDisc(symbol: app.kind == .menuBar ? "menubar.rectangle" : "terminal", color: app.hue, size: size)
        }
    }

    @MainActor private static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        let image = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "MoreApps").flatMap(NSImage.init(contentsOf:))
        cache[name] = .some(image)
        return image
    }
}
