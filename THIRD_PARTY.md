# Third-party notices

VisualBeef itself is licensed under the Apache License, Version 2.0 (`LICENSE`, attribution in
`NOTICE`). The components below are bundled with it or linked into the binaries it produces and keep
their own licences. The exact upstream licence texts are in the `THIRD_PARTY/` folder, which ships in
every package next to this file, so every distribution of `VisualBeefEditor.exe` + `vbhost.dll`
carries them. Nothing here is proprietary and nothing is under a copyleft licence that would apply
to VisualBeef.

## What is in the Windows package

| Component | Version | Licence | Where it ends up | Licence text |
|---|---|---|---|---|
| Dear ImGui (docking branch) | 1.92.9b | MIT, (c) 2014-2026 Omar Cornut | compiled into `vbhost.dll`; source in `Native/third_party/cimgui/imgui/` | `THIRD_PARTY/ImGui-LICENSE.txt` |
| stb_truetype 1.26, stb_rect_pack, stb_textedit | as embedded in Dear ImGui 1.92.9b | public domain, or MIT (alternative A in each header) | compiled into `vbhost.dll` | the header comments in `Native/third_party/cimgui/imgui/imstb_*.h` (public domain dedication and MIT text) |
| cimgui (C bindings for Dear ImGui) | generated for Dear ImGui 1.92.9b docking | MIT, (c) 2015 Stephan Dilly | compiled into `vbhost.dll`; source in `Native/third_party/cimgui/` | `THIRD_PARTY/cimgui-LICENSE.txt` |
| imnodes | as vendored in `Native/third_party/cimnodes/imnodes/` | MIT, (c) 2019 Johann Muszynski | compiled into `vbhost.dll` (not used at run time, see below) | `THIRD_PARTY/imnodes-LICENSE.txt` |
| cimnodes (C bindings for imnodes) | as vendored in `Native/third_party/cimnodes/` | generated from imnodes by the cimgui generator; the upstream repository has no licence file of its own, so imnodes's MIT licence is the one that applies | compiled into `vbhost.dll` | `THIRD_PARTY/imnodes-LICENSE.txt` |
| SDL2 | 2.32.10 (`SDL2-devel-2.32.10-mingw.zip`) | zlib, (c) 1997-2025 Sam Lantinga | **statically linked** into `vbhost.dll` | `THIRD_PARTY/SDL2-LICENSE.txt` |
| LLVM C++ runtime from llvm-mingw 20261006 (clang 23.1.3): libc++, libc++abi, libunwind, compiler-rt builtins | as released in llvm-mingw 20261006 | Apache-2.0 with LLVM Exceptions | **statically linked** into `vbhost.dll` (`-static`) | `THIRD_PARTY/LLVM-LICENSE.txt` |
| mingw-w64 runtime (CRT start-up code, import libraries, headers) | the mingw-w64 revision llvm-mingw 20261006 is built from (`a3d93999ef0521681d45e445c39964a7af0f593f`) | permissive (ZPL / BSD-style / public domain parts; list in the file) | statically linked into `vbhost.dll` | `THIRD_PARTY/mingw-w64-runtime-COPYING.txt` (`COPYING.MinGW-w64-runtime.txt`, the file meant for binaries) |
| Lucide icons (`lucide.ttf`) | 0.460.0 | ISC | shipped as `assets/fonts/lucide.ttf` | `THIRD_PARTY/Lucide-LICENSE.txt` (also `assets/fonts/LICENSE-lucide.txt`) |
| Beef language runtime and corlib | 0.43.6 (nightly 2026-09-14, commit `19ee8d2e`) | MIT, (c) 2019 BeefyTech LLC | linked statically into `VisualBeefEditor.exe` | `THIRD_PARTY/Beef-LICENSE.txt`; the third-party list of the Beef install (`LICENSES.TXT`: cJSON, FreeType, libffi, tcmalloc, utf8proc, LLVM and others) is `THIRD_PARTY/Beef-LICENSES.txt` |
| Beef IDE debugger wrapper (`IDE/src/Debugger/DebugManager.bf`, `Breakpoint.bf`, Beef tag 0.43.5) | 0.43.5 | MIT, (c) 2019 BeefyTech LLC | the C API declarations, run-state enum and message formats are adapted in `VisualBeefCore/src/Debug/DebugEngine.bf` and `DebugSession.bf` | `THIRD_PARTY/Beef-LICENSE.txt` |

