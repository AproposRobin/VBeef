---
audience: developer
title: Linux
summary: Building and testing VisualBeef on Linux under WSL2, and the Linux packages.
order: 16
---

# Linux

VisualBeef was first run on Linux on 2026-10-11, inside WSL2 (Ubuntu 26.04, kernel 6.18, WSLg for
the window). This page lists what it takes, what works and what does not. Windows stays the main
platform; Linux is **experimental** until it has its own package and a CI runner.

## What you need

| | |
|---|---|
| OS | x86-64 Linux with glibc. Tested: Ubuntu 26.04 under WSL2 (WSL 3.0.1). A desktop session (X11, or Wayland with XWayland) for the editor; nothing graphical for the tests. |
| Packages | `build-essential cmake ninja-build clang lld git ccache python3 llvm-22-dev libzstd-dev libxml2-dev libedit-dev zlib1g-dev libcurl4-openssl-dev libffi-dev autoconf automake libtool texinfo libsdl2-dev libgl1-mesa-dev zenity` (zenity: the editor's Open dialogs). Optional for screenshots: `imagemagick xdotool x11-apps`. |
| Beef | Built from source. There is no Linux binary release and no 0.43.6 tag. Beef `master` needs exactly **LLVM 22.1** (`llvm-22-dev`, in the Ubuntu 26.04 archive; elsewhere apt.llvm.org), and the build script stops if it is missing instead of compiling LLVM. The 0.43.5 tag wants LLVM 18.1, which Ubuntu 26.04 does not ship. Tested commit: `8bd578c5` (2026-10-10). |
| Disk | About 4 GB: the Beef tree with both build trees 1.7 GB, the LLVM 22 packages 0.6 GB, the other packages, VisualBeef and its build. |
| Time | Beef `bin/build.sh` (Debug and Release runtime, IDEHelper, BeefBuild, Beef's own tests): **3 min 6 s** wall at `nice -n 15` with 6 parallel jobs, peak 1.3 GB in one process. `Native/build_linux.sh` 8 s. VisualBeefTests or VisualBeefEditor: a few seconds. The full `scripts/linux-ci.sh` run with the corpus: 3 min 6 s. |

## Build

```
# 1. Beef (once)
sudo apt install build-essential cmake ninja-build clang lld git ccache python3 llvm-22-dev \
    libzstd-dev libxml2-dev libedit-dev zlib1g-dev libcurl4-openssl-dev libffi-dev \
    autoconf automake libtool texinfo libsdl2-dev libgl1-mesa-dev zenity
git clone https://github.com/beefytech/Beef ~/beef
CMAKE_BUILD_PARALLEL_LEVEL=6 nice -n 15 ~/beef/bin/build.sh
export PATH=~/beef/IDE/dist:$PATH          # BeefBuild
export VB_BEEF_LIBS=~/beef/BeefLibs         # corlib for the catalog (else found next to the BeefBuild on PATH)

# 2. The native host (SDL2 + ImGui + imnodes), then VisualBeef
Native/build_linux.sh                       # -> Native/bin/linux64/libvbhost.so
BeefBuild -workspace=$PWD -project=VisualBeefEditor -config=Debug
build/Debug_Linux64/VisualBeefEditor/VisualBeefEditor <project-folder>

# 3. Headless tests
scripts/linux-ci.sh [corpus-folder]         # corpus-folder holds UnrealUMP/ and ClockWorkEngine/ sources
```

* Clone on Linux (LF line endings) and build in the Linux file system. A Windows checkout seen
  through `/mnt/<drive>` has CRLF files (`core.autocrlf`) and is slow. `.gitattributes` keeps `*.sh`
  LF everywhere.
* `Native/bin/linux64/libvbhost.so` in the repository was built on Ubuntu 26.04 and needs glibc
  2.43; on an older distribution run `Native/build_linux.sh` (it rebuilds what changed).
* Per-user files go to `~/.local/share/VisualBeef` (settings, layout, logs, recovery) and the
  symbol cache to `$XDG_CACHE_HOME/VisualBeef/index` (else `~/.cache/VisualBeef/index`). `VB_HOME`
  moves both, as on Windows. BeefBuild is looked up on `PATH` unless Preferences name one.
* Compiling from the editor runs `BeefBuild -workspace=... -config=...` without `-platform`, so
  BeefBuild builds for the machine it runs on (`Debug_Linux64`).

## Test results (2026-10-11, WSL2, Debug)

Every suite of [Testing.md](Testing.md) except `debug`, run by `scripts/linux-ci.sh` on a copy of
the UnrealUMP and ClockWork sources (`*.bf` and `*.toml` only):

| Command | Linux | Windows (Testing.md table) |
|---|---|---|
| `edits` | `edits ok, factory failures 0, flow failures 0` | same |
| `flow` / `calls` / `lifetime` / `textforms` / `classes` | 141 / 75 / 92 / 91 / 353 checks, 0 failures | same |
| `safety` | `failures=0`, 119 `ok` lines | `failures=0`, 130 `ok` lines (see below) |
| `parser` | 296 checks, 0 failures | same |
| `catalog` | 219 passed, 0 failed | same |
| `diagnostics` / `ump` | 49 / 32 checks, 0 failures | same |
| `vocabulary` | 83 source files, 0 hits, 0 failures | same |
| `compile -out` | `cases=42 compiled=30 refusals=12 failures=0` (1.7 s) | same |
| `roundtrip` (3 UMP folders) | `files=174 methods=1545 failures=0 broken=0` (29 s) | `failures=0 broken=0` (about 15 s) |
| `roundtrip -types` | same counts, 0 failures (30 s) | same |
| `roundtrip` UMP `src` + ClockWork | `files=106 methods=1229 failures=0 broken=0` (23 s) | `failures=0` (about 8 s) |
| `orphans` | `files=174 methods=1545 failures=0` (55 s) | `failures=0` (about 25 s) |
| `loadall` | `files=322 methods=2718 nodes=125145 ... failures=0` (5 s) | `failures=0` (about 30 s) |
| `savecheck` | `files=204 edits=353 failures=0` (4.3 s) | identical counts |
| `debugmap` | `files=204 methods=1695 statements=25516 values=49295 without-line=56 failures=0` | identical counts |
| `debug` | not run: the debugger is Windows-only | 47 checks |

File and method counts differ from the Windows table only because the UMP tree moved on. The long
suites are 2 to 3 times slower than on Windows under WSL (`nice -n 15` next to a busy Windows
side).

`safety` differs between the platforms: drive-letter and UNC roots (`C:/`, `Z:/`, `//server`) are
not roots on Linux, and POSIX has no mandatory file locks, so "a file locked by another program"
cannot block a save (Windows-only checks); group 12 checks the freedesktop Trash on Linux (15
checks, 3 on Windows) and group 19, the crash report writer, is Linux-only (17 checks).
2026-10-11 (`scripts/ci-linux-local.sh`, no corpus): every suite exit 0, `safety`
154 `ok` lines (125 before the Trash and crash-report checks), `vocabulary` 89 source files,
0 hits.

* After a merge, rebuild the editor from a clean `build/Debug_Linux64/VisualBeefEditor` if `BeefBuild` finishes in about a second without linking: a stale build cache kept the old binary once.

## The editor under WSLg

`VB_SELFTEST=session` (the end-to-end path of [Testing.md](Testing.md#verifying-the-ui): New
Class, variables, functions, nodes from the Node menu, override, Save All, Compile with BeefBuild,
edit / undo / redo, a Receiver error, a compile error on its node, the fix, close and reopen) ran
on a scratch project with **38 checks, `done failures=0`** (re-run after the 0.1.3 merge: 42 `ok` lines, `done failures=0`; `VB_SELFTEST=open:Reader.Read(),ids` on a project with `MyMod.IO.File`, `MyMod.Net.File` and `IdProj.IO` classes: 0 conflicting IDs, 21,180 rows). The
compiled program runs. Screenshots of that run were taken with `import` from XWayland.

2026-10-12 (0.1.7): `Native/build_linux.sh` compiles the changed `Native/host/vbhost.cpp` (per-window display scale, `vbh_get_window_scale`, float framebuffer math) without errors; `scripts/linux-ci.sh` (now also `hotkeys` and `stress`) all green; `VB_SELFTEST=session` under WSLg `done failures=0`. **Windows host DLL not rebuilt; DPI change inactive on Windows until rebuilt** (no MinGW on the build machine): the shipped `vbhost.dll` is the previous build and Beef has no extern for `vbh_get_window_scale` yet.

## Packages: tarball and AppImage

`scripts/package_linux.sh [--appimage] [out-dir]` builds the Release editor and writes
`VisualBeef-<ver>-<channel>-linux64.tar.gz`; with `--appimage` also
`VisualBeef-<ver>-<channel>-x86_64.AppImage`, each with a `.sha256`. The AppImage is made from
`packaging/linux/` (`AppRun`, `visualbeef.desktop`, the 48 px `visualbeef.png` taken from the
Windows icon): the tarball folder goes to `usr/lib/visualbeef`, the distribution's
`libSDL2-2.0.so.0` to `usr/lib`. `AppRun` puts `usr/lib` on `LD_LIBRARY_PATH` for the bundled SDL2
and keeps the caller's value in `VB_APPIMAGE_ORIG_LD_LIBRARY_PATH`; once the window is up the editor
puts that back, so BeefBuild, zenity and the compiled program do not inherit the AppImage's path.
OpenGL and the X11 / Wayland client libraries come from the system.

The tool is appimagetool **1.9.1** with the type2 runtime **20251108** as `--runtime-file`, found
through `APPIMAGETOOL` / `APPIMAGE_RUNTIME`, `PATH`, or `APPIMAGE_TOOLS` (default
`~/.cache/visualbeef-ci/appimage-tools`); `scripts/fetch-appimagetool.sh [dir]` downloads both and
checks the sha256 GitHub publishes for the release assets. appimagetool runs with `APPIMAGE_EXTRACT_AND_RUN=1`, so
the build needs no FUSE. The script checks that the AppImage's `--version` prints
`VisualBeef <ver>-<channel> (UMP contract N)`.

Run it as `./VisualBeef-0.1.7-alpha-x86_64.AppImage [project-folder]`, or with
`--appimage-extract-and-run` first where FUSE is missing (containers). Checked under WSL2 / WSLg on
2026-10-11: 6.6 MB, `--version` through FUSE and through extract-and-run, the editor window opens
on a project (`VisualBeef alpha - proj`, 1600 x 960) and the session log is written.

## Continuous integration

`.github/workflows/linux.yml` (`ubuntu-24.04` runner, on pushes to master, pull requests and by
hand): the build packages, LLVM 22.1 from apt.llvm.org (`llvm-toolchain-noble-22`; Ubuntu 24.04
does not ship LLVM 22; `libpolly-22-dev` too when that repository has it, its cmake files ask for
Polly), Beef fetched at the pinned commit (`BEEF_COMMIT`, now `8bd578c5`) and built with
`bin/build.sh` (cached per commit), `libvbhost.so` rebuilt from scratch (the committed one needs
glibc 2.43), `scripts/linux-ci.sh` (no corpus), then `scripts/fetch-appimagetool.sh` and
`scripts/package_linux.sh --appimage`; the tarball, the AppImage and their `.sha256` are uploaded
as the `visualbeef-linux-x86_64` artifact, the build logs when a step fails. Packages built there
need glibc 2.39 (the runner's) instead of 2.43. Moving Beef forward means changing `BEEF_COMMIT`
in the workflow (the cache key follows).

The workflow was checked with a YAML parse and shellcheck over every `run:` block (actionlint is
not packaged for Ubuntu 26.04), not on GitHub. `scripts/ci-linux-local.sh [out-dir]` runs the
same steps on a machine that already has the packages: it checks `llvm-config-22`, uses the Beef
tree at `BEEF_DIR` (stops when it is not at the pinned commit unless `BEEF_ANY_COMMIT=1`; clones
and builds it when missing), builds the host (`CLEAN_HOST=1` from scratch, as CI), runs the
tests, fetches appimagetool and packages into `build/ci-dist`.

## Display scale and raising the window

The SDL host (`Native/host/vbhost.cpp`) reads the scale from `VB_UI_SCALE`, else `GDK_SCALE`
(clamped to 1 to 3; SDL's EDID DPI is ignored off Windows because it says nothing about what the
user chose). It sizes the window, loads the fonts and scales the style with it, and the editor
now takes the same value from `vbh_get_window_scale` (`Desktop.WindowDpiScale`). Before, the
editor used 1.0 on Linux and `Look.Apply` undid the host's scaling, so `GDK_SCALE=2` drew at half
size. Checked under WSLg with `GDK_SCALE=2`: text, icons and toolbar at 2x. A Wayland session
with `SDL_VIDEODRIVER=wayland` and a 2x output gets the framebuffer scale from SDL
(`SDL_WINDOW_ALLOW_HIGHDPI`) without the env variable.

`Desktop.BringToFront` (Windows: `SetForegroundWindow`) calls `vbh_raise_window` on Linux:
restore when minimized, then `SDL_RaiseWindow`. A window manager with focus-stealing prevention
may only mark the window as wanting attention. `VB_DEBUG_RAISE_TEST=<seconds>` raises the window
after that many seconds and logs the minimized / focused state before and after. Under WSLg,
`xdotool windowminimize` does not minimize an XWayland window, so the restore branch was not
observed there; the raise call ran and the window kept the focus.

## Crash reports

`CrashHandler.Install` puts `sigaction` handlers for SIGSEGV, SIGBUS, SIGILL, SIGFPE and SIGABRT in
front of the Beef runtime's crash catcher (`CrashHandlerPosix.bf`), and a Beef runtime error
(`Runtime.FatalError`, a failed assert) goes through the same writer. A crash writes
`visualbeef-crash-YYYY-MM-DD-HHMMSS-<pid>.log` (UTC) to

* `$VB_HOME/crashes` when `VB_HOME` is set, else
* `$XDG_STATE_HOME/visualbeef/crashes` (an absolute `XDG_STATE_HOME` only, as the spec says), else
* `~/.local/state/visualbeef/crashes`.

The report holds the version, the signal and its code, the fault address, the registers (from the
handler's `ucontext`), the open project folder, a `backtrace(3)` stack (`binary(+offset) [address]`;
a Beef binary exports few symbols, resolve frames with `addr2line -f -C -e <binary> <address>`) and
whether the recovery journal was flushed. Everything on that path uses fixed buffers and `write(2)`
(`PosixCrashReport` in VisualBeefCore). The session log gets `[CRASH] report written: <path>`, the
same line goes to stderr, then the signal goes on to the runtime's handler, which prints its own
backtrace and ends the process with the original signal (exit 139 for SIGSEGV). The next start
shows "The last session crashed. Crash report: <path>" once (`last-seen.txt` in the folder) and the
recovery prompt as usual; the folder keeps the 30 newest reports. No minidump (there is no dbghelp
equivalent; enable core dumps for that). `VB_DEBUG_CRASH_TEST=1` / `thread` / `fatal` / `dirty`
work as on Windows. `safety` group 19 checks the writer (folder rules, content, the next-start
lookup, pruning); the signal path was checked under WSLg with `VB_DEBUG_CRASH_TEST=1` and
`=fatal-dirty`.

## What does not work on Linux (yet)

* **Debugger.** The debugger uses `IDEHelper64.dll` of the Beef IDE. Beef's Linux build has only
  a static `libIDEHelper.a`, and its Linux debugger needs LLDB (`build.sh` printed "LLDB was not
  found; Linux IDE debugger support will be disabled"). Start Debugging reports "the debugger is
  only available on Windows". Wiring a Linux debugger means building Beef with LLDB
  (`liblldb-22-dev`) and loading a shared IDEHelper, or driving LLDB directly.
* **File locks.** A file another program holds open cannot stop a save (no mandatory locks), and
  the recovery `session.lock` is not deleted by the system when the editor dies; a second editor
  does not see that a running session owns its recovery folder.
* **Window integration.** The idle wait is a Windows call: on Linux the idle loop wakes every
  16 ms instead of sleeping until input. Raising and the display scale go through the SDL host
  (below). There is no "second instance hands its arguments to the running editor" path on any
  platform yet (a later UMP item), so nothing asks the window to rise
  except the editor itself.
* **Open dialogs** use `zenity` (started without a shell, the folder is one argument). Without
  zenity the editor's own ImGui file browser is used. The zenity path was built but not driven in
  this run.
* **Packaging.** No .deb / .rpm / Flatpak; the tarball and the AppImage (below) only. Building
  always needs a Beef source build for BeefBuild, and both packages need glibc 2.43 (Ubuntu 26.04)
  because they are built there.

## Windows-only code and what Linux does

| Where | Windows | Linux |
|---|---|---|
| `CrashHandler.bf` `Win32Raw` (session log, recovery journal, crash report) | kernel32 / dbghelp, exception filter, RtlVirtualUnwind, minidump | `PosixRaw.bf`: same signatures over `open` / `write` / `fsync` / `close` / `localtime_r` / `getpid` / `gettid`; crashes through `CrashHandlerPosix.bf` (`sigaction`) + `PosixCrashReport` (registers, `backtrace(3)`), no minidump |
| UTF-16 paths for `Win32Raw` | `ToScopedNativeWChar!` (UTF-16) | `Utf16Text.Scoped!` on both (wchar_t is UTF-32 on Linux) |
| `Program.bf` console attach | `AttachConsole` / `GetStdHandle` | not needed (stdout stays the terminal) |
| `Desktop.bf` | HWND lookup, DPI, idle wait, `SetForegroundWindow` | the host: `vbh_get_window_scale` (DPI), `vbh_raise_window` (`SDL_RestoreWindow` + `SDL_RaiseWindow`), `vbh_window_flags` (minimized / focused); idle wait is a 16 ms sleep |
| `FileSafety.AtomicWrite` | `.tmp` + `ReplaceFileW` with `.bak` | `.tmp` + fsync + copy to `.bak` + `rename(2)`; a read-only file is refused (`access(W_OK)`), as on Windows. Before, Linux wrote the file in place with no backup. |
| `FileSafety` delete | Recycle Bin (`SHFileOperationW`) | freedesktop.org Trash (`FreedesktopTrash.bf`: home trash, or the mount's `.Trash-<uid>`), else nothing deleted |
| `LibraryIndex` BeefLibs / cache | `C:\Program Files\BeefLang\BeefLibs`, `%LOCALAPPDATA%\VisualBeef\index` | `VB_BEEF_LIBS`, else `<BeefBuild on PATH>/../../BeefLibs`; `~/.cache/VisualBeef/index` |
| `LibraryIndex.Join`, `ProjectContract` (`.vbproject`, `--new-ump-mod`, command line), node menu, preferences | built paths with `\` | native separator; `Normalize` keeps `/`, marker `main` read with `\` or `/` |
| BeefBuild | `C:\Program Files\BeefLang\bin\BeefBuild.exe`, `-platform=Win64` | `BeefBuild` on `PATH`, no `-platform` |
| Debugger (`DebugEngine`, `DebugSession`, `DebugTarget`) | `IDEHelper64.dll` | not available (message) |
| Show in Explorer | `explorer.exe /select,` | `xdg-open` on the folder |
| Native host file dialog | `IFileOpenDialog` | `zenity` via `fork` + `execvp` (was `popen` with the folder pasted into a shell command) |
| Tests | `C:\...` corlib and BeefBuild paths, `\` joins | `CorlibDir`, `VB_BEEFBUILD` or `PATH`, native separators; Windows-only safety checks under `#if` |
