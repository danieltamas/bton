#!/usr/bin/env bash
# Installs Bton on this Mac: Bton.app in /Applications (it adds itself to the login items on its
# first launch from there) and the CLI as ~/.local/bin/bton. Run it again to update.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v gh >/dev/null || { echo "gh missing: brew install gh, then gh auth login" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh is not logged in: gh auth login" >&2; exit 2; }

app=$(scripts/bundle.sh | tail -1)

# A running Bton keeps its agents: they outlive the app, and the new one adopts them.
pkill -x Bton 2>/dev/null || true
rm -rf /Applications/Bton.app
cp -R "$app" /Applications/Bton.app
mkdir -p "$HOME/.local/bin"
install -m 755 "$app/Contents/MacOS/BtonCLI" "$HOME/.local/bin/bton"
# Prices at install; the app refreshes them daily after this.
"$HOME/.local/bin/bton" prices refresh || echo "Prices not fetched yet; Bton retries within the hour."
open /Applications/Bton.app

echo "Installed /Applications/Bton.app and $HOME/.local/bin/bton"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Add ~/.local/bin to PATH to use the bton command." ;;
esac
