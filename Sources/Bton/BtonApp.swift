import AppKit
import SwiftUI

@main
struct BtonApp: App {
    @State private var store: AppStore

    /// The loop starts with the app, not with the menu: the window's content only exists while
    /// it is open, and Bton dispatches whether anyone looks or not.
    init() {
        if let index = CommandLine.arguments.firstIndex(of: DemoShots.flag), index + 1 < CommandLine.arguments.count {
            do { try DemoShots.render(to: URL(fileURLWithPath: CommandLine.arguments[index + 1])) } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
            exit(0)
        }
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
            // How many moves wait for me as a person (decide, finish, an unassigned review of mine),
            // and how many issues ask me something.
            let waiting = store.waitingOnMe
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
    /// Read once: the menu bar icon draws it on every frame.
    static let btonTemplate: NSImage = {
        if let url = Bundle.main.url(forResource: "MenubarIcon", withExtension: "pdf"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = true
            return image
        }
        return NSImage(systemSymbolName: "arrow.up.right.circle", accessibilityDescription: "Bton")!
    }()
}

extension NSApplication {
    /// Quits, then opens Bton again once this process is gone: opening it while it still runs
    /// would only bring the running copy forward.
    func relaunch() {
        // `swift run` has no bundle to open again, and quitting would leave nothing running.
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", FileManager.default.isExecutableFile(atPath: Bundle.main.executablePath ?? "")
        else { return NSSound.beep() }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while kill -0 \"$0\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\"",
                            String(ProcessInfo.processInfo.processIdentifier), bundle.path]
        guard (try? reopen.run()) != nil else { return NSSound.beep() }
        terminate(nil)
    }
}
