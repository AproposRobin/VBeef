---
audience: developer
title: Architecture
summary: How the modules fit together, how one edit travels to the disk and the compiler, and where state lives.
order: 10
---

# Architecture

How VisualBeef is put together: the modules, the types that matter in each file, how one edit
travels from the screen to the disk and into the compiler, which thread does what, where state
lives, and the two most common extensions (a new node kind, a new panel).

Read [README.md](README.md) first for the reading order and [Parsing-and-Layout.md](Parsing-and-Layout.md),
[Codegen.md](Codegen.md) and [Files-and-Safety.md](Files-and-Safety.md) for the rules the pieces
below implement.

## The one invariant

**The `.bf` text is the only source of truth.** A graph is a *view* of one method body, built
from the text by `GraphBuilder`, and written back as text by `CodeGen`. There is no graph file
format. Everything else is a cache or a convenience and can be deleted without losing code:

* the `File.bf.vblayout` **sidecar** holds only what the text cannot: node positions, comment
  boxes, reroute knots and unconnected ("orphan") nodes, keyed by a node's position in the code
  plus a hash of its content (see [Parsing-and-Layout.md](Parsing-and-Layout.md));
* the library index cache under `%LOCALAPPDATA%\VisualBeef\index`;
* editor settings and window layout.

If you ever need to decide where something is stored, ask "can the text express this?". If yes
it goes in the text (a flow macro is plain `if (!__doOnce_1) { ... }` code, not metadata).

## Layers

```
 +--------------------------------------------------------------------------------+
 | Native    vbhost.dll (C++: SDL2 + OpenGL3 + Dear ImGui docking + imnodes)        |
 |           Native/src/*.bf  Beef bindings (cimgui / cimnodes C API)               |
 +--------------------------------------------------------------------------------+
 | Editor    VisualBeefEditor   the app: EditorApp + panels + canvas + shell       |
 |           depends on Core and Native                                             |
 +--------------------------------------------------------------------------------+
 | Core      VisualBeefCore     no UI, no native code: Syntax -> Graph -> Document  |
 |           (+ Catalog: symbols and types without a compiler)                      |
 +--------------------------------------------------------------------------------+
   VisualBeefMeta   attributes your projects reference ([Node], [Pure], ...)
   VisualBeefTests  command-line test runner; depends on Core and Meta only
```

Dependencies point downwards only: Core knows nothing about ImGui or the editor, which is why
the whole round trip is testable from the command line (`VisualBeefTests`). `VisualBeefTests`
does not reference the editor, so nothing in `VisualBeefEditor/` is covered by automated tests
except through Core.

## Module map

### Core: `VisualBeefCore/src/` (namespace `VisualBeef.*`)

