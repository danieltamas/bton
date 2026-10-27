# Required-check gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A merge starts only when GitHub reports a named check run `completed`/`success` on the exact head, with a base that has not moved past what the run tested.

**Architecture:** A pure judge (`RequiredCheck.judge`) over `Evidence` values; one fetch (`GitHubClient.requiredCheckEvidence`) builds the evidence from three `gh api` reads; two call sites use them: planning in `Engine.tick` (a hold: no job, reason in `Snapshot.waiting`) and `Dispatcher.dispatch` (a refusal: fails the job, fail closed).

**Tech Stack:** Swift 6, swift-testing, `gh` CLI via `ProcessRunner`.

**Spec:** `docs/superpowers/specs/2026-10-27-required-check-gate-design.md`

## Global Constraints

- Tests are written by Codex (or the user) from the spec, before the task's code, and the executor never edits them (writer is not the test author). A red test is fixed in `Sources`.
- No network in unit tests; the one `BTON_SANDBOX` test is gated like `LeaseAcceptanceTests`.
- Each `gh` read has a 60 s limit (`GitHubClient.gh` already sets it); any failure is the verdict `unavailable`.
- Files at most 500 lines; English identifiers; plain characters only in comments and docs (no dashes other than `-`, no curly quotes).
- Conventional Commits, no co-author trailer. Commit only when the user asks; stage by path.
- `BTON_PRESSED` never skips the gate.

## Review Focus

- A PR whose workflow never publishes the check (path filters): `missing`, with the reason text naming the check, never a pass.
- `mergeable_state` `unknown` right after a push: not `behind`, so no hold on it; the head and `started_at` rules decide.
- A check name with spaces or `/` (`CI / gateway`): URL-encoded in the read; matches exactly.
- A re-run that fails after an earlier success on the same head: `failed` (the latest run counts).
- More than 100 runs on a head: only the named check is read (`check_name`), so the page limit cannot hide it.

## File structure

- Modify `Sources/BtonCore/Flow.swift`: `Checks.requiredCheck`, validation in `Flow.load`.
- Create `Sources/BtonCore/RequiredCheck.swift`: `RequiredCheck`, `Evidence`, `Verdict`, `judge`, `reason`.
- Modify `Sources/BtonCore/GitHub.swift`: `requiredCheckEvidence`, static decode helpers.
- Modify `Sources/BtonCore/Dispatcher.swift` (dispatch hook), `Sources/BtonCore/Engine.swift` (planning hook).
- Tests: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift` (new, Codex), additions to `FlowAcceptanceTests.swift`.
- Docs: `docs/FLOW.md`, `docs/ARCHITECTURE.md`, `docs/MERGE-SPEED.md`, `LOG.md` at release.

---

### Task 1: The `requiredCheck` field

**Files:**
- Modify: `Sources/BtonCore/Flow.swift` (`Checks`, `Flow.load`)
- Test: `Tests/BtonCoreTests/FlowAcceptanceTests.swift`

**Interfaces:**
- Produces: `public struct RequiredCheck: Decodable, Sendable, Equatable { public let name: String }` declared in Task 2's file; here only `Checks.requiredCheck: RequiredCheck?`.

- [ ] **Step 1: Tests (Codex)**: `flowWithoutRequiredCheckParsesUnchanged`; `requiredCheckNameParses` (`"checks": {..., "requiredCheck": {"name": "gateway-ci"}}` gives `flow.checks?.requiredCheck?.name == "gateway-ci"`); `requiredCheckStringIsInvalid`, `requiredCheckWithoutNameIsInvalid`, `requiredCheckEmptyNameIsInvalid`: each `Flow.load` returns `.invalid`.
- [ ] **Step 2: Run** `swift test --scratch-path $TMPDIR/bb --filter requiredCheck`. Expected: FAIL (field unknown).
- [ ] **Step 3: Add** `public let requiredCheck: RequiredCheck?` to `Checks` (decoded with `decodeIfPresent`, keeping `beforeSession` and `beforeMerge` required as today) and an `.invalid("checks.requiredCheck.name must not be empty")` branch in `Flow.load` for an empty or whitespace-only name.
- [ ] **Step 4: Run** the same filter. Expected: PASS. Run `swift test --scratch-path $TMPDIR/bb --filter Flow` for regressions.

### Task 2: The judge

**Files:**
- Create: `Sources/BtonCore/RequiredCheck.swift`
- Test: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift`

