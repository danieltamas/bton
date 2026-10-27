# Code Graph Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bton builds and keeps a graphify code graph per watched repo under its own home, links it into every checkout it prepares, and tells agents to query it.

**Architecture:** A `CodeGraph` enum in BtonCore owns the store path, the symlink, the build marker and the build command; a `CodeGraphBuilder` actor runs at most one build per repo, started by the Engine's tick after the repo is read. The Dispatcher links the store into a job's worktree and adds one line to the agent's team instructions. Settings get a per-repo switch and a Python path.

**Tech Stack:** Swift 6 (BtonCore, SwiftUI app), graphify 0.9.48 in a Python venv (`graphify.watch._rebuild_code`, no LLM), git worktrees, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-27-repo-features-design.md`, section "1. Code graph store" (piece 1 of 3).

## Global Constraints

- The store is `<BtonHome>/graphs/<owner>__<repo>/` (slug lowercased, `/` replaced by `__`). Never inside the repo, never in git.
- The link in a checkout is a symlink named `graphify-out`, pointing at the store. A checkout whose `graphify-out` is already that link is left alone.
- The build command is the venv's Python running `from graphify.watch import _rebuild_code; from pathlib import Path; import sys; sys.exit(0 if _rebuild_code(Path('.')) else 1)`, in a worktree at the default branch tip, under `/usr/bin/nice -n 10`, timeout 30 minutes. Verified 2026-10-27: 2.5 s on Bton's sources with `graphify-out` a symlink; graphify takes its own flock in the store.
- A build runs only when the tip differs from the marker's commit and no build runs for that repo. A failed or timed-out build leaves the previous graph and the previous marker; the failure goes to the engine log.
- The marker is `<store>/bton-build.json`: `{ "commit": "<sha>", "at": "<ISO 8601>" }`, written after a successful build only.
- PR and schedule worktrees get the link only; nothing rebuilds there (the store is shared, 157 MB on lexito, and a rebuild from a PR head would replace the graph other jobs read). The agent is told the graph is of the base at the marker's commit.
- The Python path: `BtonConfig.graphifyPython` when set; otherwise the first executable of `~/.venvs/graphifyy-arm64/bin/python`, `~/.local/pipx/venvs/graphifyy/bin/python`. None found: no build, the switch shows the reason.
- Files stay under 500 lines; comments say why; English identifiers; no new scripts.
- Tests are acceptance tests from this plan, written by another vendor (codex) before implementation, per CANON; the implementer never edits them.

## Review Focus

1. A clone whose `graphify-out` is a real directory with a graph (lexito today): it must move into an empty store, not be deleted, and never be moved over a store that already has `graph.json`. Test in Task 2.
2. Two ticks while a build still runs: no second process, no marker written by the loser. Test in Task 3.
3. A build that exits non-zero after writing a partial `graph.json`: the marker must still name the previous commit, so the next tick retries. Test in Task 3.
4. The repo's switch is on but the Python path resolves to nothing: the tick must not fail the repo's other work, and the log says why once per tick, not per second. Test in Task 3.
5. A worktree where `graphify-out` exists as a file or a directory the agent made: the link step must not replace it and must not fail the job. Test in Task 4.

---

### Task 1: Config: the repo switch and the Python path

**Files:**
- Modify: `Sources/BtonCore/Config.swift` (`BtonConfig`, `WatchedRepo`)
- Modify: `Sources/Bton/AppStore.swift` (setters beside `setStartMoves`)
- Modify: `Sources/Bton/ReposPane.swift` (switch row), `Sources/Bton/AgentsPane.swift` (Python path card)
- Test: `Tests/BtonCoreTests/CodeGraphConfigAcceptanceTests.swift`

**Interfaces:**
- Produces: `WatchedRepo.codeGraph: Bool?`, `WatchedRepo.buildsGraph: Bool { codeGraph == true }`; `BtonConfig.graphifyPython: String?`; `CodeGraph.python(configured: String?, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String?` (the resolved interpreter or nil).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func repoSwitchDefaultsOff() throws {
    let repo = WatchedRepo(slug: "o/r", path: "/tmp/r")
    #expect(repo.buildsGraph == false)
    let json = try JSONEncoder().encode(repo)
    #expect(!String(decoding: json, as: UTF8.self).contains("codeGraph"))  // nil is not written
}
@Test func repoSwitchRoundTrips() throws {
    var repo = WatchedRepo(slug: "o/r", path: "/tmp/r"); repo.codeGraph = true
    let back = try JSONDecoder().decode(WatchedRepo.self, from: JSONEncoder().encode(repo))
    #expect(back.buildsGraph)
}
@Test func pythonPrefersConfigured() { #expect(CodeGraph.python(configured: "/usr/bin/true") == "/usr/bin/true") }
@Test func pythonConfiguredButMissingIsNil() { #expect(CodeGraph.python(configured: "/nonexistent/python") == nil) }
@Test func pythonFallsBackToVenv() throws {
    let home = try temporaryDirectory()  // a helper this test file defines: a new temp dir, removed at the end
    let venv = home.appendingPathComponent(".venvs/graphifyy-arm64/bin"); try FileManager.default.createDirectory(at: venv, withIntermediateDirectories: true)
    let python = venv.appendingPathComponent("python"); try "#!/bin/sh\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    #expect(CodeGraph.python(configured: nil, home: home) == python.path)
    #expect(CodeGraph.python(configured: nil, home: try temporaryDirectory()) == nil)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphConfigAcceptanceTests`
Expected: compile error, `codeGraph` and `CodeGraph` undefined.

- [ ] **Step 3: Add the fields and the resolver**

`WatchedRepo.codeGraph: Bool?` with a doc comment (nil is off; what the switch does), `buildsGraph` beside `startsMoves`. `BtonConfig.graphifyPython: String? = nil` beside `draftModel`. Create `Sources/BtonCore/CodeGraph.swift` with `public enum CodeGraph` and `python(configured:home:)`: a configured path counts only when `FileManager.isExecutableFile`; otherwise the two venv candidates under `home`, first executable wins.

- [ ] **Step 4: Settings**

`AppStore.setCodeGraph(_ on: Bool, for slug: String) throws` and `setGraphifyPython(_ path: String?) throws` through `update`. In `ReposPane.row`, under the Reviewer editor: `RepoSwitch(symbol: "point.3.connected.trianglepath.dotted", title: "Build a code graph for agents", help: "Bton keeps a graphify graph of the branch PRs merge into under ~/.bton/graphs and links it into every checkout it makes, so agents query it before searching.", isOn: repo.buildsGraph, ...)`; when on and `CodeGraph.python(configured: store.config.graphifyPython) == nil`, a `Chip(text: "graphify's Python not found", symbol: "exclamationmark.triangle", color: Theme.danger)` with help naming the two default locations and Settings > Agents. In `AgentsPane`, a `SettingsCard(title: "Code graphs", detail: "The Python that has graphify installed. Empty looks in ~/.venvs/graphifyy-arm64 and ~/.local/pipx/venvs/graphifyy.")` with a `GlassField` bound to `graphifyPython`, saved on commit.

- [ ] **Step 5: Run the tests**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphConfigAcceptanceTests`
Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/BtonCore/Config.swift Sources/BtonCore/CodeGraph.swift Sources/Bton/AppStore.swift Sources/Bton/ReposPane.swift Sources/Bton/AgentsPane.swift Tests/BtonCoreTests/CodeGraphConfigAcceptanceTests.swift
git commit -m "feat(graph): per-repo code graph switch and graphify Python path"
```

### Task 2: Store path, link and migration

**Files:**
- Modify: `Sources/BtonCore/CodeGraph.swift`
- Test: `Tests/BtonCoreTests/CodeGraphStoreAcceptanceTests.swift`

**Interfaces:**
- Produces:
  - `CodeGraph.store(for slug: String, home: BtonHome) -> URL`
  - `CodeGraph.isBuilt(_ store: URL) -> Bool` (true when `<store>/graph.json` exists)
  - `CodeGraph.link(into checkout: URL, store: URL) throws -> LinkOutcome` where `public enum LinkOutcome: Equatable { case linked, alreadyLinked, moved, kept(String) }`: `moved` when the checkout's real `graphify-out` directory was moved into an empty store, `kept(reason)` when something else occupies the name (a file, a directory while the store already has a graph, a symlink elsewhere) and nothing was changed.
  - `CodeGraph.Marker: Codable { commit: String; at: Date }`, `CodeGraph.marker(in store: URL) -> Marker?`, `CodeGraph.writeMarker(_:in:) throws`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func storePathIsUnderHome() {
    let home = BtonHome(environment: ["BTON_HOME": "/tmp/h"])
    #expect(CodeGraph.store(for: "Owner/Repo.Name", home: home).path == "/tmp/h/graphs/owner__repo.name")
}
@Test func linkMakesSymlinkAndIsIdempotent() throws {
    let (checkout, store) = try fixture()  // two empty temp dirs
    #expect(try CodeGraph.link(into: checkout, store: store) == .linked)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: checkout.appendingPathComponent("graphify-out").path) == store.path)
    #expect(try CodeGraph.link(into: checkout, store: store) == .alreadyLinked)
}
@Test func linkMovesExistingGraphIntoEmptyStore() throws {
    let (checkout, store) = try fixture()
    let old = checkout.appendingPathComponent("graphify-out"); try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try "{}".write(to: old.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    #expect(try CodeGraph.link(into: checkout, store: store) == .moved)
    #expect(FileManager.default.fileExists(atPath: store.appendingPathComponent("graph.json").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: old.path) == store.path)
}
@Test func linkKeepsExistingGraphWhenStoreIsBuilt() throws {
    let (checkout, store) = try fixture()
    try "{}".write(to: store.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    let old = checkout.appendingPathComponent("graphify-out"); try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
    try "old".write(to: old.appendingPathComponent("graph.json"), atomically: true, encoding: .utf8)
    guard case .kept = try CodeGraph.link(into: checkout, store: store) else { Issue.record("expected kept"); return }
    #expect(try String(contentsOf: old.appendingPathComponent("graph.json"), encoding: .utf8) == "old")
    #expect(try String(contentsOf: store.appendingPathComponent("graph.json"), encoding: .utf8) == "{}")
}
@Test func linkKeepsAFile() throws {
    let (checkout, store) = try fixture()
    try "x".write(to: checkout.appendingPathComponent("graphify-out"), atomically: true, encoding: .utf8)
    guard case .kept = try CodeGraph.link(into: checkout, store: store) else { Issue.record("expected kept"); return }
}
@Test func markerRoundTrips() throws {
    let (_, store) = try fixture()
    #expect(CodeGraph.marker(in: store) == nil)
    try CodeGraph.writeMarker(.init(commit: "abc", at: .init(timeIntervalSince1970: 1)), in: store)
    #expect(CodeGraph.marker(in: store)?.commit == "abc")
    #expect(CodeGraph.isBuilt(store) == false)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphStoreAcceptanceTests`
Expected: compile errors on the new names.

- [ ] **Step 3: Implement**

`store(for:home:)`: `home.url/graphs/<key>`, key = lowercased slug with `/` replaced by `__`; the function creates nothing. `link`: create the store directory (0700 like the home) if missing; inspect `checkout/graphify-out` with `attributesOfItem` (symlink type first, then directory, then file); the move uses `FileManager.moveItem` of each entry of the old directory into the store, then removes the empty old directory and makes the link; the symlink target is the store's absolute path. Marker: `JSONEncoder` with `.iso8601` dates to `bton-build.json`, written atomically.

- [ ] **Step 4: Run the tests**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphStoreAcceptanceTests`
Expected: 6 passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/BtonCore/CodeGraph.swift Tests/BtonCoreTests/CodeGraphStoreAcceptanceTests.swift
git commit -m "feat(graph): store path, checkout link with migration, build marker"
```

### Task 3: The builder and the tick

**Files:**
- Create: `Sources/BtonCore/CodeGraphBuilder.swift`
- Modify: `Sources/BtonCore/Engine.swift` (tick, after `reads` are complete and before dispatch; `Engine` holds one `CodeGraphBuilder`)
- Modify: `Sources/BtonCore/Worktrees.swift` only if `prepare(clone:branch:item:)` needs no change (it does not; it is reused with `item: "graph"`)
- Test: `Tests/BtonCoreTests/CodeGraphBuildAcceptanceTests.swift`

**Interfaces:**
- Consumes: Task 2's `store`, `link`, `marker`, `writeMarker`; `Worktrees.prepare(clone:branch:item:ghPath:runner:fresh:note:)`, `Worktrees.tip(of:clone:ghPath:runner:)`.
- Produces:
  - `public actor CodeGraphBuilder { init(home: BtonHome, runner: ProcessRunner = .init(), log: @escaping @Sendable (String) -> Void) }`
  - `func refresh(repo: WatchedRepo, branch: String, python: String?, ghPath: String) async` : returns at once; starts a build task when the repo has a clone, `buildsGraph`, no build runs for it, and the fetched tip differs from the marker; logs one line `graph <slug>: <reason>` when it skips because Python is missing (once per changed reason per repo, remembered in the actor).
  - `static let buildTimeout: Duration = .seconds(1800)`, `static let niceness = 10`, `static let script: String` (the Python one-liner from Global Constraints).
  - `func isBuilding(_ slug: String) -> Bool` for tests.
  - `func waitForBuilds() async` for tests: awaits every running task.

- [ ] **Step 1: Write the failing tests**

The tests use a real git fixture (`GitFixtureCopies`, a clone with an `origin`), `BTON_HOME` in a temp dir, and a fake Python: an executable shell script written by the test whose behaviour is chosen by the test (writes `graph.json` into `graphify-out/` and exits 0; or sleeps; or writes a partial `graph.json` and exits 1). `ghPath` is `/usr/bin/git`'s neighbour as other worktree tests pass it.

```swift
@Test(ProcessBound()) func buildsAtTipAndWritesMarker() async throws {
    let f = try await GraphFixture.make(python: .succeeds)
    await f.builder.refresh(repo: f.repo, branch: "main", python: f.python, ghPath: f.gh)
    await f.builder.waitForBuilds()
    #expect(CodeGraph.isBuilt(f.store))
    #expect(CodeGraph.marker(in: f.store)?.commit == f.tip)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.clone.appendingPathComponent("graphify-out").path) == f.store.path)
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: f.clone.appendingPathComponent(".worktrees/bton-graph/graphify-out").path) == f.store.path)
}
@Test(ProcessBound()) func unchangedTipDoesNotRebuild() async throws {
    let f = try await GraphFixture.make(python: .succeeds)
    await f.builder.refresh(...); await f.builder.waitForBuilds()
    let runs = f.pythonRuns()  // the fake appends a line to a counter file per run
    await f.builder.refresh(...); await f.builder.waitForBuilds()
    #expect(f.pythonRuns() == runs)
}
@Test(ProcessBound()) func secondRefreshWhileBuildingStartsNothing() async throws {
    let f = try await GraphFixture.make(python: .sleeps(seconds: 3))
    await f.builder.refresh(...)
    #expect(await f.builder.isBuilding(f.repo.slug))
    await f.builder.refresh(...)
    await f.builder.waitForBuilds()
    #expect(f.pythonRuns() == 1)
}
@Test(ProcessBound()) func failedBuildKeepsPreviousMarker() async throws {
    let f = try await GraphFixture.make(python: .succeeds)
    await f.builder.refresh(...); await f.builder.waitForBuilds()
    let first = CodeGraph.marker(in: f.store)?.commit
    try f.commitOnOrigin("second")          // tip moves
    f.setPython(.partialThenFails)
    await f.builder.refresh(...); await f.builder.waitForBuilds()
    #expect(CodeGraph.marker(in: f.store)?.commit == first)
    #expect(f.log.contains { $0.hasPrefix("graph \(f.repo.slug): build failed") })
}
@Test(ProcessBound()) func missingPythonLogsOnceAndSkips() async throws {
    let f = try await GraphFixture.make(python: .succeeds)
    await f.builder.refresh(repo: f.repo, branch: "main", python: nil, ghPath: f.gh)
    await f.builder.refresh(repo: f.repo, branch: "main", python: nil, ghPath: f.gh)
    #expect(f.log.filter { $0 == "graph \(f.repo.slug): graphify's Python not found; set it in Settings > Agents" }.count == 1)
    #expect(!CodeGraph.isBuilt(f.store))
}
@Test(ProcessBound()) func switchOffBuildsNothing() async throws {
    let f = try await GraphFixture.make(python: .succeeds, codeGraph: false)
    await f.builder.refresh(...); await f.builder.waitForBuilds()
    #expect(f.pythonRuns() == 0)
}
@Test func engineTickStartsBuilderForSwitchedOnRepos() async throws { /* Engine with the fake GitHub used in DispatchAcceptanceTests, one repo with codeGraph on, a fake python; after tick(dispatching: false) and waitForBuilds, the store is built */ }
```

- [ ] **Step 2: Run to verify they fail**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphBuildAcceptanceTests`
Expected: compile errors on `CodeGraphBuilder`.

- [ ] **Step 3: Implement `CodeGraphBuilder`**

State: `running: [String: Task<Void, Never>]`, `lastReason: [String: String]`, keyed by lowercased slug. `refresh`: guard `repo.buildsGraph`, `repo.path`; python nil: log the reason once, return; running: return; otherwise start a task: `Worktrees.prepare(clone:branch:item: "graph", fresh: false)` (fetches and detaches at the tip), `tip = Worktrees.tip(of:)`; marker commit equal to tip: finish; `link(into: clone)` and `link(into: worktree)`, each outcome `moved` or `kept` logged; run `/usr/bin/nice` with `["-n", "10", python, "-c", script]` in the worktree, timeout `buildTimeout`, `environment: ["GIT_TERMINAL_PROMPT": "0"]`; status 0 and `isBuilt(store)`: `writeMarker(commit: tip)` and log `graph <slug>: built at <tip prefix 8> in <seconds>s`; otherwise log `graph <slug>: build failed (exit <n>): <stderr last 200>` or `... timed out after 30 minutes`. The task removes itself from `running` in a `defer`.

- [ ] **Step 4: Wire the Engine**

`Engine` gets `let graphs: CodeGraphBuilder` made in `init` with the engine's `home`, `log`. In `tick`, after the `for repo in config.repos` read loop and before `guard dispatching`, for each `read` whose repo `buildsGraph`: `await graphs.refresh(repo: read.repo, branch: read.repo.branch ?? read.defaultBranch, python: CodeGraph.python(configured: config.graphifyPython), ghPath: github.ghPath)`. Add `public func waitForGraphBuilds() async` on Engine for the test.

- [ ] **Step 5: Run the tests**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphBuildAcceptanceTests`
Expected: 7 passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/BtonCore/CodeGraphBuilder.swift Sources/BtonCore/Engine.swift Tests/BtonCoreTests/CodeGraphBuildAcceptanceTests.swift
git commit -m "feat(graph): build the repo's graph at the default branch tip after a sync"
```

### Task 4: Jobs get the link and the agent the line

**Files:**
- Modify: `Sources/BtonCore/Dispatcher.swift` (`useRepos`, `run` after `job.worktree = worktree.path`, the `instructions` assembly)
- Modify: `Sources/BtonCore/CodeGraph.swift` (`instructionLine`)
- Test: `Tests/BtonCoreTests/CodeGraphDispatchAcceptanceTests.swift`

**Interfaces:**
- Consumes: Task 2's `store`, `isBuilt`, `link`, `marker`.
- Produces:
  - `Dispatcher.graphStores: [String: URL]` (lowercased slug to store) set in `useRepos` for repos with `buildsGraph`, from `CodeGraph.store(for:home:)`; the Dispatcher gets `home: BtonHome` in `init` (Engine passes its own).
  - `CodeGraph.instructionLine(base: String, marker: Marker) -> String` = `"Code graph: graphify-out/ in this checkout is graphify's graph of \(base) at \(marker.commit.prefix(8)); this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree."`

- [ ] **Step 1: Write the failing tests**

```swift
@Test func instructionLineNamesBaseAndCommit() {
    let line = CodeGraph.instructionLine(base: "develop", marker: .init(commit: "0123456789ab", at: .now))
    #expect(line == "Code graph: graphify-out/ in this checkout is graphify's graph of develop at 01234567; this branch's own changes may not be in it. Run graphify-src \"<question>\" before searching the tree.")
}
@Test(ProcessBound()) func jobWorktreeGetsLinkAndClaudeGetsLine() async throws {
    // DispatchAcceptanceTests' fixture: a PR, a fake claude recording its argv; the repo has codeGraph on and a built store with a marker.
    ...
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: worktree.appendingPathComponent("graphify-out").path) == store.path)
    #expect(recordedSystemPrompt.contains("Code graph: graphify-out/ in this checkout is graphify's graph of main at "))
}
@Test(ProcessBound()) func unbuiltStoreAddsNothing() async throws { /* codeGraph on, no graph.json: no link, no line, job runs */ }
@Test(ProcessBound()) func occupiedNameNeverFailsTheJob() async throws {
    /* the fixture's own worktree script leaves a file named graphify-out in the tree; the job still starts, the log has one note "graphify-out kept: ..." */
}
@Test(ProcessBound()) func codexGetsNoLine() async throws { /* a codex template: the link is made, argv has no "Code graph:" */ }
```

- [ ] **Step 2: Run to verify they fail**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphDispatchAcceptanceTests`
Expected: compile errors on `instructionLine`, `graphStores`.

- [ ] **Step 3: Implement**

In `run`, right after `jobs.note(job.id, "worktree \(worktree.path)")`: `if let store = graphStores[candidate.key.repo.lowercased()], CodeGraph.isBuilt(store), let marker = CodeGraph.marker(in: store)`: `link(into: worktree, store:)` inside a `do`, a thrown error or a `.kept(reason)` becomes `jobs.note(job.id, "graphify-out kept: \(reason)")` and the line is still added when the link already exists; keep `graphLine = CodeGraph.instructionLine(base: base, marker: marker)` and, where `instructions` is assembled for a Claude agent, join it after the team instructions with `"\n\n"`. Codex and other CLIs get the link only.

- [ ] **Step 4: Run the tests**

Run: `rx -- swift test --scratch-path .build-rx --filter CodeGraphDispatchAcceptanceTests`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/BtonCore/Dispatcher.swift Sources/BtonCore/CodeGraph.swift Tests/BtonCoreTests/CodeGraphDispatchAcceptanceTests.swift
git commit -m "feat(graph): jobs get the repo's graph linked in and Claude is told to query it"
```

### Task 5: Docs and log

**Files:**
- Modify: `docs/ARCHITECTURE.md` (a "Code graph" subsection under Dispatch; `graphs/` under Data on disk)
- Modify: `README.md` ("What you get": one paragraph)
- Modify: `LOG.md` (Unreleased entry)
- Modify: `docs/superpowers/specs/2026-10-27-repo-features-design.md` (piece 1: no incremental update in PR worktrees, the reason; the Python path replaces the binary path)

- [ ] **Step 1: Write the entries**

LOG.md, under Unreleased, bold lead: **Agents get a code graph of each repo.** One paragraph: the switch, where the graph lives, what the agent is told, the Python setting.

- [ ] **Step 2: Full suite**

Run: `rx -- swift test --scratch-path .build-rx`
Expected: every test passes; note the count.

- [ ] **Step 3: Commit**

```bash
git add docs/ARCHITECTURE.md README.md LOG.md docs/superpowers/specs/2026-10-27-repo-features-design.md
git commit -m "docs: the code graph store"
```
