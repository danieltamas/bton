import Foundation

/// Everything Bton keeps on this Mac: config, `locks/`, `jobs/`, cost offsets. `BTON_HOME`
/// moves it, so a second instance shares nothing local with the first.
public struct BtonHome: Sendable {
    public let url: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        if let path = environment["BTON_HOME"], !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            url = homeDirectory.appendingPathComponent(".bton", isDirectory: true)
        }
    }

    public var configURL: URL { url.appendingPathComponent("config.json") }

    /// Mode 0700, also on a directory that already exists: job logs and leases are this user's alone.
    public func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: url, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
