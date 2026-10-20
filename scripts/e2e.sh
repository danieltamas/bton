#!/usr/bin/env bash
# The end-to-end check. Two Bton instances (separate BTON_HOME, separate
# clones) watch the sandbox repo; a review comment makes the next move theirs; exactly one of
# them must start exactly one agent session within one poll interval, with a non-zero cost, and
# once the PR merges its Merged row must show the total. Exit 0 = complete.
#
# Needs: BTON_E2E_REPO=<owner/name>, a scratch repo you own; gh logged in with write access to it, claude on PATH, the sandbox's default
# branch carrying .bton/flow.json (examples/sandbox.flow.json). Costs one short Claude session.
set -euo pipefail

REPO=${BTON_E2E_REPO:?set BTON_E2E_REPO to a scratch repo you own (owner/name)}
POLL=${BTON_E2E_POLL:-20}
BIN=${BTON_BIN:-$(swift build --show-bin-path)/BtonCLI}
ROOT=$(mktemp -d -t bton-e2e)
STAMP=$(date +%Y%m%d%H%M%S)
BRANCH="e2e-$STAMP"
PR=""
WATCHERS=()

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { say "FAIL: $*"; say "logs: $ROOT"; exit 1; }

cleanup() {
  for pid in ${WATCHERS[@]+"${WATCHERS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  if [[ -n $PR ]]; then
    gh pr close "$PR" --repo "$REPO" --delete-branch >/dev/null 2>&1 || true
    gh api -X DELETE "repos/$REPO/git/refs/bton/leases/pr-$PR" >/dev/null 2>&1 || true
  fi
  gh api -X DELETE "repos/$REPO/git/refs/heads/$BRANCH" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ -x $BIN ]] || fail "no BtonCLI at $BIN (run swift build)"
command -v claude >/dev/null || fail "claude not on PATH"

# Two instances: own home, own clone, short poll. Test prices, so the cost is non-zero whatever
# Claude model the session uses.
for name in a b; do
  home="$ROOT/home-$name" clone="$ROOT/clone-$name"
  # HTTPS through gh's credential, so no SSH key is needed.
  git -c credential.helper= -c "credential.helper=!$(command -v gh) auth git-credential" \
    clone --quiet "https://github.com/$REPO.git" "$clone"
  mkdir -p "$home"
  BTON_HOME="$home" "$BIN" jobs >/dev/null # creates the home
  python3 - "$home/config.json" "$REPO" "$clone" "$POLL" <<'PY'
import json, sys
path, repo, clone, poll = sys.argv[1:]
config = {
    "repos": [{"slug": repo, "path": clone}], "pollSeconds": int(poll), "maxAgents": 2, "schedules": [],
    "agents": {"claude": {"argv": ["claude", "-p", "{prompt}", "--session-id", "{session}",
                                   "--permission-mode", "acceptEdits", "--allowedTools", "Bash(git:*)"]}},
}
json.dump(config, open(path, "w"), indent=2)
PY
  # A custom row: the engine's daily refresh replaces the feed's models, never these.
  printf '{"models": {}, "custom": {"claude": {"input": 5, "cacheRead": 0.5, "cacheWrite": 6.25, "output": 25}}}\n' > "$home/prices.json"
done

# A PR on the sandbox, then a review asking for changes on its head: the next move is "fix",
# owned by the author, which is this gh login on both instances.
MAIN=$(gh api "repos/$REPO/git/ref/heads/main" --jq .object.sha)
gh api "repos/$REPO/git/refs" -f ref="refs/heads/$BRANCH" -f sha="$MAIN" >/dev/null
gh api -X PUT "repos/$REPO/contents/e2e/$STAMP.md" -f message="e2e $STAMP" -f branch="$BRANCH" \
  -f content="$(printf 'e2e %s\n' "$STAMP" | base64)" >/dev/null
