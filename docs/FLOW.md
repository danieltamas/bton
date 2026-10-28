# `.bton/flow.json`, version 1

A repo's flow tells Bton whose move each open PR is and what Bton may start for it. Bton reads
the file from the repo's **default branch** on GitHub, never from a PR branch or a local
clone, so a PR cannot change the commands Bton runs. A missing file means "no flow": the repo's
PRs are shown and nothing is dispatched. An unknown `version` means "flow not supported", with
the same result.

Examples: [`examples/team.flow.json`](../examples/team.flow.json) (a three-tier review process
with a decision step) and [`examples/sandbox.flow.json`](../examples/sandbox.flow.json) (the e2e test's).

## Fields

| Field | Meaning |
|-------|---------|
| `version` | `1`. |
| `base` | The branch PRs must target. A PR with another base is shown and never dispatched. |
| `tier` | `{ "marker", "values", "default", "paths"? }`: how a PR body names its tier, and which changed files raise it (below). |
| `reviews` | Per tier, the headings that count as a review: `[{ "heading", "notByAuthor"? }]`. |
| `fixed` | The heading of a response comment, e.g. `## Fixed:`. |
| `reviewers` | Optional logins for the reviewer rotation (below). |
| `moves` | Ordered list of `{ "move", "when": [predicate...], "who", "owner"? }`. First match wins. `owner` is `who` for Btons from 0.14.1 on, read instead of `who` when present (below). |
| `dispatch` | Per move name, what Bton starts for it (below). A move without an entry is a human's. |
| `checks` | `{ "beforeSession": [argv...], "beforeMerge": [argv...] }`. A merge rule with `checks_green:<name>` lets `beforeMerge` drop the suite that CI already ran on the head (lexito: about 4 minutes per merge); a PR whose CI is still running has no due move until it is green, so put a human move after it (`{ "move": "ci", "when": ["approved_current_head"], "who": "author" }`) if the row should say so. The argv run in the worktree with the repo's environment from Settings > Repos, each stopped after the move's `timeoutMinutes`; their output reaches the job's log as it comes. When a person started the move (Merge, the move's pill, Retry, Run Next, Take it) rather than the sync, checks and the merge command also see `BTON_PRESSED=1`, so a check that guards a person's decision can let the press through: `["bash", "-c", "test -n \"${BTON_PRESSED:-}\" \|\| git diff --quiet origin/develop...HEAD -- migrations/"]`. |
| `intake` | Optional: how an agent takes a `stage:ready` issue (below). |
| `caps` | `{ "openPullRequestsPerDeveloper", "openPullRequestsTeam" }`, checked before intake. |
| `stale` | `{ "pingHours", "escalateHours", "escalateTo" }`. |
| `decision` | Optional `{ "heading", "move", "by" }`: a ruling that ends a review loop (below). |
| `release` | Optional `{ "from", "to", "who", "when", "blockedBy"?, "checks"?, "merge"?, "timeoutMinutes"? }`: how `from` (develop) is released to `to` (main). `when` is a list of predicates of which the first match makes a release due, with its reason on the page and in the footer (`ahead_commits:N` -> "N commits ahead", `ahead_days:N` -> "N days ahead", counted from the oldest commit `to` lacks, `features_waiting:N` -> "N features waiting", the registry's features in develop); `blockedBy` any match blocks it (`pr_in_review_on_paths:<glob>`: an open, non-draft PR into `from` touching the glob; `release_pr_open` is implied and only keeps a second release PR from opening, never the merge of the open one); `who` is the login whose Bton opens and merges it, everyone else sees the state; `checks` are argv run in a worktree at the release PR's head (the `from` tip) before the merge, each stopped at `timeoutMinutes` (40 by default), failing closed; `merge` is `merge-commit` (default: `gh pr merge <n> --merge --match-head-commit <head>`) or `fast-forward` (`git push origin <head>:refs/heads/<to>`, refused when `to` moved). When due (or on the owner's Release press on the repo's page, which skips `when` but not `blockedBy`), Bton opens the PR `from -> to` titled `Release <from> -> <to>: <n> features` with the release notes from the registry; the open PR merges on the press, or on its own when the repo starts its moves and the release is still due. The release PR gets no flow move. With a `release` section the repo page tells a feature "in develop" from one "live" on `to`. |

`who`, `dispatch.<move>.agent` and `dispatch.<move>.prompt` take either one value or an object
keyed by tier (`{ "quick fix": "author", "feature": "assignee" }`).

## Tier

The tier comes from the first line of the PR body that contains `tier.marker` (for example
`Tier:`, compared ignoring case). In the rest of that line, each of `tier.values` is looked for
as a whole word or phrase, ignoring case. If exactly one value appears, that is the tier;
otherwise (no such line, no value, or several) it is `tier.default`. So the PR template's
unedited `**Tier:** quick fix | feature | high-risk` gives the default.

Lines like these are all valid: `**Tier:** quick fix`, `Tier: quick fix.`,
`**Tier: quick fix.** No migration...`, `**Tier: High-risk** (migration, PII).`,
`**Tier:** feature. No migration, no runtime code...`.

### Tier floored by paths

The author names a tier, but the change sets a floor. `tier.paths` maps a tier to globs:

```json
"tier": { "marker": "Tier:", "values": ["quick fix", "feature", "high-risk"], "default": "feature",
          "paths": { "high-risk": ["migrations/**", ".github/**", "scripts/wt"], "feature": ["gateway/src/tools/**"] } }
```

A PR's tier is the highest of the one its body names (or `default`) and every `paths` tier that
one of its changed files matches, in the order of `values` (lowest first). The files come from
GitHub with the PR, never from the local tree; a PR with more than 3000 changed files (all GitHub lists) counts as the
highest tier. The PR row's tier chip says what raised it on hover (`high-risk: migrations/031_x.sql`)
and `bton moves` prints it. Globs follow gitignore syntax against the path from the repo root: `*`
and `?` stay inside one path part, `**` crosses parts, a pattern with a slash is anchored at the
root and one without matches at any depth, and a directory's pattern covers what is under it.
There is no negation or `[...]` class, and a `paths` key that is not one of `values`, or a pattern
starting with `!` or containing `[` or a backslash, makes the flow invalid. A PR whose file list
GitHub did not return counts as the highest tier. Without `paths` the body's tier stands.

## Reviews

Only a comment's **first line** is read. It is a review when:

1. it starts with a heading listed for the PR's tier in `reviews`;
2. right after the heading (spaces allowed) comes the verdict word `approve`, `changes` or
   `blocked` (ignoring case). Words after the verdict are fine: `## Review: changes needed`,
   `## Review: approve with nits`;
3. somewhere after that it names a head: `(head ` then 7 to 40 hex digits, optionally in
   backticks: `(head 1d7d8b35)`, `(head 1d7d8b35; high-risk: ...)`, ``(head `94836b2b`)``;
4. if the heading's entry has `"notByAuthor": true`, the comment's author is not the PR's author.

A heading without the verdict word or without a head is not a review and changes nothing. A
review's head **matches** the current head when the PR's `headRefOid` starts with it (ignoring
case).

A **response** is a comment whose first line starts with `fixed`, or a push (the current head
no longer matches the latest review's).

Comments carrying Bton's marker `<!-- bton:` anywhere in the body are dropped before any of
this: Bton's own failure and staleness comments never change a move.

A **decision** is a comment from one of `decision.by` (with write access) whose first line is
`<decision.heading> approve|changes|blocked (head <sha>)`. It counts as a review in every tier,
also on a PR its writer authored (`notByAuthor` does not apply), so an approve on the current
head makes the move `merge` and a `changes` makes it `fix`. `changes_rounds_at_least` counts only
the reviews after the latest decision, so the round cap starts over. When the `decision.move`
move is dispatched with `"post": "comment"`, its agent's final message must start with the
decision heading, and once Bton posts it, it removes the labels that held that move (its
`label:` conditions no other rule names), so the PR moves on; if one can't be removed, the job
fails saying which. A `decision.heading` that overlaps a review heading makes the flow invalid.
Limit: a decision move runs once per head, so a second round cap on the same head (fixes and
reviews without a push) waits for the next push.

## Predicates

All predicates of a move's `when` must hold. An empty `when` always holds.

| Predicate | Holds when |
|-----------|------------|
| `label:<name>` | the PR has that label |
| `draft` | the PR is a draft |
| `conflicting` | GitHub reports the PR conflicts with its base. `UNKNOWN` (GitHub still working it out after a push) does not count |
| `no_review_or_response_newer` | no review counts yet, or the current head does not match the latest review's, or a `fixed` comment is newer than the latest review |
| `approved_current_head` | the latest review's verdict is `approve` and its head matches the current head, or a commit the current head reaches through merge commits alone (a conflict fix merging the base in), so a fixed conflict goes straight to the merge and not back to review |
| `latest_review_changes_or_blocked` | the latest review's verdict is `changes` or `blocked` |
| `changes_rounds_at_least:<n>` | the latest review's verdict is `changes` or `blocked`, and at least `n` of the PR's counting reviews since the latest decision have a `changes` or `blocked` verdict |
| `checks_green:<name>[,<name>...]` | every named GitHub check (a check run's name, or a commit status's context) is green on the head commit: completed with the conclusion SUCCESS, or the status SUCCESS. Pending, failed, cancelled, skipped, neutral or absent is not green, nor is a head with more checks than Bton read (50), nor a PR that changes a file under `.github/workflows/` or more files than were read: a `pull_request` workflow runs the PR's own copy of the workflow, so such a PR is not vouched for by its check. A re-run replaces the older run of the same name. Names are trimmed; an empty name makes the flow invalid. A command move whose rule has this predicate reads the checks again on the exact head right before the command and refuses (`checks not green: gate pending`) when any is not green or the read fails |

"Latest" is by comment creation time.

## Who

- `author`: the PR's author.
- `assignee`: the PR's first assignee. With none, and `reviewers` set, the **rotation** picks
  one: `reviewers` without the PR author (ignoring case), indexed by the PR number modulo its
  length. Every Mac computes the same pick. The author's Bton assigns that login on GitHub, once
  per PR; an assignee a person sets is never replaced. With no `reviewers` (or none left after
  removing the author) the owner is "unassigned" and the move is never dispatched.
- `reviewer`: the PR's first requested reviewer (GitHub's "Reviewers" field; team requests are
  ignored), with the same rotation when nobody is requested. The author's Bton requests the pick's
  review on GitHub, once per PR; a request a person made is never replaced, and the assignee field
  is never touched. GitHub ends a user's request when they submit a review, and Bton files a GitHub
  review with every review comment, so after each round the request is gone and the move returns
  to the rotation's pick: the same login when the pick reviewed, the rotation's rather than the
  taker's after a Take it. A person who wants the next round too requests their own review again
  on GitHub. Use `reviewer` where the team reads "assignee" as "owns the PR" rather than "reviews
  it".
- any other string: that login.

A move is **mine** when its owner equals this Mac's `gh` login, ignoring case.

**Switching to `reviewer` while some Macs run an older Bton.** A Bton before 0.14.0 reads a `who`
it does not know as a login, so `who: reviewer` stalls its moves. Write
`"who": "assignee", "owner": "reviewer"` instead: a Bton from 0.14.1 on reads `owner` in place of
`who` (same shape, one value or per tier), an older one reads `who` and ignores `owner`. In the
meantime the older Macs assign the rotation's pick and the newer ones request that pick's review:
the same login on a PR nobody touched by hand, so the move is the same person's on every Mac. An
assignee or a request a person set, or a Take it (which changes only its own field), can split the
owner between old and new Macs for that PR until the fields agree. Once every Mac has updated,
move the value into `who` and drop `owner`.

**Take it.** A dispatchable move whose `who` for the PR's tier is `assignee` or `reviewer`, owned
by someone else (or by nobody), can be taken from its row: under the PR's lease, and only if a
fresh read still shows the owner the row showed, Bton makes this Mac's login the PR's only assignee
(`assignee`) or only requested reviewer (`reviewer`, where the row's button reads "Review here";
never offered to the PR's author, whose review GitHub refuses to request) on GitHub and starts the
move here. Every Mac then reads the move as this one's; a teammate's Bton that read the
PR just before and is already starting the move may still run it first, and then this Mac's start
finds the move done. A repo with **Take teammates' moves automatically** on (Settings > Repos, needs
"Start the flow's moves"; `takeMoves` in the config) does this on its own each sync for every move Take it could take, at most two PRs a sync,
once per PR, owner and head, and without `BTON_PRESSED`. It is not offered when the move
would then be one the author can't clear, nor for an `author` or named move, which no assignment
changes.

A move whose `when` has `no_review_or_response_newer`, on a tier where every `reviews` entry has
`"notByAuthor": true`, can't be cleared by the PR's author. When its `who` is `assignee` or `reviewer` and the
owner is the author (they assigned themselves, or requested their own review), Bton shows it as needing another reviewer and never dispatches it: the
agent's review would be posted as the author and ignored.

## Dispatch

```json
"dispatch": {
  "review": { "agent": { "quick fix": "codex", "feature": "claude" }, "prompt": "...", "post": "comment",
              "helpers": ["codex"], "timeoutMinutes": 60 },
  "fix": { "agent": "claude", "prompt": "..." },
  "merge": { "command": ["gh", "pr", "merge", "{number}", "--squash", "--match-head-commit", "{head}"] }
}
```

- `agent` names an entry in this Mac's `agents` config. A Mac without that entry never starts
  the move.
- `prompt` may use `{repo}`, `{number}`, `{head}`, `{base}`, `{issue}`, `{tier}` (the PR's tier, floored by
  `tier.paths`). Nothing else is
  substituted: PR and issue text never goes into a prompt or an argv.
- **Services first.** Before any job of a repo starts, Bton asks each URL with an explicit port in
  the repo's environment (Settings > Repos: `DATABASE_URL`, a Redis) for a TCP connect, two seconds
  at most. One that does not answer (refused, timed out, a name that does not resolve) holds every
  job of the repo for that sync, pressed picks included, with the reason on their cards: "nothing
  answers at 127.0.0.1:55439; start the service (Docker?) and Bton goes on". The owner gets one
  notification per outage. The next sync where the service answers starts the jobs; nothing else
  changes, and a job already running is not touched.
- **Feature context.** When the repo has a `.bton/features.json` that loads, every agent job gets
  `feature-context.md` in its scratch directory: what the registry knows about the PR or issue (the
  feature it links, or the features and areas whose paths the PR touches; area, paths, merged PRs
  with their titles and dates, open issues; the map of areas) so the agent reads one page before
  searching the tree. Bton appends one line of its own to the prompt naming the file; when the
  registry links the work to exactly one feature and the move edits the PR (not a review, not the
  supervisor), the line also asks for `Feature: <id>` in the PR body, which the registry job then
  links as hard evidence (`why: feature`). Everything but that id travels as data. A codex job is
  also told its scratch directory and the code graph line in the task text, as Claude is in its
  system prompt.
- `"post": "comment"`: Bton posts the agent's final message as a PR comment, only if its first
  line is a review (rules above) naming the current head.
- `command`: an argv run instead of an agent (merge, or a review), in a fresh worktree of the base
  (the base branch, never the PR's head, so a PR cannot rewrite the script that reviews it). A move
  takes a `command` or an `agent`, never both. After the
  checks, right before the command, Bton re-reads the PR on GitHub and runs it only if the PR is
  still open at the head the move started on (`{head}`); a moved head, a closed PR or a failed
  read fails the job and nothing runs. The command should still pin that head
  (`gh pr merge {number} --squash --match-head-commit {head}`) to close the seconds between the
  read and the merge. A team's own merge script must do the same: pass it `{head}` and have it
  refuse any other head.
- A command on a move with `"post": "comment"` is a review command: it gets `BTON_OUT`, a file
  path, and writes the review there. Bton posts it under the same rules as an agent's final
  message (first line a review heading of the PR's tier naming the current head; anything else
  fails the job and posts nothing). Exit 0 posts; exit 2 means "unavailable here" (a tool this Mac
  lacks): nothing is posted, the job shows `waiting: ...` and runs again after 30 minutes (at once if you press it), so a
  Mac that has the tool takes it; any other exit fails the job. Pass the PR's head and tier to the
  script with `{head}` and `{tier}`.
- `helpers`: up to three agents of this Mac's `agents` config that a Claude agent may ask for a
  second opinion through Bton's `ask` tool (`mcp__bton__ask`). Bton runs the helper itself,
  outside the agent's sandbox, Claude and codex read-only (any other program as its template
  says): an agent cannot run codex from its own Bash, since the
  sandbox keeps codex from its service. A helper missing on this Mac is skipped with a note in
  the job's log. Write the prompt to say "ask codex", not "run codex".
- `timeoutMinutes`: default 60. Each of the flow's `checks` run before the move gets the same
  allowance on its own; check time does not use up the command's or the agent's.
- `"checks": false`: the flow's `checks` do not run before this move. A `resolve` agent works
  on a PR that conflicts with its base, which a merge check such as `git merge-tree` refuses.

A move is dispatched only when it is mine, has a `dispatch` entry, the PR targets `base`, and
the PR's author is `OWNER`, `MEMBER` or `COLLABORATOR` on the repo.

A move runs once per head on any Mac, whether it succeeds or fails. When a failure's cause is
fixed (a missing variable, a down database), Retry on the failed or stopped job in the Jobs tab
runs it again on the same head, first in line, if it is still the PR's move.

A PR row shows **Merge** on a PR I authored that GitHub reports mergeable, at any move, when
the flow has a `merge` dispatch, the PR is not a draft, targets `base` and its author is
trusted: it runs that dispatch (the repo's merge command and its checks decide), and a push
before it starts cancels it. A `merge` or `resolve` move of mine that Bton would dispatch shows
**Merge** or **Fix conflicts**.

A PR I authored that GitHub reports conflicting is resolved by Bton itself, whatever its move,
once per head and without the flow's checks: the flow's `resolve` dispatch when it has one,
otherwise the `fix` agent, or else the `review` agent, with Bton's own prompt (merge the base in, resolve keeping both
sides' intent, test, push). Settings > Repos turns this off per repo; the
row's **Fix conflicts** then starts it. Either starts the move now, first in line, and
again when it failed or was stopped on this head on this Mac (a failure on another Mac is
retried there). A `resolve` move that fails waits for a new head or one of these buttons:
it never loops.

## Intake

`intake` lets a Bton take an issue nobody has, so a `stage:ready` issue does not wait for someone
to start it by hand. A repo takes issues when it starts its moves (Settings > Repos, "Start the
flow's moves") and its flow has `intake`; the Issues tab lists every ready issue of every watched
repo, taken or not, and every `stage:in-progress` issue with who has it, so nobody starts what a teammate
(with Bton or not) already works on. All of it shows whatever is configured.

```json
"intake": {
  "search": ["repo:{repo}", "is:issue", "is:open", "no:assignee", "label:stage:ready"],
  "priority": ["priority:high", "priority:medium", "priority:low"],
  "claim": [["gh", "issue", "edit", "{issue}", "--repo", "{repo}", "--add-assignee", "@me",
             "--add-label", "stage:in-progress", "--remove-label", "stage:ready"]],
  "worktree": ["bash", "scripts/wt", "new", "issue-{issue}", "{type}"],
  "worktreePath": ".worktrees/issue-{issue}",
  "type": { "default": "feat", "labels": { "bug": "fix", "docs": "docs", "chore": "chore" } },
  "agent": "claude",
  "prompt": "Implement issue #{issue} of {repo} ...",
  "timeoutMinutes": 120
}
```

- **Which issue.** `search` is checked against the issues Bton already read, not sent to GitHub.
  It understands `repo:`, `is:issue`, `is:open`, `no:assignee`, `label:<name>` and `-label:<name>`;
  any other term (or a label with a space) means nothing is taken, rather than something the search
  would have left out. The issue's author must be `OWNER`, `MEMBER` or `COLLABORATOR`, like a PR's.
  The most urgent first by `priority` (labels, first is most urgent; an issue with none goes last),
  then the oldest. `no:assignee` is how a person working by hand keeps an issue from Bton: assign
  yourself.
- **When.** One intake job at a time per repo, after the repo's PR moves and schedules have had
  their turn, and only while `caps` allow it: my open PRs in the repo under
  `openPullRequestsPerDeveloper` and all its open PRs under `openPullRequestsTeam`.
- **How.** Under the issue's lease (`issue-<n>`), Bton reads the issue again; if it is no longer
  what `search` finds, nothing starts and the key is not used up. Then it runs each `claim` argv in
  the clone, so the issue leaves the search before the lease is released (a claim that fails stops
  the job before any worktree), then `worktree` in the clone, and starts `agent` in `worktreePath`
  with `prompt`. A `worktreePath` that already exists is someone's work: the job fails and touches
  nothing. `{issue}`, `{repo}`, `{base}` and `{type}` (the first of the issue's labels `type.labels`
  maps, else `type.default`) are the only substitutions; issue text never reaches an argv or the prompt.
  The feature context above applies: an issue the registry links gets its feature, and the agent is
  asked to write `Feature: <id>` in the PR body.
- **The PR.** Bton opens none: the prompt tells the agent to follow the repo's own process (its
  AGENTS.md, its tier, its tests) and open the PR against `base` when the work is complete, which
  is the point where the repo hands the move to a reviewer. The job counts as succeeded only when
  the branch it worked on has an open PR on GitHub; an agent that exits without one fails the job
  ("finished without opening a PR") and the issue stays visible in the Issues tab with Retry. A
  draft PR succeeds with a note: it is still the author's move. From the PR on, the repo's own
  `moves` take over on the Mac of the PR's author: the reviewer rotation assigns a reviewer, and
  when a review asks for changes the author's Bton runs the flow's `fix` move, so the answer to a
  review reaches whoever worked the issue. A flow should therefore have a `fix` dispatch.
- **Once.** Like a PR move, an issue runs once per Bton home and repo. Retry on the failed or stopped job in
  the Jobs tab runs it again: the claim is skipped when the issue is already mine, and an existing
  worktree is reused.
- **How long it runs.** For an issue, `timeoutMinutes` is an idle limit, not a total: the job is stopped
  only after that long with no commit and no change in its worktree, and never runs past 8 hours. A job
  stopped that way keeps its worktree, and Retry resumes it.
- **Which agent, model and effort.** The flow names the agent; this Mac decides how it runs. Settings >
  Repos > Issue work takes `agent:model effort` (`claude:sonnet medium`) from the agents installed here,
  and Reviewer takes the same for the review moves that post a comment (`codex:gpt-6-astra high`) plus
  rules added to the review prompt. Claude gets `--model` and `--effort`; codex gets `-c model=` and
  `-c model_reasoning_effort=`. Neither is in the flow: models differ per machine.
- **Take.** A ready, unassigned issue in the Issues tab has a Take pill: the next sync claims it and
  starts the job first in line, also where the repo does not start its moves. It skips the PR caps like
  Retry and passes every other gate.
- **A job that dies with Bton.** An issue's job that ends because Bton or its Mac went away (no exit
  status, a lease lost while Bton was down, or Bton stopping before the agent started) is marked to run
  again at once, in every repo, whether or not it starts its moves: the next sync resumes it in its
  worktree while the issue is still assigned to you. A job that failed on its own (the agent exited with
  an error, timed out, or opened no PR) is not: it waits for Retry.
- **Limits.** The caps count open PRs, and a job's PR does not exist until the agent opens it, so
  Bton instances on several Macs that sync at the same moment can each start one issue and briefly
  exceed `caps` by the number of Macs. `claim` should be a single command: a multi-command claim
  that fails half-way leaves the issue neither ready nor mine. The read is the 50 newest open issues
  plus the 50 newest at each of `stage:ready` and `stage:in-progress`; more ready issues than that
  and the oldest are not seen. Load more in the Triage tab makes the read one page (50) longer, up
  to 10 pages, and the search in the issue tabs asks GitHub across all open issues, display only. Retry (the owner's press) does not wait for the caps.
