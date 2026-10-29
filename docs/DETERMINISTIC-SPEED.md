# What can run without an agent (2026-10-29)

Two readings of the dispatch path, one by Claude (Fable) in the session that shipped 0.14.0 and
0.14.1, one by Codex (`codex exec`, read-only, no Swift run), merged into one ordered list. The
question was: what does Bton spend agent time or wall-clock on that a deterministic step could do
first, or instead? Savings are estimates unless they cite a measurement in `docs/MERGE-SPEED.md`.

What Bton already does without an agent, so it is not on the list: command moves (a merge is
`wt merge`, not a model), `beforeSession` and `beforeMerge` argv checks that stop a job before it
spawns, worktrees kept between jobs, same-head dispatch dedupe, approval carried to the merge move,
no blind retry of a timed-out command.

## Ordered by saving per unit of risk

1. **Done (0.15.0, `checks_green`). Read the head's check runs on GitHub as a merge gate instead of running the suite again.**
   The PR query fetches no check status (`GitHub.swift`, the `pr` GraphQL fields) and
   `MERGE-SPEED.md` lists this gate as the open Bton item. A `beforeMerge` kind `checks:<name,...>`
   that passes only when every named check is green on the exact head SHA, and waits on pending,
   missing, failed or an API error. Saves the whole local gate per merge (about 4 min on lexito's
   `--fast` suite, 235-322 s measured) and the CPU it takes from agents running beside it. Risk:
   trusting a check that ran on a different SHA or from a fork's workflow; name the checks, pin the
   SHA, fail closed.

2. **Done (0.15.0, keyed by the head tree the checks ran on plus the base tip, since the base is not merged into the check worktree). Key check receipts by the tree, not by the job.** A receipt is reused only when the
   whole job key matches, move included (`DispatcherCommands.swift`, `Jobs.swift`), so review, fix and
   merge each run the same suite on the same code. `MERGE-SPEED.md` records one head whose suite ran
   three times. Key a receipt by `git merge-tree --write-tree <base> <head>` (the OID of the tree
   the merge would produce) plus the command's argv and an environment fingerprint: the same tree
   gives the same result whatever the move, and a rebase that produces the same tree needs no rerun.
   Saves one full suite per transition that shares a tree. Risk: a check that reads a service or
   the clock is not a pure function of the tree; mark such checks `nocache` in the flow.

3. **Done (0.15.0): `pr-evidence.md` in the job's scratch directory holds the PR's metadata,
   head, base, base tip, merge-base, local HEAD, numstat, check receipts and the PR's comments as
   indented data; every agent job on a PR except `supervise` gets it, and playbook v5 reads it
   instead of fetching. Review threads (inline comments) are not read by Bton and are not in it.
   The original item: hand the agent an evidence packet instead of telling it to collect one.** Bton reads the PR
   body, comments, reviews, head and base on every tick, then the playbook (`PRPlaybook.swift`,
   steps 1-2) tells the agent to fetch metadata, SHAs, status, CI and the diff itself. Write a
   bounded file into the worktree at spawn: head, base, merge-base, local SHA, changed paths with
   diff stats, the review threads that are open, check receipts, and point the prompt at it. Saves
   an estimated 5-10 tool calls and 30-120 s per session, and the repeated metadata in the agent's
   context. Risk: contributor text in the packet is prompt input; label it as evidence, keep the
   instructions in the prompt, and keep the live re-read before any write.

4. **Done (0.15.0): `pr-evidence.md` has a `Previous review` section: the latest review the
   flow counts (never the decision), its head resolved in the worktree, whether HEAD descends
   from it, the commits since, whether the merge-base with the base moved, the numstat since,
   and the posted findings as a table with "Location touched since". Its `scope` line is
   `delta` only when the reviewed head is an ancestor, the base context is unchanged and every
   git read succeeded, else `full`; the playbook (v6) reads that line instead of reconstructing it. The original item:
   Give a re-review its delta.** The agent reconstructs what changed since its last review
   (`PRPlaybook.swift`, ancestry step). Bton knows the reviewed head from the review it posted:
   compute `reviewed-head..head`, whether the base moved, and attach the previous findings as a
   table with each one's state. Saves the discovery turns and the repeated full diff on large PRs
   with small fix batches. Risk: a delta review misses an interaction outside the delta; fall back
   to full scope when the base moved or history was rewritten.

