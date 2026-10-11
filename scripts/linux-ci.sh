#!/bin/bash
# Headless VisualBeef test run on Linux (docs/Linux.md, docs/Testing.md).
#
# Usage: scripts/linux-ci.sh [corpus-dir]
#   BEEF_DIR    Beef source tree built with bin/build.sh (default ~/beef); its IDE/dist holds BeefBuild.
#   corpus-dir  optional folder holding UnrealUMP/ and ClockWorkEngine/ sources for the long suites
#               (roundtrip, orphans, loadall, savecheck, debugmap); skipped when absent.
#   JOBS_NICE   nice level for the build and the runs (default 15).
#
# Builds VisualBeefTests (Debug_Linux64), runs every suite one at a time, prints a summary
# table and exits 1 when any suite failed. `debug` is not run: the debugger is Windows-only.
set -u
cd "$(dirname "$0")/.."
WS=$(pwd)
BEEF_DIR=${BEEF_DIR:-$HOME/beef}
NICE=${JOBS_NICE:-15}
CORPUS=${1:-}
export PATH="$BEEF_DIR/IDE/dist:$PATH"
export VB_BEEF_LIBS=${VB_BEEF_LIBS:-$BEEF_DIR/BeefLibs}

command -v BeefBuild >/dev/null || { echo "BeefBuild not found in $BEEF_DIR/IDE/dist (build Beef first, see docs/Linux.md)"; exit 2; }

mkdir -p build
echo "== build VisualBeefTests"
if ! nice -n "$NICE" BeefBuild -workspace="$WS" -project=VisualBeefTests -config=Debug > build/linux-tests-build.log 2>&1; then
  tail -30 build/linux-tests-build.log
  echo "build failed (build/linux-tests-build.log)"
  exit 1
fi
T="$WS/build/Debug_Linux64/VisualBeefTests/VisualBeefTests"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/vb-ci.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

FAILED=0
SUMMARY=""
run() {
  local name=$1; shift
  local log="$SCRATCH/$name.log"
  local t0=$(date +%s.%N)
  nice -n "$NICE" "$T" "$@" > "$log" 2>&1
  local code=$?
  local t1=$(date +%s.%N)
  local last=$(grep -v '^\s*$' "$log" | tail -1)
  local secs=$(awk "BEGIN{printf \"%.1f\", $t1 - $t0}")
  [ $code -ne 0 ] && { FAILED=1; grep FAIL "$log" | head -20; }
  SUMMARY+=$(printf "%-10s exit=%d %6ss  %s" "$name" "$code" "$secs" "$last")$'\n'
  echo "$name: exit $code, $last"
}

for s in edits flow calls lifetime textforms classes safety parser catalog diagnostics hotkeys ump stress vocabulary; do
  run "$s" "$s"
done
run compile compile -out "$SCRATCH/compile"
echo "debug: skipped (the debugger is Windows-only)"

if [ -n "$CORPUS" ] && [ -d "$CORPUS/UnrealUMP" ]; then
  U="$CORPUS/UnrealUMP"
  C="$CORPUS/ClockWorkEngine"
  run roundtrip roundtrip "$U/src" "$U/UMPRuntime/src" "$U/UnrealSDKCore/src"
  run roundtrip-types roundtrip -types "$U/src" "$U/UMPRuntime/src" "$U/UnrealSDKCore/src"
  [ -d "$C" ] && run roundtrip-cw roundtrip "$U/src" "$C" -out "$SCRATCH/rt"
  run orphans orphans "$U/src" "$U/UMPRuntime/src" "$U/UnrealSDKCore/src"
  run loadall loadall "$U"
  [ -d "$C" ] && run savecheck savecheck "$U/src" "$U/UMPRuntime/src" "$U/UnrealSDKCore/src" "$C"
  [ -d "$C" ] && run debugmap debugmap "$U/src" "$U/UMPRuntime/src" "$U/UnrealSDKCore/src" "$C"
else
  echo "(no corpus folder: roundtrip / orphans / loadall / savecheck / debugmap skipped)"
fi

echo
echo "== summary"
printf "%s" "$SUMMARY"
exit $FAILED
