import Foundation

/// A Claude Code session as a readable list: the prompt, what the agent said, each tool call in
/// one line and the start of each result. Read from the transcript Claude Code writes as it
/// works, so it shows a running job live; `-p` itself prints only at the end.
public enum SessionTranscript {
    public struct Entry: Identifiable, Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case prompt, text, thinking
            case tool(name: String)
            case result(isError: Bool)
        }

        public let id: Int
        public let kind: Kind
        public let text: String
    }

    /// The newest `limit` entries; an unreadable file has none.
    public static func entries(ofSessionFile url: URL, limit: Int = 400) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return entries(in: data, limit: limit)
    }

    static func entries(in data: Data, limit: Int) -> [Entry] {
        var made: [(Entry.Kind, String)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // A closed view cancels the read; what was parsed so far is thrown away.
            if Task.isCancelled { return [] }
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = object["type"] as? String, type == "user" || type == "assistant",
                  let message = object["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String {
                // The first plain user message is the prompt; later ones are hook or system notes.
                if type == "user", !made.contains(where: { $0.0 == .prompt }) { made.append((.prompt, text)) }
                continue
            }
            for block in message["content"] as? [[String: Any]] ?? [] {
                switch block["type"] as? String {
                case "text":
                    if let text = block["text"] as? String, !text.isEmpty { made.append((.text, text)) }
                case "thinking":
                    made.append((.thinking, ""))
                case "tool_use":
                    let name = block["name"] as? String ?? "tool"
                    made.append((.tool(name: name), summary(of: block["input"] as? [String: Any] ?? [:])))
                case "tool_result":
                    made.append((.result(isError: block["is_error"] as? Bool ?? false), resultText(block["content"])))
                default:
                    continue
                }
            }
        }
        return made.suffix(limit).enumerated().map { Entry(id: $0.offset, kind: $0.element.0, text: $0.element.1) }
    }

    /// The PR a session works on now: the number in its latest command that acts on one (`gh pr
    /// view 339`, `scripts/wt merge 339`, a fetch of `pull/339/head`). Only the file's last
    /// `tail` bytes are read, so a long session costs the same as a short one.
    public static func currentPullRequest(ofSessionFile url: URL, tail: Int = 512_000) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard (try? handle.seek(toOffset: size > UInt64(tail) ? size - UInt64(tail) : 0)) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return currentPullRequest(in: data)
    }

    static func currentPullRequest(in data: Data) -> Int? {
        // A cut-off first line fails to parse and is skipped like any other.
        for entry in entries(in: data, limit: .max).reversed() {
            // A shell command only: another tool's input can quote a PR's own text.
            if case .tool(name: "Bash") = entry.kind, let number = pullRequest(inCommand: entry.text) { return number }
        }
        return nil
    }

    static let pullRequestVerbs: Set = ["view", "diff", "checks", "comment", "edit", "review", "merge", "checkout",
                                        "ready", "close", "reopen"]

    /// The PR a shell command acts on, from `gh pr <verb> … <n>`, `wt merge <n>` or `pull/<n>/head`;
    /// a number given as a flag's value (`--limit 50`) is not one.
    static func pullRequest(inCommand command: String) -> Int? {
        if let match = command.firstMatch(of: /pull\/(\d+)\/head/) { return Int(match.1) }
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        for (index, word) in words.enumerated() {
            let acts = word == "gh" && words.dropFirst(index + 1).first == "pr"
                && words.dropFirst(index + 2).first.map(pullRequestVerbs.contains) == true
            let merges = word.hasSuffix("wt") && words.dropFirst(index + 1).first == "merge"
            guard acts || merges else { continue }
            var previous = ""
            for argument in words.dropFirst(index + (acts ? 3 : 2)) {
                if ["|", ";", "&&", "||"].contains(argument) { break }
                let digits = argument.hasPrefix("#") ? String(argument.dropFirst()) : argument
                if !digits.isEmpty, digits.allSatisfy({ ("0"..."9").contains($0) }), let number = Int(digits),
                   !previous.hasPrefix("-") {
                    return number
                }
                previous = argument
            }
        }
        return nil
    }

    /// The part of a tool's input a person scans for: the command, the file, the pattern.
    static func summary(of input: [String: Any]) -> String {
        for key in ["command", "file_path", "pattern", "url", "query", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return value }
        }
        return input.values.compactMap { $0 as? String }.first ?? ""
    }

    private static func resultText(_ content: Any?) -> String {
        if let text = content as? String { return text }
        let parts = (content as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return parts.joined(separator: "\n")
    }
}
