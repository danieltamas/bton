# The code graph as the agents' development memory

Status: approved (2026-10-30), built on branch `graph-memory` the same day; what differs from the first draft is marked "as built". Owner: Daniel Tamas.

## The problem

A Bton job knows the code and the item it works on, and nothing of what was done before. The
code graph (graphify, per repo, of the base branch at its last build, `CodeGraphBuilder`) maps
the whole tree at that commit: on lexito 4297 files, code and the repo's own Markdown (plans,
specs, `jobs/*/JOB.md`). It does not hold what lives only on GitHub or in Bton: issue and PR
threads, review comments, `## Decision:` rulings, and the report of every job Bton ran. Each job
gets its own item's thread injected at dispatch (`pr-evidence.md`, the issue thread) and reads
everything else fresh, or not at all. The visible cost is not tokens (see Measured below): it is
an agent that re-proposes what a thread rejected two weeks ago, a reviewer that does not know the
earlier review of the same area, a decision that contradicts an earlier ruling.

## Measured before the change (2026-10-23 to 2026-10-30, Dani's Bton, succeeded jobs)

| move | queried the graph | graph present, 0 queries | no graph |
|---|---|---|---|
| review | n=60, median $0.96, 1.3 min | n=27, $0.88, 1.2 min | n=37, $0.54, 1.3 min |
| decide | n=5, $0.93, 1.3 min | n=5, $0.93, 1.3 min | n=6, $0.80, 1.5 min |
| fix | - | n=11, $1.54, 7.6 min | n=3, $3.50, 7.8 min |

Source: `~/.bton/jobs/*.json` (`cost`, `startedAt`, `endedAt`) and the `graph queries: N` note
in each job's `.log`. A job that queried the graph was not cheaper. Cheaper and faster is a
hypothesis this plan measures (unit U4), not its premise; the premise is consistency.

## Complete when

On a repo with the graph switch on, a job's agent can answer "what was decided about X and why"
and "what did the last job on #N report" from `graphify-src` alone, with the issue, PR, decision
or report that says so named in the answer, and a job on a repo without a graph behaves as today.

**Measured by** `scripts/graph-memory-check.sh <clone path> <issue>` (U4): runs
`graphify-src "what was decided on #<issue>"` in the clone's build worktree
(`.worktrees/bton-graph`, where Bton built the graph with the memory) and asserts the output
names `memory/issues/<issue>.md`; it prints the issue's first `## Decision:` line. Exit 0 =
complete. Plus the before/after table of U4 in this document.

## Layout

