---
audience: developer
title: Node catalog and types
summary: How nodes are found and pins are typed without the Beef compiler.
order: 13
---

# Node catalog and types

This page covers how VisualBeef finds the nodes it offers, and how it types pins without the
Beef compiler (step A of audit gap #3). The code is in `VisualBeefCore/src/Catalog/`.

| File | Role |
|---|---|
| `SymbolStore.bf` | A compact symbol table. All strings sit in one pool and every record is a plain struct. It loads from and saves to the binary cache. |
| `LibraryIndex.bf` | Finds the libraries a folder depends on, then parses each one or loads it from the cache. It includes `MiniToml`. |
| `AttributeParser.bf` | Reads attribute text (`[Node(Category="x")]`) and `///` doc comments. |
| `TypeRules.bf` | Type rules: normalising type text, literal types, implicit conversions, generic wildcards, type families and pin colours. |
| `TypeService.bf` | Resolves types, members and overloads, and owns the stores and the catalog. It also implements `ITypeHierarchy`. |
| `NodeCatalog.bf` | The flat catalog of node entries, with search, context relevance, specs and the category tree. |

## Indexing

- **The project.** `ProjectIndex` parses every `.bf` file under the open folder, except
  **generated library projects** (see below). It now also records:
  - namespaces, file `using`s and visibility;
  - attribute text and `///` doc comments;
  - parameter defaults, modifiers and attributes;
  - generic parameters of types and methods;
  - base types and enum cases.

  `ProjectIndex.Version` changes on every update. `TypeService.Sync()` then rebuilds the
  project's `SymbolStore`, which takes milliseconds.

  A rescan of the same folder (`Build` on an index that already holds it) keeps every file
  whose size and modification time did not change (`IndexedFile.Stamp`) and parses only the
  rest: 85 ms for a 266-file project when nothing changed.
- **Generated libraries under the folder.** A sub-folder holding a `BeefProj.toml` with
  `TargetType = "BeefLib"` whose sources are mostly `*.g.bf` (what code generators write), or
  any library folder with a `.vblibrary` marker file, is not entered by the project scan: it
  goes to `ProjectIndex.GeneratedLibraries`, and `LibraryIndex.Discover` loads it as a library
  (cached, below), followed by its own dependencies. Opening a mod platform's repository root
  with two generated game SDKs and a generator's golden output therefore indexes 266 project
  files plus those three folders as libraries.
- **Libraries the project manifest names.** The `libraries` of the folder's `.vbproject`
  ([Host-Integration.md](Host-Integration.md)) are loaded as libraries too, even when the
  workspace does not list them.
- **Libraries.** `LibraryIndex.Discover(folder)` reads the nearest `BeefSpace.toml` and the
  `BeefProj.toml` of every workspace project in or above the folder, and follows their
  `Dependencies` transitively. It resolves each dependency to one of:
  - a workspace project outside the folder;
  - `C:\Program Files\BeefLang\BeefLibs\<Name>`.

  corlib is always included. Projects inside the folder are skipped, because the project index
  already has them (generated SDKs excepted, see above). A workspace dependency that points inside
  the folder at a generated library the scan did not reach (under `build`, a dot folder) is loaded
  as a library too. Absolute paths written with `/` are normalised to `\`, so the cache key does not
  depend on the spelling.
- **Cache.** Each library is parsed once. `LibraryIndex.Load` tries, cheapest first:
  1. the **path-keyed** cache `%LOCALAPPDATA%\VisualBeef\index\<FNV-64 of the library path>.bin`,
     whose header holds a signature of every source path and its modification time plus the
     format version (4 since the class model: members carry virtual / abstract / override / sealed,
     types abstract / sealed / static, which ClassModel reads). The files are only listed and stat'ed; on a match the cache is read with
     a few `memcpy`s (6 ms for the smaller game SDK, 9-11 ms for the larger);
  2. the **content-keyed** cache `index\sdk-<FNV-64 of the content>.bin`, keyed by a hash of every
     file's path relative to the library and its bytes. It is shared by every copy of a library
     with the same files: an SDK regenerated with identical output (new times, same text), the
     same SDK in a second checkout, or a cache built ahead of time. On a hit the store's file
     records are re-pointed at this copy and the path-keyed cache is re-written, so the next
     start is stat-only again (hashing reads the files: 0.24 s for the smaller SDK, 0.5 s for
     the larger, against 4.6 s / 9.7 s to parse);
  3. a full parse, which writes both caches.

  Files are written to a temp file and then moved into place, so a crash never leaves a broken
  cache.
- **Off the UI thread.** The editor never loads libraries on the UI thread
  (`TypeService.AutoLoadLibraries = false`). `IndexJob` (`Catalog/IndexJob.bf`) runs the
  project scan and every library load on a worker thread, loading up to four libraries in
  parallel, with progress (`IndexProgress`: phase, done / total) and cancellation checked
  between files. The editor takes the result with `ProjectIndex.TakeFrom` and
  `TypeService.SetLibraries` (see [Editor-UI.md](Editor-UI.md#background-indexing)). Nothing
  in the parser or `LibraryIndex` keeps shared mutable state, so this needs no locks beyond
  the progress object.
- **`#if` arms.** The parser reads both arms of `#if A … #else … #endif` as live code. The
  indexer keeps one member per signature (name, static, parameter types and modifiers), so the
  members of both arms appear only once.

## Catalog entries

`NodeCatalog` holds one `StoreCatalog` per store (the project, then each library). Library
catalogs survive project edits; only the project's is rebuilt. Each entry is a 48-byte struct
with these fields:

- the member index;
- the category id;
- the display name, the search key and the keywords (in the catalog's pool);
- a character mask for the search prefilter;
- a kind: `Call`, `Pure`, `Get`, `Set`, `Event` (an `Event<…>` field) or `Flow`
  (`[ExpandEnumAsFlow]`);
- flags: static, conversion, advanced, compact, generic, overloaded, attributed.

`GetSpec(id)` builds the full `NodeSpec` on demand: label, category, tooltip, call text, owner
type, return type, and the pins with label, type, default, tooltip and modifier (`PinSpec.IsOutput`:
`out`, or `ref` tagged `[Pin(Out=true)]`; `PinSpec.IsRef`).

The rules for which members become entries are in [Node-Attributes.md](Node-Attributes.md).

The node menu (`VisualBeefEditor/src/NodeMenu.bf`) works over the catalog:

- **Filtering** runs only when the search text, the Context Sensitive box or the catalog
  changes. It never runs per frame.
- **Items.** A catalog entry becomes an `NodeItem` only when it is shown.
- **Search results** are capped at 300 per query, best first.
- **Browsing** (nothing typed, no pin context) shows the local items, then the whole catalog as
  the "All nodes" tree. A category is only visited when it is open, and shows at most 400
  items.
- **Favorites, node hotkeys and recents.** The star on a row (or a right-click) adds the node to
  Favorites or removes it; a favorite can get a node hotkey (a letter: hold it and click the Sheet,
  or press it while dragging a wire). Favorites and hotkeys are global, in `settings.json`
  (`editor.favorites`, `editor.nodeHotkeys`), see [Editor-UI.md](Editor-UI.md#node-hotkeys-and-favorites).
  The 12 most recently used nodes are kept too, in `%LOCALAPPDATA%\VisualBeef\node_menu.txt`.
  Favorites and recents appear at the top of the menu.
- **Creating a node.** Choosing a catalog item calls `NodeFactory.FromSpec`. The node gets typed
  and labelled pins, default values in the pins, and no flow pins when the entry is pure. Static
  entries are static calls (no Receiver pin, qualified by the type), member entries have a Receiver pin
  of the owning type (unconnected = this), `out` parameters are output pins
  ([Calls-and-Receivers.md](Calls-and-Receivers.md)).

## Search

Each query word is scored against an entry's lowercase key. The key holds the display name, the
member name, the keywords and the type name.

| Match | Score |
|---|---|
| Prefix of the key | 100 |
| Start of a word | 60 |
| Acronym (`gal` → Get Actor Location) | 40 |
| Substring | 30 |
| Letters in order (fuzzy) | 5 + 4 per word start |

On top of the word scores:

- **Bonuses:** +80 or +50 when the whole query appears as typed; context relevance × 8; a small
  bonus for shorter names.
- **Penalty:** −20 for `Advanced` entries.

Entries whose character mask lacks one of the query's letters are skipped before any string
work. The best N are kept with a sorted insert.

## Resolving types (step A, no compiler)

`TypeService` resolves names the way Beef does, as far as declarations allow.

### Type names

The lookup:

1. Normalises the text: drops `ref`/`out`/`params`, `System.`, `?`, `*` and `[]`.
2. Ignores generic arguments for the lookup, but uses their count to break ties.
3. Maps primitive keywords to corlib structs, so `int.Parse` finds `System.Int`.
4. Scores the candidates:

| Candidate | Score |
|---|---|
| Nested in the current type | 7 |
| Current namespace | 6 |
| Parent namespace | 5 |
| Namespace in the file's `using`s | 4 |
| Global namespace | 3 |
| `System` | 2 |
| Anything else | 1 |

`A.B.Type` must match the namespace or the outer type.

### Members

A type's members include its `extension`s, its partial declarations and its base types,
transitively. Each base list is resolved in the context of its own declaration.

### Generics

- **Type generics.** A generic type's parameters are bound from the use: on `List<int>`, `T` is
  `int`. The binding is applied through base types too (`class Foo : List<int>`).
- **Method generics.** These bind from the argument types, so `Math.Max(1, 2)` returns an `int`.
- **Unbound generics.** A parameter that stays unbound is a wildcard pin (grey). When it is
  connected, `Graph.UnifyWildcards` turns every `T` on that node into the connected type, so
  `List<T>` becomes `List<int>`. Disconnecting the last wire restores the generic types.

### Overloads

The candidates are first filtered by arity (default and `params` arguments count). They are then
scored by argument types:

| Argument fits the parameter | Score |
|---|---|
| Exact | +4 |
| Implicit conversion | +2 |
| Unknown | +1 |
| Refused | −100 |

The owner type's own overloads are matched the same way from the AST.

A resolved method (`SymbolMethod`) carries its declaring type (`OwnerType`, from `MemberRec.Owner`),
which the call nodes use for their Receiver type and GraphValidator's this check. When two
candidates that are not the same signature score the same and every argument type is known, the
result is marked `Ambiguous` (the node shows a warning once edited).

### Expressions and locals

| Code | Type |
|---|---|
| `let`/`var` locals | Their initialiser's type |
| `1` | int |
| `1.0` | double |
| `1.0f` | float |
| `2d` | double |
| `1u` | uint |
| `1L` | int64 |
| `1UL` | uint64 |
| `0xFF` | int |
| `'c'` | char8 |
| `'\u{…}'` | char32 |
| `"…"`, `$"…"`, `@"…"` | String |
| `this` | The owner type |
| A call | Its resolved return type |
| `Try!(x)` | `T` when `x` is a `Result<T…>` |
| `a.b` | Field or property type, generic arguments applied |

### Never blocking

Anything that can't be resolved stays an empty type: a grey pin that connects to anything.
Graph building never type-checks wires, so existing code always loads.

## Conversions (`TypeRules.CanConvert`)

The result is one of `Exact`, `Implicit`, `Unchecked` (a side is unknown or generic: allowed) or
`Refused`, with a reason. A wire you drag is refused only on `Refused`, and the tooltip and
status bar show the reason.

Allowed implicitly:

| From | To | Note |
|---|---|---|
| A signed int | A signed int at least as wide | |
| An unsigned int | An unsigned int at least as wide, or a strictly wider signed int | `int` and `uint` are 8 bytes |
| int | float, double | |
| float | double | |
| char8 | char16, char32 | |
| `String` | `StringView`, `char8*` | |
| `char8*` | `StringView` | |
| `T` | `T?` | |
| `T[]` | `Span<T>` | |
| `X*` | `void*` | |
| Anything | `Object` | Boxing |
| `null` | Classes, interfaces, pointers, delegates, nullables | |
| A subclass | Its base class or an interface it implements | Through the index, transitively |
| `G<A>` | `G<B>` | When each argument is compatible; wildcards unify |

Refused, with the reason shown:

- narrowing (int64 → int32, double → float, float → int);
- signed ↔ unsigned of the same size;
- bool ↔ anything else;
- numbers ↔ text;
- `StringView` → `String` (it needs a copy);
- `T?` → `T`;
- enum ↔ int (it needs a cast);
- two indexed classes with no common base.

User structs may declare implicit operators that can't be seen without the compiler, so
conversions involving structs stay `Unchecked`.

## Pin colours

There is one mapping, in `TypeRules.Family` / `FamilyColor` / `PinColor`. It returns ImGui
`IM_COL32` values.

| Family | Colour (R,G,B) | Types |
|---|---|---|
| Flow | 240,240,240 white | Flow pins |
| Bool | 146,0,0 red | `bool` |
| Int | 31,227,175 cyan | `int*`, `uint*` |
| Float | 160,250,68 green | `float`, `double` |
| Char | 206,120,255 violet | `char8/16/32` |
| String | 251,0,209 magenta | `String`, `StringView`, `char8*` (the game SDK's `FString`/`FName`/`FText`) |
| Object | 0,168,242 blue | Classes (and the game SDK's `U*`/`A*` object pointers) |
| Struct | 0,87,200 dark blue | Structs |
| Vector | 253,200,35 gold | Vector/colour/rotator-like structs |
| Enum | 0,109,99 teal | Enums |
| Interface | 238,252,168 pale green | Interfaces |
| Delegate | 255,56,56 red | `delegate`, `function`, `Event<>` |
| Pointer | 110,150,210 | Other pointers |
| Unknown / Wildcard | 170,170,170 grey | Unresolved types, generic parameters |

With a `TypeService` installed, the family comes from the declaration (enum, struct, class or
interface). Without one, name heuristics are used: `E…`/`…Kind` is an enum, `F…` a struct.
`Theme.TypeColor` in the editor shell should call `TypeRules.PinColor` (that change is left to
the shell owner).

## Generated libraries (very large libraries)

Measured on a generated game SDK of 209 files, 23 MB and 475k lines (Debug build):

| Step | Time |
|---|---|
| Parse + index + write cache (first run only) | 4.25 s |
| Load from cache (every later start) | 5.6 ms (9.8 MB file) |
| Load from the content-keyed cache (path cache gone, same files) | 0.24 s (hashing 23 MB) |
| Build the catalog (75,208 entries, 8,526 categories) | 114 ms |
| Build the category tree (lazy: first browse only) | 329 ms |
| Search, 300 best hits | 0.6–32 ms per query ("k2 set" 0.9 ms, "spawn actor" 5 ms, "get actor location" 17–32 ms) |
| Context filter over all entries ("takes `UActorComponent*`") | 40 ms, 1,297 matches |

The store holds 11,297 types and 93,185 members.

What makes this scale:

- **No per-entry allocations.** Records are plain structs over one string pool, so loading the
  cache is a memcpy, not 100k allocations. A catalog entry is 48 bytes.
- **Cheap search.** The character-mask prefilter discards most entries without touching strings,
  and the result list is bounded.
- **Lazy views.** Entries become menu items only when shown. The category tree is built on first
  browse, and a category's children only when it is opened. Context filtering is memoised per
  distinct type string, so 75k entries cost about one check per distinct parameter type.
- **Separate library catalogs.** A library's catalog is built once per session. Project edits
  don't touch it.

### How a generator should emit a library

A generated library without attributes offers every public member, under `Namespace|Type`
categories. A generator gets its own categories and hides its plumbing by emitting the node
attributes ([Node-Attributes.md](Node-Attributes.md), [Host-Integration.md](Host-Integration.md#node-libraries)).
It may declare the attribute types itself (VisualBeef matches them by simple name and fields), so the
library does not depend on `VisualBeefMeta`:

1. `[Node(Category=..., DisplayName=..., Tooltip=..., Keywords=...)]` on the functions to offer, with
   `Pure=true` for the ones without side effects and `Advanced=true` for rarely used ones;
2. `[CallbackNode("...", Role=...)]` on the functions that register, remove or call through a
   replaceable callback;
3. `[NodeHidden]` on internal thunks and duplicates;
4. `[Expose(Category=..., ReadOnly=...)]` on the properties to offer;
5. `[Pin(Name=..., Default=..., Out=true)]` on parameters (prefer real Beef default values when the
   type allows them);
6. `[Conversion]` on automatic conversions and `[ExpandEnumAsFlow("...")]` where an enum result
   should become flow outputs.

Once a store uses any attribute it switches to attributed mode, so only the tagged API is
offered. Emitting at least one attribute is therefore enough to remove the noise. Doc comments
(`/// <summary>`) are also picked up as tooltips, if the generator prefers those to `Tooltip=`.

When the open folder contains a generated library (a mod platform's repository root, for example),
it is loaded as a cached library, not parsed as project files (see [Indexing](#indexing)). Opening
such a repository (`VisualBeefTests catalog-scale -root`, Debug build):

| | Before (2026-10-10 audit) | After |
|---|---|---|
| Project files parsed | 751 (the SDKs included) | 266 (3 generated SDK folders loaded as libraries) |
| First open ever (cold cache) | 15.0 s, on the UI thread | 11.3 s, on a worker thread (the SDKs are parsed in parallel); the window is usable after 0.2 s |
| Every later open (warm cache) | 16.0 s, on the UI thread (the SDKs were never cached) | **0.42 s** on a worker thread (project 0.40 s, 4 libraries from cache 0.01-0.02 s) |
| Path cache dropped (SDK regenerated identically) | - | 0.9 s (content-keyed cache hit) |
| Rescan of the same root | 15-16 s (full re-parse) | 85 ms (0 parsed, 266 reused) |
| Cancel | - | worker stops within 40 ms |

Still on the UI thread: building a library's catalog the first time the node menu opens
(113 ms for the smaller SDK, 254 ms for the larger), the first category tree (0.3 / 0.9 s), and search
(up to 33 / 78 ms per query on the smaller / larger SDK).

## What a type field accepts

Every place the editor lets you pick or type a type has a `TypeSlot` and one rule set
(`VisualBeefCore/src/Catalog/TypeSlotRules.bf`, Beef 0.43.6). The picker lists only what fits, a typed
text that does not fit shows "'<word>' is not allowed here: <why>" in red and is not applied (the text stays
in the search box), the document edits refuse it too (nothing is written, `LastError` says why), and a file
edited by hand gets the same message as a declaration error (`Member.GetDeclError`: Outline row red,
Problems, the entry node) or, on a node, as a node error (a warning when the code was read as written).

| Place | Accepts | Refuses |
|---|---|---|
| Function Return Type | any type, `void`, `void*`, `ref T`, the own-type keyword, `Result<void, E>`, `var` only on a `[Comptime]` function | `let`; `void[]`, `void?`; keywords; an undeclared `T` |
| Parameter type | any type, `void*`, the own-type keyword, delegate / function types; `var` / `let` only on a mixin | `void`, `var`, `let`; `ref` / `out` / `in` / `params` written in the type (they are the Modifier); `params` not last or not an array / Span; an unknown Modifier |
| Member variable, property, indexer | any type, containers, `T[4]`, tuples, the own-type keyword | `void`, `var`, `let` (also inside `List<var>`) |
| Local variable node, Using variable | any type, `var`, `let` | `void`; `var` inside an array, pointer or generic argument |
| For Each element | any type, `var`, `let` | `void` |
| Cast To | any type, `void*` | `var`, `let`, `void` |
| Construct (new / scope) | classes and structs, generic instances | `var`, `let`, `void`; enums and interfaces are not offered |
| Base type (Type Settings) | a class, struct or interface name with arguments; an integer type for an enum; for a struct, one basic type as the first base (a typed primitive, `struct Handle : int`, as corlib's `Int64 : int64` and `HSocket : uint`) | a basic type on a class, or after an interface in a struct's list, or twice; the own-type keyword; arrays, pointers, nullable; `void`, `var` |
| Generic parameters (Type Settings) | `T, U`, `const int N` | duplicates, keywords, basic types, `var`, `void`, the own-type keyword, empty entries |

Everywhere: the own-type keywords (the type that contains the code, and its parent) only inside a type; a generic parameter (`T`, `TKey`...) only when the
function or an enclosing type declares it (the picker offers those in a "Generic parameters" group);
keywords are never type names; arrays, pointers, nullable, tuples and `delegate` / `function` / `decltype`
forms are accepted as written.

## Tests

`VisualBeefTests catalog` runs 203 checks:

- the attribute parser and the parser's attribute text;
- doc comments;
- literal types;
- conversions;
- fuzzy ranking;
- corlib cache miss and hit, the content-keyed cache (path cache dropped; a copy of a library
  in another folder loads from it with its file records re-pointed);
- the attributed fixture: categories, tooltips, pin defaults and labels, hidden members,
  overloads, `[Expose]`, `[ExpandEnumAsFlow]`, `#if`;
- the plain fixture: fallback visibility, hierarchy, context relevance, overload resolution;
- graph pin types: literals, overloads, `Try!`, `List<int>.Add`, `int.Parse` and corlib labels,
  `Math.Max<T>`, namespaces;
- wire checks and wildcard unification;
- colours;
- TOML and library discovery.

`VisualBeefTests catalog-scale [dir]` prints the SDK timings above (parse, content-hash hit,
path cache hit, catalog, searches). `catalog-scale -root <dir>` opens a whole folder the way the
editor does (`IndexJob`), cold and warm, then times a rescan, a content-cache-only open and a
cancel. `roundtrip -types` runs the round trip with the resolver and libraries installed.
