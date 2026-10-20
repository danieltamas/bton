#!/usr/bin/env bash
# The release build: dist/Bton-<version>.zip and dist/SHA256SUMS, the same bytes for anyone who
# builds the tag v<version> with the toolchain named in Support/toolchain. --verify builds the
# tag twice, from two copies at different paths, and fails if one byte differs.
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { echo "usage: release.sh <x.y.z> [--verify]" >&2; exit 2; }
version=${1:-}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
verify=${2:-}
[[ -z $verify || $verify == --verify ]] || usage

[[ -z $(git status --porcelain) ]] || { echo "the tree has changes: release from a clean checkout" >&2; exit 1; }
[[ $(git rev-parse -q --verify "v$version^{commit}") == $(git rev-parse HEAD) ]] \
  || { echo "HEAD is not tagged v$version" >&2; exit 1; }
# The build number is the commit count, which a shallow clone gets wrong.
[[ $(git rev-parse --is-shallow-repository) == false ]] || { echo "shallow clone: fetch the full history first" >&2; exit 1; }

# Xcode's build version names the compiler, linker and SDK together.
want_xcode=$(awk '$1 == "xcode-build" { print $2 }' Support/toolchain)
have_xcode=$(xcodebuild -version 2>/dev/null | awk '/Build version/ { print $3 }')
if [[ -z $want_xcode || $have_xcode != "$want_xcode" ]]; then
  echo "toolchain: Support/toolchain names Xcode build ${want_xcode:-?}; this Mac has ${have_xcode:-none}" >&2
  exit 1
fi

build=$(git rev-list --count HEAD)
SOURCE_DATE_EPOCH=$(git log -1 --format=%ct)
export SOURCE_DATE_EPOCH
stamp=$(TZ=UTC date -r "$SOURCE_DATE_EPOCH" +%Y%m%d%H%M.%S)
work=$(mktemp -d -t bton-release)
trap 'rm -rf "$work"' EXIT

# Builds the tagged tree, copied to $1/src, into $1/Bton-<version>.zip.
build_copy() {
  mkdir -p "$1/src"
  git archive HEAD | tar -x -C "$1/src"
  (cd "$1/src" && scripts/bundle.sh --universal --version "$version" --build "$build" \
    --scratch "$1/scratch" --out "$1/out" >/dev/null)
  chmod -R u=rwX,go=rX "$1/out/Bton.app"
  xattr -cr "$1/out/Bton.app"
  find "$1/out/Bton.app" -exec env TZ=UTC touch -h -t "$stamp" {} +
  # Sorted entries, no extra attributes, times in UTC: the zip depends only on the files.
  (cd "$1/out" && find Bton.app | LC_ALL=C sort | TZ=UTC zip -q -X -D -y -@ "$1/Bton-$version.zip")
}

build_copy "$work/a"
if [[ -n $verify ]]; then
  build_copy "$work/b"
  if ! cmp -s "$work/a/Bton-$version.zip" "$work/b/Bton-$version.zip"; then
    for copy in a b; do
      (cd "$work/$copy/out" && find Bton.app -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2) > "$work/$copy.sums"
    done
    diff "$work/a.sums" "$work/b.sums" >&2 || true
    echo "not reproducible: two builds of v$version differ" >&2
    exit 1
  fi
  echo "reproducible: two builds of v$version are identical"
fi

mkdir -p dist
cp "$work/a/Bton-$version.zip" dist/
(cd dist && shasum -a 256 "Bton-$version.zip" > SHA256SUMS)
cat dist/SHA256SUMS
