#!/usr/bin/env bash
# Renders Brand/*.svg into Support/Resources (menu bar template icon, vendor marks, AppIcon.icns).
# The output is committed, so a build copies fixed bytes and never depends on the renderer's
# version. Run it after changing an SVG, and commit the result.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing: brew install librsvg" >&2; exit 2; }
out=Support/Resources
mkdir -p "$out"
# cairo stamps a PDF's creation date from this, so re-rendering an unchanged SVG changes nothing.
export SOURCE_DATE_EPOCH=315532800

rsvg-convert -f pdf Brand/icon-menubar.svg -o "$out/MenubarIcon.pdf"
# The vendors' marks (simple-icons), drawn as templates so the app tints them.
rsvg-convert -f pdf Brand/vendors/claude.svg -o "$out/LogoClaude.pdf"
rsvg-convert -f pdf Brand/vendors/openai.svg -o "$out/LogoOpenAI.pdf"

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  rsvg-convert -w "$size" Brand/icon-app.svg -o "$iconset/icon_${size}x${size}.png"
  rsvg-convert -w "$((size * 2))" Brand/icon-app.svg -o "$iconset/icon_${size}x${size}@2x.png"
done
iconutil -c icns "$iconset" -o "$out/AppIcon.icns"
ls "$out"
