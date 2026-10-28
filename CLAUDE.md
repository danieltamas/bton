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

Several agents in this repo (enforced by `scripts/hooks`, activated once per clone with
`git config core.hooksPath scripts/hooks`; run that first thing if `git config core.hooksPath`
prints nothing):
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
