#!/bin/bash
# Builds bin/linux64/libvbhost.so (SDL2 + OpenGL3 + Dear ImGui + imnodes + cimgui + cimnodes),
# the Linux counterpart of build_windows_mingw.sh. VisualBeefNative links it with -lvbhost and an
# rpath to this folder (Native/BeefProj.toml, Configs.*.Linux64).
#
# Requires: g++ (or CXX=clang++), the SDL2 dev package (libsdl2-dev), OpenGL headers (libgl1-mesa-dev).
# Optional: ccache (used when found), JOBS (parallel compiles, default 6), NICE (default 15).
# Usage: Native/build_linux.sh          incremental (only changed sources are recompiled)
#        Native/build_linux.sh clean    removes obj/linux64 first
set -e
cd "$(dirname "$0")"
command -v sdl2-config >/dev/null || { echo "sdl2-config not found: install libsdl2-dev"; exit 1; }
: "${CXX:=g++}"
: "${JOBS:=6}"
: "${NICE:=15}"
CC_WRAP=""
command -v ccache >/dev/null && CC_WRAP=ccache
[ "${1:-}" = "clean" ] && rm -rf obj/linux64
T=third_party
OUT=bin/linux64
mkdir -p $OUT obj/linux64
SRCS="$T/cimgui/imgui/imgui.cpp $T/cimgui/imgui/imgui_draw.cpp $T/cimgui/imgui/imgui_tables.cpp $T/cimgui/imgui/imgui_widgets.cpp $T/cimgui/imgui/imgui_demo.cpp \
      $T/cimgui/imgui/imgui_impl_sdl2.cpp $T/cimgui/imgui/imgui_impl_opengl3.cpp \
      $T/cimgui/cimgui.cpp $T/cimnodes/imnodes/imnodes.cpp $T/cimnodes/cimnodes.cpp host/vbhost.cpp"
FLAGS="-ffile-prefix-map=$(cd .. && pwd)=. -O2 -DNDEBUG -fPIC -fvisibility=hidden -DIMNODES_NAMESPACE=imnodes -DIMGUI_IMPL_API= -I$T/cimgui/imgui -I$T/cimgui -I$T/cimnodes/imnodes $(sdl2-config --cflags)"
export CXX CC_WRAP FLAGS NICE
OBJS=""
TODO=""
for s in $SRCS; do
  o=obj/linux64/$(basename ${s%.cpp}).o
  if [ ! -f $o ] || [ $s -nt $o ]; then TODO="$TODO $s"; fi
  OBJS="$OBJS $o"
done
if [ -n "$TODO" ]; then
  printf '%s\n' $TODO | xargs -P "$JOBS" -I{} sh -c 'o=obj/linux64/$(basename {} .cpp).o; echo "  CXX {}"; nice -n $NICE $CC_WRAP $CXX $FLAGS -c {} -o $o'
fi
$CXX -shared -o $OUT/libvbhost.so $OBJS $(sdl2-config --libs) -lGL -ldl
echo "Built $OUT/libvbhost.so"
