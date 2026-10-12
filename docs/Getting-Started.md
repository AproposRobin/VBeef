---
audience: user
title: Getting started
summary: Install VisualBeef, open a project, make a class, build a graph, compile it and read the Beef it writes.
order: 1
---

# Getting started

From a clean checkout to a compiled graph, and a look at the Beef it wrote.

## Requirements

* Windows 10 or 11, x64, with OpenGL 3 (any GPU from the last decade).
* The Beef toolchain **0.43.6** at `C:\Program Files\BeefLang` (BeefBuild and the Beef IDE).
  The editor uses `C:\Program Files\BeefLang\bin\BeefBuild.exe` for **Compile** unless you set
  another path in Editor Preferences.
* Nothing else: `vbhost.dll` (SDL2 + Dear ImGui) is prebuilt in `Native/bin/win64/`.

Linux (experimental, tested under WSL2): the Windows build is the main platform.

## Install

VisualBeef is a standalone download. The folder is:

```
VisualBeefEditor.exe      the editor
vbhost.dll                the native window / ImGui host, beside the exe
assets\fonts\lucide.ttf   the icon font (and its licence)
LICENSE  NOTICE  THIRD_PARTY.md  THIRD_PARTY\   Apache-2.0 and the bundled components' notices
docs\                     these pages; start with Getting-Started.md
VERSION.txt               the VisualBeef version (first line)
```

* Unzip `VisualBeef-<version>-win64.zip` and run `VisualBeefEditor.exe`, optionally with a
  project folder or `.bf` file.
  `VisualBeefEditor.exe --version` prints the version. New versions are offered in the editor and installed when you
  choose ([Updating.md](Updating.md)).
* The Beef runtime is linked into the exe, so no Beef DLL is needed to *run* the editor. To **compile** a
  graph you still need the Beef toolchain 0.43.6 (below).
* Settings, layout, logs and caches go to the per-user folder (`VB_HOME` moves it), never next to the exe.

