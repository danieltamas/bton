import CryptoKit
import Foundation

/// A dependency cache a team opts into with `checks.cache`: directories a PR's checks build
/// (`node_modules`) kept under a key made of the lockfiles' bytes, so a new PR's first run starts
/// from the last install with the same lockfile. Copies are clones on APFS. Nothing here fails a
/// job: a copy that fails is noted and the checks run as they would without a cache. Bton evicts
/// nothing; the directory is the owner's to clear.
///
/// The worktree is the PR's: a key file or a cached path's parent that the PR turned into a
/// symlink must not make Bton read or write outside it, so every path is checked resolved before
/// the first byte, and a key file is read only as a regular file of bounded size.
extension CheckCache {
    /// A lockfile is kilobytes; a key file past this is read as missing.
    static let keyFileLimit = 64 << 20

    public static func root(home: BtonHome, repo: String) -> URL {
        home.url.appendingPathComponent("cache", isDirectory: true).appendingPathComponent(repo.lowercased(), isDirectory: true)
    }

    /// sha256 over the key files' bytes as they are in the worktree, in order; a file that is
    /// missing, not a regular file or over the limit contributes its name only, so its absence is a
    /// key of its own. First 16 hex characters.
    public static func key(for cache: CheckCache, in worktree: URL) -> String {
        var digest = SHA256()
        for name in cache.key {
            let file = worktree.appendingPathComponent(name)
            if contained(file, in: worktree), isRegularFile(file, limit: keyFileLimit),
               let data = try? Data(contentsOf: file) {
                digest.update(data: data)
            } else {
                digest.update(data: Data(name.utf8))
            }
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    /// Each cached path the worktree lacks is copied in, its parent made when absent.
    public static func restore(_ cache: CheckCache, key: String, into worktree: URL, home: BtonHome, repo: String,
                               note: @Sendable (String) -> Void) async {
        let cached = root(home: home, repo: repo).appendingPathComponent(key, isDirectory: true)
        for path in cache.paths {
            let source = cached.appendingPathComponent(path), target = worktree.appendingPathComponent(path)
            guard exists(source), !exists(target), contained(target, in: worktree) else { continue }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                guard contained(target, in: worktree) else { continue }
                try await copy(source, to: target)
                note("cache: restored \(path) for key \(key)")
            } catch { note("cache: could not restore \(path): \(error.localizedDescription)") }
        }
    }

    /// Each path the worktree has and the cache lacks is copied out. Called only after every
    /// check passed: a failed run saves nothing.
    public static func save(_ cache: CheckCache, key: String, from worktree: URL, home: BtonHome, repo: String,
                            note: @Sendable (String) -> Void) async {
        let cached = root(home: home, repo: repo).appendingPathComponent(key, isDirectory: true)
        for path in cache.paths {
            let source = worktree.appendingPathComponent(path), target = cached.appendingPathComponent(path)
            guard exists(source), !exists(target), contained(source, in: worktree), isDirectory(source) else { continue }
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try await copy(source, to: target)
                note("cache: saved \(path) for key \(key)")
            } catch { note("cache: could not save \(path): \(error.localizedDescription)") }
        }
    }

    /// Whether `url` is not a symlink itself and its parent, symlinks resolved, is inside the
    /// resolved worktree: a PR that points `build` elsewhere gets nothing written there.
    static func contained(_ url: URL, in worktree: URL) -> Bool {
        let root = worktree.resolvingSymlinksInPath().standardizedFileURL.path
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard parent == root || parent.hasPrefix(root + "/") else { return false }
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil
    }

    /// `attributesOfItem` does not follow a symlink, so a lockfile replaced by a link is not regular.
    static func isRegularFile(_ url: URL, limit: Int) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int else { return false }
        return size <= limit
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    private static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Into a temporary sibling first, moved into place when whole: a copy stopped half-way (a time
    /// limit, a cancelled job) leaves nothing a later job would trust. `cp -Rc` clones on APFS;
    /// where cloning is refused (another volume), a plain copy.
    private static func copy(_ source: URL, to target: URL) async throws {
        let staging = target.deletingLastPathComponent().appendingPathComponent(".bton-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let runner = ProcessRunner()
        var result = try await runner.run("/bin/cp", ["-Rc", source.path, staging.path], timeout: .seconds(600))
        if result.status != 0 {
            try? FileManager.default.removeItem(at: staging)
            result = try await runner.run("/bin/cp", ["-R", source.path, staging.path], timeout: .seconds(600))
        }
        guard result.status == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "cp exited \(result.status): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
        try FileManager.default.moveItem(at: staging, to: target)
    }
}
