# Required-check gate

Status: draft for review, 2026-10-27. Source: hand-off from the workload-offload session (lexito #416 D-1,
self-hosted runner), docs/MERGE-SPEED.md "Bton (this repo)" item 1. Sub-project 1 of 3; the runners and
check-runs UI (2) and the Linux `bton watch` (3) get their own specs.

## Goal

A merge starts only when GitHub says a named check run is `completed` and `success` on the exact head
Bton is about to merge, and the base has not moved past what that run tested. Bton reads the result; it
does not run the check. Success: lexito can drop `check.sh --fast` from `beforeMerge` once its workflow
and this gate have agreed on real PRs.

## Decisions taken

- **Schema.** `checks.requiredCheck` in `.bton/flow.json`, beside `beforeSession` and `beforeMerge`:
  `{ "name": "gateway-ci" }`. Optional field, so every existing flow parses unchanged. `beforeMerge` stays
  and runs after the gate while the transition lasts. A value that is not an object with a non-empty
  string `name` makes the flow invalid (shown as "flow invalid", nothing dispatched), like any other
  malformed flow field.
- **A hold is not a job.** A move runs once per head, pass or fail. A gate that failed the job on
  "queued" would burn the head's merge. So the gate is judged twice:
  1. **At planning** (each sync, in `Engine.tick`, for a merge candidate only): a verdict other than
     pass drops the candidate for this sync and records the reason in `Snapshot.waiting` (the row's
     "waiting" label). Nothing is written on GitHub and no job exists. A pressed Merge is held the same way.
  2. **At dispatch** (`Dispatcher.dispatch`, before `beforeMerge` and again right before the command,
     next to `headRefusal`): authoritative and fail closed. A verdict other than pass here fails the job
     with the reason, because a state that changed between planning and the command is a real refusal.
- **One pure judge, one fetch.** `RequiredCheck.judge(...)` is a pure function over values; the network
  read is `GitHubClient.requiredCheckEvidence(repo:number:name:)`. Unit tests drive the judge with
  values and the fetch with a stubbed `gh`; no network in unit tests.
- **Press does not bypass.** `BTON_PRESSED` is for checks that guard a person's decision. This gate
  guards a machine fact; a press never skips it.
- **Only check runs.** Commit statuses (`statuses` API) are not read; the workflow publishes a check run.

## Evidence read (one fetch, three GitHub reads, each with a 60 s limit)

1. `GET repos/{repo}/pulls/{n}`: `state`, `head.sha`, `base.ref`, `mergeable_state`.
2. `GET repos/{repo}/commits/{head}/check-runs?check_name={name}&filter=latest&per_page=100`: the runs
   of that name on the head, newest per app. `{name}` is URL-encoded.
3. `GET repos/{repo}/commits/{base.ref}`: the base tip's sha and commit date.

Any read that fails, times out, returns a status other than 200, or does not decode is the verdict
`unavailable`.

## Verdicts

`pass` only when all hold; anything else is a hold (planning) or a refusal (dispatch), named by the first
rule that fails, in this order:

| Order | Verdict | Condition |
|---|---|---|
| 1 | `unavailable` | a read failed, timed out, or did not decode |
| 2 | `notOpen` | PR `state` is not `open` |
| 3 | `headMoved` | `head.sha` is not the head the move was planned for (dispatch) or the row's head (planning) |
| 4 | `behind` | `mergeable_state` is `behind` |
| 5 | `missing` | no run of that name on the head |
| 6 | `pending` | any matching run has status `queued`, `in_progress`, `waiting`, `requested` or `pending` |
| 7 | `failed(conclusion)` | any matching run is completed with a conclusion other than `success`: `failure`, `cancelled`, `skipped`, `timed_out`, `neutral`, `action_required`, `stale`, `startup_failure`, or a value Bton does not know |
| 8 | `stale` | a matching run's `started_at` is earlier than the base tip's commit date, or is absent |
| 9 | `pass` | every matching run (one or more, so two apps publishing the same name both count) is completed and `success`, and rules 1-8 held |

