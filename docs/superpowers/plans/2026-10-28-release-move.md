# Release Move Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With a `release` section in its flow, a repo's develop branch reaches main through a release PR that Bton opens when due, checks, and merges on the owner's press or on its own when the repo starts its moves.

**Architecture:** Pure code first: `ReleaseStanding` decides due or blocked from the repo's `FeatureReport`, its open PRs and the clock; `ReleaseNotes` writes the PR title and body from the registry. The engine opens the PR itself (one `gh pr create`, no job) and, once a release PR is open, plans a command candidate on it (move `release`, the flow's `release.checks` at the PR's head, the merge argv in a trusted worktree of `to`), reusing the Dispatcher's command path with two per-candidate overrides (`checks`, `commandBase`). The repo page shows the standing and, for `who`, floats the Release action; the footer turns amber when due.

**Tech Stack:** Swift 6, BtonCore, SwiftUI, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-27-repo-features-design.md`, section 3 (and the Testing section).

## Global Constraints

- The release PR is the open PR in the repo with `headRef == release.from` and `baseRef == release.to`, whoever opened it. At most one; the oldest by number counts when there are several.
- Predicates (`release.when`, first match makes the release due, each with a reason string for the UI):
  `ahead_commits:N` -> `report.aheadCommits >= N`, reason `"<n> commits ahead"`;
  `ahead_days:N` -> `now - report.unreleasedSince >= N days`, reason `"<d> days ahead"`;
  `features_waiting:N` -> `FeaturePage.count(.shipsNext, report:) >= N`, reason `"<n> features waiting"`.
  An unparseable entry (unknown name, `N` not a positive integer) makes the flow invalid: `release.when: <entry> is not a predicate`.
- Blockers (`release.blockedBy`, any match blocks, each with a reason):
  `pr_in_review_on_paths:<glob>` -> an open, non-draft PR into `release.from`, other than the release PR, with a changed file matching the glob (`PathGlob.matches`), reason `"PR #<n> touches <glob>"`; the glob must pass `PathGlob.isValid`, else the flow is invalid: `release.blockedBy: <entry> is not a blocker`.
  `release_pr_open` is implied and only blocks opening a second PR, never the merge of the open one; an explicit `release_pr_open` entry is accepted and means the same.
- `ReleaseStanding` (Sendable, Equatable): `.open(number: Int, due: Bool)` when a release PR exists, `.blocked(String)`, `.due(String)`, `.waiting` (none of `when` matches), `.unknown` (the report has no registry or the facts failed). Order: open > blocked > due > waiting.
- The PR: title `Release <from> -> <to>: <n> feature<s>`; body line 1 `Release notes`, then per area (registry order, areas with no feature skipped) a `## <area name>` heading and one `- <feature name> (#<pr>, #<pr>)` line per feature whose standing is `inDevelop` (merged PR numbers from `FeatureStanding.changes`, ascending), then `Opened by Bton.` as the last line. Zero features: one line `No registry features in this release.` between the header and the footer. Feature and area names come from the registry file (untrusted): they are PR body text only, never a prompt or argv for a shell.
- Opening: the engine, for a repo whose `release.who` is the viewer (case-insensitive), with no release PR, standing `.due`, and `pressed || repo.startsMoves`: `GitHubClient.createPullRequest(repo:base:head:title:bodyFile:)` = `gh pr create --repo <repo> --base <to> --head <from> --title <title> --body-file <path>`. Once per sync per repo; a failure is logged (`release: could not open the PR: <error>`), not retried within the sync. `pressed` is `next` holding `<repo>#release`.
- Merging: once a release PR exists, for `who`, a `DispatchCandidate`: target `.pullRequest(pr)`, move `Move(name: "release", owner: me, ownerFromRotation: false, tier: "", hasDispatch: true)`, key `JobKey(repo:, item: "pr-<n>", move: "release", head: pr.headSha)`, agent nil, `command` = `["gh", "pr", "merge", "<n>", "--repo", repo, "--merge", "--match-head-commit", "<head>"]` for `merge-commit` (default) or `["git", "push", "origin", "<head>:refs/heads/<to>"]` for `fast-forward`, `postComment false`, `timeout` = `release.timeoutMinutes` minutes (default 40), `checks` = `release.checks` (nil or empty runs none), `commandBase` = `to`, `pressed`. Admitted when not blocked, no running `release` job of the repo, the PR is not a draft, and `pressed || (repo.startsMoves && standing is .open(due: true))`.
- Dispatcher: `candidate.checks` replaces the flow's `beforeMerge`/`beforeSession` when set; `candidate.commandBase` replaces `flow.base` for the trusted command worktree and the checks memo when set. The PR worktree (the checks' cwd) is the release PR's head, which is the `from` tip. `headRefusal` runs as for every command on a PR. A check that cannot start throws and fails the job (already so).
- The release PR gets no flow move (`pr.move` nil for it), so rotation, auto-take and the flow's moves leave it alone; the PR row shows its release state instead.
- `FeatureReport.aheadCommits: Int?` = count of commits on `origin/<from>` that `origin/<to>` lacks (from the `git log` FeatureGit already runs); `FeatureReport.release: ReleaseStanding?` set by the engine each tick (nil without a `release` section).
- UI: the repo page header summary and the footer line read `report.release`: `.due(reason)` -> amber text `release due: <reason>`; `.blocked(reason)` -> `release blocked: <reason>`; `.open(n, _)` -> `release PR #<n> open`. The Release action floats bottom right on the repo page (`.floatingAction(title: "Release", symbol: "shippingbox")`) only when `me == who` and the standing is `.due` or `.open`; it calls `store.runNext(repo:, item: "release")`; while a `release` job of the repo runs it shows `StartingLabel`/the job instead (as the registry button does). Everyone else sees the state only.
- Files <= 500 lines: new code goes in `Release.swift`, `ReleaseNotes.swift`, `EngineRelease.swift`, `ReleasePage.swift` (app), not in Engine.swift, Dispatcher.swift or AppStore.swift beyond a line each.
- Plain ASCII in text for people.

