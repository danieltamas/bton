# Review as a repo command, tier floored by paths

Date: 2026-10-27. Status: proposed, not started. Asked by Dani after reading Anthropic's
"Solving code review" post and comparing it with lexito's docs/REVIEW-PROCESS.md 3.4.

## Problem

Two things the flow promises are not enforceable with flow.json version 1:

1. **The author sets the tier.** `tier.marker` reads the `Tier:` line of the PR body. A PR
   that edits migrations, auth, billing or `.github/` can say `quick fix` and Bton believes
   it. Anthropic's rule is the opposite: the change sets the tier, and owner-listed paths
   always need a person.
2. **A review is always an agent with a prompt.** Only `merge` can be a command. A repo that
   wants a deterministic review step (a cross-vendor script that loads a security brief when
   the diff touches sensitive paths, posts `R-n` and `S-n` tables, and exits 2 when its vendor
   is unavailable) cannot express it. The agent prompt says "ask codex", and what the agent
   does with the answer is up to the agent.

Nothing here is lexito-specific. Any repo with a sensitive subtree and a review script has
both problems.

## Change 1: `tier.paths`

```json
"tier": {
  "marker": "Tier:",
  "values": ["quick fix", "feature", "high-risk"],
  "default": "feature",
  "paths": {
    "high-risk": ["migrations/**", "gateway/src/middleware/**", "gateway/src/services/billing*",
                  "gateway/src/admin*", ".github/**", "scripts/wt", "scripts/review*"],
    "feature":   ["gateway/src/tools/**"]
  }
}
```

- A PR's tier is the highest of: the marker's value (or `default`), and every entry of
  `paths` whose glob matches one of the PR's changed files. Order of `values` is the order of
  severity, lowest first.
- Changed files come from GitHub (`pulls/{number}/files`), read at the same time as the PR,
  never from the local tree. More than 3000 files: treat as the highest tier.
- The PR row shows the effective tier and, when it differs from the marker, why
  (`high-risk: migrations/031_x.sql`). The review move's prompt or command gets `{tier}`.
- Globs: gitignore syntax, matched against the path from the repo root. No negation.
- Missing `paths`: today's behaviour.

## Change 2: `dispatch.<move>.command` for every move, with `post`

Today `command` is accepted on `merge` only, and its output is not posted. Generalise:

```json
"review": {
  "command": ["bash", "scripts/review-pr.sh", "{number}", "{head}", "{tier}"],
  "post": "comment",
  "timeoutMinutes": 30
}
```

- Any move may carry `command` instead of `agent` + `prompt`; both at once is a config
  error reported on the repo row.
- Substitutions: `{repo}`, `{number}`, `{head}`, `{base}`, `{issue}`, and new `{tier}`.
  Nothing else; PR text never enters an argv.
- Run in the worktree of the PR head, with the repo's environment from Settings > Repos,
  after the flow's `checks.beforeSession`, under the move's timeout. Same lease, same
  once-per-head rule, same head re-read right before the command as `merge` has.
- `"post": "comment"`: Bton posts the file the command writes to `$BTON_OUT` (a path Bton
  passes in the environment) as a PR comment, only if its first line matches a heading the
  flow's `reviews` lists for the PR's tier. Any other first line, an empty file, or a
  non-zero exit: the job fails, nothing is posted, the move stays open.
- Exit 2 is reserved: "the vendor is unavailable". Bton shows it as waiting, not failed,
  and retries on the next sync after `retryMinutes` (default 30). This is what lets a review
  script refuse to self-review when codex is missing on this Mac.
- A command review posted by Bton carries the login of this Mac's `gh`. The `reviews`
  rules (`notByAuthor`) apply to it exactly as to an agent's comment, so a command run on the
  author's Mac still cannot approve a feature.

## What stays in the repo, not in Bton

- Which paths are sensitive: `tier.paths` in the repo's flow.json.
- What a security finding is and when it blocks: the repo's review script and merge gate
  (`scripts/review-pr.sh`, `scripts/review.ts`, run by `checks.beforeMerge` and
  `dispatch.merge.command`). Bton runs them, it does not interpret `S-n` rows.
- The brief the script loads (lexito: `SECURITY_REVIEWER.md`).

## Teammates' Macs

Nothing per machine beyond what exists: the `agents` config entries and the `gh` login. A
Mac whose config lacks a helper the script needs sees exit 2 and the move waits for a Mac
that has it, or for "Take teammates' moves". The flow is read from the base branch on
GitHub, so every Bton switches to the new flow at the merge that adds it.

## Tests

- Tier: marker says `quick fix`, a changed file matches a `high-risk` glob, effective tier
  is `high-risk` and the row says which file. No `paths`: marker wins. Both missing:
  `default`.
- Command review: first line matches a listed heading, comment posted, move advances.
  First line does not match: nothing posted, job failed. Exit 2: nothing posted, job shown
  as waiting, retried after `retryMinutes`.
- `notByAuthor`: a command review posted from the author's Mac on a feature does not count.
- Head moved between start and command: nothing runs, as for `merge`.
- `command` and `agent` on the same move: config error, no dispatch for that repo.

## Out of scope

Running codex from inside an agent's sandbox (unchanged: helpers only), an OS sandbox for
checks (docs/AUDIT.md item 2), and the lexito-side script and gate, which are lexito issues.
