import Darwin
import Foundation

/// Copy only the initial repositories. Every test still mutates and exercises its own real Git
/// repositories; no worktree, hook, lease, or result is shared between test cases.
enum GitFixtureCopies {
    static let templates: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bton-git-templates-\(UUID())").resolvingSymlinksInPath()
        atexit { try? FileManager.default.removeItem(at: GitFixtureCopies.templates) }
        return directory
    }()

    static func copy(_ source: URL, template: Bool = false) throws -> URL {
        let destination = (template ? templates : FileManager.default.temporaryDirectory)
            .appendingPathComponent("bton-git-copy-\(UUID())").resolvingSymlinksInPath()
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            // Local remotes must point into this copy, never back into the immutable template.
            let files = FileManager.default.enumerator(at: destination, includingPropertiesForKeys: nil)!
            for case let file as URL in files where file.lastPathComponent == "config" {
                let text = try String(contentsOf: file, encoding: .utf8)
                try text.replacingOccurrences(of: source.path, with: destination.path)
                    .write(to: file, atomically: true, encoding: .utf8)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
