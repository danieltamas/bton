import AppKit
import BtonCore

/// A Mac app from Settings > More apps that Launch Services knows on this Mac.
struct InstalledCopy: Equatable {
    let url: URL
    /// Nil when there is no release version to compare: shown as installed, compared with nothing.
    let version: String?
    /// The `git describe` a build from a checkout stamps (MacMaxSource, RMJSource).
    var source: String?

    init(url: URL, info: NSDictionary?, sourceKey: String?) {
        self.url = url
        source = sourceKey.flatMap { info?[$0] as? String }
        version = InstalledVersion.comparable(shortVersion: info?["CFBundleShortVersionString"] as? String, sourceStamp: source)
    }

    init(url: URL, version: String?, source: String? = nil) {
        self.url = url
        self.version = version
        self.source = source
    }
}

/// Settings > More apps' live part. The list comes from the owner's registry: the bundled copy first, then the
/// last one read into `~/.bton/registry`, then a fresh read when the pane opens (at most hourly) or on the
/// refresh button. A read that fails or is refused changes nothing on the cards; the header says why.
@MainActor @Observable
final class MoreApps {
    static let shared = MoreApps()

    private(set) var registry: AppRegistry?
    /// The time of the list shown: nil for the bundled copy, which has the registry's `updated` instead.
    private(set) var readAt: Date?
    /// By app id, so an app whose icon path changed keeps its last icon until the new one is fetched.
    private(set) var icons: [String: NSImage] = [:]
    /// By bundle id.
    private(set) var installed: [String: InstalledCopy] = [:]
    private(set) var problem: String?
    private(set) var checking = false

    private var store: RegistryStore?

    /// The newest list that still validates: the stored read, else the bundle's copy. Once per launch.
    func open(home: BtonHome) {
        guard store == nil else { return }
        let store = RegistryStore(directory: home.url.appendingPathComponent("registry", isDirectory: true))
        self.store = store
        if let stored = store.load(), case let .accepted(registry) = RegistryDecoder.read(stored.data) {
            show(registry, readAt: stored.readAt)
        } else if let registry = Self.bundled() {
            show(registry, readAt: nil)
        } else {
            problem = "This copy of Bton has no app list. Refresh to read it."
        }
    }

    static func bundled() -> AppRegistry? {
        guard let url = Bundle.main.url(forResource: "apps", withExtension: "json", subdirectory: "Registry"),
              let data = try? Data(contentsOf: url), case let .accepted(registry) = RegistryDecoder.read(data) else { return nil }
        return registry
    }

    /// The bundle's icon for a registry path, for an app whose icon was never fetched (or failed to).
    static func bundledIcon(_ path: String) -> NSImage? {
        guard AppRegistry.iconURL(path) != nil else { return nil }
        let url = Bundle.main.resourceURL?.appendingPathComponent("Registry").appendingPathComponent(path)
        return url.flatMap(NSImage.init(contentsOf:))
    }

    private func show(_ registry: AppRegistry, readAt: Date?) {
        self.registry = registry
        self.readAt = readAt
        for app in registry.apps {
            if let image = store?.icon(path: app.icon).flatMap(NSImage.init(data:)) ?? Self.bundledIcon(app.icon) {
                icons[app.id] = image
            }
        }
    }

    func refresh(byPress: Bool) {
        readInstalled()
        guard !checking, RegistryRefresh.isDue(lastRead: readAt, now: Date(), byPress: byPress) else { return }
        checking = true
        Task {
            await read(userAgent: "Bton/\(ReleaseWatch.build.version)")
            checking = false
        }
    }

    private func read(userAgent: String) async {
        let answer = await RegistryDownload.get(AppRegistry.fileURL, userAgent: userAgent, maxBytes: RegistryDecoder.maxBytes)
        guard case let .data(data) = answer else {
            if case let .failed(reason) = answer { problem = "The app list could not be refreshed: \(reason)" }
            return
        }
        switch RegistryDecoder.read(data) {
        case let .accepted(registry):
            let now = Date()
            do {
                try store?.save(data, readAt: now)
                problem = nil
            } catch {
                problem = "The app list was read but could not be saved, so the next launch reads it again."
            }
            show(registry, readAt: now)
            // An app new to the list may already be on this Mac: the scan before the read only knew the old list.
            readInstalled()
            await fetchIcons(registry.apps, userAgent: userAgent)
        case .newerSchema:
            problem = "This version of Bton can't read the newer app list. Update Bton to see it."
        case let .refused(reason):
            problem = "The app list could not be used: \(reason)"
        }
    }

    /// Icons the store does not hold yet. A changed icon always has a new path, so a stored one is never read
    /// again; a failed one keeps the icon shown so far (the previous path's, the bundle's) or the fallback glyph.
    private func fetchIcons(_ apps: [RegistryApp], userAgent: String) async {
        guard let store else { return }
        for app in apps where store.icon(path: app.icon) == nil {
            guard let url = AppRegistry.iconURL(app.icon),
                  case let .data(data) = await RegistryDownload.get(url, userAgent: userAgent, maxBytes: RegistryIcon.maxBytes),
                  RegistryIcon.accepts(data), let image = NSImage(data: data) else { continue }
            try? store.saveIcon(data, path: app.icon)
            icons[app.id] = image
        }
    }

    private func readInstalled() {
        var found: [String: InstalledCopy] = [:]
        for app in registry?.apps ?? [] {
            guard let mac = app.mac, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mac.bundleID) else { continue }
            // Read from disk each time: Bundle caches its Info.plist, so an update made while Bton runs would not show.
            let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
            found[mac.bundleID] = InstalledCopy(url: url, info: info, sourceKey: mac.sourceKey)
        }
        installed = found
    }
}
