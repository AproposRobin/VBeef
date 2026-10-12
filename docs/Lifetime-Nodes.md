---
audience: user
title: Lifetime nodes
summary: Construct, Delete, Defer, Using and Result nodes, and the lifetime rules they follow.
order: 6
---

# Lifetime nodes: Construct, Delete, Defer, Using, Result

How Beef's allocation and lifetime constructs become nodes and go back to code: `new` / `scope`
allocations (**Construct**), `delete` (**Delete**), `defer` (**Defer**), `using` (**Using**) and
`Result<T>` pattern tests (**Result: match**), plus the lifetime rules the graph checks. This is
owner gap 3 and item 6.1 of the Production audit (sections 4 and
6.1).

Everything is plain Beef: each node is written as the statement or expression it stands for, and
the same code reads back as the same node. Code that does not fit one of the shapes below stays a
Code node or text in a pin, exactly as before, so nothing is ever lost.

Where it lives: `Syntax/Ast.bf` (`ExprKind.New`, `StmtKind.Delete / Defer / Using`), `Syntax/Parser.bf`
(`TryParseNew`, `ParseDelete`, `ParseDefer`, `ParseUsing`, the `case` operator), `Graph/Graph.bf`
(`NodeKind.Construct / Delete / Defer / Using / ResultMatch`, `Node.Alloc`, `Node.IsArray`),
`Graph/GraphBuilder.bf` (*lifetime nodes* section), `Graph/CodeGen.bf` (*lifetime nodes* section,
`AnalyzeLifetimes`), `Graph/GraphValidator.bf` (`CheckLifetime`), `Graph/NodeFactory.bf`, and in the
editor `NodeMenu.bf` (category *Lifetime*), `EditorApp.bf`, `GraphPanel.bf` (`LifetimeSubtitle`),
`PropertiesPanel.bf` (`DrawLifetimeDetails`), `PinStyle.bf`, `Theme.bf`.

## Construct

A pure node with one output (the object) and one input per constructor argument.

| Code | Node |
|---|---|
| `new Item()` | Construct `Item`, allocation `new`, output typed `Item` |
| `new Item(3, "x")` | the same with inputs `value`, `name` (named and typed from `this(int value, String name)`) |
| `scope Item()` / `scope:: Item()` / `scope:outer Item()` | allocation `scope` / `scope::` / `scope:outer` |
| `new:gAlloc Item()` / `append String()` | allocation `new:gAlloc` / `append` |
| `String s = scope .();` / `Take(scope .())` | type `.` (inferred): the output takes the type of the input it feeds (`String`) |
| `new int[n]` / `scope uint8[4]` | `IsArray`: one **Count** input per dimension, output `int[]` |
| `scope $"x = {x}"` / `new $"..."` | type `$`: a **Text** input holding the interpolated string, output `String` |
| `new String()..Append("h")` | a Construct wired into the Receiver of the cascade call |

* **Allocation** (`Node.Alloc`) is the keyword exactly as written, without spaces: `new`, `scope`,
  `scope::`, `scope:label`, `new:allocator`, `append`. Properties shows it as a dropdown with *custom*
  for allocator / label forms. The node's subtitle says how long the object lives
  ("scope: freed when the block ends", "new: you delete it", ...).
* **Output type**: the type text; `T*` for `new` of a struct the resolver knows; `T[]` for arrays;
  `String` for the `$` form; for `.()` the type of the first input the value is wired into.
* **Constructor arguments** go through `GraphBuilder.BuildArg` like call arguments, so `ref`, `out`
  and `var x` arguments work the same way. Names and types come from the type's `this(...)` overload
  that takes that many arguments: the method's own type, any type declared in the same file, the
  project index or the `TypeService` (libraries); otherwise the pins are `Arg 0`, `Arg 1`.
* **Stays text**: initialiser blocks (`new List<int>() { 1, 2 }`), `new T[] (1, 2)`, `new [Friend]`,
  tuples, and lambdas / delegates (`new () => ...`, `new => Method`, `scope [&] () => ...`), which
  are owner gap 5.
