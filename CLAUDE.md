# Bton: project rules

UI:
- A list's main action (New issue, and any like it) floats at the bottom right over the list with
  `.floatingAction(...)` (Components.swift): never a button in a row or bar above the list. Actions
  inside a form or a conversation (Send, Create issue, Apply) stay in the footer under their content.
- Everything clickable shows the pointing-hand cursor: use `PillButton`, `IconButton`, a button with
  `PressStyle`, or `.pointingHandCursor()`. A native `Menu` or `Picker` does not, so build selectors
  from a button and a popover.
- A choice that belongs to the screen's title (which repo the new issue goes in) sits under the
  title, not in a block of its own with the same value repeated elsewhere.
- One direction for depth: a page one level deeper comes in from the right and leaves to the
  right (`.transition(.push)`); the page it covers goes out to the left and comes back from the
  left (`.pushed`, or the offset in `RootView.content` when the covered page is itself a pushed
  page: a transition set on a mid page is fixed at its last render and would leave the wrong way).
  Check both directions in the built app before calling a new page done.
- A job on a row is that row, working: the card glows, a working line under it says what the
  agent does and that a click watches it, and the click opens the session. Never a second card
  for the same job; the Active now cards are only for jobs with no row.

Several agents in this repo (enforced by `scripts/hooks`, activated once per clone with
`git config core.hooksPath scripts/hooks`; run that first thing if `git config core.hooksPath`
prints nothing):
- Every commit is authored and committed by the owner, Daniel Tamas <hello@danieltamas.ro>, with
  no co-author trailer; the `pre-commit` and `commit-msg` hooks refuse anything else. A helper
  agent (Codex writing tests, a reviewer, a subagent) never runs `git commit`: it leaves its files
  in the worktree and the session that asked for them stages and commits them.
- Work in a worktree, `.worktrees/<branch>`, branched from main. The main checkout is for
  merging and releasing only. Before the first write: `repo-sync peers`, then
  `repo-sync claim --task "<what>" <paths>`; stage by path, commit only hunks you wrote.
- A change lands on main by `git merge --ff-only` of a branch rebased onto main, with the full
  suite green on the rebased tip, and never while `repo-sync peers` shows a task starting with
  `release`: the `reference-transaction` hook refuses to move main then. Wait for the release.
- LOG.md: a change adds its paragraph under one `## Unreleased` heading at the top of LOG.md, in
  the voice of the entries below. Never write a `## x.y.z` heading in a feature commit; the
  release turns `## Unreleased` into the version heading. The `pre-commit` hook refuses a second
  `## Unreleased` or one that is not first.
- Releasing (`/release`): from the main checkout, after `repo-sync claim --task "release vX.Y.Z"
  LOG.md .release.json Sources Tests`, so every other session sees main is held; rename
  `## Unreleased` to the version, run `release`, then `repo-sync release`. A release that fails
  mid-way is resumed with the same command, not restarted.
- Before anything ships, the owner sees it running: from `.worktrees/preview` (branch `preview`
  off main) lay every unshipped branch's working-tree diff (LOG.md left out) and untracked files
  over main, then `scripts/bundle.sh --scratch /tmp/bton-preview --out /tmp/bton-preview-app
  --source preview-<main sha>+<branch count>` and `./install.sh --app /tmp/bton-preview-app/Bton.app`.
  Before installing, grep the bundled binary for one string from each branch (a build from the
  wrong directory bundles fine and ships the wrong app). Say what is installed and stop. Merging,
  releasing and the worktree cleanup wait for the owner
  to say the local install is right; the preview worktree and branch go once the release is out.
