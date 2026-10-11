#!/bin/bash
# Builds the Release editor on Linux and assembles the blank (alpha) tarball (docs/Operations.md > Blank builds).
#
# Usage: scripts/package_linux.sh [--appimage] [out-dir]      (default: dist/ in the repo)
#   --appimage  also build <out>/VisualBeef-<ver>-<channel>-x86_64.AppImage (+ .sha256), see below.
#   BEEF_DIR   Beef source tree built with bin/build.sh (default ~/beef); its IDE/dist holds BeefBuild.
#   JOBS_NICE  nice level for the build (default 15).
#   APPIMAGETOOL     appimagetool to use (default: appimagetool or appimagetool-x86_64.AppImage on PATH,
#                    else $APPIMAGE_TOOLS/appimagetool-x86_64.AppImage). Release 1.9.1 is the tested one.
#   APPIMAGE_RUNTIME type2 runtime file passed as --runtime-file (default: $APPIMAGE_TOOLS/runtime-x86_64
#                    when present; without one appimagetool downloads the runtime).
#   APPIMAGE_TOOLS   folder holding the two files above (default ${XDG_CACHE_HOME:-~/.cache}/visualbeef-ci/appimage-tools);
#                    scripts/fetch-appimagetool.sh fetches them with their published sha256.
#
# Output: <out>/VisualBeef-<ver>-<channel>-linux64.tar.gz (+ .sha256) holding one folder VisualBeef/ with
# VisualBeefEditor, libvbhost.so, assets/, VERSION.txt, LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY/ and
# README-linux.txt. No docs. The binary finds libvbhost.so next to itself (rpath $ORIGIN).
set -eu
cd "$(dirname "$0")/.."
WS=$(pwd)
BEEF_DIR=${BEEF_DIR:-$HOME/beef}
NICE=${JOBS_NICE:-15}
APPIMAGE=0
if [ "${1:-}" = "--appimage" ]; then APPIMAGE=1; shift; fi
OUTDIR=${1:-$WS/dist}
export PATH="$BEEF_DIR/IDE/dist:$PATH"
export VB_BEEF_LIBS=${VB_BEEF_LIBS:-$BEEF_DIR/BeefLibs}
command -v BeefBuild >/dev/null || { echo "BeefBuild not found in $BEEF_DIR/IDE/dist (docs/Linux.md)"; exit 2; }

INFO=VisualBeefCore/src/Document/CommandLine.bf
VER=$(sed -n 's/.*public const String Version = "\([^"]*\)";.*/\1/p' "$INFO" | head -1)
CHAN=$(sed -n 's/.*public const String Channel = "\([a-z0-9]*\)";.*/\1/p' "$INFO" | head -1)
[ -n "$VER" ] && [ -n "$CHAN" ] || { echo "VisualBeefInfo.Version / Channel not found in $INFO"; exit 2; }
FULL="$VER-$CHAN"

echo "== libvbhost.so"
nice -n "$NICE" Native/build_linux.sh

echo "== BeefBuild VisualBeefEditor (Release)"
# A stale build cache can skip the relink (docs/Linux.md): delete the outputs first.
rm -rf build/Release_Linux64/VisualBeef*
mkdir -p build
nice -n "$NICE" BeefBuild -workspace="$WS" -project=VisualBeefEditor -config=Release > build/linux-package-build.log 2>&1 \
  || { tail -30 build/linux-package-build.log; echo "build failed (build/linux-package-build.log)"; exit 1; }
