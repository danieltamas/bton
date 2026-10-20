#!/usr/bin/env bash
# Builds Bton from this checkout and installs it the way install.sh installs a release.
set -euo pipefail
cd "$(dirname "$0")/.."

app=$(scripts/bundle.sh | tail -1)
exec ./install.sh --app "$app"