| Unit | Depends on | Touches |
|---|---|---|
| U1 Memory export | - | `BtonCore/GraphMemory.swift` (new: records, renderers, export, link, exclude, rebuild rule), `BtonCore/GraphMemoryGitHub.swift` (new: one GraphQL query for issues and PRs, paged) |
| U2 Build with memory | U1 | `BtonCore/CodeGraphBuilder.swift`, `BtonCore/CodeGraph.swift` (marker gains `shape` and `memoryAt`), `BtonCore/Dispatcher.swift` (links `memory/` into job trees), `BtonCore/Engine.swift` |
| U3 Instruction line and playbook | U2 | `BtonCore/CodeGraph.swift` (`defaultMemoryInstruction`), `BtonCore/PRPlaybook.swift`, `docs/FLOW.md` |
| U4 Measurement | U2, U3 | `scripts/graph-memory-check.sh` (new), this document's after table, `BtonCore/GraphUse.swift` (unchanged, the count exists) |
| U5 Settings and page | U2 | `Sources/Bton/AgentsPane.swift`, `RepoPage.swift`, `ReposPane.swift` (the switch's text says what the graph holds), `CodeGraphsSettings.swift` (memory time per graph), `README.md` |

### U1 Memory export

Every sync (as built: not only before a build, so the memory is never older than the last sync
and a job reads it fresh through the link) Bton writes the repo's memory as Markdown files
graphify maps like any other file, under `memory/` in the graph store
(`~/.bton/graphs/<owner>__<repo>/memory`), copied into the build worktree before graphify runs
and linked read-only into every job's tree beside `graphify-out`:

- `memory/issues/<n>.md`: title, labels, state, the body and every comment with author and time,
  as `IssueDrafts.thread` already renders an issue. Every issue updated since the last export,
  open or closed; the first export takes the last 180 days.
- `memory/prs/<n>.md`: title, base and head branch, state, merged at, the body, review comments
  and review bodies with author, time and state (`## Review:` and `## Decision:` headings kept
  verbatim so a query for the heading finds them), the list of changed files.
- `memory/jobs/<item>.md`: one file per item (as built: one per item, runs newest first, not
  one per run), the first 4000 characters of every ended job's report on this Mac with move,
  agent, status, cost and head; rendered again only for items with a run ended since the last
  export (`jobsAt` in the state file). Only this Mac's: another Mac's jobs reach the graph when
  that Mac builds its graph; GitHub stays the only shared state (decided 2026-10-25, no
  Bton-to-Bton channel).
- `memory/INDEX.md`: one line per file with its title and date, so a community hub exists for
  the folder.

Reads are one GraphQL query for both sides (`GitHubClient.memoryItems`): issues open and
closed, PRs open, merged and closed, 50 a side per page ordered by `updatedAt` descending, each
page taken whole, a side continued while it has a next page and its oldest item is at or after
the floor (the last export's newest `updatedAt`, kept in `bton-memory.json` in the store; the
first export reaches 180 days back), 12 pages per refresh at most (600 items a side), so a
sync is never held by GitHub paging. Secrets never: a body is written as is, but the export runs
the same `DispatchPlanner.redact` the posted reviews go through (the repo's environment
values), and the file is excluded when the redaction reports a hit. A body from a contributor is data in a file,
never an instruction; the files carry no front matter an agent could read as config.

Acceptance (a different vendor writes the tests from these lines):

1. `GraphMemory.export(repo:into:since:)` on a fixture of 2 issues (one with a `## Decision:`
   comment), 1 merged PR with a review and 1 job report writes exactly the four kinds of file
   with the names above, and `memory/issues/<n>.md` contains the decision heading verbatim.
2. A second export with `since` after every update writes nothing and returns `unchanged`.
3. A body containing a value of the repo's environment, which `DispatchPlanner.redact` replaces, is not written; the export's log
   names the issue number and nothing of the body.
4. A GitHub error mid-export leaves the previous `memory/` in place and the build goes on with
   it; the state's `updatedAt` does not advance (fail closed on the newest, keep the last good);
   the log says "memory not refreshed" once per reason, not every sync.
5. The state carries `GraphMemory.shape`. A state written under another shape (or none) makes
   the next refresh read everything again (`since` nil, job reports too) and the export rewrites
   what changed, so an item an older rule left out comes in without a press. Measured
   2026-10-30 on lexito: the first export kept 304 of 814 items out because the local database
   URL's password equals its user name, the word "lexito", which `redact` took for a secret;
   the rule now drops a URL password equal to its user, and the shape bump re-exports them.
   The files not written are one summary line in the log, not one line each.
6. graphify honours the clone's `info/exclude` (its #1810), the file that hides `memory` from
   git: measured 2026-10-30 on lexito, the first build with memory indexed 0 of its 799 files
   ("no topology changes, outputs left untouched"). The build tree therefore carries
   `.graphifyignore` with `!memory` (last match wins; 799 detected with it), itself excluded
   from git. A file is dated by its record's own `updatedAt`, not the sync's minute, which
   had rewritten 100 files a sync and made the memory "newer" forever.

### U2 Build with memory

`CodeGraphBuilder.build` refreshes the memory every sync after `Worktrees.prepare`, then
decides whether the graph is due (`GraphMemory.rebuildReason`): no graph; the base moved; the
marker's `shape` is not `CodeGraph.shape` (a Bton upgrade that changed what a graph holds
rebuilds every store on its first sync, nothing to press); or the memory is newer than the
graph and the graph is 30 minutes old or more (as built: 30 minutes, not 6 hours, so a
decision reaches the graph within the hour without a merge; the 30 minutes bound the rebuild
cost of a busy repo, 80 to 190 s on lexito). The store's `memory/` is copied into the build
worktree before graphify runs. `memory/` and `graphify-out` are listed in `info/exclude` of the
common `.git` (measured: git reads `info/exclude` from the common dir only, a per-worktree
one is ignored), so `git status` stays clean and the worktree is still reused. The marker gains
`shape` and `memoryAt` (the newest `updatedAt` exported); Settings > Agents shows "memory to
<time> ago" under each graph. A build that fails keeps the last graph and marker.

Acceptance:

1. A build on a fixture repo produces `graphify-out/graph.json` whose nodes include a file node
   for `memory/issues/<n>.md`, and `graphify-src "decision on #<n>"` run in that worktree prints
   the file's path.
