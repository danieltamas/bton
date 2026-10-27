#!/usr/bin/env bash
# Points the Homebrew cask (danieltamas/homebrew-tap, Casks/bton.rb) at a published release:
# version and sha256 from the release's SHA256SUMS, checked against the bytes GitHub serves before
# anything is committed, one commit on the tap's main. The cask is created on the first run.
#   scripts/tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>] [--push]
set -euo pipefail

fail() { echo "tap: $*" >&2; exit 1; }

version=${1:-}; shift || true
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "usage: tap.sh <X.Y.Z> [--sums <file>] [--tap <dir>] [--push]"
sums=dist/SHA256SUMS
tap=${BTON_TAP_DIR:-${TMPDIR:-/tmp}/bton-tap}
push=0
while (($#)); do
  case $1 in
    --sums) sums=$2; shift ;;
    --tap) tap=$2; shift ;;
    --push) push=1 ;;
    *) fail "unknown option $1" ;;
  esac
  shift
done

asset=Bton-$version.zip
url=https://github.com/danieltamas/bton/releases/download/v$version/$asset
sha=$(awk -v name="$asset" '$2 == name { print $1 }' "$sums")
[[ $sha =~ ^[0-9a-f]{64}$ ]] || fail "no checksum for $asset in $sums"

# The pin is checked against what GitHub serves, not against a local build: a replaced asset or a
# stale SHA256SUMS must stop here, before the tap changes.
scratch=$(mktemp -d "${TMPDIR:-/tmp}/bton-tap-check.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
curl -fsSL --retry 3 -o "$scratch/$asset" "$url" || fail "cannot download $url; publish the release first"
served=$(shasum -a 256 "$scratch/$asset" | awk '{ print $1 }')
[[ $served == "$sha" ]] || fail "$asset served by GitHub has sha256 $served, SHA256SUMS says $sha: not pinning"

if [[ -d $tap/.git ]]; then
  git -C "$tap" fetch -q origin main && git -C "$tap" reset -q --hard origin/main
else
  gh repo clone danieltamas/homebrew-tap "$tap" -- -q
fi
cask=$tap/Casks/bton.rb
if [[ ! -f $cask ]]; then
  cat >"$cask" <<'CASK'
cask "bton" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/danieltamas/bton/releases/download/v#{version}/Bton-#{version}.zip"
  name "Bton"
  desc "Runs a team's pull request flow and scheduled agents from the macOS menu bar"
  homepage "https://github.com/danieltamas/bton"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "Bton.app"
  binary "#{appdir}/Bton.app/Contents/MacOS/BtonCLI", target: "bton"

  # The app is signed ad hoc, not notarized. The curl installer leaves no quarantine flag, so the
  # app opens at once; the cask matches it instead of sending the user to System Settings.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Bton.app"],
                          writable_paths: ["Bton.app"], writable_base: :appdir
  end

  uninstall quit: "ro.danieltamas.bton"

  zap trash: [
    "~/.bton",
    "~/Library/Preferences/ro.danieltamas.bton.plist",
  ]

  caveats <<~EOS
    Bton drives GitHub through gh: brew install gh, then gh auth login.
    Bton updates itself from Settings, About. After such an update, run
    brew upgrade --cask danieltamas/tap/bton once so Homebrew's record matches.
  EOS
end
CASK
fi
# Only the two pinned lines change; the stanza order, comments and steps stay as reviewed.
sed -i '' -e "s/^  version \".*\"/  version \"$version\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
grep -q "version \"$version\"" "$cask" && grep -q "sha256 \"$sha\"" "$cask" || fail "the cask did not take the new pins"

if [[ -z $(git -C "$tap" status --porcelain Casks/bton.rb) ]]; then
  echo "tap: bton $version already pinned"
else
  git -C "$tap" add Casks/bton.rb
  git -C "$tap" commit -q -m "bton $version" --author "Daniel Tamas <hello@danieltamas.ro>"
  echo "tap: committed bton $version ($sha)"
fi
if ((push)); then
  git -C "$tap" push -q origin main
  echo "tap: pushed; brew install --cask danieltamas/tap/bton"
else
  echo "tap: not pushed; run: git -C $tap push origin main"
fi