The table is the order of evaluation, so `pending` (6) wins over `failed` (7) while any matching run
still moves: a failed run beside a queued one holds as `pending` and settles to `failed` when the queued
one completes. A mix of `success` and any non-success completed run is `failed`, never a pass.

## Log and reason text

- Job log line at dispatch, always: `required check <name>: run <id> <conclusion> at head <sha7>, base <ref> tip <sha7>` (one line per matching run); on a refusal the first line is
  `required check <name>: <verdict reason>`.
- `Snapshot.waiting` text at planning: `waiting for <name> on <sha7>: <verdict reason>`. Reasons are
  short and name the cause (`queued`, `failed (timed_out)`, `not run on this head`, `PR is behind its base`,
  `GitHub did not answer`).
- Reasons never include PR text.

## Components

| Unit | Does | Depends on |
|---|---|---|
| `Flow.swift` `Checks.requiredCheck` | parses the field | nothing |
| `RequiredCheck.swift` (new, BtonCore) | `Evidence`, `Verdict`, `judge`, `reason(for:)` | Foundation |
| `GitHub.swift` `requiredCheckEvidence` | the three reads, decoded to `Evidence` | `gh` runner |
| `Engine.swift` planning hook | evaluates merge candidates, drops holds, records reasons | judge, fetch |
| `Dispatcher.swift` dispatch hook | the authoritative evaluation, before `beforeMerge` and before the command | judge, fetch |

`Engine` reads evidence once per merge candidate per sync (at most a few PRs), not per PR in the repo.

## Docs

`docs/FLOW.md` (the field, the verdict table, hold vs refusal), `docs/ARCHITECTURE.md` (components and the
two evaluation points), `docs/MERGE-SPEED.md` item 1 (status), `LOG.md` entry at release. The lexito flow
change (adding `requiredCheck`) is a hand-off to the lexito worker, not done here.

## Acceptance tests (Codex or the user, from this spec; `Tests/BtonCoreTests`)

Each judged through `RequiredCheck.judge` with values, none with network:

1. pass: one run, completed, success, head and base fresh.
2. pass: two apps, same name, both success.
3. each of `queued`, `in_progress`, `waiting`, `requested`, `pending` is `pending`.
4. each of `failure`, `cancelled`, `skipped`, `timed_out`, `neutral`, `action_required`, `stale`,
   `startup_failure` and an unknown conclusion string is `failed`.
5. no run of that name: `missing`. A run of another name only: `missing`.
6. one success plus one failure of the same name: `failed`. One failure plus one pending: `pending`.
7. `mergeable_state` `behind`: `behind`, even with a green run.
8. run `started_at` before the base tip's commit date: `stale`. Absent `started_at`: `stale`.
9. PR `closed`: `notOpen`. `head.sha` differs from the expected head: `headMoved`.
10. each of: non-zero `gh` status, timeout, undecodable body on each of the three reads: `unavailable`.

Behavior, with a stubbed `gh` and an in-memory job store:

11. planning: a held merge candidate starts no job, writes nothing, and its pick shows the reason in
    `Snapshot.waiting`; the next sync with a passing check starts it.
12. dispatch: a verdict other than `pass` after planning passed fails the job with the reason and runs no
    `beforeMerge` command and no merge command.
13. a flow without `requiredCheck` plans and dispatches exactly as before (no extra reads).
14. a malformed `requiredCheck` (a string, an object without `name`, an empty `name`) marks the flow invalid.
15. `BTON_PRESSED=1` does not skip the gate.
16. one `BTON_SANDBOX` test against the sandbox repo: a real PR head with a real check run reads back as
    `pass` or the right hold.

## Out of scope

Commit statuses; required reviews (the flow's own moves cover them); a branch-protection read; writing the
lexito workflow; the runners and check-runs UI (sub-project 2); Linux (sub-project 3).

## Risks

- `filter=latest` returns the newest run per name and app, so a re-run that fails after a success is
  seen as failed: correct and wanted.
- A workflow that never publishes the check on a PR (path filters) is `missing` forever. The row says so;
  the fix is the workflow's.
- `mergeable_state` can be `unknown` right after a push; it is not `behind`, so the gate does not hold on
  it, and the run's freshness (rule 8) plus the head check are what protect.
