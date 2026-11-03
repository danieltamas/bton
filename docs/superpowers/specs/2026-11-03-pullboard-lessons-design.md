# Five lessons from Pullboard, in Bton's terms

Date: 2026-11-03. Branch `feat/lessons`, worktree `.worktrees/lessons`, from main 13335f5 (v0.33.0).

Pullboard (pullboard-dev/pullboard, inspected 2026-11-03, verdict REVIEW with 0 fails) keeps a
work board in SQLite with structured reject causes, a criterion frozen at claim, a refusal of a
check that already passes, flake quarantine and conflict-hotspot rulings. Bton's board is GitHub.
Each lesson below is restated as the Bton mechanism that carries it, with the end state a test
can observe. Nothing here softens a fail-closed check: `checks not green` stays a refusal whatever
a flake record says.

Order of commits (the owner's order): 0 handoff fix, 1 causes, 2 criterion, 3 proof, 4 flakes,
5 hotspots. One branch, one `## Unreleased` paragraph per commit.

## 0. `bton handoff` posts through stdin

Observed 2026-11-03 in a kazu session: `bton handoff danieltamas/kazu 637 --to ...` exited 3 with
"You don't have permission to save the file bton-handoff-....md in the folder T": the CLI wrote
the comment body to `FileManager.temporaryDirectory`, which an agent's sandbox cannot write.

- `ProcessRunner.run` takes `input: Data? = nil`; when set, the child's stdin is a pipe fed those
  bytes and closed; nil keeps the null device.
- `GitHubClient.gh(_:input:)` passes it on. `commentOnIssue(repo:number:body:)` posts with
  `--body-file -` and the body on stdin. `handOff` uses it and writes no file.
- The other posters (`comment`, `commentOnIssue(bodyFile:)`, `editIssueBody`, `createIssue`,
  `createPullRequest`, `editPullRequestBody`) run in the app, outside any sandbox, and keep their
  files; moving them is a later sweep, not this change.

Acceptance: `GitHubClient.handOff` against a fake `gh` that records its argv and stdin receives
`issue comment <n> --repo <repo> --body-file -` and the body on stdin; no file named
`bton-handoff-` exists in the temporary directory after the call.

## 1. Causes and repeats

Pullboard: every reject carries a cause key (`test:<file>::<title>`, `refusal:<CODE>`); a cause on
two items is a repeat the coordinator turns into a rule. Bton names many failures itself already
(`Supervision.knownAnswer` reads the structured detail prefixes); the new signal is the same cause
on a different item of the repo within a window.

`Sources/BtonCore/Causes.swift`:

- `public enum Cause`, `public static func key(for job: Job) -> String?`: nil unless the job
  failed and its detail starts with a prefix Bton wrote (an agent's or gh's text has no key).
  The table, first match wins:

  | detail | key |
  | --- | --- |
  | `check ` or `posting the check failure failed: check ` | `check:` + the text of the first backtick span (the argv as logged), e.g. `check:swift build` |
  | `checks not green: ` | `red:` + the check names (each entry's text before its last space: `gate failure` gives `gate`), sorted, joined with `,`; `more checks than were read` dropped |
  | `timed out` prefix or ` minutes and was stopped` suffix | `timeout` |
  | `DispatchPlanner.endedWithoutPushing` | `no-push` |
  | `agent exited ` | `agent-exit:` + the integer that follows, or `agent-exit` when none |
  | `lease lost` | `lease-lost` |
  | `posting the review failed` | `post-failed` |
  | `proves nothing: ` | `proves-nothing` |
  | `proof still red: ` | `proof-red` |
  | `proof: ` | `proof-failed` |
  | `environment: ` | `environment` |
  | anything else, or nil | nil |

- `public static let window: TimeInterval = 14 * 86400`.
- `public static func repeats(of job: Job, among jobs: [Job], now: Date = .now) -> [String]`: the
  distinct `key.item` values, sorted, of other failed jobs of the same repo (case-insensitive)
  with the same cause key, a different item, ended within `window` before `now`. Empty when the
  job has no key. The job's own item never counts, so a key that failed three times on one PR is
  `repeated` (existing flag), not recurring.
- `JobFlag.recurring`, raw value `recurring`, last in `allCases` (after `loggedOut`).
  `Watchdog.flags` adds it when `Cause.repeats(of:among:now: job.endedAt ?? .now)` is not empty.
  The Jobs row chip reads `recurring`; the notification carries it like the others.
- `Supervision`: the facts block gains two lines after `flags:`: `cause: <key or none>` and
  `recurring on: <items joined by ", " or none>`. `defaultPrompt` gains, before the verdict
  format: "A cause marked recurring failed the same way on other items of this repo: that is a
  setup problem, so prefer propose, and say which rule or check would catch it before the next
  run." `knownAnswer` is unchanged: a known failure keeps its answer whether or not it recurs.

Behavior change: `WatchdogAcceptanceTests.jobFlagsHaveStableCodableNames` lists the raw values;
`recurring` is appended to that list with this spec as the evidence.

Acceptance (`CausesAcceptanceTests`): the key table above row by row, including nil for `agent
exited 1 after: check x` (prefix decides, so `agent-exit:1`) and nil for free text; repeats
across items within and outside the window, same item excluded, case-insensitive repo; the flag
appears on a job whose cause failed on another item and not on one whose cause failed only on
its own item; `Supervision.candidate` on an enabled supervisor puts `cause:` and `recurring on:`
lines in the prompt.

## 2. The criterion freezes when the job starts

Pullboard: `pullboard show <id>` is the bar the work is judged against, frozen at claim. Bton's
implement agent reads the issue live; an edit mid-job moves the goal.

- `IssueIntake.criterionFile = "criterion.md"`, `IssueIntake.criterionLimit = 12_000` characters.
- `public static func criterion(for issue: OpenIssue, at: Date) -> String`: first line
  `# Issue #<n> as it stood on <yyyy-MM-dd HH:mm UTC>` (through `Day`), a blank line, the title,
  a blank line, the body. A body longer than the limit is cut at the limit and ends with a line
  `(cut at 12000 characters)`. Issue text is data: the file carries it as written, nothing is
  escaped or interpreted.
- `IssueIntake.criterionLine`: "The bar for this job is criterion.md in the scratch directory:
  the issue as it stood when the job started. An edit to the issue after that is not part of
  this job: mention it in the PR instead."
- `IssueIntake.candidate(...)` sets `attachments[criterionFile]` to the criterion at `now` and
  appends `"\n\n" + criterionLine` to the prompt. The attachment lands in the job's scratch
  directory like `PREvidence.file` does (`Dispatcher.attach`), so the record outlives the issue.
- Gap, named: the review move's evidence (`PREvidence`) does not carry the frozen text; a
  reviewer still reads the issue live. Carrying it needs the PR-to-implement-job link in the
  evidence and is a later change.

Acceptance (`CriterionAcceptanceTests`): the attachment holds the header with the number and
stamp, the title and the body; a long body is cut with the marker and the attachment is under
the limit plus the header; the prompt ends with `criterionLine`; a body with `{base}` in it
reaches the file unfilled (the attachment is never run through `fill`).

## 3. Proof: a check that already passes proves nothing

Pullboard refuses a claim whose check already passes on main (`CRITERION_PROVES_NOTHING`), and
accepts only when the check fails before and passes after. In Bton a dispatch rule or the intake
may name `proof`: argv run in the worktree before the agent, that must fail, and after a push,
that must pass.

- `DispatchRule.proof: [[String]]?` and `Intake.proof: [[String]]?`. Flow validation refuses an
  empty argv: `dispatch.<move>.proof[<i>]: empty` / `intake.proof[<i>]: empty`.
- `DispatchCandidate.proof: [[String]]` (default empty), filled with the move's placeholders:
  PR moves through `DispatchPlanner.fill(_:repo:number:head:base:issue:tier:redChecks:)`, implement
  through the intake's `{repo} {issue} {base} {type}` values.
- `public enum Proof` (`Sources/BtonCore/Proof.swift`):
  - `static func beforeDetail(_ argv: [String], status: Int32, head: String) -> String?`: status 0
    gives `proves nothing: \`<argv>\` already passes on <head prefix 7>`; any other status nil.
  - `static func afterDetail(_ argv: [String], status: Int32) -> String?`: status 0 nil; else
    `proof still red: \`<argv>\` exited <status>`.
  - `static func unrunDetail(_ argv: [String], reason: String) -> String`: `proof: \`<argv>\`
    <reason>` (a timeout, an executable not found).
- Dispatcher, before the agent, after the checks: each proof argv runs through `runLogged` in
  the worktree with the move's environment and timeout. Three outcomes: exit 0 ends the job
  failed with `beforeDetail`, nothing dispatched; a thrown run (timeout, not found) ends it
  failed with `unrunDetail`, never read as red; a non-zero exit is noted
  (`proof \`<argv>\` exited <n> before the agent`) and the move goes on.
- After the agent, when the move's outcome is a success and the job carries proof: each argv runs
  again in the same worktree (the agent's pushed tree); a non-zero exit turns the outcome into
  failed with `afterDetail`. The PR's new head gets its own move, which runs proof before the
  agent again, so a red proof after a push loops back by itself.
- `Supervision.knownAnswer`: `proves nothing: ` gives `.escalate` "the proof command passes
  before the work: nothing shows the problem; sharpen the issue or the findings, then press
  Retry"; `proof still red: ` gives `.none` "the agent pushed but the proof still fails: the new
  head gets its own move"; `proof: ` gives `.escalate` "the proof command could not run on this
  Mac: fix what the detail names, then press Retry".
- `bton moves <repo> --flow` lists a move's proof argv under its dispatch line.
- Read before shipping: kazu's `fix` rule runs `git merge-tree` as its session check and no
  suite, so a `proof` naming the suite does not contradict a check.

Acceptance (`ProofAcceptanceTests`): flow decoding of `proof` on a dispatch rule and on intake,
the empty-argv refusal, the candidate's filled proof argv for a PR move and for implement, the
three `Proof` detail functions, the three `knownAnswer` rows, and the dispatcher: with a fake
agent and a proof script that exits 0 the job ends failed with `proves nothing` and the agent
never starts; with a script that exits 1 before and 0 after, the job succeeds; with a script
that exits 1 both times, the job ends `proof still red`.

## 4. Flaky checks

Pullboard: a test with two verdicts on one tree is quarantined the same day and its owner gets an
item. Bton's unit is a CI check on a head: the same check name on the same head sha read as
`failure` on one tick and `success` on a later one, with no push between, is a flake.

- `Sources/BtonCore/Flakes.swift`: `public struct Flake: Codable, Hashable, Sendable { repo,
  check, number, head, at }`; `public struct FlakeStore` at `<home>/flakes.json`: `load(home:)`
  (missing or unreadable gives empty, never throws), `save(home:)`, `pruned(now:)` keeps 30 days
  and at most 500 records, newest first.
- `public static func flips(previous: [String: [String: CheckResult.State]], pullRequests:
  [PullRequest], repo: String, now: Date) -> [Flake]`: `previous` is head sha to check name to
  state from the last tick; a PR whose head is in it, with a check now `success` that was
  `failure`, yields one Flake per such check. `public static func states(_ pullRequests:
  [PullRequest]) -> [String: [String: CheckResult.State]]` is what the engine keeps per repo
  between ticks (memory only: a restart loses one comparison).
- `public static func known(_ store: FlakeStore, repo: String, now: Date) -> [String: Int]`:
  check name to the number of distinct heads it flipped on within 14 days.
  `isFlaky` is a count of at least 2.
- `public static func label(for check: String) -> String`: `flaky:` + the check name cut to 43
  characters, with any character outside letters, digits, `-`, `_`, `.`, `/`, ` ` replaced by `-`.
- `public static func line(redChecks: [String], known: [String: Int]) -> String?`: for the red
  checks that are flaky: "Check <name> turned red then green on the same commit <n> times in 14
  days (and <name2>, <m>): rerun the failed run before changing code (`gh run rerun <id>
  --failed`); change code only for a failure you reproduce." nil when none.
- Engine, each tick per repo with PR moves: compute flips against the kept states, append them
  to the store (saved once per tick when it changed), then for each flip: `addLabel(label(for:))`
  on the PR after `GitHubClient.ensureLabel` (`gh label create <name> --repo <repo> --color
  e4e669 --description "a check that turned red then green on the same commit" --force`, once
  per label per process), a log line, and a notification "Flaky check <name> on #<n>: red then
  green on the same commit" with the existing notification path. A label or notification
  failure is a log line, never a job's failure.
- Dispatcher, before the agent of a PR move whose `move.redChecks` holds a flaky check: the
  prompt gets `Flakes.line(...)` through `Supervision.adding`, so the steering note stays last.
- Nothing else reads the store: `checks_red`, `checks_green` and the merge's `checks not green`
  are untouched.

Acceptance (`FlakesAcceptanceTests`): `flips` yields a flake for failure to success on the same
head, none for success to failure, none for a new head, none for a check missing before;
`known` counts distinct heads and drops records older than 14 days; `label(for:)` cuts and
replaces; `line` names only the flaky red checks and is nil otherwise; the store survives a save
and load round trip, prunes by age and count, and loads empty from a missing file.

## 5. Conflict hotspots

Pullboard counts which files caused conflict reopens and drafts "consider splitting this file"
rulings. Bton knows every conflict: the `resolve` move runs on a PR that conflicts with its base.

- `Job.conflicts: [String]?`: the paths in conflict between the PR head and its base when the
  resolve job started.
- `Worktrees.conflicts(in worktree: URL, base: String, ghPath: String, runner: ProcessRunner)
  async -> [String]?`: `git merge-tree --write-tree --name-only <base> HEAD`; exit 1 gives the
  conflicted paths, exit 0 an empty list, anything else nil (recorded as nothing, noted on the
  job). `static func conflictPaths(in output: String) -> [String]`: the lines after the first
  (the tree id) up to the first empty line, de-duplicated, in order.
- Dispatcher: after the worktree of a `resolve` job is prepared, `job.conflicts` is set and the
  job saved, before the agent starts.
- `public enum ConflictHotspots` (`Sources/BtonCore/ConflictHotspots.swift`):
  `static let window: TimeInterval = 14 * 86400`, `static let shown = 8`;
  `public static func rank(jobs: [Job], repo: String, now: Date = .now) -> [(path: String, pullRequests: Int)]`:
  over resolve jobs of the repo started within the window, per path the count of distinct
  `key.item`, sorted by count descending then path, at most `shown`;
  `public static func line(_ ranked: ...) -> String?`: `Conflicts, 14 days: <path> (<n> PRs),
  ...` with `1 PR` singular, nil when empty.
- `RepoPage` header: the line under the summary, meta font, secondary color, two lines at most.
  The data is the store's jobs; no new read.

Acceptance (`ConflictHotspotsAcceptanceTests`): `conflictPaths` on a captured merge-tree output
with an informational section; `rank` counts distinct PRs per path, honors the window, the repo
and the move, sorts and caps; `line` wording; a job record with `conflicts` round-trips through
the JSON coder and an old record without the field decodes.

## Out of scope

The review-side criterion, a CLI for flakes and hotspots, a rigor-style rule draft from a
recurring cause, and moving the app's other comment posters to stdin.
