import Foundation
import ServiceManagement

enum LoginItem {
    private static let registeredKey = "loginItemRegistered"

    /// Registers Bton to open at login, once: a teammate who turns it off in System Settings keeps
    /// it off. Only the installed app does this, never `swift run` or a build folder copy.
    static func registerOnce() {
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: registeredKey) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: registeredKey)
        } catch {
            // Retried at the next launch; the app works without it.
        }
    }
}
