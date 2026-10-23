import AppKit
import BtonCore
import SwiftUI

/// Who made Bton and why, its repo, this build, and whether a newer release is out.
struct AboutPane: View {
    @State private var standing: Standing = .checking
    private let updater = Updater.shared

    private enum Standing: Equatable {
        case checking, known(BtonRelease.Standing), failed(String)
    }

    private static let build: BtonRelease.Build = {
        let info = Bundle.main.infoDictionary
        return BtonRelease.build(version: info?["CFBundleShortVersionString"] as? String ?? "0.0.0",
                                 source: info?["BtonSource"] as? String)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .about, title: "About Bton", detail: "Who makes it, where it lives, and which build this is.")
            Bezel {
                HStack(alignment: .center, spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Bton").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(Self.versionLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                        standingLine
                        if let problem = updater.problem {
                            label("Update failed: \(problem)", color: Theme.danger, symbol: "exclamationmark.triangle")
                        }
                    }
                    Spacer()
                    if case let .known(known) = standing, BtonRelease.canUpdate(bundlePath: Bundle.main.bundlePath, standing: known),
                       case let .behind(latest) = known {
                        PillButton(title: updater.installing == nil ? "Update to \(latest)" : "Updating...", symbol: "arrow.down.circle",
                                   disabled: updater.installing != nil) { updater.install(latest) }
                            .help("Installs \(latest) the way install.sh does, then Bton restarts. Running agents keep going.")
                    }
                    PillButton(title: "Check again", symbol: "arrow.clockwise", prominent: false,
                               disabled: standing == .checking || updater.installing != nil) { Task { await check() } }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            SettingsCard(title: "Why it exists", detail: nil) {
                Text("""
                    A small team's pull requests should never sit waiting for whoever is next. Bton shows every PR's \
                    next move and whose it is, and runs it on the Mac whose move it is, with the coding agents its \
                    owner already trusts. No server, no stored token: each teammate's own gh login, and a lease on \
                    GitHub so one Mac takes each move.
                    """)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard(title: "Made by Daniel Tamas", detail: "Open source under the MIT license.") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        link("Repository", BtonRelease.url)
                        link("Report an issue", BtonRelease.url.appendingPathComponent("issues"))
                    }
                    HStack(spacing: 8) {
                        link("danieltamas.com", URL(string: "https://danieltamas.com")!)
                        link("Daniel on GitHub", URL(string: "https://github.com/danieltamas")!)
                    }
                }
            }
        }
        .task { await check() }
    }

    private static var versionLine: String {
        let build = Self.build
        var line = "v\(build.version)"
        if build.commitsAfter > 0 { line += " + \(build.commitsAfter) commit\(build.commitsAfter == 1 ? "" : "s")" }
        if let commit = build.commit { line += " (\(commit))" }
        if Bundle.main.infoDictionary?["BtonSource"] != nil { line += ", built from source" }
        if build.dirty { line += ", uncommitted changes" }
        return line
    }

    @ViewBuilder private var standingLine: some View {
        switch standing {
        case .checking:
            label("Checking GitHub for the latest release...", color: Theme.textTertiary, symbol: "arrow.triangle.2.circlepath")
        case .known(.latest):
            label("Latest release", color: Theme.success, symbol: "checkmark.seal")
        case let .known(.behind(latest)):
            HStack(spacing: 8) {
                label("\(latest) is out", color: Theme.unassigned, symbol: "arrow.down.circle")
                Button("See the release") { NSWorkspace.shared.open(BtonRelease.url.appendingPathComponent("releases/tag/\(latest)")) }
                    .buttonStyle(.link).font(.meta)
            }
        case .known(.ahead):
            label("Newer than the latest release", color: Theme.mint, symbol: "arrow.up.circle")
        case .known(.unknown):
            label("This version cannot be compared with the latest release", color: Theme.textTertiary, symbol: "questionmark.circle")
        case let .failed(reason):
            label("Could not check: \(reason)", color: Theme.danger, symbol: "exclamationmark.triangle")
        }
    }

    private func label(_ text: String, color: Color, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.meta).foregroundStyle(color).lineLimit(2)
    }

    private func link(_ title: String, _ url: URL) -> some View {
        PillButton(title: title, symbol: "arrow.up.right", prominent: false) { NSWorkspace.shared.open(url) }
    }

    private func check() async {
        standing = .checking
        do {
            let latest = try await GitHubClient().latestReleaseTag()
            standing = .known(BtonRelease.standing(of: Self.build, latestTag: latest))
        } catch {
            standing = .failed(error.localizedDescription)
        }
    }
}
