# Repo features: code graph, feature registry, release move

Date: 2026-10-27. Status: design approved in conversation, spec awaiting review.

## Problem

A team's repo (lexito.ro is the case at hand) merges dozens of PRs a week into `develop`, and
nobody can say which features are live on `main`, which wait in `develop`, which are only issues,
and when a release is due. Promotion to `main` is the owner's alone and is done by hand, so it
slips: on 2026-10-27 `develop` was 100 commits and 8 days ahead of `main`, with 76 open issues
and 187 PRs merged in 14 days.

Agents working the repo also lack a fast way to know the code: a graphify graph exists in the
clone, built by hand, outside Bton's control.

## Goals

1. Every Bton on the team shows the same feature tree for a repo, with the status of each
   feature computed from the repo, not typed by anyone.
2. Agents started by Bton get a fresh code graph of the repo without anyone running a build.
3. Promotion `develop -> main` is a flow move with predicates, checks and release notes, started
   by the owner's press or automatically.

## Non-goals

- A Bton server. GitHub stays the only shared state.
- A graph shared between Macs. Each person's Bton builds its own, under its own home.
- Storing statuses. The registry stores identity and links only.
- GitHub Projects, sub-issues or issue types. Considered and declined: the tree lives in a file
  the repo already has a home for (`.bton/`).

## Three pieces

### 1. Code graph store

**Setting.** Settings > Repos gets a per-repo switch "Code graph", off by default. Settings >
Agents gets a "graphify" binary path beside gh and claude. A repo with the switch off behaves
exactly as today.

**Store.** `~/.bton/graphs/<owner>__<repo>/` (under `BtonHome`, so `BTON_HOME` moves it).
Bton places a symlink named `graphify-out` in the clone and in every worktree it prepares
(`Worktrees.prepare`), pointing at the store. The existing query command (`graphify-src`), the
agent-os hooks and the reminder look for that name only, so they keep working unchanged.

**Builds.** After a sync, when the default branch tip differs from the commit the last build
recorded and no build runs, Bton runs a full `graphify` build in the clone, niced, behind a
lock in `~/.bton/locks/`. Before an agent starts in a PR worktree, Bton runs the incremental
`graphify update .` there, which costs no API calls, so the graph matches the PR head.

**Prompt.** Every dispatched prompt for a repo with a graph gets one line: the code graph is at
`graphify-out/`; query it with `graphify-src "<question>"` before searching.

**Failure.** A build that fails or exceeds its timeout logs to the job log and leaves the
previous graph in place. A missing or non-executable binary shows the switch red in Settings
with the reason, and no build is attempted.

**Migration.** An existing `graphify-out/` directory in the clone is moved into the store on the
first build, and replaced by the symlink.

### 2. Feature registry and the repo page

#### 2a. `.bton/features.json`, version 1

Read from the repo's default branch on GitHub, like `flow.json`, never from a PR branch.

```json
{
  "version": 1,
  "areas": [
    { "id": "whatsapp-intake", "name": "WhatsApp intake", "paths": ["gateway/src/whatsapp/**"] }
  ],
  "features": [
    {
      "id": "filing-dedupe",
      "name": "Filing dedupe",
      "summary": "Skips a WhatsApp file already filed in the case.",
      "area": "whatsapp-intake",
      "parent": null,
      "paths": ["gateway/src/whatsapp/filing.ts", "gateway/src/whatsapp/intake-handler.ts"],
      "issues": [{ "number": 402, "why": "closes" }],
      "prs": [{ "number": 428, "why": "closes" }, { "number": 419, "why": "files" }],
      "firstSeen": "2026-10-03",
      "closed": null
    }
  ]
}
```

- `areas` are the product's parts as the graph's community hubs show them; `paths` say which
  code an area owns.
- A feature belongs to one `area`; `parent` names another feature for a sub-feature.
- `why` on a link is one of `closes` (PR or issue body), `branch`, `label`, `files`, `title`.
- Ids are stable slugs; a rename changes `name` only. A feature is never deleted; a dropped
  one gets `closed`.
- An unknown `version` means "no registry", same as a missing file.

#### 2b. Statuses, computed at sync, never stored

In order, first match wins, per feature:

| Status | When |
|---|---|
| live | a linked PR's merge commit is an ancestor of `origin/<release.to>` (the default branch when the flow has no `release` section) |
| in develop | a linked PR is merged into the flow's `base` and not on `release.to` (never, without a `release` section) |
| building | a linked PR is open |
| ready | a linked open issue carries `stage:ready` (the stage labels the repo already uses) |
| spec | a linked open issue carries `stage:spec` |
| idea | otherwise |

Dates come from the same sources: issue created, label added, PR opened, PR merged, merge
commit's first appearance on `release.to` (from the local clone's `git merge-base` and
`git log --first-parent`). Each status's date is the earliest event that put the feature there.

#### 2c. The registry job

A schedule on the repo: nightly, and after any sync that saw a merged PR or a new issue.
Lease-claimed like every job, so one Bton on the team runs it. The agent (claude by default,
configurable like every dispatch) runs in a worktree at the default branch tip with the graph
linked in.