## Review Focus

1. A pressed Release on a repo whose standing is `.waiting` (not due) still opens the PR: the press is the owner's decision; only blockers and checks stop it.
2. A second Mac of the same login: the open is idempotent (GitHub refuses a second PR on the same head and base, the error is logged); the merge is one job through the `pr-<n>` lease.
3. The merge argv pins the head: develop moving after the plan is refused by `headRefusal`, and a non-fast-forward push is rejected by git (fail closed, job failed, PR stays open with the log).
4. A `release.checks` entry that cannot start (missing binary) fails the job; nothing is merged.
5. Ten PRs merged into develop in a day with `ahead_commits:50` not yet met and `features_waiting:5` met: the release is due by the third predicate and the reason names the features, not the commits.

---

### Task 1: `ReleaseStanding` and the flow validation (BtonCore)

**Files:**
- Create: `Sources/BtonCore/Release.swift`
- Modify: `Sources/BtonCore/Flow.swift` (validation), `Sources/BtonCore/EngineFeatures.swift` and `FeatureGit.swift` (`aheadCommits`), `FeatureReport` (`aheadCommits`, `release`)
- Test: `Tests/BtonCoreTests/ReleaseAcceptanceTests.swift` (codex)

**Interfaces:**
- `public enum ReleaseStanding: Sendable, Equatable { case open(number: Int, due: Bool), blocked(String), due(String), waiting, unknown }`
- `public enum ReleasePredicate: Sendable, Equatable { case aheadCommits(Int), aheadDays(Int), featuresWaiting(Int); public init?(_ text: String) }`
- `public enum ReleaseBlocker: Sendable, Equatable { case prInReviewOnPaths(String), releasePROpen; public init?(_ text: String) }`
- `public enum Release { public static let move = "release"; public static let item = "release"; public static let defaultTimeoutMinutes = 40 }`
- `public static func Release.pullRequest(_ pullRequests: [PullRequest], release: Flow.Release) -> PullRequest?`
- `public static func Release.standing(release: Flow.Release, report: FeatureReport?, pullRequests: [PullRequest], now: Date) -> ReleaseStanding`
- `public static func Release.dueReason(release:report:now:) -> String?` and `blockedReason(release:pullRequests:) -> String?` (the pieces of `standing`)
- `FeatureGit.aheadCommits: Int?`, `FeatureReport.aheadCommits: Int?`, `FeatureReport.release: ReleaseStanding?`
- Flow validation: `release.when: <entry> is not a predicate`, `release.blockedBy: <entry> is not a blocker`, `release.timeoutMinutes must be positive`.

