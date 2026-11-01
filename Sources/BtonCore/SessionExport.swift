import Foundation

/// A job's whole session as one Markdown file, to read or paste where the window cannot be: the
/// window shows the newest 400 entries, a result cut short and the log's last 8 KB, and none of
/// it selects as a whole. The file holds Bton's log first (what Bton did around the agent: the
/// worktree, the checks, the outcome), the prompt, every tool call with its full result, the
/// failed ones marked, and the agent's report last. Written when a job ends and on demand for
/// one still running, so a copy from the session page is the session so far.
public enum SessionExport {
    /// Where the agent's transcript is: Claude Code's session file for the job, or nil for an
    /// agent whose session is its log (Codex) or none.
    public typealias Transcript = @Sendable (Job) -> URL?

    public enum Failure: LocalizedError {
        case notWritten
        public var errorDescription: String? { "The session file could not be written; the output and log are still in ~/.bton/jobs." }
    }

    /// Writes the whole session, once, as the job ends and before its originals are trimmed; false
    /// when the file could not be written, so the caller keeps the originals whole. Only the job's
    /// end writes this file: a render asked for on demand goes to `snapshot`, in a file of its own,
    /// so one that finishes late can never put a trimmed read over the whole session.
    /// The read and the render run on their own task: a stopped job finishes inside a cancelled
    /// one, which hands the transcript parsers nothing, and an actor or the main thread should
    /// not wait on a transcript of many megabytes.
    public static func write(_ job: Job, in jobs: JobStore, transcript: @escaping Transcript) async -> Bool {
        await render(job, in: jobs, transcript: transcript, to: jobs.sessionExportURL(job.id)) != nil
    }

    /// The session as it stands now, written on demand to the job's snapshot file: for a running
    /// job, or an ended one whose whole session was never written. Nil when it could not be written.
    public static func snapshot(of job: Job, in jobs: JobStore, transcript: @escaping Transcript) async -> URL? {
        await render(job, in: jobs, transcript: transcript, to: jobs.sessionPreviewURL(job.id))
    }

    private static func render(_ job: Job, in jobs: JobStore, transcript: @escaping Transcript, to url: URL) async -> URL? {
        await Task.detached(priority: .utility) {
            let text = render(job, in: jobs, transcript: transcript)
            return (try? Data(text.utf8).write(to: url, options: .atomic)) != nil ? url : nil
        }.value
    }

    /// The session as Markdown, rendered now from the job's files.
    public static func markdown(for job: Job, in jobs: JobStore, transcript: @escaping Transcript) async -> String {
        await Task.detached(priority: .utility) { render(job, in: jobs, transcript: transcript) }.value
    }

    /// What a copy gets: an ended job's saved file, which still has what the trim of its output
    /// and log took since; a running job, or one that ended before Bton wrote these, rendered now.
    public static func text(of job: Job, in jobs: JobStore, transcript: @escaping Transcript) async -> String {
        if job.status != .running, let saved = try? String(contentsOf: jobs.sessionExportURL(job.id), encoding: .utf8) {
            return saved
        }
        return await markdown(for: job, in: jobs, transcript: transcript)
    }

    private static func render(_ job: Job, in jobs: JobStore, transcript: Transcript) -> String {
        let log = text(at: jobs.logURL(job.id))
        var entries = transcript(job).map { SessionTranscript.entries(ofSessionFile: $0, limit: .max) } ?? []
        if entries.isEmpty { entries = CodexTranscript.entries(ofLog: jobs.logURL(job.id), limit: .max, resultLimit: .max) }
        return markdown(job: job, log: log, entries: entries, report: text(at: jobs.outputURL(job.id)))
    }

    static func markdown(job: Job, log: String?, entries: [SessionTranscript.Entry], report: String?) -> String {
        var lines = ["# \(job.key.repo) \(job.key.item): \(job.key.move)", ""]
        lines.append("- Job: \(job.id.uuidString)")
        lines.append("- Agent: \(job.agent ?? "command")")
        lines.append("- Head: \(job.key.head)")
        lines.append("- Status: \(job.status.rawValue)" + (job.detail.map { ", \($0)" } ?? ""))
        lines.append("- Started: \(job.startedAt.formatted(.iso8601))"
                     + (job.endedAt.map { "; ended: \($0.formatted(.iso8601))" } ?? "; still running"))
        if let cost = job.cost { lines.append("- Cost: $\(cost)") }
        lines.append("")
        lines.append("## Bton's log")
        lines.append("")
        lines.append(log.map { fenced($0, language: "text") } ?? "(no log)")
        lines.append("")
        if let prompt = entries.first(where: { $0.kind == .prompt }) {
            lines.append("## Prompt")
            lines.append("")
            lines.append(prompt.text)
            lines.append("")
        }
        lines.append("## Session")
        lines.append("")
        var step = 0
        for entry in entries {
            switch entry.kind {
            case .prompt, .thinking:
                continue
            case .text:
                lines.append(entry.text)
                lines.append("")
            case let .tool(name):
                step += 1
                lines.append("### \(step). \(name)")
                lines.append("")
                lines.append(fenced(entry.text, language: name == "Bash" || name == "exec" ? "sh" : "text"))
                lines.append("")
            case let .result(isError):
                lines.append(isError ? "**Error:**" : "Result:")
                lines.append("")
                lines.append(entry.text.isEmpty ? "(no output)" : fenced(entry.text, language: "text"))
                lines.append("")
            }
        }
        if step == 0, !entries.contains(where: { $0.kind == .text }) {
            lines.append("(no transcript: the agent left none, or it has not started)")
            lines.append("")
        }
        lines.append("## Report")
        lines.append("")
        lines.append(report ?? "(no report)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// A fence longer than any run of backticks inside, so a result that quotes Markdown stays in it.
    static func fenced(_ text: String, language: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return "\(fence)\(language)\n\(text.hasSuffix("\n") ? String(text.dropLast()) : text)\n\(fence)"
    }

    private static func text(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
