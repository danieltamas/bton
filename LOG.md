# Bton log

What changed in each release, newest first. Each entry is also that release's notes on GitHub.

## 0.13.0 (2026-10-28)

**Retired features, and the repo page slides in from the right.** A feature the registry closed has the status retired: it is out of the tree and the area counts until you choose the new "retired" chip or a search names it, then it shows dimmed, and its detail ends the timeline with the retirement date. The repo page used to come in from the left, against every other page; it now slides in from the right, the features list slides left under a feature's detail, and back runs the other way.

**More apps comes from the registry.** Settings > More apps now reads the maker's app list from one file in github.com/danieltamas/registry instead of a list built into Bton plus one GitHub API call per app. Each card shows the latest release and when it came out, whether the copy on this Mac is up to date, behind or built from source, and the install command only once there is a release. A copy of the list ships in Bton for the first launch and offline; the live file is read at most hourly when the pane opens, or on its refresh button, kept in `~/.bton/registry`, and validated whole before any of it shows: an entry Bton cannot read is left out and counted, a newer list format keeps the last good one and asks for an update. MacMax's card takes the registry's teal.

**A repo's jobs wait for its services, and say so.** When a URL in a repo's environment (`DATABASE_URL`, a Redis, anything with a port) does not answer a TCP connect, Bton holds every job of that repo instead of starting it: the pressed merge, the schedule, the supervisor. The card says "DATABASE_URL: nothing answers at 127.0.0.1:55439; start the service (Docker?) and Bton goes on", and one notification says the same, at once rather than at the end of a 60-minute timeout. Before this, a merge pressed while Docker was off ran the repo's checks against a dead database for its whole time limit and then failed with "check ...", and the owner learned an hour later. The jobs start on the next sync where the service answers.

## 0.12.0 (2026-10-28)

**Agents start from the feature registry.** Every agent job of a repo with a registry (a PR move, a taken issue, the supervisor; claude and codex alike) gets `feature-context.md` beside its session: the feature the registry links the work to, or the features and areas whose paths the PR touches, with area, paths, the merged PRs that built it (titles and dates), its open issues, and the map of areas, so the agent reads one page before searching the tree. When the registry links the work to one feature and the job edits the PR, the agent is asked to put `Feature: <id>` in the PR body, and the registry job takes that line as hard evidence (`why: feature`) instead of guessing from titles. Only that id, a checked slug, reaches the prompt; the rest of the registry travels as data. A codex job now gets the code graph line and the path of its data files in its task, which only Claude got before, so both agents query the graph instead of searching the tree.

## 0.11.0 (2026-10-28)

**A codex reviewer no longer blocks on the ask tool it never had.** Bton offers the `ask` helper tool to Claude agents only, but the playbook told every agent to consult through it, and lexito's decide prompt says to ask codex: a review or decision run by codex (Settings > Agents, reviewer codex) blocked every head on "consultation unavailable". The playbook (now v3) asks a helper only where the session exposes the tool and says a helper that is not exposed never blocks, and a job whose flow names helpers it cannot be offered is told so, by identity: "you are the codex agent; a step that says to consult codex is satisfied by your own work". The job log notes it.

**`bton handoff` without an issue.** `bton handoff <owner/name> --to <login> "text"` posts on the repo's inbox issue, the open issue labelled `bton:inbox` (the lowest number when there are several). A repo without one gets a message naming the label and the create command; nothing is created unattended. The playbook's handoff rule says so.

**Settings > More apps.** The other open source tools from the same maker, in two groups: in the menu bar (MacMax, RMJ) and in the terminal (Axon, Run.dev, Cloak). Each card shows the app's own icon, platform, pitch, one line, Website and GitHub links, and its install command with a copy button; whether an app has a release is asked of GitHub when the pane opens (no login needed) and kept across launches, so an app that ships after this Bton was built shows its version and install line, and one that has not says so instead of a command.

