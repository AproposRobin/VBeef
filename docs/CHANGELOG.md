---
audience: developer
title: Changelog
summary: What changed in each VisualBeef build, for developers.
order: 25
---

# Changelog

Newest first. Dates are commit dates; commit ids refer to the development history before the public repository was created.

## 0.2.2-alpha

- Updates: an Install button on Editor Preferences > Updates, the Help menu says "Update to X..." when a version is available, a status bar item opens the Updates page, and "Later" hides the notice for the current session only.

## 0.2.1-alpha

- Math Expression node: type a formula, get one input pin per name and a typed result; Initial Value keeps the Expression choice and validates the text.
- Switch on an enum shows plain case names; Properties headers show readable node kinds; refreshed user docs screenshots; release smoke tool.

## Unreleased: Math Expression

- Fix: Properties > Initial Value > Expression jumped back to the value's own mode (it started the
  expression as `default`, which reads back as default; a typed `0` read back as Number). The choice
  is now remembered for the variable (`InitExpressionChoice`), the box starts with the value there
  is, nothing is written until an expression is typed. Member variables, Local Variable nodes and
  Local Variables alike.
- Expression initial values must be one Beef expression (`MemberInit.CheckExpression`): the box is
  framed red with the reason under it, and nothing is written; the Add Variable dialog does the same.
- New node: **Math Expression** (docs/Math-Expression.md). A formula typed on the node (or in
  Properties); one input per free name, one Result; the result type inferred where Beef's rules
  make it certain, chosen in Properties otherwise. The code is the formula with the values in
  place; the `.vblayout` `#math` / `#orphanmath` records bring the node back on load.
- Suites: `calls` + 48, `textforms` + 27, `classes` + 29, `compile` + 1 case (`MathExpression`);
  `VB_SELFTEST=mathexpr` with six captures.

## Unreleased: polish

