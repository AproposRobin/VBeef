---
audience: user
title: Editor interface
summary: The panels, the Project Browser, the compile status, the shortcuts and the node hotkeys.
order: 2
---

# VisualBeef editor UI

How the editor shell is put together, what every panel does, every shortcut, and how to
extend it. The goal is that someone who has used a node-graph code editor feels at
home: a familiar layout, colours and shortcuts, with VisualBeef's own words.

## Layout

```
 Menu row:  logo | File Edit Graph Build Debug Window Help ................ project badge
 Toolbar:   Compile [Release v] | Debug (Pause Stop Steps) | Save  SaveAll  Browse | Find | Arrange  Align  Minimap  Snap | Prefs ... asset
 Notice:    VisualBeef 0.2.0 is available. ................... Update  Release notes  Later   (only while there is one)
 +-------------+-----------------------------------------------+---------------+
 | Outline|  graph tabs (one per open function / enum)     |   Properties     |
 |  search     |                                               |  property grid|
 |  class      |              node canvas            [minimap] |               |
 |  FUNCTIONS +|                                               |               |
 |  VARIABLES ++-----------------------------------------------+               |
 |             | Project Browser | Output Log | Problems | Find Results | Beef Source |
 +-------------+-----------------------------------------------+---------------+
 Status bar: Project Drawer  Output Log  [indexing progress x]  last message .... compile state   save state
```

**Lists on the left, properties on the right.** The left column (the Outline) holds the lists of things: the
type's functions and variables and, under the function whose Sheet is in front, its **LOCAL
VARIABLES**, each section with its **+** and rows that can be selected and dragged onto the
Sheet. The right column (Properties) holds only the properties of the current selection: a node,
a function (its Inputs and Outputs belong to the function), a variable or a local
variable. A new panel follows the same rule.

All panels dock (drag a tab to move it; **Window > Reset Layout** restores the default).
ImGui's dock-node menu triangle and node close buttons are hidden; the graph area's own dock
tab hides itself while nothing else is docked with it, so the function tabs act as the
document tabs.

