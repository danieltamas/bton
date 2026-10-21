# Security

## Reporting a vulnerability

Report it privately through GitHub's "Report a vulnerability" button on this repository's
Security tab. Please do not open a public issue. Include what an attacker controls, what they
gain, and the steps to reproduce. You will get an answer within a week.

## Scope

Bton runs agents on a developer's Mac against a team's GitHub repos. The threat model below
says what it defends and what it leaves to the repo's own settings (branch protection,
collaborator access). In scope, for example:

- a PR, issue or comment from someone who is not an owner, member or collaborator that makes Bton start an agent,
  count a review, or run a command;
- a PR that changes which commands Bton runs or which agent flags it passes before it merges;
- a way for one Mac to take or keep a lease another Mac holds;
- Bton writing a credential or PR text where it was not meant to go.

Out of scope: what an owner, member or collaborator can do through the code of their own PR,
which runs on the Mac that takes the move by design.

## Threat model

The threat model is a team that trusts its collaborators, not a public repo open to anyone.

- `flow.json` comes only from the branch PRs merge into, on GitHub.
- Bton dispatches only for PRs whose author is OWNER, MEMBER or COLLABORATOR, and counts reviews
  only from those. Anything else is shown, never acted on. This is GitHub's `authorAssociation`,
  not a permission check: an organization member or collaborator with read-only access passes
  it. Keep the repo's member and collaborator list to people you trust to run code on your Mac.
- PR and issue text never reaches a shell, an argv or a prompt; agents read it themselves under
  instructions that treat it as data.
- Agents' permissions are set per Mac, never by the repo, and hardened at launch:
  a PR's `.claude/settings.json`, `CLAUDE.md` and `.mcp.json` never load, GitHub writes that
  skip the merge gate are denied, Claude Code's sandbox is always on, and the team's
  instructions come from the branch PRs merge into. Each Claude agent writes scratch files only
  to its own directory, removed when the job ends. Codex runs with `--ignore-user-config` and
  hooks off, so no MCP server, plugin or hook starts, and a PR's `.codex/config.toml` configures
  nothing; only the owner's model, reasoning effort and service tier carry over.
- Bton changes the owner's own checkout in one way: after a sync it fast-forwards the local
  working and default branches that are only behind origin (`merge --ff-only
  --no-overwrite-ignore` in the folder that has the branch checked out, while it still does).
  Git refuses when that would overwrite uncommitted changes; a branch with local commits is only
  reported.
- No token is stored: `gh` holds the credential.
- Bton writes on GitHub only: lease refs, the rotation's assignee, review and decision comments
  of a `post: comment` move, removal of a decided move's labels, and failure and staleness
  comments (which carry its marker). A review or decision comment has the repo's environment
  values (8 characters or more, and a URL's password) replaced by their names before it is posted.

What it does not contain, by design or for want of a client-side lever:

- Checks and agents run in the PR's worktree, so the PR's own code, scripts and hooks run on the
  Mac that takes the move. Checks run as the Mac's user, outside any sandbox.
- A file the agent opens itself (a PR's `AGENTS.md`, its docs) is read as data under the system
  prompt's rule, nothing stronger.
- A schedule's agent reads PRs itself, so the collaborator gate is up to its prompt. On a repo
  whose sync starts no moves (the default), that prompt is the only gate for the work it does.
- A repo's environment (Settings > Repos) is stored in plain text in `config.json` and reaches
  the PR's own code through its checks and agents. Put only values meant for that code there,
  such as a local test database. Job logs are not redacted, and an agent that posts with `gh`
  itself is not either.
- On a repo without branch protection, nothing on the client stops an agent with `git` from
  pushing to the base branch. Protect the base branch.
