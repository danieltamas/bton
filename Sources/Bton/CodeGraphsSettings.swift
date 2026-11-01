import AppKit
import BtonCore
import SwiftUI

extension AppStore {
    /// Code graphs at all; off builds, links and mentions nothing, whatever each repo says.
    func setCodeGraphs(_ on: Bool) throws {
        try update { $0.codeGraphs = on }
    }

    /// The line agents get about their graph; empty or the default stores nil.
    func setGraphInstruction(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try update { $0.graphInstruction = trimmed.isEmpty || trimmed == CodeGraph.defaultInstruction ? nil : trimmed }
    }
}

/// Settings > Agents > Code graphs: the switch, graphify's Python (and its install), the line
/// agents are told, and what the graphs cost on disk.
struct CodeGraphsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RepoSwitch(symbol: "point.3.connected.trianglepath.dotted", title: "Use graphify",
                       help: "Off: no repo builds, links or mentions a code graph, whatever its own switch on Repos says. The graphs on disk stay.",
                       isOn: store.codeGraphs, problem: $problem) { try store.setCodeGraphs($0) }
            VStack(alignment: .leading, spacing: 14) {
                GraphifyPythonField()
                GraphInstructionField()
                StoredGraphsList()
            }
            .opacity(store.codeGraphs ? 1 : 0.55)
            if let problem { ProblemText(text: problem) }
        }
    }
}

/// The Python that has graphify; "Install graphify" when none is found.
private struct GraphifyPythonField: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var problem: String?
    @State private var installer = GraphifyInstaller()

    private var found: String? { CodeGraph.python(configured: store.graphifyPython) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLabel("Python with graphify", help: "Empty looks in ~/\(CodeGraph.installVenv) and ~/.local/pipx/venvs/graphifyy.")
            // Read so the chip is drawn again when the install ends.
            let _ = installer.finished
            HStack(spacing: 8) {
                GlassField(placeholder: "~/\(CodeGraph.installVenv)/bin/python", text: $text, monospaced: true)
                    .onSubmit(save)
                if let found {
                    Chip(text: "found", symbol: "checkmark", color: Theme.success).help(found)
                } else {
                    Chip(text: "not found", symbol: "exclamationmark.triangle", color: Theme.danger)
                    PillButton(title: installer.running ? "Installing..." : "Install graphify", symbol: "arrow.down.circle",
                               prominent: false, disabled: installer.running, action: install)
                        .help("Makes the venv ~/\(CodeGraph.installVenv) with uv or a Python 3.10 or newer that runs native, and installs graphify into it. A few minutes.")
                }
            }
            if let problem { ProblemText(text: problem) }
            if let failure = installer.problem { ProblemText(text: failure) }
        }
        .onAppear { text = store.graphifyPython ?? "" }
        .onDisappear(perform: save)
    }

    /// The install, then: a path set by hand that points nowhere would hide the venv just made,
    /// so it is cleared. Through the store, not this view, which may be gone by then.
    private func install() {
        let store = store
        installer.install {
            if store.graphifyPython != nil, CodeGraph.python(configured: store.graphifyPython) == nil {
                try? store.setGraphifyPython("")
            }
        }
    }

    private func save() {
        do { try store.setGraphifyPython(text); problem = nil } catch { problem = error.localizedDescription }
    }
}

/// Runs `CodeGraph.installSteps` in order, with uv when this Mac has it, else with the first
/// Python that passes the probe; a failed step's last output lines are the problem.
@MainActor @Observable
final class GraphifyInstaller {
    private(set) var running = false
    private(set) var finished = false
    private(set) var problem: String?

    /// `then` runs once every step exited 0.
    func install(then: @escaping @MainActor () -> Void) {
        guard !running else { return }
        running = true
        problem = nil
        Task {
            defer { running = false }
            let runner = ProcessRunner()
            guard let steps = await Self.steps(runner) else {
                problem = "No uv and no Python 3.10 or newer that runs native (\(CodeGraph.machine)) was found. "
                    + "Install uv (astral.sh/uv) or Python from python.org, then press again."
                return
            }
            for step in steps {
                do {
                    let result = try await runner.run(step[0], Array(step.dropFirst()), timeout: .seconds(600))
                    guard result.status == 0 else {
                        problem = "\(step.joined(separator: " ")) failed: " + Self.tail(result)
                        return
                    }
                } catch {
                    problem = "\(step.joined(separator: " ")) failed: \(error.localizedDescription)"
                    return
                }
            }
            finished = true
            then()
        }
    }

