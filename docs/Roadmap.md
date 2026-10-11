---
audience: developer
title: Roadmap and known limitations
summary: Where VisualBeef is going, in what order, and what does not work yet.
order: 18
---

# Roadmap and known limitations

Where VisualBeef is going, in what order, and what does not work yet. Rewritten 2026-10-10 after
a production audit, which has the evidence (file and function references, test runs, measured
numbers) behind every item here (the audits are not part of the public repository). An earlier
audit produced Phase 1; the [CHANGELOG](CHANGELOG.md) says what
changed and when.

## The goal

VisualBeef becomes a first-class UMP feature. On the UMP launcher's Create screen you choose
**"Visual mod (VisualBeef, native performance)"**, VisualBeef opens on the new mod project, you build
the mod as graphs, and the output is plain Beef compiled exactly like any other mod: no interpreter,
no graph format, no runtime cost. The generated game SDK is the node library.

Everything below is ordered by what blocks that.

## Where it stands (2026-10-10)

* **Phase 1 is done**: the Blueprint feel and safety (lossless round trip, minimal diffs, refusals
  instead of wrong code, flow macros, switch, typed pins without a compiler, safe saves, read-only
  mode). See the CHANGELOG.
* **Measured on UMP's own code** (launcher, runtime, SDK core: 146 files, 1,073 methods): round trip
  and orphan tests 0 failures; **72 % of method bodies open with no Code node**; 86 % of data pins
  typed. The other 28 % show text mainly for `scope` allocations, `using`, `defer`, `case .Ok(let v)`
  pattern tests and `delete`.
* **Licence**: Apache-2.0, same as UnrealUMP (`LICENSE`, `NOTICE`, [../THIRD_PARTY.md](../THIRD_PARTY.md)).

## Milestone 1: "a visual UMP mod, end to end" (about 6 weeks)

The owner's named gaps first, then what UMP integration needs. Sizes: S up to 1 week, M 1-3, L 3-6.