**A schedule with "only on change" no longer re-arms itself.** The gate read each PR's updatedAt, and GitHub bumps that for a label too: a run's own lease claim and release flip the work label on every PR it looks at, so every run made the next one due (430 runs on one schedule). The gate now reads what a run should see: a PR opened, a commit on its head, a comment, a merge, or a head that moved since the last run saw the queue.

**The release move.** A flow with a `release` section gets its develop branch released to main by Bton: when a `when` predicate holds (so many commits or days ahead, so many registry features waiting) and nothing in `blockedBy` is open, the Bton of `release.who` opens the release PR with release notes from the registry, by area with each feature's merged PRs. The repo's page floats Release for that owner (the press opens the PR whatever `when` says, then runs the release checks at the PR's head and merges it pinned to that head); a repo that starts its moves merges on its own while the release stays due. The page and the footer say "release due: 5 features waiting" in amber, or why it is blocked, or that the PR is open; the release PR gets no flow move, so rotation and the flow leave it alone.

**A feature's changes carry their titles.** The detail's Changes section names each merged PR with its title and merge date, read with the feature facts, where it said "merged" for any PR older than the lists' window. Going a level deeper slides everything left and coming back slides everything right, on every page.

**The registry shows before its PR merges.** While the base has no registry and the job's PR is open, the page reads `.bton/features.json` from the PR's branch and shows the tree with "From PR #n, not merged yet" in the header and the way to the PR floating over it, instead of an empty page with a link. The code graph switch under the empty state shows only until the graph is built.

**The registry job waits for the code graph.** The job draws a registry's areas from the repo's graphify graph; without one it would draw them from the tree's layout, which the first live run did. Now a repo whose "Build a code graph for agents" is off, or whose first build has not finished, gets no registry job: the page's Build the registry is off, the switch sits right there under the empty state with one line on what graphify does, and a press made while the graph builds waits in line with that reason, then starts. While the job's PR is open the page shows "Registry PR #n open" instead of the button, and Settings > Agents says what graphify is and when Bton rebuilds the graph. While the graph builds, the page shows the build's step and, as graphify reads the files, a bar with the count, from the build's output Bton now keeps beside the graph as `bton-build.log`. A job the graph is made for fails when it cannot be linked into its worktree, where any other job goes on without it.

**The registry builds itself.** A repo that starts its moves gets a `features` job: nightly, or an hour after a merged PR or a new issue, an agent (the repo's Issue work pick, else claude) reads the issues and PRs changed since the registry's last commit, or everything and the last 200 merged PRs the first time, with the code graph for the areas, extends `.bton/features.json` and opens a PR titled `features: <n> added, <m> linked` against the flow's base. One Bton on the team runs it, through the job's lease, and none while that PR is open. A repo without a registry has "Build the registry" on its page, which starts the job on any Bton, moves started or not.

**The repo's page: every feature with its status.** The footer's branch line (and a chevron per repo in the repo filter) opens a page for the repo: its branches against origin, how many commits develop holds that main lacks and for how long, and, when the repo has a `.bton/features.json`, every feature by area as live, in develop, building, ready, spec or idea, from the linked issues and PRs and the clone's refs. Chips narrow the page to what ships next, what is being built, what is live and what is not started; a feature opens to its paths, its timeline and the PRs that changed it. A flow's new `release` section (`docs/FLOW.md`) names the branches a release moves between; without one nothing counts as "in develop". A repo without a registry says so; an invalid one shows why.

**Agents get a code graph of each repo.** Settings > Repos has "Build a code graph for agents": after a sync, Bton keeps a graphify graph of the branch PRs merge into under `~/.bton/graphs/<owner>__<repo>`, rebuilt in its own worktree whenever that branch moves, one build at a time, and links it as `graphify-out` into the clone and into every worktree it makes. A Claude job is told the graph is there and of which commit, so it queries it with `graphify-src` before searching the tree; a graph a clone already had moves into the store the first time. Settings > Agents takes the Python that has graphify installed; empty looks in the usual venv places. The switch says when that Python is not found, and a failed build keeps the previous graph.

**A ready issue no longer waits for someone to start it.** The Issues tab now lists every `stage:ready` issue of the repos you watch, taken or not, with who has it. A repo whose flow has `intake` and that starts its moves has a Bton take the most urgent unassigned one on its own, as the flow says: it re-reads the issue, runs the flow's claim, makes the worktree and starts the agent, which opens the PR the repo's own way. At most one per repo at a time, only while the flow's PR caps allow it, and after the repo's PR moves. Assign yourself to an issue you want to do by hand and Bton leaves it. See `docs/FLOW.md`, Intake.

**Long issue work, your own agent and model, and a Take button.** An issue's `timeoutMinutes` now counts idle time (no commit or file change) instead of total time, up to 8 hours, and a stopped job resumes with Retry. Settings > Repos has Issue work and Reviewer, each `agent:model effort` picked from what is installed on this Mac (`claude:sonnet medium`, `codex:gpt-6-astra high`), and the reviewer takes rules that are added to every review it runs. A ready issue with no one on it has a Take pill that starts it now. Issues that wait for your reply are hatched in amber. An issue's job that dies with Bton or the Mac resumes by itself at the next sync, while a job that failed on its own still waits for Retry. In-progress issues now show in the Issues tab too, with who has them, and the footer names the repo whose branches it shows.

## 0.10.1 (2026-10-27)

**Voice input no longer keeps 3 GB of memory.** With voice on, Bton held the speech model in memory for as long as it ran, about 3 GB for Large v3 turbo. It now lets the model go five minutes after you last opened a new issue or dictated, and loads it again when you open one; if you press the mic after it was let go, the mic shows a spinner for a few seconds while it loads, then records. The first recording after a load is also faster: the warm-up that was meant to prepare the GPU never ran, so that recording paid about 3 seconds for it.

## 0.10.0 (2026-10-27)

**Dictate new issues, write several at once, and hand a message to a teammate's agent.** New issue has a microphone: press it, speak, press Stop, and the words land in the box for you to edit; nothing is sent until you press Send. Speech is turned into text on this Mac (Settings > Voice downloads the model and checks that your Mac can run it), in pieces while you speak, so Stop returns almost at once. Each new issue is now its own conversation: start as many as you like, they sit in Triage as hatched cards, survive a restart and a reinstall, and show whether their agent is working, waiting or stopped. The agent reads the repo's code map first when the repo has one, keeps its own notes between turns instead of reading the repo again, and runs on Sonnet unless you pick another model in Settings > Agents. The tab bar keeps every count whichever tab is open. Agents can now ask a teammate something without you relaying it: `bton handoff <repo> <issue> --to <login> "<text>"` comments `@login` on the issue, once, and the teammate's Bton shows it in Issues as "handed off" with a draft reply. Agents Bton starts are told to use it; one you start by hand needs the same command.

## 0.9.0 (2026-10-27)

**Triage open issues from the menu bar, and icon tabs.** A new Triage tab lists the open issues that are not yet `stage:ready`, in progress or in review. Click one and answer three plain questions: how bad the problem is today, how soon it needs doing, and whether someone could start building it today. The answers add up to a score out of 9 that sets the priority (6 or more high, 3 to 5 medium, below that low) and the stage (a clear plan is ready, an open decision or a risky area goes to spec, a missing repro stays in triage). Apply sets both labels in one edit. No agent runs, so an issue opens at once. The tab bar is now icons only; the open tab also shows its name, so six tabs fit. The README has a new layout and fresh screenshots.

## 0.8.4 (2026-10-27)

**A PR no longer waits out a dead merge's lease.** When Bton restarted in the middle of a merge's checks, the failed job kept the PR's lease for up to 15 minutes, so the PR sat on "waiting" and its merge could not start again. A relaunched Bton now releases that lease as it fails the job, and the merge starts at the next sync.

## 0.8.3 (2026-10-27)

**A restart no longer leaves a merge's checks running, and a PR that can't start says why.** When Bton quit in the middle of a merge's checks (installing an update does that), the check and its test run kept going with nothing reading them, held the PR's worktree, and the row sat on "starting" with no way to tell why. A relaunched Bton now stops those leftover checks before it marks the job failed, and a move that has not started shows "waiting" with the reason on hover: another job holds the PR, no agent slot is free, the repo could not be read, or the move is not one Bton can start.

## 0.8.2 (2026-10-27)

**Take it can't be pressed twice.** While a take is under way the button reads "Taking..." and is dimmed and unpressable, and it stays that way until the row shows the PR as yours, instead of coming back for a moment after the take.

## 0.8.1 (2026-10-27)

**A merge that needs `bun` no longer fails with "bun not found".** Bton looks for the programs a repo's commands and checks run in `~/.bun/bin` too, where bun installs itself, so a merge or check that starts with `bun` runs from the menu bar app the way it does in your terminal.

## 0.8.0 (2026-10-27)

**Bton can take a teammate's move for you.** Settings > Repos has a new switch, "Take teammates' moves automatically" (it shows when "Start the flow's moves on every sync" is on). Each sync then does what Take it does for every move you could take, such as a review a teammate was assigned: it assigns the PR to you on GitHub and starts the move. It takes at most two PRs a sync and tries each PR once per owner and head, so it never fights a teammate who takes the PR back. A take is not your press: the flow's checks still run without `BTON_PRESSED`. Off by default.

## 0.7.4 (2026-10-26)

**Your press counts as a person's decision.** When you start a move yourself (Merge, a move's pill, Retry, Run Next, Take it), the flow's checks and the merge command now see `BTON_PRESSED=1`. A check that guards a person's call, such as "a person merges PRs with migrations", can let your press through and still stop a move the sync starts on its own: `["bash", "-c", "test -n \"${BTON_PRESSED:-}\" || git diff --quiet origin/develop...HEAD -- migrations/"]`. Change the check in your repo's `.bton/flow.json` to use it; until then it refuses your press as before.

## 0.7.3 (2026-10-26)

**Take it in one press.** Take it no longer asks "Take from <login>" first: one press assigns the PR to you and starts the move. The extra button also squeezed the row, wrapping the PR number and cutting the title short.

## 0.7.2 (2026-10-26)

**Take it.** A review the flow gives a teammate, because they are the PR's assignee or the rotation picked them, now offers Take it on its row. Press it, confirm "Take from <login>", and Bton makes you the PR's only assignee on GitHub and starts the review on your Mac. The teammate sees the change on GitHub, and their Bton stops treating the move as theirs. Bton checks first that the PR still shows the same owner and that no Bton is working on it; if either has changed, nothing is reassigned and the row says why. A move the flow gives the PR's author, such as a fix or a quick fix's merge, has no Take it, because assigning the PR does not change who wrote it.

## 0.7.1 (2026-10-26)

**A drafted reply promises only what Post reply does.** Draft reply on an issue could write that you were setting a label, such as "I'm setting stage:ready", but Post reply only posts the text, so the label never changed and the teammate kept waiting. A draft now never claims a step it cannot take. When the answer needs one, it ends with a line naming it as yours to do, for example "To do: add the label stage:ready."

## 0.7.0 (2026-10-25)

**Reviews show up on GitHub too.** When Bton posts a review or a decision on a PR, it now also files it as a GitHub review on the commit it read: approve as an approval, changes or blocked as a request for changes. GitHub's "requested your review" clears once the review is in, and GitHub's own lists show the verdict. The `## Review:` comment is still what Bton's flow counts. Because the review is filed with your GitHub login, an approval counts toward the repo's branch protection like one you gave by hand. GitHub does not let you review your own PR; that case is noted on the job and nothing else changes.

## 0.6.3 (2026-10-25)

**No change to the app.** This release is built from the same code as 0.6.2. Only the way Bton is released changed: one command now runs the tests, builds, tags, publishes and checks the published files every time. Skip this update if you like; nothing is lost.

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
