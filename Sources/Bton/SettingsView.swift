import AppKit
import BtonCore
import ServiceManagement
import SwiftUI

/// Bton's settings window: everything `config.json` and `prices.json` hold, edited in place and
/// saved as it changes. The engine reads the config every sync, so a change applies at the next one.
struct SettingsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 0) {
            sidebar(selection: $store.settingsPane)
            Rectangle().fill(Theme.hairline).frame(width: 0.5)
            ScrollView {
                pane.padding(28).frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .id(store.settingsPane)
            .transition(.opacity)
        }
        .frame(minWidth: 760, minHeight: 540)
        .background(Backdrop())
        .preferredColorScheme(.dark)
        .animation(Motion.spring, value: store.settingsPane)
    }

    @ViewBuilder private var pane: some View {
        switch store.settingsPane {
        case .general: GeneralPane()
        case .repos: ReposPane()
        case .agents: AgentsPane()
        case .schedules: SchedulesPane()
        case .supervisor: SupervisorPane()
        case .prices: PricesPane()
        case .about: AboutPane()
        }
    }

    private func sidebar(selection: Binding<SettingsPane>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Eyebrow(text: "Settings").padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(SettingsPane.allCases) { pane in
                let selected = selection.wrappedValue == pane
                Button {
                    withAnimation(Motion.spring) { selection.wrappedValue = pane }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: pane.symbol)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(selected ? pane.color : Theme.textTertiary)
                            .frame(width: 24, height: 24)
                            .background(pane.color.opacity(selected ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(pane.rawValue).font(.system(size: 12.5, weight: selected ? .semibold : .medium))
                            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.core)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle(scale: 0.98))
            }
            Spacer()
            AppControls().padding(.horizontal, 10)
        }
        .padding(.horizontal, 12)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 196)
        .background(Theme.canvas.opacity(0.55))
    }
}

extension SettingsPane {
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .repos: "folder"
        case .agents: "cpu"
        case .schedules: "clock.arrow.circlepath"
        case .supervisor: Theme.symbol(forMove: Supervision.move)
        case .prices: "dollarsign.circle"
        case .about: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .general: Theme.mint
        case .repos: Color(hex: 0x7AA2FF)
        case .agents: Color(hex: 0xC792FF)
        case .schedules: Theme.color(forMove: "schedule")
        case .supervisor: Theme.color(forMove: Supervision.move)
        case .prices: Color(hex: 0xFFB547)
        case .about: Theme.neutral
        }
    }
}

private struct GeneralPane: View {
    @Environment(AppStore.self) private var store
    @State private var problem: String?
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled

    private static let intervals = [15, 30, 60, 120, 300, 600]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .general, title: "General", detail: "How often Bton looks at GitHub and how much it runs at once.")
            SettingsCard(title: "GitHub sync", detail: "Each sync reads every repo, starts the moves that are yours, and runs due schedules.") {
                HStack(spacing: 6) {
                    ForEach(Self.intervals, id: \.self) { seconds in
                        SegmentChip(title: Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)),
                                    selected: store.pollSeconds == seconds) { save { try store.setPollSeconds(seconds) } }
                    }
                }
            }
            SettingsCard(title: "Agents at once", detail: "Running jobs on this Mac never exceed this. 0 pauses every start; running jobs go on.") {
                HStack(spacing: 14) {
                    IconButton(symbol: "minus", help: "Fewer") { save { try store.setMaxAgents(store.maxAgents - 1) } }
                    Text("\(store.maxAgents)").font(.statValue).foregroundStyle(Theme.textPrimary).monospacedDigit()
                        .contentTransition(.numericText()).frame(minWidth: 34)
                    IconButton(symbol: "plus", help: "More") { save { try store.setMaxAgents(store.maxAgents + 1) } }
                }
            }
            SettingsCard(title: "Open at login", detail: "Bton only dispatches while it runs.") {
                Toggle("Open Bton when you log in", isOn: Binding(get: { opensAtLogin }, set: { setOpensAtLogin($0) }))
                    .toggleStyle(.switch).tint(Theme.mint)
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            SettingsCard(title: "Data folder", detail: "Config, job logs and leases on this Mac.") {
                HStack {
                    Text(store.home.url.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    PillButton(title: "Show in Finder", symbol: "arrow.up.right", prominent: false) {
                        NSWorkspace.shared.activateFileViewerSelecting([store.home.url])
                    }
                }
            }
            if let problem { ProblemText(text: problem) }
        }
    }

    private func save(_ change: () throws -> Void) {
        do {
            try withAnimation(Motion.spring) { try change() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            problem = nil
        } catch {
            problem = "macOS refused: \(error.localizedDescription) Bton must run from /Applications."
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
