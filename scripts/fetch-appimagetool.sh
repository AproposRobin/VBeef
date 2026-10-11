#!/bin/bash
# Downloads the pinned appimagetool and AppImage type2 runtime into a folder and checks them
# against the sha256 GitHub publishes for those release assets (docs/Linux.md > Packages).
# Files already there with the right checksum are kept.
#
# Usage: scripts/fetch-appimagetool.sh [dir]
#   dir  default $APPIMAGE_TOOLS, else ${XDG_CACHE_HOME:-~/.cache}/visualbeef-ci/appimage-tools
# Then: APPIMAGE_TOOLS=<dir> scripts/package_linux.sh --appimage
set -eu
DIR=${1:-${APPIMAGE_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/visualbeef-ci/appimage-tools}}

# name | url | sha256 (the release asset digest on GitHub)
PINS="appimagetool-x86_64.AppImage|https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage|ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
runtime-x86_64|https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64|2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d"

mkdir -p "$DIR"
while IFS='|' read -r name url sum; do
  f="$DIR/$name"
  if [ -f "$f" ] && echo "$sum  $f" | sha256sum -c --status; then
    echo "ok (cached) $f"
    continue
  fi
  rm -f "$f.part"
  curl -fsSL --retry 3 -o "$f.part" "$url"
  if ! echo "$sum  $f.part" | sha256sum -c --status; then
    echo "checksum mismatch for $url (expected $sum, got $(sha256sum "$f.part" | cut -d' ' -f1))" >&2
    rm -f "$f.part"
    exit 1
  fi
  mv "$f.part" "$f"
  echo "ok $f"
done <<< "$PINS"
chmod +x "$DIR/appimagetool-x86_64.AppImage"
