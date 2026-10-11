---
audience: developer
title: Documentation index
summary: Index of the developer documentation for the whole stack.
order: 26
---

# VisualBeef documentation

VisualBeef is a visual node-graph editor for the Beef language. Every graph *is* Beef code:
each function body is a node graph, edits to the graph rewrite only the statements they touch, and
edits to the text rebuild the graph. There is no separate graph format.

This folder is the manual for the whole stack. Read it in the order below if you are new; jump
straight to a page if you know what you need.

## Reading order

| # | Page | Read it to learn | Time |
|---|---|---|---|
| 1 | [Overview](#overview-and-architecture) (this page) | The idea, the layers, the one invariant | 5 min |
| 2 | [Getting-Started.md](Getting-Started.md) | Build, run, open a project, make a class, build a graph, compile, read the Beef it wrote; keyboard shortcuts | 15 min |
| 2b | [Vocabulary.md](Vocabulary.md) | The words VisualBeef uses for its panels and nodes, and the older terms they replace | 3 min |
| 3 | [Editor-UI.md](Editor-UI.md) | Every panel, shortcut and extension point of the editor | 15 min |
| 4 | [Architecture.md](Architecture.md) | Module map, data flow, threading, where state lives, how to add a node kind or a panel | 20 min |
| 5 | [Parsing-and-Layout.md](Parsing-and-Layout.md) | The parser, broken-code recovery, literal kinds, the `.vblayout` sidecar and content-keyed layout | 15 min |
| 6 | [Codegen.md](Codegen.md) | Graph to code: temporaries, merges, scopes, style, refusals | 15 min |
| 7 | [Flow-Nodes.md](Flow-Nodes.md) | Switch, Sequence, Do Once, Do N, Flip Flop, Gate, Multi Gate, loops with Break | 10 min |
| 7b | [Calls-and-Receivers.md](Calls-and-Receivers.md) | Member calls and their Receiver / this, static calls, the This node, out and ref pins, GraphValidator's errors | 15 min |
| 7c | [Lifetime-Nodes.md](Lifetime-Nodes.md) | `new` / `scope` (Construct), Delete, Defer, Using, `case .Ok(let v)` (Result: match), the lifetime rules, coverage on UMP code | 10 min |
| 7d | [Classes-and-Members.md](Classes-and-Members.md) | Type Settings, parents and interfaces, overrides and stubs, the Base node, properties / indexers / constructors as graphs, project-wide renames, new types and the UMP mod template | 15 min |
| 8 | [Catalog-and-Types.md](Catalog-and-Types.md) | How nodes are found and pins typed without a compiler; the node menu's data | 15 min |
| 9 | [Node-Attributes.md](Node-Attributes.md) | Tagging your own code (`[Node]`, `[Pure]`, ...) to decide what becomes a node | 10 min |
| 9b | [Debugging.md](Debugging.md) | Breakpoints on nodes, Start Debugging, stepping, pin values, Locals, Call Stack; how Beef's debugger engine is used; phase 2 (attach for UMP mods) | 10 min |
| 10 | [Files-and-Safety.md](Files-and-Safety.md) | What is written when; atomic saves, conflicts, read-only mode, delete, undo | 10 min |
| 11 | [Testing.md](Testing.md) | Every `VisualBeefTests` command, expected counts, how to add a case | 10 min |
| - | [CI.md](CI.md), [Code-Signing.md](Code-Signing.md) | Build and release automation, release integrity (unsigned releases, build attestations, checksums) | 10 min |
| 11b | [UMP-Integration.md](UMP-Integration.md) | How UnrealUMP launches VisualBeef: command line, exit codes, `.vbproject`, `--new-ump-mod`, game SDKs as node libraries, files needed at run time | 10 min |

Reference: [CHANGELOG.md](CHANGELOG.md) (what changed and when) and [../THIRD_PARTY.md](../THIRD_PARTY.md) (licences of
bundled components). The two audits of 2026-10-09 and 2026-10-10 that produced the plans are not part of the public
repository.

If you are going to change code, read 1, 4, then the page for the area, then 11.

## Overview and architecture

### The one invariant: the text is the only truth

A `.bf` file is the only thing that defines your program. A graph is a view of one method body:

* **Opening** a file lexes and parses it losslessly (every comment, blank line and preprocessor line
  is kept as trivia) and builds a graph per method.
* **Editing the graph** regenerates only the statements you changed. Unchanged code is copied
  verbatim, so comments, spacing and style survive and a one-node edit gives a one-line diff.
* **Editing the text** (in the Beef Source panel, or in any editor) rebuilds the graph.
* **Unsafe graphs are refused**, not approximated: if a graph cannot be written without changing what
  it does (a value evaluated twice, code that would be duplicated, a read outside its scope), nothing is
  written and the node at fault says why.
* Code the graph does not model stays text: it becomes a Code node holding the exact characters.

### What a sidecar is

Some things a graph needs are not code: where each node sits, comment boxes, reroute knots, and
nodes you have left unconnected. VisualBeef keeps them in a **sidecar** text file next to the source,
`Player.bf.vblayout`. Entries are keyed by a node's position in the code plus a hash of its content,
so editing the file by hand does not shuffle positions. The sidecar is optional and disposable:
delete it and you lose positions, comments boxes, knots and unconnected nodes, but never code. It is
written only when its content changed and never in read-only mode. Properties: [Parsing-and-Layout.md](Parsing-and-Layout.md),
[Files-and-Safety.md](Files-and-Safety.md).

### Layers

```
 Native   vbhost.dll (C++): SDL2 window + OpenGL3 + Dear ImGui docking; Beef bindings in Native/src
   ^
 Editor   VisualBeefEditor: EditorApp, the node canvas, panels, node menu, build runner
   ^
 Core     VisualBeefCore: Syntax (lexer, parser, AST) -> Graph (builder, codegen, factory, layout)
          -> Document (SourceDocument, project index, file safety) + Catalog (types, node catalog)

 Meta     VisualBeefMeta: attributes your projects use       Tests   VisualBeefTests: command-line suites
```

Arrows point from dependent to dependency. **Core -> Editor -> Native** is the order to read
the code in: Core has no UI and is fully testable from the command line; the Editor adds the
canvas and panels; Native is the host that gives you a window and ImGui.

| Layer | Folder | Depends on | Pages |
|---|---|---|---|
| Core | `VisualBeefCore/` | corlib only | Parsing-and-Layout, Codegen, Flow-Nodes, Catalog-and-Types, Files-and-Safety |
| Editor | `VisualBeefEditor/` | Core, Native | Editor-UI |
| Native | `Native/` | corlib; prebuilt `vbhost.dll` | Architecture (Native section) |
| Meta | `VisualBeefMeta/` | corlib | Node-Attributes |
| Tests | `VisualBeefTests/` | Core, Meta | Testing |

### The path of one edit

Open folder -> index -> open file -> parse -> build graph -> you edit -> `BeginEdit` (undo snapshot) ->
mutate graph -> commit at end of frame (`CodeGen` -> splice -> re-parse, keeping the same graph objects)
-> Save (atomic, with `.bak`) -> Compile (BeefBuild; errors mapped back onto nodes). Each arrow and the
file that does it is in [Architecture.md](Architecture.md#data-flow-open-graph-edit-commit-save-compile).

## Conventions in these docs

* "Core", "Editor", "Native", "Meta" always mean the folders above.
* File names in backticks are relative to the repository root unless they start with `docs/`.
* Numbers (test counts, timings) are from the tree at the date in the [CHANGELOG](CHANGELOG.md); when
  you change behaviour, update the page and the number in the same commit.