**Syntax/** : text to tree, losslessly.

| File | Key types | Role |
|---|---|---|
| `Token.bf` | `TokenKind`, `Token`, `Literals`, `CharUtil` | Token model; literal classification (`1.0` double, `1.0f` float, suffixes, raw strings). |
| `Lexer.bf` | `Lexer` | Keeps every comment, blank line and preprocessor line as trivia, so lexing reproduces the file byte for byte. Nested block comments. |
| `Ast.bf` | `CompilationUnit`, `Member`, `Stmt`, `Expr`, `SwitchCase`, `Param`, `MemberKind`, `StmtKind`, `ExprKind`, `LiteralKind` | The AST. Nodes point back into the token array (`FirstTok`/`LastTok`), so any node's exact text is recoverable. |
| `Parser.bf` | `Parser` | Never fails: unknown code becomes Raw; a damaged member becomes `Member.Kind == .Broken` with its exact text and the parser resumes at the next member. |

**Graph/** : tree to graph and back.

| File | Key types | Role |
|---|---|---|
| `Graph.bf` | `Graph`, `Node`, `Pin`, `Link`, `NodeKind`, `PinKind`, `CallBinding`, `ArgMode`, `OutForm`, `GraphError` | The graph model: flat lists of nodes, pins and links; `Connect`/`Disconnect`; typed connection checks with reasons; how a call binds (`Node.Binding`, `OwnerType`, `Qualifier`), `ref` / out argument pins; `Graph.Errors` / `Graph.Warnings` filled by GraphValidator and CodeGen. |
| `GraphBuilder.bf` | `GraphBuilder` | AST of one method to a `Graph`. Pin typing (`InferType`) through `GraphBuilder.Index` (a `ProjectIndex`) and the installed `TypeService`. Recognises flow-macro shapes. |
| `CodeGen.bf` | `CodeGen`, `CodeStyle` | Graph to method body. Plans the block tree, hoists values, spells and places out variables, refuses unsafe graphs, copies unchanged statements verbatim. Rules in [Codegen.md](Codegen.md). |
| `GraphValidator.bf` | `GraphValidator` | Node-anchored checks before code is written (Receiver / this, required inputs, `ref`, wire types, the graph-only lifetime rules, an `override` with nothing to override, a Base node without this); first step of `CodeGen.GenerateBody`. See [Calls-and-Receivers.md](Calls-and-Receivers.md), [Lifetime-Nodes.md](Lifetime-Nodes.md) and [Classes-and-Members.md](Classes-and-Members.md). |
| `NodeFactory.bf` | `NodeFactory` | The only place nodes and their pins are created (`StaticCall`, `MemberCall`, `This`, `Call`, `Set`, `Branch`, `Loop`, `Switch`, `Flow`, `FromSpec`, ...). Parsed and menu-created nodes go through it, so they are identical. |
| `FlowMacros.bf` | `FlowMacros` | Pin layout, names and field prefixes of Sequence, Do Once, Do N, Flip Flop, Gate, Multi Gate. |
| `Layout.bf` | `KeyAssigner`, `AutoLayout` | Gives nodes their layout key; places nodes that have no saved position. |
| `LayoutKeys.bf` | `LayoutKeys` | Content-keyed layout: `path#hash`, exact / moved / edited matching on load. |

**Document/** : files, projects, undo, safety.

| File | Key types | Role |
|---|---|---|
| `SourceDocument.bf` | `SourceDocument`, `MethodGraph`, `Snapshot`, `OrphanSet` | One open file. Owns the text, the parsed unit, one `MethodGraph` per method, undo/redo snapshots (200 deep), dirty tracking, `Commit`, `ReparseKeeping`, sidecar load/save, conflict fingerprint. |
| `OrphanStore.bf` | `OrphanRecord`, `OrphanCodec` | Unconnected nodes saved in the sidecar as code snippets and rebuilt on load. |
| `LayoutExtras.bf` | `GraphComment`, `GraphReroute`, `LayoutText` | Comment boxes and reroute knots (layout only). |
| `EnumCases.bf` | `EnumCases` | Reading and rewriting an enum's cases for the Enum editor. |
| `ProjectIndex.bf` | `ProjectIndex`, `SymbolType`, `SymbolMethod`, `SymbolField` | Every `.bf` under the open folder: types, methods, fields, namespaces, `using`s, visibility, attributes, `///` docs. `Version` bumps on every change. |
| `AssetOps.bf` | `AssetOps` | Create / rename / move types, files, folders and projects; namespace-aware; never overwrites. |
| `FileSafety.bf` | `FileSafety`, `SaveOutcome` | Atomic saves and `.bak`, conflict detection, Recycle Bin delete, the read-only (viewer) flag. |

**Catalog/** : what the node menu offers and what type a pin has, without a compiler.

| File | Key types | Role |
|---|---|---|
| `SymbolStore.bf` | `SymbolStore`, `TypeRec`, `MemberRec` | Compact symbol table with a binary cache. |
| `LibraryIndex.bf` | `LibraryIndex`, `MiniToml` | Finds a workspace's libraries (`BeefSpace.toml`, `BeefProj.toml`, corlib, BeefLibs) and loads each from the cache or parses it. |
| `AttributeParser.bf` | `AttributeParser`, `AttrInfo`, `DocComment` | Reads `[Node(Category="x")]` and `///` text. |
| `TypeRules.bf` | `TypeRules`, `TypeFamily`, `Conversion` | Normalising type text, literal types, implicit conversions, wildcards, pin colour families. |
| `TypeService.bf` | `TypeService`, `ResolveContext` | Namespace-aware type, member and overload resolution; owns the stores and the `NodeCatalog`. |
| `NodeCatalog.bf` | `NodeCatalog`, `NodeSpec`, `PinSpec`, `CatalogEntry` | The flat list of node entries with fuzzy search, context relevance and the category tree. |

More on the catalog: [Catalog-and-Types.md](Catalog-and-Types.md), attributes: [Node-Attributes.md](Node-Attributes.md).

**Debug/** : running a program under Beef's debugger engine ([Debugging.md](Debugging.md)).

| File | Key types | Role |
|---|---|---|
| `DebugEngine.bf` | `DebugEngine`, `EngineRunState` | Loads `IDEHelper64.dll` (the Beef IDE's debugger) at run time and binds its C API. One engine per process. |
| `DebugSession.bf` | `DebugSession`, `DebugEvent`, `DebugFrame`, `DebugBreakpoint`, `EvalValue` | Launch / attach, run state, events polled from the UI thread, breakpoints by (file, line), steps, frames, locals, evaluation without calls, the program's output (a reader thread per pipe). |
| `DebugMap.bf` | `DebugMap` | Node <-> line (`LineOf`, `NodeAt`) and the expression of a pin (`PinExpr`). |
| `DebugTarget.bf` | `DebugTarget`, `LowPriority` | The startup project's Debug command, arguments and folder (like the IDE); BelowNormal priority for child processes. |

### Editor: `VisualBeefEditor/src/` (namespace `VisualBeef.Editor`)

`EditorApp` is one large class split into many files with `extension EditorApp`. Think of the
extensions as the "controllers" and of the static/instance classes as the "views".

| File | Key types | Role |
|---|---|---|
| `Program.bf` | `Program` | `Main`: preferences, theme, `EditorApp`, and the frame loop (`PaceFrame`, `vbh_begin_frame`, `app.Frame()`, `vbh_end_frame`). |
| `EditorApp.bf` | `EditorApp` | Open documents and tabs, the commit queue, menus, settings, compile, quit flow, `ExecuteMenuEntry` (turns a node-menu choice into nodes), modals. |
| `Shell.bf` | `Panels`, `CompileState`, `EditorApp` ext. | Panel names and ids, dockspace, toolbar, status bar, `WantsContinuousFrames`. |
| `GraphPanel.bf` | `GraphPanel`, `GraphTab`, `NodeLay`, `PinLay` | The node canvas, drawn with `ImDrawList` (not imnodes): layout, hover, draw, input, comment boxes, reroutes, in-graph find. |
| `Canvas.bf`, `Theme.bf`, `PinStyle.bf` | `Canvas`, `Theme`, `PinStyle` | Splines, grid, zoom table, snap; node header colours; pin colours, shapes and header icons. |
| `GraphTools.bf` | `LayeredArrange`, `AlignMode` | Arrange, align, distribute, straighten; also used to place the companion nodes one menu entry spawns. |
| `Minimap.bf` | `GraphPanel` ext. | Minimap. |
| `NodeMenu.bf` | `NodeMenu`, `NodeItem`, `MenuEntryKind`, `NodeMenuPrefs` | The right-click / drag-off-pin menu: built-in entries, catalog entries, context filter, favourites and recents. |
| `Outline.bf` | `EditorApp` ext. | Outline panel. |
| `PropertiesPanel.bf`, `PropertyGrid.bf`, `TypePicker.bf` | `PropertyGrid`, `ParamRow` | Properties panel on the property grid; the searchable type picker. |
| `ProjectBrowser.bf`, `CBExtras.bf` | `CBItem`, `CBDir`, `AssetKind`, `AssetStyle` | Folder tree, one tile per type, create / rename / move / delete, filters, polling for external changes. |
| `AssetEditors.bf` | `AssetTab`, `AssetRow` | Enum editor and type overview tabs. |
| `FindPanel.bf` | `FindHit` | Find in Sheets (project-wide). |
| `OutputLog.bf`, `Notify.bf` | `Notify`, `LogEntry`, `LogLevel` | Output Log and Problems; the thread-safe log and toast API (mirrored into the session log). |
| `BuildRunner.bf` | `BuildRunner`, `BuildMessage` | Runs BeefBuild as a child process, parses its output into messages. |
| `Debugger.bf`, `DebugCanvas.bf`, `DebugPanels.bf` | `EditorBreakpoint`, `EditorApp` / `GraphPanel` ext. | Breakpoints on nodes, Start Debugging, the stopped node and pin values on the canvas, Locals / Call Stack / Debug Output. |
| `Style.bf`, `Icons.bf`, `Prefs.bf`, `TitleBar.bf`, `Desktop.bf` | `Look`, `Icon`, `Prefs`, `Desktop` | Theme and metrics; Lucide glyph constants; preferences; project badge; window handle, DPI and idle wait. |

### Native: `Native/`

| Path | Role |
|---|---|
| `host/vbhost.cpp` | The C++ host: SDL2 window, OpenGL3, Dear ImGui (docking), imnodes, native file dialogs. Exports `vbh_*` functions (`vbh_init`, `vbh_begin_frame`, `vbh_end_frame`, `vbh_poll_drop`, ...). |
| `src/ImGui.bf`, `ImGuiShell.bf`, `ImNodes.bf` | Beef bindings: `Gui` (cimgui), extra style / IO / font / table bindings, `Host` (the `vbh_*` exports). |
| `bin/win64/vbhost.dll`, `vbhost.lib` | Prebuilt host; SDL2 is linked in statically. `CopyToDependents` puts the DLL next to every dependent exe. |
| `build_windows.ps1` (llvm-mingw, PowerShell), `build_windows_mingw.sh`, `build_linux.sh` | Rebuild the host (only needed when `vbhost.cpp` or the vendored libraries change). |
| `third_party/` | Dear ImGui, cimgui, imnodes, cimnodes. See `../THIRD_PARTY.md`. |

### Meta and Tests

`VisualBeefMeta/src/Attributes.bf` defines the attributes. `VisualBeefTests/` is described in
[Testing.md](Testing.md).

## Data flow: open, graph, edit, commit, save, compile

```
 open folder ──> ProjectIndex.Build ──> TypeService.Sync (project store + library stores)
      │
 open file ───> SourceDocument.Load ─> Lexer ─> Parser ─> CompilationUnit
      │                │                         (+ sidecar .vblayout read if present)
      │                └─> one MethodGraph per method (graph built lazily)
 open tab ────> GraphBuilder.Build(method)   ─> Graph
      │                └─> layout: saved positions by content key, AutoLayout for the rest
      │
 user edits the graph ──> EditorApp.BeginEdit()      push an undo snapshot (whole document)
      │                   mutate Graph (NodeFactory, Connect, ...)
      │                   EditorApp.CommitCurrent()  sets a flag
      │
 end of frame ─────────> EditorApp.DoCommit()
      │                   KeyAssigner.Assign(graph)
      │                   SourceDocument.Commit(mg)
      │                     CodeGen.GenerateBody: GraphValidator, then plan + write
      │                       ── errors? ──> refuse: text untouched, errors on nodes (warnings shown)
      │                     splice body between the braces
      │                     ReparseKeeping: re-parse the whole file, re-attach the SAME Graph objects
      │
 Save (Ctrl+S) ────────> SourceDocument.Save ─> FileSafety: temp file, flush, ReplaceFileW (+ .bak)
      │                   conflict fingerprint checked first; sidecar written only if touched
      │
 Compile (F7) ─────────> SaveAll ─> BuildRunner.Start(BeefBuild -workspace=<nearest BeefSpace.toml>)
                          reader threads queue output ─> main thread parses ERROR lines ─>
                          mapped to the smallest node whose line range contains the line
                          (only shown while document Version == build Version)
```

Notes on each step:

* **Why commit is deferred to the end of the frame.** `ReparseKeeping` replaces the
  `MethodGraph` wrappers while panels may still hold pointers to them. The `Graph` objects
  themselves are kept, so what you placed stays exactly that node ("nodes keep their shape").
  Selection is re-applied by node key after the commit (`GraphTab.ReselectKeys`).
* **Editing the text** (Beef Source panel, **Apply**) goes the other way: `SourceDocument.ApplyText`
  re-parses and rebuilds the graphs from the new text.
* **Undo** is whole-document snapshots (`Snapshot`), 200 deep. Moves, resizes and knot drags are
  one step per drag. Dirty means "text differs from the last saved or loaded text".
* **Nothing is written to disk on open, scroll, select, auto-layout or compile**; see the table
  in [Files-and-Safety.md](Files-and-Safety.md).

## Threading

* **Everything runs on the main (UI) thread**: parsing, indexing, graph building, code
  generation, ImGui. There are no locks around documents or graphs.
* **`BuildRunner`** starts BeefBuild as a child process and two reader threads (stdout, stderr).
  They append lines to a queue guarded by a `Monitor`; the main thread drains it each frame.
* **`Notify`** (`Notify.Info/Warn/Error/Log`) is thread-safe (its own `Monitor`); toasts are drawn
  by the main thread.
* The idle loop (`Desktop.PaceFrame`) blocks the main thread in `MsgWaitForMultipleObjectsEx`
  when nothing is happening; see [Editor-UI.md](Editor-UI.md#idle).

## Where state lives

| State | Where | Lifetime |
|---|---|---|
| Source text, parsed unit, graphs, undo stack, dirty flag | `SourceDocument` (one per open file) held in `EditorApp.mDocs` | Open file |
| Open tabs, selection, pan / zoom | `GraphTab` in `EditorApp.Tabs` | Session (tabs restored from settings) |
| Project symbols | `ProjectIndex` (`EditorApp.Index`, also `GraphBuilder.Index` static) | Open project; built on a worker thread by `IndexJob` on open, then rescanned incrementally on file changes |
| Library symbols, node catalog | `TypeService` | Open project; libraries cached on disk |
| Node positions, comment boxes, reroutes, orphan nodes | `File.bf.vblayout` beside each source | Persistent, optional |
| Library index cache | `%LOCALAPPDATA%\VisualBeef\index\<hash>.bin` | Persistent, safe to delete |
| Editor Preferences, last project folder, open tabs, BeefBuild path, per-workspace compile configuration | `%LOCALAPPDATA%\VisualBeef\settings.json` (`Settings`, `Prefs`) | Persistent |
| Dock layout | `%LOCALAPPDATA%\VisualBeef\layout.ini` (ImGui `io.IniFilename`) | Persistent |
| Session log, crash reports, minidumps | `%LOCALAPPDATA%\VisualBeef\logs\` (`SessionLog`, `CrashHandler`) | Persistent (30 newest kept) |
| Unsaved document text (recovery journal) | `%LOCALAPPDATA%\VisualBeef\recovery\<pid>-<start>\` (`Recovery`) | Until save / clean exit; offered back after a crash |
| Favorite nodes and node hotkeys | `settings.json` `editor.favorites` / `editor.nodeHotkeys` (`NodeMenuPrefs` over `NodeHotkeys` in VisualBeefCore) | Persistent, global |
| Recently used nodes | `%LOCALAPPDATA%\VisualBeef\node_menu.txt` (`NodeMenuPrefs`) | Persistent |
| Log, toasts, build messages | `Notify`, `BuildRunner` | Session |

Nothing is written to the working directory; `VB_HOME` moves the whole per-user folder (tests,
portable installs). See [Editor-UI.md](Editor-UI.md#logs-crash-reports-recovery-settings).

## How to add a node kind, end to end

Worked example: the Switch and Flow nodes (`git show 84d816e --stat` lists every file they
touched). A new kind `Foo` that reads and writes plain Beef needs:

1. **Model** (`Graph.bf`): add `Foo` to `NodeKind`, a title in `Node.GetTitle`, and, if it has
   special state, a field on `Node` (`Text`, `Text2`, `Reason` already exist for kind-specific text).
2. **Create** (`NodeFactory.bf`): `NodeFactory.Foo(g, ...)` creating the pins. All creation goes
   here so the factory test can compare menu-made and parsed nodes.
3. **Read** (`Parser.bf` / `Ast.bf` only if the syntax is new; `GraphBuilder.bf`): recognise the
   code shape and build the node. If the shape is only a *convention* (like `if (!__doOnce_1)`),
   recognise it strictly by shape so look-alike code stays an ordinary node.
4. **Write** (`CodeGen.bf`): emit the code. Obey [Codegen.md](Codegen.md): copy clean statements,
   follow the style of the surrounding code, and add a refusal (a `GraphError` on the node)
   for any wiring you cannot express without changing behaviour.
5. **Menu** (`NodeMenu.bf`): add an `MenuEntryKind` and entries, and the case in
   `EditorApp.ExecuteMenuEntry` that calls the factory. Entries that spawn several nodes should
   place the companions with `LayeredArrange.ArrangeFrom` (see how `.LoopBreak` does it).
6. **Draw** (`GraphPanel.bf`, `Theme.bf`, `PinStyle.bf`): header colour, header icon, any custom body.
7. **Edit** (`PropertiesPanel.bf`): a Properties category for the node's fields, using `PropertyGrid`.
8. **Test**: a `FactoryTests` case (menu-made node survives commit and reads back identical), a
   parse/edit/refusal case in a suite like `FlowTests`, and a `CompileTests` case that builds and
   runs the generated code. See [Testing.md](Testing.md).
9. **Document** it next to [Flow-Nodes.md](Flow-Nodes.md) and add a line to the code-to-node
   table in [Parsing-and-Layout.md](Parsing-and-Layout.md) or the README.

If the node comes from a *library function* rather than from syntax, none of this is needed:
tag the function with `[Node]` (see [Node-Attributes.md](Node-Attributes.md)) and the catalog
makes the node.

## How to add a panel

(Also in [Editor-UI.md](Editor-UI.md#adding-things).)

1. Add a name to `Panels` in `Shell.bf` as `"<icon>  Title###Title"`; the part after `###` is
   the stable id.
2. Draw it from `EditorApp.Frame` with `Gui.Begin(Panels.MyPanel, &mShowMyPanel)` ... `Gui.End()`.
   Put the drawing code in its own file as `extension EditorApp` (see `OutputLog.bf`).
3. Add a **Window** menu item.
4. Dock it in `SetupDockspace` and bump `cLayoutVersion` (`EditorApp.bf`) so saved layouts pick it up.
5. Focus it from elsewhere with `Panels.Focus(Panels.MyPanelId)`.
6. Keep drawing cheap and allocation-free; the panel runs every frame while anything animates
   and once per input otherwise. If it animates by itself, make `WantsContinuousFrames` return true while it does.
7. Report problems through `Notify`, not `SetStatus` alone, so they reach the Output Log.

## Conventions worth knowing

* Beef 0.43.6 quirks that shaped the code: no `[Bitfield]`; `@word` escaping only works for
  parameters and locals; Debug builds import `Beef042Dbg64.dll` (copied next to the exe).
* Files are LF in the repository (`core.autocrlf`); tools that rewrite files should preserve that.
* Warnings are errors in spirit: the tree builds with 0 warnings in Debug and Release.
* UI strings: the VisualBeef vocabulary, see [Vocabulary.md](Vocabulary.md) ("Compile", "Properties", "Outline", "Project Browser").

## Host asserts

The host never shows an assert dialog. A failed assert in the host's C++ (Dear ImGui's `IM_ASSERT`,
SDL's own assertions) calls `vbh_assert_failed` (`Native/host/vbhost.cpp`) instead of `assert()`:

* `Native/third_party/cimgui/imgui/imconfig.h` (a documented local change) defines `IM_ASSERT(e)` as a call to
  `vbh_assert_failed(#e, __FILE__, __LINE__)`. `vbh_init` routes SDL's assertion handler there too.
* `vbh_assert_failed` reports each distinct site (file and line) once per run and returns, so ImGui's
  recovery path continues. It never aborts. The site goes to the handler the editor registers through the
  exported `vbh_set_assert_handler` (`Host.vbh_set_assert_handler` in `Native/src/ImNodes.bf`); with no handler
  it writes one line to stderr.
* The editor's handler (`HostAsserts` in `VisualBeefEditor/src/Program.bf`, registered in `Program.Main` before
  `vbh_init`) logs `[ASSERT] <expr> at <file>:<line>` as an Error in the Output Log and the session log, and
  counts it. Editor test runs count the lines as a failure (`SelfTest.bf`, `done failures=N`; see
  [Testing.md](Testing.md#verifying-the-ui)).
* `build_windows.ps1` and `build_linux.sh` compile with `-DNDEBUG`, so the C library's `assert` is compiled out of
  the third-party code and the only assert left in the host is the routed one.

So misuse of ImGui (an unbalanced ID stack, `End()` without `Begin()`, a style pop with no push) shows up as an
`[ASSERT]` line for a developer, and a user sees nothing. Before this, the shipped DLL had `assert()` live and a
misuse opened the Microsoft Visual C++ Runtime Library dialog in front of the editor.

## Editor: theme

`Style.bf` (`static class Look`) holds the dark palette (Title #151515, Recessed
#1A1A1A, Panel #242424, Header #2F2F2F, Dropdown #383838, Hover #575757, Input #0F0F0F,
Foreground #C0C0C0, Primary #0070E0) and the metrics (rounding, padding, 1 px borders).
`Look.Apply(scale)` writes them into the ImGui style; it starts from an unscaled copy of the
host's style each time, so it can be re-applied at any time (DPI change, font size,
theme). "Darker" darkens the panels. Node-graph colours are in `Theme.bf`; pin and
header colours/shapes go through `PinStyle.bf`, which is the one place to swap when the
node catalog provides its own mapping.

## Editor: icons

`assets/fonts/lucide.ttf` is Lucide 0.460.0 (ISC licence, `assets/fonts/LICENSE-lucide.txt`).
The build copies `assets/` next to the program; `Icon.Load` finds it there (or in the
source tree) and merges the glyphs (U+E000-U+E700) into the UI and mono fonts after the
first frame. Use them in any label: `scope $"{Icon.Save}  Save"`. Constants are in
`Icons.bf` (generated from Lucide's CSS; add more the same way). Without the font file
the editor still runs and shows a warning.

## Editor: DPI and fonts

The editor follows the DPI of the monitor its window is on (`GetDpiForWindow`, checked
twice a second): `Look.Apply` rescales the style and sets ImGui 1.92's `FontScaleDpi`, and the
dynamic font atlas re-rasterises glyphs at the new size. The base font size comes from
Preferences (`FontSizeBase`). Only the host's start-up scale is fixed (fonts are loaded once
by `vbhost.dll`; 1.92 renders them at any size, so this does not blur).

## Editor: idle frame pacing

The frame loop sleeps when nothing happens. `Desktop.PaceFrame` (`Desktop.bf`, called from
`Program.Main`) waits in `MsgWaitForMultipleObjectsEx` until a window message arrives, waking
once a second (twice a second while a text field is active, for the caret) so file watching
still runs. File-change polling is time-based (not frame-based) for this reason.

While the background indexer runs, the wait is at most 100 ms (`IdleTimeoutMs`), so the
progress bar moves and the finished index is taken promptly, without rendering continuously.

It renders **continuously** (no sleeping) while any of these hold (`EditorApp.WantsContinuousFrames`
in `Shell.bf`):

* a build is running, a toast is animating, or a commit is pending;
* a mouse button is held;
* **any ImGui popup is open** (`igIsPopupOpen("", AnyPopupId | AnyPopupLevel)`): the node
  menu, context menus, combo lists and every modal. Popups track hover, filter text and
  animations frame by frame, so they must never be left on a stale frame;
* a conflict or error dialog is queued but not open yet;
* a text field is active (`igIsAnyItemActive`).

Otherwise it keeps rendering for `Desktop.HoldSeconds` (1.2 s) after the last input (hover
delays, tooltips) before it goes back to sleep. Measured: 104 % of a core before, 0.3-0.4 %
after (Debug build, window visible but not focused, project open).

**The hold restarts on any input ImGui processed, not only on a wake.** Input that arrives while
frames are already running (busy, or inside the hold) never goes through `WaitForInput`, so
`Desktop.NoteActivity` (called after `app.Frame()` every frame) refreshes the hold whenever the
frame saw activity: the mouse position changed, a mouse button or the wheel is down/released
(`igIsKeyDown` / `igIsKeyReleased` over `ImGuiKey_Tab .. ImGuiKey_MouseWheelY`, which includes
the mouse buttons and wheel), any key is down or released, a widget is active, or the display
size changed. Without this, the frame after a popup closed or a drag ended could go straight
to sleep while ImGui still had the release to process.

*Input trickling.* ImGui's `io.ConfigInputTrickleEventQueue` is on (the default; the host does
not change it): events that arrive in the same frame are spread over several frames (e.g. a
button down and up, or a mouse move after a button change), and the queue is not visible from
Beef. The activity rule covers it: trickling only defers an event after one that changed
state in the same frame (position, button, wheel, key, character), each of those changes shows
up in `NoteActivity`, so every frame that leaves an event queued restarts the hold, and the
loop keeps rendering until the queue has drained. Typed characters only matter while a text
field is active, which renders continuously anyway. SDL's own queue is drained every frame
(`vbh_begin_frame` polls until empty); Windows messages SDL leaves for the next pump make
`MsgWaitForMultipleObjectsEx(MWMO_INPUTAVAILABLE)` return immediately.

**A/B switch.** `VB_NO_IDLE=1` in the environment, or **Preferences > Graph Editor > Idle Frame
Pacing** off, makes `PaceFrame` return immediately (render every frame, vsync only, the
behaviour before the idle loop). The mode is written to the Output Log at start-up
(`Frame pacing: idle` / `Frame pacing: continuous (...)`).

**2026-10-10 mouse report.** "Mouse nigh impossible in the node menu, nodes only placeable
with the keyboard" was not the idle loop: the node menu itself fought the mouse (see the
CHANGELOG entry). Continuous rendering for open popups (`2187dbf`) made it worse, because the
menu then re-ran its per-frame bug at full frame rate.

## Editor: adding notices, panels and property rows

**A toast or log line** (from anywhere, any thread):

```beef
Notify.Info("Saved Player.bf");        // Output Log + toast
Notify.Success("..."); Notify.Warn("..."); Notify.Error("...");
Notify.Log(.Verbose, "MyCategory", "..."); // Output Log only
Notify.LogAt(.Error, "Build", text, path, line); // double-click in the log jumps there
```

`EditorApp.SetStatus` also logs (and toasts failures), so older code shows up in the log.

**A panel:** add a name to `Panels` in `Shell.bf` (`"<icon>  Title###Title"`, the part after
`###` is the stable id), draw it from `EditorApp.Frame` with `Gui.Begin(Panels.MyPanel, &mShowMyPanel)`,
add a Window menu item, and dock it in `SetupDockspace` (bump `cLayoutVersion` so saved
layouts pick it up). Focus it with `Panels.Focus(Panels.MyPanelId)`.

**A Properties section:** inside a `PropertyGrid.Begin(...)` / `End()` pair, add
`PropertyGrid.Category("Name")`, then `PropertyGrid.Row("Label", "tooltip", swatch)` followed
by any widget (it fills the value column). `PropertyGrid.WideRow()` gives a full-width row.
`TypeButton(id, typeString)` is the searchable type picker.

**A toolbar button:** `ToolbarButton(id, icon, label, tooltip, enabled, iconColor, active, badge, badgeColor)`
in `DrawToolbar` (Shell.bf).

## Editor: source files

| File | Contents |
|---|---|
| `Shell.bf` | Panels, toolbar, status bar, window title, compile state, frame-pacing hints |
| `Style.bf` | Theme and metrics |
| `Icons.bf`, `assets/fonts/` | Icon font and constants |
| `Notify.bf` | Notify API, log store, toasts |
| `OutputLog.bf` | Output Log and Problems panels |
| `PropertyGrid.bf`, `PropertiesPanel.bf` | Property grid and the Properties panel |
| `TypeSettings.bf` | Type Settings, function / variable class options, Override dropdown, attribute lists, type pickers, rename preview and multi-file undo groups, Add Property / Indexer, Create dialog options ([Classes-and-Members.md](Classes-and-Members.md)) |
| `TypePicker.bf` | Type picker |
| `FindPanel.bf` | Find in Sheets |
| `Outline.bf` | Outline panel |
| `GraphTools.bf`, `Minimap.bf`, `PinStyle.bf` | Arrange, align, minimap, pin / header styles |
| `CBExtras.bf` | Project Browser filters and drag-to-move |
| `Prefs.bf` | Editor Preferences (stored in `settings.json`, see below) |
| `Settings.bf` | `settings.json` (a small JSON reader / writer), `AppPaths` (the per-user folder, `VB_HOME`) |
| `CrashHandler.bf` | Session log, crash handler, crash report and minidump, `VB_DEBUG_CRASH_TEST` |
| `Recovery.bf` | Recovery journal and the orphaned-session scan |
| `ShellServices.bf` | Background indexing (status bar, retyping), the recovery prompt, compile configuration, diagnostics on nodes, the Build menu |
| `BuildRunner.bf` | BeefBuild process, output streaming, configuration and command line |
| `Debugger.bf`, `DebugCanvas.bf`, `DebugPanels.bf`, `SelfTestDebug.bf` | The debugger: breakpoints, Start Debugging, stops, values, Debug menu / toolbar / keys; the node overlay; Locals, Call Stack, Debug Output; `VB_SELFTEST=debug` ([Debugging.md](Debugging.md)) |
| `Desktop.bf` | Window handle, DPI, idle wait (`PaceFrame`) |
| `TitleBar.bf` | Project badge on the menu row |
| `Native/src/ImGuiShell.bf` | Extra cimgui bindings (style, IO, font config, tables, drags, side bars, window class) |

## Building from source

Either open `BeefSpace.toml` in the Beef IDE (`VisualBeefEditor` is the startup project; F5 builds
and runs), or from a shell:

```
"C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace=<repo> -config=Debug   -platform=Win64
"C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace=<repo> -config=Release -platform=Win64
```

Before any build, run the scope-delete lint (it fails on `X = scope ...` lists that a `Delete*!` macro frees; use `ClearAndDeleteItems!` for those): `powershell -ExecutionPolicy Bypass -File scripts\lint-scope-delete.ps1` must print `OK`. `scripts\package.ps1` runs it first.

The build ends with post-build steps that copy `vbhost.dll` and the icon font (`assets/fonts/`) next
to the program:

| Config | Editor | Tests |
|---|---|---|
| Debug | `build\Debug_Win64\VisualBeefEditor\VisualBeefEditor.exe` | `build\Debug_Win64\VisualBeefTests\VisualBeefTests.exe` |
| Release | `build\Release_Win64\VisualBeefEditor\VisualBeefEditor.exe` (about 2.4 MB, plus the 3.3 MB `vbhost.dll`) | n/a |

The Debug build needs `Beef042Dbg64.dll`, which the build copies beside the exe. The Release exe
has no Beef DLL next to it. If BeefBuild reports success but the exe did not change, delete the
stale exe and build again (a relink is sometimes skipped).

Run the tests once to know the tree is healthy: `VisualBeefTests.exe edits` (see [Testing.md](Testing.md)).

## Debugger: how it works

VisualBeef does not have its own debugger: it drives the one in the Beef IDE.

* **The engine** is `IDEHelper64.dll` from the Beef installation, the DLL the Beef IDE loads, through
  the same C API (`Debugger_OpenFile`, `Debugger_Run`, `Debugger_Update`, `Debugger_GetRunState`,
  `Debugger_CreateBreakpoint`, `Debugger_StepOver` / `Into` / `Out`, `Debugger_Continue`,
  `Debugger_BreakAll`, `CallStack_GetStackFrameInfo`, `Debugger_GetAutoLocals`, `Debugger_Evaluate`,
  `Debugger_PopMessage`, `Debugger_GetStdHandles`, `Debugger_StopDebugging`, `Debugger_Detach`, ...).
  It is loaded at run time (`VisualBeefCore/src/Debug/DebugEngine.bf`), looked for next to the
  editor, in `%VB_BEEF_BIN%`, in the folder of the configured BeefBuild and in
  `C:\Program Files\BeefLang\bin`. Without it, Start Debugging says "Debugging needs Beef 0.43.6
  installed". Symbol servers are off (an empty server list: a session never goes to the network);
  the program's PDB is read from beside it. `BeefDbgVis.toml` from the install formats corlib types.
* **The session** (`DebugSession.bf`) launches the program with its output redirected, keeps the
  run state (Running / Stopped / Stopping / Not debugging), and turns the engine's state into
  events the editor polls every frame (the idle loop wakes every 30 ms while the program runs).
  The loader's first break is continued, like the IDE does. Values are read with
  `Debugger_Evaluate` without allowing calls, so looking at a value never runs code in the program
  (a pin fed by a call shows the variable the call's result was kept in, or nothing).
* **The program to run** (`DebugTarget.bf`) is the workspace's startup project, resolved like the
  Beef IDE: `[Workspace] StartupProject` in `BeefSpace.toml`, then the project's
  `[Configs.Debug.Win64]` `TargetDirectory`, `TargetName`, `DebugCommand`,
  `DebugCommandArguments` and `DebugWorkingDirectory`, with the IDE's defaults
  (`build\Debug_Win64\<Project>\<Project>.exe`, working folder = the project folder). A library
  startup project needs a Debug command.
* **Build before debugging** is the Compile path with the configuration forced to Debug; BeefBuild
  runs at BelowNormal priority; errors land on the nodes and in Problems as usual, and debugging
  does not start.
* **Node <-> line** (`DebugMap.bf`): breakpoints are given to the engine as (file, line) of the
  saved text; stops come back as (file, line) and are mapped to the innermost statement node that
  holds the line. A breakpoint on a line without code of its own is moved by the engine to the next
  line with code (a function's `{` binds to its first statement); the node you set it on is still
  the one shown as stopped.
