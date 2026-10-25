# Bton log

What changed in each release, newest first. Each entry is also that release's notes on GitHub.

## 0.6.2 (2026-10-25)

**Retry stays on one line.** On a PR card, Retry merge and Retry fix conflicts no longer wrap onto two lines beside the title.

**One work label for the team.** Settings, Repos, Work label suggested `bton: working`, with a space, while the label Bton puts on PRs is `bton:working`, so a teammate who typed the suggestion got a second label that the others never clear. The field now suggests `bton:working`. Everyone watching a repo should save the same name.

## 0.6.1 (2026-10-25)

**A review that can't count says so.** When a PR's author is also its assignee, on a tier that counts no review from the author, the review move used to read "review · you" and Bton would run the review agent, whose comment was then ignored. The pill now reads "review · needs another reviewer", no agent is started for it, the PR sorts with the unassigned ones and counts as waiting on you, and stale pings ask for a reviewer other than the author. `bton moves` marks it too.

## 0.6.0 (2026-10-24)

**Themes.** Settings, General has a Theme choice. Bton keeps its own look, and two new ones join it: Solid Glass, with neutral grey panes lit at the edge, and Solid Glass Light, with light panes on a cool grey page. A colour means the same thing in every theme, and the menu bar icon and the app's controls follow the one you choose.

**Start a review from its pill.** A PR's review pill now starts the review agent in Bton even when GitHub could already merge the PR. Merge stays as a button beside it. While an agent works the PR, the pill is drawn tinted, so it no longer looks like something to press again.

**A steady hand cursor.** The hand stays over buttons on macOS 15 instead of flickering back to the arrow. It also shows over the Active Now cards and the summary tiles, and an Active Now card lifts when you hover it.

**Merges that stall.** A merge command that timed out is not run again unchanged. Checks that already passed on the same head and base are not run again. A leftover base tree is removed, and a stopped job releases its lease at once.

**Tab outline.** The open tab's outline no longer has a gap in its bottom edge.

## 0.5.4 (2026-10-23)

**Update restarts Bton.** Pressing Update in Settings, About installed the new version but left the old one running, so Bton looked unchanged until it was quit and opened again. The installer now stops the running Bton, waits until it is gone, and opens the new one. Updating from v0.5.3 to this release still needs that one manual restart, because v0.5.3's installer does the update; from here on it restarts by itself.

**An arrow when a release is out.** The menu's header shows a small arrow when a newer Bton is out; it opens Settings, About. Bton asks GitHub at most every 15 minutes, and About's Check again asks at once.

**PR cards keep their room.** A failed move's reason runs the card's full width under the row, so the title and author no longer squeeze into a narrow column.

## 0.5.3 (2026-10-23)

**Checks get the move's time limit.** A flow check (a test suite before a merge) used to be stopped after a fixed 10 minutes, whatever the flow said. It now gets the move's own `timeoutMinutes` (default 60), so a long suite can finish.

**Check output as it runs.** A check's and a merge command's output reaches the job's log while they run. A check that is stopped shows how far it got instead of an empty log.

**Merges are bound to the reviewed head.** Right before a merge command runs, after its checks, Bton re-reads the PR on GitHub. It merges only if the PR is still open at the head the move started on; a push during the checks, a closed PR or a failed read fails the job and nothing is merged. Have the merge command pin that head too (`gh pr merge {number} --squash --match-head-commit {head}`), or a team script that refuses any other head.

**Timeouts judged fairly.** An agent that finishes in the last seconds before its limit is no longer marked timed out, and one that ran past its limit while Bton was closed no longer passes.

## 0.5.2 (2026-10-23)

**Start a move from its pill.** A move of yours that an agent takes (a review, a fix) shows as a pill with a play mark. Press it and the agent starts in Bton, no trip to GitHub. If the move failed on the PR's current head, the pill shows a retry mark and runs it again. While an agent works the PR, or the repo starts its moves on every sync, the pill is just a label.

**Issues tab.** Questions on issues have their own tab instead of a section above the PRs, and a reply being drafted shows as active there. The reply chip under Waiting on you opens it. When every tab has a count and they no longer fit, only the open tab keeps its number.

## 0.5.1 (2026-10-23)

**Update from About.** When a newer release is out, Settings > About offers Update. It runs the same installer as the install line, bundled in the app and pinned to the release shown: it checks the download against SHA256SUMS, swaps /Applications/Bton.app and reopens Bton. Running agents keep going. If it fails, About shows why. From v0.5.0, run the install line once more; after that, the button does it.

**Logged-out agents wait instead of failing.** A failed job now names the agent's last line of output, not just "agent exited 1". When an agent's CLI login has expired, Bton holds that agent's jobs and shows a notice saying how to log in again, with Open Terminal and I've logged in. The supervisor leaves those jobs alone.

**gh in a custom Homebrew prefix.** Bton finds gh on your PATH and in ~/.local/bin, not only in Homebrew's usual places, and the installer links a gh from elsewhere into ~/.local/bin. The bton command prints errors instead of crashing. An agent's own folder goes first on its PATH, so an nvm codex given by full path in Settings > Agents finds its node.

**Retry draft.** A failed or stopped issue draft gets Retry draft on its row.

