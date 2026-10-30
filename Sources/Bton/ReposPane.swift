import AppKit
import BtonCore
import SwiftUI

/// The repos this Bton watches, added by their project folder: the repo is whatever GitHub repo
/// the folder is a clone of, and worktrees are made in that folder.
struct ReposPane: View {
    @Environment(AppStore.self) private var store
    @State private var problem: String?
    @State private var adding = false
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PaneHeader(pane: .repos, title: "Repos",
                       detail: "Add a project folder. Bton reads its GitHub repo from the folder's origin and runs agents in worktrees inside it.")
            dropZone
            if let problem { ProblemText(text: problem) }
            if !store.repos.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Eyebrow(text: "Watching \(store.repos.count)")
                    ForEach(Array(store.repos.enumerated()), id: \.element.slug) { index, repo in
                        row(repo).riseIn(index)
                    }
                }
            }
        }
        .animation(Motion.spring, value: store.repos.map(\.slug))
        .animation(Motion.spring, value: problem)
    }

    private var dropZone: some View {
        Bezel(fill: targeted ? Theme.coreHover : Theme.core, glow: targeted ? Theme.mint : nil) {
            HStack(spacing: 16) {
                Image(systemName: adding ? "hourglass" : "folder.badge.plus")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 52, height: 52)
                    .background(Theme.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.mint.opacity(targeted ? 0.7 : 0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                VStack(alignment: .leading, spacing: 4) {
                    Text(adding ? "Reading the folder…" : "Drop a project folder here")
                        .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("Any folder inside a clone of a GitHub repo works.").font(.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                PillButton(title: "Choose Folder…", symbol: "plus", disabled: adding) {
                    if let folder = pickFolder(message: "Choose a project folder: a clone of a GitHub repo.") { add(folder) }
                }
            }
            .padding(18)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: \.hasDirectoryPath) else { return false }
            add(folder)
            return true
        } isTargeted: { targeted in withAnimation(Motion.snappy) { self.targeted = targeted } }
    }

    private func row(_ repo: WatchedRepo) -> some View {
        let flow = store.flows[repo.slug]
        let open = store.openPullRequests.filter { $0.repo == repo.slug }.count
        return HoverCard(accent: Theme.color(for: flow), action: nil) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(repo.slug).font(.rowTitle).foregroundStyle(Theme.textPrimary)
                        Chip(text: flowLabel(flow), color: Theme.color(for: flow))
                        if open > 0 { Chip(text: "\(open) open", color: Theme.neutral, style: .outline) }
                    }
                    if let path = repo.path {
                        Label(path, systemImage: "folder").font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.head)
                        BranchPicker(repo: repo, problem: $problem)
                        EnvironmentEditor(repo: repo)
                        WorkLabelEditor(repo: repo)
                        AgentPickEditor(title: "Issue work", symbol: "hammer", current: repo.work) { line, _ in
                            try store.setWork(line, for: repo.slug)
                        }
                        AgentPickEditor(title: "Reviewer", symbol: "checkmark.seal", current: repo.reviewer, rules: repo.reviewRules,
                                        rulesPrompt: "Review rules: added to every review this Mac runs here. Empty adds none.") { line, rules in
                            try store.setReviewer(line, rules: rules, for: repo.slug)
                        }
                        HStack(spacing: 8) {
                            RepoSwitch(symbol: "point.3.connected.trianglepath.dotted", title: "Build a code graph for agents",
                                       help: "After a sync, Bton keeps a graphify graph of the branch PRs merge into under ~/.bton/graphs, with the repo's issues, PRs, decisions and job reports as its memory, and links both into every checkout it makes, so agents ask it before searching or reading GitHub.",
                                       isOn: repo.buildsGraph, problem: $problem) { try store.setCodeGraph($0, for: repo.slug) }
                            if repo.buildsGraph, !store.codeGraphs {
                                Chip(text: "graphify is off", symbol: "exclamationmark.triangle", color: Theme.neutral)
                                    .help("Use graphify is off in Settings > Agents: nothing is built or linked for any repo")
                            } else if repo.buildsGraph, CodeGraph.python(configured: store.graphifyPython) == nil {
                                Chip(text: "graphify's Python not found", symbol: "exclamationmark.triangle", color: Theme.danger)
                                    .help("Bton looks in ~/.venvs/graphifyy-arm64 and ~/.local/pipx/venvs/graphifyy; set another path in Settings > Agents")
                            }
                        }
                        RepoSwitch(symbol: "play.circle", title: "Start the flow's moves on every sync",
                                   help: "Off (the default): a sync only reads the PRs, and agents start here from your schedules and from Run now, Merge and Retry.",
                                   isOn: repo.startsMoves, problem: $problem) { try store.setStartMoves($0, for: repo.slug) }
                        if repo.startsMoves {
                            RepoSwitch(symbol: "arrow.triangle.branch", title: "Fix conflicts on my PRs automatically",
                                       help: "An agent merges the base into the PR, resolves, tests and pushes. Off: the PR row's Fix conflicts does it.",
                                       isOn: repo.resolvesConflicts, problem: $problem) { try store.setResolveConflicts($0, for: repo.slug) }
                            RepoSwitch(symbol: "hand.raised", title: "Take teammates' moves automatically",
                                       help: "A sync assigns a PR to you on GitHub when its move is one Take it could take, then starts it. Once per PR and head. Off: the row's Take it does it.",
                                       isOn: repo.takesMoves, problem: $problem) { try store.setTakeMoves($0, for: repo.slug) }
                        }
                    } else {
                        Text("No folder yet: nothing is started here until it has one.").font(.meta).foregroundStyle(Theme.unassigned)
                    }
                }
                Spacer()
                if repo.path == nil {
                    PillButton(title: "Choose Folder…", symbol: "folder", prominent: false) { chooseClone(for: repo.slug) }
                } else {
                    IconButton(symbol: "arrow.up.forward.square", help: "Show the folder in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path!)])
                    }
                }
                IconButton(symbol: "minus", help: "Stop watching \(repo.slug)", tint: Theme.danger) {
                    do { try store.removeRepo(repo.slug) } catch { problem = error.localizedDescription }
                }
            }
        }
    }

    private func flowLabel(_ flow: FlowStatus?) -> String {
        switch flow {
        case nil: "flow not read yet"
        case .some(.none): "no flow"
        case let .unsupported(version)?: "flow v\(version.map(String.init) ?? "?") not supported"
        case .invalid?: "flow invalid"
        case .ready?: "flow v1"
        }
    }

    private func add(_ folder: URL) {
        guard !adding else { return }
        adding = true
        problem = nil
        Task {
            defer { adding = false }
            do { try await store.addFolder(folder) } catch { problem = error.localizedDescription }
        }
    }

    private func chooseClone(for slug: String) {
        guard !adding else { return }
        guard let clone = pickFolder(message: "Choose the local clone of \(slug). Bton makes its worktrees there.") else { return }
        problem = nil
        adding = true
        Task {
            defer { adding = false }
            do { try await store.chooseClone(clone, for: slug) } catch { problem = error.localizedDescription }
        }
    }
}

