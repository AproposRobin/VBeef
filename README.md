# VisualBeef

A visual node-graph editor for the [Beef](https://www.beeflang.org/) programming language.
Every graph **is** Beef code: open a `.bf` file and each function becomes a node graph. Edit the
graph and only the statements you touched are rewritten; edit the text and the graph is rebuilt.
There is no separate graph format, so your source stays the only truth, stays diffable, and builds
with the normal Beef toolchain.

![VisualBeef editing a function of the ClockWork engine](docs/images/editor-clockwork.png)

*The editor on a function of the ClockWork engine (Release build): Outline, the node canvas, Properties
and the Project Browser.*

## What VisualBeef does

VisualBeef is a desktop application (Windows x64 today, Linux builds in progress) for people who write
programs in [Beef](https://www.beeflang.org/). It shows each function of a Beef source file as a graph of
nodes and wires, and lets you edit the program either way:

* **A node-graph editor that writes plain Beef source.** There is no separate graph format. Editing a graph
  rewrites only the statements you touched in the `.bf` file; editing the text rebuilds the graph. The file stays
  readable, diffable and under your version control.
* **Compiles with the Beef toolchain.** F7 runs the `BeefBuild` of your Beef installation on the project and
  shows the compiler's messages next to the nodes they belong to. Generated code is checked by compiling and
  running it in the test suites.
* **A debugger on the graph.** Run a program, stop on a node, read the values on its pins and step node by node,
  using Beef's own debugger engine from the installation.
* **UnrealUMP integration.** The [UnrealUMP](https://github.com/AproposRobin/UniversalUnrealModPlatform) launcher uses VisualBeef to
  edit "visual mods", which are ordinary Beef projects (see [docs/UMP-Integration.md](docs/UMP-Integration.md)).
  VisualBeef works on its own without it.

VisualBeef is not an installer-based product: unzip the package and run `VisualBeefEditor.exe`. It does not
connect to the network, collect data, or change system settings.

## What it does

* **Graphs from code and back, losslessly.** Comments, spacing and style outside the edited statements are
  untouched; a one-node edit is a one-line diff. Tested round trip over corlib and real projects
  (about 3,500 methods in the standard runs).
* **Refuses to write unsafe graphs** instead of guessing: a value that would be evaluated twice, code that
  would run twice, a read outside its scope. The reason is shown on the node.
* **Node-graph editor**: Outline, Properties, Project Browser, Output Log, Compiler Results, Find in
  Sheets, minimap, alignment tools, a context-sensitive node menu, typed wires.
* **Switch and flow nodes as plain Beef**: Switch, Sequence, Do Once, Do N, Flip Flop, Gate, Multi Gate,
  loops with Break.
* **Nodes from your own code**: tag functions with `[Node]`, `[Pure]`, `[Expose]`... (library
  `VisualBeefMeta`) to decide what the menu offers; libraries you reference become nodes automatically.
* **Safe with your files**: nothing is written by just looking; atomic saves with a backup; conflict
  detection; Recycle Bin deletes; a read-only (`--view`) mode.

## Install

VisualBeef ships with [UnrealUMP](https://github.com/AproposRobin/UniversalUnrealModPlatform): the UnrealUMP package carries it
under `tools\VisualBeef\` and the launcher opens it on a visual mod ("Open in VisualBeef"). It is also
available standalone: unzip `VisualBeef-<version>-win64.zip` anywhere and run `VisualBeefEditor.exe`
(`vbhost.dll`, the fonts, the licences and these docs are in the same folder; nothing is installed and
nothing is written next to the exe). VisualBeef keeps its own name, version (`VERSION.txt`, `--version`),
licence and notices in both cases. [docs/Getting-Started.md](docs/Getting-Started.md#install) explains
both, and `scripts\package.ps1` builds the package.

## Build and run

Requires Windows x64 and the Beef toolchain 0.43.6 in `C:\Program Files\BeefLang`.

```
"C:\Program Files\BeefLang\bin\BeefBuild.exe" -workspace=<repo> -config=Release -platform=Win64
build\Release_Win64\VisualBeefEditor\VisualBeefEditor.exe D:\path\to\your\beef\projects
```

Or open `BeefSpace.toml` in the Beef IDE and press F5 (`VisualBeefEditor` is the startup project). The
prebuilt `vbhost.dll` and the icon font are copied next to the program by the build. Add `--view` to open
a project read-only. Press **F7** to compile with BeefBuild. Step-by-step: [docs/Getting-Started.md](docs/Getting-Started.md).

Tests: `build\Debug_Win64\VisualBeefTests\VisualBeefTests.exe edits` (and the other suites, see
[docs/Testing.md](docs/Testing.md)).

## Documentation

Start at **[docs/README.md](docs/README.md)** for the reading order. Direct links:
[Getting Started](docs/Getting-Started.md) |
[Vocabulary](docs/Vocabulary.md) |
[Editor UI](docs/Editor-UI.md) |
[Architecture](docs/Architecture.md) |
[Parsing and Layout](docs/Parsing-and-Layout.md) |
[Codegen](docs/Codegen.md) |
[Flow Nodes](docs/Flow-Nodes.md) |
[Catalog and Types](docs/Catalog-and-Types.md) |
[Node Attributes](docs/Node-Attributes.md) |
[Files and Safety](docs/Files-and-Safety.md) |
[Testing](docs/Testing.md) |
[Continuous integration](docs/CI.md) |
[Code signing](docs/Code-Signing.md) |
[Roadmap](docs/Roadmap.md) |
[Changelog](docs/CHANGELOG.md)

## Repository

```
BeefSpace.toml        open this in the Beef IDE
VisualBeefCore/       language layer: lexer, parser, graph, codegen, documents, catalog. No UI.
VisualBeefEditor/     the editor app (Dear ImGui; the node canvas is drawn in Beef)
VisualBeefMeta/       attributes ([Node], [Pure], ...) your projects can reference
VisualBeefTests/      command-line suites: round trip, edits, codegen compile-and-run, catalog, safety
Native/               SDL2 + OpenGL3 + Dear ImGui host (vbhost.dll) and its Beef bindings
docs/                 the manual
LICENSE, NOTICE        Apache-2.0 licence and attribution notice
THIRD_PARTY.md        licences of bundled components
```

## Status (end of Phase 1, 2026-10-10)

Working: everything above; Debug and Release build with 0 warnings; all test suites pass.

Limitations you will notice (full list in [docs/Roadmap.md](docs/Roadmap.md)):

* Lambdas, local functions, `defer`, `scope` / `new` forms, tuples, property accessors and `=>`
  methods are still shown as Code nodes holding the exact text.
* Types are resolved without the Beef compiler, so some pins stay grey (connect to anything); renaming
  does not update references.
* Windows only in practice; settings and the dock layout files are written to the working directory.
* No installer and no crash handler yet.

Where it is going: a node-graph editor with nodes declared from Beef attributes, a viewer mode for
projects that are not VisualBeef projects, a compiler-backed language service, a debugger on the graph, and
integration with UMP so a generated game SDK becomes a node library. See the roadmap.

## Code signing

Windows releases are built by a GitHub workflow from the tagged commit ([docs/CI.md](docs/CI.md)) and are meant to be
signed through the SignPath Foundation's free code signing for open source projects. **No release is signed yet;
the application is pending.** The policy (what is signed, who approves, privacy, how to verify a download with
`Get-AuthenticodeSignature`) is in [docs/Code-Signing.md](docs/Code-Signing.md).

*Once approved:* Free code signing provided by [SignPath.io](https://signpath.io), certificate by
[SignPath Foundation](https://signpath.org).

## License

VisualBeef is licensed under the Apache License, Version 2.0 (Copyright 2026 AproposRobin); see [LICENSE](LICENSE) and [NOTICE](NOTICE). This is the same licence as UnrealUMP, which VisualBeef is meant to ship with. Bundled third-party components keep their own licences ([THIRD_PARTY.md](THIRD_PARTY.md)); the prebuilt `vbhost.dll` statically links Dear ImGui, cimgui, imnodes, cimnodes (MIT), SDL2 (zlib), the LLVM C++ runtime (Apache-2.0 with LLVM Exceptions) and the mingw-w64 runtime, and their notices must travel with it.