5. **Done (0.15.0): a review rule's `second` (`{"agent": {tier: name}, "prompt": {tier: text}}`)
   runs the second reviewer as a second agent process in the same job and worktree, with its own
   prompt, session, output and log; Bton merges both findings tables by location (the second's
   rows prefixed `S-`, duplicates by location dropped and counted), posts the first's heading with
   the stricter verdict, and appends the second's notes as data. A second that gives no verdict
   (died, timed out, no heading) makes the review `blocked`; a Mac without the second's program
   never starts the review. `examples/team.flow.json` uses it for feature and high-risk instead of
   "ask codex once". The original item: Run the independent reviewer as its own job, in parallel, instead of nested.** The team flow's
   review prompt (`examples/team.flow.json`) tells the Claude reviewer to ask Codex once through the
   `ask` MCP tool from inside its session, so the second opinion is serial and
   its findings pass through the first model's summary. A `review` move with two agents, each with
   its own transcript, both findings tables attached to the review that is posted. Wall-clock drops
   to the slower of the two; the verdict quality rises because neither reviewer edits the other.
   Risk: two sessions cost more tokens; the review poster has to merge two tables deterministically
   (by file:line) rather than ask a third model.

6. **Done (0.15.0): a dispatch rule's `checks` takes a list of argv that run instead of the
   flow's list for that move, with the same placeholders, environment, time allowance and
   receipts; the team example's `review` rule runs the conflict check, `bun install
   --frozen-lockfile`, lint and typecheck, while `fix` keeps the flow's conflict check only.
   The original item: cheap deterministic gates before paying for a review.** The team flow's
   `beforeSession` ran only the conflict check (`examples/team.flow.json`). Add `bun install
   --frozen-lockfile`, format check, lint, the gateway `tsc` (18 s measured): a mechanical red
   stops the review before it spawns and the fix agent gets the exact output. Saves an entire
   review session each time a PR is mechanically broken. Risk: the same gate on the `fix` move
   stops the agent from repairing what the gate found; gates are chosen per move.

7. **Done (0.15.0): `tier.only` lowers a PR to a tier when every changed file matches its
   globs and the body names no tier but the default (an `only` tier named in the body is not a
   claim; `paths` still raise it), and a dispatch rule with per-tier agents runs its `command`
   for the tiers without one, so the team example's `docs` tier gets `scripts/docs-review.sh`
   as its review. The rule's `checks` (item 6) still run before it: checks are per rule, not
   per tier. The original item: a deterministic review for documentation-only PRs.** Tier
   rules only raised a tier (`TierPaths.swift`). A rule that lowers it when every changed path matches an allowlist
   (`docs/**`, `*.md`, excluding anything executable or generated), and a command review (link
   check, markdown lint, plain-character check) that posts a verdict marked as policy, not judgment.
   Saves the whole review session and its helper. Risk: a markdown file can carry an executable
   example or a security instruction; the allowlist is by path, never by line count.

8. **Done (0.15.0): `Supervision.knownAnswer` reads the structured details Bton itself writes
   (`waiting:`, a program not on PATH, a logged-out agent, a moved head, a closed PR, checks not
   green or not trusted, a check past its limit, an invalid environment, a failed check) and
   records the known verdict on the job at finish; such a job is never supervised. Agent text
   (`agent exited`, `timed out`, no verdict, a lost lease) stays with the model. The original
   item: route known operational failures past the supervisor.** `Supervision.swift` spent a
   model run classifying each flagged job; missing executable, stale head, a check timeout, a tool that is not
   installed and a logged-out `gh` are structured causes with a known answer (wait, retry once,
   escalate). Saves one supervisor session per recognized failure. Risk: a broad match hides a real
   defect; match the structured cause only, leave the rest to the model.

9. **Done (0.15.0), opt-in: `checks.together` names groups of argv a team declares independent,
   and consecutive checks of one group start at the same time (`runTogether`), each with its own
   time limit and its output as one block in the log; the first failure ends the others. Off
   without the declaration; little gain where one suite dominates, as measured on lexito. The
   original item: independent checks in parallel groups.** Checks ran serially (`DispatcherCommands.swift`).
   An opt-in group in the flow runs declared-independent checks together, so A+B becomes max(A, B).
   Little gain where one suite dominates, as on lexito. Risk: Postgres, output directories and CPU
   contention; independence is declared in the flow, never inferred from argv.

10. **Dependency and build caches keyed by lockfile and toolchain.** Worktrees already persist, so
    installs are warm; the measurement puts two installs at 2 s on lexito. Worth doing only for a
    repo whose setup is minutes, not seconds.

## Not recommended

- **Automatic rebase.** The playbook forbids it; it rewrites the head, which invalidates every
  receipt and review above, and the human loses the thread of what was reviewed.

## Suggested order to build

Items 1 and 2 share the receipt store and the fail-closed gate shape, and remove the largest
measured cost (the suite run several times per head). Items 3 and 4 share the evidence packet.
Items 6 and 7 are flow configuration first, code second. Items 5, 8, 9 and 10 stand alone.
