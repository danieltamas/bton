import BtonCore
import SwiftUI

/// The one place a press starts a Task. The press holds `id` in the store's `inFlight` while
/// the action runs, so the button shows it and a second press meanwhile is nothing. Ids are
/// stable per target (`stop:<job>`, `take:<repo>#<n>`), so the same action offered twice shares
/// one state. A test refuses a `Task` in any other button closure (AsyncPressAcceptanceTests).
struct AsyncPress<Content: View>: View {
    @Environment(AppStore.self) private var store
    let id: String
    let action: () async -> Void
    @ViewBuilder let content: (_ running: Bool, _ press: @escaping () -> Void) -> Content

    var body: some View {
        content(store.inFlight.isRunning(id)) {
            Task { await store.inFlight.perform(id) { await action() } }
        }
    }
}

/// A PillButton whose press awaits: dimmed, renamed and unpressable until the action returns.
struct AsyncPillButton: View {
    let title: String
    var runningTitle: String?
    var symbol = "arrow.up.right"
    var prominent = true
    var disabled = false
    let id: String
    let action: () async -> Void

    var body: some View {
        AsyncPress(id: id, action: action) { running, press in
            PillButton(title: running ? runningTitle ?? title : title, symbol: symbol, prominent: prominent,
                       disabled: disabled || running, action: press)
        }
    }
}

/// An IconButton whose press awaits: dimmed and unpressable until the action returns.
struct AsyncIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = Theme.textSecondary
    var size: CGFloat = 26
    var disabled = false
    let id: String
    let action: () async -> Void

    var body: some View {
        AsyncPress(id: id, action: action) { running, press in
            IconButton(symbol: symbol, help: help, tint: tint, size: size, action: press)
                .disabled(disabled || running)
                .opacity(disabled || running ? 0.4 : 1)
        }
    }
}

/// A RunNowButton whose press awaits: dimmed, renamed and unpressable until the action returns.
struct AsyncRunNowButton: View {
    let title: String
    var runningTitle: String?
    let symbol: String
    let color: Color
    var help: String?
    var disabled = false
    let id: String
    let action: () async -> Void

    var body: some View {
        AsyncPress(id: id, action: action) { running, press in
            RunNowButton(title: running ? runningTitle ?? title : title, symbol: symbol, color: color, help: help,
                         disabled: disabled || running, action: press)
        }
    }
}