| Panel | What it does |
|---|---|
| **Toolbar** | **Type Settings** (the class being edited, in Properties); **Compile** (F7) with a state badge (see [Compile status](#compile-status)): grey `?` not compiled, yellow `?` needs compile, spinning blue while compiling, green tick up to date, yellow triangle up to date with warnings, red cross errors. Next to it the **configuration dropdown** (`Debug` / `Release`, see [Compile configuration](#compile-configuration-and-problems)). **Save** (dot when the file is unsaved), **Save All**, **Browse** (Ctrl+B: show the asset in the Project Browser), **Find** (Ctrl+Shift+F), **Arrange** (layered auto-arrange), **Align** (menu), minimap and snap toggles, **Editor Preferences**. The open asset's name sits on the right. |
| **Outline** | Search box, the class header (kind icon, kind on the right), a **Type Settings** row (and a red *N problems* row when the class misses members), **FUNCTIONS** and **VARIABLES** category bars with a count and a **+** button. FUNCTIONS has an **Override (N)** dropdown; its **+** offers Function, Override, Constructor, Static Constructor, Destructor, Property, Indexer. Functions show their parameters dimmed, overrides a red event icon, constructors / destructors their kind; variables show a type-coloured pill and their type, properties and indexers their `get` / `set` graphs. Click to open / select, drag into the graph (Ctrl = Get, Alt = Set), right-click to rename (every reference, with a preview), change type or delete. Under the function whose Sheet is in front, a **LOCAL VARIABLES** section (count, **+**) lists its local variables in declaration order with the same pill and dim type: click selects (Properties shows it), double-click or F2 in the context menu edits the name in place, drag places a Get / Set, the context menu has Rename, Move Up / Down and Delete. See [Classes-and-Members.md](Classes-and-Members.md). |
| **Properties** | A two-column property grid (name / value) with collapsible category bars. Node: kind-specific fields, then **Inputs** with a widget per pin type (checkbox for bool, numeric drag for int / float literals, enum combo for project enums, text otherwise), **Connected Inputs**, **Comment**, **Source**. Call nodes: a **Call** category (static / member / unresolved, "Receiver is", each out variable's spelling, the node's error or warning). Function: **Graph** (name, access, static, inheritance virtual / override / abstract / new, mut, *Overrides*, **Add Override**), **Attributes**, **Inputs** (one row per parameter: name + **Passing** chooser (value / out / ref / in, only what Beef takes for that row: a parameter with a default value is passed by value) + type picker + remove, **Add Input**), **Outputs** (the **Return Value** type picker, then one row per further output: name, type picker, move up / down, remove, **Add Output**; each further output is an `out` parameter, and the read-only Beef header is shown under the rows). Local variable (selected in the Outline): **Variable Name**, **Variable Type**, **Ownership** for class types (Reference, or **Made for this call** with its Arguments / Initial Text), **Initial Value** (the member variable controls), the declaration line, **Delete Local Variable**. A Local Variable node read from the middle of a function shows **Move to Local Variables** with a note (see [Classes-and-Members.md](Classes-and-Members.md#local-variables)). The **Add Function** dialog uses the same controls: Name, a Return Type picker and Inputs rows (name, Passing, type picker, remove, Add Input); no parameter text is typed. Variable: name, type picker, access, storage (static / const / readonly), default value, get / set graphs, owner, attributes, delete. **Type Settings** (the type itself selected): problems, name, kind, parent class, namespace, interfaces, Implement Missing Members, Override, modifiers, attributes, generics, enum values, add constructors / destructor. Renames (class, function, variable, parameter, local) rename every reference in the project after a **Rename References** preview. Several nodes: the selection list and alignment buttons. |
| **Project Browser** | Folder tree + tiles. **Filters** (asset kinds, Unsaved, Changed in the last 24 hours) with removable chips. **Drag a tile onto a folder** (tile or tree) to move it. Double-click opens, F2 renames, Del deletes. |
| **Output Log** | Every editor message and BeefBuild's output as it streams (including the exact BeefBuild command line); GraphValidator's errors and warnings (category `Graph`) after each edit and when a graph is first shown. Search, severity toggles (Messages / Warnings / Errors / Verbose), category filter, **Copy** (visible lines) and **Clear**. Compiler messages with a location: double-click to open the node. Every line is also written to the session log file (see [Logs, crashes, recovery](#logs-crash-reports-recovery-settings)). |
| **Problems** | (Was "Compiler Results"; same dock slot.) The last compile: summary with the state icon and configuration, a table of errors and warnings (icon, message, **where**: `Class.Method` when the line belongs to a graph node, `(document) Class` for fields, signatures outside graphs and other declarations, and file:line:col), error / warning filters. Click a row to open the graph with the node selected. |
| **Find Results** | Find in Sheets: searches the whole project for type, function and variable names and for every statement inside function bodies (node titles, pin values, literals). Words match in any order. Results are grouped by file; click one to open the graph with that node selected. |
| **Beef Source** | The function's live code and the editable file text (unchanged from before). |
| **Locals**, **Call Stack** (with Properties), **Debug Output** (bottom) | The debugger's panels: variables of the selected frame (expandable), the frames (double-click opens the Sheet at the node), the program's console output. See [Debugging.md](Debugging.md). |
| **Debug toolbar** | After the configuration dropdown: **Debug** / **Continue** (F5), then while debugging Pause, Stop (Shift+F5), Step Over (F10), Step Into (F11), Step Out (Shift+F11). |
| **Status bar** | **Project Drawer** and **Output Log** buttons (bottom-left), the background indexing progress (phase, bar, **x** to cancel) while it runs, the debugger state ("Running", "Stopped at Greeter.Hello", "Not debugging"), the latest message, compile state and "All Saved" / "N Unsaved" (bottom-right). |
| **Toasts** | Bottom-right notifications, coloured by severity, auto-dismiss (4 s info, 6 s warning, 8 s error), hover to keep, click to dismiss, repeats collapse into "(x2)". |
| **Update notice** | A line under the toolbar, only while a new version is available, downloading (progress, **Cancel**), downloaded (**Restart to finish**) or refused (the reason, **Dismiss**); **Update**, **Release notes**, **Later**. **Help > Check for Updates...** checks at once. See [Updating.md](Updating.md). |
| **Editor Preferences** | Edit > Editor Preferences or the toolbar gear. Appearance (theme, font size, display scale, notifications), Graph Editor (snap to grid, minimap, idle frame pacing), Saving (autosave interval, off by default; recovery journal interval, 30 s by default; the recovery and logs folders), Build (BeefBuild path and whether it was found; default compile configuration), Node Hotkeys, Updates (the version, **Check at Start**, **Channel** Stable / Preview, the last result, **Check Now**, **Open Release Page**). Stored in `%LOCALAPPDATA%\VisualBeef\settings.json`. |

The window title follows the active tab: `VisualBeef - <Project> - <Class> *`.

## Compile status

The Compile button (badge and tooltip) and the status bar show whether the project is compiled, and
the Problems panel uses the same colours.

| State | Colour | Text | When |
|---|---|---|---|
| Not compiled | grey | "Not compiled" | There is no record of a compile for this workspace |
| Up to date | green check | "Up to date" (triangle, "Up to date, with warnings") | The sources match the last successful compile |
| Needs compile | yellow `?` | "Needs compile" | Any unsaved edit, a saved change, or another configuration since the last compile |
| Compiling | blue | "Compiling..." | BeefBuild is running |
| Failed | red cross | "Compile failed (N errors)" | The last compile failed and the sources are unchanged since |

After each compile the editor stores, per workspace, a record in `settings.json`
(`projects.<folder>.compile`: result, configuration, time, error and warning counts) with a content
hash of every `.bf` and project `.toml` file under the workspace folder (`build/` and dot folders
skipped; relative names count). On the next start the same hash is taken and compared, so a project
that was compiled and not touched opens green, and one changed outside the editor opens yellow. The
hash is retaken after a save and at most every three seconds otherwise. A damaged record is ignored.
The logic is `CompileRecord` (Core, tested by `safety` group 17).

## Working on a whole project

Use **File > Open Project Folder...** (the standard Windows folder picker) and pick the
folder that holds your projects, e.g. `<project folder>`. Every `.bf` file under it is indexed
(build output, `recovery` and dot-folders are skipped).

### Project Browser

Docked at the bottom (**Ctrl+Space** also opens it as a drawer).

- The left side is the folder tree. The right side shows the current folder's subfolders and
  **one tile per class, struct, enum and interface**, even when a file holds several. Global
  `static { }` blocks show up as a "Global functions" tile.
- **+ Add** or right-click: New Folder, New Class, New Struct, New Enum, New Interface,
  New Beef File, New Project. A new type gets its own file (`Player.bf`) with the namespace
  its neighbours use. The dialog also takes a **Template** (Empty class, or the UMP mod
  `ModMain : UMPMod` with Initialize / Tick / Shutdown), **Derived from** (project and library
  types), **Interfaces** and **Implement missing members** (stubs for abstract and interface
  members); enums take an underlying type.
- **Double-click** a folder to enter it, a class or struct to open it in the graph
  editor, an enum to open the Enum editor.
- **F2** renames (every reference in the project, after a preview; a type's file is renamed with
  it when it only holds that type), **Del**
  deletes after a confirmation (to the Recycle Bin on Windows, the Trash on Linux). Search filters the whole
  project. Files changed outside VisualBeef are picked up automatically.

### New projects

**File > New Project...** (or **+ Add > New Project**) creates `Name/BeefProj.toml` and
`Name/src/Program.bf` (console app, library or Windows app) and registers the project in the
workspace's `BeefSpace.toml`, creating one if there isn't one yet. Compile and the Beef IDE
see it straight away.

### Many files at once

- Graph tabs from different files sit side by side; the tab you're on decides which file
  Outline, Properties and Beef Source show.
- Calls know about the whole project: real parameter names, pin types and return types.
  Static functions, global functions and fields from anywhere in the project are in the
  node menu, and instance methods appear as "Receiver is *Type*" calls.
- **Double-click a call** to jump to that function's graph, in whatever file it lives.
- Unsaved files are marked with `*`. **Ctrl+S** saves the current file, **Ctrl+Shift+S**
  saves them all, and quitting lists every unsaved file.
- **Compile (F7)** saves all open files first, and errors land on the right nodes.

See [Files-and-Safety.md](Files-and-Safety.md) for what is written when, atomic saves and
backups, conflict handling, read-only (`--view`) mode and undo semantics.

### Background indexing

Opening a folder never blocks the editor. The window is up in about 0.2 s and the project and
its libraries are indexed on a worker thread (`IndexJob`):

- The status bar shows the phase and a progress bar ("Indexing project (120/266)", "Loading
  libraries (2/4)"). The **x** next to it cancels; Project Browser **F5** indexes again.
- While it runs, everything works: open files and graphs, edit, save, compile. The Content
  Browser shows the folders at once and the asset tiles when the project index arrives;
  pins show their types and the node menu offers library nodes once the libraries arrive.
- When it finishes, graphs of open files that you have not touched yet (no edit, no undo
  history, no moved node) are rebuilt so their pins get their types. Edited files keep their
  graphs as they are.
- Generated SDKs inside the folder (`Sdks\ScreechSDK`, `Sdks\HogwartsLegacySDK` in the UMP
  repository) are loaded as cached libraries, not parsed as project files. Opening
  `<UnrealUMP>`: first time ever 11 s in the background (both SDKs are parsed in
  parallel and cached), every later open 0.4 s; it was 15-16 s on the UI thread, every time.
- Rescans of the same folder (after creating, renaming, deleting files, or when the Content
  Browser notices a change on disk) are synchronous but incremental: only files whose size or
  time changed are parsed (85 ms for the 266 UMP files when nothing changed).
- The Output Log (category `Index`) records each run: files, time, libraries, cache hits.
- The **node menu's catalog is built on the indexer too** (`NodeCatalog.Prebuild` right after the
  libraries load). The UI thread only adopts it (renumbering categories: 2.0 ms for Screech's
  75,208 entries, 3.8 ms for Hogwarts' 162,080, instead of 123 / 445 ms on the first menu open)
  and warms the category tree right away (7 / 21 ms, was 470 / 1,116 ms: children are looked up by
  name). The log line "Node catalog: ... built on the indexer in N ms; adopted in ..." shows it.
- **Search in the node menu** waits until typing pauses for 80 ms (Enter, an emptied box and the
  first frame filter at once; the idle loop wakes for it), and a query that only adds characters
  searches the previous matches with their word scores reused: typing "get actor location" key by
  key costs 228 ms in all on Screech (worst key 27 ms) and 508 ms on Hogwarts (worst 60 ms), was
  485 / 1,101 ms (Debug build). Measured with `VisualBeefTests catalog-scale`.

### Find References, overloads, `#if` twins

- **Find References** (**Shift+F12**, Edit menu): every use in the project of the symbol under the
  cursor: the selected node (a variable or member read or written, a call, a construct's type, a
  local, the function's entry) or the variable / type selected in the Outline. It uses the
  project-wide rename's resolution (`RenameService.FindReferences`): results in the Find Results
  panel by file and line ("References to Player.mHealth: 6 in 2 files"), a click opens the
  graph at that line; occurrences that cannot be told apart are listed as "maybe". Libraries are
  not searched. Capture: [find-references.png](images/find-references.png).
- **Overloads**: a call whose overloads fit the arguments equally well (an `int8` passed to
  `Show(int)` and `Show(float)`) keeps its warning, which now lists the candidates, and Properties
  has an **Overloads** section: picking one puts a Cast to that overload's parameter type on the
  argument(s) that tell them apart and renames / retypes the argument pins (`Show((float)small)`),
  in one undo step. Beef has no syntax to name an overload, so a cast is how the choice is written;
  when only `out` / `ref` differ the pick is refused with the reason and the warning stays.
- **Methods in `#if` / `#else` arms** with the same signature are two functions in the Outline,
  each with its arm (`Report()  [else BF_X, inactive]`, the inactive one dimmed, the condition in
  the tooltip); the Entry node's subtitle shows the arm.
- **Lambda** nodes list their captures in the subtitle and in Properties, with the allocation,
  the parameters and the capture list (`[&]`) as editors; Local Function, Format Text and Scope
  nodes have their own Properties rows. Capture: [lambda-properties.png](images/lambda-properties.png).

### Compile configuration and Problems

**Compile** builds the workspace (`BeefSpace.toml`) of the current file with
`BeefBuild -workspace="<dir>" -config=<Debug|Release> -platform=Win64`. The exact command is
written to the Output Log before the build output.

The configuration is chosen with the dropdown next to **Compile** (or **Build >
Configuration**) and remembered per workspace. Without a choice it is:

1. the Editor Preferences default (Build > Default Configuration), when it is not Automatic;
2. **Release** for a UMP mod (a `ModConfig.json` beside `BeefSpace.toml`): the game cannot load
   a Debug mod (it imports `Beef042Dbg64.dll`), and the mod template copies its DLL into the
   game's mod folder in Release only;
3. the Beef IDE's last configuration (`LastConfig` in `BeefSpace_User.toml`);
4. Debug.

The tooltip of the dropdown says which rule applied.

**Errors and warnings on nodes.** BeefBuild's messages are parsed (`BuildOutput.Parse`:
`ERROR: ... at line L:C in <file>`, `WARNING: ...`, and the `file(L,C): error` /
`file:L:C: error` forms) and mapped to the node that owns the line (`DiagnosticMap`):

- the graphable method whose span holds the line, then the smallest node whose source lines
  hold it (a statement wins over a pure node of the same size); a line on the signature or a
  brace goes to the function's entry node;
- the badge follows **that node**, until the next compile: while the Sheet is the one the
  message was mapped to, by the node itself (a node edited in the graph keeps its message; nodes
  inserted before it do not take it); in a Sheet built again (the file reopened, an undo step) by
  its **content-keyed layout key** (`path#hash`, the same key the `.vblayout` sidecar uses): the
  same statement, also when lines were inserted above it. A different statement that now sits at
  the place of a deleted one is never taken for it: **a deleted node's message goes nowhere** (no
  new or neighbouring node shows it), and its Problems row shows a dimmed bin icon instead of the
  Sheet icon (tooltip: the node was deleted since the compile);
- errors get a red **ERROR!** banner under the node, warnings a yellow **WARNING!** banner
  (a node with both shows the error);
- a line outside every graph (a field initialiser, a type declaration) is listed at
  **document level** in Problems, named by its type; files that are not open are loaded just
  for the mapping.

Click a row in **Problems** (or double-click a compiler line in the Output Log) to open the
graph with the node selected and centred. A line in no graph (a member variable, a declaration)
opens **Beef Source > File** scrolled to that line; a line in a member the editor could not read
opens that member's red read-only node.

Problems also lists, without a compile, every member of the project the editor cannot use as
written (see [Files-and-Safety.md](Files-and-Safety.md#unparsed-members-are-kept)): the name
(`Program.Main`, or `unparsed member at line N`), the message and file:line. The Outline shows the
same members in red.

### Logs, crash reports, recovery, settings

Everything per user lives in `%LOCALAPPDATA%\VisualBeef\` (or `%VB_HOME%` when that
environment variable is set; nothing is written to the working directory or the project):

| Path | What |
|---|---|
| `settings.json` | Editor Preferences, node hotkeys and favorites (`editor.nodeHotkeys`, `editor.favorites`), the last session (folder, open tabs, Project Browser folder and tile size, layout version), the BeefBuild path, per-workspace choices (compile configuration). Written atomically. The old `%APPDATA%\VisualBeef\EditorPreferences.ini` and `VisualBeef_settings.txt` in the working directory are read once to migrate and no longer written. |
| `layout.ini` | The ImGui dock layout (was `VisualBeef_layout.ini` in the working directory; copied over once). |
| `logs\visualbeef-<date>.log` | The session log: every Output Log line of every session that day, with a header per session (time, pid, exe). Written unbuffered, so the lines before a crash are on disk. The 30 newest are kept. |
| `logs\visualbeef-crash-<date>-<time>.log` + `.dmp` | A crash report and a minidump (see below). |
| `recovery\<pid>-<start>\` | The recovery journal of a running session (see [Files-and-Safety.md](Files-and-Safety.md#recovery-journal-and-crash-recovery)). |
| `index\` | Library symbol caches. |
| `node_menu.txt` | Node menu recents (favorites and node hotkeys are in `settings.json`, see [Node hotkeys and favorites](#node-hotkeys-and-favorites)). |

**Crash handler** (`CrashHandler.bf`): an unhandled-exception filter (chained to the Beef
runtime's own crash dialog, which still appears) and a Beef runtime error handler
(`Runtime.FatalError`, failed asserts, a discarded `Result` error). On a crash it writes:

- the report: time, process and thread, exception code and name, the faulting address as
  `module+RVA`, for access violations the read / write address, all registers, and a
  best-effort stack (unwound with `RtlVirtualUnwind`, each frame as `module+RVA`);
- the recovery journal of every unsaved document (`Recovery.CrashFlush`);
- a minidump (`MiniDumpWriteDump` from `dbghelp.dll`, thread info + indirectly referenced
  memory), next to the report;
- a `[CRASH] report written: ...` line in the session log.

The crash path uses only stack buffers and raw Win32 calls, so it works on any thread
(including non-Beef threads) with a damaged heap. A 64 KB stack guarantee leaves room for it
after a stack overflow on the UI thread.

Test it with the hidden switch `VB_DEBUG_CRASH_TEST`: `1` (access violation on the UI thread,
45 frames after start), `thread` (on a worker thread), `fatal` (`Runtime.FatalError`);
append `dirty` (`dirty`, `fatal-dirty`, ...) to make the open document unsaved first, so the
recovery prompt has something to offer on the next start.

**Recovery prompt.** When a previous session crashed or was killed with unsaved changes, the
next start asks **Recover unsaved changes?** with the list of files and the time of their
journal entry: **Recover** opens each file with the recovered text as an unsaved change (undo
goes back to the disk version), **Discard** deletes the journal, **Decide Later** keeps it for
the next start.


### Node menu categories: the tree rule

The Node menu is a tree keyed by the full category path. A namespace segment is ONE row per parent: everything under
`System` is one **System** row whose children are `System | IO`, `System | Collections`, and so on, whichever source
(corlib, an SDK, the project) or search rank brought them in. The same name under another parent is another row
(`MyMod | IO` lives under `MyMod`, never merged with `System | IO`). A row can hold items and children at once (a
namespace that is also a category of its own). Each row's ImGui ID is its full path and each item row has its own ID
scope, so hovering never reports a conflicting ID. Search results show the same tree.
`VB_SELFTEST=ids` checks that every row ID in a frame is distinct (`MergedCategory` is tested in `catalog`).

## Shortcuts

| Keys | Does |
|---|---|
| **F7** | Compile |
| **F5** / **Shift+F5** | Start Debugging (compile in Debug, run) or Continue / Stop Debugging ([Debugging.md](Debugging.md)) |
| **F9** | Toggle a breakpoint on the selected node(s) (or click the circle on a node's corner) |
| **F10** / **F11** / **Shift+F11** | Step Over / Step Into / Step Out while stopped |
| **Ctrl+S** / **Ctrl+Shift+S** | Save / Save All |
| **Ctrl+O** | Open file |
| **Ctrl+B** | Browse to the current asset in the Project Browser |
| **Ctrl+Shift+F** | Find in Sheets (project-wide) |
| **Ctrl+F** | Find in the current graph |
| **Shift+F12** | Find References of the selected node / Outline item |
| **Ctrl+Space** | Project Drawer |
| **Ctrl+Z** / **Ctrl+Y** (or Ctrl+Shift+Z) | Undo / redo |
| **Ctrl+C / Ctrl+V / Ctrl+D**, **Del** | Copy, paste, duplicate, delete |
| **Ctrl+A** | Select all nodes |
| **Shift+W / Shift+S** | Align top / bottom |
| **Shift+A / Shift+D** | Align left / right |
| **Alt+Shift+W / Alt+Shift+S** | Align middle / center |
| **Alt+Shift+H / Alt+Shift+V** | Distribute horizontally / vertically |
| **Q** | Straighten connection(s) |
| **M** | Toggle the minimap |
| **C** | Comment box around the selection |
| **F** / **Home** | Frame selection / entry node |
| **Ctrl+1..9** / **1..9** | Save the current view / go to saved view n (canvas focused, no text field active) |
| **Letter+click** (B, S, E, O, W, R, L, T, P, N, D) | Place that node at the click ([Node hotkeys](#node-hotkeys-and-favorites)) |
| A node hotkey while dragging a wire | Place that node at the cursor, connected to the pin |
| **Alt+click** a pin or wire | Break links |
| **Double-click** a wire | Add a reroute knot |
| Project Browser: **F2**, **Del**, **Enter**, **F5** | Rename, delete, open, refresh (F5 refreshes while the Project Browser has focus) |

## Node hotkeys and favorites

**Node hotkeys** are plain letters that place a node without opening the Node menu:

- **Hold the letter and click** empty canvas: the node is placed at the click (B + click = a Branch).
- **Press the letter while dragging a wire** from a pin: the node is placed at the cursor and
  connected to that pin, exactly as if it had been chosen in the Node menu opened from that pin
  (the same connect rules: a flow output continues into the node and the node keeps the old
  continuation, a value goes to the input that fits its type, a node dragged from an input lands
  left of it). Releasing the mouse afterwards does nothing more.

They only work while the Sheet has the keyboard: its window is focused and no text field is
being edited, and with no Ctrl, Alt or Shift held (those combinations keep their own meaning).
The letters the Sheet already uses on their own, **C** (comment box), **F** (frame), **L** (add a
local variable to the function: it is selected in the Outline with its name box focused), **M**
(minimap) and **Q** (straighten wires), can never be node hotkeys.

Default keys (seeded on first run, each node also a favorite):

| Key | Node | Node menu entry |
|---|---|---|
| **B** | Branch | Flow Control > Branch |
| **S** | Sequence | Flow Control > Sequence |
| **E** | For Each Loop | Flow Control > For Each Loop (F is Frame) |
| **O** | For Loop | Flow Control > For Loop |
| **W** | While Loop | Flow Control > While Loop |
| **R** | Return | Flow Control > Return |

| **T** | Get a reference to this | Variables > Get a reference to this (not in static functions) |
| **P** | Print | Utilities > Print > Print (Console.WriteLine) |
| **N** | Construct (new .()) | Lifetime > Construct (new .()) |
| **D** | Defer | Lifetime > Defer |

There is no Delay node in VisualBeef (code runs when it is called, not on a timeline), so D is
Defer. A comment box stays on **C** (the Sheet's own key, it wraps the selection or drops one at
the mouse).

**Favorites.** Every row of the Node menu, the Library tree included, has a star on its right:
click it to add the node to **Favorites** or remove it (right-click a row for the same, plus Set /
Change / Clear Hotkey). Favorites are the first group of the menu when nothing is typed, in the
order they were added. A row whose node has a hotkey shows the letter in a small key box before
the star, in every group, so the hints are where the nodes are.

**Giving a favorite a key.** On a favorite's row the key box is the **key-capture control**: click
it, it shows **Press a key**, and a line under the search box says which node is waiting. Then:

- a free letter becomes the node's hotkey (a node has one letter; a new one replaces the old);
- **Esc** clears the node's hotkey (it stays a favorite);
- a letter another node has is refused with the owner named ("B is already the hotkey of
  Branch."), a Sheet letter likewise ("C is taken by the Sheet (Comment box)."), and the control
  keeps waiting;
- a click anywhere else ends the capture.

Removing a favorite also removes its hotkey: a hotkey always belongs to a favorite.

**Where they are kept.** Both are global (the same in every project) in `settings.json`:
`editor.favorites` (an array of node keys) and `editor.nodeHotkeys` (an object, letter -> node
key). A node key is the menu's `Category<TAB>Label`, for example `"B": "Flow Control\tBranch"`. A
library node is found again by its category and label once its library is indexed; a key whose node
a Sheet does not offer (Get a reference to this in a static function) puts a reason in the
status bar instead of placing anything. The favorite lines of an older `node_menu.txt` are moved
to `settings.json` once.

**Editor Preferences > Node Hotkeys** lists every key with its node and a **Clear** button, the
letters the Sheet keeps, the favorites without a key, and **Reset to Defaults** (the default
favorites and keys above; other favorites are removed). Keys are given in the Node menu.

The map itself (`NodeHotkeys` in VisualBeefCore: defaults, conflicts, clearing, favorites owning
their keys) is tested by `VisualBeefTests hotkeys`; the editor path (B + click, P while dragging a
wire from a flow pin, a favorite given a key through the key-capture control, then used) by the
`VB_SELFTEST=session` steps 27-32.

## Pin values

An input pin that nothing is wired to shows the control for its type, inline on the node and as a row in
Properties > Inputs (`PinValue`, `PinValueEditor`; tests: `PinTests.bf` in `flow`, session steps 99-111):

| Pin type | Control | Beef written |
|---|---|---|
| enum | dropdown of the enum's members | `.Member` (read back from `.Member` or `Enum.Member`) |
| `String`, `StringView` | text field, no quotes | `"text"` (escapes for `\`, quotes, line breaks) |
| `bool` | checkbox | `true` / `false` |
| `int`, `uint8`, ..., `float`, `double` | number field; refuses a value the type cannot hold | `5`, `-3`, `1.5f` (float), `2.0` (double) |
| `char8`, `char32` | one-character field | `'x'` |
| class, struct, pointer, function | none (wire it, or use a Construct); `null` / `default` shown dim | |
| not a plain literal | read-only text with a **Custom** badge; edit it as text in Properties | kept as written |

Typing is committed when the field loses focus or Enter is pressed; a refused value (`300` for `uint8`)
turns the frame red while typed, and on commit the value stays as it was and the reason shows in a
toast (`300 does not fit uint8 (0 to 255).`). Receivers and pins of a type the index does
not know stay plain expression text.

## Canvas

- Node headers carry a kind icon (function, branch, loop, return, variable, code, cast).
  Colours: function entry purple-red, calls blue, pure calls green, flow grey, return purple,
  code orange, variable nodes in their type's colour.
- Pins: flow arrow, data circle (filled when linked), **array** pins as a 3x3 grid, **map**
  pins as two squares, **set** pins as braces.
- Calls ([Calls-and-Receivers.md](Calls-and-Receivers.md)): a member call's unconnected **Receiver**
  reads a greyed **this**; a static call has no Receiver pin and the subtitle "Receiver is Console";
  `out` parameters are output pins; the **This** pill ("Get a reference to this" in the node
  menu, first when dragging off a Receiver) writes `this`.
- Lifetime nodes ([Lifetime-Nodes.md](Lifetime-Nodes.md)): **Construct** (box icon, green) with
  the allocation as its subtitle ("scope: freed when the block ends", "new: you delete it",
  "scope::  freed when the method returns"); **Delete** (bin icon, blue) with an *Object* input;
  **Defer** (grey, "runs at the end of the block") with *Deferred* and *Completed*; **Using** (grey,
  "disposed when Body ends") with *Body*, *Completed* and an optional variable pin; **Result: match**
  (grey, subtitle `case .Ok(let v)`) with *Ok*, *Err*, *Completed* and the *Value* / *Error* payload
  pin. A `Try!` call says "returns early on error". The node menu lists them under **Lifetime**
  ("Construct <Type> (scope)" / "(new)" for the type a dragged input wants, for this file's
  classes and structs and for those of the project's other files this file can name: its
  namespace, an enclosing one, a `using`, or none), "Construct (scope .())", "Construct String (scope $"...")", "Construct Array (new T[n])",
  "Delete", "Defer", "Using", "Result: match", "Result: match Err"); dragged off a `Result<T>`
  output, "Result: match" comes first. Properties has a **Lifetime** category: the allocation dropdown
  (new / scope / scope:: / append / custom `new:<allocator>`), type, array toggle and constructor
  arguments of a Construct; the Defer's `defer` / `defer::` / custom label; the Using variable
  (name, type); which case a Result node tests (Ok / Err, which swaps the arms' meaning) and its
  binding; and the node's error or warning.
- Problems on nodes: an error (GraphValidator or the generator) turns the header red, adds a red
  outline and an **ERROR!** badge with the message (a Receiver error also turns the Receiver pin red);
  a warning adds a yellow outline and a **WARNING** badge. The tooltip starts with the message. A
  graph is checked when it is first shown and after every edit.
- **Pin types follow the code**: a type changed anywhere (the Type of a Construct, a local's
  Variable Type, a function's return or parameter types in the same file) reaches every node that
  shows it as soon as the edit is written: the local's pins and header colour, the type after
  `let` / `var` on a Local node (`let (GameBase)`), a call's Return Value, a read of the local.
  Undo restores them.
- **Pin context menu** (right-click a pin): **Break Link(s)**; on a data output **Make variable**
  (a member variable of the type, named after the pin and typed like it, and a Set fed by the pin,
  spliced into the flow after the pin's node) and **Make local variable** (the same into the
  function's local variables, declared at the top of the body); on a data input **Make variable
  (Get)** (a member variable and a Get wired into the pin; it starts at its default) and **Reset
  to Default**. Each is one undo step. An entry is disabled with the reason when the pin's type is
  not one Beef takes there (not known yet, `void`, a generic parameter).
- **Reload Node** (node right-click menu) and **Graph > Reload Sheet** are safety valves for a node
  or Sheet that shows something the function no longer says. Reload Node takes the node's pin types
  and its own messages from the function as it is now (only for a node with nothing unwritten);
  Reload Sheet builds the whole Sheet again (positions and unconnected nodes kept, one undo step).
  Neither should be needed: the Sheets follow every edit by themselves.
- **Arrange** (toolbar / Graph menu) lays the graph out by execution flow: the chain runs
  left to right, each additional flow output (True/False, Loop Body, Completed) stacks its
  chain below the previous one, and the pure nodes feeding a node sit in columns to its
  left, under the flow wire. Undoable.
- **Align** (toolbar menu, Graph > Alignment, Properties for multi-select, or the shortcuts).
  Undoable.
- **Snap to Grid** (toolbar magnet / Preferences): dragged, placed (node menu, hotkeys,
  drops from Outline) and aligned nodes land on the 16-unit grid.
- **Minimap** (toolbar, Window > Graph Minimap, M, or the small x on its corner; remembered in the
  settings): a fixed 180 x 120 px overview (scaled by the display scale, never by the zoom) in the
  bottom-right corner, semi-transparent and opaque under the pointer. Nodes are small rounded blocks in
  their header colour, comment boxes a faint wash, wires are left out. The map is scaled to the graph's
  own extent (a small graph stays small), so panning and zooming move the white view rectangle but never
  rescale the map. Click or drag inside it: the view follows the mouse, clamped to the graph (grab the
  rectangle to keep your grip on it, click outside it to centre on that point). It is not drawn when the
  pane is too small for it, and a popup (Node menu) is never covered by it.
- **Saved views 1-9**: **Ctrl+digit** saves the current pan and zoom of this function under that number
  (toast "View 3 saved"), **digit** alone eases there in about 150 ms (toast "View 3"; an unset number says
  "View 3 is not set (Ctrl+3 saves it)"). Numbered markers show them on the minimap (click one to go
  there). **Window > Saved Views** lists them, jumps, saves and clears (one or all). Kept per function
  in the layout file as `#view<TAB>methodKey<TAB>n<TAB>x<TAB>y<TAB>zoom` (x, y: the grid point in the
  middle of the canvas); files without them load unchanged.
- **Home** (house button in the upper right of the canvas, or **Home**): eases to the entry node at zoom 1,
  or fits the whole graph when the Sheet has no entry node. **Fit all** (the button beside it) fits the
  whole graph; the **F** key (frame the selection, or everything with nothing selected) was already taken.

## Node Library

A fifth asset kind next to Class, Struct, Enum and Interface (amber books icon). Project Browser >
New > **New Node Library...** (or New Class with the Template set to Node Library) writes
`static class Name`; Type Settings > Kind > Node Library converts a class. Its Outline entry shows the kind
"node library" and has Variables and Functions only (no Override list, no constructors). In Properties a
function's **Static** checkbox is on and locked (tooltip: every function in it is static), a variable's
Storage offers Static / Const / Static Readonly, and Add Variable's **Static** checkbox is locked on.
The Project Browser Filters list has a Node Library entry. See
[Classes-and-Members.md](Classes-and-Members.md#node-libraries-and-global-variables).

## Known gaps

- The OS title bar is still drawn by Windows (the menu could move into it later).
- Per-monitor DPI changes are handled in code but were not tested on a second monitor.
- Moving an asset does not rewrite its namespace.
- Keyboard shortcuts could not be exercised by the automated screenshot run (posted key
  messages don't reach SDL without real keyboard focus); their menu / toolbar equivalents
  were.