    private static func steps(_ runner: ProcessRunner) async -> [[String]]? {
        let tools = CodeGraph.installTools()
        if let uv = tools.uv.first { return CodeGraph.installSteps(uv: uv) }
        let machine = CodeGraph.machine
        for python in tools.pythons {
            guard let probe = try? await runner.run(python, ["-c", CodeGraph.installPythonProbe], timeout: .seconds(30)),
                  probe.status == 0, CodeGraph.installPythonFits(String(decoding: probe.stdout, as: UTF8.self), machine: machine)
            else { continue }
            return CodeGraph.installSteps(python: python)
        }
        return nil
    }

    private static func tail(_ result: ProcessOutput) -> String {
        let text = result.stderr.isEmpty ? String(decoding: result.stdout, as: UTF8.self) : result.stderr
        return text.split(separator: "\n").suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What a job is told about its graph; the placeholders are filled per job.
private struct GraphInstructionField: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SettingsLabel("Instruction to agents",
                              help: "Added to a job's instructions when its checkout got a graph. {graph} is \(CodeGraph.linkName), {base} the branch the graph is of, {commit} its commit. Empty: the default.")
                if store.graphInstruction != nil {
                    PillButton(title: "Reset", symbol: "arrow.uturn.backward", prominent: false) {
                        text = CodeGraph.defaultInstruction
                        save()
                    }
                }
            }
            GlassField(placeholder: CodeGraph.defaultInstruction, text: $text).onSubmit(save)
            Text("{graph} is \(CodeGraph.linkName), {base} the branch the graph is of, {commit} its commit.")
                .font(.meta).foregroundStyle(Theme.textTertiary)
            if let problem { ProblemText(text: problem) }
        }
        .onAppear { text = store.graphInstruction ?? CodeGraph.defaultInstruction }
        .onDisappear(perform: save)
    }

    private func save() {
        do { try store.setGraphInstruction(text); problem = nil } catch { problem = error.localizedDescription }
    }
}

/// The graphs under ~/.bton/graphs, their size and what they were built from; a trash removes one.
private struct StoredGraphsList: View {
    @Environment(AppStore.self) private var store
    @State private var graphs: [CodeGraph.StoredGraph]?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsLabel("On disk", help: "~/.bton/graphs. A deleted graph is built again on the next sync when its repo's switch is on.")
            if let graphs {
                if graphs.isEmpty {
                    Text("No graphs yet").font(.meta).foregroundStyle(Theme.textTertiary)
                } else {
                    ForEach(graphs, id: \.slug) { graph in row(graph) }
                    Text("\(graphs.count) \(graphs.count == 1 ? "graph" : "graphs"), \(Self.size(graphs.map(\.bytes).reduce(0, +)))")
                        .font(.meta).foregroundStyle(Theme.textTertiary)
                }
            } else {
                Text("Measuring...").font(.meta).foregroundStyle(Theme.textTertiary)
            }
            if let problem { ProblemText(text: problem) }
        }
        .task { await load() }
    }

    /// The repo on its own line, its facts in one line under it, the buttons at the right: the
    /// slug never wraps to make room for the facts.
    private func row(_ graph: CodeGraph.StoredGraph) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(graph.slug).font(.system(size: 11.5, weight: .medium, design: .monospaced)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                // One Text, so a narrow pane wraps the facts in order instead of cutting each one.
                TimelineView(.everyMinute) { context in
                    Text(Self.facts(graph, now: context.date))
                        .font(.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            PillButton(title: "View", symbol: "circle.grid.2x2", prominent: false, disabled: !CodeGraph.isBuilt(graph.url)) {
                ModuleMapWindow.open(graph)
            }
            .help(ModuleMapWindow.help)
            AsyncIconButton(symbol: "trash", help: "Delete this graph", size: 22, id: "delete-graph:\(graph.slug)") { await delete(graph) }
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        let home = store.home
        graphs = await Task.detached { CodeGraph.storedGraphs(home: home) }.value
    }

    private func delete(_ graph: CodeGraph.StoredGraph) async {
        // Hundreds of files: not on the main thread.
        let failure = await Task.detached { () -> String? in
            do {
                try FileManager.default.removeItem(at: graph.url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        problem = failure
        await load()
    }

    /// "456 MB · built from 3c1c8763 10 min ago · memory to 14 min ago".
    private static func facts(_ graph: CodeGraph.StoredGraph, now: Date) -> String {
        var parts = [size(graph.bytes)]
        if let marker = graph.marker {
            parts.append("built from \(marker.commit.prefix(8)) \(RelativeTime.text(marker.at, now: now)) ago")
            if let memoryAt = marker.memoryAt {
                parts.append("memory to \(RelativeTime.text(memoryAt, now: now)) ago")
            }
        } else {
            parts.append("no finished build")
        }
        return parts.joined(separator: " · ")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A field's title with what it is for on hover.
private struct SettingsLabel: View {
    let title: String
    let help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textSecondary).help(help)
    }
}