/// The branch PRs merge into, picked from origin's branches in the clone: Bton reads the flow
/// there and starts schedules from it.
private struct BranchPicker: View {
    @Environment(AppStore.self) private var store
    let repo: WatchedRepo
    @Binding var problem: String?
    @State private var branches: [String] = []

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.merge").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Text("PRs merge into").font(.meta).foregroundStyle(Theme.textTertiary)
            Menu {
                Button("Default branch") { pick("") }
                Divider()
                ForEach(branches, id: \.self) { branch in Button(branch) { pick(branch) } }
            } label: {
                HStack(spacing: 4) {
                    Text(repo.branch ?? "default branch").font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(repo.branch == nil ? Theme.textSecondary : Theme.mint)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Theme.canvas.opacity(0.7), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .pointingHandCursor()
            .fixedSize()
        }
        .task(id: repo.path) {
            guard let path = repo.path else { return }
            branches = await RepoOrigin.remoteBranches(clone: URL(fileURLWithPath: path))
        }
    }

    private func pick(_ branch: String) {
        do {
            try store.setBranch(branch, for: repo.slug)
            problem = nil
            Task { await store.refresh() }
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// One of a repo's on/off settings on this Mac, saved as soon as it is flipped.
/// A repo setting as a labelled switch, in Settings > Repos and on the repo's page.
struct RepoSwitch: View {
    let symbol: String
    let title: String
    let help: String
    let isOn: Bool
    @Binding var problem: String?
    let set: (Bool) throws -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
            Text(title).font(.meta).foregroundStyle(Theme.textTertiary)
            Toggle("", isOn: Binding(get: { isOn }, set: { on in
                do { try set(on); problem = nil } catch { problem = error.localizedDescription }
            }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(Theme.mint)
            .pointingHandCursor()
        }
        .help(help)
    }
}

/// Variables for this repo on this Mac, such as a test database's DATABASE_URL: checks, merge
/// commands and agents get them. Only the names are shown until the editor is opened.
private struct EnvironmentEditor: View {
    @Environment(AppStore.self) private var store
    let repo: WatchedRepo
    @State private var editing = false
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text(names).font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                Button(editing ? "Cancel" : "Edit") {
                    text = editing ? "" : WatchedRepo.environmentText(repo.environment ?? [:])
                    problem = nil
                    editing.toggle()
                }
                .buttonStyle(.plain).pointingHandCursor().font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            if editing {
                GlassEditor(text: $text, monospaced: true, minHeight: 70)
                Text("One KEY=VALUE per line. Checks, merge commands and agents for this repo get them on this Mac.")
                    .font(.meta).foregroundStyle(Theme.textTertiary)
                if let problem { ProblemText(text: problem) }
                PillButton(title: "Save", symbol: "checkmark") { save() }
            }
        }
        .animation(Motion.snappy, value: editing)
    }

    private var names: String {
        let keys = (repo.environment ?? [:]).keys.sorted()
        return keys.isEmpty ? "No environment" : "Environment: " + keys.joined(separator: ", ")
    }

    private func save() {
        do {
            try store.setEnvironment(text, for: repo.slug)
            text = ""
            problem = nil
            editing = false
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The label teammates without Bton see on a PR a Bton is working on; off until named.
private struct WorkLabelEditor: View {
    @Environment(AppStore.self) private var store
    let repo: WatchedRepo
    @State private var editing = false
    @State private var text = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "tag").font(.system(size: 10)).foregroundStyle(Theme.textTertiary)
                Text(repo.workLabel.map { "Work label: \($0)" } ?? "No work label")
                    .font(.meta).foregroundStyle(Theme.textTertiary).lineLimit(1).truncationMode(.tail)
                Button(editing ? "Cancel" : "Edit") {
                    text = editing ? "" : repo.workLabel ?? ""
                    problem = nil
                    editing.toggle()
                }
                .buttonStyle(.plain).pointingHandCursor().font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.mint)
            }
            if editing {
                TextField("bton:working", text: $text)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(8)
                    .background(Theme.core, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onSubmit(save)
                Text("A PR carries this label while a Bton on any Mac works it, so teammates see it on GitHub. Empty turns it off.")
                    .font(.meta).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
                if let problem { ProblemText(text: problem) }
                PillButton(title: "Save", symbol: "checkmark") { save() }
            }
        }
        .animation(Motion.snappy, value: editing)
    }

    private func save() {
        do {
            try store.setWorkLabel(text, for: repo.slug)
            text = ""
            problem = nil
            editing = false
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The app is activated first: from an accessory app the panel otherwise opens behind other windows.
@MainActor
func pickFolder(message: String) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = message
    panel.prompt = "Choose"
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
}