* A Construct read by several inputs is written once into `let __vN = scope T();` before the first
  reader (an allocation is never "trivial").
  When a Defer's Deferred body reads it and a statement after the Defer reads it too (Defer -> Delete
  of an object the function then uses), it is written before the Defer:
  `let __v0 = new Greeter(); defer delete __v0; __v0.Run();`.

## Delete

A flow node with an **Object** input: `delete x;`, `delete:gAlloc x;` (the keyword is `Node.Alloc`).
The input is wired from what it deletes (a Get of `x`, a local's variable pin, a call result).
`DeleteAndNullify!(x)`, `DeleteContainerAndItems!(list)` and `DeleteDictionaryAndValues!(d)` are
mixin **calls** and already were call nodes (named `DeleteContainerAndItems!`); `lifetime` checks it.

## Defer

A flow node with a **Deferred** body and **Completed**:

| Code | Node |
|---|---|
| `defer delete x;` | Defer -> Delete (the most common form) |
| `defer { a(); b(); }` | Defer with two statements in Deferred |
| `defer:: Console.WriteLine("d");` / `defer:mixin ...` | the scope label in `Node.Alloc` (`defer::`, `defer:mixin`) |

Writing: a Defer whose body is one plain statement and had no braces is written on one line
(`defer delete x;`); a body of several statements, a compound statement, or a Defer that had
braces is written `defer { ... }` in the file's brace style (`defer {` stays K&R). The deferred
body is its own block for scope analysis. Beef runs it when the enclosing block ends, last Defer
first; the subtitle says "runs at the end of the block" (`defer::`: "when the method returns").

## Using

A flow node with a **Value** input, a **Body** and **Completed**: `using (sLock.Enter()) { ... }`
(the lock idiom) or `using (let scope1 = sLock.Enter()) { ... }`, which adds a **variable**
output (name and type in Properties, like a Local Variable). The variable can be read only inside
Body (refused elsewhere, like a loop element). Headers keep their spelling (`using(` / `using (`,
K&R or Allman) while only the body changes.

## Result: match

`if (X case .Ok(let v)) { ... } else { ... }` is a branch on a `Result`:

| Pin | Meaning |
|---|---|
| flow in | |
| **Result** (data in) | the value tested (`X`) |
| **Ok**, **Err** (flow out) | the two arms |
| **Completed** | the code after the `if` |
| **Value** / **Error** (data out) | the bound payload (`v`), typed `T` of `Result<T>` (`E` of `Result<T, E>` for `.Err(let e)`) |

* `Node.Text` is the case the `if` tests: `Ok` (`if (X case .Ok...)`, the if-arm is Ok) or `Err`
  (`if (X case .Err) return .Err;`, the if-arm is Err). Properties switches between them.
* The payload pin is an out-style pin (`Pin.Mode == .Out`, the call model's plumbing): readers wire
  from it and the code reads the variable. It exists in the tested arm only; a wire that reads it
  anywhere else is refused. It is written `.Ok(let v)` when something reads it or when the code had
  a binding (`let` or `var` kept), `.Ok` otherwise; a new node names it `value` / `error`.
* `else if (Y case .Err)` chains read as a Result node in the other arm and are written back as
  `else if`.
* Every other pattern test is an **Operator** node `case` whose second operand is the pattern text,
  like `is` / `as`: `bool ok = X case .Ok;`, `return X case .Ok;`,
  `if (Root.TryGet("x") case .Ok(let a) && a.IsString())`. The parser takes `case` as an operator
  only after a postfix expression (a name, member, call, index, parenthesised expression), binding
  tighter than `&&` / `||`; the generator puts a `case` inside any other operator in parentheses.
  A binding in such a test (`let a`) stays a name read by Get nodes.
* `Try!(expr)` is a call node `Try!` whose result is typed `T` (subtitle "returns early on error");
  `.IgnoreError()` is an ordinary call. A `switch` over a Result is a Switch node, payload cases
  (`case .Ok(let v):`) included: the binding is a payload pin of that case (see
  [Flow-Nodes.md](Flow-Nodes.md#switch)).

## Lifetime rules

**How `scope` lifetimes are modelled.** A Construct is a pure node, written where its value is
read; when several inputs read it, it is written once into a `let __vN` temp before the first
reader. So a `scope` object lives until the end of the block of the statement that evaluates it,
and the generator's planning pass already knows that block for every statement. A pure value can
only outlive that block through a **variable** (`s = scope String();` into a local declared outside
the block, then read after it) or by being **returned**; those are the two things checked.
`scope::` lives until the method returns (only returning it is wrong); `scope:label` is not checked.

| Rule | Where | Severity |
|---|---|---|
| A `scope` value stored in a local inside a block and read after that block (reads by name or by wire) | CodeGen planning (`AnalyzeLifetimes`) | **error** on the Construct ("This value was allocated with `scope` in a block that has ended. Allocate it with `scope::` ...") and on each reader |
| A `scope` value stored in a field (anything that is not a local or parameter) | CodeGen planning | warning |
| A `scope` value (or a local initialised with one) returned | CodeGen planning | **error** ("Returns a value allocated with `scope` ...") |
| A Result node's Value / Error read outside its tested arm | CodeGen planning | **error** |
| A value computed in a Defer body (a call result, an out value) read outside the body | CodeGen planning | **error** (the body runs when the block ends) |
| `return` in a Defer body; `break` / `continue` leaving it | CodeGen planning | **error** (Beef: "Deferred blocks cannot contain 'return' statements", and the error for a break that crosses a deferred block) |
| A Defer whose body reads `x` while a later Defer in the same block deletes `x` (Defers run last-first) | CodeGen planning | warning on the earlier Defer |
| A Using variable read outside its Body | CodeGen planning (`AnalyzeProducers`) | **error** |
| A local declared after a Defer and read in its body | CodeGen planning (existing rule) | **error** (read before it is declared) |
| A Construct of a project class whose constructors all take inputs, with no inputs on the node (`new Greeter()` would not compile) | GraphValidator (`CheckWritable`, `NeedsConstructorChoice`) | **error** on a node made or edited in the editor ("Greeter needs a constructor: choose one in Properties > Constructor ..."), warning when read from code. Properties > **Constructor** lists the class's constructors; picking one gives the node one input per parameter |
| `delete` of a `scope` value (directly, or of a local initialised with one) | GraphValidator (`CheckLifetime`) | warning (double free) |
| A `new` object, made in the editor, that nothing deletes or takes over (only its members are used) | GraphValidator | warning, never an error |

The rules that need to know which block a statement is written in run in the generator's
planning pass, right after the out-pin analysis; the graph-only ones run in GraphValidator. Both
report through `Graph.Errors` / `Graph.Warnings`, so the editor shows them on the node and an error
refuses the commit like every other refusal.

**Code as read is never refused.** "Unresolved is never an error" applies: when the allocation,
the store and the reader were all read from the code (the compiler accepted it), the `scope` rules
are warnings; they are errors only once the graph was edited there (a node or a wire made in the
editor). The `new` ownership warning is only given for Construct nodes made in the editor (a thread
started with auto-delete, an object that registers itself, ... are the author's call). On a mod platform's
sources and ClockWork a dry generation reports no lifetime error and no warning.

## The last text forms

What the coverage probe still showed as text after the lifetime nodes, now nodes (all in
`Syntax/Parser.bf`, `Graph/GraphBuilder.bf`, `Graph/CodeGen.bf`, `Graph/NodeFactory.bf`; the
kinds were appended to `NodeKind`, so existing layout keys keep their numbers):

| Code | Node |
|---|---|
| `scope (a, b) => a <=> b` / `x => x + 1` | **Lambda** (pure): parameters as outputs (`param0`...; read by name inside, like a function's parameters), the expression wired into **Returns**, the allocation (`scope`, `new`, `scope::`, none) in Node.Alloc |
| `scope [&] (v) => { ... }` / `new () => { ... }` | **Lambda** with a **Body** flow output: the statements are a chain inside the lambda, written into its braces at the statement's indentation; the capture list (`[&]`, `[=]`) in Node.Attributes |
| `new => OnTick` / `=> obj.Method` | **Create Delegate**: a Lambda whose Text2 is the method (no parameters, no body) |
| `mOnValue += new (x) => ...;` / `Ctx.Log = => HostLog;` | a Set (`+=` / `=`) whose value is a Lambda: events and delegate fields bind like any assignment; `mOnValue.Add(new => OnTick)` is a call with a Create Delegate argument |
| `(function int())=> StubReturnZero` | a Cast of a Create Delegate |
| `int Twice(int x) => x * 2;` / `void Say(String s) { ... }` | **Local Function** (a statement): the declaration in Text2, parameters as outputs, Body or Returns |
| `$"count={count} hex={count:X2} pad={name,8}"` | **Format Text** (pure): the literal with each hole's expression taken out (`$"count={} hex={:X2} pad={,8}"`), one input per hole, built like any expression (calls, operators, `case` tests); `{{`, `$@` / `@$` kept; a string with no hole stays a pin value |
| `scope $"{x} items"` | a Construct `$` whose Text input is wired from a Format node |
| `const int kLimit = 3;` / `ref FPage page = ref sPages[i];` | Local Variable with the modifier in Node.Alloc (subtitle `const int`); Properties has a Modifier dropdown |
| `(.)GetProcAddress(...)` | Cast with the type `.` (the type of where the value goes) |
| `Result = .();` / `.(a, b)` | Construct with no allocation (Alloc empty): a value of the inferred type made in place |
| `x >>= 4;` | a Set (it used to read as `x > (>= 4)` and stay text) |

**Captures.** `Graph.GetCaptures(lambda)` lists the parameters and locals of the enclosing
function that the lambda reads (Get nodes by name, plain names in pin values, wires from
variables and out values outside it); its own parameters and locals are not captures, and
fields are reached through `this`. The node's subtitle shows them ("scope: freed when the block
ends | captures by ref sum, factor"), Properties lists them with the allocation, parameters and
capture list editors.

**Round trip.** An unedited lambda, local function or Format node is written from its original
text. A regenerated one: `alloc [captures] (params) => expr`, or `=> {` plus the body as a block in
the file's brace style; a Format hole whose expression has a top-level `:`, `,` or `?` is put in
parentheses. A short lambda or a Format that replaced pin text hashes like that text in layout
keys, so saved positions of the node it feeds still match; statements in a lambda body get keys
under the lambda (`s1/arg0/body/s0`). The orphan codec writes a lambda's body inside the
lambda, never as a chain of its own; the generator treats a lambda's statements as statements
(for temps, out values and scope analysis) inside the statement that holds the lambda.

**Still text** (on a mod platform's sources: 10 Code and 20 Expression nodes left, in 21 of 1,366 bodies): tuple
assignments and `let (a, b) = ...` (6), object initialisers `.() { x = 1 }` /
`JsonWriterOptions() { Indented = true }` (8), casts the parser cannot tell from arithmetic
(`(uint)*(uint64*)p`, `*(uint32*)&b[0] = ...`: 5), `offsetof(...)` (2), assignments used as values
(`NewLine = Carry.IndexOf('\n')`, `a = b = 0`: 2), `new T[n]*` pointer arrays (2 pin values). Each
needs its own node shape (tuples, initialisers) or the compiler's type information (the casts);
none hides a semantic the graph gets wrong.

## Limits

* `switch` cases with `when` guards, ranges or several bindings stay Code nodes; payload cases with
  one binding are Switch cases with a payload pin. A pattern test inside `&&` is an operator whose
  binding is read by name, not a pin.
* One-line bodies (`using (x) Foo();`, `defer { a(); }` on one line) get braces and their own lines
  when the node is regenerated (the same as `if` / `while`); untouched ones are copied as they are.
* The `scope` checks follow values through locals and returns; a `scope` value passed to a function
  that keeps it, or stored through a pointer, is not seen.
* Constructor overloads are matched by argument count (and types, through the TypeService); there
  is no overload dropdown yet (the same as calls).
* Initialiser blocks and `new [Friend]` are not nodes; lambdas and delegates are (see above).
* A lambda body's statements are checked like any statements, but a value made inside the body
  and read outside it is not refused yet (the compiler reports it).
