#!/usr/bin/env bash
# The release's test step: the suite once, in parallel; on a failure, only the suites that failed
# are run again, one at a time. A suite that fails under the parallel run's load and passes alone
# (a timing bound, a port, a lock) costs its own minutes, not the whole suite's.
set -euo pipefail
cd "$(dirname "$0")/.."

scratch="${BTON_TEST_SCRATCH:-${TMPDIR:-/tmp}/bton-release-test}"
log="$scratch/last-run.log"
mkdir -p "$scratch"

if swift test --scratch-path "$scratch" 2>&1 | tee "$log"; then
  exit 0
fi

# "Suite Name failed after ..." names what to run again. A suite with a display name is printed
# in quotes ("Registry store acceptance") and filtered by its type, the struct under its @Suite
# line. A failed suite whose type is not found, or none named at all (a build error, a crash),
# runs the whole suite again serially, as before.
names=$(sed -nE 's/.*Suite "([^"]+)" failed after.*/\1/p; s/.*Suite ([A-Za-z0-9_]+) failed after.*/\1/p' "$log" | sort -u)
suites=()
while IFS= read -r name; do
  [[ -n $name ]] || continue
  if [[ $name =~ ^[A-Za-z0-9_]+$ ]]; then
    suites+=("$name")
  else
    type=$(grep -rh -A1 -F "@Suite(\"$name\"" Tests | sed -nE 's/^(final )?(struct|class|actor|enum) ([A-Za-z0-9_]+).*/\3/p' | head -1)
    if [[ -z $type ]]; then
      echo "test.sh: no type found for suite \"$name\", running the suite again serially" >&2
      exec swift test --no-parallel --scratch-path "$scratch"
    fi
    suites+=("$type")
  fi
done <<< "$names"
if [[ ${#suites[@]} -eq 0 ]]; then
  echo "test.sh: no failed suite named in the log, running the suite again serially" >&2
  exec swift test --no-parallel --scratch-path "$scratch"
fi

filter=$(IFS='|'; echo "${suites[*]}")
echo "test.sh: running again serially: ${suites[*]}" >&2
exec swift test --no-parallel --scratch-path "$scratch" --filter "$filter"
