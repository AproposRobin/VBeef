---
audience: developer
title: Code generation rules
summary: How a method graph is turned back into Beef statements, and what is refused.
order: 12
---

# Code generation rules

`VisualBeefCore/src/Graph/CodeGen.bf` turns a method graph back into the method body.
`SourceDocument.Commit` splices that body into the file. (Declarations, the method headers, base
lists, modifiers and attributes, are written by the class-level splices of
[Classes-and-Members.md](Classes-and-Members.md), not by the generator.) The rule behind everything here:
**the generated code must never quietly do something different from what the graph says.**
If the generator cannot express a graph safely, it refuses to write it and says why on the
node at fault. It never writes a "best effort" version.

## How a commit runs

1. **Collect.** The generator collects the execution flow (flow nodes reachable from the
   entry) and every node that feeds it data.
2. **Validate.** `GraphValidator` checks those nodes before anything is written: a member call's
   Receiver / this, inputs that need a value, `ref` arguments, the types of wires made in the editor.
   Its errors refuse the commit like the generator's own; its warnings are only shown. See
   [Calls-and-Receivers.md](Calls-and-Receivers.md#graphvalidator).
3. **Find shared values.** These are data nodes whose output is read more than once (see
   *Temporaries* below).
4. **Planning pass.** The whole body is generated into a scratch buffer. Along the way the
   generator records:
   - which block (`{ }`) each statement lands in, and in what order;
   - which statements read the value of an flow node (a call result, a local variable, a
     loop element);
   - every error.
5. **Scope analysis.** Each read is checked against the block of the node it reads. Call
   results that are read after their block are scheduled to be *hoisted*; each out pin gets its
   spelling (`var name`, `?`, or a declaration before the statement or hoisted). Then the
   lifetime rules that need blocks run (`AnalyzeLifetimes`: `scope` values after their block,
   a Result node's value outside its arm, Defer bodies; see
   [Lifetime-Nodes.md](Lifetime-Nodes.md#lifetime-rules)).
6. **Writing pass.** The body is generated again, this time with the hoisted declarations.
   The output has exactly the same shape as the plan.
7. **Commit or refuse.** If `Graph.Errors` is not empty, `Commit` returns `false`. The file
   text stays as it was, and the graph keeps its edits (and its undo step). Each error is
   attached to a node, so the editor draws a red border and a message badge on that node.
   The errors are also listed in the *Messages* tab and the status bar, prefixed with
   `Not written -`. The next commit after you fix the graph writes everything.

## Only edited statements change

Unchanged code is copied from the original text, never regenerated.

- **Clean statements** (neither the statement nor anything it reads was edited) are copied
  as they are, including their comments and the whitespace around them.
- **Statements marked edited that read back the same.** Wiring an flow pin marks both ends
  as edited, even when the statement's own code has not changed. If the regenerated
  statement has *the same tokens* as the original (whitespace and comments may differ), the
  original text is kept. Inserting a node after `x=1;` leaves `x=1;` alone.
- **Compound statements** (`if`, `while`, `do`, `for`, `foreach`) whose body changed keep
  their original header, as long as the regenerated header has the same tokens. They also
  keep the original spacing before `{`, between `}` and `else`, and the `while (...);` tail
  of a `do`. Adding a node inside `while(bRunning) {` therefore no longer rewrites the
  header to `while (bRunning)`.

## Style of new code

Statements that really are new or changed follow the conventions of the code around them:

- **Keyword spacing:** `if (` or `if(` (the same applies to `while` and `for`).
- **Brace placement:** Allman (`{` on its own line) or K&R (`{` at the end of the line).
- **`} else`:** on one line, or with `else` on its own line.

The method's own compound statements decide. When the method has none, the whole file
decides. When neither has any, the defaults are `if (`, plus whatever brace style the file
mostly uses, with `else` on its own line. Indentation (a tab or N spaces) comes from the
file.

## Temporaries

### Shared values: `let __vN = <expr>;`

A data node may be wired to several inputs. If its value is *not trivial*, it is computed
**once**, into a temporary declared right before the first statement that reads it:

```beef
let __v1 = list.PopBack();
int a = __v1;
int b = __v1;
```

A value counts as trivial when reading it twice is the same as reading it once: a name, a
literal, a member read, or operators, casts, selects and indexers built only from those.
Trivial values stay inline at each use, exactly as before. Anything that contains a call,
`++` or `--`, `new` or `scope`, or code the generator cannot see into is not trivial.

The rules for shared values:

- **Single use stays inline.** A value read by only one input is written inline, so code
  that was not edited keeps round-tripping byte for byte.
- **Declared once per run of the declaring statement.** The temporary is declared just
  before the first statement (in program order) that reads it. Inside a loop body, it is
  computed once per iteration. If it is first read before the loop, it is computed once.
- **Stable names.** The name is stored on the node, so it does not change from one commit
  to the next. `__vN` skips any name that is already in use.
- **Read back as one node.** When the file is parsed, `let __vN = <expr>;` folds back into
  the single shared node, with its wires to every reader. This happens only if the result
  would regenerate to exactly the same lines: the value is read at least twice, it is not
  trivial, and it is declared directly before its first reader, in the order the generator
  writes. Otherwise the line stays an ordinary local variable.
- **Calls that are not in the flow.** An impure call that is not connected to the
  execution flow but feeds several inputs is treated the same way. It gets
  `let fooResult = Foo();` before its first reader.

### Call results: `let fooResult = Foo();`

This rule is unchanged: an impure call whose result is read stores the result in a `let`
temporary at the call.

### Hoisting call results

A call can run inside a block (a branch arm or a loop body) while its result is read
*after* that block. In that case the declaration moves up to the innermost block that
contains both the call and every reader, and the call assigns it:

```beef
int computeResult = default;
if (flag)
{
	Console.WriteLine("computing");
	computeResult = Compute(4);
}
Console.WriteLine("value {}", computeResult);
```

On a path where the call did not run, the value is `default`. This matches what an unset
output pin means in a node graph. Hoisting needs the call's return type to be known, because
it has to write `T name = default;`.

## Calls

How a call is written depends on how it binds (more on the reading side in
[Calls-and-Receivers.md](Calls-and-Receivers.md)):

- **Static** (`Node.Binding == .Static`): `<qualifier>.Name(...)` with the qualifier exactly as it
  was read (`Console`, `System.Math`), or `Name(...)` when it has none. There is no Receiver pin.
- **Member** (`.Instance`): `<receiver>.Name(...)` when the Receiver is wired (a This node writes
  `this`, a Base node `base`) or holds text, `Name(...)` when it is unconnected (this). `?.` and
  `..` are kept. `base.Tick(DeltaSeconds)` is how an override calls its parent's version
  ([Classes-and-Members.md](Classes-and-Members.md#the-base-node-base)).
- **Unresolved**: as read.
- Arguments in order (`Node.GetArgPins`): values, `ref <value>` for ref inputs, and for out pins the
  variable: `var name`, `?`, `out name` (declared before the statement), `out b` (an existing
  variable), `ref name` (`[Pin(Out=true)]`).

### Out variables

| The out pin is | Written |
|---|---|
| read by nothing, made in the editor | `Get(1, ?)` |
| read in the call's statement, its bodies, or later in its block | `Get(1, var value)` |
| read after a `while` whose condition calls it | `int value;` before the loop, `out value` in the condition |
| read after the block the call runs in | `int value = default;` hoisted before the enclosing statement, `out value` at the call |
| read where the call has not run | refused |
| read from code as `T a;` + `out a`, `out b`, `var a`, `?` | kept as read (a new reader after the block still moves the declaration up) |

Beef 0.43.6 has neither `out let x` nor `out _` (`var x` / `let x` in the argument and `?` are its
forms). The hoisted declaration has the same rule as a hoisted call result: it needs a known type.

## Execution merges

Every flow node is written exactly once, so the generator never duplicates code.

- **Diamond after a Branch.** If both arms of a Branch lead to the same node X (directly,
  or after other nodes), X and everything after it are written once, after the `if` /
  `else`. This also works with nested Branches (inner arms that merge into the outer merge
  point) and with `else if` chains whose arms all meet again.
- **Diamond after a Switch (N arms).** The same rule for every output of a Switch: when
  *all* arms (each case, and Default) lead to the same node X, X is written once after the
  closing `}`. An arm that is empty, or a Default that is not wired, means "nothing runs
  after this arm", so there is no merge and the usual refusal applies (wire Default too, or
  use *Completed*). The same rule covers Flip Flop (A and B) and a looping Multi Gate (all
  Outs). Do Once, Do N, Gate and a Multi Gate that does not loop have an implicit "skipped"
  path, so they never merge; wire their *Completed* output instead.
- **Arm wired into Completed.** An arm that continues into the Branch's own *Completed*
  flow simply ends there. The generated code is the same as without that wire.
- **Any other merge is refused.** This includes a loop body that continues into the node
  after the loop, and two unrelated statements wired into one node. The error is on that
  node: *"Two execution wires lead into this node, so its code would be written twice..."*

## What is refused, and why

Nothing is dropped silently: a graph the writer cannot express gets an error on the node (the commit is refused and the file stays as it was); a node that produces no code (never reached by the flow, or an empty Code node) gets a warning saying nothing is written for it.

| Graph | Error (on the node) | Why it can't be written |
|---|---|---|
| Two flow wires into a node that is not a Branch diamond | Two execution wires lead into this node… | Its code would be written twice. |
| Flow cycle (the flow loops back to a node already running) | Execution loops back into this node… | A cycle needs a loop statement. |
| A call result read on a path where the call has not run: the other branch, or earlier in the flow | Reads the result of 'X', which has not run on this path… (and on the call) | No ordering can make the value exist there. |
| A call result read after its block when the return type is unknown | …its type is unknown… | It can't be hoisted without a type. |
| A local variable's pin read outside its block, or before its declaration | Local 'x' is read outside the block that declares it… | The name is not in scope there. |
| A loop element pin read outside the loop body | The loop element 'x' is read outside the loop body. | The name is not in scope there. |
| A shared value first computed in a block and read outside it | This value is shared by nodes in different blocks… | Computing it earlier would change *when* it runs. |
| A shared value that feeds a `while` / `do` condition | This value feeds a loop condition… | One shared value would freeze the condition. |
| Data loops, or nodes with no code form | Data loop… / This node has no code form. | There is no valid expression. |
| A Switch case with no value | A case has no value… | `case :` is not Beef. |
| A Reset / Open / Close / Toggle node with no (or a wrong) state field | '…' must name the state field of a … | There is no field to change. |
| A Sequence / Multi Gate with no outputs | …needs at least one output | There would be nothing to write. |
| A call result read after the Sequence it ran in | …is read after the Sequence it runs in… | A Sequence cannot declare a hoisted variable in front of itself. |
| An out pin read where its call has not run (another branch, earlier, a do-while body reading its condition's out value) | Reads the out value 'x' of 'Foo', which has not run on this path… (and on the call) | No ordering can make the variable exist there. |
| An out pin read after its block when its type is unknown | …its type is unknown… | The hoisted `T name = default;` needs the type. |
| A member call with this in a static method, or this of another type; a wire of an unrelated type into Receiver | Receiver must be a Player: … / Receiver must be a Player; this is an Enemy. / …the wire brings an Enemy. | There is no `this`, or it is not a Player (GraphValidator). |
| A function declared `override` with nothing virtual or abstract of its signature in the (fully known) base chain | 'Foo' is marked override, but no base class of Enemy has a virtual or abstract Foo(int) to override. … (on the Entry node) | It would not compile (GraphValidator, `ClassModel.CheckEntry`). |
| A Parent (`base`) node in a static function | There is no parent (base) here: … | There is no `this`. |
| An input with neither a wire nor a value; a `ref` argument from a value; a wire or typed value of the wrong kind | 'x' needs a value… / ref needs a variable… / 'x' takes int, but… | The code would not compile (GraphValidator). |
| A Construct without a Type (`.`) wired into a Receiver; a new Local Variable, For Each, Call or Get without a name; a Cast without a type | A Construct without a Type cannot be used as a Receiver� / This node has no name� | The text would not compile (GraphValidator `CheckWritable`). `scope Greeter(1, null).Ping()` itself is valid and is written as typed. |
| A `scope` value stored in an outer local inside a block and read after the block; a `scope` value returned | This value was allocated with `scope` in a block that has ended… / Returns a value allocated with `scope`… | The object is already freed (read from code: a warning). |
| A Result node's Value / Error read outside its tested arm | Reads the Ok value of a Result match outside its Ok arm… | The bound variable does not exist there. |
| A value computed in a Defer body read outside it; `return` in a Defer body; `break` / `continue` leaving it | …runs inside a Defer body… / A deferred body can't return… | The body runs when the block ends; Beef refuses the jumps. |
| A Using variable read outside its Body | '…' of this Using is read outside its body… | It is disposed (and out of scope) there. |

An impure call outside the flow whose value is read **once** is still called where the
value is used. This is a warning, not an error, because the code does what the graph says.

## Switch and flow macros

`switch` and the flow macros are written by the same pass; see [Flow-Nodes.md](Flow-Nodes.md).
In short:

- A Switch is written `switch (value)`, then each output in order as `case <label>:` /
  `default:` followed by its statements, then the code after the switch. `case` lines keep
  the indentation, comments and spacing of the clause they were read from; new clauses use
  the layout of the other switches in the method (cases level with the braces by default).
  Default is written only when it has a body, was in the source, or is marked "write
  `default:` even when empty".
- Each case body is its own block for scope analysis, like a Branch arm.
- Flow macros regenerate only when edited. Their state fields (`private bool __doOnce_1;`)
  are added to the owning type in the same commit (`static` when the method is static), once
  and only when the type does not have them. A node with no state name, a name that does not
  match the macro, or a name another macro in the graph uses gets the next free `__doOnce_N`.
- `break;` inside a switch case leaves the switch, not the loop around it. The generator
  writes what the graph says and adds a warning when that happens inside a loop.

## Lifetime nodes

Construct, Delete, Defer, Using and Result nodes are written by the same pass; see
[Lifetime-Nodes.md](Lifetime-Nodes.md). In short:

- A Construct is written `<alloc> <Type>(<args>)` (`scope .()` for an inferred type,
  `new int[n]` for an array, `scope $"..."` for the string form); the allocation keyword is
  kept exactly (`scope::`, `new:alloc`). It is never trivial, so a Construct read twice is
  computed once into `let __vN`.
- Delete is `delete <value>;`. Defer is `defer <statement>` on one line when its body is one
  plain statement that had no braces, `defer { ... }` otherwise (the original `defer {` spacing
  is kept). Using is `using (<value>)` or `using (let x = <value>)` with its body, header kept
  while only the body changes. The Defer body and the Using body are blocks for scope analysis.
- A Result node is `if (<value> case .Ok(let v)) { Ok } else { Err }` (`.Err` first when it
  tests Err), with the binding written only when the payload is read or the code had one; in
  an else arm it continues an `else if` chain. Any other `case` test is an Operator `case`.

## Comments and declarations

A statement written with declarations in front of it (an out variable `T a;`, a shared value
`let __vN = ...;`, a hoisted result) gets its leading comments after those lines, right above
the statement, so they read back on the statement (and a `T a;` line still folds into the out
pin). Statements that keep their exact original lead (unmoved) are written as they were.

## Tests

- `VisualBeefTests lifetime`: Construct / Delete / Defer / Using / Result parsing, shapes, round
  trips, code for new nodes and the lifetime rules (see
  [Lifetime-Nodes.md](Lifetime-Nodes.md#tests)).
- `VisualBeefTests calls` (also in `flow` / `edits`): the call model, out pins and GraphValidator
  (see [Calls-and-Receivers.md](Calls-and-Receivers.md#tests)).
- `VisualBeefTests classes`: declaration edits, stubs, override signatures, the Base node, the
  override check, accessor graphs, renames (see [Classes-and-Members.md](Classes-and-Members.md#tests)).
  A compile case can make class-level edits before its graph edit (`Case.Prepare`) with a
  TypeService over its file (`Case.WithTypes`).
- `VisualBeefTests compile [-out <dir>] [-v]` is the compile-and-run harness
  (`VisualBeefTests/src/CompileTests.bf`). For each case it does the following:
  1. loads a small Beef program;
  2. edits the graph the way the editor does;
  3. commits;
  4. checks the generated text;
  5. checks that a second commit, and a full regeneration of the reparsed file, reproduce
     the same text;
  6. writes the file into a scratch workspace and builds it with BeefBuild;
  7. runs the program and compares its stdout.

  The refusal cases check that commit fails, the file is untouched, and the error is on a
  node. The default scratch folder is `<temp>/vb-codegen`. Pass `-out` to use another.
- `VisualBeefTests flow` (also part of `edits`) covers switch and macro parsing, graph shapes,
  byte-exact regeneration, scripted edits, merges, state fields and refusals;
  `VisualBeefTests factory` checks that every Switch / flow node from the node menu reads
  back as the same node. `compile` has a case per macro that runs the generated code
  (Do Once fires once, Flip Flop alternates, Gate respects open / close, ...).
- `VisualBeefTests edits` and `VisualBeefTests roundtrip <dirs>` must stay green.

## Calls: extending the builder

* Every call goes through `GraphBuilder.FillCall` (binding and Receiver) and `BuildArg` (one argument:
  value, `ref`, out). A new expression kind that contains calls gets all of this by calling
  `BuildExprNode` / `BuildInput`.
* Out variables are scoped per block by `BuildChain` (`mOutVars`); a construct that opens a scope of
  its own (a `using`, a `defer` body, a lambda) should build its body through `BuildChain` / `BuildBody`
  so out variables declared inside stay inside.
* Declaration lines that fold into a node (`let __vN`, `T a;`) are collected in `BuildChain` before
  the statement they belong to; a new statement kind that is a valid fold point needs nothing extra,
  one that is not (raw text, blocks) is rejected by `CanFoldOutDecl`.
* In `CodeGen`, the planning pass records where each call is written (`mOutHome`) and who reads each
  out pin (`mOutUses`); `AnalyzeOuts` decides spellings and declaration anchors (`mOutDeclAt`), and
  `GenStatement` writes the declarations as pre-lines (hoisted results, out declarations, shared
  values, in that order). A new compound statement must record its body scopes like the existing ones
  (`Block`, `PushScope`) for the out-pin scope analysis to see them.
* `GraphValidator` is the place for node-anchored checks that need no code (a `scope` value read
  outside its block, an override's signature): add a check there, keep "unresolved is never an error",
  and add a case to `CallTests`.
* `Pin.Mode`, `Pin.Form`, `Node.Binding`, `Node.OwnerType`, `Node.Qualifier` are copied by
  `Graph.CloneNodeExact` and the orphan / clipboard copies (`OrphanSet.CloneNode`); keep new fields in
  both.
