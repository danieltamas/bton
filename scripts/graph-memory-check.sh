#!/usr/bin/env bash
# Asks a repo's code graph what was decided on an issue, the way an agent does, and checks the
# answer names the memory file of that issue. Exit 0 = the graph carries the repo's memory.
#
# Usage: scripts/graph-memory-check.sh <path to the repo's clone> <issue number>
# Needs: a graph built by Bton for that clone (Settings > Repos, "Build a code graph for agents"),
# graphify-src on PATH. Runs in the clone's .worktrees/bton-graph, where Bton built the graph.
set -euo pipefail

CLONE=${1:?clone path}
ISSUE=${2:?issue number}
TREE="$CLONE/.worktrees/bton-graph"
[ -d "$TREE/graphify-out" ] || { echo "no graph in $TREE: Bton has not built one for this clone"; exit 2; }
[ -f "$TREE/memory/issues/$ISSUE.md" ] || { echo "memory/issues/$ISSUE.md is not in the build tree: the memory does not hold #$ISSUE yet"; exit 3; }
cd "$TREE"
ANSWER=$(graphify-src "what was decided on #$ISSUE" 2>&1 || true)
if grep -q "memory/issues/$ISSUE.md" <<<"$ANSWER"; then
  echo "PASS: the graph answers #$ISSUE from memory/issues/$ISSUE.md"
  grep -m1 -n "## Decision:" "memory/issues/$ISSUE.md" || echo "note: the issue has no ## Decision: comment"
  exit 0
fi
echo "FAIL: the answer does not name memory/issues/$ISSUE.md (the graph was built before the memory, or #$ISSUE is not indexed yet)"
printf '%s\n' "$ANSWER" | head -20
exit 1