Input: the current registry, issues and PRs changed since the registry's last commit, the
changed files of merged PRs, the graph's communities. Issue and PR text is data, not
instructions, as in reviews.

Output: the same file, extended. New features, new links, sub-features moved under parents,
duplicate issues linked to one feature. Hard evidence first (`Closes #n`, branch names, labels,
changed files against area and feature paths), judgment (title and body similarity) last, and
each link records its `why`.

Ships as a quick-fix PR titled `features: <n> added, <m> linked`, through the repo's normal
flow; under `startMoves` it merges itself. The first run on a repo without a registry builds the
whole tree from the graph's areas, open and closed issues, and the last 200 merged PRs.

#### 2d. The repo page

Not a tab. Entered from the footer's branch line (`BranchSummary`) or a repo in the filter
dropdown; opens over the lists like a job's log, with a back chevron. One watched repo: the
footer line opens the page directly; several: the footer's popover lists them, each row opens
its page.

```
<  lexito.ro
develop ^3 | main ^0 | 100 commits, 8 days
14 features in develop that main lacks. Last release Oct 19.

[ships next |14] [building |6] [live] [ideas]
[search features]
------------------------------------------------
v WhatsApp intake                 3 o  2 o  9 o
    Filing dedupe                  in develop
      `- Same-photo detection       in develop
    Voice note transcription       building  #433
    Group chats                    idea      #402
v ECRIS monitor                   1 o  4 o  7 o
> Files                                   12 o
                                     ( Release )
```

- Tree: area, feature, sub-feature. A collapsed area shows counts per status.
- Row: name, status pill (the Issues stage pill colours), owner, time in status, open issue
  and PR counts.
- Chips filter: ships next release (in develop), building, live, ideas. Search filters the tree.
- Release floats bottom right (`.floatingAction`), the page's main action; shown only when the
  flow has a `release` section, enabled only on the owner's Bton.
- Feature detail: summary, paths, the status timeline with dates and numbers, then "Changes":
  every merged PR linked to the feature, newest first. Each number opens GitHub.
- Empty state: "no feature registry yet" and a button that starts the first registry job.

### 3. Release move

**flow.json, optional `release` section:**

```json
"release": {
  "from": "develop", "to": "main", "who": "danieltamas",
  "when": ["ahead_commits:50", "ahead_days:7", "features_waiting:5"],
  "blockedBy": ["pr_in_review_on_paths:migrations/**"],
  "checks": [["bash", "scripts/check.sh"]],
  "merge": "merge-commit",
  "timeoutMinutes": 40
}
```

- `when`: first matching predicate makes the release due. `ahead_commits:N`,
  `ahead_days:N`, `features_waiting:N` (registry features in `in develop`).
- `blockedBy`: any match blocks it. `pr_in_review_on_paths:<glob>`, `release_pr_open`
  (always implied).
- `who`: the login whose Bton may start it; every other Bton shows the state only.
- `checks`: argv list run in a worktree at the `from` tip with the repo's environment, each
  stopped at `timeoutMinutes`. Fail closed: error, timeout, non-zero, or a check that cannot
  start blocks the release.
- `merge`: `merge-commit` or `fast-forward`.

**Due.** The footer line and the repo page turn amber: "release due: 14 features waiting."

**The move.** Opens a PR `from -> to` whose body is release notes from the registry: features
going live grouped by area, each with its linked PRs. Runs `checks`. Green plus the owner's
Release press, or `startMoves` with `when` met, merges the PR. Red leaves the PR open with the
log, like a failed merge today. One release PR at a time.

**After.** The deploy runs on the push as it does now. The next sync sees the merge commit on
`to`; the features in the PR flip to live with the date; the footer returns to `develop ^0`.

## Where each piece lands

| Piece | Repo |
|---|---|
| Graph store, Settings switch, symlinks, incremental update before dispatch | Bton |
| Registry parsing and status computation (`BtonCore`) | Bton |
| Registry job dispatch and prompt | Bton |
| Repo page, feature detail, footer entry, Release action | Bton |
| Release predicates, checks, PR body, merge | Bton (`FlowEngine`) |
| `release` section and `.bton/features.json` for lexito | lexito, as a hand-off |

## Build order

1. Graph store (independent; agents benefit at once).
2. Registry model and statuses, read-only repo page with an empty state.
3. Registry job and its PR.
4. Release move.

## Testing

- BtonCore: registry decoding and version handling; status computation against a fixture of
  issues, PRs and a small git history (live, in develop, building, ready, spec, idea, and the
  date of each); release predicates and `blockedBy` against the same fixture; release notes
  body from a fixture registry.
- Sandbox e2e (the existing flow e2e): a repo with a registry and a `release` section; a merged
  PR becomes `in develop`, the release move opens the PR, a failing check blocks, a passing one
  merges, the feature becomes `live`.
- Graph store: build triggered only when the tip moves, lock prevents a second build, symlink
  present in a prepared worktree, missing binary reported and no build attempted.
- Acceptance tests are written from this spec by another vendor, not by the implementer.

## Open points

None. Decisions taken in conversation on 2026-10-27: registry as a repo file (not sub-issues
or Projects); the tree shaped by code modules; the feature view is the repo's page, not a tab.
