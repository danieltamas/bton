#!/usr/bin/env bash
# Builds Bton.app from the SwiftPM targets: the app and CLI binaries, Info.plist and the icons
# committed in Support/Resources. Ad hoc signed. --universal builds arm64 and x86_64 and joins
# them; --version and --build stamp Info.plist, --source the commit a build from a checkout
# comes from (BtonSource, for Settings > About); --scratch and --out place the build. The source
# and build paths are remapped in the binaries, so where the tree lives leaves no trace in them.
set -euo pipefail
cd "$(dirname "$0")/.."

archs=("$(uname -m)")
version=""
build=""
source=""
scratch=.build
out=build
while (($#)); do
  case $1 in
    --universal) archs=(arm64 x86_64) ;;
    --version) version=$2; shift ;;
    --build) build=$2; shift ;;
    --source) source=$2; shift ;;
    --scratch) scratch=$2; shift ;;
    --out) out=$2; shift ;;
    *) echo "usage: bundle.sh [--universal] [--version <x.y.z> --build <n>] [--source <describe>] [--scratch <dir>] [--out <dir>]" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p "$scratch" "$out"
src=$(pwd -P)
scratch=$(cd "$scratch" && pwd -P)
export ZERO_AR_DATE=1

slices=()
for arch in "${archs[@]}"; do
  flags=(-c release --scratch-path "$scratch" --triple "$arch-apple-macosx14.0"
         -Xswiftc -file-prefix-map -Xswiftc "$src=/bton"
         -Xswiftc -file-prefix-map -Xswiftc "$scratch=/bton/.build")
  swift build "${flags[@]}" >&2
  slices+=("$(swift build "${flags[@]}" --show-bin-path)")
done

app="$out/Bton.app"
if [[ -d "$app" ]]; then rm -R "$app"; fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
# The CLI serves a schedule's `ask` tool to its agent (bton ask-server).
for binary in Bton BtonCLI; do
  lipo -create "${slices[@]/%//$binary}" -output "$app/Contents/MacOS/$binary"
  # SwiftPM adds the toolchain's own library folder as an rpath. Nothing loads from it (the
  # Swift runtime is the OS's), and it would tie the bytes to where Xcode is installed.
  otool -l "$app/Contents/MacOS/$binary" | awk '$1 == "path" { print $2 }' | sort -u \
    | grep '\.xctoolchain/' | while read -r rpath; do
      install_name_tool -delete_rpath "$rpath" "$app/Contents/MacOS/$binary" 2>/dev/null
    done
  # Debug symbols name each object file with its build time; the release carries none.
  strip -S "$app/Contents/MacOS/$binary" 2>/dev/null
done
cp Support/Info.plist "$app/Contents/Info.plist"
if [[ -n $version ]]; then
  plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "${build:-1}" "$app/Contents/Info.plist"
fi
if [[ -n $source ]]; then
  plutil -replace BtonSource -string "$source" "$app/Contents/Info.plist"
fi
cp Support/Resources/* "$app/Contents/Resources/"
# About's Update runs the same installer as the curl line, pinned to the release it showed.
install -m 755 install.sh "$app/Contents/Resources/install.sh"

# Ad-hoc unless this Mac has "Bton Local" (scripts/make-signing-identity.sh): an ad-hoc build is a
# new app to macOS privacy every time. A release stays ad-hoc so two builds match byte for byte.
identity=-
if [[ -z $version ]] && security find-identity -p codesigning 2>/dev/null | grep -q '"Bton Local"'; then
  identity="Bton Local"
fi
codesign --force --sign "$identity" "$app/Contents/MacOS/BtonCLI"
codesign --force --sign "$identity" "$app"
echo "$app"