- A locked Static box (a function in a Node Library) is grey with the tooltip "A Node Library is always static".
- Node menu > Libraries groups a library under `<Namespace>.<Library>`.
- Editor Preferences: the "Saved to" line and the folder paths are cut in the middle with "..." to fit; the tooltip has the whole path.
- Properties > Inputs: a type name longer than the row has room for gets a line of its own under Passing and remove; the picker ends a long name in "..." (tooltip: the whole name).
- The enum dropdown of an inline pin editor stays inside the window (pulled left at the right edge, opened upwards at the bottom).
- Docs: the per-function local variables are "Local Variables" everywhere (the debugger's panel stays "Locals"); the button is Move to Local Variables.
- `VB_SELFTEST=session` captures `pins-values-lower`, `pins-values-edge`, `pins-enum-open-edge`, `pins-bool-off`, `pins-type-number`, `pins-type-char`, `pins-type-string`.

## 0.2.0-alpha

- In-editor updates from GitHub Releases (Help > Check for Updates, Preferences > Updates).
- The README stands on its own: it no longer links to pages that are not in the public repository.
- Crash report check fixed.
- Linux build fixed.
- The vocabulary check allows the product name.

## Unreleased: updates from GitHub Releases

- The editor updates itself from the public repository's GitHub Releases, like the UniversalUMP launcher: a signed
  `release.json` (Ed25519 over a canonical text: version, channel, sequence, tag, each file's platform, name, size and
  SHA-256) is read from `releases/latest/download/release.json` (stable) or the newest published release (preview),
  verified against the key in `VisualBeefCore/src/Update/ReleaseKeys.bf` (empty: updates are not set up), and offered only
  when its sequence (or, for a fresh copy, its version) is above the running one. The package is downloaded with the
  system's curl, its size and SHA-256 checked, and installed on **Restart to finish** (refused with unsaved files): on
  Windows by a helper copy of the editor that keeps a `previous` copy and restores it when the new version does not start
  within 60 s; on Linux the AppImage is replaced and restarted. Docs: [Updating.md](Updating.md), [Releasing.md](Releasing.md).
- UI: a notice line under the toolbar (Update / Release notes / Later, progress, Restart to finish), **Help > Check for
  Updates...**, **Editor Preferences > Updates** (Check at Start, Channel Stable / Preview, Check Now). Settings
  `updates.check`, `updates.channel`.
- Release side: `scripts/release.mjs` (`keygen`, `public`, `sign`, `verify`, `publish`, `vectors`); tags now build one
  draft pre-release with the Windows and Linux packages (the Linux workflow runs on tags too), published by the owner after
  signing.
- Ed25519 from the launcher: in Debug builds a `static readonly int64[32]` initialised with a list ending in zeros came out
  with garbage in its last element (Beef 0.43.6), so every signature failed in Debug only; `L` and `gf1` are filled by the
  static constructor now. New suite `update` (98 checks), `update -net` by hand.

## 2026-10-11: 0.1.9-alpha

Alpha build with per-function Local variables in the Outline and the pin actions Make variable / Make local variable, multiple function outputs, the Node Library kind and global variables, typed pin controls and the single Switch node, hook nodes for UMP visual mods, the debugger attaching to a running game, the minimap pass with saved views and Home / Fit, comment bubbles with a pin, the pending wire while the Node menu is open, and host assertions that log instead of showing a dialog. Still alpha.

## 2026-10-12: Debugger phase 2: Attach to Game

- **Debug > Attach to Game...** lists the running processes with the UMP runtime (`UMPRuntime.dll`) and the mods each has loaded, says whether the picked game runs this project's mod (loaded, the same build as `build\Release_Win64`, from this folder, symbol file present), and attaches Beef's debugger engine (`Debugger_Attach`, flags 0) to it.
- Breakpoints on the mod's nodes stop the game (it pauses); the Sheet opens on the node, Locals and Call Stack show the mod's frame, Step / Continue work. The Call Stack folds frames without source into dimmed **game code** rows (Show game code frames expands them) and ends with a `game code (callers not shown: no symbols)` row when the game's executable is not read.
- **Detach** (Shift+F5, the red toolbar button, Debug > Detach) leaves the game running; so do closing the editor and the editor crashing (the engine's thread sets kill-on-exit off). The status bar is red while attached: `Attached to HogwartsLegacy.exe (pid) - running` / `- game paused at ModMain.Tick: F5 Continue, Shift+F5 Detach`.
- Beef 0.43.6's debugger engine crashes (access violation on its thread, which ended the editor) reading Hogwarts Legacy's protected executable. On attach, a main executable without a symbol file here is served to the engine as stripped headers (the engine DLL's ReadFile import is redirected in the editor's process), so it is never parsed. `VisualBeefTests attachprobe <pid> [seconds] [images...]` reproduces and checks this on a stand-in process.
- Fixed on the way: an attached session no longer starts pipe reader threads (a stale engine handle blocked one and the program could not exit); reader threads are background threads.
- Live proof (Epic Hogwarts Legacy client, fresh launcher 20261011-b802a7e, a `modauthor` Release mod with `mTicks += 1` in Tick): attach, stop on that node in `ModMain.Tick` (frames: the mod, `UMPRuntime.ModLoader.DispatchTick`, `FUMPTickHook.HookedTick`), `this.mTicks = 2635`, Step Over, Continue, Detach, the game ran on and stopped gracefully with `--stop`.
- Counts: `debug` 74 checks (25 new: the Debuggee fixture started as its own process, found by module, attached by pid twice, break, local, Step Over, Continue, Detach with the process still running), `VB_SELFTEST=attach` 13 checks at 1280x800 / 1920x1080, Dark / Darker, 100 % / 125 %; `VB_SELFTEST=attachlive` 9 checks on the game; no `[ASSERT]` lines.

## 2026-10-12: Typed pin values and the one Switch node

The owner's rules (A) and (B) of 2026-10-12 (branch `wt/typed-pins`). Tests: `flow` +45 (`PinTests.bf`), a
`factory` case, `VB_SELFTEST=session` steps 99-111 (session 37 checks, captures `pins-values`, `pins-enum-open`,
`pins-refuse`, `pins-switch`).

* **Every unwired input pin shows the control for its type**, on the node and in Properties (`PinValue` in the
  core, `PinValueEditor` in the editor): enum -> a dropdown of the enum's members (`.Member`, also read from
  `EnumName.Member`); `String` / `StringView` -> a text field without quotes (quotes and escapes added on
  write); `bool` -> checkbox; numbers -> a field that refuses what the type cannot hold (`300` for `uint8`, `1.5`
  for `int`, a negative for `uint`) with the reason in a toast and a red frame, written `1.5f` for `float`;
  `char8` / `char32` -> one character, `'x'`. Class / struct / pointer pins have no editor (a dim `null` /
  `default`). A value that is not a plain literal (an expression) shows read-only with a **Custom** badge and is
  edited as text in Properties. Receivers and pins of unknown type stay expression text.
* **One Switch node.** Properties > Cases > **Switch On** (a type picker: whole numbers, characters, `String`,
  any enum). Changing it keeps the cases that still fit and starts a new type with one case; an enum gets one
  output per member. **Update members** (and Reload node) follow the enum when it changes. Case values are typed
  with the same controls. The Node menu has one `Switch`, and dragging off an enum-typed output offers
  `Switch on <Enum>` as the first row, placed with the wire connected.

## 2026-10-12: No code signing

- Owner decision: no code-signing certificate and no SignPath application. Releases are unsigned; trust comes from the public GitHub workflow, build attestations and checksums. The signing steps, variables, `package.ps1 -SignedDir`, the `stage-sign` / `package-signed` CI steps and the SignPath pages are removed (branch `wt/no-signpath`).

## 2026-10-12: Inputs stay on their function, several outputs, local variables

The owner's requests after using 0.1.8 (branch `wt/locals`), each exercised by the new
`VB_SELFTEST=fnlocals` (28 checks) and `LocalsTests.bf` (`classes` +31, `flow` +3).

* **Add Input no longer jumps to another function.** The Sheet tab's identity in the tab bar was
  `<file>|<method key>`, and the key holds the parameter types, so Add Input / remove / a type
  change made a new tab id: the tab bar put another function's Sheet in front and Properties
  followed it. Tabs now have a stable id, `SourceDocument.SetSignature` reports the function's new
  key (`LastSignatureKey`) and the tab follows it (never another overload of the same name), and
  the new row's name box gets the keyboard focus.
* **Several outputs.** Properties > Outputs: the Return Value and one row per further output (an
  `out` parameter), with the read-only header under them. The Return node has an input per
  output and writes `value = ...; name = ...; return ...;`; read back from the assignments right
  before a `return`, byte for byte. Adding an output gives every Return its default in the same
  undo step. See [Classes-and-Members.md](Classes-and-Members.md#outputs).
* **Local variables instead of the Local Variable node.** The declarations at the top of a body
  are the function's local variables: listed in the Outline under the open function (LOCAL
  VARIABLES, +, drag for Get / Set, rename in place), shown in Properties when selected (type,
  Ownership with **Made for this call** = `scope .()`, Initial Value), written first in
  order, byte for byte. The Local Variable node is gone from the Node menu and the hotkeys; **L**
  adds a local variable. A declaration in the middle of a body stays as it was, with **Move to
  Locals** offered (only when asked: it can change when the value is computed). See
  [Classes-and-Members.md](Classes-and-Members.md#local-variables).
* **Make variable from a pin.** The pin context menu: **Make variable** / **Make local variable**
  on a data output (the variable, typed like the pin, and a Set fed by it spliced after the pin's
  node), **Make variable (Get)** on a data input. One undo step each (`SourceDocument.DropLastUndo`
  merges the member's own edit with the nodes).
* **Layout rule** (Editor-UI.md > Layout): lists on the left (Outline), the properties of the selection on
  the right (Properties).
* Fixed on the way: an ImGui `Mismatching PushID/PopID!` assertion (imgui_tables.cpp:1594) from the
  first draft of the Locals rows (value rows drawn inside a row's ID scope); the orphan record of a
  function with local variables is restored with them declared first.
* Tests changed with the model: edits scenarios 18 / 20 use `var` declarations where they wire a
  declaration's output (a typed one at the top is now a local variable), two factory cases put a
  print first, hotkeys have 10 defaults (L is the Sheet's own key), compile cases move top
  declarations back into the flow before wiring their values.
* Not changed: `orphans` on the three UMP folders reports 19 refused reconnect commits ("For Loop
  'Count' takes int, but the wire brings bool") on master too: a counting loop header with `&&`
  in its condition (`for (int i = 0; i < 10000 && !done; i++)`) is read as a For Loop whose Count
  is the whole `10000 && !done`.

## 2026-10-12: Node Library (static class) and global variables

- New type kind **Node Library** = Beef `static class Name` (byte for byte; `class` with only static members stays a Class). Project Browser > New Node Library..., New Class > Template, Type Settings > Kind. Own Outline entry, Type Settings without the instance-only rows, no constructors / destructor / parent / interfaces.
- Everything in a library is static: Add Function / Add Variable write `static`, the Static checkbox is locked on, `static` cannot be turned off; a member written without it is treated as static.
- Node menu: library functions under **Libraries > Name** (no Receiver pin, `Name.Fn(...)`); static variables of any type get Get / Set under **Globals > Owner** (`Owner.Field`). Add Variable has a Static checkbox for classes; owned static objects are written `static String sName = new .() ~ delete _;`.
- GraphValidator: a This node in a library function is refused, `new Lib()` (Construct) is an error in the editor and a warning read from code; the Node menu never offers Construct for a library.
- Counts: `classes` 476 (31 new: reading, kind change and its refusals, static writing, owned global, validator, catalog categories), `VB_SELFTEST=session` steps 36 (New Node Library, function and variable, call it from the Greeter Sheet, Get the global, captures `library-newdialog`, `library-typesettings`, `library-function`, `library-sheet`), no `[ASSERT]` lines.

## 2026-10-12: Minimap pass, saved views, Home and Fit

- **Minimap.** Before: 30 % of the pane (up to 240 x 150 px), scaled to the nodes plus the current view, so the map rescaled on every pan and zoom, a 3-node sheet showed giant blocks, the box was nearly opaque and covered the corner, and every frame walked all nodes. Now: a fixed 180 x 120 px (display scale, not zoom) in the bottom-right corner, semi-transparent (opaque on hover), nodes as small rounded blocks in their colour, no wires, a clear white view rectangle kept inside the box, scale from the graph's own extent (never from the view, capped so small graphs stay small), click or drag moves the view clamped to the graph, a close mark on the corner (M and Window > Graph Minimap also toggle, remembered in settings), hidden when the pane is small. Block geometry is cached and rebuilt only when a node, box, selection or size changes.
- **Saved views 1-9** per function: Ctrl+digit saves (toast "View 3 saved"), digit eases there in about 150 ms (toast "View 3", or "View 3 is not set (Ctrl+3 saves it)"); numbered markers on the minimap; Window > Saved Views. Stored as `#view` lines in the layout file; old files load unchanged.
- **Home / Fit all.** Two small buttons in the upper right of the canvas (Home, tooltip "Go to the entry node (Home)", and "Fit the whole graph"); Home eases to the entry node at zoom 1, or fits the graph when there is none. F is already frame, so it stays.
- Counts: `edits`, `hotkeys` 36, `safety` (new block 20, 13 checks), `vocabulary` 0 hits, `VB_SELFTEST=session` 157 ok, `done failures=0`.

## 2026-10-12: Pending wire, comment bubbles, paste selection

- The wire you drag off a pin stays drawn from the pin to the release point while the Node menu is open (pin colour, flow wires thicker, either direction), until a node is placed, the menu closes or the Sheet changes; a menu from the empty canvas draws nothing.
- Node comments show as a bubble above the node on the canvas (click it, hover the node's `+ comment` chip, or Add Comment in the node menu to edit in place; Enter commits, Ctrl+Enter is a new line, Esc cancels). It is the same text and the same comment lines as Properties > Comment. A pin icon on the bubble (and on comment boxes) keeps it readable when zoomed out; the pin is saved in the `.vblayout` file (`#bubble` lines, a trailing `1` on `#comment` lines; old files load unchanged).
- Paste (and Duplicate) select the pasted nodes, so they drag as a group.

## 2026-10-11: Host asserts no longer open a dialog

- The shipped `vbhost.dll` had `assert()` live, so an ImGui misuse (ID stack, Begin / End, style push / pop) opened the
  Microsoft Visual C++ Runtime Library dialog in front of the editor. The host now routes `IM_ASSERT` and SDL's assertions
  to `vbh_assert_failed`: each site is logged once per run as `[ASSERT] <expr> at <file>:<line>` (Output Log and session log)
  and the editor carries on. `vbh_set_assert_handler` (one new export) registers the editor's handler at start-up.
- Editor test runs count `[ASSERT]` lines as a failure (`no host asserts` check before `done failures=N`).
- `build_windows.ps1` and `build_linux.sh` compile with `-DNDEBUG`. `vbhost.dll` and `vbhost.lib` rebuilt from source
  (13 `vbh_*` exports, was 12). See [Architecture.md](Architecture.md#host-asserts).

## 2026-10-11: Hook nodes for UMP mods

The `modauthor` self test now builds its hook part from the Node menu only, over UMP's emitter v5 SDK (`Hooks|<Class>`
nodes, `ReadModFile`, `ModDirectoryPath`, `ToOwnedString`); 42 checks, a Release compile to `HelloMod.dll`, no typed Beef.

* **Catalog noise (6, 7, 8).** Over the v5 SDK a search for "Days In Year" lists 8 rows with the words (the function, its
  Get / month siblings and the hook family) and 0 `_PE` / `SdkHooks` / raw `Original_` rows; the same search over the SDK before
  v5 (unattributed) listed the `Days In Year PE`, `Get U Kismet Math Library Days In Year` and `Set ...` rows among its first ten.
  **Call original** is a node of the hook family.
* **UMPJson.** File > New Project > UMP Mod finds `UMPJson` (older UMP folders: `BJSON-1.3.0`) and writes it into the workspace;
  with the library gone from the UMP folder the Game SDK row had refused every SDK.
* **Inherited properties (9).** A mod's protected base fields and properties are offered as Get / Set
  (`ModDirectoryPath`), as its protected functions already were.
* **Raw-name search (14).** `m_LoopStart`, `Loop_Start`, `TryHook_DaysInYear` and other names with underscores find their row first.
* **Unread Result (13).** A call returning `Result<...>` whose return pin nothing reads shows a note on the node.
* **Mutating receivers (12).** A struct or text value returned by a call and used as a Receiver is written `var`, not `let`
  (`let` made `ToOwnedString()` fail to compile).

## 2026-10-11: The mod author pass

A first UMP mod made from an empty folder in the Release editor (`VB_SELFTEST=modauthor`, 22 checks): Initialize logs
a line, hooks `UKismetMathLibrary.DaysInYear`, reads the mod's own `ModConfig.json` and logs it; OnWorldReady keeps the
world; Tick reads the level name once; Shutdown removes the hooks; a Release compile gives `HelloMod.dll`.

* **File > New Project > UMP Mod.** The project type a mod author needs, with a **Game SDK** folder chooser. From the
  SDK folder (or a launcher / UMP folder with exactly one SDK below it) VisualBeef finds UMP's libraries above it and
  writes the launcher's visual mod project: `BeefSpace.toml` (the SDK, UMPSDK, UnrealSDKCore, UMPDebug, WindowsUtils,
  BJSON by absolute path), a DLL `BeefProj.toml` (Release copies into the launcher's `mods` folder when the SDK is the
  launcher's), `ModConfig.json` with `MinRuntimeAbi` read from the UMP source and `MinLauncher`, `.vbproject`,
  `src\ModMain.bf` (`TypeTemplates.MakeUMPMod`) and `README.md`, then opens the mod. Before, New Project offered only
  Console / Library / Windows: the mod's workspace, SDK references and manifest had to be written by hand. The name is
  the mod's display name; the folder and id follow UMP's rules (`Hello Mod` -> `HelloMod`, `hello-mod`).
* **Usings for placed calls.** A static call placed from the Node menu whose type is in a namespace the file does not
  use writes that `using` (File.ReadAllText -> `using System.IO;`) in the same undo step. Before, the file did not compile.
* **Function pins.** The Node menu from a pin that takes a function (`function uint64(uint64)`, a hook's Callback)
  offers the type's static functions of that exact shape, written `=> OnDaysInYear`. Before, nothing was offered and
  `=> Name` had to be typed.
* **bool inputs start false.** A bool input of a placed call starts with `false` (as its checkbox shows) instead of
  "needs a value".

## 2026-10-11: 0.1.8-alpha

Alpha build with the newcomer pass and its second round, the type chooser spacing fix, the load-all leak fix, the Windows host DLL built from source with a version resource, Linux crash reports, Trash, display scale and the AppImage, and the SignPath readiness work (release workflows, licences, docs). Still alpha.

## 2026-10-12: The type chooser's search box no longer sits on the container buttons

Popups opened from inside a Properties / Type Settings grid drew with the grid's tight item spacing (6 x 2 instead of 6 x 4, the style stack is global), so in the type chooser the Single / Array / List / Nullable buttons touched the search box (its 1 px focus border overlapped their lower edge, about 2.5 px of gap at 125 %, 1 px of real clearance), and the first list row was squeezed under it. `Look.BeginPopupSpaced` / `EndPopupSpaced` give such popups the normal spacing at any scale; used by the type chooser, the Type Settings class picker, Add Attribute presets and the two Override dropdowns. Checked at 100 % and 125 %, Dark and Darker.


## 2026-10-11: The newcomer pass, second round

The open findings of the newcomer pass, each exercised by `VB_SELFTEST=newcomer` (now 25 checks):

* **For Loop counter.** A counting header (`for (int i = 0; i < count; i++)`, `for (int i < count)`) reads as a For Loop with a **Counter** output pin named after the variable and **Start** / **Count** input pins; printing the counter is a wire. Unchanged headers are written byte for byte; any other header stays Loop Header text. Properties: Counter Name, Counter Type (whole-number types). A new For Loop is `for (int i = 0; i < 10; i++)`.
* **Passing.** Properties > Inputs rows have a Passing chooser (value / out / ref / in, only what Beef takes for the row); the Add Function dialog has the same Inputs rows and a Return Type type picker instead of typed text. A constructor chain no longer writes `in x` in its argument list (Beef refuses it).
* **Return defaults.** A Return placed in a value function starts with `false`, `0`, `null` (classes, interfaces, delegates, arrays, pointers, nullables) or `default` (structs, enums, characters, unknown types).
* **Set pin wording.** A Set node's first pin is labelled *Variable* (the variable being set), not *Receiver*.
* **Construct needs a constructor.** A Construct of a project class whose constructors all take inputs, with none chosen, shows "Greeter needs a constructor: choose one in Properties > Constructor" before any compile; Properties > **Constructor** lists the class's constructors and gives the node their inputs.
* **A print read from code takes any value.** `Console.WriteLine("text")` read back has the `obj` pin typed `Object`, like a placed Print, so a wired int is accepted; the text is unchanged.

Counts: `flow` 154, `classes` 445, `vocabulary` 0 hits; `VB_SELFTEST=newcomer` 25 checks, `session,debug` 113 + 20 checks, each `done failures=0`.

## 2026-10-11: Window raise and minimized state use the SDL host on Windows too

`vbh_raise_window` and `vbh_window_flags` (added for Linux) are in the Windows `vbhost.dll`, 1,694 exports (the 1,692 before are unchanged), and their Beef externs are no longer Linux-only. `Desktop.BringToFront` calls `SetForegroundWindow` and then `vbh_raise_window`, so a minimized editor comes back when the debugger stops. `VB_DEBUG_RAISE_TEST=<seconds>` on Windows with the window minimized logs `before: minimized=True` and then `after: minimized=False focused=True`. Linux still needs its own `libvbhost.so` rebuild (the CI does it clean). No version bump.

## 2026-10-11: A newcomer pass

A first-time user's path from an empty folder to a debugged program (the new `VB_SELFTEST=newcomer`, docs/Testing.md), the way the 0.1.2 and 0.1.7 reports were found. Fixed:

* **Implement missing members found nothing to implement.** Add Function on an interface wrote a body (`public void Greet(String name) { }`), which in Beef is a default implementation. It now writes `void Greet(String name);`.
* **Add Variable `List<int>` wrote a member Beef refused** ("Type could not be found") in a file with only `using System;`. Add Variable and Add Function now add the `using` for every type they name from a namespace the file does not use, in the same undo step.
* **A false "Several overloads fit" warning on the new project's own `Console.WriteLine("Hello from Mod")`.** String -> StringView and String -> Object tied; `Object` now ranks a step below any other implicit conversion, as in Beef.
* **Print refused a number** ("int is not text: format it ..."): Print and Console.Write from the Node menu take `Object obj`, any value Beef prints.
* **Construct offered only this file's classes**, so `Main` could not make the class just created in its own file; and a Construct of a class whose constructors all take parameters wrote `new Greeter()`, which Beef refuses. The project's other classes and structs that the file can name are offered, with the inputs of their create constructor (or only / first constructor with parameters).
* **Defer -> Delete of a `new` object that the function then uses was refused** ("shared by nodes in different blocks"). The shared value is now declared before the Defer.
* Lifetime-Nodes.md: "An flow node" -> "A flow node".

Open (in `findings.md` of the pass, not fixed here): the For Loop node has no counter output and its count is a typed Beef header; the Properties Inputs rows cannot make a parameter `out` / `ref` (only the Add Function text can); a Return with a `bool` value starts empty.

## 2026-10-12: The Windows host DLL is built from source again

`Native/bin/win64/vbhost.dll` was last built before the 0.1.7 DPI work (per-window display scale, `vbh_get_window_scale`, float framebuffer math), so the shipped 0.1.7 builds still had the old host. It is rebuilt now, with the new `Native/build_windows.ps1` (portable llvm-mingw 20261006 ucrt, clang 23.1.3, plus the SDL2 2.32.10 mingw devel build, both under `tools\`, static SDL2 and C++ runtime). The export set is the old 1,691 plus `vbh_get_window_scale`; the DLL now imports the UCRT (`api-ms-win-crt-*`, Windows 10 and later) instead of `msvcrt.dll`. `build_windows_mingw.sh` still works with a real MinGW. No version bump.

## 2026-10-12: Undo removes placed nodes

Not a defect of undo: found while testing 0.1.7 as "the hotkey nodes survive the undos of session step 32". `SourceDocument` already restores the graphs of a snapshot whether or not the step wrote text, and every placement path (Node menu, hotkeys, drops, paste) goes through `BeginEdit` -> `PushUndo`, so each placement is an undo step of its own. The step 32 loop undid until the *text* equalled the saved file, which happens as soon as the last step that wrote text is undone: a Branch placed unconnected, and a print placed without a value, write no text (the print is refused until it has one), so their steps were still on the stack.

* Session step 32 now undoes by undo depth back to where the hotkey steps began, then checks the saved text, the graph's node count and no graph errors, redoes every step (the nodes are back), and undoes again.
* New `edits` scenario 24 (8 checks): an unconnected Branch, a print placed without a value and a connected call, each its own step with no text written for the first two; three undos remove them one by one, three redos bring them back.
* `session,debug,disk` now chains cleanly (`disk` 17 checks after `session` 108 and `debug` 20); `reload-check` still belongs after `session,debug` alone (`disk` deletes and rewrites the scratch `src`, so there is no compile record to be green against).

## 2026-10-12: 0.1.7

Combines the bug hunt (24 fixes found by a read-through of the day's code, new `stress` suite) and the suspected-issue fixes (the eight suspected issues: typed primitives, rename refusal, constructor chain check, native host DPI source, code-point characters, breakpoint choice, tuple generic arguments, disk faults).

* **Windows host DLL not rebuilt; DPI change inactive on Windows until rebuilt.** `Native/vbhost.cpp` changed (compiled and checked on Linux only; no MinGW toolchain on this machine), the shipped `vbhost.dll` is the previous build.
* Gates: Windows Release and Debug clean builds 0 warnings, every suite green, editor self tests `session,debug`, `reload-check`, `unreadable`, `nodoc`, `disk`, `open:...,ids` green; Linux `build_linux.sh` compiles `vbhost.cpp`, `linux-ci.sh` green, editor `session` green under WSLg.
* Finding: after `session` step 32 (3 undos) the text is back but the Branch and print nodes placed by the hotkey steps stay in Hello's open graph (graph-only nodes are not undone); the print has no value, so a later Save All is refused. `disk` therefore runs in its own process after `session` (docs/Testing.md). Not changed in 0.1.7.
* Notes: `EditorApp` Add Function keeps the 0.1.6 field order with the bug hunt's display-scaled widths; the self test names `nodoc` and `disk` both exist.

## 2026-10-12: Suspected issues resolved

The eight items the bug hunt listed as suspected, each confirmed or refuted with a test, then fixed at the root or
documented.

* **Typed primitives** (confirmed, fixed): `struct Handle : int` is legal Beef (corlib: `Int64 : int64`, `HSocket : uint`,
  `TypeId : int32`) and was refused. A struct may list one basic type, first, before its interfaces; a class, `void`, a
  second basic type or one after an interface is still refused.
* **Rename with a refused commit** (confirmed, fixed): `ApplyRenameEdits` rebuilt such a function from the renamed text and
  dropped its graph edits silently. It refuses the rename and names the function; a rename that does not touch it goes through.
* **Constructor chain** (confirmed, fixed): `this() : base(x)` with no `x` was written. Every chain argument must be a
  parameter of the new constructor (optionally behind `ref` / `out` / `in`) or a literal, and the chain must be `base(...)` or
  `this(...)`; the refusal names the argument.
* **Native host DPI** (partly confirmed, source fixed; **`vbhost.dll` not rebuilt**, no MinGW toolchain on this machine): the
  window opens on the display under the mouse sized by that display's DPI, follows `SDL_WINDOWEVENT_DISPLAY_CHANGED`
  (exported as `vbh_get_window_scale`), off Windows the physical EDID DPI is no longer read as a UI scale (`VB_UI_SCALE` /
  `GDK_SCALE` count), and the viewport is computed in float before the cast. On Windows the editor already followed monitor
  changes through `GetDpiForWindow`; the new export is for the other platforms once the library is rebuilt.
* **Character values** (confirmed, fixed): the value box counted bytes, so `'e'` with an accent or an emoji was refused.
  It counts code points and applies Beef's range per type (checked with BeefBuild: `char8` up to U+00FF, `char16` up to
  U+FFFF, `char32` any).
* **Two breakpoints on one bound line** (confirmed, fixed): the stop named the first one added. It prefers the breakpoint
  bound at the stop address, then the one asked for on exactly that line, then the nearest above.
* **Tuple generic arguments** (confirmed, fixed): `Dictionary<int, (int, int)>` counted three arguments; a tuple is one.
* **Disk faults** (exercised; one silent failure and one stale marker fixed): Reload From Disk returned silently when the
  file could not be read, now it says so and keeps the text; a text change under a stopped debug session left the stop
  marker on a stale line, now it is hidden with a status line saying why. A read-only source file and a deleted source
  folder were already safe and reported. New self test `disk` and debug step 7 (`docs/Testing.md`).

## 2026-10-11: 0.1.6

Combines the pixel pass fixes, node hotkeys and favorites, no silent writes and blank alpha builds.

* **Pixel pass fixes**: see "Editor pixel fixes" below (the Node Hotkeys page wraps, the captures re-shot).
* **Hotkeys and favorites**: a letter hotkey per Node menu favorite, the Node Hotkeys preferences page.
* **No silent writes**: a form the writer cannot express is an error or a warning on the node, never a silently missing statement.
* **Blank alpha builds**: `VisualBeefInfo.Channel = "alpha"`, `package.ps1 -Minimal`, `scripts/package_linux.sh`.
* **Add Variable with no document open** no longer crashes (see below).
* Root cause of the Add Variable crash: `FindType` read `Doc.Unit` of the empty document (null) on the first frame of the dialog. `FindType` is null-safe and Add Variable / Add Function refuse to open without a document; `VB_SELFTEST=nodoc` covers it.
* Notes: the session self-test chain is one numbering again: step 24 scope Construct into a Receiver, 25 ownership, 26 set on create, 27-32 hotkeys.

## 2026-10-11: Node hotkeys and favorites

User request: node hotkeys with favorites, "press B when dragging and a Branch node is created".
Hold a letter and click the Sheet to place its node there, or press it while dragging a wire from a pin to drop the node
at the cursor connected to that pin (the Node menu's own placement and connect logic, `NodeMenu.ItemForKey` +
`ExecuteAction`). Defaults: B Branch, S Sequence, E For Each Loop, O For Loop, W While Loop, R Return, L Local Variable,
T Get a reference to this, P Print (Console.WriteLine), N Construct (new .()), D Defer (there is no Delay node; F is
Frame, C the comment box, M the minimap, Q straighten: those four can never be node hotkeys). Only plain letters, only
while the Sheet has the keyboard. The hard-wired B / R + click is replaced by the map.
Every Node menu row (Library tree included) has a star: Favorites are the first group, a key box before the star shows a
node's hotkey on every row, and on a favorite it is a key-capture control ("Press a key", Esc clears, a taken letter is
refused naming its owner: "B is already the hotkey of Branch."). Removing a favorite removes its key. Favorites and keys
are global in `settings.json` (`editor.favorites`, `editor.nodeHotkeys`), seeded with the defaults on first run; the
favorite lines of `node_menu.txt` move there once (recents stay in `node_menu.txt`). Editor Preferences has a new
**Node Hotkeys** page (every key with Clear, the reserved letters, favorites without a key, Reset to Defaults). The map is
`NodeHotkeys` in VisualBeefCore. Tests: new `hotkeys` suite (36 checks), `VB_SELFTEST=session` steps 27-32 (B + click,
P while dragging from a flow pin, a favorite given K through the key-capture control and used, `settings.json` text).
The Node menu says "Favorites" (was "Favourites").
Together with the pixel fixes: the Node Hotkeys page's explanatory rows wrap inside their column (they were cut mid-word at 1280x800 / 125%); captures of the Node menu with Favorites, the key-capture control and the page checked at 1280x800 and 1920x1080, 100% and 125%, Dark and Darker.

## 2026-10-11: Blank alpha builds

User request: "a blank build that is just the application for both Windows and Linux. This won't
have any docs or anything and will be marked alpha or beta." Decision: alpha.

* `VisualBeefInfo.Channel = "alpha"`: `--version` prints `VisualBeef 0.1.x-alpha (UMP contract 1)`, the window title is
  `VisualBeef alpha - <project> - <class>`, `VERSION.txt` reads `0.1.x-alpha` (full package too).
* `scripts/package.ps1 -Minimal`: exe, `vbhost.dll`, `assets\`, `VERSION.txt` and the licence texts only; zip
  `VisualBeef-<ver>-alpha-win64.zip`. The packaged exe's `--version` is checked against `VERSION.txt` (every package).
* `scripts/package_linux.sh`: Release build in WSL/Linux, `VisualBeef-<ver>-alpha-linux64.tar.gz` with the editor,
  `libvbhost.so`, assets, licences and `README-linux.txt`. Release link adds `-Wl,-rpath,$ORIGIN` so the library is
  found beside the binary.
* UnrealUMP compatibility: its VERSION.txt reader and package check accept the `-alpha` suffix; no change needed there.

## 2026-10-11: Bug hunt

A read-through of the day's code and scripted sessions on crafted projects (CRLF and LF, tabs and spaces, Allman and
K&R, every member kind, generic and nested types, a 1,770-line class, an unreadable member, a path with spaces and
non-ASCII). New suite `stress` (random edits, undo all byte for byte, redo all, graphs in sync after every step).

* **Kept graphs follow their context**: a graph whose body text is unchanged was kept after a member variable it reads
  was renamed or deleted (or a parameter renamed); it now rebuilds when a fresh read gives another shape.
* **Set on Create** follows a marked variable's type change (also Ownership > Pointer) and its deletion, in the same
  undo step; before, the constructor read as edited by hand or kept an assignment that no longer compiled.
* **Properties undo**: the undo step is taken before a node's text or type changes (Ctrl+Z after a Construct's Type
  change kept the new type). **Type picker** checks the type with its container (no more `List<var>`, `void[]`).
* Edit buffers in Properties are keyed by file and member (A.Update's attributes no longer show on B.Update).
* **Base list** refuses a type as its own parent and a base listed twice. **Namespace** edits of a file-scoped dotted
  namespace replace the whole name; on a nested declaration the outer path is kept. **Initial value** edits keep
  `~ delete _`; integers are checked against the type's range; `\u{...}` escapes read in the value box.
* **Type checks**: generic arguments are invariant (`List<Circle>` is not a `List<Shape>`); `int[]` is not `int[,]`;
  `UI.Button` is not `Physics.Button`. Constant generic arguments (`SizedArray<int, 4>`) fit type fields. Overloads
  score a `params` array passed whole.
* Undo / redo keep the layout side file's version (a newer sidecar is no longer overwritten after an undo); a layout
  file that cannot be written is reported; Save As that fails leaves the document on its file.
* Debugger: values of the last run are not shown at the first stop of the next; output readers can no longer touch
  a freed session when a child process keeps the pipe open. Constructor chaining passes `ref` / `out` arguments.
* Node menu: arrow keys no longer read rows freed by a re-filter. Add Variable keeps a Member value typed for an enum
  the index does not know. Dialog widths scale with the display; dock tabs keep their whole title (the shrink floor is
  the widest panel title); the error / warning badge goes above its node when below would cover another node or run
  out of the canvas.

## 2026-10-11: 0.1.5

Combines initializer ownership and initial values with Set on create, plus three follow-ups.
Counts: `classes` 353, `parser` 296, `diagnostics` 49, `catalog` 219, `debug` 47, `VB_SELFTEST=session` 82
(steps 24 ownership, 25 set on create) plus 14 `debug`.

* **Owned for the run and Disposed with it** (new `MemberInit` choices). A static member's `= new .(args)` with no
  destructor reads as **Owned for the run** (made once, never deleted; an instance member written that way stays Custom,
  and the choice is refused for one). `~ _.Dispose()` and `= .(..) ~ _.Dispose()` (corlib `Event` and struct fields) read as
  **Disposed with it**, with the Initial Value (`.()` / `.(args)` / `default` / an expression) kept before the `~`. Legal
  choices: Owned for the run for a static class / `String` / unknown-type member; Disposed with it for structs, classes
  and unknown types, never for a property or a `const`. `inits` Custom counts: corlib 53 -> 29 (24 Disposed with it),
  UMP `UMPRuntime/src` 45 -> 9 (36 Owned for the run; the 9 left are instance members of `ModLoader`), `src` 3, `UnrealSDKCore` 0,
  ClockWork 0; every member still reads and writes back byte for byte and flips and back.
* **Types the index does not know** keep every choice; the Ownership row (Properties and Add Variable) shows
  "(type not indexed)" under it.
* **Construct node pin defaults** for set-on-create variables come from the variable's Initial value (its `MemberInit`),
  not the text of the initializer clause: `= 2.5f` gives `2.5f`, `= new .(3) ~ delete _` gives `new .(3)` (it used to
  carry the `~ delete _`), no value gives `default`.
* Notes: the Add Variable dialog has the Ownership rows and the **Set on create** checkbox (one create call,
  `AddFieldSetOnCreate(type, T, name, MemberInit, on)`); the duplicate `var:` capture step is one;
  session step 25 writes the class's plain `public this()` next to the create constructor so a scratch `Main` with
  `scope Greeter()` (the debug step) still compiles.

## 2026-10-11: Set on create

User request: "Variables should be marked as exposed on spawn like with Unreal. This fixes the
one-constructor thing."

* **Set on create** checkbox on a variable (Properties, after *Default Value*, and the Add Variable dialog): creating the
  object asks for the value. The marked variables become the parameters of one create constructor the editor owns, found
  by its marker line `// VisualBeef: set on create`:
  `public this(float speed, String name) { mSpeed = speed; mName = name; }` (variable order, names from the variables;
  clashes and reserved words refused). One undo step per change; with no constructor it is created, the last unmark
  removes it. A same-signature constructor written by hand is refused. Structs too.
* **Read-back**: the checkboxes are read from the file; a hand-edited create constructor shows "custom constructor" with
  the checkboxes disabled and a tooltip.
* **Construct node** spawns one input per constructor parameter (the create constructor, or a class's only constructor with
  parameters); a set-on-create input starts with the variable's initial value or `default`.
* Tests: `classes` 178 -> 216 checks (mark one, two, unmark, clash, reserved name, hand-written clash, custom read-back,
  struct, Add Variable as one undo step, K&R file), `VB_SELFTEST=session` +6 (step 22, compile green with the call
  written), vocabulary 0 hits.

## 2026-10-11: Ownership and initial values

The owner: "for a class property I can put `new .() ~ delete _`, but that is not going to work
for people who don't understand Beef." A member variable's initializer and destructor clause are now two choices,
**Ownership** (Owned, made here `= new .() ~ delete _`; Owned, set later `~ delete _`; Reference; Pointer `T*`;
Appended `= append .()`; Value for structs `.()` / `default`; Custom, kept as written) and **Initial Value** (a number,
true / false, a character or text with escapes, an enum member from the index, `default`, `null`, an expression), with
only the choices legal for the type and the Beef shown under the rows. The same choices in the Add Variable dialog
(defaults: class owned, value none) and for a Local Variable node's unwired value. Core: `MemberInit`,
`SourceDocument.ReadMemberInit` / `SetMemberInit` (only that member's text changes, one undo step); `T x ~ delete _;` is
parsed as a member variable (`DtorTok`). Read and write are byte for byte on every member of corlib, UMP and ClockWork
(4,250 members; Custom: corlib 53, UMP 48, ClockWork 0), each also flipped to another choice and back
(`VisualBeefTests inits`). Tests: `classes` 143 -> 269 (the ownership group), `parser` +7 (destructor clauses), session
step 21 (owned -> reference, an int value, an enum member, undo).

## 2026-10-11: No silent writes

Found while building Set on create: a Construct set to `scope` and wired into a call's
Receiver was "not written". It could not be reproduced in Core: `scope Greeter(1, null).Ping();` is written (also for
`scope::` and `new`), reads back to the same nodes, and compiles and runs (Beef applies `scope` to the construction
and the call runs on it, so no hoisted local is needed; the lifetime tests and `VB_SELFTEST=session` step 24 check it).
What was real: forms the writer could not express were left out or written as text that cannot compile, without a
word. Now each is an error on the node (the commit is refused, the file is unchanged) or a warning:

* A Construct without a Type (`.`) wired into a Receiver (a call, Get, Index or Set target): error "A Construct without a Type cannot be used as a Receiver...".
* A new Local Variable / For Each without a name, a new Call or Get without a name (an empty-named call that has a Receiver is an Invoke and stays), a Cast without a type: errors.
* The type rules (`void` local, `var` cast) were written but never run (`CheckNodeType` had no caller): now run in the validator.
* A node the flow never reaches writes nothing: warning "Not connected to the execution flow..." on it. An empty Code node: warning.
* `savecheck` fails a refused commit that has no error and no message; `lifetime` has 17 new checks (a table of unexpressible configurations).
* Also fixed: the session self-test stopped at step 43 (an earlier change left `return true` there), so the constructor and Context Sensitive steps never ran.

## 2026-10-11: 0.1.4

Three changes (details in the next three entries): node errors stay with their node and Local Variable nodes follow type edits; constructors with parameters and always-present default constructor/destructor rows; the Context Sensitive checkbox is always in the Node menu. Also: two constructor Sheets are titled with their signature, and a plain `.()` Construct no longer says "custom allocator". Counts after the merge: `classes` 179, `diagnostics` 49, `parser` 289, `catalog` 219, `debug` 47, `VB_SELFTEST=session` 68 (steps 21 local types, 22 constructors, 23 Context Sensitive; renumbered from the three branches) plus 14 `debug`.

## 2026-10-11: Node errors stay where they belong; nodes follow type edits

Two user reports (0.1.3):

* **"The error carries over into the new node."** A compile error was shown on a node; the node was deleted and a
  new one placed, and the new node (or the statement that moved into the deleted one's place) showed the old error.
  Root cause: `DiagnosticMap.Resolve` looked the message's node up by its cached id and, when that id was gone, fell
  back to `LayoutKeys.Reconcile`, whose last rule matches "the same structural path with a different content hash"
  (meant for the saved positions of an edited statement). After a delete, `KeyAssigner` gives the deleted node's
  path (`s1`) to whatever now stands there: the next statement, or the node just placed, so that node took the
  message. The cache also compared the graph object's address, which the allocator can reuse. Now a message is
  followed by node identity while the Sheet is the same graph (`Graph.Serial`, not the address): a deleted node's
  message goes nowhere and `Diagnostic.NodeGone` is set (the Problems row shows a dimmed bin icon); in a Sheet built
  again it is found by content only (same statement, or the same statement moved), never by position alone
  (`FindByKey(..., samePlaceEdited: false)`; breakpoints keep the old rule).
* **"Switching the type of a Local Variable's constructor and compiling: the Local Variable node doesn't update."**
  Pin types are worked out by `GraphBuilder` when a graph is built; a kept graph (every Sheet after a commit) only
  took the new text's line numbers and trivia (`RefreshFromCode`), so `let a = scope Foo();` changed to `Bar` kept
  `Foo` on the Local's variable and value pins (and its header colour), `Bar b = .();` typed to `Foo` kept `Bar`,
  and a `var` local from a call kept the old return type after the called function's signature changed (the body of
  the caller did not change, so its graph was kept without a rebuild). Now `RefreshFromCode` copies the pin types of
  every node the new text confirms (`CopyPinTypes`; wire-unified pins keep theirs), and a kept graph whose body did
  not change but whose file did (a signature, a type, an outside edit) gets the same pass (`RefreshPinTypes`). A
  `let` / `var` Local now shows the type it holds after the keyword (`let (Bar)`).
* Safety valves (not the cure): **Reload Node** in the node right-click menu (`SourceDocument.ReloadNode`: pin
  types and the node's own messages from the function as it is now) and **Graph > Reload Sheet**
  (`SourceDocument.ReloadGraph`: the Sheet built again, positions and unconnected nodes kept, one undo step).

Tests: `diagnostics` 31 -> 49 checks (delete then place a node at the same place and elsewhere, the neighbour that
moves up, insert before, undo, a reopened file, an edited node); `edits` scenario 23 (20 checks: Construct type, a
local's Variable Type, a `var` from a call whose return type changes, undo / redo, Reload Node / Reload Sheet);
`VB_SELFTEST=session` 41 -> 56 checks (17b: the print with the compile error deleted, a new print placed and typed,
no node shows the error, Problems marks it, three undos bring it back; 21: a Local's Construct type and Variable Type
changed, pins and header colour follow, undo restores, file as saved).

## 2026-10-11: Constructors

User request: "You can add multiple constructors to classes; all classes should come with a default
constructor/destructor, these should just be present." And: a new class should not come with `Update()`.

* **Several constructors per class**, with parameters: FUNCTIONS **+ > Constructor...** opens the Add Function dialog in
  constructor mode (access, parameters with the usual type checks, `params` / `ref` / `out`, and a **Chain to another
  constructor first** picker offering the parent's constructors and this class's own others). Writes
  `public this(int a, String b) : base(a) { }`. The same parameter types as another constructor are refused with the existing
  one named; Properties edits a constructor's parameters like a function's (`SetSignature` handles `this`, keeps the chain,
  refuses a duplicate signature); the Outline lists `Constructor (int, String)`. Static constructor and destructor stay single
  (the refusal names the existing one).
* **Default constructor and destructor always present**: every class and struct row in the Outline shows `Constructor ()`
  and `Destructor`, dimmed with "Not written yet; open it to add it". Opening one writes the empty member after the fields and
  before the other functions, in the file's brace style, as one undo step, and opens its Sheet. Deleting a written default
  puts the row back to dimmed. Interfaces, enums, extensions and static classes do not get them.
* **New classes are empty**: the class template no longer writes `this()` and `Update()` (the UMP mod template is unchanged).
* Tests: `classes` 143 -> 178 checks (two constructors, duplicate refusal, chaining text, parameter edits, defaults materialising
  and un-materialising, parent constructors for the picker, the empty class template), `VB_SELFTEST=session` 41 -> 48 (step 21),
  vocabulary 0 hits.

## 2026-10-11: Context Sensitive is back

* The Node menu's **Context Sensitive** checkbox is always in the header. It used to be drawn only when the menu was opened by dragging off a pin, so a menu opened with a right-click on the empty canvas (no pin) showed no checkbox at all. It is now right-aligned from its measured width (no fixed offset, so any window width or display scale keeps it in view), enabled when there is a pin context, and disabled with the tooltip "Drag from a pin to filter by what can connect" when there is none. Filtering is unchanged and the choice is remembered for the session.
* Tests: session steps for a pin drag (context on, filtered rows fewer than unfiltered) and a menu with no pin (nothing filtered); `menu-pin` capture step.

## 2026-10-11: 0.1.3

* Debugger phase 1: breakpoints on nodes, Start Debugging, stops shown on the Sheet with pin values and Locals, Step Over, Continue, Debug Output.
* Type fields accept only what fits: every type field has a slot (Return, Parameter, Member, Local, For Each, Cast, Construct, Base) and the picker lists only types valid there.
* Node menu: one merged category tree and distinct ImGui IDs per row (no "conflicting ID" error when hovering a namespace such as IO).
* Kept graph follows a header-only edit (return type typed in the source).

## 2026-10-11: Type fields accept only what fits

The Return Type picker offered `var` and hid the function; "no fake return types". Every type field
now has a slot (Return, Parameter, Member, Local, For Each, Cast, Construct, Base) and one rule set,
`TypeSlotRules`: `void` only as a Return Type (or `void*`, `Result<void>`), `var` / `let` only for locals, For Each
elements and `[Comptime]` returns (and a mixin's parameters), `Self` only inside a type, generic parameters only when declared,
`params` / modifiers only where they belong. The picker lists only what fits (plus the declared generic parameters), a typed
type that does not fit shows "'x' is not allowed here: <why>" and is not applied, the Add Function / Variable / Property /
Indexer dialogs and the generic list say the same, and `SetSignature`, `AddMethod`, `AddField`, `SetMemberType`,
`AddProperty`, `AddIndexer`, `SetGenericParams` and `SetBaseList` refuse an illegal type with the reason and write nothing.
A file edited by hand: `Member.GetDeclError` covers return types, parameters and member variables (Outline row red, Problems
lists variables too), and local, For Each, Cast and Construct nodes get a node error (a warning when read from code).
No false positive on corlib, UMP and ClockWork (`VisualBeefTests decls <folders>` prints every declaration error). Tests:
`parser` now 289 checks (49 new), `VB_SELFTEST=session` 38 -> 41 checks (an illegal `var` return and a `void` variable
typed: error text, file unchanged).

## 2026-10-11: Node menu IDs

User report (0.1.2): an ImGui error ("conflicting ID") when hovering **IO** in the Node menu. The
search results drew every category string as its own top-level row, in score order, so a namespace that two results
reached non-adjacently (`System | IO` ... `Math` ... `System | Collections`) got a second **System** row with the
same ImGui ID, and a name such as `IO` under two parents depended on the scope it was drawn in. A scripted
reproduction of the exact collision was not obtained (the repeat needs the user's project), so the fix removes the whole class.

* **One row per path**: the menu results are drawn from a tree keyed by the full path (`MergedCategory`,
  `VisualBeefCore/src/Catalog/MergedCategories.bf`). `System | IO` and `System | Collections` are children of ONE `System`
  row, however many sources (corlib, an SDK, the project) contributed them or in what order; `MyMod | IO` stays under
  `MyMod`. Every tree row's ID is its full path (`IO##grp|System|IO`), every item row keeps its own ID scope. Labels are unchanged.
* **Other lists**: dropdown rows of the shared combo (`PropertyGrid`) and the flow-target list get a per-row ID scope;
  the Outline, Output Log, Find Results, Project Browser path bar, Type Settings and Override lists already had one.
* **Tests**: `catalog` +12 checks (two sources for one namespace, the same leaf under different parents, a namespace that is
  also a category of its own, a dotted type name, distinct paths); `VB_SELFTEST=ids` opens the Node menu on a project with
  two `File` classes in `MyMod.IO` / `MyMod.Net` and an `IdProj.IO` class, walks seven searches and the Library tree drawn
  open (21,060 rows), and requires every row ID in a frame to be distinct.

## 2026-10-11: Linux (WSL2) first run

VisualBeef built and ran on Linux for the first time (WSL2, Ubuntu 26.04, WSLg), with Beef built
from `master` (`8bd578c5`, LLVM 22.1 from the distribution, 3 min). See [Linux.md](Linux.md).

* **Tests**: every suite except `debug` passes on Linux with the Windows counts (`compile` 42/30/12, `catalog` 207,
  `savecheck` and `debugmap` identical; roundtrip / orphans / loadall over UMP and ClockWork 0 failures).
  `scripts/linux-ci.sh` builds VisualBeefTests and runs them all.
* **Editor**: the `session` self-test (New Class to Compile to reopen) passes under WSLg, 38 checks.
* **Portability fixes**: `Win32Raw` has POSIX versions (`PosixRaw.bf`) so the session log and recovery journal
  work; UTF-16 paths through `Utf16Text` (wchar_t is UTF-32 on Linux); `LibraryIndex`, the project contract, the
  node menu and preferences build paths with the native separator; BeefLibs from `VB_BEEF_LIBS` or next to the
  BeefBuild on `PATH`, the symbol cache in `~/.cache/VisualBeef/index`.
* **Saving on Linux** is now atomic with a `.bak` (`.tmp`, fsync, `rename`) and refuses a read-only file; it
  used to write the file in place with no backup.
* **Native host**: the Linux Open dialog starts `zenity` with `fork` + `execvp` instead of a shell command line
  with the folder pasted in (the shell-injection item of the audit). `Native/build_linux.sh` compiles in parallel
  and uses ccache. The editor copies `assets/` on Linux too.
* **Not on Linux yet**: the debugger (no shared IDEHelper, no LLDB), crash reports, the Recycle Bin, mandatory
  file locks, raising the window, a package.

## 2026-10-11: 0.1.2

Version 0.1.2 = 0.1.1 plus the change below (a member the parser could not read vanished from the Outline, found by the user in a real project).

## 2026-10-11: Unparsed members are kept

Found from a user's file: `public static var Main()` (the Return Type list offered `var`) made the
parser keep `Main` as a hidden text member, so it vanished from the Outline and the graph, and its compile error opened
nothing. The text was not cut by a save (saves splice the edits into the read text; the missing `Run()` matches a
member delete), but a member that cannot be seen cannot be fixed. See
[Files-and-Safety.md](Files-and-Safety.md#unparsed-members-are-kept).

* **Parser**: `var F()` / `let F()` parse as functions (`[Comptime]` corlib functions return `var`); a declaration that looks
  like a function or member variable but does not parse becomes a Broken member with its exact text and a message
  (`UnreadableDeclaration`). All BeefLibs, UMP and ClockWork still parse with `broken=0`.
* **Declaration errors**: `Member.GetDeclError`; `var F()` outside `[Comptime]` and `let F()` put an error on the entry node
  (cleared when the Return Type is fixed, also on a kept graph).
* **Outline**: unreadable members are red rows (`Name (unreadable)` or `unparsed member at line N`) with the parser's
  message; functions with a declaration error are red with the message in the tooltip.
* **Problems**: lists every unreadable member and declaration error of the project (`ProjectIndex` keeps them per file)
  without a compile. A click on any row whose line is in no graph opens Beef Source > File at that line; a line in an
  unreadable member opens its red read-only node. Compile messages in such members are mapped to them.
* **Type picker**: no `var` / `let` for a Return Type, parameter, member variable, Construct or Cast (only local variables and
  For Each elements); the Return Type offers `void`. Add Function / Add Variable refuse `var` / `let`.
* **Tests**: `parser` gains the recovery cases (the report file, `[Comptime] var`, a keyword as a type, a `var` member variable,
  a nameless member, forms that must stay text); `safety` group 18 runs the new `savecheck` on crafted files; `savecheck
  <folders>` (load + save byte for byte, a graph edit and an added member variable keep every other member) is in the full
  run; `VB_SELFTEST=unreadable` checks the Outline / Problems / jump paths in the editor.

## 2026-10-11: Debugger phase 1

Debug a standalone Beef program from its Sheets ([Debugging.md](Debugging.md)):

* **Beef's own engine**: `IDEHelper64.dll` from the Beef install (the DLL the Beef IDE drives; not `Beef042Dbg64.dll`,
  which is the runtime's debug allocator), loaded at run time through the IDE's C API (exports checked with
  `dumpbin`). `Targets_Create` must run before `Debugger_Create` (the engine crashes otherwise); the symbol-server
  "disable" flag also stops reading the program's own PDB, so the server list is empty instead. Not bundled: without
  the install, "Debugging needs Beef 0.43.6 installed". Licence notes in `THIRD_PARTY.md`.
* **Breakpoints on nodes**: a circle on each node's corner (click or F9), saved per workspace in `settings.json` by the
  node's content key. Values have the line of the statement that uses them; a function's entry node breaks when it starts.
* **Start Debugging (F5)** compiles in Debug (BelowNormal), runs the startup project (the IDE's Debug command rules),
  and stops on the node: yellow outline and arrow, the Sheet opens on it, its pin values beside the pins, any pin's
  value on hover. Continue, Pause, Stop (Shift+F5), Step Over / Into / Out (F10 / F11 / Shift+F11; Step Into stays in
  the workspace's files). Locals, Call Stack and Debug Output panels; "Running" / "Stopped at Greeter.Hello" in the
  status bar; a fault stops at its node and goes to Problems; the exit code is logged.
* **Core**: `VisualBeefCore/src/Debug/` (`DebugEngine`, `DebugSession`, `DebugMap`, `DebugTarget`); attach is one call
  (`DebugSession.Attach(pid)`) for phase 2.
* **Tests**: `VisualBeefTests debugmap` (node <-> line on the corpus) and `debug` (the `Debuggee` fixture built and
  debugged, with a fault and a Pause: 47 checks), `VB_SELFTEST=session,debug` in the editor. The default dock layout version is 5 (the new panels).

## 2026-10-11: 0.1.1

Since 0.1.0 (`VisualBeefInfo.Version` is `0.1.1`; the UMP contract is still 1).

* **Verdict session self test** (`35a5b45`, merge `06b5c57`): `VB_SELFTEST=session` drives the editor through the calls the UI
  makes, on a scratch project (a new class, nodes from the Node menu, Save, Compile, undo / redo, delete, close and reopen), then `reload-check` in a second process. See [Testing.md](Testing.md).
* **Editor pixel fixes** (`35a5b45`, `06b5c57`): the pixel pass of the verdict session. `VB_UI_SCALE` (for example `1.25`) replaces
  the monitor's display scale, so the editor can be checked at 125 % or 150 % without changing Windows settings.
* **Allocation dropdown fits** (`4209ec2`): the Lambda / Construct Allocation box shows the bare keyword when its label is cut
  (the full label is the tooltip).
* **Doc images recaptured** (`4209ec2`): the SDK node menu and out pin images show the current vocabulary.
* **Scope-list delete fix and lint** (`7857a8f`, see the entry below): `scripts/lint-scope-delete.ps1` runs before every
  release build.
* **Licence texts** (`2f02cde`): the real mingw-w64 `winpthreads` COPYING text ships in `THIRD_PARTY\winpthreads-COPYING.txt`.

## 2026-10-11: Deletes of scope lists

`7857a8f`. `NodeMenu.bf` and `PropertiesPanel.bf` ran `DeleteContainerAndItems!` on lists allocated with `scope`, which frees
the list itself (stack memory) on the heap: a `0xc0000374` heap corruption in Release builds. Both use `ClearAndDeleteItems!`
now. `scripts/lint-scope-delete.ps1` (shared with UniversalUMP, where the same bug crashed every injected game launch) fails on
any delete of a scope-allocated object; `scripts/package.ps1` runs it before the build.

## 2026-10-10: Compile status indicator

`8688574`. The Compile button, the status bar and the Problems panel show one state per workspace: neutral "Not compiled"
(never compiled), green check "Up to date" (the sources are unchanged since the last successful compile, also after
the workspace is closed and loaded again), yellow "Needs compile" (the sources changed since), red "Compile failed (N errors)".

* The last result and a content hash of the workspace sources are persisted per workspace in `settings.json`; the state is
  derived by comparing the hash, so it is right on load without compiling.
* The Node menu favourites file `action_menu.txt` is renamed to `node_menu.txt` once on first load (migration).

## 2026-10-10: Own vocabulary (naming pass)

`9c3c503`, merge `9ed9895`. No Unreal terms where a user can see them: UI, docs and error messages use VisualBeef's own words.
**Sheet**, **Outline**, **Type Settings**, **Properties**, **Project Browser** (and its Drawer), **Node menu**, **Receiver**
(`this`), **This** and **Base** nodes, flow pins, Value call, Return, Tick override.

* Files and classes renamed to match (`NodeMenu`, `TypeSettings`, `ProjectBrowser`, `PropertiesPanel`, `Outline`, `Look`).
* Layout hashes, pin ids and node kind numbers are unchanged, so existing `.vblayout` files still match. The attributes
  `ExposeType` and `ExpandEnumAsFlow` are the new names; the old names are still read.
* New [Vocabulary.md](Vocabulary.md) (the glossary and the words not to use), [Calls-and-Receivers.md](Calls-and-Receivers.md)
  and a `vocabulary` test that fails on an Unreal term in the string literals of the sources, the manual or the README.

## 2026-10-10: Release packaging

`0112689`, merge `e0e5cbf`. `scripts/package.ps1` builds `dist/VisualBeef` and a zip: the Release exe (`VisualBeefEditor.exe`, with an icon and a
VERSIONINFO resource), `vbhost.dll`, `VERSION.txt`, `LICENSE`, `NOTICE` and the licence texts in `THIRD_PARTY/` (including the mingw-w64
`winpthreads` text that was still missing), and install docs. This is the package UnrealUMP bundles under `tools\VisualBeef`.

## 2026-10-10: Polish and robustness

Merge `0829f4e`.

* **Node menu off the UI thread** (`63c5af4`): library catalogs are built on the indexer (`NodeCatalog.Prebuild`) and adopted on
  the UI thread (Screech 123 -> 2.0 ms, Hogwarts 445 -> 3.8 ms); the category tree 470 -> 7 ms / 1116 -> 21 ms, warmed right
  after indexing; search reuses the last query's matches when the query only grows; the menu waits 80 ms after the last key.
* **Find References** (`8b9a6f3`): Shift+F12 and the Edit menu list every reference by file and line (overloads, overrides and
  interface members are listed, not refused; maybe-matches flagged) in a Find Results panel. Editor self tests
  (`VB_SELFTEST=rename-undo,move-undo,find-refs,openall`) confirm that a multi-file rename and a node move undo.
* **Overload choice** (`60f9dda`): an ambiguous call lists the tied overloads in Properties; picking one writes a cast on the
  argument that tells them apart, and refuses (with the reason) when only `out` / `ref` differ.
* **Robustness** (`3b47427`): the `loadall` command opens every project file like the editor and checks graph invariants (UMP
  root: 272 files, 2084 functions, 0 failures); the editor opened and drew all 2084 in tabs without a crash. Static classes may
  derive from static classes (a false class error). Safety groups 14 and 15 cover a read-only file, a denied folder and a locked file.
* **Text forms and `#if`** (`e3a8002`, `53610ce`): Scope blocks, const / ref locals, `(.)` casts, `.()` values, `repeat`, local
  functions, lambdas and delegates with captures, `event +=`, payload switches, Format (interpolated string holes) and statement
  attributes are nodes; UMP bodies with no text 94.0 % -> 98.4 %. Methods in `#if` / `#else` arms get their own keys (corlib
  roundtrip 172 -> 0 failures); the Entry subtitle and Outline show the arm.
* Docs: text forms, `#if` keys, node menu timings, Find References, overloads, `loadall`, self tests; `Testing.md` counts match the
  final run (`34518dc`: 162 files / 1,366 methods, `loadall` 286 files, coverage 99.6 %).

## 2026-10-10: UMP integration

`702bca9`. [UMP-Integration.md](UMP-Integration.md).

* `EditorArgs` / `ProjectContract` (VisualBeefCore): `<folder-or-file>`, `--file`, `--view`, `--new-ump-mod` (`--mod-id`,
  `--namespace`, `--class`, `--mod-name`, `--version`, `--game`), `--version`, `--help`; exit codes 0 / 1 / 2; the `.vbproject`
  marker names the main file; VisualBeefInfo 0.1.0, UMP contract 1.
* `TypeTemplates.MakeUMPMod` is the source of truth for UnrealUMP's visual mod template (`using UnrealUMP.Unreal`, escaped literals).
* `LibraryIndex.Discover` loads generated SDK libraries that a workspace dependency path points at; absolute paths are
  normalised. Pin labels drop a leading `@` (UMP SDK parameters).
* Test hook `VB_DEBUG_NODE_MENU_SEARCH`; `VisualBeefTests ump [-sdk <dir>]`.

## 2026-10-10: Class model, lifetime nodes and Type Settings

Merges `c507d23`, `3227f41`. Closes the gaps named in the production audit.

* **Class model** (`075fed0`, `54a46b2`, `8bfd4aa`, [Classes-and-Members.md](Classes-and-Members.md)): the parser records
  declaration spans; property and indexer accessors are graphs; `ClassEdits` change modifiers, visibility, inheritance,
  attributes, kind, base list, generics, constraints, namespace and members as token-range splices (one undo step);
  `ClassModel` knows base class, interfaces, overrides and missing members; the **Parent** (base) node; project-wide renames
  with a preview that refuse what they cannot resolve; Type Settings, an Override dropdown, member options and a create flow
  with parent class and interfaces in the editor. `classes` test (141 checks, later 143).
* **Lifetime nodes** (`befc22f`, `0b7b7c1`, [Lifetime-Nodes.md](Lifetime-Nodes.md)): Construct, Delete, Defer, Using and Result
  match, with lifetime rules (a scope value after its block, returned, deleted; defer order; `new` with no owner), byte-exact
  round trips, and `coverage` and `lifetime` test commands (92 checks).
* **Call model** (`16dccf9`, `6114649`, `41a17ec`, `66be1b5`, `80d485b`, [Calls-and-Targets.md](Calls-and-Targets.md), now
  Calls-and-Receivers.md): calls record how they bind (static, instance, unresolved); a member call has a Target pin and an
  unconnected one means self; `out` parameters are output pins written in Beef 0.43.6 syntax (`var name`, `?`, hoisted
  `T name = default`); `GraphValidator` runs first in code generation and the editor shows its errors and warnings on nodes;
  graphs are checked when first shown; no save while a built graph has errors.
* Compile cases cover the class hierarchy with an interface, Event Tick from the Override dropdown and an override without a base
  (refused) (`1c11df7`).

## 2026-10-10: Indexing and editor shell

Merge `19513ef` (with `201dd3c`).

* **Indexing**: generated SDK libraries under the root are indexed as cached libraries (content-keyed `sdk-<hash>.bin`),
  rescans reuse files whose size and mtime did not change, and `IndexJob` runs on a worker thread (up to 4 libraries in
  parallel) with status-bar progress and cancel. UMP root: 16.0 s on the UI thread -> 0.42 s warm in the background.
* **Compiler diagnostics**: BeefBuild, MSVC and clang output is parsed and mapped line -> method -> node by content key;
  errors and warnings show on nodes and in the Problems panel with jump-to-node.
* **Shell**: settings in `%LOCALAPPDATA%\VisualBeef\settings.json` (`VB_HOME` overrides the folder), a session log and a crash
  handler that writes a crash log and a minidump, a recovery journal of unsaved documents ("Recover unsaved changes?" on the next
  start), Debug / Release compile dropdown (default Release for UMP mods).


## 2026-10-10: Production audit for UMP integration

A production audit (not part of the public repository): the owner's five gaps (Target pin / self / static, class model and
inheritance, `new` / `scope` / `defer`, `out` parameters as output pins, everything else) checked against
the code, with measurements: test suites green; `roundtrip` and `orphans` over UMP's launcher, runtime and
SDK core sources (146 files, 1,073 methods) 0 failures; 72 % of those method bodies open with no Code
node; SDK indexing 4.3 s (Screech) / 9.0 s (Hogwarts) on first sight and 14.1 s to open the UMP repo
root, all on the UI thread. One hazard found: a catalog instance call with an empty Target is written
as an implicit-`this` call without checking the enclosing type. `docs/Roadmap.md` is rewritten around
the goal (a visual UMP mod end to end) with three milestones, Milestone 1 split into six parts.

## 2026-10-10: Apache-2.0

VisualBeef is now licensed under the Apache License, Version 2.0, the same as UnrealUMP, replacing
the all-rights-reserved notice of the previous commit. `LICENSE` is the Apache-2.0 text (identical to
UnrealUMP's), `NOTICE` carries the attribution and points at the statically linked components.
`THIRD_PARTY.md` gains a row and a section for the mingw-w64 runtime (`winpthreads` is inside
`vbhost.dll`; its exact COPYING text still has to be copied from the toolchain that built the DLL).

## 2026-10-10: Discarded `Result` audit

Beef calls `ReturnValueDiscarded()` when a statement throws away a `Result`, and a discarded
`.Err` is a fatal error (`Unhandled error in result`); there is no compiler warning. The Content
Browser crash (`Path.GetDirectoryPath` at a drive root) was one instance. Audited every
statement in Core, Editor, Tests, Meta and Native against the project's own `Result` methods and
the corlib ones in use.

* Discarded sites found: 23 bare `Path.GetDirectoryPath` calls, 3 `Environment.GetEnvironmentVariable`,
  1 `Path.GetTempPath` and 10 `SourceDocument.Load` in `SafetyTests`. Everything else already
  matched, bound or `.IgnoreError()`d. Each is now `.IgnoreError()` with a comment where an empty
  out string is already handled, or checked (`case .Err`) in the upward walks in `BuildRunner`,
  `ContentBrowser` and `Icons` so they stop at a root.
* New `AssetOps.TryGetParent` (false at a root); the Content Browser's remembered-folder walk uses
  it. Safety 10 has a regression test: no parent at `C:/`, `C:\`, `/`, empty, `Z:/`, UNC; a full
  upward walk terminates; project lookup under a missing drive is empty.

## 2026-10-10: Mouse in the action menu

Report: keyboard fine, mouse "nigh impossible", especially placing nodes; the action menu
"looks like it's being drawn a ton"; nodes could only be placed with the keyboard.

* **Action menu re-filtered every frame** (`ActionMenu.Draw`, from `eaeeb7e5`): it compared
  `mCatalogGeneration` with `Types.Generation` but only `CatalogItem()` synced it, and browsing
  with an empty search never builds a catalog item. So every frame it re-ran `Refilter`,
  re-forced every category's open state (`SetNextItemOpen(.., Always)`), re-picked the
  highlight and scrolled to it: categories could not be clicked open, the wheel fought the
  auto-scroll, arrow keys were reset. Now `SyncCatalogCache()` syncs the generation where it is
  checked.
* **Search box stole the click** (`ActionMenu.Draw`): "keep typing going to the search box"
  re-focused the search field on any frame where no widget was active. Pressing a row
  deactivates the search field, so the next frame grabbed focus back and took the active id
  from the row being pressed; a click held longer than a frame or two never registered (only
  Enter placed a node). It now never re-focuses while a mouse button is down.
* **Idle pacing**: the 1.2 s hold now restarts on any input ImGui processed
  (`Desktop.NoteActivity`), not only when `WaitForInput` woke the loop, so a frame right after a
  popup closes or a drag ends no longer sleeps with input still queued (trickled events).
* **A/B switch**: `VB_NO_IDLE=1` or Preferences > Graph Editor > Idle Frame Pacing turns the
  idle loop off (render every frame); the mode is logged to the Output Log at start-up.
* Verified with window messages only (no global input), held clicks of ~120 ms: right-click
  opens the menu once, hover follows, a category expands and collapses, a row places a node and
  the menu closes, a second right-click re-opens it. With the search-focus guard removed, the
  same held clicks did nothing (A/B). Idle CPU after the run: ~0 (0.016 s of CPU in 5 s).

## 2026-10-10: Phase 1 consolidated ("Feels like Blueprints, and is safe")

Six areas of work, plus a consolidation
pass. Baseline was `e897cea` (the code at the start: builds clean, edits 30/30, roundtrip 0 failures
on the UMP sources); an audit of 2026-10-09 (not part of the public repository) set the plan.
State at the end: Debug and Release build with 0 warnings; all suites green (counts in
[Testing.md](Testing.md)).

### Safety (`c9c74f8`, docs `877d52b`) - [Files-and-Safety.md](Files-and-Safety.md)
* **Viewer mode**: `--view`, **Open Project (Read-only)**, and a toggle. Every write is refused with a message.
* Merely looking writes nothing: no `.vblayout` on open, auto-layout or scrolling; a sidecar is written
  only when its content changed.
* **Atomic saves**: temp file, flush, `ReplaceFileW`, one `.bak` kept (switchable). A failed write
  leaves the original.
* **Conflicts**: a fingerprint of the file as loaded; saving a file that changed on disk offers
  Overwrite / Reload / Cancel instead of overwriting silently.
* **Delete goes to the Recycle Bin or does nothing** (no permanent-delete fallback); the `.vblayout`
  goes with the file.
* Rename and delete of a type write only that change and refuse if the file has other unsaved edits.
* Dirty state follows the saved text (undo back to saved clears the `*`); node moves, comment
  moves / resizes and knot drags are undoable (one step per drag).
* Creation goes to the right project `src` folder, in the neighbours' namespace, unique per namespace.
* Tests: `safety` (12 groups).

### Parser (`72f3e94`, merge `bc94041`, sidecar unification `a71eb6b`) - [Parsing-and-Layout.md](Parsing-and-Layout.md)
* **Error recovery**: strict bracket matching; a damaged member becomes a `Broken` member that keeps its
  exact text; the rest of the file parses normally. Shown red and read-only in the graph and in
  My Blueprint, with the error as the tooltip. Previously one unbalanced bracket hid every later member.
* **Content-keyed layout**: positions keyed by `path#contenthash`, matched exact / moved / edited on load,
  so editing the file in a text editor no longer shuffles node positions. Old positional sidecars are
  migrated; stale entries pruned; unknown lines preserved; single `#vblayout 2` header.
* **Literal kinds**: `1.0` is `double`, `1.0f` is `float`, integer suffixes, interpolated, verbatim and
  raw strings. Nested block comments in the lexer (found by running corlib).
* Tests: `parser` (187 checks); `roundtrip` reports `broken=N`.

### Codegen (`b75d4ce`, merge `ed0b602`) - [Codegen.md](Codegen.md)
Rule: **generated code never quietly does something different from the graph.**
* A value read by several inputs is computed once (`let __v1 = list.PopBack();`) instead of once per
  use; the parser folds such lines back into the shared node when it can.
* Branch arms that meet again write the shared tail once after the `if` / `else`; other merges that
  would write code twice are refused.
* Scope analysis: call results read after their block are hoisted; out-of-scope reads are refused.
* Only edited statements change; statements and compound headers that read back with the same
  tokens keep their original text; new code follows the surrounding style (`if (` vs `if(`, braces).
* Refusals attach errors to nodes (red border, message in Messages), `Commit` writes nothing.
* Tests: `compile` harness that edits graphs, builds with BeefBuild, runs and compares output.

### Catalog (`eaeeb7e`, merge `fe8ae07`) - [Catalog-and-Types.md](Catalog-and-Types.md), [Node-Attributes.md](Node-Attributes.md)
* **`VisualBeefMeta`** attributes: `[Node]`, `[Pure]`, `[Expose]`, `[Pin]`, `[NodeLibrary]`, `[NodeHidden]`,
  `[Conversion]`, `[ExpandEnumAsExecs]`, `[BlueprintType]`. You choose what becomes a node, as with
  `UFUNCTION`.
* **Types without a compiler**: `ProjectIndex` records namespaces, usings, visibility, attributes,
  `///` docs, defaults, generics, bases and enum cases; `LibraryIndex` finds the libraries a
  workspace uses (corlib, BeefLibs, `BeefSpace.toml` projects) and caches each symbol store
  under `%LOCALAPPDATA%\VisualBeef\index`; `TypeService` resolves types, members and overloads;
  `TypeRules` has literal types, conversions and wildcards.
* Typed pins and typed wires: dropping a wire is checked and the reason is shown; wildcard pins
  unify on connect and restore on disconnect.
* **`NodeCatalog`** and a rewritten **action menu**: fuzzy search (prefix, word start, acronym,
  substring), favourites and recents, context filtering when dragging off a pin, library nodes.
* Tests: `catalog` (197 checks), `catalog-scale`, `roundtrip -types`.

### Shell (`b59efbe`, `643648e`, `e885086`, merge `b826b33`) - [Editor-UI.md](Editor-UI.md)
* **UE5 look**: Starship theme, Lucide icon font, toolbar with Compile state badge, status bar,
  toasts, window title following the tab, dock nodes without ImGui chrome.
* Panels: UE-style **My Blueprint**, property-grid **Details** with a searchable type picker,
  **Output Log** (filters, search, build output streamed), **Compiler Results**, project-wide
  **Find in Blueprints**, Content Browser filters and drag-to-move.
* Canvas: node header icons, pin shapes (single, array, map, set), minimap, align / distribute /
  straighten shortcuts, layered **Arrange** (pure nodes under the exec wire), snap on place.
* **Editor Preferences** in `%APPDATA%\VisualBeef`; DPI-aware fonts.
* **Idle frame loop**: the editor sleeps when nothing happens (background CPU about 104 % of a
  core down to about 0.3 %).
* Find skips declaration lines; BeefBuild progress-bar mojibake is stripped.

### Flow (`84d816e`, merge `62fe092`, `c6f2012`) - [Flow-Nodes.md](Flow-Nodes.md)
* **Switch node**: `switch` becomes one node with an exec output per case, Default and Completed;
  fallthrough, `when`, ranges and payload patterns stay Code nodes that say why.
* **Flow macros as plain Beef**: Sequence, Do Once, Do N, Flip Flop, Gate (with Open / Close /
  Toggle) and Multi Gate (with Reset). Stateful ones keep a `private` field with a reserved prefix
  that the generator adds and the parser recognises by shape; look-alike code stays ordinary nodes.
* Action menu entries under Flow Control, Details editing (case list, outputs, polarity, loop,
  reset target), *For Each / For Loop with Break*.
* Codegen: arms of a Switch or Flip Flop that all meet in one node are written once after it.
* Tests: `flow` (58 checks), 12 added factory cases, 13 added compile-and-run cases.

### Consolidation (this pass)
* **Fixed: the window could stop repainting while an ImGui popup was open** (reported as the action
  menu freezing). The idle loop only knew about input and builds, not about open popups, so it could
  leave a popup on a stale frame once the ~1.2 s grace period after input ran out. It now renders continuously while any popup is open, a conflict / error dialog is queued or a
  text field is active ([Editor-UI.md](Editor-UI.md#idle)).
* **Fixed: nodes spawned together landed on top of each other.** Companions that one menu entry
  creates (the Branch and Break of *For Each Loop with Break*) are placed with the Arrange spacing
  relative to the first node (`LayeredArrange.ArrangeFrom`), and any freshly created group steps
  clear of existing nodes (`LayeredArrange.AvoidOverlap`).
* Removed dead code orphaned by the merges: the unreachable Settings popup, `Theme.NodeIcon`,
  `Gui.ColorV`, `FlowMacros.IsFlow`.
* `VisualBeefTests compile` no longer defaults to a path on one developer's machine; it uses
  `<temp>\vb-codegen`.
* Release build verified (post-build copies `vbhost.dll` and the fonts); `THIRD_PARTY.md` added
  (SDL2's zlib notice was missing).
* Documentation rewritten as a stack: [README.md](README.md), [Getting-Started.md](Getting-Started.md),
  [Architecture.md](Architecture.md), [Testing.md](Testing.md), [Roadmap.md](Roadmap.md), this file;
  root `README.md` is now a landing page.

## 2026-10-09: audit and baseline

* `760d489` Audit of the baseline against Unreal's Blueprint editor, with screenshots and a
  three-phase roadmap (from the 2026-10-09 audit).
* `e897cea` Baseline: VisualBeef as received.
