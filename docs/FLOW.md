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
| `tier` | `{ "marker", "values", "default" }`: how a PR body names its tier (below). |
| `reviews` | Per tier, the headings that count as a review: `[{ "heading", "notByAuthor"? }]`. |
| `fixed` | The heading of a response comment, e.g. `## Fixed:`. |
| `reviewers` | Optional logins for the reviewer rotation (below). |
| `moves` | Ordered list of `{ "move", "when": [predicate...], "who" }`. First match wins. |
| `dispatch` | Per move name, what Bton starts for it (below). A move without an entry is a human's. |
| `checks` | `{ "beforeSession": [argv...], "beforeMerge": [argv...] }`, run in the worktree with the repo's environment from Settings > Repos, each stopped after the move's `timeoutMinutes`; their output reaches the job's log as it comes. |
| `intake` | Optional: how an agent takes a new issue. Parsed, not dispatched yet. |
| `caps` | `{ "openPullRequestsPerDeveloper", "openPullRequestsTeam" }`, checked before intake. |
| `stale` | `{ "pingHours", "escalateHours", "escalateTo" }`. |
| `decision` | Optional `{ "heading", "move", "by" }`: a ruling that ends a review loop (below). |

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
| `approved_current_head` | the latest review's verdict is `approve` and its head matches the current head |
| `latest_review_changes_or_blocked` | the latest review's verdict is `changes` or `blocked` |
| `changes_rounds_at_least:<n>` | the latest review's verdict is `changes` or `blocked`, and at least `n` of the PR's counting reviews since the latest decision have a `changes` or `blocked` verdict |

"Latest" is by comment creation time.

## Who

- `author`: the PR's author.
- `assignee`: the PR's first assignee. With none, and `reviewers` set, the **rotation** picks
  one: `reviewers` without the PR author (ignoring case), indexed by the PR number modulo its
  length. Every Mac computes the same pick. The author's Bton assigns that login on GitHub, once
  per PR; an assignee a person sets is never replaced. With no `reviewers` (or none left after
  removing the author) the owner is "unassigned" and the move is never dispatched.
- any other string: that login.

A move is **mine** when its owner equals this Mac's `gh` login, ignoring case.

## Dispatch

```json
"dispatch": {
  "review": { "agent": { "quick fix": "codex", "feature": "claude" }, "prompt": "...", "post": "comment",
              "helpers": ["codex"], "timeoutMinutes": 60 },
  "fix": { "agent": "claude", "prompt": "..." },
  "merge": { "command": ["bash", "scripts/wt", "merge", "{number}"] }
}
```

- `agent` names an entry in this Mac's `agents` config. A Mac without that entry never starts
  the move.
- `prompt` may use `{repo}`, `{number}`, `{head}`, `{base}`, `{issue}`. Nothing else is
  substituted: PR and issue text never goes into a prompt or an argv.
- `"post": "comment"`: Bton posts the agent's final message as a PR comment, only if its first
  line is a review (rules above) naming the current head.
- `command`: an argv run in the worktree instead of an agent (merge). A merge command should
  pin the head the checks ran on (`gh pr merge {number} --squash --match-head-commit {head}`),
  so a push between the checks and the merge is refused.
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
