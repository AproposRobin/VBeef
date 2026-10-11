#!/bin/bash
# Cross-compiles vbhost.dll for Windows x64 from Linux with mingw-w64, statically
# linking SDL2 so the DLL has no dependencies beyond system DLLs.
# Usage: SDL2_MINGW=/path/to/SDL2-2.32.x/x86_64-w64-mingw32 LLVM_DLLTOOL=llvm-dlltool ./build_windows_mingw.sh
set -e
cd "$(dirname "$0")"
: "${SDL2_MINGW:?set SDL2_MINGW to the x86_64-w64-mingw32 folder of SDL2-devel-*-mingw}"
: "${LLVM_DLLTOOL:=llvm-dlltool}"
CXX=x86_64-w64-mingw32-g++-posix
T=third_party
OUT=bin/win64
mkdir -p $OUT obj/win64
SRCS="$T/cimgui/imgui/imgui.cpp $T/cimgui/imgui/imgui_draw.cpp $T/cimgui/imgui/imgui_tables.cpp $T/cimgui/imgui/imgui_widgets.cpp $T/cimgui/imgui/imgui_demo.cpp \
      $T/cimgui/imgui/imgui_impl_sdl2.cpp $T/cimgui/imgui/imgui_impl_opengl3.cpp \
      $T/cimgui/cimgui.cpp $T/cimnodes/imnodes/imnodes.cpp $T/cimnodes/cimnodes.cpp host/vbhost.cpp"
FLAGS="-O2 -DIMNODES_NAMESPACE=imnodes -DSDL_MAIN_HANDLED -I$T/cimgui/imgui -I$T/cimgui -I$T/cimnodes/imnodes -I$SDL2_MINGW/include/SDL2"
OBJS=""
for s in $SRCS; do
  o=obj/win64/$(basename ${s%.cpp}).o
  if [ ! -f $o ] || [ $s -nt $o ]; then echo "  CXX $s"; $CXX $FLAGS -c $s -o $o; fi
  OBJS="$OBJS $o"
done
$CXX -shared -o $OUT/vbhost.dll $OBJS -Wl,--output-def,$OUT/vbhost.def \
  -s -static -static-libgcc -static-libstdc++ $SDL2_MINGW/lib/libSDL2.a \
  -lopengl32 -lsetupapi -lwinmm -limm32 -lversion -lole32 -loleaut32 -lgdi32 -luser32 -lshell32 -luuid -ladvapi32 -lcfgmgr32
# MSVC-compatible import library so Beef (MSVC/lld-link) can link against the DLL.
$LLVM_DLLTOOL -m i386:x86-64 -d $OUT/vbhost.def -D vbhost.dll -l $OUT/vbhost.lib
echo "Built $OUT/vbhost.dll + vbhost.lib"
