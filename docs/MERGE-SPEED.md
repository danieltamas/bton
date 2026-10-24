# Why lexito merges are slow (2026-10-24)

Measured on the live merge of lexito PR #406 (job `465C9D58`, head `407f592`), then on two trial runs of
the same suite. Split into what lexito owns and what Bton owns.

## What the merge spent its time on

| Step | Time |
| --- | --- |
| Bton setup (lease, worktree, env) | 5s |
| `git diff` migrations, 2x `bun install --frozen-lockfile` | 2s |
| `check.sh --fast` stage 1, gateway `tsc` | 18s |
| `check.sh --fast` stage 2, 597 test files, **one at a time** | **1403s (23.4 min)** |
| landing `tsc` | 1s |
| base worktree, head re-read, `wt merge` (squash, close issues, cleanup) | 60s |
| **Total** | **24m55s** |

The merge itself is about a minute. Stage 2 is 94% of the job.

Inside stage 2:

- `burst-fixture.pg.test.ts` about 4.3 min and `burst-recovery.pg.test.ts` about 6 min: **two files, 44% of
  the stage.** They are acceptance tests (a 500-file onboarding burst on real Postgres, with a "<4 min"
  assertion) sitting in the `--fast` gate.
- The other 595 files: about 786s, 1.3s each. A pure unit file costs 0.2s (bun start included); a
  `*.pg.test.ts` costs 1.5-2.4s, mostly building its scratch databases.
- Each scratch database is created empty and all migrations are applied to it: 609ms per client DB.
  Cloning the same DB from a template is 53ms (measured). 225 pg files build one to three DBs each.
- All of the above was measured at load 9-20 on 10 cores (agents, Docker, the other worktrees); idle
  was not measured.

## Why it is slow

1. **Serial on a 10-core Mac.** `check.sh` runs every file in its own bun process, one after another.
   The per-file process is required ("all-at-once is known-broken: mock cross-pollution"), but that rule
   is about sharing one process, not about running separate processes at the same time.
