import Foundation

/// The team's agent instructions, from the branch PRs merge into: its `CLAUDE.md`, each `@path`
/// import inlined from the same tree. The PR checkout's own copies never load
/// (`--setting-sources user`), so a branch cannot rewrite what its agent is told; this puts
/// the reviewed version back.
public enum TeamInstructions {
    /// Claude Code follows imports five deep; past that a token stays as written.
    static let maxDepth = 5
    /// The text rides in one argv element, which macOS caps with the environment at 1 MB.
    static let maxBytes = 200_000

    /// `read` returns the file at a repository path on the base branch, or nil when it is absent.
    static func expand(_ path: String = "CLAUDE.md", read: (String) async throws -> String?) async throws -> String? {
        var stack: [String] = []
        guard let text = try await file(path, depth: 0, stack: &stack, read: read) else { return nil }
        guard text.utf8.count <= maxBytes else {
            throw DispatchError.worktree("the team instructions are over \(maxBytes / 1000) KB")
        }
        return text
    }

    private static func file(_ path: String, depth: Int, stack: inout [String],
                             read: (String) async throws -> String?) async throws -> String? {
        guard depth <= maxDepth, !stack.contains(path), let text = try await read(path) else { return nil }
        stack.append(path)
        defer { stack.removeLast() }
        var lines: [String] = []
        var fenced = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { fenced.toggle() }
            lines.append(fenced ? line : try await inline(line, from: path, depth: depth, stack: &stack, read: read))
        }
        return lines.joined(separator: "\n")
    }

    /// Each `@path` that starts a word and names a file in the tree becomes that file's text.
    private static func inline(_ line: String, from path: String, depth: Int, stack: inout [String],
                               read: (String) async throws -> String?) async throws -> String {
        var result = ""
        var rest = Substring(line)
        while let match = rest.firstMatch(of: /@([A-Za-z0-9_.\/-]+)/) {
            result += rest[..<match.range.lowerBound]
            // An `@` inside a word (an email address, a handle in a sentence) is no import.
            let startsWord = match.range.lowerBound == line.startIndex
                || line[line.index(before: match.range.lowerBound)].isWhitespace
            var imported: String?
            if startsWord, let target = resolve(String(match.output.1), from: path) {
                imported = try await file(target, depth: depth + 1, stack: &stack, read: read)
            }
            result += imported ?? String(match.output.0)
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    /// The import's path in the repository, relative to the importing file; nil for one that
    /// leaves the tree (`..` past the root, an absolute or home path).
    static func resolve(_ target: String, from importer: String) -> String? {
        guard !target.hasPrefix("/") else { return nil }
        var parts = importer.split(separator: "/").dropLast().map(String.init)
        for part in target.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": guard parts.popLast() != nil else { return nil }
            default: parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// From the clone's `origin/<base>` as the worktree step just fetched it.
    static func read(clone: URL, base: String, runner: ProcessRunner) async throws -> String? {
        guard WatchedRepo.isBranchName(base) else { throw DispatchError.worktree("invalid base branch \(base)") }
        let instructions = try await expand { path in
            let result = try await runner.run("/usr/bin/git", ["-C", clone.path, "show", "refs/remotes/origin/\(base):\(path)"],
                                              environment: ["GIT_TERMINAL_PROMPT": "0"], timeout: .seconds(30))
            if result.status == 0 { return String(decoding: result.stdout, as: UTF8.self) }
            // A path the branch does not have is no import; anything else is a failure.
            if result.stderr.contains("does not exist") || result.stderr.contains("exists on disk, but not in") { return nil }
            throw DispatchError.worktree("git show \(path) exited \(result.status): \(result.stderr.prefix(200))")
        }
        return instructions.map { "Team instructions: CLAUDE.md on \(base), the reviewed branch.\n\n" + $0 }
    }
}
