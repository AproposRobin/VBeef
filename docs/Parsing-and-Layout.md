---
audience: developer
title: Parsing and layout
summary: Parser recovery, layout keys, literal kinds and the layout sidecar.
order: 11
---

# Parsing recovery, layout keys and literals

How the parser copes with broken code, how saved node positions stay put when the file is
edited in a text editor, and how literals are classified. Tests: `VisualBeefTests parser`.

## 1. Error recovery

Before: one unbalanced bracket turned the broken member and every member after it into one
Raw member, so the editor silently showed only the members before the error.

Now the parser resynchronises at the next member boundary and represents the damaged member
as `Member { Kind = .Broken }`. Its exact text is kept (round trip stays byte exact), so the
rest of the file parses normally.

A member is **broken** when, while parsing it, any of these happen:

| Trigger | Example |
|---|---|
| Brackets that do not close in order (`SkipBalanced` is strict: `(` needs `)`, `[` needs `]`, `{` needs `}`) | `void M(int a {`, `a[1]]` |
| A bracket never closed before the end of the file | truncated file |
| A block cut off by the end of the file | `void M() { if (x) {` EOF |
| Balanced braces but a declaration starts inside the member: a line-leading `public/private/protected/internal` at or left of the member's own indentation | missing `}` inside a method, missing `)` in a call that swallows the method's `}` |
| An unparsed member that runs to the end of the file without `;` or `}` | |
| A declaration that looks like a function or member variable but did not parse (`UnreadableDeclaration`, 2026-10-11): a keyword as its type, a member variable typed `var` / `let`, a member with no name | `public default Bad(int a)`, `public var mX = 1;`, `public 42 = 7;` |

