import Foundation

/// The engine's log lines in `~/.bton/bton.log`: what a read or a job did not do and why,
/// one line a message, with the time. The command-line tool prints the same lines instead.
public enum EngineLog {
    /// Bytes the file may reach before it is rotated to `bton.log.1`, replacing the previous one.
    public static let cap = 1_000_000

    public static func url(home: BtonHome) -> URL { home.url.appendingPathComponent("bton.log") }

    /// A sink for `Engine(home:log:)`. Writes never throw: a log that cannot be written is
    /// nothing, never a failure of what it was logging.
    public static func sink(home: BtonHome) -> @Sendable (String) -> Void {
        let url = url(home: home)
        let lock = NSLock()
        return { message in
            lock.withLock {
                let line = Data("\(Date.now.formatted(.iso8601)) \(message)\n".utf8)
                let files = FileManager.default
                try? files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                if size >= cap {
                    let previous = url.deletingLastPathComponent().appendingPathComponent("bton.log.1")
                    try? files.removeItem(at: previous)
                    try? files.moveItem(at: url, to: previous)
                }
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                } else {
                    try? line.write(to: url)
                }
            }
        }
    }
}
