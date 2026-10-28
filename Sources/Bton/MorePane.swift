import AppKit
import SwiftUI

/// The other tools from the same workbench, each with its mark, one line on what it does, its repo
/// and the install line. Bton runs the agents; these are what they run with and on.
struct MorePane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .more, title: "More from the same workbench",
                       detail: "Tools for a Mac that runs coding agents, from the same maker. Open source, each on its own.")
            ForEach(Product.all) { product in ProductCard(product: product) }
        }
    }
}

/// One of the tools: what it is and where it lives.
private struct Product: Identifiable {
    let id: String
    let name: String
    let tagline: String
    let detail: String
    let repo: URL
    let install: String

    static let all: [Product] = [
        Product(id: "Axon", name: "Axon",
                tagline: "The coordination bus for the coding agents on your machine, and on your teammate's.",
                detail: "Claude Code, Codex, OpenCode and Hermes see and talk to each other, and you see what every one of them is doing and what it costs. Bton's agents register on it.",
                repo: URL(string: "https://github.com/danieltamas/axon")!,
                install: "brew install danieltamas/tap/axon"),
        Product(id: "RMJ", name: "RMJ",
                tagline: "Run My Job. Your builds and tests, on your boxes, watched from the menu bar.",
                detail: "Routes the builds, test suites and CI jobs your agents start to the Linux boxes on your tailnet, and shows every run in one place: what runs, how long it took, what failed, where the log is.",
                repo: URL(string: "https://github.com/danieltamas/runmyjob")!,
                install: "brew install --cask danieltamas/tap/rmj"),
        Product(id: "Cloak", name: "Cloak",
                tagline: "Protect .env secrets from AI coding agents.",
                detail: "The real credentials live encrypted in a vault behind the OS keychain and Touch ID; the .env on disk holds structurally valid sandbox values. Agents see fakes, your editor and your app see the real ones.",
                repo: URL(string: "https://github.com/danieltamas/cloak")!,
                install: "curl -fsSL https://getcloak.dev/install.sh | sh"),
        Product(id: "RunDev", name: "run.dev",
                tagline: "AI-native local dev environment. One dashboard, all your services.",
                detail: "One Rust binary runs every project and service from a TUI: automatic .local domains with HTTPS, an SNI reverse proxy, live CPU and memory per service, and Claude reads the stderr when something dies.",
                repo: URL(string: "https://github.com/danieltamas/run.dev")!,
                install: "curl -fsSL https://getrun.dev/install.sh | bash"),
        Product(id: "MacMax", name: "MacMax",
                tagline: "Why is my Mac slow? One answer, from the menu bar.",
                detail: "Shows what is using your Mac, checks it on a schedule, and tells you what to close, what to clean and whether your VPN is really on.",
                repo: URL(string: "https://github.com/danieltamas/macmax")!,
                install: "brew install --cask danieltamas/tap/macmax"),
    ]

    /// The bundled mark (`Support/Resources/Product<id>.pdf`); `swift run` has no bundle.
    var mark: NSImage? {
        guard let url = Bundle.main.url(forResource: "Product\(id)", withExtension: "pdf") else { return nil }
        return NSImage(contentsOf: url)
    }
}

private struct ProductCard: View {
    let product: Product
    @State private var copied = false
    /// The press's own reset: a second press replaces it, so the tick stays its full two seconds.
    @State private var reset: Task<Void, Never>?

    var body: some View {
        Bezel {
            HStack(alignment: .top, spacing: 16) {
                mark
                VStack(alignment: .leading, spacing: 8) {
                    Text(product.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(product.tagline).font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(product.detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    PillButton(title: "See on GitHub", symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(product.repo) }
                        .padding(.top, 4)
                    installLine
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var mark: some View {
        if let image = product.mark {
            Image(nsImage: image).resizable().scaledToFit().frame(width: 56, height: 56)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.canvas).frame(width: 56, height: 56)
                .overlay(Text(String(product.name.prefix(1))).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.textTertiary))
        }
    }

    /// The install command, copied with one press; the button says so for a moment.
    private var installLine: some View {
        HStack(spacing: 6) {
            Text(product.install).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: copied ? "Copied" : "Copy the install command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(product.install, forType: .string)
                withAnimation(Motion.gentle) { copied = true }
                reset?.cancel()
                reset = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.gentle) { copied = false }
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 4).padding(.vertical, 3)
        .background(Theme.canvas.opacity(0.6), in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}