## 0.5.0 (2026-10-22)

**Work label.** Name a label for a repo in Settings > Repos, and a PR carries it while any Bton, on any Mac, works on it. Teammates who don't run Bton see on GitHub which PRs an agent has. The label goes on after the lease is claimed and comes off before it is released, also for a schedule agent's `bton lease claim`. A label the repo lacks is created once. A label left by a crashed job comes off at a later sync once its lease is free. It is display only: the lease stays the lock, and a label failure never fails a job. Off until you name one.

**Fix conflicts that changed nothing says so.** When the resolve agent stops without pushing (say, the conflict needs a product decision), the job now fails instead of passing. The row links the agent's report and offers Retry fix conflicts, where before your next press was dropped without a word.

## 0.4.1 (2026-10-22)

**Merge on a teammate's PR.** When the flow gives you the merge of someone else's PR, Merge now starts it, instead of being dropped without a word. A merge you asked for stays pinned to the head you saw until it starts.

**A stopped merge says why.** When a flow check stops a merge (say, the repo's rule that PRs with migrations are merged by a person), the row names the check that stopped it and offers Retry merge, instead of showing a fresh Merge.

**No second start while an agent works.** While an agent works a PR, on this Mac or under a schedule, its row hides Merge, Fix conflicts, Retry and Run Next. A start you already asked for still shows as starting.

**Issue drafts you can post.** A finished draft opens in place and is editable. Post reply comments it on the issue as you, after a confirm. The ask clears at the next sync that reads your reply. A draft says plainly what is left for you.

## 0.4.0 (2026-10-22)

**Questions on issues.** When a teammate mentions you on an open issue in a watched repo, it shows under "Asked on issues" on the PRs tab, counts in what is waiting on you and in the menu bar, and notifies you once. Mentions inside code are ignored, and only teammates with write access count. Press Draft reply and a read-only agent reads the thread and the code and drafts your answer: where you must choose, it recommends one option and says why. View draft shows it with Copy and Open on GitHub. Bton never posts on an issue; you do.

**About (Settings > About).** Who makes Bton and why, the repo and issue links, this build's version (a build from source shows the commit it came from) and whether it is the latest release.

**Hardening.** A read-only job (supervisor, issue draft) loads no MCP servers from the agent template. A job's scratch directory is created fresh and private, and files Bton puts in it are never written through a link.

## 0.3.0 (2026-10-22)

**Watchdog.** Every ended job is checked for what went wrong: timed out, lease lost, no verdict, comment not posted, agent crashed, failed again, or far costlier than that move usually is. Flags show on the job's row and in its notification.

**Supervisor (opt-in, Settings > Supervisor).** An agent looks at each flagged job once and answers retry, escalate, propose or none. A retry runs the move again on the same head with the supervisor's note in its prompt; escalate and propose are notifications. It only reads (no shell, no edits, no web, no GitHub writes), runs one at a time, stops at a daily budget, and never supervises a job it already steered. Off by default.

**Fixes.** A button disabled by its pane now looks disabled; saving the supervisor prompt confirms with "saved".

## 0.2.2 (2026-10-22)

Lease host fix: a Mac's leases now carry one host name, kept in ~/.bton/host, and host names compare case-insensitively, so a schedule agent's `bton lease release` is no longer refused when the Mac's name changes (VPN, Tailscale, a rename).

## 0.2.1 (2026-10-21)

- A sync only reads PRs, on every repo by default. Agents start from your schedules and from Run now, Merge, Fix conflicts and Retry. Settings > Repos > "Start the flow's moves on every sync" turns automatic moves on for a repo.
- A schedule's agent can claim a PR with `bton lease claim`, so no move starts there while it works. A Merge you press while the PR is claimed waits for it.
- Every agent follows a built-in PR playbook: the diff read once, targeted tests first, evidenced findings, scoped re-reviews, short comments, and each move's edge cases. Your flow and CLAUDE.md still win.
- A running schedule no longer holds back moves on other PRs of its repo.

## 0.2.0 (2026-10-21)

Your local develop and main stay current: after every sync Bton fast-forwards the ones only behind origin, never touches a branch with commits of its own, and the footer shows each against origin and develop against main. Search finds any PR by number, title or login. A schedule's row names the PR it is on and the PRs it worked on; Merged lists the newest first. A move of yours that failed gets a Retry on its row. Codex runs start with no MCP server, plugin or hook, and a PR's .codex/config.toml configures nothing. Each Claude agent gets its own scratch directory. Worktrees survive an antivirus that quarantines a file or refuses a git command. A taller window.

Install: curl -fsSL https://raw.githubusercontent.com/danieltamas/bton/main/install.sh | bash

## 0.1.1 (2026-10-21)

Conflicts on your PRs fix themselves (Settings > Repos turns it off). Merge and Fix conflicts buttons, and a press shows starting at once. Much lower CPU: pulses run in Core Animation and the menu bar icon stays still. Syncs no longer wait on checks or merges. A stuck check is named in the job log. Install: curl -fsSL https://raw.githubusercontent.com/danieltamas/bton/main/install.sh | bash

## 0.1.0 (2026-10-20)

First release. Install: curl -fsSL https://raw.githubusercontent.com/danieltamas/bton/main/install.sh | bash