EXE=build/Release_Linux64/VisualBeefEditor/VisualBeefEditor
[ -x "$EXE" ] || { echo "missing $EXE"; exit 1; }

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/vb-pack.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/VisualBeef"
mkdir -p "$D/assets/fonts" "$D/THIRD_PARTY"
cp "$EXE" "$D/VisualBeefEditor"
cp Native/bin/linux64/libvbhost.so "$D/libvbhost.so"
cp VisualBeefEditor/assets/fonts/lucide.ttf VisualBeefEditor/assets/fonts/LICENSE-lucide.txt "$D/assets/fonts/"
cp LICENSE NOTICE THIRD_PARTY.md "$D/"
cp THIRD_PARTY/*.txt "$D/THIRD_PARTY/"
printf '%s\n' "$FULL" > "$D/VERSION.txt"
cat > "$D/README-linux.txt" <<EOT
VisualBeef $FULL (Linux x86-64, blank alpha build: the application only, no docs).
Requirements:
  - glibc 2.43 or newer (built on Ubuntu 26.04), x86-64
  - SDL2 runtime (libsdl2-2.0-0) and OpenGL (libgl1)
  - zenity, for the Open dialogs (without it the editor's own file browser is used)
  - a Beef toolchain with BeefBuild on PATH, to compile projects from the editor
  - a desktop session: DISPLAY (X11 / XWayland) or WAYLAND_DISPLAY
Run: ./VisualBeefEditor [project-folder]      ./VisualBeefEditor --version
Settings and logs: ~/.local/share/VisualBeef (VB_HOME moves them). Licences: LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY/.
EOT

# The editor must load libvbhost.so from its own folder.
if readelf -d "$D/VisualBeefEditor" | grep -q 'RUNPATH\|RPATH'; then
  readelf -d "$D/VisualBeefEditor" | grep -q '\$ORIGIN' || { echo "binary has no \$ORIGIN rpath"; readelf -d "$D/VisualBeefEditor" | grep 'RPATH\|RUNPATH'; exit 1; }
else
  echo "binary has no rpath"; exit 1
fi
REPORTED=$(cd "$D" && env -u LD_LIBRARY_PATH ./VisualBeefEditor --version | head -1)
case "$REPORTED" in "VisualBeef $FULL (UMP contract "*) ;; *) echo "--version printed '$REPORTED', expected 'VisualBeef $FULL ...'"; exit 1;; esac

mkdir -p "$OUTDIR"
TAR="$OUTDIR/VisualBeef-$FULL-linux64.tar.gz"
rm -f "$TAR" "$TAR.sha256"
tar -C "$STAGE" --owner=0 --group=0 --sort=name -czf "$TAR" VisualBeef
# Owner's rule (2026-10-12): no developer page in a package. This tarball has no docs at all; the check proves it.
if tar -tzf "$TAR" | grep -E '(^|/)(docs/|(Architecture|Testing|CI|Code-Signing|Codegen|Parsing-and-Layout|Catalog-and-Types|Linux|UMP-Integration|Vocabulary|CHANGELOG|README)\.md$)'; then
  echo "developer documentation in $TAR" >&2; exit 1
fi
( cd "$OUTDIR" && sha256sum "$(basename "$TAR")" > "$(basename "$TAR").sha256" )
echo "Packaged $TAR ($(du -h "$TAR" | cut -f1))"
cat "$TAR.sha256"

[ "$APPIMAGE" = 1 ] || exit 0

# ---- AppImage: AppDir = AppRun + .desktop + icon at the root, the tarball folder in
# usr/lib/visualbeef, the distribution's SDL2 in usr/lib (AppRun puts it on LD_LIBRARY_PATH).
echo "== AppImage"
TOOLS=${APPIMAGE_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/visualbeef-ci/appimage-tools}
TOOL=${APPIMAGETOOL:-}
[ -n "$TOOL" ] || TOOL=$(command -v appimagetool || command -v appimagetool-x86_64.AppImage || true)
[ -n "$TOOL" ] || TOOL="$TOOLS/appimagetool-x86_64.AppImage"
[ -x "$TOOL" ] || { echo "appimagetool not found (APPIMAGETOOL, PATH or $TOOLS; scripts/fetch-appimagetool.sh fetches it)"; exit 2; }
RUNTIME=${APPIMAGE_RUNTIME:-$TOOLS/runtime-x86_64}
A="$STAGE/VisualBeef.AppDir"
mkdir -p "$A/usr/lib" "$A/usr/share/applications" "$A/usr/share/icons/hicolor/48x48/apps"
cp -a "$D" "$A/usr/lib/visualbeef"
SDL=$(ldd Native/bin/linux64/libvbhost.so | awk '/libSDL2-2\.0\.so\.0/ {print $3}')
[ -f "$SDL" ] || { echo "libSDL2-2.0.so.0 not found (libsdl2-2.0-0)"; exit 1; }
cp -L "$SDL" "$A/usr/lib/libSDL2-2.0.so.0"
install -m 755 packaging/linux/AppRun "$A/AppRun"
cp packaging/linux/visualbeef.desktop "$A/visualbeef.desktop"
cp packaging/linux/visualbeef.desktop "$A/usr/share/applications/visualbeef.desktop"
cp packaging/linux/visualbeef.png "$A/visualbeef.png"
cp packaging/linux/visualbeef.png "$A/usr/share/icons/hicolor/48x48/apps/visualbeef.png"
ln -s visualbeef.png "$A/.DirIcon"
cat > "$A/usr/lib/visualbeef/README-linux.txt" <<EOT
VisualBeef $FULL (Linux x86-64 AppImage, blank alpha build: the application only, no docs).
Requirements:
  - glibc 2.43 or newer (built on Ubuntu 26.04), x86-64
  - OpenGL (libgl1) and the usual X11 / Wayland client libraries (SDL2 is inside the AppImage)
  - FUSE 2 or 3 to mount the AppImage; without it: ./VisualBeef-$FULL-x86_64.AppImage --appimage-extract-and-run
  - zenity, for the Open dialogs (without it the editor's own file browser is used)
  - a Beef toolchain with BeefBuild on PATH, to compile projects from the editor
Run: ./VisualBeef-$FULL-x86_64.AppImage [project-folder]      ... --version
Settings and logs: ~/.local/share/VisualBeef (VB_HOME moves them); crash reports: ~/.local/state/visualbeef/crashes.
Licences: LICENSE, NOTICE, THIRD_PARTY.md, THIRD_PARTY/ next to this file inside the AppImage (--appimage-extract).
EOT
APPIMG="$OUTDIR/VisualBeef-$FULL-x86_64.AppImage"
rm -f "$APPIMG" "$APPIMG.sha256"
RT_ARGS=()
[ -f "$RUNTIME" ] && RT_ARGS=(--runtime-file "$RUNTIME")
# APPIMAGE_EXTRACT_AND_RUN: appimagetool is itself an AppImage, and FUSE is often missing (WSL, containers).
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 VERSION="$FULL" nice -n "$NICE" "$TOOL" --no-appstream "${RT_ARGS[@]}" "$A" "$APPIMG" \
  > build/linux-appimage.log 2>&1 || { tail -30 build/linux-appimage.log; echo "appimagetool failed (build/linux-appimage.log)"; exit 1; }
chmod +x "$APPIMG"
REPORTED=$(APPIMAGE_EXTRACT_AND_RUN=1 env -u LD_LIBRARY_PATH "$APPIMG" --version | head -1)
case "$REPORTED" in "VisualBeef $FULL (UMP contract "*) ;; *) echo "AppImage --version printed '$REPORTED', expected 'VisualBeef $FULL ...'"; exit 1;; esac
( cd "$OUTDIR" && sha256sum "$(basename "$APPIMG")" > "$(basename "$APPIMG").sha256" )
echo "Packaged $APPIMG ($(du -h "$APPIMG" | cut -f1)): $REPORTED"
cat "$APPIMG.sha256"