2. **Two acceptance tests in the fast gate** take almost half the time.
3. **Every pg file migrates from zero** instead of cloning a migrated template.
4. **The same suite runs several times per PR, on this Mac**: when the PR opens, after each fix batch
   (REVIEW-PROCESS steps 3 and 5) and again at merge. For #406 at the same head `407f592` the merge check
   ran three times: two runs were killed by the then-10-minute limit, the third passed in 23 min. The
   merge limit is now 60 min in develop (#409), so those timeouts stop; the 23 minutes do not.

## Measured: running the files in parallel

Same develop tree (with #406), same Postgres, every file still in its own process, 8 at a time:

| Run | Wall time | Failing files |
| --- | --- | --- |
| Serial (the live merge) | 1403s | 0 |
| 8 parallel, run 1 (partial export) | 225s | 19, 13 of them files my export left out |
| 8 parallel, run 2 | **165s** | 19 |

The 165s is **not a clean number**: both burst files died early in both runs (at 168s in run 1, 66s in
run 2, each pair at the same moment), so it is the time for the 595 other files. With the burst files
completing, a parallel run is bounded by the longest file, about 4-6 min. So the realistic win is
1403s to about 3 min only once the burst tests leave the fast gate.

The failures are pg files failing with `Connection terminated unexpectedly` (plus one ENOENT,
`search-fixture/questions.test.ts`, likely an artifact of the export). They pass serially. What is known:

- **Not server-side.** Postgres logged the same number of admin terminations serially and in parallel
  (17 vs 17 and 20), no crash, no restart, no "too many clients". Scratch DB names are pid-suffixed, so
  it is not a name clash.
- **One kill instant per run, about 2s wide** (run 1 at 22:57:35-37 UTC, run 2 at 23:01:43-45 UTC). Every
  victim, the burst files included, lost its connections then; some probes failed on their very first
  connection, 106ms in.
- **Not connection volume.** 3000 short connections 60 at a time, and 90 held connections plus churn,
  all through the same Docker port forward, ended cleanly.
- The passing files running at each instant differ between runs (run 2: `research-e2e.pg` with real
  Redis, `research-admin-stats`, `reseller-fixes3-statement`; run 1: `whatsapp-cost-sync`,
  `onedrive-status`, `onedrive-extract-attempts`, `work-dispatcher-defer`), so no single co-runner is
  implicated yet.

Root cause **not pinned**. Leading suspect: the network path (Docker Desktop's port forward dropping
every proxied connection at once, which shows the same client error with no server log line; its
logs had rotated). Next probes: run the parallel trial against a Postgres reached without the port
forward (container network, or a server per worker), and log `pg_stat_activity` plus Docker's
vpnkit/backend log at the instant. Parallelism is not usable until this is found.

Side finding: `lexito-testdb` holds **261 leaked scratch databases** (pid-suffixed, since 2026-10-07).
A killed or timed-out file never drops its DBs; the two trial runs above added some of them.

## What to do, biggest win first

### Lexito (hand off to the lexito worker)

1. **Run the gate once per push, off this Mac.** A CI workflow with Postgres and Redis services runs
   `check.sh --fast` on every push (the original reason for the local gate was "CI had no Postgres
   service"). Bton's merge then only checks that the required status is green on the exact head. Merge
   becomes about a minute and stops competing with the agents for cores. Costs: CI minutes, `check.sh`
   has to work on Linux, and Bton needs the gate below.
2. **Move the two burst acceptance tests out of `--fast`** into the full run or a nightly job. Alone
   that is about -10 min serial, and it is what lets parallelism pay: with them in, a parallel run still
   waits 4-6 min for them.
3. **Parallel stage 2.** Keep one process per file, run N at a time (`xargs -P`). Prerequisite: find the
   cross-file connection killer above, or give each worker its own database server (one container per
   worker, or a server per shard). Measured on the other 595 files: 165s at 8-way.
4. **Template databases.** Migrate one template per run, `CREATE DATABASE ... TEMPLATE` per file
   (609ms to 53ms). Only 151 of the 225 pg files use `scratch-db.ts`; the other 74 build their own DBs
   and must move to the shared helper first (`check.sh`'s comment says 16; it is stale).

### Bton (this repo)

Acceptance tests for items 2-5: `Tests/BtonCoreTests/MergeFixesAcceptanceTests.swift`.

1. **A "required checks green at this head" gate.** A `beforeMerge` kind (or a `when` condition) that
   reads the head commit's check runs on GitHub instead of running a command. Fail closed on pending,
   missing, failed, or an API error. This is what makes lexito item 1 possible.
2. **Done: no blind retry of a timed-out command move.** This is what cost #406 its extra 10 minutes:
   the supervisor answered "retry" with a note no one reads (a command move has no agent), and the same
   check timed out again. Now a command time-out is flagged `timedOut` like an agent's, a supervisor
   `retry` on such a job is recorded as "not retried" with the reason (raise `timeoutMinutes` or speed up
   the command, then press Retry), and the supervisor's prompt says so. A manual Retry still works.
3. **Done: passed checks are not run again.** When every check passes, the job saves the base tip it ran
   against and the argv list. A later job for the same key (same head) over the same base tip with the
   same checks skips them and logs "not run again" with the earlier job's id. Another head, a moved base
   or a changed flow runs everything again. The head re-read before the merge command still happens.
4. **Done: orphan base worktree removed.** After the merge command, `.worktrees/bton-base-<item>` is
   removed when git no longer lists it (as well as when it is clean); it is kept only when git still
   lists it and it has changes. A fresh base tree also replaces such an orphan instead of failing. Never
   through a link at or below the clone; a schedule's tree is still refused, not removed.
5. **Done: a stopped job released its lease 15 minutes late.** `finish()` ran inside the stopped job's
   cancelled task, where every process is killed as it starts, so the `git push` that releases the lease
   and the label removal never ran: the PR read as busy until the lease expired. They now run outside
   the cancelled task.