System libraries (the Windows universal C runtime `api-ms-win-crt-*`, `KERNEL32`, `USER32`, `GDI32`,
`OPENGL32`, `SETUPAPI`, `WINMM`, `IMM32`, `VERSION`, `ADVAPI32`, `SHELL32`, `OLE32`, `OLEAUT32`) are
imported from Windows and not shipped.

`vbhost.dll` is built from source by `Native/build_windows.ps1` with the pinned llvm-mingw and SDL2
(versions and sha256 in the header of that script and in `scripts/ci-windows.ps1`); the release
build does that in GitHub Actions (`docs/CI.md`). The DLL contains no GCC runtime and no winpthreads.
The Linux build (`libvbhost.so`) compiles the same Dear ImGui, cimgui, imnodes and cimnodes sources and
loads the system's SDL2 dynamically; the Linux packages carry the same `THIRD_PARTY/` folder.

## Not shipped, used at run time or to build

* **The debugger engine `IDEHelper64.dll`** of the Beef installation (MIT, plus LLVM and the libraries in the
  install's `LICENSES.TXT`). It is not bundled (57 MB): VisualBeef looks for it next to
  `VisualBeefEditor.exe`, in `%VB_BEEF_BIN%`, in the folder of the configured BeefBuild and in
  `C:\Program Files\BeefLang\bin`, and without it says "Debugging needs Beef 0.43.6 installed".
  To bundle it later, copy `IDEHelper64.dll`, `BeefDbgVis.toml`, `LICENSE.TXT` and `LICENSES.TXT` from the
  install next to the exe (the two licence files are already in `THIRD_PARTY/`).
* **BeefBuild** (compiling a graph's source) comes from the user's Beef installation.
* **Build tools** (not part of the package): llvm-mingw 20261006 (Apache-2.0 with LLVM Exceptions and
  others), the mingw-w64 SDL2 development files, 7-Zip (LGPL) to unpack the Beef installer in CI.
  The compiler output contains only the runtime pieces listed above.

imnodes is compiled into `vbhost.dll` and has Beef bindings (`Native/src/ImNodes.bf`), but the node
canvas is drawn by VisualBeef itself (`GraphPanel.bf`); imnodes is unused at run time.

## Licence files per vendored folder

* `Native/third_party/cimgui/imgui/LICENSE.txt`: identical to upstream `ocornut/imgui` `LICENSE.txt` at
  v1.92.9b-docking.
* `Native/third_party/cimgui/LICENSE`: identical to upstream `cimgui/cimgui` `LICENSE`.
* `Native/third_party/cimnodes/imnodes/LICENSE.md`: identical to upstream `Nelarius/imnodes` `LICENSE.md`.
* `Native/third_party/cimnodes/`: the cimnodes repository carries no licence file; see the table.
* `VisualBeefEditor/assets/fonts/LICENSE-lucide.txt`: identical to upstream `lucide-icons/lucide` `LICENSE`
  at 0.460.0.

The copies in `THIRD_PARTY/` are byte-for-byte the upstream texts (line endings aside), taken from:
Dear ImGui, cimgui, imnodes, Lucide (their repositories at the versions above), SDL2 (`LICENSE.txt` of
`SDL2-devel-2.32.10-mingw.zip`), LLVM (`LICENSE.TXT` of `llvm-mingw-20261006-ucrt-x86_64.zip`), mingw-w64
(`COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt` at the revision above), Beef (`LICENSE.TXT` and
`LICENSES.TXT` of `BeefSetup_0_43_6__09_14_2026.exe`).