| # | Item | Size | Depends on | Audit section |
|---|---|---|---|---|
| 1 | **Target pin / self / static.** Every instance call has a Target pin typed with the owning type; unconnected means `this` (drawn as "self"); if the enclosing `this` is not that type (or derived), or the function is static, the node shows *"Target must be a X"* and the commit is refused, exactly like Unreal. Static calls have no Target pin. A Self node writes `this.`. Live `GraphValidator`. | M | - | 2 |
| 2 | **`out` parameters as output pins**, like Unreal: `out let name` with stable names, discard when unused, hoisting when read after a block; `ref` inputs must be wired to a variable. | M | 1 | 5 |
| 3 | **`new` / `scope` / `defer` / `delete` / `using` as nodes**: Construct node (allocation dropdown, constructor overloads, arrays), Delete, Defer (runs at end of scope), Using; scope-lifetime refusals. | M | 1 | 4 |
| 4 | **`Result<T>` node**: `case .Ok(let v)` / `.Err` as exec outputs with payload pins; `Try!`; realises `[ExpandEnumAsExecs]`. | M | 2 | 6.1 |
| 5 | **Class model**: Class Settings (parent class, interfaces with generated stubs, modifiers, attributes), function options (visibility, static, virtual / override / abstract, mut, parameter modifiers), **Override** dropdown in My Blueprint that writes the override with a call to the parent. | M-L | 1 | 3 |
| 6 | **Compile in Release** for UMP mods, configuration dropdown. | S | - | 6.14 |
| 7 | **Shell hardening**: crash handler + minidump + log + autosave journal; settings and layout under `%APPDATA%`; warnings on nodes. | S-M | - | 6.2, 6.12 |
| 8 | **Indexing off the UI thread**; library projects under the root loaded as libraries (opening the UMP repo takes 14 s today); SDK cache built by the launcher after SDK generation (`--index`); search debounce. | M | - | 6.13 |
| 9 | **UMP side**: visual template kind and Create screen option, "Open in VisualBeef" (`--project`, `--ump-root`, `--game`, single instance), Build & Install; SDK emitter writes `[Node]` / `[Pure]` / `[NodeHidden]` (no `_PE` twins) / `[Expose]` from runtime flags, out-parameter marking, `[AutoTarget]` for world context, a curated category overlay. | M-L | 1, 2, 5, 6 | 8 |
| 10 | **Packaging**: `tools\VisualBeef\` in the UMP release zip, `VisualBeefMeta` in `<Root>\sdk\_core`, notices (copy the exact `winpthreads` COPYING text into THIRD_PARTY first), "Your first visual mod" guide. | S-M | 6-9 | 9 |

Exit test: on a clean machine with only the UMP release zip and Beef installed, create a visual mod
for Screech from the launcher, open it in VisualBeef, add a Tick override that reads the player's
location through SDK nodes and logs it, compile, see it run in the game, and read the Beef it wrote.

### Order of work

The audit (section 10) splits Milestone 1 into six parts with files and done criteria:
**A** call model (items 1, 2), **B** lifetime constructs (3, 4), **C** class model (5),
**D** shell hardening and scale (6, 7, 8), **E** UMP side (9, in the UnrealUMP repo),
**F** packaging and docs (10); optional **G**, a language-service spike.
Order: A lands first (B and C share `GraphBuilder.bf` / `CodeGen.bf` and rebase on A's pin
model); C's Override dropdown and D's Release compile and command-line arguments come before E's
"Open in VisualBeef" is end-to-end; A fixes the out-parameter form before E changes the emitter;
F is last, after a full green test run.

## Milestone 2: completeness (after the first UMP release)

| Item | Size | Audit section |
|---|---|---|
| Renames that update references: index-based reference finder, multi-document undo transaction (exact references later from the language service) | M | 6.3 |
| Lambdas as collapsed local-function graphs; Create Delegate; event dispatchers (`Event<>` Bind / Unbind / Broadcast) | L | 6.5 |
| Generics in signatures and the type picker; explicit generic arguments on call nodes | M | 6.7 |
| Property accessors and indexers as graphs; `=>` bodies converted on first edit | M | 6.8 |
| Attribute list in Details with typed editors for VisualBeef's attributes | S-M | 6.9 |
| Ambiguous-overload marker with an overload picker | S | 6.6 |
| Remaining text constructs: `const` locals, tuples, `when` / range / payload switch cases, interpolation, `mixin` calls, `#if` arms | M | 6.11 |
| Latent nodes (Delay, timers) on a UMP-provided scheduler | M | 8.2 |
| Viewer mode as the default for folders without the `.visualbeef` marker; layout cache under `%LOCALAPPDATA%` for those | S | - |
| A `coverage` test command (Code / Expression nodes per method, typed-pin ratio) replacing the audit's throw-away probe | S | 1 |

Exit test: at least 90 % of UMP and corlib method bodies open with zero Code nodes.

## Milestone 3: compiler brain and debugging

1. **Language service on `IDEHelper64.dll`** (the Beef compiler API the Beef IDE uses), in-process on
   a worker thread behind an interface, pinned to Beef 0.43.6: exact pin types and overloads, live
   compiler errors on nodes, exact rename references. L.
2. **Debugger on graphs**: node breakpoints (a node maps to a source line), exec-wire highlighting,
   pin values via `Debugger_Evaluate`, stepping along exec flow; for UMP mods this means attaching
   to the game process. L.
3. **Unreal-parity polish**: custom title bar, node collapse, bookmarks, compact formula nodes,
   Collapse to Function, `[Node(Compact)]` drawing, Advanced pins toggle, Make / Break nodes, Details
   sliders from `[Expose(Min, Max)]`, auto-inserted `[Conversion]` nodes.

## Known limitations (true today)

**Language coverage**

