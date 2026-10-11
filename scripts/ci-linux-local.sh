#!/bin/bash
# The steps of .github/workflows/linux.yml on this machine (docs/Linux.md > Continuous integration),
# for a machine that already has the build packages and llvm-22-dev (no apt, no sudo).
#
# Usage: scripts/ci-linux-local.sh [out-dir]          (default build/ci-dist)
#   BEEF_DIR        Beef tree (default ~/beef). Missing: cloned at the pinned commit and built.
#                   Present at another commit: stops, unless BEEF_ANY_COMMIT=1.
#   APPIMAGE_TOOLS  where appimagetool + runtime go (default ${XDG_CACHE_HOME:-~/.cache}/visualbeef-ci/appimage-tools)
#   JOBS_NICE       nice level for every heavy step (default 10)
#   CLEAN_HOST=1    rebuild libvbhost.so from scratch, as CI does (default: incremental)
set -eu
cd "$(dirname "$0")/.."
WS=$(pwd)
export BEEF_DIR=${BEEF_DIR:-$HOME/beef}
export JOBS_NICE=${JOBS_NICE:-10}
OUT=${1:-$WS/build/ci-dist}
export APPIMAGE_TOOLS=${APPIMAGE_TOOLS:-${XDG_CACHE_HOME:-$HOME/.cache}/visualbeef-ci/appimage-tools}
BEEF_COMMIT=$(sed -n 's/^  BEEF_COMMIT: *\([0-9a-f]\{40\}\).*/\1/p' .github/workflows/linux.yml)
[ -n "$BEEF_COMMIT" ] || { echo "BEEF_COMMIT not found in .github/workflows/linux.yml"; exit 2; }
step() { echo; echo "==== $*"; }
T0=$(date +%s)

step "LLVM 22.1"
LLVM_CONFIG=$(command -v llvm-config-22 || true)
[ -n "$LLVM_CONFIG" ] || { echo "llvm-config-22 not found: install llvm-22-dev (Ubuntu 26.04) or from apt.llvm.org"; exit 2; }
"$LLVM_CONFIG" --version | grep -q '^22\.1\.' || { echo "LLVM $("$LLVM_CONFIG" --version), Beef wants 22.1"; exit 2; }
"$LLVM_CONFIG" --version

step "Beef $BEEF_COMMIT in $BEEF_DIR"
if [ ! -d "$BEEF_DIR/.git" ]; then
  git init -q "$BEEF_DIR"
  git -C "$BEEF_DIR" remote add origin https://github.com/beefytech/Beef
  git -C "$BEEF_DIR" fetch -q --depth 1 origin "$BEEF_COMMIT"
  git -C "$BEEF_DIR" checkout -q --detach FETCH_HEAD
fi
HEAD=$(git -C "$BEEF_DIR" rev-parse HEAD)
if [ "$HEAD" != "$BEEF_COMMIT" ] && [ "${BEEF_ANY_COMMIT:-0}" != 1 ]; then
  echo "$BEEF_DIR is at $HEAD, the workflow pins $BEEF_COMMIT (BEEF_ANY_COMMIT=1 to go on)"; exit 2
fi
if [ ! -x "$BEEF_DIR/IDE/dist/BeefBuild" ]; then
  CMAKE_BUILD_PARALLEL_LEVEL=${CMAKE_BUILD_PARALLEL_LEVEL:-6} nice -n "$JOBS_NICE" "$BEEF_DIR/bin/build.sh"
else
  echo "built (IDE/dist/BeefBuild present)"
fi

step "Native host (libvbhost.so)"
if [ "${CLEAN_HOST:-0}" = 1 ]; then NICE=$JOBS_NICE Native/build_linux.sh clean; else NICE=$JOBS_NICE Native/build_linux.sh; fi

step "Tests (scripts/linux-ci.sh)"
TESTS=0
scripts/linux-ci.sh || TESTS=$?

step "appimagetool"
scripts/fetch-appimagetool.sh "$APPIMAGE_TOOLS"

step "Packages (tarball, AppImage) -> $OUT"
scripts/package_linux.sh --appimage "$OUT"

echo
echo "ci-linux-local: tests exit $TESTS, packages in $OUT, $(( $(date +%s) - T0 )) s"
exit $TESTS