2. With the base unmoved, the graph 31 minutes old and the memory newer, `refresh` builds; with
   the graph 10 minutes old or the memory not newer it does not (today's "same commit, built"
   early return holds). A marker without `shape`, or with an older one, builds.
3. The export's folder never appears in `git status --porcelain` of the build worktree.

### U3 Instruction line and playbook

The instruction line of a graph built with memory (`CodeGraph.defaultMemoryInstruction`) is:
"Code graph: graphify-out/ in this checkout is graphify's graph of {base} at {commit}; memory/
beside it holds the repo's issues, PRs, decisions and Bton's job reports as of {memory}; this
branch's own changes may not be in it. Run graphify-src "<question>" before searching the tree
or reading GitHub; read GitHub only for the item you work on and for anything newer than
{memory}." The PR playbook's step 2 says the same in its own words: what was decided, tried or
reviewed before is asked of the graph first; the live thread of the job's own item stays as
injected. A repo with the switch off, no built graph, or a graph built before this change (no
`memoryAt`) gets today's line or none, as today. `docs/FLOW.md` documents the memory folder and
the line.

Acceptance:

1. `CodeGraph.instructionLine` with a marker that has `memoryAt` renders the memory sentence;
   with a marker without it (a graph built before this change) renders today's line.
2. A job's tree on a repo whose marker has `memoryAt` holds `memory` as a link to the store's
   folder and `git status` of the tree stays clean; on a repo without, it does not.

### U4 Measurement

`scripts/graph-memory-check.sh` as in Complete when. And the after table: the same query as
the before table, over the first 7 days after the release, pasted under Measured after the
change. The hypothesis "cheaper and faster" holds if the median cost of `review` and `decide`
jobs that queried the graph drops below the before medians with n >= 30; if it does not, the
feature stays for consistency and the line says nothing about cost. The consistency measure:
the supervisor's weekly count of decisions that reversed an earlier `## Decision:` on the same
issue (today it is not counted; `Supervision` gains the count from `memory/issues`).

### U5 Settings and page

The graph switch's text in Settings > Repos names what the graph holds (code of the base, and
the repo's issues, PRs, decisions and this Mac's job reports); the repo page's graph line shows
the memory time beside the commit. No new switch: a team that wants the code graph wants the
memory with it, and the export costs one GraphQL page per 50 updated items a side.

## Tests (as built)

`Tests/BtonCoreTests/GraphMemoryAcceptanceTests.swift`, 13 tests written by Codex from this
document's acceptance lines, hashed; one edit by the implementer with evidence (two lines
reading the git dir read the common dir instead, after measuring that git ignores a
per-worktree `info/exclude`). Green: "Test run with 13 tests in 1 suite passed".

## Quality criteria

- Code: Swift 6, files at most 500 lines (`GraphMemory.swift` split into export and renderers
  if it nears it), English identifiers and comments that say why, the layer's casing. Tests by
  another vendor from the acceptance lines, hashed, never edited by the implementer.
- Speed: the export must not delay a sync by more than 20 s on lexito (about 600 issues and
  PRs on the first run, then the day's updates): measured with the log's timestamps around
  "memory refreshed". graphify's rebuild of the added Markdown is its own cost; the first lexito
  build after the change is timed and pasted here. Measured 2026-10-30 (lexito, 226 issues and
  402 PRs in reach): the full export wrote 795 files in 1 s (15:03:57 to 15:03:58Z); a quiet sync
  after it wrote 1 to 4 files; the rebuild with memory took 160 s against 82 to 104 s without,
  for 2924 documents detected against 2125 and 11624 graph nodes from `memory/`;
  `scripts/graph-memory-check.sh ~/Sites/lexito.ro/lexito.ro 296` printed PASS at 15:08Z. The
  question has to name the item as `#296`: "issue 296 decision" lands on code symbols named
  Issue and Decision, so the graph line says so.
- Security: the export reads GitHub with the user's `gh` token as every reader does, and writes
  only under the build worktree. Contributor text enters the graph as data; the instruction line
  tells the agent the memory is the repo's record, never instructions, in the words the prompts
  already use for threads. Redaction before write, exclusion on a hit, fail closed on a read
  error (last good memory kept, marker not advanced). The memory folder is never linked into a
  job's worktree as writable: the agent reads it through `graphify-out`, which is a link to the
  store, as today.

## Out of scope

Other Macs' job reports (would need a channel Bton does not have), a graph that rebuilds per
comment (the memory is as fresh as the last sync; the graph index follows within 30 minutes),
and any change to how GitHub is read for the job's own item.