To build the package yourself: `powershell -ExecutionPolicy Bypass -File scripts\package.ps1` builds Release
and writes `dist\VisualBeef\` and `dist\VisualBeef-<version>-win64.zip` (+ `.sha256`). `-NoBuild` repackages the
existing Release build; `-Out` / `-ZipDir` move the outputs. The script stamps the version, product name,
company and icon into the exe's VERSIONINFO (from `VisualBeefInfo.Version`) and checks them, and stops when
a licence file is missing.

### Blank (alpha) builds

A blank build is just the application, marked **alpha** (`VisualBeefInfo.Channel`; `--version` prints
`VisualBeef <version>-alpha (host contract 1)`, the window title starts `VisualBeef alpha`, and `VERSION.txt` reads
`<version>-alpha`). It carries no `docs\`, README or samples, only the licence texts that must travel with the binaries.
Windows: `scripts\package.ps1 -Minimal` writes `dist\VisualBeef-minimal\` and `dist\VisualBeef-<version>-alpha-win64.zip`
(+ `.sha256`): `VisualBeefEditor.exe`, `vbhost.dll`, `assets\`, `VERSION.txt`, `LICENSE`, `NOTICE`, `THIRD_PARTY.md`,
`THIRD_PARTY\`. Linux: `scripts/package_linux.sh` (on Linux) builds Release and
writes `dist/VisualBeef-<version>-alpha-linux64.tar.gz` (+ `.sha256`) with `VisualBeefEditor`, `libvbhost.so` (found
through an `$ORIGIN` rpath), `assets/`, the same licence files and a short `README-linux.txt`. The version line accepts `[A-Za-z0-9][A-Za-z0-9._+-]{0,63}`, so `-alpha` is valid.

## Run and open a project

Start `VisualBeefEditor.exe`. Optional arguments:

```
VisualBeefEditor.exe                                  reopen the last project and tabs
VisualBeefEditor.exe <project folder>                     open this folder (or a .bf file: its project, focused on that file)
VisualBeefEditor.exe <project folder> --file src\Game.bf  open the folder and focus a file in it
VisualBeefEditor.exe --view <project folder>              read-only: nothing is ever written to the project
VisualBeefEditor.exe --version                        print the version (also --help)
```

Exit codes are 0 (ok), 1 (the window or a file could not be created) and 2 (bad command line).
`--new-from-template <template folder> <destination>` writes a new project from a template folder and
opens it (see [Host-Integration.md](Host-Integration.md)).

Use **File > Open Project Folder...** (native folder picker) and choose the folder that holds your
Beef projects. Every `.bf` file under it is indexed (`build`, `recovery` and dot-folders are
skipped). Use **File > Open Project (Read-only)...** to look at someone else's code without
risking a write; the status bar shows `[LOCKED read-only]` in that mode.

Large folders open at once: indexing runs in the background with a progress bar in the status
bar, and generated libraries inside the folder are loaded as cached libraries. Settings, the
dock layout and logs live in `%LOCALAPPDATA%\VisualBeef`, whatever folder you start the exe from.

## Make a class

1. In the **Project Browser** (bottom), open the folder that should contain it.
2. **+ Add > New Class** (or **File > New Class...**). Choose a name such as `Greeter`.
3. The file `Greeter.bf` is created in the `src` folder of the enclosing project, in the same
   namespace as its neighbours. Existing files are never overwritten, and names must be unique
   within a namespace.
4. **Double-click** the new tile to open it in **Outline**.

New structs, enums, interfaces, plain files, folders and whole projects (`BeefProj.toml`, registered
in `BeefSpace.toml`) come from the same menu.

The New Class dialog can also set a parent: **Derived from** lists the project's classes and the
libraries' (corlib, a node library...), **Interfaces** adds interfaces, and **Implement missing
members** writes a stub (a graph) for every abstract or interface member the class has to provide.
**Template > Node Library** makes a static class whose functions and variables are global.

## Type settings, overrides and interfaces

* Click **Type Settings** at the top of the class in Outline (or the toolbar button). Properties
  then shows the class itself: parent class, interfaces, access, `static` / `abstract` / `sealed`,
  attributes such as `[AlwaysInclude]`, generic parameters. Every change rewrites just that part of
  the declaration and is one undo step.
* **Override a parent function** (the Override dropdown): FUNCTIONS > **Override** lists the
  parents' virtual and abstract functions and the interfaces' members. Pick `Tick`: VisualBeef writes
  `public override void Tick(float DeltaSeconds)` with a call to the parent (`base.Tick(...)`, a
  **Base** node wired into the call's Receiver) and opens its graph, drawn with a red entry like
  override entries.
* **Implement an interface**: Type Settings > Interfaces > **Add Interface**, then **Implement
  Missing Members**. Until they are implemented the class shows a red *problems* row with the
  missing members by name.
* **Rename** a class, function or variable from Properties or Outline: a preview lists every
  reference in the project that will change; nothing changes if one cannot be renamed safely (the
  Output Log says which line and why). See [Classes-and-Members.md](Classes-and-Members.md).

## Build a graph

1. In **Outline**, click the **+** next to **FUNCTIONS**. Name it `Hello`, return type `void`.
   A graph tab `Greeter.Hello` opens with a purple **entry** node.
2. **Right-click** empty canvas. The node menu ("All nodes for this Sheet") opens; type
   `WriteLine` to filter and pick `Console.WriteLine`. The node appears at the cursor.
3. **Drag from the white flow pin** of the entry node to the white flow pin of the new node.
4. Type `"Hello"` (with quotes) into the node's string pin.
5. Optional: drag off a pin into empty space instead of right-clicking. The menu then offers only
   what fits that pin, and the new node is wired up for you.

Every step is one undo step (**Ctrl+Z**). Behind the scenes each edit rewrites only the changed
statements of that method.

## Compile

Press **F7** (or the toolbar **Compile**). The editor saves your modified files, then runs BeefBuild on
the nearest `BeefSpace.toml`. The toolbar badge shows the state (yellow `?` not compiled, spinning
blue compiling, green good, yellow warnings, red errors). Errors land on the node whose code they
come from (red border and banner; warnings in yellow), in **Problems**, and in the **Output Log**;
click one to jump to it. The dropdown next to **Compile** picks Debug or Release (the default
can come from the project's `.vbproject`, for a project made from a template).

## Read the Beef it wrote

* **Beef Source** tab (bottom dock): *Function* shows the live code of the open graph. *File* shows
  the whole file; edit it and press **Apply** (Ctrl+Enter) to rebuild the graphs from your text.
* Or open `Greeter.bf` in any editor after **Ctrl+S**. After the steps above it contains
  roughly:

```beef
public void Hello()
{
	Console.WriteLine("Hello");
}
```

Nothing else in the file changed. No other file is touched except the optional `Greeter.bf.vblayout`
(node positions), which VisualBeef writes only once you move something, and `Greeter.bf.bak`, which
keeps the content before the last save.

If the generator cannot write a graph safely (a value that would be evaluated twice, two paths
that would duplicate code, a read outside its scope, ...), nothing is written. The nodes at fault get
a red border and the message says why.

## Shortcuts

Consolidated from [Editor-UI.md](Editor-UI.md), which is the authority.

| Keys | Does |
|---|---|
| **F7** | Compile |
| **Ctrl+S** / **Ctrl+Shift+S** | Save / Save All |
| **Ctrl+O** | Open file |
| **Ctrl+B** | Browse to the current asset in the Project Browser |
| **Ctrl+Shift+F** | Find in Sheets (project-wide) |
| **Ctrl+F** | Find in the current graph |
| **Ctrl+Space** | Project Drawer |
| **Ctrl+Z** / **Ctrl+Y** (or Ctrl+Shift+Z) | Undo / redo |
| **Ctrl+C / Ctrl+V / Ctrl+D**, **Del** | Copy, paste, duplicate, delete |
| **Ctrl+A** | Select all nodes |
| **Ctrl+Enter** (in Beef Source) | Apply the edited text to the graphs |
| **Shift+W / Shift+S** | Align top / bottom |
| **Shift+A / Shift+D** | Align left / right |
| **Alt+Shift+W / Alt+Shift+S** | Align middle / center |
| **Alt+Shift+H / Alt+Shift+V** | Distribute horizontally / vertically |
| **Q** | Straighten connection(s) |
| **M** | Toggle the minimap |
| **Ctrl+1..9** / **1..9** | Save the view / jump to saved view n |
| **C** | Comment box around the selection |
| **F** / **Home** | Frame selection / entry node |
| **Letter+click** (B Branch, S Sequence, R Return, P Print, ...) | Place that node at the click; the same letter while dragging a wire places it connected to the pin ([node hotkeys](Editor-UI.md#node-hotkeys-and-favorites)) |
| **Alt+click** a pin or wire | Break links |
| **Ctrl+drag** a connected pin | Move its wires to another pin |
| **Double-click** a wire | Add a reroute knot |
| **Double-click** a call node | Open that function's graph (any file in the project) |
| Mouse wheel; **right-drag** or middle-drag | Zoom around the cursor; pan |
| **Right-click** empty canvas; drag a wire into empty space | Node menu; context-sensitive node menu |
| Drag a variable into the graph | Get / Set menu (**Ctrl** = Get, **Alt** = Set) |
| Project Browser: **F2**, **Del**, **Enter**, **F5** | Rename, delete, open, refresh |

The automated screenshot runs used for verification cannot deliver keyboard messages to SDL, so
the shortcuts above were exercised by hand; their menu and toolbar equivalents were scripted.

## Where settings and caches go

| What | Where |
|---|---|
| Editor Preferences, last project, open tabs, compile configuration per workspace | `%LOCALAPPDATA%\VisualBeef\settings.json` |
| Dock layout | `%LOCALAPPDATA%\VisualBeef\layout.ini` (**Window > Reset Layout** restores the default) |
| Session logs, crash reports | `%LOCALAPPDATA%\VisualBeef\logs` (**Build > Open Logs Folder**) |
| Unsaved changes after a crash | `%LOCALAPPDATA%\VisualBeef\recovery` (offered back on the next start) |
| Library index cache (corlib, BeefLibs, workspace libraries) | `%LOCALAPPDATA%\VisualBeef\index` (safe to delete) |
| Favorite nodes and node hotkeys | `settings.json` (`editor.favorites`, `editor.nodeHotkeys`) |
| Recent nodes | `%LOCALAPPDATA%\VisualBeef\node_menu.txt` |
| Downloaded updates, the previous version, the update log ([Updating.md](Updating.md)) | `%LOCALAPPDATA%\VisualBeef\update` |

## Next

* What every panel does: [Editor-UI.md](Editor-UI.md).
* Choosing which of *your* functions become nodes: [Node-Attributes.md](Node-Attributes.md).
* What is written to disk and when: [Files-and-Safety.md](Files-and-Safety.md).
* Switch, Do Once, Gate and friends: [Flow-Nodes.md](Flow-Nodes.md).
