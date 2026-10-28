import Foundation

/// Whether an agent asked the code graph, read from its own record of commands after the job:
/// the graph line only tells the agent to; the count in the job log shows whether it did.
public enum GraphUse {
    /// The commands that query the graph: `graphify-src` (also by path) and graphify's own
    /// readers. `graphify` alone is the builder, and reading `graphify-out/` by hand is not a query.
    public static func isQuery(_ command: String) -> Bool {
        command.range(of: #"(^|[^A-Za-z0-9_.-])graphify-src($|[^A-Za-z0-9_-])"#, options: .regularExpression) != nil
            || command.range(of: #"(^|[^A-Za-z0-9_.-])graphify\s+(explain|query|path|affected)($|[^A-Za-z0-9_-])"#, options: .regularExpression) != nil
    }

    /// The Bash calls of a Claude Code transcript that query the graph; nil for a file that
    /// cannot be read.
    public static func queries(inClaudeSessionFile url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SessionTranscript.entries(in: data, limit: .max).filter { entry in
            if case .tool(name: "Bash") = entry.kind { return isQuery(entry.text) }
            return false
        }.count
    }

    /// The command executions of the worktree's codex sessions in the window that query the
    /// graph, each `cmd:"..."` fragment of a script counted on its own; nil when the window has
    /// no session of the worktree.
    public static func queries(inCodexWorktree worktree: String, from start: Date, to end: Date,
                               sessionsRoot: URL = CodexSessions.sessionsRoot) -> Int? {
        CodexSessions.commands(inWorktree: worktree, from: start, to: end, sessionsRoot: sessionsRoot)?
            .reduce(0) { $0 + queries(inCall: $1) }
    }

    /// A script of several `cmd:"..."` fragments is several commands; a call without the
    /// fragments is one.
    static func queries(inCall text: String) -> Int {
        let fragment = try! NSRegularExpression(pattern: #"cmd:\s*"((?:[^"\\]|\\.)*)""#)
        let fragments = fragment.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text) }.map { String(text[$0]) }
        return fragments.isEmpty ? (isQuery(text) ? 1 : 0) : fragments.filter(isQuery).count
    }
}
