# The code graph as the agents' development memory

Status: approved in shape (2026-10-30), build after v0.20.0 ships. Owner: Daniel Tamas.

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

**Measured by** `scripts/graph-memory-check.sh <owner/repo> <issue>` (new, U4): builds the
graph for the repo's clone, then runs `graphify-src "what was decided on #<issue>"` in the build
worktree and asserts the output names `memory/issues/<issue>.md` and quotes the issue's newest
`## Decision:` heading. Exit 0 = complete. Plus the before/after table of U4 in this document.

## Layout

| Unit | Depends on | Touches |
|---|---|---|
| U1 Memory export | - | `BtonCore/GraphMemory.swift` (new), `BtonCore/IssueAsks.swift` (readers reused), `BtonCore/GitHub.swift` (PR threads), `BtonCore/Jobs.swift` (reports) |
| U2 Build with memory | U1 | `BtonCore/CodeGraphBuilder.swift`, `BtonCore/CodeGraph.swift` (marker gains `memoryAt`) |
| U3 Instruction line and playbook | U2 | `BtonCore/CodeGraph.swift` (`defaultInstruction`), `BtonCore/PRPlaybook.swift`, `BtonCore/IssueIntake.swift` prompt, `docs/FLOW.md` |
| U4 Measurement | U2, U3 | `scripts/graph-memory-check.sh` (new), this document's after table, `BtonCore/GraphUse.swift` (unchanged, the count exists) |
| U5 Settings and page | U2 | `Sources/Bton/SettingsRepos*.swift` (the switch's text says what the graph holds), repo page's graph line |

### U1 Memory export

Before a graph build, Bton writes the repo's memory as Markdown files graphify maps like any
other file, under `memory/` in the build worktree (`.worktrees/bton-graph`, never the clone or a
job's tree):

- `memory/issues/<n>.md`: title, labels, state, the body and every comment with author and time,
  as `IssueDrafts.thread` already renders an issue. Every issue updated since the last export,
  open or closed; the first export takes the last 180 days.
- `memory/prs/<n>.md`: title, base and head branch, state, merged at, the body, review comments
  and review bodies with author, time and state (`## Review:` and `## Decision:` headings kept
  verbatim so a query for the heading finds them), the list of changed files.
- `memory/jobs/<item>/<started>.md`: the report (`.post` file when the move wrote one, else the
  last message of the session) of every job of this Mac on that item, with move, agent, status,
  cost and head. Only this Mac's: another Mac's jobs reach the graph when that Mac builds its
  graph; GitHub stays the only shared state (decided 2026-10-25, no Bton-to-Bton channel).
- `memory/INDEX.md`: one line per file with its title and date, so a community hub exists for
  the folder.

Reads go through the GraphQL readers Bton has (`openIssues` paginated, PR facts in
`FeatureFacts`), extended for closed issues and PR review threads; one page of 50 per request,
stopped at the `updatedAt` of the last export (kept in the marker). Secrets never: a body is
written as is, but the export runs the same `DispatchPlanner.redact` the posted reviews go through (the repo's environment values), and the
file is excluded when the redaction reports a hit. A body from a contributor is data in a file,
never an instruction; the files carry no front matter an agent could read as config.

Acceptance (a different vendor writes the tests from these lines):

1. `GraphMemory.export(repo:into:since:)` on a fixture of 2 issues (one with a `## Decision:`
   comment), 1 merged PR with a review and 1 job report writes exactly the four kinds of file
   with the names above, and `memory/issues/<n>.md` contains the decision heading verbatim.
2. A second export with `since` after every update writes nothing and returns `unchanged`.
3. A body containing a value of the repo's environment, which `DispatchPlanner.redact` replaces, is not written; the export's log
   names the issue number and nothing of the body.
4. A GitHub error mid-export leaves the previous `memory/` in place and the build goes on with
   it; the marker's `memoryAt` does not advance (fail closed on the newest, keep the last good).

### U2 Build with memory

`CodeGraphBuilder.build` calls the export after `Worktrees.prepare` and before graphify's
rebuild, in the staging copy's worktree. `memory/` is a folder of the worktree that git does
not track (it is listed in the worktree's `.git/info/exclude`), so `git status` stays clean and
the worktree is still reused. The marker gains `memoryAt` (the newest `updatedAt` exported) and
the repo page's graph line says "of <commit>, memory to <time>". A build is also due when the
base did not move but the memory is older than 6 hours and the repo had activity (an issue or
PR updated since `memoryAt`), so a decision reaches the graph the same day without a merge.

Acceptance:

1. A build on a fixture repo produces `graphify-out/graph.json` whose nodes include a file node
   for `memory/issues/<n>.md`, and `graphify-src "decision on #<n>"` run in that worktree prints
   the file's path.
2. With the base unmoved and `memoryAt` 7 hours old and one issue updated since, `refresh`
   builds; with no activity it does not (today's "same commit, built" early return holds).
3. The export's folder never appears in `git status --porcelain` of the build worktree.

### U3 Instruction line and playbook

The default instruction line becomes: "Code graph: graphify-out/ in this checkout is graphify's
graph of {base} at {commit}, with the repo's issues, PRs, decisions and Bton's job reports to
{memoryAt} under memory/; this branch's own changes may not be in it. Ask it with graphify-src
"<question>" before searching the tree or reading GitHub; read GitHub only for the item you work
on and for what is newer than {memoryAt}." The PR playbook's step 2 and the intake prompt say
the same in their own words: what was decided, tried or reviewed before is asked of the graph
first; the live thread of the job's own item stays as injected. A repo with the switch off or
no built graph gets no line and the prompts' "read it fresh" wording, as today. `docs/FLOW.md`
documents the memory folder and the line.

Acceptance:

1. `CodeGraph.instructionLine` with a marker that has `memoryAt` renders the memory sentence;
   with a marker without it (a graph built before this change) renders today's line.
2. The prompts of a review and an intake job on a repo with a graph contain "memory/"; on a repo
   without, they do not.

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
memory with it, and the export costs one GraphQL page per 50 updated items.

## Quality criteria

- Code: Swift 6, files at most 500 lines (`GraphMemory.swift` split into export and renderers
  if it nears it), English identifiers and comments that say why, the layer's casing. Tests by
  another vendor from the acceptance lines, hashed, never edited by the implementer.
- Speed: the export must not delay a build by more than 20 s on lexito (about 600 issues and
  PRs on the first run, then the day's updates): measured with the build log's timestamps
  around the export, and the paginated reads run three pages at a time. graphify's rebuild of
  the added Markdown is its own cost; the first lexito build after the change is timed and
  pasted here.
- Security: the export reads GitHub with the user's `gh` token as every reader does, and writes
  only under the build worktree. Contributor text enters the graph as data; the instruction line
  tells the agent the memory is the repo's record, never instructions, in the words the prompts
  already use for threads. Redaction before write, exclusion on a hit, fail closed on a read
  error (last good memory kept, marker not advanced). The memory folder is never linked into a
  job's worktree as writable: the agent reads it through `graphify-out`, which is a link to the
  store, as today.

## Out of scope

Other Macs' job reports (would need a channel Bton does not have), a memory that updates per
comment (the 6-hour rule is the bound), and any change to how GitHub is read for the job's own
item.