**Interfaces:**
- Produces:
  - `public struct RequiredCheck: Decodable, Sendable, Equatable { public let name: String }`
  - `public struct Evidence: Sendable, Equatable { head: String, state: String, mergeableState: String, runs: [Run], baseRef: String, baseTip: String, baseTipDate: Date }` with `struct Run { id: Int, status: String, conclusion: String?, startedAt: Date? }`
  - `public enum Verdict: Sendable, Equatable { case pass, unavailable(String), notOpen, headMoved, behind, missing, pending, failed(String), stale }`
  - `RequiredCheck.judge(_ evidence: Evidence, expectedHead: String) -> Verdict`
  - `RequiredCheck.reason(_ verdict: Verdict, name: String, head: String) -> String`

- [ ] **Step 1: Tests (Codex)**, each calling `judge` with values, one per spec acceptance item 1-9: `onePassingRun`, `twoAppsBothSuccessPass`, `everyNonTerminalStatusIsPending` (`queued`, `in_progress`, `waiting`, `requested`, `pending`), `everyNonSuccessConclusionFails` (`failure`, `cancelled`, `skipped`, `timed_out`, `neutral`, `action_required`, `stale`, `startup_failure`, `"mystery"`), `noRunIsMissing`, `successPlusFailureFails`, `failureBesidePendingIsPending`, `behindBeatsGreen`, `runStartedBeforeBaseTipIsStale`, `runWithoutStartedAtIsStale`, `closedPRIsNotOpen`, `otherHeadIsHeadMoved`. Plus `reasonTexts`: `reason(.pending, name: "ci", head: "1f3a9c2...")` is `waiting for ci on 1f3a9c2: queued`, `.failed("timed_out")` contains `failed (timed_out)`, `.missing` contains `not run on this head`, `.behind` contains `behind its base`, `.unavailable` contains `GitHub did not answer`.
- [ ] **Step 2: Run** `--filter RequiredCheckAcceptance`. Expected: FAIL (types missing).
- [ ] **Step 3: Implement** the types and `judge` in the spec's table order 1-9 (`unavailable` is produced by the fetch, not `judge`, so `judge` starts at `notOpen`); `pending` is any status not `completed`; `stale` is `startedAt == nil || startedAt < baseTipDate`.
- [ ] **Step 4: Run** the filter. Expected: PASS.

### Task 3: The evidence fetch

**Files:**
- Modify: `Sources/BtonCore/GitHub.swift`
- Test: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift` (additions)

**Interfaces:**
- Consumes: `Evidence`, `GitHubClient.gh(_:)`.
- Produces: `public func requiredCheckEvidence(repo: String, number: Int, name: String) async throws -> Evidence` (throws `Failure.ghFailed` or a decode error; callers map any throw to `Verdict.unavailable`), and `static func decodeEvidence(pull: Data, runs: Data, base: Data) throws -> Evidence` for tests.

- [ ] **Step 1: Tests (Codex)**: `decodeEvidenceReadsThreeBodies` (fixtures from real `gh api` output); `undecodableBodyThrowsForEachOfThree`; with a stub `gh` script as in `CheckTimeLimitAcceptanceTests`: `nonZeroStatusOnEachReadThrows` (three cases), `nameWithSpacesAndSlashIsEncoded` (the stub records its argv; the path contains `check_name=CI%20%2F%20gateway`).
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** the three reads from the spec ("Evidence read"), `check_name` percent-encoded with `urlQueryAllowed` minus `/` and `&`, `filter=latest&per_page=100`; run `completed_at` is not needed.
- [ ] **Step 4: Run** the filter. Expected: PASS.

### Task 4: Dispatch hook (authoritative refusal)

**Files:**
- Modify: `Sources/BtonCore/Dispatcher.swift` (inside `dispatch`, before `runChecks` and again beside `headRefusal`)
- Test: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift` (additions)

**Interfaces:**
- Consumes: `RequiredCheck.judge`, `RequiredCheck.reason`, `GitHubClient.requiredCheckEvidence`, `Flow.checks?.requiredCheck`.
- Produces: `func requiredCheckRefusal(_ check: RequiredCheck, repo: String, pr: Int, head: String, job: UUID) async -> String?` (nil on pass; logs the per-run line and the base/head it judged on).

