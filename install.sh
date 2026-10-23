#!/usr/bin/env bash
# Installs Bton on this Mac:
#
#   curl -fsSL https://raw.githubusercontent.com/danieltamas/bton/main/install.sh | bash
#
# Downloads the latest release, checks it against the release's SHA256SUMS, and installs
# Bton.app in /Applications (it adds itself to the login items on its first launch from there)
# and the CLI as ~/.local/bin/bton. Run it again to update. BTON_VERSION=x.y.z pins a release;
# --app <path> installs a Bton.app built here instead (scripts/install-from-source.sh).
#
# Everything runs from main, called on the last line: a download cut short defines nothing and
# runs nothing.
set -euo pipefail

repo=danieltamas/bton
target=/Applications/Bton.app

fail() { echo "bton: $*" >&2; exit 1; }

# A stalled connection fails within a minute instead of hanging the install (and About's Update).
fetch() { curl --connect-timeout 20 --speed-limit 1024 --speed-time 60 "$@"; }

# Downloads the release into $1 and prints the path of its Bton.app.
download() {
  local work=$1 base sums zip want have
  if [[ -n ${BTON_VERSION:-} ]]; then
    [[ $BTON_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "BTON_VERSION is not x.y.z: $BTON_VERSION"
    base="https://github.com/$repo/releases/download/v$BTON_VERSION"
  else
    base="https://github.com/$repo/releases/latest/download"
  fi
  sums=$(fetch -fsSL "$base/SHA256SUMS") || fail "no release found at $base"
  # The release names exactly one zip; anything else is not a release this script trusts.
  [[ $sums =~ ^([0-9a-f]{64})\ \ (Bton-[0-9]+\.[0-9]+\.[0-9]+\.zip)$ ]] || fail "unexpected SHA256SUMS at $base"
  want=${BASH_REMATCH[1]}
  zip=${BASH_REMATCH[2]}
  echo "Downloading $zip" >&2
  fetch -fSL --progress-bar "$base/$zip" -o "$work/$zip" || fail "download failed: $base/$zip"
  have=$(shasum -a 256 "$work/$zip" | awk '{ print $1 }')
  [[ $have == "$want" ]] || fail "$zip does not match the release's SHA256SUMS"
  ditto -x -k "$work/$zip" "$work/out" || fail "$zip does not unpack"
  echo "$work/out/Bton.app"
}

# Bton opened from Finder gets no shell PATH: it finds gh in ~/.local/bin and Homebrew's usual
# places, so a gh anywhere else (a custom Homebrew prefix) gets a link in ~/.local/bin.
link_gh() {
  local gh dir
  gh=$(command -v gh)
  dir=$(dirname "$gh")
  case $dir in
    /opt/homebrew/bin | /usr/local/bin | /usr/bin | /bin | "$HOME/.local/bin") return ;;
  esac
  local link=$HOME/.local/bin/gh
  # A gh already there stays; a link to one that moved is replaced.
  [[ -x $link ]] && return
  if [[ -L $link ]]; then rm "$link"; fi
  [[ -e $link ]] && fail "$link is not a gh Bton can run: remove it and run this again"
  mkdir -p "$HOME/.local/bin" && ln -s "$gh" "$link" || fail "could not link $gh into ~/.local/bin"
  echo "Linked $gh into ~/.local/bin, where Bton finds it" >&2
}

# One install at a time: two would share the staged and the previous app. The lock is a link
# naming the install's pid, made in one step. A lock whose install is gone is taken over by one
# installer only: the takeover is itself a directory made in one step, and the lock is read again
# inside it.
take_lock() {
  lock="${TMPDIR:-/tmp}/bton-install.lock"
  ln -s "$$" "$lock" 2>/dev/null && return
  mkdir "$lock.takeover" 2>/dev/null || fail "another Bton install is running"
  local other
  other=$(readlink "$lock" || true)
  if [[ $other =~ ^[0-9]+$ ]] && kill -0 "$other" 2>/dev/null; then
    rmdir "$lock.takeover"
    fail "another Bton install is running"
  fi
  rm -f "$lock"
  ln -s "$$" "$lock" 2>/dev/null || { rmdir "$lock.takeover"; fail "another Bton install is running"; }
  rmdir "$lock.takeover"
}

# Removes the work folder, and the lock only while it is this install's.
cleanup() {
  rm -rf "${work:-}"
  if [[ $(readlink "${lock:-}" 2>/dev/null) == "$$" ]]; then rm -f "$lock"; fi
}

main() {
  [[ $(uname -s) == Darwin ]] || fail "Bton runs on macOS only"
  command -v gh >/dev/null || fail "Bton drives GitHub through gh: brew install gh, then gh auth login"
  gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
  link_gh

  local app
  take_lock
  work=$(mktemp -d -t bton-install)
  trap cleanup EXIT

  if [[ ${1:-} == --app ]]; then
    [[ -d ${2:-} ]] || fail "--app needs the path of a Bton.app"
    app=$2
  else
    app=$(download "$work")
  fi
  [[ -x $app/Contents/MacOS/Bton && -x $app/Contents/MacOS/BtonCLI ]] || fail "$app is not a Bton.app"

  # The new app is copied in full before the old one is touched, and the old one comes back if
  # the swap fails.
  local staged="$target.new" previous="$target.old"
  rm -rf "$staged" "$previous"
  ditto "$app" "$staged" || { rm -rf "$staged"; fail "could not copy Bton.app to /Applications"; }
  # A running Bton keeps its agents: they outlive the app, and the new one adopts them.
  pkill -x Bton 2>/dev/null || true
  if [[ -e $target ]]; then mv "$target" "$previous"; fi
  if ! mv "$staged" "$target"; then
    if [[ -e $previous ]]; then mv "$previous" "$target"; fi
    fail "could not replace $target"
  fi
  rm -rf "$previous"

  mkdir -p "$HOME/.local/bin"
  install -m 755 "$target/Contents/MacOS/BtonCLI" "$HOME/.local/bin/bton"
  # Prices at install; the app refreshes them daily after this.
  "$HOME/.local/bin/bton" prices refresh >/dev/null 2>&1 || echo "Prices not fetched yet; Bton retries within the hour."
  open "$target"

  echo "Installed Bton: it lives in the menu bar."
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "Add ~/.local/bin to PATH to use the bton command." ;;
  esac
}

main "$@"
