import Foundation

/// A Codex job's log read as a session, in the entries a Claude transcript gives: Codex writes
/// no session file Bton can follow, only its stream on stderr, which Bton keeps as the job's
/// log. The stream is blocks under one-word markers: `user` (the prompt), `codex` (what it
/// says, Markdown), `thinking`, `exec` (a command, its exit line and its output) and
/// `tokens used`. Lines before the first marker are Bton's own and Codex's banner.
public enum CodexTranscript {
    static let banner = "OpenAI Codex"
    /// A result keeps this much: the rows show three lines collapsed and forty open.
    static let resultLimit = 6_000

    /// The newest `limit` entries; a log without Codex's banner before its first marker, or one
    /// that cannot be read, has none, so another agent's log is not mistaken for a session.
    public static func entries(ofLog url: URL, limit: Int = 400) -> [SessionTranscript.Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return entries(in: data, limit: limit)
    }

    static func entries(in data: Data, limit: Int) -> [SessionTranscript.Entry] {
        let text = String(decoding: data, as: UTF8.self)
        var made: [(SessionTranscript.Entry.Kind, String)] = []
        var marker: String?
        var block: [Substring] = []
        var sawBanner = false

        func close() {
            defer { block = [] }
            guard let marker else { return }
            switch marker {
            case "user":
                let prompt = joined(block)
                if !prompt.isEmpty, !made.contains(where: { $0.0 == .prompt }) { made.append((.prompt, prompt)) }
            case "codex":
                let said = joined(block)
                if !said.isEmpty { made.append((.text, said)) }
            case "thinking":
                made.append((.thinking, ""))
            case "exec":
                guard let first = block.first else { return }
                made.append((.tool(name: "exec"), command(in: first)))
                // The exit line follows the command; anything after it is the output.
                let status = block.dropFirst().first.map(String.init) ?? ""
                let isExit = status.hasPrefix(" exited ") || status.hasPrefix(" succeeded ")
                let output = joined(block.dropFirst(isExit ? 2 : 1))
                made.append((.result(isError: status.hasPrefix(" exited ")), String(output.prefix(resultLimit))))
            default:
                return
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if Task.isCancelled { return [] }
            if marker == nil {
                if line.hasPrefix(banner) { sawBanner = true }
                guard Self.isMarker(line) else { continue }
                // A marker before the banner: not Codex's stream, whatever follows.
                guard sawBanner else { return [] }
            }
            if Self.isMarker(line) {
                close()
                marker = String(line)
                continue
            }
            // Codex's own tracing (a model list that timed out) is noise between the blocks.
            if Self.isTrace(line) { continue }
            block.append(line)
        }
        close()
        return made.suffix(limit).enumerated().map { .init(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    static let markers: Set<Substring> = ["user", "codex", "thinking", "exec", "tokens used"]

    static func isMarker(_ line: Substring) -> Bool { markers.contains(line) }

    /// `2026-10-30T13:10:39.439320Z ERROR codex_core::...`: a timestamp, a level, a module.
    static func isTrace(_ line: Substring) -> Bool {
        guard line.hasPrefix("20"), let space = line.firstIndex(of: " "), line[..<space].hasSuffix("Z") else { return false }
        let rest = line[line.index(after: space)...]
        return ["ERROR ", "WARN ", "INFO ", "DEBUG "].contains { rest.hasPrefix($0) }
    }

    /// `/bin/zsh -lc 'git status' in /path/to/worktree` reads as `git status`.
    static func command(in line: Substring) -> String {
        var text = String(line)
        if let range = text.range(of: " in /", options: .backwards) { text = String(text[..<range.lowerBound]) }
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "/bin/sh -lc ", "/bin/zsh -c ", "/bin/bash -c "] where text.hasPrefix(shell) {
            text = String(text.dropFirst(shell.count))
        }
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") { text = String(text.dropFirst().dropLast()) }
        return text
    }

    static func joined(_ lines: some Sequence<Substring>) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