URL=$(gh pr create --repo "$REPO" --head "$BRANCH" --base main --title "Bton e2e $STAMP" --body "**Tier:** quick fix")
PR=${URL##*/}
HEAD=$(gh pr view "$PR" --repo "$REPO" --json headRefOid --jq .headRefOid)
say "PR #$PR at ${HEAD:0:7}"

for name in a b; do
  BTON_HOME="$ROOT/home-$name" "$BIN" watch > "$ROOT/watch-$name.log" 2>&1 &
  WATCHERS+=($!)
done
sleep 2
gh pr comment "$PR" --repo "$REPO" --body "## Review: changes needed (head ${HEAD:0:7})

e2e: please fix." >/dev/null
COMMENTED=$(date +%s)
say "review posted; watching for $((POLL * 3))s"

jobs_json() { for name in a b; do BTON_HOME="$ROOT/home-$name" "$BIN" jobs; done; }

# Three poll intervals for the start, then until the job ends (the agent's own time).
deadline=$((COMMENTED + POLL * 3))
while (( $(date +%s) < deadline )); do sleep 5; done
end_by=$(( $(date +%s) + 300 ))
until jobs_json | python3 -c 'import json,sys; jobs=[json.loads(l) for l in sys.stdin]; sys.exit(0 if jobs and all(j["status"]!="running" for j in jobs) else 1)'; do
  (( $(date +%s) < end_by )) || fail "the job did not finish in 5 minutes"
  sleep 5
done

jobs_json > "$ROOT/jobs.jsonl"
python3 - "$ROOT/jobs.jsonl" "$PR" "$HEAD" "$COMMENTED" "$POLL" "$ROOT" <<'PY' || fail "job assertions (see above)"
import json, sys, datetime, os
path, pr, head, commented, poll, root = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6]
def home_of(job):
    return next(h for h in (f"{root}/home-a", f"{root}/home-b") if os.path.exists(f"{h}/jobs/{job['id']}.json"))
jobs = [json.loads(line) for line in open(path)]
ok = True
def check(cond, text):
    global ok
    print(("ok   " if cond else "FAIL ") + text)
    ok = ok and cond
check(len(jobs) == 1, f"exactly one job across both instances (got {len(jobs)})")
if jobs:
    job = jobs[0]
    started = datetime.datetime.fromisoformat(job["startedAt"].replace("Z", "+00:00")).timestamp()
    check(job["key"]["item"] == f"pr-{pr}" and job["key"]["move"] == "fix" and job["key"]["head"] == head,
          f"the job is fix on pr-{pr} at {head[:7]}")
    delay = started - commented
    check(0 <= delay <= poll + 15, f"started {delay:.0f}s after the review (poll {poll}s, plus the tick's reads and claim)")
    check(job.get("pid") is not None and os.path.exists(os.path.join(home_of(job), "jobs", job["id"] + ".exit")),
          "an agent process ran and recorded its exit status")
    check(job["status"] == "succeeded", f"status {job['status']} {job.get('detail') or ''}")
    check((job.get("cost") or 0) > 0, f"non-zero cost (got {job.get('cost')})")
sys.exit(0 if ok else 1)
PY

LEASES=$(gh api "repos/$REPO/git/matching-refs/bton/leases/pr-$PR" --jq 'length')
[[ $LEASES == 1 ]] || fail "expected one lease ref, found $LEASES"
say "ok   one lease ref"
SESSIONS=$(cat "$ROOT"/watch-*.log | grep -c "started job" || true)
[[ $SESSIONS == 1 ]] || fail "expected one agent session started, logs show $SESSIONS"
say "ok   one agent session started"

# Merge, then the Merged row carries the job's cost.
gh pr merge "$PR" --repo "$REPO" --squash >/dev/null
TOTAL=""
for _ in 1 2 3 4 5 6; do
  TOTAL=$(for name in a b; do BTON_HOME="$ROOT/home-$name" "$BIN" prs; done | awk -v pr="$REPO#$PR" '$1=="merged" && $2==pr && $3!="-" {print $3}' | head -1)
  [[ -n $TOTAL ]] && break
  sleep 5
done
[[ -n $TOTAL ]] || fail "the Merged row shows no total for #$PR"
COST=$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readline(), parse_float=str)["cost"])' "$ROOT/jobs.jsonl")
python3 -c 'import sys; from decimal import Decimal as D; sys.exit(0 if D(sys.argv[1].lstrip("$")) == D(sys.argv[2]) else 1)' \
  "$TOTAL" "$COST" || fail "Merged row total $TOTAL is not the job's cost $COST"
say "ok   Merged row total $TOTAL is the job's cost"
PR="" # merged: nothing to close
gh api -X DELETE "repos/$REPO/git/refs/bton/leases/pr-${URL##*/}" >/dev/null 2>&1 || true
say "COMPLETE"