- [ ] **Step 1: Tests (Codex)**, with a stub `gh` and a real `JobStore` in a temp home: `failingGateFailsJobBeforeAnyCheck` (no `beforeMerge` argv ran, no merge command ran, job `failed` with the reason in `detail`), `gateThatTurnsRedBeforeTheCommandFailsTheJob`, `passingGateRunsChecksThenCommand` (log has `required check ci: run 77 success at head ...`), `flowWithoutRequiredCheckMakesNoGateRead` (the stub saw no `check-runs` request), `pressedMergeStillGated` (`candidate.pressed` true, gate red, job failed).
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement** the hook for `candidate.pr != nil && candidate.agent == nil && !candidate.skipsChecks` (the merge move), any throw from the fetch is `.unavailable`.
- [ ] **Step 4: Run** the filter plus `--filter Dispatch`. Expected: PASS.

### Task 5: Planning hook (hold, reason in the row)

**Files:**
- Modify: `Sources/BtonCore/Engine.swift` (candidate stage in `tick`; extend the `waiting` computation from 0.8.3)
- Test: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift` (additions)

**Interfaces:**
- Consumes: Task 2 and 3 symbols.
- Produces: `static func gateHolds(_ candidates: [DispatchCandidate], flow: Flow, evidence: ...) ` is not required; the hook may be inline. Observable behavior only: a held merge candidate is absent from this sync's `pending`, and `Snapshot.waiting[pick]` is `RequiredCheck.reason(...)`.

- [ ] **Step 1: Tests (Codex)**: `heldMergeStartsNoJobAndShowsReason` (check `queued`: no job file, no `gh` write call, `snapshot.waiting` has `waiting for ci on <sha7>: queued`); `nextSyncStartsItOnceGreen`; `pressedMergeIsHeldToo` (pick in `next`, still held, still shown).
- [ ] **Step 2: Run** the filter. Expected: FAIL.
- [ ] **Step 3: Implement**: after candidates are built per repo, for each merge candidate of a flow with `requiredCheck`, fetch and judge; drop non-pass from `candidates`, store the reason keyed by the pick, and merge it into the `waiting` dictionary ahead of the generic reasons.
- [ ] **Step 4: Run** the filter plus `swift test --scratch-path $TMPDIR/bb` (full suite). Expected: all pass.

### Task 6: Sandbox test, docs

**Files:**
- Test: `Tests/BtonCoreTests/RequiredCheckAcceptanceTests.swift` (a `.enabled(if: BTON_SANDBOX)` suite)
- Modify: `docs/FLOW.md`, `docs/ARCHITECTURE.md`, `docs/MERGE-SPEED.md`

- [ ] **Step 1: Sandbox test (Codex)** `realCheckRunReadsBack` against the sandbox repo from `BTON_SANDBOX`: a real PR head with a completed check run reads back as `pass`; a head without the named check as `missing`.
- [ ] **Step 2: Docs**: FLOW.md gets the field, the verdict table, hold versus refusal and "a press does not skip it"; ARCHITECTURE.md the two evaluation points and the new unit; MERGE-SPEED.md item 1 marked done with the lexito hand-off (add `requiredCheck`, then drop `check.sh --fast` from `beforeMerge` once both agreed on real PRs).
- [ ] **Step 3: Run** the full suite. Expected: all pass (sandbox suite skipped without `BTON_SANDBOX`).
- [ ] **Step 4: Release** with `/release` as a minor (new flow field), LOG entry written for people who use Bton.

## Self-review

- Spec coverage: schema (T1), judge and table (T2), fetch and `unavailable` (T3), dispatch refusal and log line (T4), planning hold and reason (T5), acceptance items 1-16 (T2 items 1-9, T3 item 10, T5 item 11, T4 items 12, 13, 15, T1 item 14, T6 item 16), docs (T6).
- Type consistency: `Evidence`, `Verdict`, `RequiredCheck.judge(_:expectedHead:)`, `RequiredCheck.reason(_:name:head:)`, `requiredCheckEvidence(repo:number:name:)` are named the same in every task.