Not broken: declarations kept as text on purpose (`using`, `typealias`, `delegate` / `function`
types, enum `case`s, operators, members whose type is `Event<delegate ...>`, explicit generic
interface members, C#-style constructors in inactive `#if` arms). `var F()` / `let F()` parse as
functions (`[Comptime]` functions may return `var`); `Member.GetDeclError` reports them and
GraphBuilder puts the message on the entry node. Before 2026-10-11 they were hidden Raw members.

Not broken either: code the parser just does not model (switch, lambdas, `int x = 1 + ;`). Those stay
Code/Raw nodes inside a normal method, as before.

**Extent of a broken member** (`MakeBroken`): from the member start (attributes included),
counting only braces. It ends at the `}` that closes its first `{` (plus a trailing `;`), or at
the first `;` before any `{`. It never runs into the next declaration (a line-leading access
modifier at or left of the member's indentation) and never past a `}` that closes the parent
(or a line-leading `}` indented less than the member). At the end of the file it stops at the
last token. Parsing then continues right after it, in the same type body.

AST: `Member.Kind == .Broken`, `Member.Error` ("line 12: '{' opened on line 12 is never
closed"), `Member.Name` (best effort: the identifier before the first `(`, else `?`),
`FirstTok/LastTok` = the span (`CompilationUnit.NodeText(m)` is the exact text). It has an
empty `Params` list and empty `TypeText` so consumers never see null.
`CompilationUnit.CollectMethods` lists Broken members together with methods, so
`SourceDocument.Methods` contains them (never `Graphable`; `MethodGraph.Key` ends in
`!broken`).

Graph side: `GraphBuilder.Build` on a Broken member returns the Entry node plus one Code node
whose `Node.Error` is set; its title is `Broken: <error>` and the header is `Theme.ErrorHeader`
(red). `Graph.ReadOnly = true`; `SourceDocument.Commit` ignores it (no body), so it can be
looked at and moved but never written back. Outline lists it as `!  Name (broken)` in red
with the error as tooltip, and it opens in a tab. Compile is still allowed: BeefBuild reports
the real error.

Known limits: a stray extra `}` that closes the type early is not detected (later members
simply become members of the enclosing scope, nothing is hidden). A type that misses its
closing `}` while its sibling starts at the same indentation is not detected either.

Lexer fix found by the corlib run: block comments nest in Beef (`/* a /* b */ c */`), which
the lexer now follows (it used to end the comment at the first `*/` and expose commented-out
code, which showed up as a false Broken member in `IO/Path.bf`).

`roundtrip` prints `broken=N` and lists every Broken member found in the input; on valid
sources N must be 0.

## 2. Layout keys

Before: a node's saved position was keyed by its position in the code (`s3/true/s0`), so
inserting a line in a text editor shifted every later node.

Now a position is stored under `methodKey|path#hash`:

* `path` is the structural path as before (`Node.Key`: `s3`, `s2/true/s1`, `s4/arg0`).
  Everything else in the editor (orphans, reroutes, selection) still uses the plain path.
* `hash` is 8 hex digits of FNV-1a over the node's own content: kind, text, second text,
  flags and the constant (unlinked) input values, each normalised by lexing (tokens joined by
  one space, so whitespace and comments do not count). A data node's hash is combined with its
  consumer's hash, so `x` in two different statements stays distinct and follows its statement.
  The Entry node hashes to 0 (editing the signature does not move it).

Example: `a2();` as the 4th statement is `C.M()|s3#9c41d2f7`. After a line is inserted above,
the statement is `s4` with the same hash.

**Matching on load** (`ApplyLayout` -> `LayoutKeys.Reconcile`), in this order:

1. exact: same path and same hash;
2. same hash, different path (the statement moved): paired in source order when several
   statements share a hash;
3. same path, different hash (the statement was edited). Old positional entries (no `#hash`)
   can only match this way.

Nodes that match nothing are new and get auto-layout near their neighbours. Saved entries that
match nothing are pruned: they are removed from the in-memory layout and not written back;
`SourceDocument.LayoutPruned` counts them. After loading, the matched entries of the method are
re-keyed in the new form, so the next sidecar write has no positional-only entries.
`CaptureLayout` replaces all of a method's entries by the keys of its current nodes.

Calls hash as they did before the call model ([Calls-and-Receivers.md](Calls-and-Receivers.md)): a static
call's qualifier counts as its old receiver text, and a Receiver wired from a plain name or a This node
as that name, so positions saved earlier keep matching exactly.

Limit: a statement that is edited and shifted by an insertion or deletion at the same time
matches nothing (new hash, new path) and is auto-laid out. Reroute knots and unconnected-node
records still reference nodes by plain path.

### Migration

* Old files have keys without `#`. They load through step 3 (path only);
  `SourceDocument.LayoutMigrated` counts how many were upgraded.
* The side file is written with a single `#vblayout<TAB>2` header (read into `SourceDocument.LayoutFileVersion`; the legacy `#version<TAB>2` line is still accepted). Migrating or pruning entries marks the layout touched, so the next write persists it.
* Unknown `#name` lines (and nothing else) are kept in `LayoutUnknown` and written back
  unchanged, so newer fields survive. Comment lines starting with `# ` are regenerated.

### Methods in `#if` / `#else` arms

Both arms of a conditional are parsed (directives are trivia), so a method declared in each arm
(corlib's `GC.Report()`: `extern` when leak checking is on, an empty stub otherwise) used to give
two members one key, and committing either was refused (the 172 corlib round-trip failures).

* `CompilationUnit.CondPathAt(token)` follows the directives in the leading trivia from the top
  of the file: the arms in force at a token, as `if A`, `elif B`, `else A`, nested ones joined by
  `; `. The parser stores it on every member that is inside a conditional (`Member.CondPath`).
* **Keys**: only members that would share a key (same type, name and parameter types) get a
  suffix (`Member.KeySuffix`, added by `GraphBuilder.MakeMethodKey`): the arm path first
  (`GC.Report() [if BF_ENABLE_REALTIME_LEAK_CHECK or BF_DEBUG_ALLOC]`, `... [else ...]`; `||` /
  `&&` spelled `or` / `and`, no `|` or `#`, which layout keys use), then a method's own `where`
  clause (`Variant.Get() [where T : class]`), then the `where` of an `extension` block
  (`CompactList.Remove(T) [where T : class]`), then a number. Every other method keeps the key it
  had, so existing side files and open tabs are unaffected.
* **Active arm**: `Preprocessor.IsActive(path)` evaluates the arms (`!`, `&&`, `||`, parentheses,
  `true` / `false`; unknown words are undefined) against `Preprocessor.Defines`, the defines of a
  Windows x64 Debug build (`BF_PLATFORM_WINDOWS`, `BF_64_BIT`, `DEBUG`, `BF_DEBUG_ALLOC`,
  `BF_ENABLE_REALTIME_LEAK_CHECK`, ...). An `#elif` is judged on its own condition. The Entry
  node's subtitle shows the arm (`#else BF_X (inactive in this build)`), and the Outline lists both
  twins with the arm, the inactive one dimmed.
* Result: corlib `roundtrip` 3,774 methods, **0 failures** (was 172); the UMP and ClockWork runs
  are unchanged.

## 3. Literals

`Expr.LitKind` (`LiteralKind`) is set for every Literal expression; `Literals.Classify(tokenKind, text)`
does the classification and is usable on any token.

| Source | Kind |
|---|---|
| `1`, `0x10`, `0b101`, `1_000`, `1'000` | Int |
| `5u`, `0xFFFFFFFF`, `0b11u` | UInt |
| `5L`, `3000000000`, `0xFFFFFFFFFF` | Long |
| `5UL`, `0xFFFFFFFFFFFFFFFF`, `18446744073709551615` | ULong |
| `1.0`, `1e3`, `.5`, `1.5d` | **Double** (Beef: not float) |
| `1.0f`, `1f`, `2.5e3f` | Float |
| `'a'`, `'\n'` | Char8 |
| `'\u{1F600}'`, non-ASCII char | Char32 |
| `"x"` | String |
| `@"x"` | VerbatimString |
| `$"x{y}"`, `$@"..."`, `@$"..."` | InterpolatedString |
| `"""..."""` | RawString |
| `true`/`false`, `null`, `this`, `base`, `default`, `.Case` | Bool, Null, This, Base, Default, EnumCase |

`0x1F` is Int: the `F` is a hex digit, not a suffix. `GraphBuilder.InferType` now uses the
kind (`1.0` infers `double`).

## How code maps to nodes (reference)

| Beef | Node |
|---|---|
| method | entry node (parameters shown as output pins) |
| `get { ... }` / `set { ... }` of a property or indexer | its own graph (`Type.Prop.get()`, `Type.Prop.set(T)` with `value`, `Type.this[].get(int)`); see [Classes-and-Members.md](Classes-and-Members.md) |
| `base.Foo(x)` | Call node, Receiver wired from a Base node |
| `Foo(a, b);` (a member function of this type or a base) | Call node with flow pins and an unconnected Receiver (this) |
| `obj.Foo(a);` / `this.Foo(a);` | Call node, Receiver wired from `obj` / from a This node |
| `Console.WriteLine(x);` / `Twice(x);` (static) | Call node without Receiver; the qualifier is kept on the node |
| `Get(1, var v)`, `Get(1, ?)`, `int v;` + `Get(1, out v)`, `Get(1, out b)` | Call node with an out pin `v` (readers of `v` wired from it) |
| `Fill(ref x)` | Call node, ref input wired from `x` |
| `Foo(a)` used as a value | pure Call node (green header) |
| `x = v;` `x += v;` `x++;` | Set node |
| `int x = 0;` at the top of the body (typed, a value that needs no node) | One of the function's local variables (`Graph.Locals`, Outline > LOCAL VARIABLES; not a node, written first, byte for byte) |
| `int x = v;` / `let x = v;` elsewhere | Local Variable node (its output pin reads the variable); Properties offers Move to Local Variables |
| `if / else if / else` | Branch (True / False / Completed) |
| `while`, `do while` | While Loop / Do While Loop |
| `for (let x in xs)` | For Each Loop (Element pin) |
| `for (int i = 0; i < n; i++)` / `for (int i < n)` | For Loop with a Counter output pin (`i`) and Start / Count inputs; other `for (...)` headers stay editable text |
| `return v;` `break;` `continue;` | Return / Break / Continue |
| `switch (x) { case A: ... case B, C: ... default: ... }` | Switch (one output per case, Default, Completed) |
| `// vb:sequence` followed by `{ }` blocks | Sequence (one Then output per block) |
| `if (!__doOnce_1) { __doOnce_1 = true; ... }` and the other `__doOnce_` / `__doN_` / `__flipFlop_` / `__gateOpen_` / `__gateClosed_` / `__multiGate_` shapes | Do Once, Do N, Flip Flop, Gate, Multi Gate (and their Reset / Open / Close / Toggle nodes) |
| names and member chains | compact Get nodes |
| `a + b`, `!x`, ... | operator nodes |
| `c ? a : b`, `(T)x`, `a[i]` | Select, Cast, Get [ ] |
| literals, `.EnumCase`, short code | editable values on the pin |
| `{ ... }` inside a body, `[ConstSkip] { ... }` | Scope (Body, Completed; attributes kept) |
| `(a, b) => a + b`, `scope [&] (v) => { ... }`, `new => Method` | Lambda / Create Delegate (see [Lifetime-Nodes.md](Lifetime-Nodes.md#the-last-text-forms)) |
| `int Twice(int x) => x * 2;`, `void Say() { ... }` inside a body | Local Function |
| `$"a {b} c {d:X2}"` with holes | Format Text, one input per hole |
| `const int k = 3;`, `ref T r = ref x;` | Local Variable with the modifier |
| `(.)x`, `.()` / `.(a)` | Cast to the inferred type, Construct with no allocation |
| `case .Ok(let v):` | a Switch case with a payload pin |
| anything else (`switch` with `fallthrough`, `when` or ranges; tuples, initialisers, ...) | Code node holding the exact text (the Properties panel says why) |

## Calls: layout keys

`LayoutKeys.ContentHash` hashes a static call's qualifier, and a Receiver wired from a plain name or a
This node, as the old text-in-Receiver shapes did, so positions saved before the call model still
match exactly.

## Classes: declarations in the parse

Every `Member` keeps the token span of each part of its declaration (`-1` when absent), so each
part can be replaced on its own without touching the rest of the line:

| Field | Covers | Example |
|---|---|---|
| `AttrFirstTok` .. `AttrLastTok` | the attributes | `[AlwaysInclude, Reflect(.All)]` |
| `ModFirstTok` .. `ModLastTok` | the modifier words | `public sealed` |
| `KindTok` | types: the kind keyword | `class` |
| `GenericOpenTok` .. `GenericCloseTok` | `<...>` after the name (types and methods) | `<T, U>` |
| `BaseColonTok` .. `BaseLastTok` | types: the base list with its `:` | `: Base<T>, IFoo` (an enum's `: uint8`) |
| `WhereFirstTok` .. `WhereLastTok` | the constraints | `where T : class where U : struct` |
| `InitTok` | fields (and auto-properties): the `=` of the initial value | `= 10` |

Properties and indexers have their **accessors** as members: `Member.Members` of a property holds
one method per `get` / `set` (`IsAccessor`, `AccessorOf`), named `Score.get` / `Score.set`
(`this[].get` for an indexer). A setter has a `value` parameter of the property's type, an
indexer's accessors have its index parameters. `CompilationUnit.CollectMethods` lists them with the
methods of the property's type, so every accessor with a body is a graph like any function, keyed
`Type.Score.get()`, `Type.Score.set(int)`, `Type.this[].get(int)`. `get;`, `set;` and `=> expr`
accessors have no body and no graph. An indexer (`int this[int i] { ... }`) is a property with
`IsIndexer`, `Name == "this"` and `Params`; it was a Raw member before.

On the UMP corpus this makes 28 more graphs (1,078 -> 1,106 methods), on corlib 814; all round-trip
(`roundtrip`, `orphans`).

The index (`ProjectIndex`, `SymbolStore` format 4) records `virtual`, `abstract` (also an
interface member without a default body), `override` and `sealed` on members and `abstract`,
`sealed`, `static` on types. The format bump rebuilds every library cache once.

## Math Expression records

A Math Expression node (`NodeKind.MathExpr`, appended after `Format`) writes the plain formula,
so the code alone reads back as the usual value nodes. The side file adds one line per node:

```
#math <tab> methodKey <tab> nodeKey <tab> chosen result type <tab> formula (escaped)
#orphanmath <tab> methodKey <tab> snippet key <tab> chosen result type <tab> formula (escaped)
```

`nodeKey` is the node's structural path without the hash (`s0/value`). When a graph is built
(`SourceDocument.BuildGraph`, also for the fresh graphs `RefreshFromCode` and `SameShapeAsCode`
compare against), `MathExpression.Restore` looks at the value at that path: when its code is the
formula with something in place of each name (`MathExpression.Match`, an AST match; a name used
twice must hold the same text), the value's nodes are replaced by the Math Expression node, the
node that made each value is wired into its input (a local, parameter or loop variable read is
wired from its output; anything else becomes the input's typed value) and nothing is marked
edited. A record that no longer matches (the formula changed by hand, a line added above it) is
ignored and the code reads as usual. Built graphs write their records afresh on save; a graph
dropped by a text edit leaves its records in `SourceDocument.MathRecords` (part of undo states).
Unconnected Math Expressions travel in the orphan record (`#orphanmath`, restored on the
snippet graph before its keys are used).

## Lifetime: layout keys and orphans

The five kinds were appended to `NodeKind`, so the kind numbers that layout keys hash are
unchanged. A short allocation that used to be the pin's text (`scope String()`) hashes the same
way when it is now a Construct wired into the pin, so saved positions of the node it feeds still
match. Nodes whose kind changed (a Branch on `X case .Ok` is now a Result node, a Code node
`using (...)` is now a Using node) get a fresh position.

Two orphan fixes came with the larger graphs: an impure call's `let` temp name is kept when the
call is unconnected and the layout is saved (an `#orphandefault` record with the pin `@temp`), and
a `T a;` declaration folded into an out pin keeps its exact line through the orphan copy, so a
comment or blank line before the statement stays on the statement.
