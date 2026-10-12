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

Placeholders in the commands below: `<repo>` is this checkout, `<Corpus>` is the root of a large Beef code base
(a mod platform's checkout was used for the numbers below), `<CorpusA>`, `<CorpusB>` and `<CorpusC>` three of
its source folders (its launcher, runtime and SDK core sources), and `<ClockWork>` the ClockWorkEngine folder
(the corpus the long suites read; pass your own paths). `<scratch-dir>` is any empty folder for the output.

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
startpage
docs
update
host
workspace
vocabulary
stress
compile -out <scratch-dir>
debug -out <scratch-dir>
debugmap <CorpusA> <CorpusB> <CorpusC> <ClockWork>
roundtrip <CorpusA> <CorpusB> <CorpusC>
roundtrip -types <CorpusA> <CorpusB> <CorpusC>
roundtrip <CorpusA> <ClockWork> -out <scratch-dir>
orphans <CorpusA> <CorpusB> <CorpusC>
loadall <Corpus>
savecheck <CorpusA> <CorpusB> <CorpusC> <ClockWork>
inits "C:/Program Files/BeefLang/BeefLibs/corlib/src"
inits <CorpusA> <CorpusB> <CorpusC> <ClockWork>
```

Run them one at a time (the roundtrip / orphans / loadall runs are long and single-threaded;
on a shared machine start them at BelowNormal priority).

Lint: `powershell -ExecutionPolicy Bypass -File scripts\lint-scope-delete.ps1` prints `OK: no delete of a scope-allocated object` (exit 0). Run it before the full run; it is the same check the owner's other Beef projects run.

Expected output on the tree this page was written against (2026-10-10, after the last text forms, `#if` keys, the node menu on the indexer, Find References, the overload choice and the robustness pass):

| Command | Expected last line | Time |
|---|---|---|
| `edits` | `total: edits ok, factory failures 0, flow failures 0` (edit scenarios 1-26 with 0 failures; 25 (2026-10-12) is the text pins, 34 checks of `OverloadTests.RunEdits`; 26 (2026-10-12) is variables dropped on pins, 25 checks of `DragVarTests.RunEdits`: a Get into an input, a Set from an output after the statement and before the statement using a value node, refusals with their reasons (text / float onto int, a flow pin, a Set's Variable pin, read-only), a wired input replaced, each one undo step; factory 63 cases, flow 157 checks including the 75 call checks, the 7 Defer / Using body checks and the 3 local variable splice checks; the 7 Defer / Using body checks) | seconds |
| `flow` | `flow checks: 251  failures: 0` (251 includes the 48 Math Expression checks of `calls`; 203 before them includes 6 loop-header checks: a bound that mixes `&&` or `||` stays header text) (59 switch / macro checks + 13 counting For Loop checks + 75 call checks + 7 Defer / Using body checks + 3 `LocalsTests.RunFlow`: a Set spliced after a call, after the local variables) | < 1 s |
| `calls` | `call checks: 126  failures: 0` (3 unread Result notes: Set keeps it, String.AppendF has none; + 48 `MathExprTests.RunNode`: pins of ten formulas, nine refusals, eleven result types, the node's pins following its text, the code with values in place and parenthesised, a call read twice kept in a variable, a Branch condition, an open input and an unknown type refused) | < 1 s |
| `lifetime` | `lifetime checks: 126  failures: 0` (14 in "deleting Locals": a Local that later nodes use is not deleted, with the `scope` wording) | < 1 s |
| `textforms` | `text form checks: 169  failures: 0` (+ 41 `OverloadTests.RunTextForms` and + 10 `#if` / `#endif` member edits (2026-10-12): overloads that follow the values; + 27 `MathExprTests.RunInit`: Initial Value > Expression on `int x = 0;` stays chosen, `a + b` written and read back after a reload, back to Number, refusals, a Local's value) | < 1 s |
| `classes` | `class checks: 575  failures: 0` (15 `DragVarTests.RunClasses` (2026-10-12): Add Variable's type picker: the container row split and joined back, a typed `Dictionary<String, int>` taken and `void` / `var` refused, the preview line equal to the line Create writes; 29 `MathExprTests.RunRoundTrip` (2026-10-12): `#math` / `#orphanmath` records written, the nodes back on reload with wires, values, place and chosen type, identity and regenerated commits byte for byte, no side file or a changed formula reads as usual, undo after a text edit, + 53 `LocalsTests.RunClasses` (2026-10-12): local variables read, written, added / renamed / retyped / reordered / removed / moved, outputs on Return nodes and calls, a signature change keeps its function's key, variables made from a pin in one undo step, + 31 Node Library: kind change, static writing, validator, catalog categories, + 179 + 136 in the ownership and initial values group + 38 in set on create, + 19 from the 2026-10-11 passover, + 26 from the suspected-issues pass: typed primitives, a rename with a refused commit, constructor chains, code-point characters, + 12 from the newcomer pass: interface functions, usings, overload ties, + 10 Passing: the chooser's choices, out / ref / in written and read back, + 14 Return defaults per type and a fresh bool function written with `return false;`, + 3 Set labels: Variable on Set nodes, Receiver on calls, + 5 Construct needs a constructor: the error, the classes that need no choice, cleared by an input, a warning when read from code, + 5 a print read back: WriteLine(StringView line) with its Message pin, byte for byte, a wired int accepted and switching it to WriteLine(Object obj)) | < 1 s |
| `safety` | `safety: failures=0` (23 groups on Windows, 209 `ok` lines; groups 21-23 (2026-10-12): graph edits not written, shared undo copies and the byte budget, side files kept; group 24 (2026-10-12, 30 checks): what a compile reads (`BuildInputs`), the up-to-date record (`CompileInputs`), the source hash read once per change) | seconds |
| `vocabulary` | `vocabulary: source files=132 string literals=12194 docs=23 host-rule files=233 host-rule hits=0 hits=0 failures=0` | < 1 s |
| `parser` | `parser checks: 305  failures: 0` (8 for a `using` without `;`; then the 32 declaration-form checks of `classes`; exit code covers both) | < 1 s |
| `catalog` | `catalog checks: 257 passed, 0 failed` (23 of them the corlib overloads: Console / Debug Write and WriteLine, Message / Format / Values, an int dropped on the text pin) | under 1 s once the corlib cache exists |
| `diagnostics` | `diagnostics checks: 49  failures: 0` | < 1 s |
| `hotkeys` | `hotkey checks: 36  failures: 0` | < 1 s |
| `startpage` | `startpage checks: 38  failures: 0` (the folder name made from a typed project name, the recent projects list, stored paths, the "opened ..." wording; no window) | < 1 s |
| `docs [folder]` | `docs checks: 54  failures: 0` (front matter, the Markdown subset, anchors, link resolution, search, and the real `audience: user` pages of the docs folder: they parse, are in front-matter order, every picture exists, every link leads somewhere; links to developer pages are counted, not failures) | < 1 s |
| `update` | `update checks: 98  failures: 0` | < 1 s |
| `host` | `host checks: 92  failures: 0` (command line, `.vbproject`, templates, the Fixture Kit node library, `host-install.json`; 2026-10-12: libraries written relative and found after a move, a missing one reported, template creation all or nothing) | < 1 s |
| `workspace` | `workspace checks: 107  failures: 0` (TomlText, paths, workspace edits, Project Settings, project folders renamed and deleted, projects renamed) | < 1 s |
| `workspace -build` | `workspace checks: 109  failures: 0` (the same plus BeefBuild on a workspace edited this way, and its program run) | about 5 s |
| `stress` | `stress checks: 68  failures: 0` (4 context checks + 16 runs of 50 random edits x 4 checks) | about 2 s |
| `debug -out <dir>` | `debug checks: 83  failures: 0` (9 for a breakpoint on a Local declaration) | about 8 s (one small BeefBuild, three runs under the debugger, two attaches) |
| `debugmap` (the three corpus folders, ClockWork) | `debugmap: files=204 methods=1702 statements=25724 values=49778 without-line=57 failures=0` | about 15 s |
| `host -lib <a large generated library>` | the `host` checks plus load time, catalog size, output pins and callback nodes of that library | 18 s on the first run of a 20k-function library (parse + cache), about 1 s after |
| `compile -out <dir>` | `compile: cases=44 compiled=32 refusals=12 failures=0` (`MathExpression`: Math.Sqrt over an int and a float, a cast, int arithmetic, run: `len 10 7 5`; `TextPinsAndOverloads`: typed texts written with quotes and escapes, a char8* pin, an overload chosen with a cast) | about 1.5 s warm, longer on the first BeefBuild |
| `roundtrip` (the three corpus folders) | `files=174 methods=1552 failures=0 broken=0` | about 15 s |
| `roundtrip -types` (same three) | same | about 15 s |
| `roundtrip <CorpusA> <ClockWork> -out <dir>` | `files=106 methods=1235 failures=0 broken=0` | about 8 s |
| `orphans` (same three corpus folders) | `orphans: files=197 methods=2034 failures=0` | about 25 s |
| `loadall <Corpus>` | `loadall: files=323 methods=3213 nodes=156944 ... warnings=22 failures=0` (warnings were 499: 477 were String.AppendF) | about 6-30 s (most of it indexing the SDKs the first time) |
| `inits` corlib, then the three corpus folders + ClockWork | one line per folder ending `failures=0`, then `inits: failures=0` (counts in [`inits`](#inits--v--noflip-files-or-folders)) | about 25 s for corlib, 10 s for the rest |
| `savecheck` (the three corpus folders + ClockWork) | `savecheck: files=204 edits=353 failures=0` (all BeefLibs corlib + the corpus + ClockWork + the report project: `files=401 edits=659 failures=0`) | about 11 s |

The corpus is edited by other work, so its file and method counts drift; `failures=0` is what
matters.

If a count differs, the number of cases changed: update this table in the same commit.

## Commands

### `edits`
Runs three suites in one go and prints one total: `EditTests.Run()` (scripted graph-editing
scenarios), `FactoryTests.Run()` and `FlowTests.Run()`.

* **EditTests** (`EditTests.bf`, scenarios 1-25, about 275 checks; 25 is the text pins of `OverloadTests.RunEdits`: bare text
  written with quotes and escapes, one pair of typed quotes taken off, `$"` / `@"` written as typed, round trips, a
  quoted literal read from code and from the side file showing the bare text, a char8* pin): load a sample `Player.bf`, edit
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
unambiguous, undo; out-only overloads refused with a reason); overloads that follow the values
(`OverloadTests.RunTextForms`, [Calls-and-Receivers.md](Calls-and-Receivers.md#overloads)): a text literal
reads as `WriteLine(StringView line)` and an int as `WriteLine(Object obj)`, an int wired into a text pin, a
text typed into an Object pin, an empty node, the Node menu off an int, `Abs(double)` wired with an int or a
float, Properties' choice with a cast for a literal and for a wire, a pin removed and added back, a typed
number carried over to a float, an out overload refused, the Message / Format / Values labels; Find References (a field across two
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
`<Corpus>` (2026-10-10): `files=331 methods=2883 nodes=136007 failures=0`; on a scratch
copy of the three corpus folders with side files written and reloaded:
`files=150 methods=1190 sidecars=110 failures=0`.

### `coverage [-notypes] [-v] <folders>...`
The production audit's coverage probe as a command (`CoverageTests.bf`): loads every `.bf` file
with the editor's setup (ProjectIndex + TypeService, unless `-notypes`), builds every method graph
and prints the method bodies with no Code node and with no text node at all (no Code and no
Expression node), every node kind, the Code / Expression nodes and pin texts grouped by the
construct they start with (`using`, `defer`, `scope`, `case` pattern, lambda, ...), and what a dry
generation reports on code as read (the editor's first check). `-v` lists each text node, pin text
and report with its file and line. It measures, it does not fail. On the three corpus folders
(2026-10-10, after the last text forms): 1,361 of 1,366 bodies (99.6 %) have no Code node and 1,345
(98.4 %) no text at all, nothing reported (see [Coverage](#coverage-lifetime-nodes-on-a-large-code-base) for before / after).

### `safety`
File-safety scenarios on real files in a scratch folder **`vb_safety_tmp` under the current
directory** (created and removed by the test): 22 groups on Windows, 179 checks.
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
20 saved views (`#view` lines).
21 graph edits not written: a refused commit leaves the text as saved but `NeedsSave` true; undo onto a step taken while the commit was refused and redo keep its errors (the save is still refused, nothing written); undoing the edit clears it.
22 undo memory: 20 drags of one graph hold 20 copies of it, one of the other graph and one text; every undo and redo position comes back; over the byte budget the newest 10 steps stay and undo in order.
23 the side file is kept: a function hidden by an unclosed `(` keeps its positions and `#math` record through a save with an edit and opens at its position once fixed (a really gone function still loses them); a newer-format file is not written and the reason is kept for the editor; (Windows) a side file held with no sharing at load is reported, not written while held, and merged (its comment box kept, the new position saved) once readable.
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
Prints every declaration error the editor would show (a return type, parameter or member variable type that does not fit its place, see [Catalog-and-Types.md](Catalog-and-Types.md#what-a-type-field-accepts)) and a count. Use it on a new tree before trusting the rules: corlib, the corpus and ClockWork give `declaration errors=0`. The editor session test has 82 checks (41 before the 0.1.1 work) (step 20: an illegal `var` Return Type and a `void` variable are refused with the reason, file unchanged).

### `inits [-v] [-noflip] <files or folders>...`
Ownership and initial values on real code (`InitTests.bf`, [Classes-and-Members.md](Classes-and-Members.md#ownership-and-initial-values)).
For every member variable and auto-property with a value: the text after its name is read into a
choice (`MemberInit.Classify`) and written back, which must give the same bytes; writing the same
choice through `SetMemberInit` must leave the file unchanged; then it is flipped to another legal
choice (`Owned, made here` -> `Owned, set later`, `Reference` -> `Pointer`, ...) and back, which must
give the original file byte for byte (`T *name` pointers, written C style, are not flipped). Each
folder prints `files= members= custom= convertible= multi= flips= failures=`, the count per choice and
the ten most frequent Custom forms (`-v` lists every Custom member). 2026-10-11: corlib 2,061 members,
29 Custom (2 convertible), 24 Disposed with it, 2,030 flips; corpus A 997 / 3; corpus B 376 / 9 (36 Owned for
the run); corpus C 707 / 0; ClockWork 133 / 0; `failures=0` everywhere. Before Owned for the run and
Disposed with it (0.1.5): corlib 53 Custom, corpus B 45, the rest unchanged.

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
interpolated strings); the new-type templates and a host template's entry class (`ToolMain : ToolBase`: graphs, Override list,
OnLevelReady with its parent call); ownership and initial values (`InitTests.RunChecks`, 126 checks:
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

### `catalog-scale <lib-dir>`
Not an assertion suite: timings of indexing, the content-hash cache hit, the path cache hit, the
catalog build, and several searches on a large generated library (a generated game SDK with about
4,000+ nodes was used below). Without a folder it reads the `VB_SCALE_LIB` environment variable (the
library folder); when that is unset too it prints its usage and exits 2. Use it to catch performance
regressions.
It also times the catalog built the way the indexer does (`catalog prebuild` on the worker,
`catalog adopt` on the UI thread), the category tree, and typing "get actor location" one key at a
time from scratch and incrementally. Typical on this machine (Debug, 2026-10-10, a loaded
machine), a 75k-entry SDK: catalog 131 ms in place / prebuild 132 ms + adopt 2.0 ms, tree 7 ms, typing 485 ms
from scratch vs 228 ms incremental (worst key 27 ms), searches 1-35 ms; a 162k-entry SDK: catalog 445 ms /
adopt 3.8 ms, tree 21 ms, typing 1,101 vs 508 ms (worst key 60 ms), searches up to 83 ms.

### `catalog-scale -root <dir>`
Opens a whole folder exactly like the editor's background indexer (`IndexJob.Run` on the test
thread), with an empty cache (cold) and again (warm), then times a rescan of the same root, an
open with only the content-keyed caches, and how fast a running job stops after `Cancel`. On
`<Corpus>` (2026-10-10, Debug):

```
open root (cold): 11260 ms total; project index 403 ms, 266 files (3 generated SDK folders skipped); libraries 10858 ms, 4 stores [...] (0 from cache, 4 parsed, 29904 types)
open root (warm): 416 ms total; project index 405 ms, 266 files (3 generated SDK folders skipped); libraries 12 ms, 4 stores [...] (4 from cache, 0 parsed, 29904 types)
rescan same root: 85 ms (0 parsed, 266 reused)
open root (path cache dropped, content cache only): 900 ms; libraries 498 ms (4 from cache, 0 parsed)
cancel: worker stopped 36.5 ms after Cancel (done=True)
```

Before this change the same folder took 15.0 s cold and 16.0 s warm (751 files parsed as
project sources on every open, on the UI thread). The cache goes to `build\vbtest-cache\root`.

### `host [-lib <dir>]`
The host contract ([Host-Integration.md](Host-Integration.md)), `HostTests.bf`, 92 checks: the command line
(`EditorArgs.Parse`: `--version` with the host contract number, `--new-from-template` with `--name`, `--var`
and `--no-open`, the usage errors and exit codes, and the deprecated option of contract 1 mapped onto the new
one: a deprecation line, its values as template variables, with a template folder a fill-in of the existing
folder that keeps every file), the project manifest (`ProjectManifest`: every key, unknown keys ignored, a BOM,
write and read back, broken JSON, a `main` outside the project), project resolution
(`ProjectContract.ResolveTarget`: folder, `.vbproject` main, `.bf` file walking up to its project,
`BeefProj.toml`, relative `--file`, missing paths), templates with the fixture
`VisualBeefTests/fixtures/Host/Template` (`TemplateManifest`, the built-in names `Identifier` / `Slug`,
`@@Key@@` and `@@Key:str@@` substitutions, an unknown key, bad template folders, the files and `.vbproject`
written, a second run refused without writing, existing files kept, `ProjectContract.WriteFromTemplate` with
exit codes 1 and 2), generated libraries reached through a workspace dependency inside the opened folder (under
`build\`, with `*.g.bf` or a `.vblibrary` marker, not for an ordinary project) and a library only the
`.vbproject` names, the Fixture Kit node library (`VisualBeefTests/fixtures/Host/FixtureKit`: its own attribute
types, `[NodeLibrary("Fixture Kit")]`, the four `[CallbackNode]` roles and their callback pin, `[NodeHidden]`,
an attributed struct, search), and `host-install.json` (`InstallInfo.IsHostManaged`). With `-lib <dir>` it
also loads any large generated library and prints its load time, catalog size, output pins and callback nodes.

### `workspace [-build]`
The workspace and project files behind the Project Browser's project rows and Project Settings
(`WorkspaceTests.bf`, `VisualBeefCore/src/Document/WorkspaceFiles.bf`), 107 checks in 6 groups, all in scratch
folders under `%TEMP%\VisualBeefWorkspaceTests`. **toml text**: `TomlText` reads `[Projects]` (the Beef IDE's
form) and `Dependencies = {...}`, quoted keys, comments after values, multi-line arrays with escapes; a value
replaced in place keeps its comment, a key added to a table goes after its last key with the file's CRLF, inline
entries added / removed with their commas, an emptied configuration table removed, a missing table appended, and
`MiniToml` (library discovery, the debugger) reads the edited text. **paths**: relative paths with `..`, the
workspace folder as `.`, another drive, `Resolve`, project names. **workspace**: File > New Project's
registration into a `[Projects]` workspace (one Projects table, the comment and the unknown key kept), an inline
workspace and a missing one; Add Existing Project by its `[Project] Name` and a `../` path, refused twice and
without BeefProj.toml; Set as Startup Project; read-only mode writes nothing. **project settings**: build kinds
(Console, Dynamic library with `BuildKind = "DynamicLib"` in every configuration and back, Library, Windows),
dependencies in the `[Dependencies]` form (no write when unchanged), a post-build command list with quotes,
a debug command, both cleared (the table goes), the startup object. **project folders**: Core renamed to Engine
(the workspace entry, `StartupProject`, `Locked`, `Name`, the dependents in both forms, `.vbproject` main and a
relative library, the absolute one and a host key kept), a folder around a project, a project named unlike its
folder, a rename onto another project's name (the path follows, the name stays), and the Engine folder deleted
(the project, its dependents' entries and the startup project). **project rename** (`WorkspaceFiles.RenameProject`, the call
Project Settings' Name field and Rename Project... make): a name another project has, an empty one, one starting with a
digit and one with a space are refused with nothing written; Core renamed to Engine writes the `[Projects]` key (the path
stays), `StartupProject`, `Locked` and `Unlocked`, `Name`, the dependents in both forms, one log line per file change and a
`.bak` of each file; the folder then renamed through `FolderMoved` (folder box on) leaves the name alone, follows with the
path and `.vbproject` and does not rename a dependency twice; a name with a dot is written as a quoted key with the folder
kept (box off); a table-form `[Projects]` and a project file with no `Name` (one is added); the same name changes nothing;
read-only mode writes nothing. With `-build` two projects are made, one renamed
through its folder, a dependency added, and BeefBuild builds and runs the result (`answer 42`).

### `vocabulary [root] [-v]`
Reads the string literals of `VisualBeefCore/src`, `VisualBeefEditor/src` and `VisualBeefMeta/src`
(comments and interpolation holes skipped) and every page of `docs/` and `README.md`, and fails on a
banned whole word (the list is at the top of `VocabularyTests.bf`: the older terms of [Vocabulary.md](Vocabulary.md)
and the words that name their old pins and panels). Only Beef keywords and ids nobody sees (the old pin ids and
type names the layout hashes keep) are allowed, and
`CHANGELOG.md`, `Roadmap.md`, the audit reports and `Vocabulary.md` itself are skipped (history and the
mapping). It also enforces the host rule ([Vocabulary.md](Vocabulary.md#host-names)) on every line of the
sources (comments included), the test fixtures, `scripts/`, `packaging/` and every doc but `CHANGELOG.md`:
the host words and identifier prefixes listed in `VocabularyTests.bf` (the only file allowed to hold them).
The count line ends `host-rule files=N host-rule hits=0 hits=0 failures=0`. Run it from the repository root or
pass the root.

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

### `update`

The updater without the network (`UpdateTests.bf`; [Releasing.md](Releasing.md)): base64, SHA-512 (FIPS 180-4 `abc`),
SHA-256 of a file, the JSON reader (escapes, surrogate pairs, depth limit, trailing comma, raw line break); Ed25519
RFC 8032 test 1 (public key, signature, verify, changed signature, other message); the descriptor `scripts/release.mjs
vectors` signs with its fixed TEST seed: fields, the canonical text byte for byte, verification in Beef, an empty key list
("not set up"), another key, a key list, every signed field changed (refused), the unsigned notes changed (still
verifies), a malformed and a missing signature; a descriptor signed in Beef with a key made at test time; shape refusals
(not JSON, an array, format 2, another product, an unknown channel, sequence 0 or fractional, a tag or file name with a
path, an upper-case or short SHA-256, a negative size, a platform twice, a line break in a signed field, over 64 KiB);
the sequence rules (higher offered, equal and lower refused, unknown sequence falls back to the version, never a
downgrade); version order; the platform file per kind of install; a download with the right / wrong SHA-256 and size;
the package layout check; swap and restore of an install folder (files and folders replaced, user files kept, the
`previous` copy, the restore byte for byte, new files removed, an empty package refused); the preview release list
(drafts and releases without `release.json` skipped, an error object, an unsafe tag); `installed.json` and
`last-result.json`; the HTTP header reader (status and ETag of the last redirect hop, 304). 98 checks, in Debug and Release.

`update -net` (by hand, needs the network, not in CI): a real stable and preview check against the public repository
through curl, the ETag cache of the releases list, a download through GitHub's redirect with progress, and the size cap.
2026-10-11: 8 checks, `failures: 0` (no release published yet: "No VisualBeef release is published yet." on both).

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
by the fault on the Set node, and Stop; then a run with `loop`: Pause shows the main thread down to `Main`, Continue, Stop.
Then attach: the PDB named in the exe's debug record exists, attaching to a process that does not
exist fails with a reason, the fixture started on its own (`loop`, not under the debugger) is found by
its module, attached by process id; the breakpoint on the Sleep node in the loop stops it (bound in
the attached process), frames without source are on the stack, `g.mCount` reads 3, Step Over stays in
Main, Continue reaches the breakpoint again, Detach ends the session and the process keeps running;
a second attach to the same process stops again (the first detach let it run). The test ends the
process. 74 checks. Needs the Beef install.

### `attachprobe <pid> [seconds] [images...]`
A diagnostic, not a suite: attaches the engine to a running process, prints its messages, pauses half
way (frames of the stop), continues, detaches and says whether the process still runs. Images given
after the seconds are served to the engine as stripped headers (Architecture.md, "Images the engine
must not read"). With a stand-in process that maps a file (`LoadLibraryEx` with
`DONT_RESOLVE_DLL_REFERENCES`) it shows whether the engine can read that file.

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
`OverrideTickFromDropdown`: `Initialize` / `Tick` overrides of a host-like base class with the parent call
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
| `<CorpusA>` + `<ClockWork>` (the standard pre-push run) | files=99 methods=1126 failures=0 |
| the three corpus folders, with and without `-types` | files=166 methods=1424 failures=0 |
| `<ClockWork>` with `-types` | files=30 methods=150 failures=0 |
| Beef corlib `C:/Program Files/BeefLang/BeefLibs/corlib/src` (about 80 s) | files=201 methods=3774 failures=0 (was 172 before methods in `#if` / `#else` arms got their own keys, see [Parsing-and-Layout.md](Parsing-and-Layout.md#methods-in-if--else-arms)) |
| The Beef IDE sources (`IDE/src` of the Beef repository, not installed with the toolchain) | with corlib and ClockWork about 9,000 methods in total, 0 failures when last run (not re-run for this page) |

### `orphans [-v] <files or folders>...`
For every method: disconnect the body from the entry, save the layout, reload text and layout,
compare the unconnected nodes, reconnect, and compare the rebuilt graph with the original.
Proves that breaking a wire never loses work. A refused reconnect commit is a failure. Standard
runs: `orphans <ClockWork>` (`files=30 methods=136 failures=0`) and the three corpus
folders (`files=166 methods=1424 failures=0`).

### Developer tools
* `dump <file>`: prints the parsed AST of a file.
* `graph <file>`: prints each method's graph signature (nodes, pins, links).
* `bench <file>`: load and one-commit timings for a big file.

## Release smoke

`scripts/release-smoke.ps1 -Zip <path> | -Tag <vX.Y.Z[-channel]> [-Out <report folder>]` is the regression pass on the **exact
artifact that ships** ([Releasing.md](Releasing.md#the-rule-no-release-without-a-smoke-pass)). It needs a desktop session
(real windows, PrintWindow captures) and BeefBuild; it runs one editor at a time at BelowNormal, uses a scratch folder under
`%TEMP%`, and stops only the processes it started (plus editors started by the update helper inside its scratch folder).
It never touches an installed editor.

| Phase | What runs | Fails on |
|---|---|---|
| `verify` | `-Tag`: the full win64 zip, `.sha256` and `release.json` from `AproposRobin/VBeef` via `gh`; hash and `gh attestation verify`. Unpacks into a scratch install folder. | hash mismatch, no attestation, missing `VisualBeefEditor.exe` / `vbhost.dll` / `LICENSE` / `VERSION.txt` / `docs`, no BeefBuild |
| `version` | `VisualBeefEditor.exe --version` | non-zero exit, output without the `VERSION.txt` version |
| `matrix` | `VB_SELFTEST=theme:<n>,session` on the packaged exe: Dark and Darker x 1280x800 and 1920x1080 x 100% and 125% (`VB_UI_SCALE`), eight runs, each on a fresh data folder and scratch project; every `shot:` is captured with `PrintWindow` into `<Out>\shots\<run>\` | a run that does not end `done failures=0`, any `[ASSERT]` or `[SELFTEST] FAIL` line, a crash report in the data folder, a requested capture that is missing or tiny, fewer than 20 captures |
| `fresh` | empty data folder: (a) no project (`nodoc,startpage,docs`: the start page, a project switch with unsaved changes, and the documentation panel on the package's own `docs` folder); (b) a scratch project: `session` (compiles the sample with BeefBuild), then `open:` a function, the Node menu (`menu`), Editor Preferences > Updates (`prefs:5`), and `update-check` (Help > Check for Updates) | as above, and an update answer that is not "up to date" or "<next version> is available" (never "not set up"; no network is a failure unless `-AllowOffline`) |
| `update` | `VB_SELFTEST=update-stage:<dir>` with a staged copy of the same package as a newer version: expects `update complete`, the new `VERSION.txt`, `installed.json` and the new editor running; then a staged copy whose program exits at once: expects `previous copy restored`, the old `VERSION.txt`, no `installed.json` for the failed version and the old editor running again | an end state not reached within 180 s |
| `soak` | the editor on a scratch project for 60 s (sampled every 2 s), then a close message | exit before the end, a window that stops responding, no clean exit (code 0) within 30 s, `[ASSERT]`, a crash report |

File > Open's native dialog cannot be scripted; the first-start run opens the project from the command line and a function
through `open:` (the call the Project Browser makes). The captures are for a person to look at
([Verifying the UI](#verifying-the-ui)); the pass only proves they exist.

Output: `<Out>\smoke-<first 12 hex of the zip's sha256>.json` (the report `release.mjs publish` reads: `passed`, `complete`,
`zip.sha256`, one entry per phase with the results of each run) and `smoke-<...>.md` (the summary), plus the session logs and
`update-*.update.log`. Default `<Out>` is `build\smoke`. Exit code 0 = passed, 1 = failed. `-Only matrix,soak` runs a subset
for development; the report is then `complete=false` and `publish` does not accept it.

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

* **`compiletime`** (`VB_SELFTEST=compiletime`, `SelfTestCompile.bf`; any project, its `build` folder removed by the
  caller first; `VB_CTIME_FILE` = the file for the one-line change, else the first project file): the source hash
  taken twice (one read) and the inputs fingerprint, then four compiles through the calls F7 and Ctrl+F7 make, each
  logged as `[CTIME] <case>: total=... beefbuild=... call=... finish=... maxframe=...`: the first (BeefBuild runs), one
  with nothing changed (up to date: BeefBuild not run, under 1 s, no project file written, indicator green), Force
  Compile (BeefBuild runs), and a one-line change saved by Compile's Save All. Every case checks that no frame took
  longer than 50 ms while it ran (Compile()'s own Save All, which flushes the file to disk, is `call`, apart) and,
  except the one-line case, that Compile() itself took under 50 ms; at the end the file is put back and the indicator
  says *Needs compile* at once after that save (the hash is read on a worker). 2026-10-12 (Debug editor): `done
  failures=0` on corlib + three projects, a ClockWorkEngine copy, a copy of this workspace and a visual mod with a
  game SDK library; the numbers are in [CHANGELOG.md](CHANGELOG.md).
* **`compileshots`** (`VB_SELFTEST=theme:<n>,size:1280x800,compileshots,size:1920x1080,compileshots`, a project whose
  compile takes a few seconds, `VB_SHOTS`): captures `ct-compiling` (Problems and the status bar with the elapsed
  time while BeefBuild runs), `ct-done`, `ct-uptodate`, `ct-log` (the Output Log lines) and `ct-buildmenu` (Build >
  Force Compile). 2026-10-12: Dark and Darker x 1280x800 and 1920x1080 x 100% and 125%, `done failures=0`, no
  `[ASSERT]` line.
* **`VB_SELFTEST=ids`**: opens the Node menu on the open graph, walks seven searches and the Library tree drawn open, and fails if any two rows drawn in one frame share an ImGui ID (`[SELFTEST] ok   ids: ...  0 conflicting IDs`). Use a project with the same class name in two namespaces.
* **This tests in the running editor**: `VB_SELFTEST=rename-undo,move-undo,find-refs,openall`
  (any subset; also `open:Type.Method()`, `fit`, `select:Kind:Text` to set up a capture) drives the
  editor through the same calls its UI makes once indexing is done and logs `[SELFTEST] ok ...` /
  `[SELFTEST] FAIL ...` and `[SELFTEST] done failures=N` to the session log (`SelfTest.bf`).
  rename-undo / move-undo / find-refs expect a project with a `Player` class whose `mHealth` field
  is used in `Player.Hit(int)` and in another file. `openall` opens every function of the project
  in a tab, lets it draw, and closes it; with `VB_NO_IDLE=1` and `--view` (read-only) it ran over
  `<Corpus>` (2,084 functions, all drawn, no crash) in about 100 s.
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
* **`newcomer`** (`VB_SELFTEST=newcomer`, `SelfTestNewcomer.bf`; an empty scratch folder as the project, a fresh `VB_HOME`): a first-time user's path through the calls the UI makes. File > New Project `Mod`, New Struct `Point`, New Interface `IGreeter` with a function (written as a declaration), New Class `Greeter` implementing it (the stub), Add Variable `List<int>` (Owned, made here; `using System.Collections;` added) and `int mCount = 3`, a constructor `(int start)`, Set on create (refused on `mCount` because `this(int)` exists, then a `String mName`), a For Loop with a print, `TryGet(out int value)` with Set value and Return, `Run` with a Defer, a call, a Branch on `TryGet`'s value and the out pin printed, then in `Main` Construct Greeter (from another file, with the create constructor's input), Defer -> Delete and Run on its Receiver, Save All, a Release compile, close / reopen byte for byte, Reload node, Reload Sheet, undo / redo / undo, and a debugger stop on the print in the loop (`i = 0`) then Continue to exit code 0. `[NEWCOMER]` lines log what each chooser offered and the code written. 2026-10-11: 15 checks, `done failures=0`; the program prints `Hello from Mod`, 0-9, 3, `Run done`. 2026-10-11 (`wt/newcomer2`): 25 checks, `done failures=0`; added: the For Loop's Counter pin `i` wired into the print and read back after reopen, `TryGet` made through the Add Function dialog's Inputs rows with Passing out (the chooser offers value, out, ref, in), Properties > Inputs reads out and writes ref (undone), the Return in `TryGet` starts with `false`, the Set of the parameter labels its pin Variable, the template's print in `Main` is a Message text field and a wired int switches it to WriteLine(Object obj) (2026-10-12), a bare Construct Greeter shows "needs a constructor" until one is chosen.
* **`attach`** (`VB_SELFTEST=attach`, `SelfTestAttach.bf`; the `Debuggee` fixture's workspace as the
  project, `VB_ATTACH_MODULE=Debuggee.exe`, the fixture running as `Debuggee.exe loop` started by the
  caller): Attach to Process with a made-up module (the empty list, Attach disabled; capture
  `attach-empty`), then the fixture listed with a green symbol line (`attach-dialog`), Attach, the
  stop on the Sleep node with the red status and the external code rows collapsed (`attach-stopped`),
  Locals (`attach-locals`), the rows expanded (`attach-frames`), the breakpoint removed and Continue
  (`attach-running`), Detach with the process still running (`attach-detached`). 2026-10-12: 13
  checks, `done failures=0`, at 1280x800 and 1920x1080, Dark and Darker, `VB_UI_SCALE` 1.0 and 1.25;
  no `[ASSERT]` lines.
* **`attachlive`** (`VB_SELFTEST=attachlive`, `VB_ATTACH_FILE=<the project's main .bf>`,
  `VB_ATTACH_TEXT=<the statement to stop on>`): the live proof on a program started by its host tool
  with the project's DLL loaded: the dialog (`live-dialog`), Attach, the stop in the project's Tick
  (`live-stopped`, `live-locals`), `[ATTACHLIVE]` lines with the frames and locals, Step Over,
  Continue without the breakpoint (`live-running`), Detach (`live-detached`). 2026-10-12 on a game
  client started through its store launcher: 9 checks, `done failures=0`, the game ran on after Detach.
* **`fnlocals`** (`VB_SELFTEST=fnlocals`, `SelfTestLocals.bf`; an empty scratch folder as the project, a fresh `VB_HOME`): the 2026-10-12 owner requests through the calls the UI makes. Add Input, remove and a type change keep TryGet's Sheet in front and Properties on it, the new row focused; Outputs with two `out` rows and a Return writing `value = 0; name = null; return false;`; L adds `int newLocal = 0;` selected in the Outline with its name box focused, renamed there to `count`; a String local variable made here (`scope .()`); Get / Set count from the Node menu (no Local Variable node offered); Make variable / Make local variable / Make variable (Get) from pins, one undo step each; Save All and a Release compile; close / reopen byte for byte; no `[ASSERT]` line in the session log. Captures `fn-outputs`, `local-props`, `outline-locals`. 2026-10-12: 28 checks, `done failures=0`.
* **`localsui`** (`VB_SELFTEST=theme:<n>,panel:outline,localsui`, `SelfTestLocalsUi.bf`; a copy of the `Debuggee` fixture as the project, with `int first = 1;` added at the top of `Hello` so it has a local variable): the Outline's LOCAL VARIABLES section. No Sheet open: the bar counts 0 and shows the dim *Open a function to see its locals* row (capture `ls-none`); the bars are in the order FUNCTIONS, VARIABLES, LOCAL VARIABLES, the last starting right below the VARIABLES rows and at the same screen position with no Sheet, with `Add` open and with `Hello` open; Add's `sum` with a breakpoint, its context menu, a refused delete, `int extra` in Hello with Move to Local Variables and a Debug stop on `sum` (captures `ls-bp`, `ls-menu`, `ls-refused`, `ls-move`, `ls-stopped`); then the rows follow the Sheet (`sum` while Add is in front, `first` while Hello is in front, capture `ls-switch`) and a local added, renamed, undone twice, added and deleted. 2026-10-12: 28 checks (plus the host-assert check), `done failures=0` at Dark and Darker x 1280x800 and 1920x1080 x 100% and 125%, no `[ASSERT]`.
* **`mathexpr`** (`VB_SELFTEST=mathexpr`, `SelfTestMath.bf`; a scratch project with a `Shapes` class: `Length(int x, float y, float scale)` and `Sum(int p, int q)` returning `0`, member variables `a`, `b`, `int mTotal = 0`): a Math Expression picked from the Node menu off Length's Return value (the search finds it by `math` and `expression`; it starts as `a + b`, its inputs need values: the error on the node), its formula typed and the parameters wired (`return Math.Sqrt(x * x + y * y) * scale;`, the Result float), a second one in Sum with `r` left open (the error, Sum not written) and `p * (q +` typed into its field (the red frame), then Properties of `mTotal`: Initial Value > Expression stays chosen over `0` with nothing written, `a + b` written and read back as Expression, `a +` refused (red frame and the reason), `r` given a value and Save All writing the `#math` records. Captures `math-first`, `math-node`, `math-error`, `init-expr-chosen`, `init-expr-written`, `init-expr-refused`. 2026-10-12: 18 checks, `done failures=0` at Dark and Darker x 1280x800 and 1920x1080 x 100% and 125%.
* **`strings`** (`VB_SELFTEST=strings`, `SelfTestStrings.bf`; a scratch project with a `Greeter` class: `Hello()` printing
  `Console.WriteLine("Hello from NewProject");`, `Show(int n)` printing a text, `Paths()` printing a long verbatim string):
  the print reads as WriteLine(StringView line) with a Message text field showing the text without quotes and the
  subtitle naming the overload; text typed into it (`say "hi" \ done`) is written with quotes and escapes and shown as
  typed; undo; the verbatim string shows the Expression badge, its value ends before the badge at 100% and at a 1.5 zoom
  (the positions are checked, not only looked at); an int dropped on a print is accepted and the print becomes
  WriteLine(Object obj), written `Console.WriteLine(n);`; Properties > Call > Overload lists the 4 overloads; choosing
  WriteLine(Object obj) for the text writes `Console.WriteLine((Object)"Hello from NewProject");`; undo restores the file.
  Captures `strings-first` (the first frame after opening), `strings-bare`, `strings-typed`, `strings-badge`,
  `strings-badge-zoom`, `strings-overloads`. 2026-10-12: 17 checks, `done failures=0` at Dark and Darker x 1280x800 and
  1920x1080 x 100% and 125%, no `[ASSERT]` line.
* **`dragvars`** (`VB_SELFTEST=theme:<n>,dragvars,dragvars-live`, `SelfTestDragVars.bf`; a scratch project with a `Shop` class: `int mCount`, `float mPrice`, `String mName`, `int Add(int a, int b)` and `Run()` with the local variable `int total = 0;` and the statement `Add(1, 2);` between two prints): the 2026-10-12 owner requests through the calls the UI makes. The ghost over Add's `a` while mCount is dragged (green ring, `Get mCount into a`), mName over `b` (red ring, `Can't connect: text to int needs parsing (Int.Parse)`), the ghost over the empty Sheet, of a function and of a Project Browser tile; mCount dropped on `a` (`Add(mCount, 2);`, the Get selected), one undo; total dropped on the Return Value (a Set run right after Add), one undo; mName on `b` refused in the status bar with nothing written and no undo step; a Node menu Get row dropped on `b` (`Add(1, total);`) and a Set row on the Sheet (a Set, no question), one undo each; Add Variable starting with `int`, its picker open, `bool` picked (preview `public bool bRunning;`), Create, the next Add Variable starting with `bool`, a typed `Dictionary<String, int>` taken, undo. Captures `dv-first`, `dv-accepted`, `dv-refused`, `dv-ghost`, `dv-ghost-fn`, `dv-ghost-asset`, `dv-dropped`, `dv-set`, `dv-addvar-picker`, `dv-addvar-bool`. **`dragvars-live`** drags for real through ImGui's mouse input (`ImGuiIO_AddMousePosEvent` / `AddMouseButtonEvent`, one step per frame): the mCount row pressed, moved over `a`, released (`Add(mCount, 2);`); the Node menu opened, its Get total row pressed (the menu closes), moved over `b`, released (`Add(1, total);`); captures `dvlive-over-pin`, `dvlive-menu-over-pin`, `dvlive-after`. Start the editor minimized and show it without activating it: a window that has had the keyboard focus reads the real cursor every frame. 2026-10-12: 21 + 9 checks, `done failures=0`, no `[ASSERT]`, at Dark and Darker x 1280x800 and 1920x1080 x 100% and 125%.
* **`host`** (`VB_SELFTEST=host`, `SelfTestHost.bf`; an empty scratch folder as the project, a fresh `VB_HOME`, the template folder in `VB_HOST_TEMPLATE`, default `VisualBeefTests/fixtures/Host/Template` of the checkout that built the exe): a project made from a host tool's template, through the calls the UI makes. File > New Project offers **From template folder...**; a folder without `template.json` says so; the fixture template loads with its two variables (fields `Id` = `hello-tool`, `Version` = `0.1.0`); `Hello Tool` is created and opened (`HelloTool`, `src/Program.bf`); `.vbproject` names main and configuration and `tool.json` has the filled-in id; the Fixture Kit library is indexed; the Node menu lists Days In Year under Fixture Kit and the four callback nodes under Callbacks, not the `[NodeHidden]` function; **Try register Days In Year** is placed in `Main` and `OnDaysInYear` is picked from its callback pin's Node menu, written `Clock.TryRegisterDaysInYear(=> OnDaysInYear);`; the compile configuration is Release because the `.vbproject` names it; Save All and a compile with the library; close / reopen, Reload Sheet and identity commits byte for byte. `[HOST]` lines log what the Node menu offered and the code written. `newproject-template:<template folder>` opens the New Project dialog on From template folder... with the folder filled in, for captures (`close-popups` closes it).
* **`workspace`** (`VB_SELFTEST=workspace`, `SelfTestWorkspace.bf`): the Project Browser's projects and Project
  Settings through the calls the UI makes, on a scratch workspace the caller writes: `BeefSpace.toml` in the Beef
  IDE's form (`# the workspace` comment, `[Workspace] StartupProject = "Tester"`, `[Projects]` with
  `Core = {Path = "Core"}` and `Tester = {Path = "Tester"}`); `Core/BeefProj.toml` (a comment, `Dependencies =
  {corlib = "*"}`, `TargetType = "BeefLib"`) with `src/Greeter.bf` (namespace `Core`, `public static class
  Greeter` with `Hello()`); `Tester/BeefProj.toml` (depends on corlib and Core, `StartupObject =
  "Tester.Program"`) with `src/Program.bf` calling `Core.Greeter.Hello()` and an `assets` folder; and beside the
  workspace `Outside/Ext/BeefProj.toml` (a library). Checks: the project rows, the startup mark, Core's `src`
  beneath it (no chain), the current project (the open file's); the project menu, a folder menu (captures);
  Project Settings: build kind Dynamic library and back, post-build commands, the namespace, a dependency off
  and on, Set as Startup Project (the tree mark follows); the + Add menu; New Project in This Workspace (library
  `Kit` beside Tester, registered in `[Projects]`, Tester depends on it); Add Existing Project with the path the
  folder dialog returns (`../Outside/Ext`, the row outside the folder, refused a second time); the rename dialog's
  project note and Core renamed to Engine through the rename call (BeefSpace.toml, BeefProj.toml `Name`,
  Tester's dependency, the open document, the tree, no error); the Name field of Project Settings (holds `Tester`, the
  folder box starts on; committed as `Runner` with the box off: the BeefSpace.toml key, the startup project, `Name`, the
  tree row and Properties follow, the folder stays Tester); refusals (a name another project has, empty, `two words`,
  `CON` with the folder box on: status-bar message, nothing written, no error dialog); **Rename Project...** (the rename
  dialog holds `Runner`, folder box off; `Player` with the box on renames the project and its folder, the open document and
  Properties follow); Engine renamed to Motor with its folder (the dependency in Player's BeefProj.toml follows); the delete
  dialog's note (cancelled); Remove from Workspace; Save All and a compile of the edited workspace (green). Captures
  `ws-first`, `ws-tree`, `ws-project-menu`, `ws-folder-menu`, `ws-settings`, `ws-settings-dll`, `ws-add-menu`, `ws-newproject`,
  `ws-outside`, `ws-rename-dialog`, `ws-renamed`, `ws-name-first`, `ws-name-field`, `ws-name-renamed`, `ws-name-refused`,
  `ws-rename-menu`, `ws-rename-project-dialog-first`, `ws-rename-project-dialog`, `ws-renamed-project`, `ws-delete-dialog`.
  2026-10-12: 63 workspace checks (65 with the theme and host-assert checks), `done failures=0`,
  no `[ASSERT]`, at Dark and Darker x 1280x800 and 1920x1080 x 100% and 125%. The folder dialog itself is native
  and cannot be scripted; the step calls what its answer goes to (`AddExistingProjectAt`).
* **`startpage`** (`VB_SELFTEST=startpage`, `SelfTestStartPage.bf`; **no project argument**, a fresh `VB_HOME`; the editor must show the start page): the start page shows and nothing is reopened; File > New Project (`CreateProject`, the calls the dialog makes) makes `Alpha One` in `<VB_HOME>\sp-scratch` and the folder, `BeefProj.toml` (`Name = "Alpha One"`), `BeefSpace.toml` (`"Alpha One" = {Path = "."}`, `StartupProject`) and `Program.bf` (namespace `AlphaOne`) carry the typed name; it becomes the open project (root, a Sheet on `Program.Main`, title, Project Browser tree, index, recent list); with an unsaved change a second New Project (`Beta`) is made but the switch waits for the question; Don't Save closes `Alpha One` (nothing of it stays open: documents, Sheets, tree, index; its file on disk is unchanged); an unsaved change in `Beta`, `RequestOpenProject` and Save All writes it and opens `Alpha One`; Close Project returns to the start page; the list is in `settings.json`, loads back in order, dims and removes a folder that was deleted; the New Project dialog's `Creates` path for `My Game` and for a name with forbidden characters; the project with a space in its name opens and compiles (BeefBuild run with `-workspace=.`). 2026-10-12: 43 checks, `done failures=0`.
* **`projectarg`** (`VB_SELFTEST=projectarg`, `SelfTestStartPage.bf`; **with** a project folder argument): the project on the command line opened directly, the start page never showed, it heads the recent list and the window title follows. 2026-10-12: 3 checks, `done failures=0`.
* **`docs`** (`VB_SELFTEST=docs`, `SelfTestStartPage.bf`; no project needed, a fresh `VB_HOME`): the shipped pages load from the checkout's `docs` (11 `audience: user` pages, none of the developer pages), Help > Documentation opens on Getting started, the page is laid out, the 5 pictures of Classes-and-Members decode and upload as textures (Windows), a link to another page is followed and Back returns, a link to a page that is not shipped changes nothing, a deep heading scrolls the page, a search finds pages and headings, a search with no match shows nothing. 2026-10-12: 17 checks, `done failures=0`.
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
  `sp-seed` (four recent projects, the last one's folder gone), `sp-close`, `sp-open:<dir>`, `sp-switch:<seeded name>`, `sp-dirty` (an unsaved change), `sp-cancel` (answers the unsaved-changes question Cancel), `filemenu`, `newproject:<name>` (the New Project dialog with that name typed, `newproject:` for the empty state), `docs-open:<File.md>[#heading]`, `docs-search:<text>`, `docs-scroll:<pixels>`, `docs-image:<images/name.png>`, `docs-image-close`, `docs-close`, `helpmenu`,
  `newclass:<Parent>:<Interface>` (the New Class dialog, left open), `status:<text>` (the status bar
  text; empty hides a scratch path), `var:<Type>.<member>` (a member variable in Properties, as an Outline
  click), `addvar:<Type>:<VarType>:<name>` (the Add Variable dialog, left open) and `close-popups` (closes
  it), `initbuf:<text>` (the Initial Value box shows `<text>` as if typed: the error state). `select:` also
  brings the node to the middle of the canvas.
  Steps wait for indexing, a pending commit and the first-start focus of the Project Browser.
* **`VB_DOCS=<folder>`** names the documentation folder Help > Documentation reads (default: `docs` next to the program, else the `docs` folder of the checkout the program was built in).
* **`VB_UI_SCALE`** (for example `1.25`) replaces the monitor's display scale, so a 125 % or 150 %
  layout can be checked on a 100 % screen.
* Launch the Debug or Release exe in a scratch copy of a project (never your real repo).
* **`VB_DEBUG_NODE_MENU_SEARCH=<text>`** pre-fills the node menu's search box each time it opens,
  since typing cannot be posted (below); picking a result is still a posted click.
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
the corpus sources shows up as a failure. See [Testing.md](Testing.md).

## Tests: classes and members

`VisualBeefTests classes` (141 checks in 7 groups): modifier words and attribute lists; declaration
spans for every declaration form (also run by `parser`); each Type Settings edit with its exact
text and undo; inheritance (Override list, missing members, document errors, stubs, override
signatures for virtual / protected-out / property / generic bases, abstract members, unknown bases,
sealed and struct parents, the pickers); graph checks (the Entry error, the Base node read, written
and refused in a static function, accessor graphs); renames across two files (field, type, refused
plans, parameter and local); templates (a host template's entry class: graphs and Override list). `compile` builds
and runs a class hierarchy with an interface whose stubs and overrides were made with these APIs
(`ClassHierarchyInterface`), an Tick override from the Override dropdown (`OverrideTickFromDropdown`),
and refuses an override with nothing to override (`RefuseOverrideWithoutBase`).

## Coverage: lifetime nodes on a large code base

`VisualBeefTests coverage` (the audit's probe, now a command) over the three corpus folders with the
editor's setup (1,078 method bodies):

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

After the last text forms (2026-10-10, same command; the corpus had grown to 162 files, 1,366
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
