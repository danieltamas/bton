import AppKit
import SwiftUI

@main
struct BtonApp: App {
    @State private var store: AppStore

    /// The loop starts with the app, not with the menu: the window's content only exists while
    /// it is open, and Bton dispatches whether anyone looks or not.
    init() {
        let store = AppStore()
        store.start()
        LoginItem.registerOnce()
        _store = State(initialValue: store)
    }

    var body: some Scene {
        MenuBarExtra {
            RootView()
                .environment(store)
        } label: {
            // How many moves wait for me as a person (decide, finish, an unassigned review of mine).
            let waiting = store.humanMovesForMe.count
            HStack(spacing: 2) {
                Image(nsImage: store.icon.image)
                if waiting > 0 { Text("\(waiting)") }
            }
        }
        .menuBarExtraStyle(.window)

        // A Settings scene, not a Window: it never opens by itself at launch, and gets ⌘, for free.
        Settings {
            SettingsView()
                .environment(store)
        }
    }
}

extension NSImage {
    /// The bundled template icon; `swift run` has no bundle, so it falls back to an SF Symbol.
    static var btonTemplate: NSImage {
        if let url = Bundle.main.url(forResource: "MenubarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "arrow.up.right.circle", accessibilityDescription: "Bton")!
    }
}