* Shown as Code nodes or text in pins: `scope` / `new` / `delete` / `defer` / `using`, lambdas, local
  functions, tuples, `case .Ok(let v)` pattern tests, property accessors, expression-bodied members
  (`=>`), `const` locals, `fallthrough` / `when` / ranges / payload patterns in a `switch`, string
  interpolation (edited as text). They round-trip exactly.
* `out let x` stays text in the argument pin; `x` has no pin (item 2).
* Implicit-`this` calls have no Target pin; a catalog instance call with an empty Target is written as
  an implicit-`this` call without checking the enclosing type (item 1; the audit calls this out as a
  meaning-changing hazard).
* Static calls show the type name as text in a Target pin.
* `#if` regions: both arms are read as live code; the indexer de-duplicates members.
* Operators, delegates and `typealias` declarations appear as Raw members.
* A stray extra `}` that closes a type early, and a type missing its closing `}` whose sibling starts
  at the same indentation, are not detected as broken ([Parsing-and-Layout.md](Parsing-and-Layout.md)).

**Types** (no compiler: [Catalog-and-Types.md](Catalog-and-Types.md))

* Unresolved types keep grey wildcard pins. Overloads are chosen by arity, then argument types.
* Wire checks are the editor's own rules; the compiler is the judge after **Compile**.

**Classes**

* No parent class, interface list, modifiers or attributes when creating or editing a type; no
  Override dropdown; function modifiers are read-only in Details (item 5).

**Editing**

* Renames change the declaration only, not references.
* Undo is per document: node moves, resizes, knots and comments are undoable (one step per drag),
  but asset rename / delete across files is not. Each step is a whole-document snapshot.
* Reopening shows the code's natural shape (a typed-in value may come back as a Get node and the
  reverse; flow-macro outputs come back as Get nodes of the field).
* A comment inside an expression is lost when that expression is really changed.
* Flow macros are recognised only by their exact shape; their state is per object.
* A statement edited and shifted at the same time loses its saved position.
* Moving an asset does not rewrite its namespace.

**Shell, scale and platform**

* Library and project indexing run on the UI thread: a game SDK takes 4-9 s the first time; opening
  a folder that contains SDKs indexes them as project files (14 s for the UMP repo).
* Compile runs BeefBuild with the default (Debug) configuration; UMP mods need Release.
* No crash handler, minidump, autosave journal or log file.
* `VisualBeef_settings.txt` and `VisualBeef_layout.ini` are written to the current directory.
* Linux is experimental: tests and the editor session pass under WSL2 (2026-10-11), but there is no
  debugger, crash report, Recycle Bin or package there yet ([Linux.md](Linux.md)).
* Per-monitor DPI changes were not tested on a second monitor; the OS draws the title bar.
* No installer or packaging; imnodes is compiled into the host but unused; `EditorApp` is very large.

## Debugger: phase 2 (attach for UMP mods)

A UMP mod is a DLL inside a game started by the UMP launcher. Phase 2 needs:

* **Attach**: `DebugSession.Attach(processId)` exists already (`Debugger_Attach`, Stop detaches and
  leaves the process running); the Debug menu entry and a process picker are the missing UI.
* **The launcher handing the pid**: the UMP launcher starts the game and injects the runtime; it
  should start VisualBeef (or tell a running one) with the game's process id (for example
  `--attach <pid>` in the [UMP contract](UMP-Integration.md)), after the mod DLL is loaded.
* **Debug builds of mods**: mods are built Release today because the game cannot load a Debug mod
  (it imports `Beef042Dbg64.dll`); a debuggable mod needs that DLL beside it or a Release build with
  debug information, and the PDB next to the mod DLL.
* **Hot reload** (`Debugger_HotLoad` in the same engine): compile changed methods and patch them into
  the running game, as the Beef IDE does with hot swap enabled.
* Pausing a game stops every thread; the attach break and the game's own exceptions need filtering.
