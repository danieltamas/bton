# Bton

A macOS menu bar app that runs a team's coding-agent flow on GitHub. It shows the open PRs and
whose move each one is, starts the moves that are yours with a headless agent (Claude Code, or
any CLI agent you configure), runs your scheduled agent tasks, and tells you what each task cost.

There is no server. Each repo's `.bton/flow.json` says who makes the next move on a PR and what
gets started for it; every teammate runs their own Bton with their own `gh` login, and GitHub is
the only shared state. A lease on GitHub makes sure exactly one Mac takes each move.

## How it works

1. Every minute Bton reads each watched repo's open PRs and the flow on the branch PRs merge
   into.
2. The flow turns each PR into a move (`review`, `fix`, `merge`, `decide`, ...) and an owner.
3. For a move that is yours and has a dispatch entry, Bton claims the PR's lease, makes a
   worktree at the PR's head, runs the flow's checks and starts the agent there.
4. A review agent's final message is posted as the PR comment; a merge runs the repo's merge
   command. The next move follows from what changed on GitHub.

`docs/FLOW.md` describes the flow schema;
`examples/team.flow.json` is a complete three-tier review flow.

## Requirements

- macOS 14 or later
- [`gh`](https://cli.github.com), logged in (`gh auth login`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude`) for agent moves;
  [codex](https://github.com/openai/codex) optional, as an agent or a second opinion
- To build from source: Xcode with Swift 6.2

## Install

From a release: download `Bton-<version>.zip` from the
[releases](https://github.com/danieltamas/bton/releases), check it against `SHA256SUMS`, unzip
it and move `Bton.app` to `/Applications`. The app is ad hoc signed, not notarized, so macOS
blocks the first launch: right-click `Bton.app`, choose Open, then Open again (or run
`xattr -dr com.apple.quarantine /Applications/Bton.app`). The `bton` CLI is inside the app:
`ln -s /Applications/Bton.app/Contents/MacOS/BtonCLI ~/.local/bin/bton`.

From source:

```bash
git clone https://github.com/danieltamas/bton.git && cd bton
scripts/install.sh   # /Applications/Bton.app (opens at login) and ~/.local/bin/bton
```

Run `scripts/install.sh` again to update. A running Bton's agents keep running and the new
version adopts them.

## First run

Open the menu bar icon, then the gear for Settings.

- **Repos:** drop a project folder. Bton reads the GitHub repo from its `origin` and makes its
  worktrees in that clone. Pick the branch PRs merge into: Bton reads `.bton/flow.json` there,
  never from a PR. A repo's environment (`KEY=VALUE` lines, such as a local test database's
  `DATABASE_URL`) goes to its checks, merge commands and agents on this Mac. Bton keeps `PATH`,
  `HOME`, `GIT_*` and `BTON_*` for itself.
- **Agents:** the command each agent runs, one argument per line, with `{prompt}` and
  `{session}`; `{clone}`, `{base}` and `{repo}` are filled from the repo a job works. These are
  the agents this Mac may start unattended, never the repo's choice. Bton hardens every Claude
  Code agent at launch: a PR's `.claude/settings.json`, `CLAUDE.md` and `.mcp.json` never load,
  GitHub writes that skip the merge gate are denied, and Claude Code's sandbox is always on.
- **Schedules:** an agent with your prompt, in one repo, every N minutes, hours or days, in a
  fresh worktree of the base branch. A schedule can pin its model, run only when a PR changed,
  and ask other agents (codex, for one) for a second opinion.
- **Prices:** fetched daily from LiteLLM's public model price list. Add a price yourself only
  for a model the feed lacks. Costs are API-equivalent; a model without a price shows "no
  price", never $0.

Then add a flow to your repo: copy `examples/team.flow.json` to `.bton/flow.json` on the branch
PRs merge into, and change the logins, headings and commands to your team's.

## Security

Bton is built for a team that trusts its collaborators. It dispatches only for PRs whose author
is an owner, member or collaborator of the repo and counts reviews only from those, but checks
and agents run the PR's own code on the Mac that takes the move. Protect your base branch: nothing on the client stops an
agent with `git` from pushing to it. Read the threat model in `SECURITY.md` before pointing
Bton at a repo; it also says how to report a vulnerability.

## Develop

```bash
swift build
swift test                 # BTON_SANDBOX=<owner/name> adds the live GitHub lease tests
swift run Bton             # quick run, SF Symbol icon instead of the brand icon
scripts/bundle.sh          # build/Bton.app, ad hoc signed
BTON_E2E_REPO=<owner/name> scripts/e2e.sh   # two headless instances against a scratch repo
scripts/release.sh <x.y.z> --verify         # reproducible release zip, built twice and compared
```

Releases are reproducible: `scripts/release.sh` builds a clean, tagged, full clone with the Xcode
build pinned in `Support/toolchain`, and anyone with that Xcode gets the same bytes as the
published zip. `--verify` builds the tag twice from copies at different paths and compares them.

The CLI: `bton watch` runs the app's tick without a UI, `bton jobs` and `bton prs` print a
home's jobs and the PRs with their costs, `bton moves <owner/name>` the flow's verdict on each
open PR, and `bton lease claim|renew|release|check` lets scripts take the same lease as the
dispatcher.

Everything Bton keeps lives in `~/.bton` (mode 0700), or in `$BTON_HOME` when set. The config is
`$BTON_HOME/config.json`; Settings writes it, and a hand edit is read on the next sync.

## License

MIT, see [LICENSE](LICENSE). The Claude and OpenAI marks in `Brand/vendors/` (from simple-icons)
identify the vendors and are trademarks of their owners.
