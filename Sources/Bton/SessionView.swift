import BtonCore
import SwiftUI

/// One job's session, in place of the window's list: what the agent said and every command it
/// ran, read from Claude Code's transcript every two seconds while it works. Another agent, or a
/// session without a transcript, shows the output and log files instead.
struct SessionView: View {
    @Environment(AppStore.self) private var store
    let job: Job
    let title: String
    let close: () -> Void
    @State private var entries: [SessionTranscript.Entry] = []
    /// Without a transcript: the agent's output and Bton's log, read as the job writes them.
    @State private var fallback = Fallback()
    /// The agent's final message, once the job has ended: what it did, or why it did nothing.
    @State private var report: String?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 8) {
            header.padding(.horizontal, 14)
            if let text = problem ?? failure { ProblemText(text: text).padding(.horizontal, 14) }
            ScrollViewReader { reader in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if let report { reportBlock(report) }
                        if entries.isEmpty { fallbackBlock }
                        ForEach(entries) { entry in EntryRow(entry: entry).id(entry.id) }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.never)
                // Follows the agent while it works; an ended job opens on its report, not past it.
                .onChange(of: entries.count) {
                    guard current.status == .running else { return }
                    withAnimation(Motion.snappy) { reader.scrollTo("end", anchor: .bottom) }
                }
            }
        }
        .task(id: job.id) { await follow() }
    }

    private var current: Job { store.jobs.first { $0.id == job.id } ?? job }

    /// Why a job ended badly, from the job itself: it can fail before any agent writes a line.
    private var failure: String? {
        guard current.status == .failed || current.status == .cancelled else { return nil }
        return current.detail.map { "\(current.status == .failed ? "Failed" : "Stopped"): \($0)" }
    }

    private var placeholder: String {
        if current.status == .running { return "Waiting for the agent's first step…" }
        return current.pid == nil ? "The agent never started, so there is no session to show."
            : "The agent left no transcript and no output."
    }

    private var header: some View {
        let current = current
        return HStack(spacing: 8) {
            IconButton(symbol: "chevron.left", help: "Back to the list", action: close)
                .keyboardShortcut(.cancelAction)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Chip(text: current.status.rawValue, color: Theme.color(for: current.status))
                }
                HStack(spacing: 6) {
                    if current.status == .running {
                        Text(current.startedAt, style: .timer)
                    } else if let ended = current.endedAt {
                        RelativeTime(date: ended)
                    }
                    if let cost = current.cost { Text("·"); Text(cost.usd()) }
                }
                .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            if store.hasLogs(of: current) {
                IconButton(symbol: "doc.text", help: "Open the agent's output and error log", size: 24) {
                    store.openLogs(of: current)
                }
            }
            if current.status != .running, current.worktree != nil, store.isClaude(current) {
                IconButton(symbol: "terminal", help: "Resume this session in Terminal", size: 24) {
                    do { try store.resumeInTerminal(current) } catch { problem = error.localizedDescription }
                }
            }
            if current.status == .running {
                AsyncIconButton(symbol: "stop.fill", help: "Stop and release the lease", tint: Theme.danger, size: 24,
                                id: "stop:\(current.id)") { await store.stop(current) }
            }
        }
    }

    /// The report first, above the session that produced it: a row that says "its report says
    /// why" opens here, and the why is the first thing read.
    private func reportBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Eyebrow(text: "The agent's report", color: Theme.mint)
            // Agents write Markdown: drawn as an issue's text is (MarkdownView, from the issue-markdown change).
            MarkdownView(text: text, tone: Theme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.core, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.bottom, 6)
    }

    /// The agent's output is Markdown, drawn as the report is, and never shown twice: once the
    /// job has ended the report above is that same file, so only Bton's log follows it. The log
    /// is Bton's own account and the agent's errors, plain text.
    @ViewBuilder private var fallbackBlock: some View {
        if report == nil, fallback.output == nil, fallback.log == nil {
            Text(placeholder)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if report == nil, let output = fallback.output {
            MarkdownView(text: output, tone: Theme.textPrimary)
        }
        if let log = fallback.log {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Bton's log", color: Theme.textTertiary)
                Text(log)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
    }

    /// Re-reads while the view shows. The read is a child of the view's task, so closing the view
    /// cancels it instead of leaving a parse of a large file running.
    private func follow() async {
        while !Task.isCancelled {
            let (read, files) = await Self.read(transcript: store.sessionFile(of: job), logs: store.outputFiles(of: job))
            guard !Task.isCancelled else { return }
            if read != entries { entries = read }
            if files != fallback { fallback = files }
            if current.status != .running, let url = store.outputFiles(of: job).first {
                report = await Self.report(at: url)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    struct Fallback: Equatable {
        var output: String?
        var log: String?
    }

    /// Off the main actor: the transcript and the logs grow as the agent works. Without a Claude
    /// transcript, a Codex job's log reads as its session; the output and the log are shown as
    /// files only when neither gives one, and only their last 8 KB each.
    nonisolated private static func read(transcript: URL?, logs: [URL]) async -> ([SessionTranscript.Entry], Fallback) {
        var entries = transcript.map { SessionTranscript.entries(ofSessionFile: $0) } ?? []
        if entries.isEmpty, let log = logs.last { entries = CodexTranscript.entries(ofLog: log) }
        guard entries.isEmpty, !Task.isCancelled else { return (entries, Fallback()) }
        let texts = logs.map { tail(of: $0, bytes: 8_000)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { $0?.isEmpty == false ? $0 : nil }
        return ([], Fallback(output: texts.first ?? nil, log: texts.dropFirst().first ?? nil))
    }

    /// The output file is the agent's final message; a job that ended without one has no report.
    nonisolated private static func report(at url: URL) async -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data.prefix(16_000), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    nonisolated private static func tail(of url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: end - min(end, bytes))) != nil,
              let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct EntryRow: View {
    let entry: SessionTranscript.Entry
    @State private var expanded = false

    var body: some View {
        switch entry.kind {
        case .prompt:
            bubble(label: "Prompt", color: Theme.color(forMove: "schedule"), text: entry.text, lines: 3)
        case .text:
            // The agent's own words are Markdown, in the session as in the report above it.
            MarkdownView(text: entry.text, tone: Theme.textPrimary)
                .padding(.vertical, 2)
        case .thinking:
            Label("thinking", systemImage: "ellipsis").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
        case let .tool(name):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(name).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.color(forMove: "review"))
                    .padding(.horizontal, 6).padding(.vertical, 1.5)
                    .background(Theme.color(forMove: "review").opacity(0.14), in: Capsule())
                Text(entry.text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textSecondary)
                    .lineLimit(expanded ? nil : 2).textSelection(.enabled)
            }
            .onTapGesture { expanded.toggle() }
        case let .result(isError):
            // A failed step's reason is in its last lines, so a collapsed failure keeps them: the
            // preview cuts it to twelve lines itself, so a wrapped long line cannot push them out.
            Text(entry.text.isEmpty ? "(no output)"
                 : isError && !expanded ? SessionTranscript.preview(entry.text) : entry.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(isError ? Theme.danger.opacity(0.9) : Theme.textTertiary)
                .lineLimit(expanded ? 40 : isError ? nil : 3).textSelection(.enabled)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.hairline).frame(width: 1) }
                .onTapGesture { expanded.toggle() }
        }
    }

    private func bubble(label: String, color: Color, text: String, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Eyebrow(text: label, color: color)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                .lineLimit(expanded ? nil : lines).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { expanded.toggle() }
    }
}
