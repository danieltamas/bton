@testable import BtonCore
import Foundation
import Testing

/// The session file is the whole job: nothing the window cuts (the newest 400 entries, a result's
/// first 6 KB, the log's tail) is cut here, and it reads in order: Bton's log, the prompt, the
/// steps with their results, the report.
@Suite(ProcessBound())
struct SessionExportAcceptanceTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let none: SessionExport.Transcript = { _ in nil }

    private static func job(agent: String? = "claude", status: Job.Status = .failed, detail: String? = "agent exited 1") -> Job {
        Job(id: UUID(), key: JobKey(repo: "synthetic/project", item: "pr-582", move: "fix", head: "abcdef12"),
            agent: agent, startedAt: now, endedAt: now.addingTimeInterval(90), status: status, detail: detail, cost: 1.25)
    }

    private static func claudeTranscript(steps: Int, first: String = "ok") -> Data {
        var lines = [#"{"type":"user","message":{"content":"Fix PR 582."}}"#,
                     #"{"type":"assistant","message":{"content":[{"type":"text","text":"Reading the review."}]}}"#]
        for step in 1...steps {
            let error = step == steps ? "true" : "false"
            lines.append(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"step \#(step)"}}]}}"#)
            lines.append(#"{"type":"user","message":{"content":[{"type":"tool_result","is_error":\#(error),"content":"\#(step == 1 ? first : "ok") \#(step)"}]}}"#)
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func home() throws -> (JobStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bton-export-\(UUID().uuidString)")
        let home = BtonHome(environment: ["BTON_HOME": root.path])
        return (try JobStore(home: home), root)
    }

    @Test func fileHoldsTheLogFirstEveryStepWithItsWholeResultAndTheReportLast() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Self.job()
        try store.save(job)
        let session = root.appendingPathComponent("session.jsonl")
        let longResult = String(repeating: "q", count: 20_000)
        try Self.claudeTranscript(steps: 450, first: longResult).write(to: session)
        try "worktree ready\nagent exited 1\n".write(to: store.logURL(job.id), atomically: true, encoding: .utf8)
        try "I could not push: `bun test` was blocked.\n".write(to: store.outputURL(job.id), atomically: true, encoding: .utf8)
        #expect(await SessionExport.write(job, in: store) { _ in session })
        let text = try String(contentsOf: store.sessionExportURL(job.id), encoding: .utf8)

        let sections = ["## Bton's log", "## Prompt", "## Session", "## Report"]
        let offsets = sections.map { text.range(of: $0)!.lowerBound }
        #expect(offsets == offsets.sorted(), "the sections read in order")
        #expect(text.hasPrefix("# synthetic/project pr-582: fix\n"))
        #expect(text.contains("- Status: failed, agent exited 1"))
        #expect(text.contains("worktree ready\nagent exited 1"))
        #expect(text.contains("Fix PR 582."))
        #expect(text.contains("### 1. Bash\n\n```sh\nstep 1\n```"), "the first step is kept: no newest-400 cap")
        #expect(text.contains("### 450. Bash"))
        #expect(text.filter { $0 == "q" }.count == 20_000, "a result is kept whole: no 6 KB cut")
        #expect(text.contains("**Error:**\n\n```text\nok 450\n```"), "the failed step is marked")
        #expect(!text.contains("**Error:**\n\n```text\nok 1\n```"))
        #expect(text.hasSuffix("## Report\n\nI could not push: `bun test` was blocked.\n"))
    }

    @Test func aResultThatQuotesAFenceStaysInsideItsOwn() {
        let fenced = SessionExport.fenced("here is markdown:\n```sh\nls\n```\n", language: "text")
        #expect(fenced == "````text\nhere is markdown:\n```sh\nls\n```\n````")
        #expect(SessionExport.fenced("plain", language: "sh") == "```sh\nplain\n```")
    }

    @Test func aCodexJobReadsItsLogAsTheSessionWithWholeResults() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Self.job(agent: "codex", status: .succeeded, detail: nil)
        try store.save(job)
        let output = String(repeating: "y", count: 9_000)
        let log = """
        2026-10-30T13:10:34Z bton: agent starts
        OpenAI Codex v0.160.0
        user
        Review this change.
        exec
        /bin/zsh -lc 'git status --short' in /Users/x/wt
         succeeded in 322ms:
        \(output)
        codex
        ## Review: approve (head abcdef12)
        tokens used
        1234

        """
        try log.write(to: store.logURL(job.id), atomically: true, encoding: .utf8)
        let text = await SessionExport.markdown(for: job, in: store, transcript: Self.none)
        #expect(text.contains("## Prompt\n\nReview this change."))
        #expect(text.contains("### 1. exec\n\n```sh\ngit status --short\n```"))
        #expect(text.contains("Result:\n\n```text\n\(output)\n```"), "the window keeps 6 KB of a Codex result; the file keeps it all")
        #expect(text.contains("## Review: approve (head abcdef12)"))
        #expect(text.contains("- Agent: codex"))
        #expect(text.hasSuffix("## Report\n\n(no report)\n"))
    }

    @Test func aJobWithoutTranscriptOrFilesStillRenders() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = Self.job(agent: nil, status: .running, detail: nil)
        job.endedAt = nil
        let text = await SessionExport.markdown(for: job, in: store, transcript: Self.none)
        #expect(text.contains("- Agent: command"))
        #expect(text.contains("still running"))
        #expect(text.contains("## Bton's log\n\n(no log)"))
        #expect(text.contains("(no transcript: the agent left none, or it has not started)"))
    }

    /// A stopped job finishes inside its cancelled task, where the transcript parsers hand back
    /// nothing: the file written then must still be the whole session.
    @Test func theFileWrittenFromACancelledTaskIsStillWhole() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Self.job(status: .cancelled, detail: "stopped")
        try store.save(job)
        let session = root.appendingPathComponent("session.jsonl")
        try Self.claudeTranscript(steps: 3).write(to: session)
        let written = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            return await SessionExport.write(job, in: store) { _ in session }
        }.value
        #expect(written)
        let text = try String(contentsOf: store.sessionExportURL(job.id), encoding: .utf8)
        #expect(text.contains("### 3. Bash"))
        #expect(text.contains("Fix PR 582."))
    }

    /// The copy of an ended job is its saved file, which still has what a later trim of the log
    /// took; a running job is rendered from its files as they are now.
    @Test func anEndedJobCopiesItsSavedFileAndARunningJobCopiesTheFilesNow() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Self.job()
        try store.save(job)
        try "the whole log\n".write(to: store.logURL(job.id), atomically: true, encoding: .utf8)
        #expect(await SessionExport.write(job, in: store, transcript: Self.none))
        try "[9 earlier bytes trimmed]\nlog\n".write(to: store.logURL(job.id), atomically: true, encoding: .utf8)
        #expect(await SessionExport.text(of: job, in: store, transcript: Self.none).contains("the whole log"))
        var running = job
        running.status = .running
        running.endedAt = nil
        #expect(await SessionExport.text(of: running, in: store, transcript: Self.none).contains("[9 earlier bytes trimmed]"))
    }

    /// Open renders a snapshot; the job can end, write its whole file and trim its originals
    /// before that snapshot is written. The snapshot has its own file, whatever the job's status
    /// was when Open saw it, so however late it lands it never replaces the whole session.
    @Test func aSnapshotHasItsOwnFileAndNeverReplacesTheWholeSession() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        var running = Self.job(status: .running, detail: nil)
        running.endedAt = nil
        try store.save(running)
        try "the whole log\n".write(to: store.logURL(running.id), atomically: true, encoding: .utf8)
        var ended = running
        ended.status = .succeeded
        ended.endedAt = Self.now.addingTimeInterval(90)
        try store.save(ended)
        #expect(await SessionExport.write(ended, in: store, transcript: Self.none))
        try "log\n".write(to: store.logURL(running.id), atomically: true, encoding: .utf8)
        for seen in [running, ended] {
            let snapshot = await SessionExport.snapshot(of: seen, in: store, transcript: Self.none)
            #expect(snapshot == store.sessionPreviewURL(seen.id))
            let soFar = try String(contentsOf: #require(snapshot), encoding: .utf8)
            #expect(soFar.contains("```text\nlog\n```"))
        }
        let whole = try String(contentsOf: store.sessionExportURL(running.id), encoding: .utf8)
        #expect(whole.contains("the whole log"))
        #expect(whole.contains("- Status: succeeded"))
    }

    @Test func aFileThatCannotBeWrittenIsReportedNotHidden() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        let job = Self.job()
        try store.save(job)
        // A directory where the file would go: the atomic write cannot replace it.
        try FileManager.default.createDirectory(at: store.sessionExportURL(job.id), withIntermediateDirectories: true)
        #expect(await SessionExport.write(job, in: store, transcript: Self.none) == false)
    }

    @Test func pruneRemovesTheSessionFileWithTheJobsOtherFiles() async throws {
        let (store, root) = try home()
        defer { try? FileManager.default.removeItem(at: root) }
        var job = Self.job()
        job.endedAt = Self.now.addingTimeInterval(-40 * 86_400)
        try store.save(job)
        try "log".write(to: store.logURL(job.id), atomically: true, encoding: .utf8)
        #expect(await SessionExport.write(job, in: store, transcript: Self.none))
        #expect(FileManager.default.fileExists(atPath: store.sessionExportURL(job.id).path))
        #expect(store.prune(now: Self.now) == 1)
        #expect(!FileManager.default.fileExists(atPath: store.sessionExportURL(job.id).path))
    }
}
