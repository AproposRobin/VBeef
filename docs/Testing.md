---
audience: developer
title: Testing
summary: Every VisualBeefTests suite, the expected counts and how to add a case.
order: 14
---

# Testing

All automated tests are in `VisualBeefTests` (`VisualBeefTests/src/`), one command-line program
with a sub-command per suite. It references only `VisualBeefCore` and `VisualBeefMeta`, so it
tests the language layer, the file layer and the catalog, but **not** the editor UI (no ImGui
code is linked). UI changes are checked by running the editor (see [Verifying the UI](#verifying-the-ui)).

```
build\Debug_Win64\VisualBeefTests\VisualBeefTests.exe <command> [options]
```

Every command exits 0 on success and 1 on any failure, prints `ok` / `FAIL` lines (or only
failures, without `-v`) and ends with a count line. Build it with the normal Debug build
(`BeefBuild -workspace=<repo> -config=Debug -platform=Win64`).

Placeholders in the commands below: `<repo>` is this checkout, `<UnrealUMP>` is the root of an
UnrealUMP checkout and `<ClockWork>` the ClockWorkEngine folder (the corpus the long suites read; pass
your own paths). `<scratch-dir>` is any empty folder for the output.

## Before you push: the full run

```
edits
flow
lifetime
textforms
classes
safety
parser
catalog
diagnostics
hotkeys
ump
vocabulary
stress
compile -out <scratch-dir>
debug -out <scratch-dir>
debugmap <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src <ClockWork>
roundtrip <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src
roundtrip -types <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src
roundtrip <UnrealUMP>/src <ClockWork> -out <scratch-dir>
orphans <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src
loadall <UnrealUMP>
savecheck <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src <ClockWork>
inits "C:/Program Files/BeefLang/BeefLibs/corlib/src"
inits <UnrealUMP>/src <UnrealUMP>/UMPRuntime/src <UnrealUMP>/UnrealSDKCore/src <ClockWork>
```

Run them one at a time (the roundtrip / orphans / loadall runs are long and single-threaded;
on a shared machine start them at BelowNormal priority).

Lint: `powershell -ExecutionPolicy Bypass -File scripts\lint-scope-delete.ps1` prints `OK: no delete of a scope-allocated object` (exit 0). Run it before the full run; it is the same check UnrealUMP runs.

Expected output on the tree this page was written against (2026-10-10, after the last text forms, `#if` keys, the node menu on the indexer, Find References, the overload choice and the robustness pass):

| Command | Expected last line | Time |
|---|---|---|
| `edits` | `total: edits ok, factory failures 0, flow failures 0` (edit scenarios 1-24 with 0 failures, factory 63 cases, flow 154 checks including the 75 call checks and the 7 Defer / Using body checks) | seconds |
| `flow` | `flow checks: 154  failures: 0` (59 switch / macro checks + 13 counting For Loop checks + 75 call checks + 7 Defer / Using body checks) | < 1 s |
| `calls` | `call checks: 75  failures: 0` | < 1 s |
| `lifetime` | `lifetime checks: 112  failures: 0` | < 1 s |
| `textforms` | `text form checks: 91  failures: 0` | < 1 s |
| `classes` | `class checks: 476  failures: 0` (31 Node Library: kind change, static writing, validator, catalog categories, + 179 + 136 in the ownership and initial values group + 38 in set on create, + 19 from the 2026-10-11 bug hunt, + 26 from the suspected-issues pass: typed primitives, a rename with a refused commit, constructor chains, code-point characters, + 12 from the newcomer pass: interface functions, usings, overload ties, + 10 Passing: the chooser's choices, out / ref / in written and read back, + 14 Return defaults per type and a fresh bool function written with `return false;`, + 3 Set labels: Variable on Set nodes, Receiver on calls, + 5 Construct needs a constructor: the error, the classes that need no choice, cleared by an input, a warning when read from code, + 3 a print read back takes Object: the pin, byte for byte, a wired int) | < 1 s |
| `safety` | `safety: failures=0` (18 groups, 136 `ok` lines) | seconds |
| `vocabulary` | `vocabulary: source files=90 string literals=8700 docs=22 hits=0 failures=0` | < 1 s |
| `parser` | `parser checks: 297  failures: 0` (then the 32 declaration-form checks of `classes`; exit code covers both) | < 1 s |
| `catalog` | `catalog checks: 234 passed, 0 failed` | under 1 s once the corlib cache exists |
| `diagnostics` | `diagnostics checks: 49  failures: 0` | < 1 s |
| `hotkeys` | `hotkey checks: 36  failures: 0` | < 1 s |
| `ump` | `ump checks: 48  failures: 0` (16 for New Project > UMP Mod: names, the SDK folder resolved, the files written) | < 1 s |
| `stress` | `stress checks: 68  failures: 0` (4 context checks + 16 runs of 50 random edits x 4 checks) | about 2 s |
| `debug -out <dir>` | `debug checks: 49  failures: 0` | about 8 s (one small BeefBuild, three runs under the debugger) |
| `debugmap` (UMP `src`, `UMPRuntime/src`, `UnrealSDKCore/src`, ClockWork) | `debugmap: files=204 methods=1702 statements=25724 values=49778 without-line=57 failures=0` | about 15 s |
| `ump -sdk <launcher data>\sdk\hogwarts-legacy\HogwartsLegacySDK` (emitter v5) | `ump checks: 46  failures: 0` | 18 s on the first run (parse + cache), about 1 s after |
| `compile -out <dir>` | `compile: cases=42 compiled=30 refusals=12 failures=0` | about 1.5 s warm, longer on the first BeefBuild |
| `roundtrip` (UMP `src`, `UMPRuntime/src`, `UnrealSDKCore/src`) | `files=174 methods=1552 failures=0 broken=0` | about 15 s |
| `roundtrip -types` (same three) | same | about 15 s |
| `roundtrip <UnrealUMP>/src <ClockWork> -out <dir>` | `files=106 methods=1235 failures=0 broken=0` | about 8 s |
| `orphans` (same three UMP folders) | `orphans: files=174 methods=1552 failures=0` | about 25 s |
| `loadall <UnrealUMP>` | `loadall: files=331 methods=2883 nodes=136007 ... failures=0` | about 6-30 s (most of it indexing the SDKs the first time) |
| `inits` corlib, then the three UMP folders + ClockWork | one line per folder ending `failures=0`, then `inits: failures=0` (counts in [`inits`](#inits--v--noflip-files-or-folders)) | about 25 s for corlib, 10 s for the rest |
| `savecheck` (the three UMP folders + ClockWork) | `savecheck: files=204 edits=353 failures=0` (all BeefLibs corlib + UMP + ClockWork + the report project: `files=401 edits=659 failures=0`) | about 11 s |

The UMP tree is edited by other work, so its file and method counts drift; `failures=0` is what
matters.

If a count differs, the number of cases changed: update this table in the same commit.

## Commands

### `edits`
Runs three suites in one go and prints one total: `EditTests.Run()` (scripted graph-editing
scenarios), `FactoryTests.Run()` and `FlowTests.Run()`.

* **EditTests** (`EditTests.bf`, scenarios 1-24, about 240 checks): load a sample `Player.bf`, edit
  the graph the way the editor does (insert a call, remove a node, morph node kinds, rename,
  asset operations, orphan persistence, broken sidecar records), commit, and assert on the
  generated text (comments and formatting preserved, only the edited statement changed), on
  undo / redo, and that orphan (unconnected) nodes survive a save / reload through the sidecar.
* **FactoryTests** (`factory` alone runs just this): for each node the *menu* can create, build it
  with `NodeFactory`, commit, and assert the live graph is unchanged by the commit and that
  re-reading the committed file gives an identical graph ("nodes keep their shape"). 63 cases,
  including every flow macro, nested macros and multi-gate variants, every call shape (static
  with and without qualifier, member with this, This wired, out pin read and unread, ref), and the
  lifetime nodes (Construct in each form, Defer -> Delete, Defer with a block, Using with and
  without a variable, Result on Ok and on Err).
* **FlowTests**: see `flow`.

### `flow`
Switch and flow-macro behaviour that needs no compiler (59 checks in 7 groups): switch parsing
(case lists, defaults, Code-node fallbacks with reasons), graph shape and byte-exact round trip,
scripted switch edits, merges of switch arms, recognition of every macro shape (Sequence, Do
Once, Do N, Flip Flop, Gate, Multi Gate), the state fields they own, and refusals (a Reset with
no state field, a field that is not a Do Once field). Then the call checks (`calls`, below) and the
Defer / Using body checks of `lifetime` (7 checks: a statement added to a one-line Defer, K&R
headers kept, a node wired into a body and after it refused, an `else if` chain of Result nodes).
Runtime behaviour of the same code is covered by `compile`.

### `calls`
The call model (`CallTests.bf`, [Calls-and-Receivers.md](Calls-and-Receivers.md)), 75 checks in 8
groups: the three call shapes read from code with and without a resolver (a `TypeService` over the
test source) and their byte-exact identity commit and forced regeneration; GraphValidator's Receiver
errors with the owner's exact texts ("Receiver must be a Base: this function is static, so there is no
this.", "Receiver must be a Player; this is an Enemy.", "...the wire brings an Enemy.") and the cases
that must not be errors (base member with this, unknown owner, no resolver); required inputs, `ref`
lvalues, wire and literal types (error vs warning); out and ref arguments read from code (`T v;` +
`out v`, `var w`, `?`, `out mHp`, `ref`, `[Pin(Out=true)]`, `out let a`, a fold that must not
happen); out pins written (`var value`, `?`, hoisted `int value = default;`, other path refused,
unknown type refused, loop condition, distinct names, pure call); `[Pin(Out=true)]` written and read
back; overload ties; layout-key continuity.

### `lifetime`
The lifetime nodes (`LifetimeTests.bf`, [Lifetime-Nodes.md](Lifetime-Nodes.md)), 92 checks in 6
groups: parsing of every `new` / `scope` / `delete` / `defer` / `using` / `case` form (and what stays
raw: initialisers), graph shapes (Construct types and constructor labels, `.()` typed from the
local, `scope $"..."`, the cascade receiver, Defer -> Delete, Using variables, Result payloads typed
from `Result<T>` / `Result<T, E>`, the `case` operator, `Try!`), round trips (identity commits byte
for byte; forced regeneration reads back as the same graphs; Allman and K&R blocks byte for byte),
code written for `NodeFactory` nodes (then read back and regenerated to the same text), the
lifetime rules (each error, warning or the absence of one, including "read from code: a warning,
not an error"), and the Defer / Using body edits (also run by `flow`).

### `textforms`
The last text forms as nodes (`TextFormTests.bf`, [Lifetime-Nodes.md](Lifetime-Nodes.md#the-last-text-forms)), 91 checks in 7 groups:
overload choice (an ambiguous call lists both overloads, picking one writes the cast, read back
unambiguous, undo; out-only overloads refused with a reason); Find References (a field across two
files, an overloaded function a rename would refuse, a type, a parameter); methods in `#if` /
`#else` arms (keys, the arm on each graph, the active arm for a define set, condition
evaluation, identity commit and regeneration byte for byte of every function, an edit of one arm
only); parsing of every form; graph shapes (Scope, `const` / `ref`, `(.)`, `.()`, `repeat`,
attributes, lambdas with parameters / Returns / Body / captures, Create Delegate, event `+=`, local
functions, Format templates and holes, payload switches); round trips (identity commit, forced
regeneration byte for byte and back to the same graph, a statement added to a lambda body, a
ternary in a hole); layout keys (lambda body keys, a short lambda hashing like the pin text it
replaced).

### `loadall [-v] [-savelayout] <folders>...`
Opens every project file of a folder the way the editor does (`LoadAllTests.bf`): the editor
setup (`ProjectIndex.Build`, so generated SDK folders are libraries, and the `TypeService` with
corlib and the libraries), then per file `SourceDocument.Load` (the text and its `.vblayout` side
file, orphans included), every function graph built and laid out, structural keys, a dry
generation (code as read must not be refused), the layout text a save would write, and graph
invariants (each link between pins of nodes in the graph and of the right kinds, unique ids,
finite positions, keys). Nothing is written, except with `-savelayout` (side files written next to
each file: use it on a scratch copy, then run `loadall` again to load them back). On
`<UnrealUMP>` (2026-10-10): `files=331 methods=2883 nodes=136007 failures=0`; on a scratch
copy of `src`, `UMPRuntime`, `UnrealSDKCore` with side files written and reloaded:
`files=150 methods=1190 sidecars=110 failures=0`.

### `coverage [-notypes] [-v] <folders>...`
The production audit's coverage probe as a command (`CoverageTests.bf`): loads every `.bf` file
with the editor's setup (ProjectIndex + TypeService, unless `-notypes`), builds every method graph
and prints the method bodies with no Code node and with no text node at all (no Code and no
Expression node), every node kind, the Code / Expression nodes and pin texts grouped by the
construct they start with (`using`, `defer`, `scope`, `case` pattern, lambda, ...), and what a dry
generation reports on code as read (the editor's first check). `-v` lists each text node, pin text
and report with its file and line. It measures, it does not fail. On the three UMP folders
(2026-10-10, after the last text forms): 1,361 of 1,366 bodies (99.6 %) have no Code node and 1,345
(98.4 %) no text at all, nothing reported (see [Lifetime-Nodes.md](Lifetime-Nodes.md#coverage-on-ump-code) for before / after).

### `safety`
File-safety scenarios on real files in a scratch folder **`vb_safety_tmp` under the current
directory** (created and removed by the test): 18 groups, 130 checks.
1 viewing writes nothing; 2 atomic save, backup, sidecar on edit; 3 failed write leaves the
original; 4 disk change is a conflict; 5 read-only project refuses every write; 6 dirty tracking
follows the saved text; 7 node moves are undoable; 8 comment boxes are undoable; 9 sidecar hygiene
(version, prune, tolerance); 10 where new files go and per-namespace uniqueness; 11 rename and
delete write only their own change; 12 delete goes to the Recycle Bin (on Linux the freedesktop Trash, moved into the scratch folder with `XDG_DATA_HOME`: `files/` + `.trashinfo`, `name.2` for a second item of the same name, percent-encoded `Path=`, folders, a tmpfs `/dev/shm` item going to that mount's `.Trash-<uid>` with a relative `Path=`) or does nothing; 13 a graph
with errors is not saved (and saves once fixed); 14 saving over a read-only file, and into a
folder whose ACL denies writing (set and removed with `icacls`), fails with a reason, leaves the
file untouched and keeps the edit, then saves once writable; 15 saving a file another handle holds
with no sharing fails the same way, leaves no temp file, and saves (with a backup) once released;
16 layouts saved before the vocabulary pass still match (the content hash of a call with a wired or
unconnected Receiver equals the pre-rename shape, node kind numbers are unchanged, the pin id
is unchanged and its label is `Receiver`).
17 the compile status: no record -> grey, matching hash -> green, unsaved or saved change or other configuration -> yellow, failed and unchanged -> red, the hash returns when the content does, the record text round trip.
18 unparsed members are kept: `savecheck` (below) on 7 crafted files, each with one member the
parser cannot read or a declaration error (the 2026-10-11 report with `var Main()`, a keyword as a
return type, a `var` member variable, unbalanced brackets, a missing `}`, a nameless member, a CRLF
file): unchanged saves byte for byte, and both edits (14) keep every other member.
19 (Linux only) the crash report writer: the report folder (`VB_HOME`, `XDG_STATE_HOME`, `~/.local/state`), a report from a fake SIGSEGV with registers (version, signal, address, project, a `backtrace(3)` stack, the caller's lines last), a runtime-error report, an unwritable folder, the next-start lookup (once), pruning.
Group 12 exercises the Recycle Bin path.

### `stress [-seed N] [-edits N] [-v] [files or folders]...`
Undo / redo stress (`StressTests.bf`). On four crafted texts (Allman with tabs and K&R with spaces, each in LF and
CRLF; nested and generic types), four seeds each, and on every `.bf` file given: 50 random edits of every kind the
Outline, Properties and the Sheet make (member variable, function, property and constructor added; rename; signature;
member type; modifiers; initial value; Set on Create; delete; a statement committed into a function graph), then undo
all (each step must give the text before its edit; at the end the original byte for byte) and redo all (the text after
the last edit). After every step the document's functions and built graphs must match a fresh read of its text (same
keys, same node counts): a desync stops that run with the edit that caused it (`-v` prints the text before and after).
First the context checks: a member variable a function reads is renamed, then deleted; every built graph must follow.

### `savecheck [-v] <files or folders>...`
`SaveCheckTests.bf`, the rule of [Files-and-Safety.md](Files-and-Safety.md#unparsed-members-are-kept)
on real files, in a scratch folder `vb_savecheck_tmp` under the current directory. For every `.bf`
file: load it from disk, open every graph, save (nothing written) and force a save: the file is
byte for byte what it was. Then a statement is added to the first function graph that commits and
the file is saved: every other member (each member's exact text, the edited function and a
property holding it excepted) is still in the file. Then a member variable is added to the first
class and saved: every member is still there. Prints `savecheck: files=N edits=N failures=0`.

### `decls <files or folders>`
Prints every declaration error the editor would show (a return type, parameter or member variable type that does not fit its place, see [Catalog-and-Types.md](Catalog-and-Types.md#what-a-type-field-accepts)) and a count. Use it on a new tree before trusting the rules: corlib, UMP and ClockWork give `declaration errors=0`. The editor session test has 82 checks (41 before the 0.1.1 work) (step 20: an illegal `var` Return Type and a `void` variable are refused with the reason, file unchanged).

### `inits [-v] [-noflip] <files or folders>...`
Ownership and initial values on real code (`InitTests.bf`, [Classes-and-Members.md](Classes-and-Members.md#ownership-and-initial-values)).
For every member variable and auto-property with a value: the text after its name is read into a
choice (`MemberInit.Classify`) and written back, which must give the same bytes; writing the same
choice through `SetMemberInit` must leave the file unchanged; then it is flipped to another legal
choice (`Owned, made here` -> `Owned, set later`, `Reference` -> `Pointer`, ...) and back, which must
give the original file byte for byte (`T *name` pointers, written C style, are not flipped). Each
folder prints `files= members= custom= convertible= multi= flips= failures=`, the count per choice and
the ten most frequent Custom forms (`-v` lists every Custom member). 2026-10-11: corlib 2,061 members,
29 Custom (2 convertible), 24 Disposed with it, 2,030 flips; UMP `src` 997 / 3; `UMPRuntime/src` 376 / 9 (36 Owned for
the run); `UnrealSDKCore/src` 707 / 0; ClockWork 133 / 0; `failures=0` everywhere. Before Owned for the run and
Disposed with it (0.1.5): corlib 53 Custom, `UMPRuntime/src` 45, the rest unchanged.

### `classes`
The type-level model (`ClassTests.bf`, [Classes-and-Members.md](Classes-and-Members.md)), 353 checks
in 8 groups: modifier words and attribute lists; declaration spans of every declaration form
(class with attributes / modifiers / generics / base list / constraints, struct with a base,
interface extending one, enum with an underlying type, extension, static and partial classes,
const / static readonly / attributed fields, auto, expression-bodied and accessor properties,
indexers, `this()` / `static this()` / `~this()`, generic, abstract, extern methods, mixins) and
their byte-exact round trip; each Type Settings edit (base list, modifiers, attributes, kind,
generics, constraints, namespace, initial values) with its exact text and undo; inheritance and
interfaces (Override list, missing members and their document errors, stubs, override signatures
for virtual / protected out / property / generic bases, abstract members, unknown bases, sealed and
struct parents, the type pickers); graph checks (the override error on the Entry node, the Parent
node read, regenerated and refused in a static function, accessor graphs); renames across two files
(a field: 7 references, Other's same-named field kept; a type: 8 references and the function key
that follows a parameter type; refusals with file and line; a parameter and a local with
interpolated strings); the new-type templates and the UMP mod (graphs, Override list,
OnWorldReady with its parent call); ownership and initial values (`InitTests.RunChecks`, 126 checks:
`~ delete _` parsed as a member variable, type kinds, the choices per type, every form read and
written back byte for byte, each edit with its exact text and one undo step, the refusals (appended in
a struct or static, owned on a property or a const, `int a, b;`), literal formatting and escaping, enum
members from the index, the preview line).

### `parser`
296 checks in five areas (destructor clauses since 2026-10-11: `T x ~ delete _;` and `~ { ... };` are
member variables with `DtorTok`, `= ~0` is not a clause): **literal kinds** (`1.0` double, `1.0f` float, suffixes, interpolated,
verbatim and raw strings), **error recovery** (every trigger of a `Broken` member, its exact
extent, that later members survive, graph and Outline consequences; since 2026-10-11 also the
declarations that used to be hidden: `var Main()` from the user report as a function with an
entry error and Problems row, `[Comptime] var` without one, a keyword as a type, a `var` member
variable, a nameless member listed as `unparsed member at line N`, and the forms that must stay
text: `Event<delegate ...> m ~ ...`, explicit generic interface members, operators, `typealias`) and **layout keys**
(content-keyed positions: exact / moved / edited matching, migration of old positional entries to
format 2, pruning, unknown lines preserved).

### `catalog`
207 checks in 11 groups: attributes, literals and conversions, fuzzy ranking, the corlib cache
(path-keyed miss and hit, content-keyed hit with the path cache gone, a copied library loading
from the content cache with its file records re-pointed),
attributed catalog, plain catalog (`#if` de-duplication, context), type resolution in graphs,
wire type checks and wildcards, pin colours, library discovery, and the prebuilt catalog (built
as the indexer does, then adopted: same entries, names, categories and tree) with letter-by-letter
(incremental) search giving exactly the from-scratch results. Uses `VisualBeefTests/fixtures/`
(`Attributed`, `Plain`: two tiny libraries) and the real corlib at
`C:\Program Files\BeefLang\BeefLibs\corlib`. The corlib symbol cache is kept in
`build\vbtest-cache\` next to the repository (found through the source path baked into the exe,
so run the exe on the machine and tree that built it).

### `catalog-scale [sdk-dir]`
Not an assertion suite: timings of indexing, the content-hash cache hit, the path cache hit, the
catalog build, and several searches on a large SDK (a generated game SDK with about 4,000+ nodes).
Without a folder it reads the `VB_UMP_SDK` environment variable (the SDK folder); when that is unset
or empty the default is `D:/UnrealUMP/UnrealUMP/Sdks/ScreechSDK`. Use it to catch performance regressions.
It also times the catalog built the way the indexer does (`catalog prebuild` on the worker,
`catalog adopt` on the UI thread), the category tree, and typing "get actor location" one key at a
time from scratch and incrementally. Typical on this machine (Debug, 2026-10-10, a loaded
machine): Screech catalog 131 ms in place / prebuild 132 ms + adopt 2.0 ms, tree 7 ms, typing 485 ms
from scratch vs 228 ms incremental (worst key 27 ms), searches 1-35 ms; Hogwarts catalog 445 ms /
adopt 3.8 ms, tree 21 ms, typing 1,101 vs 508 ms (worst key 60 ms), searches up to 83 ms.

### `catalog-scale -root <dir>`
Opens a whole folder exactly like the editor's background indexer (`IndexJob.Run` on the test
thread), with an empty cache (cold) and again (warm), then times a rescan of the same root, an
open with only the content-keyed caches, and how fast a running job stops after `Cancel`. On
`<UnrealUMP>` (2026-10-10, Debug):

```
open root (cold): 11260 ms total; project index 403 ms, 266 files (3 generated SDK folders skipped); libraries 10858 ms, 4 stores [...] (0 from cache, 4 parsed, 29904 types)
open root (warm): 416 ms total; project index 405 ms, 266 files (3 generated SDK folders skipped); libraries 12 ms, 4 stores [...] (4 from cache, 0 parsed, 29904 types)
rescan same root: 85 ms (0 parsed, 266 reused)
open root (path cache dropped, content cache only): 900 ms; libraries 498 ms (4 from cache, 0 parsed)
cancel: worker stopped 36.5 ms after Cancel (done=True)
```

Before this change the same folder took 15.0 s cold and 16.0 s warm (751 files parsed as
project sources on every open, on the UI thread). The cache goes to `build\vbtest-cache\root`.

### `ump [-sdk <dir>]`
The UnrealUMP contract ([UMP-Integration.md](UMP-Integration.md)), `UmpTests.bf`: the command line
(`EditorArgs.Parse`: every option, `--version` as print vs. the mod's version, the usage errors and
exit codes), project resolution (`ProjectContract.ResolveTarget`: folder, `.vbproject` main, `.bf`
file walking up to its project, `BeefProj.toml`, relative `--file`, missing paths, a marker `main`
outside the project), `--new-ump-mod` (`WriteUmpMod`: the file and `.vbproject`, byte for byte the
text UMP's launcher writes, never overwriting), and generated libraries reached through a workspace
dependency inside the opened folder (under `build\`, with `*.g.bf` or a `.vblibrary` marker, not for an
ordinary project). With `-sdk <dir>` it loads a UMP-generated SDK (emitter v5) as a library and
checks the node catalog: attributed, no `_PE` / hook members, output pins from `[Pin(Out=true)]`,
`[Expose]` Get nodes, Break Vector (category, pure, static, three output pins labelled X / Y / Z),
Get Actor Location (display name without `K2_`, category, pure member, tooltip from the dump), Set
Actor Location (flow node with an output pin), and search ranking.

### `vocabulary [root] [-v]`
Reads the string literals of `VisualBeefCore/src`, `VisualBeefEditor/src` and `VisualBeefMeta/src`
(comments and interpolation holes skipped) and every page of `docs/` and `README.md`, and fails on a
banned whole word (the list is at the top of `VocabularyTests.bf`: the older terms of [Vocabulary.md](Vocabulary.md)
and the words that name their old pins and panels). Only Beef keywords, ids nobody sees (the old pin ids and
type names the layout hashes keep) and the game SDK's own names are allowed, and
`CHANGELOG.md` and `Vocabulary.md` itself are skipped (history and the
mapping). Run it from the repository root or pass the root.

### `diagnostics`
49 checks (`DiagnosticsTests.bf`). **Output parsing** (`BuildOutput.Parse`): BeefBuild's
`ERROR: <text> at line L:C in <path>` and `WARNING: ...` (text, path, line, column), the
progress-bar prefix, paths with spaces, the MSVC `file(L,C): error CODE: text` and clang
`file:L:C: warning: text` forms, messages without a location, and lines that are not messages.
**Line -> node mapping** (`DiagnosticMap`) on a sample class: a statement line lands on that
statement, a line inside an `if` body on the innermost call (not the Branch), the `if` line on
its one-line condition, the signature on the entry node, a field at document level named by its
type, a line outside every type with no owner, a second method by its key; after inserting two
lines above, the diagnostic follows its statement by content key; after editing the call's
argument (a node of its own) the call is still found by its content; a removed statement no longer
resolves to an unrelated node. **Node errors stay where they belong** (the 0.1.3 report, 18 checks): the
node with the error deleted, then a new node placed at its place and elsewhere: no node shows the
error (not the new one, not the statement that moved up into the deleted one's place) and the message
is marked `NodeGone`; undo brings the node back with its error; a node inserted before it does not take
it; the node edited in the graph keeps it until the next compile; a reopened file finds it by content.

### `hotkeys`
Node hotkeys and favorites (`HotkeyTests.bf`, the `NodeHotkeys` map of VisualBeefCore,
[Editor-UI.md](Editor-UI.md#node-hotkeys-and-favorites)), 36 checks in 4 groups: the 11 defaults
(distinct letters and nodes, none of C / F / M / Q, seeded as keys and favorites, B is Branch, P is
Print, letters in order), conflicts (a letter another node owns is refused and the message names the
owner: "B is already the hotkey of Branch."; C / F / M / Q refused as the Sheet's; a digit refused;
one letter per node; assigning makes a favorite), clearing (by letter and by node, the favorite
stays, Reset to Defaults) and favorites (order, removing a favorite removes its hotkey).

### `debugmap [-v] <files or folders>...`
The debugger's node <-> line map (`DebugTests.bf`, [Debugging.md](Debugging.md)) on every function of
a corpus: each node with a line (`DebugMap.LineOf`: statements their first line, values the line of
the statement using them, the entry node its `{` line) maps to a line inside its function, and
`DebugMap.NodeAt` of that line gives back a statement of the same function with the same line.
Prints `files= methods= statements= values= without-line= failures=` (without-line: unconnected
values, locals declared without a value, local function declarations).

### `debug [-out <dir>] [-v]`
Copies the `VisualBeefTests/fixtures/Debuggee` workspace to the scratch folder (default
`<temp>vb-debug`), builds it in Debug (BeefBuild at BelowNormal) and runs it under Beef's debugger
engine (`IDEHelper64.dll` from the install): the startup project resolved like the IDE; breakpoints
from nodes (Main's entry node, binding to its first statement and shown on the entry; the print in
`Greeter.Hello`); the stop on that node and the call stack; locals; values (`name`, a pin's expression,
`this` and a member through its expression, a call refused, an unknown name with the reason); Step
Over (the next node), Step Into (inside `Add`), Step Out (back in `Hello`, the field changed);
Continue to exit code 7 with the program's output; then a run with `crash` (a null object): the stop
by the fault on the Set node, and Stop; then a run with `loop`: Pause shows the main thread down to `Main`, Continue, Stop. 47 checks. Needs the Beef install.

### `compile [-out <dir>] [-v]`
The strongest check of code generation (`CompileTests.bf`). Each *case* is a small Beef program
plus an edit to its graph. The runner edits the graph exactly like the editor, commits, writes
the committed file into a scratch workspace, builds **all cases in one BeefBuild run**, runs the
program once per case and compares stdout with the expected text. 42 cases: 30 build and run
(shared values, diamond merges, scope hoisting, style matching, the switch and every flow macro,
nested combinations, `CallsSelfStaticOutRef`: this in a derived class, This, a qualified static,
`var` / `?` / hoisted / loop-declared out values, `ref`, `[Pin(Out=true)]`; `LifetimeFromCode`:
every lifetime construct regenerated and run, a destructor printing when a `scope` block ends,
Defers in LIFO order, `using` disposing, Result matches, `Try!`; `LifetimeNewNodes`: the same made
from `NodeFactory` nodes; `ClassHierarchyInterface`:
an abstract class with a virtual function, an abstract one, a virtual property and a protected
out function, and a class implementing an interface whose stubs and overrides were added with the
Type Settings APIs (`Case.Prepare`, with a TypeService over the file: `Case.WithTypes`);
`OverrideTickFromDropdown`: `Initialize` / `Tick` overrides of a UMP-like base with the parent call
and a graph edit), 12 *refusal* cases that must not write anything and must name the problem on a
node (`RefusalContains`), including `RefuseTargetSelfInStatic`, `RefuseScopeAfterBlock`,
`RefuseReturnInDefer`, `RefuseResultValueOutsideArm` and `RefuseOverrideWithoutBase`. `-out` is the scratch folder (default `<temp>b-codegen`); `-v` prints
every check. Needs BeefBuild at `C:\Program Files\BeefLang\bin\BeefBuild.exe`.

### `roundtrip [-types] [-v] [-out <dir>] <files or folders>...`
For every method of every `.bf` file (folders are searched recursively):

1. lexing reproduces the file byte for byte;
2. building the graph and committing with no edit reproduces the file byte for byte;
3. forcing regeneration of every statement from the graph and re-parsing it gives an identical graph.

Prints `files= methods= failures= broken=`; `broken` counts members the parser flagged `Broken`
(must be 0 on valid sources). A commit that is **refused** in step 2 or 3 is a failure too (it is
printed with every error and the node's line): valid code must never be refused, so a false error
from GraphValidator or the generator shows up here. With `-out <dir>` the fully regenerated files are written so they can be
compiled (the regenerated corlib compiles and runs). `-types` additionally installs the project
index and `TypeService` with libraries, like the editor, so graphs are typed. Corpora used:

| Corpus | Result |
|---|---|
| `<UnrealUMP>/src` + `<ClockWork>` (the standard pre-push run) | files=99 methods=1126 failures=0 |
| UMP `src` + `UMPRuntime/src` + `UnrealSDKCore/src`, with and without `-types` | files=166 methods=1424 failures=0 |
| `<ClockWork>` with `-types` | files=30 methods=150 failures=0 |
| Beef corlib `C:/Program Files/BeefLang/BeefLibs/corlib/src` (about 80 s) | files=201 methods=3774 failures=0 (was 172 before methods in `#if` / `#else` arms got their own keys, see [Parsing-and-Layout.md](Parsing-and-Layout.md#methods-in-if--else-arms)) |
| The Beef IDE sources (`IDE/src` of the Beef repository, not installed with the toolchain) | with corlib and ClockWork about 9,000 methods in total, 0 failures when last run (not re-run for this page) |

### `orphans [-v] <files or folders>...`
For every method: disconnect the body from the entry, save the layout, reload text and layout,
compare the unconnected nodes, reconnect, and compare the rebuilt graph with the original.
Proves that breaking a wire never loses work. A refused reconnect commit is a failure. Standard
runs: `orphans <ClockWork>` (`files=30 methods=136 failures=0`) and the three UMP
folders (`files=166 methods=1424 failures=0`).

### Developer tools
* `dump <file>`: prints the parsed AST of a file.
* `graph <file>`: prints each method's graph signature (nodes, pins, links).
* `bench <file>`: load and one-commit timings for a big file.

## How to add a case

* **A generated-code case** (`CompileTests.bf`): add a `Mutate...(Graph g)` function that edits
  the graph with `NodeFactory`, `g.Connect`, then an `AddCase(cases, "Name", "Ns", source, "Test.Run()", => MutateFn, expectedStdout)` (the fifth argument is the method key of the method being edited)
  in `MakeCases`. The source is a Beef program with a `Test.Run()` that prints. Add
  `MustContain` / `MustNotContain` for style checks, `SameAsSource` for no-op edits, or
  `RefusalContains` for a graph that must be refused. Cases share one workspace, so names
  and namespaces must be unique.
* **A menu-node case** (`FactoryTests.bf`): `Case("name", "Host.Method()", (g) => { ... })` builds nodes
  into the `Host` sample; the harness checks they survive commit and re-read unchanged.
* **An editing scenario** (`EditTests.bf`): add a numbered `Scenario` block using `Method(doc, key)`,
  mutate, `doc.Commit(mg)`, then `Check(condition, "what")`.
* **A parser or flow check**: add `Check(...)` lines under the matching group in `ParserTests.bf` /
  `FlowTests.bf`. The suites count checks themselves; update the expected count in the table above.
* **A new suite**: add a `static class FooTests { public static int Run() }` returning the number
  of failures, a branch in `Program.Main` (`if (args[0] == "foo") return (FooTests.Run() == 0) ? 0 : 1;`),
  a line in the usage comment at the top of `Program.bf`, and a section in this page.

Conventions: every `Check` prints a sentence that reads as a claim ("document rolled back"); tests
write only to scratch folders; tests never assume the machine's state beyond the Beef install and
the paths named above.

## Verifying the UI

**Rule (owner, 2026-10-12): a change that touches anything drawn is not done until someone has looked at it rendered.**
That means every panel, popup, dialog, node, pin control, canvas overlay or theme change, however small. Before the
branch is merged:

1. Capture the changed surface in the real editor (the `VB_SELFTEST` shot paths or a PrintWindow capture of the
   editor window) at 1280x800 and 1920x1080, in Dark and Darker, at 100% and at 125% display scale (this PC runs
   125%; `VB_UI_SCALE` gives the other), in every state the change touches: empty, filled, hover, open popup,
   error, and the first frame after opening as well as the settled frame (a first-frame glitch is still a defect).
2. Look at every capture yourself, zoomed crops included, and check: nothing overlaps, clips or overflows; edges
   and spacing line up with the rows around it; text is readable and not cut; no placeholder copy; the session
   log has no `[ASSERT]` line.
3. Fix what you see and capture again. Record the capture names in the report or commit message; a capture that
   nobody looked at counts for nothing.

The editor was verified by driving a real window:

* Set **`VB_HOME`** to a scratch folder so the run uses its own settings, layout, logs, recovery
  journal and symbol cache instead of `%LOCALAPPDATA%\VisualBeef`.
* The session log (`<VB_HOME>\logs\visualbeef-<date>.log`) has every Output Log line, including
  `Index:` timings and the BeefBuild command line, so most checks need no screenshot.
* **Host asserts are failures** (`SelfTest.bf`): an ImGui or SDL assert in the host logs one `[ASSERT] <expr> at <file>:<line>`
  line per site and shows no dialog (see [Architecture.md](Architecture.md#host-asserts)). Every editor test run ends with the check
  `no host asserts ([ASSERT] lines in the session log: N)` before `done failures=N`, so an `[ASSERT]` line makes that run fail.
  Any editor-driven run (`VB_SELFTEST=...`) counts, and a plain run with no `VB_SELFTEST` still logs the line for a developer.
* Crash reports and recovery: **`VB_DEBUG_CRASH_TEST=dirty`** dirties the open document and
  crashes (access violation) 45 frames after start: expect `logs\visualbeef-crash-*.log` and
  `.dmp`, a `.vbrec` in `recovery\<pid>-...\`, the Beef runtime's "Fatal Error!" dialog (kill
  the process by id), and **Recover unsaved changes?** on the next start. `=fatal` checks the
  `Runtime.FatalError` path, `=thread` a crash on a worker thread.

* **`VB_SELFTEST=ids`**: opens the Node menu on the open graph, walks seven searches and the Library tree drawn open, and fails if any two rows drawn in one frame share an ImGui ID (`[SELFTEST] ok   ids: ...  0 conflicting IDs`). Use a project with the same class name in two namespaces.
* **This tests in the running editor**: `VB_SELFTEST=rename-undo,move-undo,find-refs,openall`
  (any subset; also `open:Type.Method()`, `fit`, `select:Kind:Text` to set up a capture) drives the
  editor through the same calls its UI makes once indexing is done and logs `[SELFTEST] ok ...` /
  `[SELFTEST] FAIL ...` and `[SELFTEST] done failures=N` to the session log (`SelfTest.bf`).
  rename-undo / move-undo / find-refs expect a project with a `Player` class whose `mHealth` field
  is used in `Player.Hit(int)` and in another file. `openall` opens every function of the project
  in a tab, lets it draw, and closes it; with `VB_NO_IDLE=1` and `--view` (read-only) it ran over
  `<UnrealUMP>` (2,084 functions, all drawn, no crash) in about 100 s.
  2026-10-10: rename-undo confirmed that one undo / redo of a project rename from either file moves
  both files (the group undo works; nothing to fix), move-undo that a drag is one undo step that
  leaves the text clean, find-refs 6 references in 2 files.
* **The end-to-end session** (`VB_SELFTEST=session`, `SelfTestSession.bf`): on a scratch project
  with a `GameBase` class (a virtual `Tick(float dt)`), an `Other` class and a `Main`, it walks the user
  path through the calls the UI makes: Project Browser > New Class `Greeter : GameBase`, two variables,
  three functions, nodes picked from the Node menu (Return with a typed value, the print call, a
  Branch, `IsReady()` as a Value call into its Condition, `Ping()` with its Receiver left as `this`, a
  Return on the False arm), the Tick override from the Override list with a call added after the parent
  call, Save All, Compile (indicator green), an edit (yellow), undo / redo (green again), Del on a node
  and its undo, an `Other` wired into `Ping`'s Receiver (the error "Receiver must be a Greeter; the wire
  brings an Other." on the node, nothing written), an unknown name in the print pin (compile fails,
  indicator red, the error on that node), the fix (green), and a close / reopen of the file (text byte
  for byte, node positions, graphs, indicator green). Between the compile error and its fix (17b) the print with the
  error is deleted (no node shows the error, its Problems row is marked), a new print is placed and typed (no error on
  it or any other node) and three undos bring the old one back with its error; at the end (21) a function with
  `let a = scope Other();` and `Other b = .();`: the Construct's Type and b's Variable Type changed to `GameBase` the way
  Properties does it, the Locals' pins and header colour follow at once, undo restores, the file is left as saved.
  Captures `nodeerr-before`, `nodeerr-after-add`, `local-before`, `local-after`. 2026-10-10: 37 checks, `done failures=0`,
  at 1280x800 and 1920x1080; 2026-10-11 (steps 22-24 now run: constructors, Context Sensitive, no silent writes - Construct set to `scope` is written and compiles, type-less shows its error; capture `scope-error`): 75 session checks, `done failures=0`, Dark 1280x800 only; 2026-10-11: 56 session checks, `done failures=0`, Dark and Darker,
  1280x800 and 1920x1080.
  Then the node hotkeys (steps 27-32; 21-26 on the branch): the defaults in `settings.json`
  and every default key naming a node the Node menu offers, B held + a click on empty canvas (a second Branch at the
  click, unconnected, code unchanged), P pressed while a wire is dragged from Ping's flow output (a print wired after
  Ping, written after `Ping();`), a star on Console.Write and the key-capture control (B refused naming Branch, C
  refused, K assigned, Esc clears it, K again, `settings.json` checked), K while dragging from the print
  (`Console.Write("from K");` after it), then undos by depth back to where the hotkey steps began (the saved text, the original node count, no graph errors), redos (the nodes come back) and undos again (steps 32; 108 session checks). The letters are fed to ImGui as key
  events (`ImGuiIO_AddKeyEvent`), so the Sheet's own key reading is exercised; the click and the wire drag are the
  calls the canvas makes. 2026-10-10: 37 checks, `done failures=0`, at 1280x800 and 1920x1080; 2026-10-11 with the
  node hotkeys: 60 checks, `done failures=0` (1280x800).
  **`debug`** follows `session` on the same project (`VB_SELFTEST=session,debug`; the scratch project's
  `Main` must call `Greeter.Hello()`): F9 on the print node (saved in `settings.json`), Start Debugging
  (compile in Debug, launch), the stop on that node with its Sheet open, the print's pin value, Locals,
  `mCount`, two Step Overs (Branch, then Ping), Continue to exit code 0 with "Hello" in Debug Output, the
  breakpoint removed. With `VB_SHOTS` it waits for a capture `debug-stopped` at the stop. 2026-10-11:
  `done failures=0` (2026-10-11, 0.1.4 merge: `session` 68 checks + 14 debug checks; step 22 is the constructors flow: dimmed defaults, a second constructor, the duplicate refusal, back to dimmed, all undone; step 23 the Context Sensitive checkbox: a pin drag filters the Node menu, no pin filters nothing).
  Step 25 (ownership and initial values, 8 checks): Add Variable `Other mApp` Owned, made here writes
  `= new .() ~ delete _`, Properties reads it back, Ownership > Reference leaves `public Other mApp;`,
  `mCount` set to 42, a `DayOfWeek` member with `.Friday` picked from the index, and undo restores the
  text. 
  Step 24 (no silent writes): a Construct set to `scope` wired into Ping's Receiver is written and compiles; with its Type cleared the node shows an error and the file keeps its text (capture `scope-error`).
  Step 26 (set on create, 6 checks): two variables marked, the create constructor, the Construct node with two inputs wired into a call (the pin defaults come from the variables' Initial values: `new Greeter(1, null)`), the class's plain `public this()` written next to it so a scratch `Main` with `scope Greeter()` still compiles, compile green, undone.
  Ordering: the scratch project's `Main` may call `scope Greeter()`; step 26 (set on create) leaves the class with only the create constructor `this(int count, Other other)`, so it writes the plain `public this()` next to it before the compile of step 28, and `session,debug` then compiles and runs. Steps 24 and 25 run before it and leave the file as saved. 2026-10-11, 0.1.6 merge: `session,debug` on a fresh scratch project (`Main` = `let g = scope Greeter(); g.Hello();`) `done failures=0` with 105 session checks + 14 debug checks. 2026-10-12, 0.1.7 merge: `session,debug` `done failures=0` with 105 session checks + 20 debug checks (debug step 7, the reload while stopped, adds 6); `reload-check`, `unreadable` (11), `nodoc` (2 `ok` lines), `open:Reader.Read(),ids` (0 conflicting IDs, 21,205 rows) each `done failures=0`.
  2026-10-11, 0.1.5 merge: `session,debug` `done failures=0` with 82 session checks + 14 debug checks (the scratch project's `Main` is `Greeter g = scope .(); g.Hello();`); `reload-check` 3 checks, `unreadable` 11 checks, `open:Reader.Read(),ids` 0 conflicting IDs (21,195 rows), each `done failures=0`.
  **`reload-check`** is the second run in a new process on the same project and `VB_HOME`: the file
  opens unchanged, its graphs check clean, the indicator is green.
* **`newcomer`** (`VB_SELFTEST=newcomer`, `SelfTestNewcomer.bf`; an empty scratch folder as the project, a fresh `VB_HOME`): a first-time user's path through the calls the UI makes. File > New Project `Mod`, New Struct `Point`, New Interface `IGreeter` with a function (written as a declaration), New Class `Greeter` implementing it (the stub), Add Variable `List<int>` (Owned, made here; `using System.Collections;` added) and `int mCount = 3`, a constructor `(int start)`, Set on create (refused on `mCount` because `this(int)` exists, then a `String mName`), a For Loop with a print, `TryGet(out int value)` with Set value and Return, `Run` with a Defer, a call, a Branch on `TryGet`'s value and the out pin printed, then in `Main` Construct Greeter (from another file, with the create constructor's input), Defer -> Delete and Run on its Receiver, Save All, a Release compile, close / reopen byte for byte, Reload node, Reload Sheet, undo / redo / undo, and a debugger stop on the print in the loop (`i = 0`) then Continue to exit code 0. `[NEWCOMER]` lines log what each chooser offered and the code written. 2026-10-11: 15 checks, `done failures=0`; the program prints `Hello from Mod`, 0-9, 3, `Run done`. 2026-10-11: 25 checks, `done failures=0`; added: the For Loop's Counter pin `i` wired into the print and read back after reopen, `TryGet` made through the Add Function dialog's Inputs rows with Passing out (the chooser offers value, out, ref, in), Properties > Inputs reads out and writes ref (undone), the Return in `TryGet` starts with `false`, the Set of the parameter labels its pin Variable, the template's print in `Main` takes Object and accepts a wired int, a bare Construct Greeter shows "needs a constructor" until one is chosen.
* **`modauthor`** (`VB_SELFTEST=modauthor`, `SelfTestModAuthor.bf`; an empty scratch folder as the project, a fresh `VB_HOME`, the game SDK in `VB_MODAUTHOR_SDK`, default `D:\UnrealUMP\UnrealUMP\Sdks\HogwartsLegacySDK`): a first UMP mod. File > New Project > UMP Mod `Hello Mod` with the Game SDK row resolved (game id, UMP libraries, runtime ABI), the OnWorldReady override, `UWorld* mWorld`, `bool mLevelLogged`, `String mConfigText`, a static `uint64 OnDaysInYear(uint64 year)` returning `Original_DaysInYear(year)`, Hook Days In Year in Initialize with OnDaysInYear picked from its Callback pin's Node menu, File.ReadAllText of the mod's ModConfig.json (`using System.IO;` added) and a second Log of it, Tick's Branch / Get Current Level Name (bool input starts `false`) / Set, Shutdown's Remove All, Save All, a Release compile to `HelloMod.dll`, ModConfig.json checked against UMP's docs/Mods.md and `Info()`, close / reopen, Reload Sheet, Reload node and identity commits byte for byte. `[MODAUTHOR]` lines log Node menu timings and what each chooser offered. 2026-10-11: 22 checks, `done failures=0` (also as `newcomer,modauthor` in one run). 2026-10-11: 42 checks over UMP's v5 SDK: the hook part uses the Node menu only (Try hook with a Branch on its bool, Call original through two Casts, ReadModFile, Get ModDirectoryPath, To Owned String, Unhook with its unread-Result note), catalog and raw-name search checks. `newproject-mod:<sdk folder>` opens the New Project dialog on UMP Mod for captures (`close-popups` closes it).
* **`nodoc`** (`VB_SELFTEST=nodoc`, `SelfTest.bf`; run with no project, a fresh `VB_HOME`): asks for the Add Variable and Add Function dialogs and Type Settings with no document loaded. Add Variable / Add Function need a selected type: with no document they are refused (counted in `mDialogRefusals`, nothing opens) and `FindType` returns null. Before the fix the first frame crashed (access violation reading null in `FindType`, `Doc.Unit` is null for the empty document). 2026-10-11: 3 checks, `done failures=0`.
* **`disk`** (`VB_SELFTEST=disk`, chained after `session,debug` as `session,debug,disk`, or in a second process on the project `session` left, like `reload-check`, with `VB_SELFTEST_DELETE_OK=1`. 2026-10-12, undoplace: `session,debug,disk` chains, 108 + 20 + 17 checks `done failures=0`; it used to fail its first save because session step 32 stopped undoing when the text equalled the saved file and left the Branch and the value-less print in Hello's graph. `reload-check` does not follow `disk` (the scratch `src` was deleted and rewritten, no compile record). 2026-10-12, 0.1.7 merge: `disk` 17 checks `done failures=0`; `SelfTestDisk.bf`, 17 checks): the disk going wrong under the open editor, through
  Save All and Reload From Disk. A read-only `Greeter.bf`: Save All is refused ("Save failed: Could not replace ... The original
  file is untouched."), the file is byte for byte as before, the edit stays in memory unsaved, and it saves once the file is
  writable. With `VB_SELFTEST_DELETE_OK=1` the step also deletes the scratch project's `src` folder under the open document:
  the per-frame external-change check leaves the edit alone, Save All fails with a message ("Could not write ...tmp"), the edit
  is still in memory, Reload From Disk says "Could not reload ...: the file cannot be read. Your text in the editor is
  unchanged." (it used to return silently), and with the folder back the edit saves. `debug` step 7 reloads from disk while
  stopped: identical text keeps the stop marker; a file changed on disk (two lines inserted) is taken, the session stays stopped
  with its call stack and values, the stale marker is hidden with a status line saying why (the marker comes from line numbers of
  the program as built), and with the original text back the frame shows on the same node again.
* **`unreadable`** (`VB_SELFTEST=unreadable`, `SelfTest.bf`): on a scratch project holding the 2026-10-11 report
  (`Program.bf` with `public static var Main()` on line 11 and `Run()` after it) and a `Bad.bf` with
  `public default Bad(int a)` on line 3: Problems lists `Program.Main` and `C.Bad` without a compile, `Main` has a
  graph whose entry node carries the error, `Run()` is listed, a jump to line 11 opens `Program.Main`, to line 7 (a
  member variable) Beef Source > File at line 7, to `Bad.bf` line 3 the red read-only node; a save without an edit
  leaves the file byte for byte; Return Type `void` clears the error and undo restores the text. 2026-10-11: 11
  checks, `done failures=0`; `session` on a fresh scratch project after it: 41 checks, `done failures=0`.
* **Captures**: `shot:<name>` logs `[SELFTEST] shot <name>` and waits (at most 20 s) until
  `<VB_SHOTS>\<name>.done` exists, so an outside script can take the picture with `PrintWindow`; without
  `VB_SHOTS` it does nothing. `size:<W>x<H>` does the same as `shot:size-<W>x<H>` (the script resizes the
  window). Set-up steps for captures: `theme:0` / `theme:1` (Dark / Darker), `panel:<browser | properties
  | outline | log | problems | source | find>`, `typesettings:<Type>`, `menu` / `menu-close` (the Node
  menu), `menu-pin` (the Node menu opened from the first value output pin: Context Sensitive enabled), `hotkey-menu` (the Node menu at the canvas's top-left corner), `hotkey-capture:<label>` (the key-capture
  control waiting on that favorite), `prefs:<n>` / `prefs-close` (Editor Preferences on a category, 4 = Node Hotkeys), `override:<Type>:<Member>`, `override-menu:<Type>` (the Outline's Override dropdown, left open),
  `newclass:<Parent>:<Interface>` (the New Class dialog, left open), `status:<text>` (the status bar
  text; empty hides a scratch path), `var:<Type>.<member>` (a member variable in Properties, as an Outline
  click), `addvar:<Type>:<VarType>:<name>` (the Add Variable dialog, left open) and `close-popups` (closes
  it), `initbuf:<text>` (the Initial Value box shows `<text>` as if typed: the error state). `select:` also
  brings the node to the middle of the canvas.
  Steps wait for indexing, a pending commit and the first-start focus of the Project Browser.
* **`VB_UI_SCALE`** (for example `1.25`) replaces the monitor's display scale, so a 125 % or 150 %
  layout can be checked on a 100 % screen.
* Launch the Debug or Release exe in a scratch copy of a project (never your real repo).
* **`VB_DEBUG_NODE_MENU_SEARCH=<text>`** pre-fills the node menu's search box each time it opens,
  since typing cannot be posted (below); picking a result is still a posted click. The UMP end-to-end
  run in [UMP-Integration.md](UMP-Integration.md#end-to-end-check) used it.
* Send **window messages** (mouse move, button, wheel, `WM_CHAR`) with `PostMessage`. Do not use
  global input injection.
* Capture with **`PrintWindow`** (flag 2, `PW_RENDERFULLCONTENT`), not screen capture, so other windows
  never leak in.
* Kill by process id when finished.
* Known limits: posted key messages do not reach SDL's keyboard state (so typing into the node
  menu and keyboard shortcuts cannot be scripted this way), and a posted click needs the mouse to
  have hovered the control a frame earlier.

## Tests: calls and receivers

`VisualBeefTests calls` (also part of `flow` and `edits`): 75 checks in 8 groups: the three shapes
with and without a resolver (byte-exact identity commit and forced regeneration), the owner's three
Receiver errors and the cases that must not be errors, required inputs / `ref` / wire and literal
types, out and ref arguments read from code, out pins written (`var`, `?`, hoisted, other path,
unknown type, loop condition, two names, pure call), `[Pin(Out=true)]`, overload ties, layout-key
continuity. `factory` has a case per shape (static with and without qualifier, this, This wired, out
read and unread, ref). `compile` builds and runs this in a derived class, This, a qualified static,
`var` / `?` / hoisted / loop-declared out values, `ref` and `[Pin(Out=true)]`
(`CallsSelfStaticOutRef`), and refuses this in a static method (`RefuseTargetSelfInStatic`).
`roundtrip` and `orphans` fail on any refused commit of real code, so a validator false positive on
the UMP sources shows up as a failure. See [Testing.md](Testing.md).

## Tests: classes and members

`VisualBeefTests classes` (141 checks in 7 groups): modifier words and attribute lists; declaration
spans for every declaration form (also run by `parser`); each Type Settings edit with its exact
text and undo; inheritance (Override list, missing members, document errors, stubs, override
signatures for virtual / protected-out / property / generic bases, abstract members, unknown bases,
sealed and struct parents, the pickers); graph checks (the Entry error, the Base node read, written
and refused in a static function, accessor graphs); renames across two files (field, type, refused
plans, parameter and local); templates (the UMP mod's graphs and Override list). `compile` builds
and runs a class hierarchy with an interface whose stubs and overrides were made with these APIs
(`ClassHierarchyInterface`), an Tick override from the Override dropdown (`OverrideTickFromDropdown`),
and refuses an override with nothing to override (`RefuseOverrideWithoutBase`).

## Coverage: lifetime nodes on UMP code

`VisualBeefTests coverage` (the audit's probe, now a command) over UMP `src`, `UMPRuntime/src` and
`UnrealSDKCore/src` with the editor's setup (1,078 method bodies):

| Measure | Before | After |
|---|---|---|
| Method bodies with no Code node | 779 (72.3 %) | 1,041 (96.6 %) |
| Method bodies with no Code and no Expression node (no text at all) | 562 (52.1 %) | 1,013 (94.0 %) |
| Code nodes | 460 (`using` 171, `defer` 147, `delete` 34, pattern tests 18, ...) | 104 (`const`, lambdas, nested blocks, casts `(.)`, ...) |
| Expression nodes | 873 (pattern tests 449, `scope` 367, `new` 26) | 37 |
| Pin texts holding `scope ...` / `new ...` / a pattern test | 1,444 / 169 / 223 | 7 / 17 / 0 |
| New nodes | | Construct 2,120, Result 430, Using 179, Defer 150, Delete 80 |

What is left as text is mostly lambdas and delegates (`new () => ...`, gap 5), `const` locals,
casts to `(.)` and nested `{ }` blocks.

After the last text forms (2026-10-10, same command; the UMP tree had grown to 162 files, 1,366
bodies):

| Measure | Before | After |
|---|---|---|
| Method bodies with no Code node | 1,069 of 1,106 (96.7 %) | 1,361 of 1,366 (99.6 %) |
| Method bodies with no Code and no Expression node (no text at all) | 1,040 (94.0 %) | 1,345 (98.5 %) |
| Code / Expression nodes | 104 / 38 | 10 / 20 |
| Pin values holding a lambda | 93 | 3 |
| New nodes | | Format 1,101, Lambda 157, Scope 54, LocalFunc 2, DoWhile (`repeat`) 3 |
| ClockWork (150 bodies): no Code / no text | 144 (96.0 %) / 133 (88.7 %) | 149 (99.3 %) / 148 (98.7 %) |

## Tests: lifetime nodes

* `VisualBeefTests textforms` (`TextFormTests.bf`): the last text forms: parsing of each, graph
  shapes (lambda parameters, Returns and Body, captures, Create Delegate, event `+=`, local
  functions, Format templates and holes, `const` / `ref`, `(.)`, `.()`, `repeat`, attributes,
  payload switches), identity commit and forced regeneration byte for byte and back to the same
  graph, a statement added to a lambda body, a ternary in a hole, layout keys. `compile`:
  `TextFormsFromCode` regenerates a program using all of them byte for byte and runs it.
* `VisualBeefTests lifetime` (`LifetimeTests.bf`): parsing of every form, graph shapes (types,
  constructor labels, wiring), identity commits byte for byte and forced regeneration reading back
  as the same graphs, code written for nodes made with `NodeFactory` (and read back and regenerated
  to the same text), every lifetime rule above (error, warning, or none), and the Defer / Using
  body edits.
* `flow` runs the Defer / Using body group too (a statement added to `defer delete x;`, K&R
  `defer {` / `using(...) {` headers kept, a node wired into a Defer body and after it refused, an
  `else if` chain of Result nodes regenerated byte for byte).
* `factory`: Construct (scope, new with a Defer -> Delete, array, inferred, string), Defer with a
  block, Using with and without a variable, Result on Ok and on Err.
* `compile`: `LifetimeFromCode` regenerates every statement of a program that uses all of them and
  runs it (a `scope` object freed at the end of its block, Defers in LIFO order, `using` disposing,
  `case .Ok(let n)`, `Try!`, `scope $"..."`, arrays); `LifetimeNewNodes` builds the same from
  `NodeFactory` nodes; `RefuseScopeAfterBlock`, `RefuseReturnInDefer`, `RefuseResultValueOutsideArm`.
* `coverage <dirs>` prints the table above (and the checks a dry generation reports on code as read).

## Tests: flow nodes

| Suite | What it checks |
|---|---|
| `VisualBeefTests flow` | counting For Loops (Counter / Start / Count pins, the forms that stay text, identity and forced regeneration byte for byte, a wired counter, rename and retype, undo), parsing of switch / macro shapes, why a switch stays a Code node, graph pins, byte-exact regeneration (comments, grouped labels, indented K&R switches, every macro), scripted edits (add / relabel / move / remove a case), merges and their refusal, state fields (names, `static`, no duplicates, pasted copies), refusals; edits inside Defer / Using bodies and Result `else if` chains |
| `VisualBeefTests factory` | each Switch / flow node from the node menu reads back as the same node (kind, pins, wiring) |
| `VisualBeefTests textforms` | payload switches, Scope blocks, `repeat`, attributes: parsing, shapes, byte-exact regeneration (see [Lifetime-Nodes.md](Lifetime-Nodes.md#the-last-text-forms)) |
| `VisualBeefTests compile` | builds and runs the generated code: switch on int / enum / string, adding a case, arms merging; Sequence, Do Once (with reset), Do N (counter, reset), Flip Flop (Is A), Gate starting closed and open (open / close / toggle), Multi Gate (one shot, loop, reset), and a switch + Do Once + Sequence nested in a loop |

## Tests: files and safety

`VisualBeefTests safety` (SafetyTests.bf) covers all of the above headless on real files in a
scratch folder, except the recovery journal and the crash path, which live in the editor and
were checked by running it (`VB_HOME` + `VB_DEBUG_CRASH_TEST=dirty`, see
[Editor-UI.md](Editor-UI.md#logs-crash-reports-recovery-settings)).

## Tests: debugger

* `VisualBeefTests debugmap <folders>`: every node with a line maps inside its function and back
  (see [Testing.md](Testing.md#debugmap)).
* `VisualBeefTests debug`: builds the `Debuggee` fixture in Debug and runs it under the engine:
  breakpoints from nodes, the stopped node, locals, values, Step Over / Into / Out, Continue to the
  exit code and output, a fault and Stop.
* `VB_SELFTEST=session,debug` in the editor: a breakpoint on the session's print node, Start
  Debugging, the stop, a pin value, two Step Overs, Continue to the end.