- [ ] Tests (codex) for predicate and blocker parsing (valid, unknown, zero, negative, non-numeric), the flow validation messages, `standing` ordering (open beats blocked beats due beats waiting; unknown without a registry), each predicate against a fixture report (at, just under and over N), `ahead_days` from `unreleasedSince`, `pr_in_review_on_paths` (draft PR ignored, PR into another base ignored, the release PR ignored, glob anchored per `PathGlob`), `pullRequest` picking the oldest.
- [ ] Implement. Commit `feat(release): the release standing, its predicates and blockers`.

### Task 2: `ReleaseNotes` (BtonCore)

**Files:**
- Create: `Sources/BtonCore/ReleaseNotes.swift`
- Test: in `ReleaseAcceptanceTests.swift` (codex)

**Interfaces:**
- `public enum ReleaseNotes { public static func title(release: Flow.Release, report: FeatureReport) -> String; public static func body(report: FeatureReport) -> String }`

- [ ] Tests (codex): title counts, body grouping by area in registry order, PR numbers ascending, features not `inDevelop` left out, closed features left out, an area with no feature skipped, the zero-feature line, the footer line, a feature name holding `{head}` or a backtick kept verbatim (body text only).
- [ ] Implement. Commit `feat(release): release notes from the registry`.

### Task 3: The Dispatcher's overrides and the release candidate (BtonCore)

**Files:**
- Modify: `Sources/BtonCore/Dispatch.swift` (`DispatchCandidate.checks: [[String]]?`, `commandBase: String?`), `Sources/BtonCore/Dispatcher.swift` (two uses), `Sources/BtonCore/GitHub.swift` (`createPullRequest`)
- Create: `Sources/BtonCore/EngineRelease.swift` (`extension Engine`: `releaseCandidate(...)`, `openRelease(...)`) and the static `Release.candidate(pr:release:repo:me:jobs:pullRequests:startsMoves:pressed:) -> DispatchCandidate?` in `Release.swift`
- Modify: `Sources/BtonCore/Engine.swift` (one call in the planning block, after the registry job; `pr.move` nil for the release PR at line 201)
- Test: `ReleaseAcceptanceTests.swift` candidate shape (codex); engine case over `StartMovesFixture` (codex): flow with `release` whose `who` is `owner`, a fake `gh pr create` case that records its arguments to a file and prints a URL, pressed via `engine.runNext(repo:item:"release", pressed: true)` -> the file holds `--base main --head develop` and a body file whose first line is `Release notes`; a second sync with the release PR in the fake listing and `startMoves` on -> a job with move `release` and item `pr-<n>` starts and the flow's `merge` command is not what runs (the argv is the release merge).

- [ ] Tests (codex).
- [ ] Implement. Commit `feat(release): the engine opens the release PR when due and merges it through the release job`.

### Task 4: The page and the footer (app)

**Files:**
- Create: `Sources/Bton/ReleasePage.swift` (`extension RepoPage { var releaseAction }`, `ReleaseLine` view for the summary)
- Modify: `Sources/Bton/RepoPage.swift` (summary line, `.floatingAction` on the list), `Sources/Bton/BranchStatusViews.swift` (footer amber text), `Sources/BtonCore/FeaturePage.swift` (`releaseLine(_ standing: ReleaseStanding) -> (text: String, amber: Bool)?`)
- Build: `swift build --scratch-path .build-rx`. Commit `feat(release): the page's Release action and the amber footer`.

### Task 5: Docs and evidence

- `docs/FLOW.md` release row: the predicate reasons, `release_pr_open` semantics, the merge argv per `merge` value; `LOG.md` Unreleased paragraph; `README.md` sentence. Commit `docs: the release move`.
- Full suite green; codex review, two fix rounds at most; `.ship/log.jsonl`; commit `chore(ship): evidence for the release move`.
