---
audience: user
title: Calls, Receivers and out pins
summary: How function calls appear as nodes, what the Receiver pin does, and how out and ref arguments are drawn.
order: 5
---

# Calls, Receivers and out pins

How a function call becomes a node and goes back to code: the **Receiver** pin of member calls and
its "this" default, static calls, the **This** node, `out` parameters as output pins, `ref`
arguments, and **GraphValidator**, which reports problems on the node before anything is written.
This answers the production audit's owner gaps 1 and 4 (with
6.2 live checks, the 6.6 ambiguity marker).

The owner's rule, which everything here implements:

> A member-function call node has a **Receiver** pin of the owning class type. Unconnected means
> `this` (drawn as "this"). If the enclosing context's `this` is not of the owning type,
> or there is no `this` (static method, free context), it is a compile error on the node ("Receiver
> must be a &lt;Type&gt;"), and it blocks writing code. Static calls
> have no Receiver pin. A **This** node provides `this` as a value for wiring.

A **Set** node's first pin is not a Receiver: it is the **Variable** being set (a field, parameter,
local, array element; `value = mCount;`, `start++`, `local += start`), so it is labelled
*Variable*. Its pin id is unchanged (the same as the Receiver's), so saved layouts still match.

A print read from code, `Console.WriteLine("text")` or `Console.Write("text")` with one argument,
takes any value like a Print placed from the Node menu: its pin is `obj` typed `Object` (Beef's
`WriteLine(Object)`), not the `StringView` of the overload the text resolves to. Wiring a number
into it writes `Console.WriteLine(i)`; the text as written is unchanged.

Where it lives: `Graph.bf` (the model), `GraphBuilder.bf` (`FillCall`, `BuildArg`, the out-variable
scopes and folds), `NodeFactory.bf` (`StaticCall`, `MemberCall`, `This`), `CodeGen.bf` (`CallText`,
`ArgText`, `AnalyzeOuts`), `GraphValidator.bf`, and in the editor `GraphPanel.bf`, `NodeMenu.bf`,
`EditorApp.bf` (`CreateCallNode`, `ReportGraphIssues`, `EnsureChecked`), `PropertiesPanel.bf`.

## The three call shapes

| Code | Node | Binding |
|---|---|---|
| `Foo(1)` in a type that has (or inherits) a member function `Foo` | Call `Foo`, **Receiver pin unconnected** (drawn "this"), typed with the declaring type | Instance |
| `this.Foo(1)` | Call `Foo`, Receiver **wired from a This node** | Instance |
| `obj.Foo(1)`, `mList.Add(x)`, `GetEnemy().Foo()`, `a[i].Foo()` | Call `Foo`, Receiver **wired from the node of `obj`** (a Get, a call, an index...) | Instance |
| `Console.WriteLine("x")`, `Math.Max(a, b)`, `System.Console.Write(...)` | Call `WriteLine`, **no Receiver pin**; the qualifier text is kept on the node (`Node.Qualifier`) and shown as "Receiver is Console" | Static |
| `Twice(5)` resolving to a static function of the type, a base or a global block | Call `Twice`, no Receiver pin, no qualifier | Static |
| `base.Foo()` | Call `Foo`, Receiver **wired from a Base node** (`NodeKind.Base`, writes `base`; see [Classes-and-Members.md](Classes-and-Members.md#the-base-node-base)) | Instance |
| `Unknown.Foo()`, `Foo()` that resolves to nothing | the text stays in the Receiver pin (`Unknown`), or no Receiver | Unresolved |
| `mOnTick()` (a delegate in a field, parameter or local) | Call `mOnTick` without Receiver | Unresolved |

`Node.Binding` is `Static`, `Instance` or `Unresolved`; `Node.OwnerType` is the declaring type
(`Base` for `Hit` declared in `Base` and called from `Enemy`; an extension's type for an extension
member); `Node.Qualifier` is the exact text before the dot of a static call. Every shape writes back
byte for byte: `Foo()` (unconnected Receiver), `this.Foo()` (This wired), `obj.Foo()` (wire),
`Console.Foo()` (qualifier).

### How the builder decides

`GraphBuilder.FillCall`:

* **`X.Foo(...)`**: `X` is classified (`ClassifyTarget`): `this` -> This node; a name chain whose root
  is a local, parameter, field, folded temp or out variable -> a **value** (wired); a name chain that
  resolves as a type (the `TypeService`, else the project index, else the built-in `Console` / `Math` /
  `Runtime`) -> **static**; `base` -> a Base node ([Classes-and-Members.md](Classes-and-Members.md)); anything unknown -> text in the Receiver pin, as before; any
  other expression -> a value. Locals win over types, as in Beef.
* **`Foo(...)`**: a name that is a variable is a delegate call (unresolved). Otherwise the type's
  own declarations decide (`OwnBinding`): static or member when every overload that takes that many
  arguments agrees, unresolved when they disagree. Without an own declaration the resolver decides
  (`TypeService.ResolveCall` walks bases, global `static { }` blocks and `using static`); a member
  function found that way **in a static context** stays unresolved: only the type's own
  declarations are trusted to say "there is no this", so code that compiles is never reported.
* The pins: Receiver first (member calls), then `arg0..argN` in order; the result pin as before.

Methods of a `static` type and of a `static { }` block are static. `Graph.SelfType` is the type the
method belongs to, `Graph.StaticContext` says whether there is a `this` (static method, static type,
or no type at all).

### The This node

`NodeKind.This` is a pure node with one output (`result`, typed with the graph's type), drawn like
a variable pill, titled "This". It writes `this`. The node menu offers it as **Get a reference to
this** (only where there is a `this`), first in the list when you drag off a Receiver pin. Wiring This
into a Receiver writes `this.Foo()`; leaving the pin unconnected writes `Foo()`. That is what keeps
both spellings exact.

### Node Library calls

A function of a Node Library (`static class Tools`, see [Classes-and-Members.md](Classes-and-Members.md#node-libraries-and-global-variables))
is a static function: `Tools.Twice(3)` reads as a Call `Twice` with **no Receiver pin** and
written `Tools.Twice(...)`; the Node menu offers it under **Libraries > Tools**. Inside the library its
own functions are called as plain `Twice(3)` (no Receiver). A function Sheet of a library has no
`this`: a This node there is an error, `this` read from code a warning (GraphValidator.CheckLibraryRules;
`Graph.InLibrary`). Static variables (of a library or a class) are read and written with Get / Set
nodes under **Globals > Owner**, written `Owner.Field`.

## ref arguments

`Foo(ref x)` is an input pin with `Pin.Mode == .Ref`, wired from `x` (a Get node) or holding the text
`x`. The generator writes `ref <value>`. GraphValidator refuses a ref argument whose source is not
assignable: a variable, field, parameter, array element, out variable, dereference (`*p`), or a
function returning `ref`. Text typed into the pin must be a plain name or member chain.

## out parameters: output pins

Every `out` parameter is an **output pin** of the call, named `arg<i>` like the inputs (so
`Node.GetArgPins` lists the arguments in order) and labelled with the parameter name. Readers of the
value wire from it, like any other output. The call keeps its flow pins.

### What Beef 0.43.6 accepts

Checked with BeefBuild on this machine (2026-10-10):

| Spelling | 0.43.6 |
|---|---|
| `Get(1, var x)`, `Get(1, let x)`: an out variable declared in the argument (no `out` keyword) | yes; in an `if` condition `x` is still visible after the `if`; in a `while` condition it is visible in the loop only |
| `Get(1, ?)`: discard | yes |
| `int x; Get(1, out x);` / `Get(1, out mField)` | yes |
| `Get(1, out let x)`, `Get(1, out var x)`, `Get(1, out int x)` | **no** ("Expected expression") |
| `Get(1, out _)` | **no** ("Identifier not found") |
| `Get(1, int x)` | **no** ("Only 'ref' or 'var' variables can be declared in method arguments") |

### How an out pin is spelled (`Pin.Form`)

| Form | Code | Comes from |
|---|---|---|
| `Inline` | `var name` / `let name` (or `out let name` with `Pin.OutKeyword`, read from newer code) | the default for a read pin; `var a` / `let a` / `out let a` in code |
| `Discard` | `?` | a new pin nothing reads; `?` in code |
| `Declared` | `T name;` on the line before the statement, `out name` at the call (or `T name = default;` when hoisted) | a value read after its block; a `T a;` line directly before `Foo(out a)` in code |
| `DeclaredRef` | `T name = default;` before the statement, `ref name` at the call | a `ref` parameter tagged `[Pin(Out=true)]` |
| `Existing` | `out b` | `out b` into a variable that exists anyway (the pin is a "writes `b`" marker, readers of `b` read the variable itself) |

The generator (`CodeGen.AnalyzeOuts`, after the planning pass) chooses per pin:

* **Nothing reads it**: `?` for a pin the generator spells (`Pin.OutAuto`, every new pin); a pin read
  from code keeps its spelling (`var a` stays, never silently becomes `?`), and a name that is also
  used where no wire shows it (a Code node, an interpolated string: `Pin.OutKeepName`) is never
  dropped.
* **Read in the call's statement, its bodies, or later in its block**: `var name` in the argument.
  A `var` in a loop condition lives in the loop only, so a read after the loop declares `T name;`
  right before the loop and writes `out name`.
* **Read after the block the call runs in**: `T name = default;` hoisted before the statement of the
  innermost block that holds the call and every reader (exactly like a hoisted call result; on a path
  where the call did not run the value is `default`), `out name` at the call. Needs the type; refused
  when it is unknown. Not possible across a Sequence (refused, as for call results).
* **Read where the call has not run** (the other branch, earlier, a do-while body reading its own
  condition's out value): refused, on the reader and on the call.

Names are the parameter name made unique (`value`, `value2`), chosen when the pin is made (the
factory) or first written, stored on the pin (`Pin.OutName`) and kept from commit to commit. Names
read from code are never changed. After writing, the pin records the spelling the code now has, so
the live graph equals a fresh read of the file.

### Reading out arguments back

`GraphBuilder.BuildArg`:

* `var a` / `let a` / `out let a` (the parser keeps them as text): an `Inline` pin; `a` becomes an
  **out variable in scope** for the rest of the block (and nested blocks): every read of `a` that is
  a plain name or `a.b` is wired from the pin (`TryLinkTemp`, `ChainOutVar`). Assignments to `a`
  stay text.
* `?`: a `Discard` pin.
* `out b`: an `Existing` pin (`OutName` = the text of `b`).
* `T a;` (or `T a = default;` for a `ref` to a `[Pin(Out=true)]` parameter) directly before the
  statement that passes `out a`, possibly with `let __vN` shared-value lines in between: folded into a
  `Declared` pin with the line's exact text (`Pin.OutDeclRaw`), so an untouched statement writes the
  line back byte for byte. The fold is checked like the other folds: the declarations must be the
  out pins of that statement's own header, in the order the generator writes them
  (`CodeGen.CollectOutPins`), and every other use of `a` must have become a wire. Otherwise the line
  stays an ordinary Local Variable and the pin is `Existing` (the graph is rebuilt with the name in
  the no-fold set, like temps).

### Pure calls with out pins

A pure call (or an impure one outside the flow) is written where its value is read, so its out
variables are declared there: `if (TryGet(2, var v))`, readers in the body or after it. When only its
out pins are read, it runs once as a statement of its own before the first reader
(`TryGet(7, var value);`), which reads back as an ordinary call statement.

## GraphValidator

`GraphValidator.Validate(graph, emittedNodes)` runs as the first step of `CodeGen.GenerateBody`, so
on every commit (every edit) and before anything is written. In the editor it also runs once when a
graph is first shown (`EditorApp.EnsureChecked`: a dry generation, nothing written), so problems in
code as read are visible before the first edit. Only nodes that produce code are checked (unconnected
nodes are not).

Errors go to `Graph.Errors` (the commit is refused, exactly like the generator's refusals); warnings
go to `Graph.Warnings` (shown, never blocking).

| Check | Message (on the node) | Severity |
|---|---|---|
| Member call, Receiver unconnected, no `this` (static method, static type, no type) | `Receiver must be a Player: this function is static, so there is no this.` | error |
| Member call, Receiver unconnected, `this` is not the owner and does not derive from it | `Receiver must be a Player; this is an Enemy.` | error |
| Member call, a wire made in the editor brings a value of a known, unrelated type | `Receiver must be a Player; the wire brings an Enemy.` | error |
| A call argument (or a Set / Branch / loop / Switch / operator / cast / index input) with neither a wire nor a value | `'amount' needs a value: connect a wire or type one in.` | error |
| A `ref` argument from something not assignable | `ref needs a variable: 'total' is passed by reference, so connect a variable, field or array element to it.` | error |
| A wire made in the editor whose types change kind (bool <-> number, number <-> text, class <-> unrelated known class) | `'amount' takes int, but the wire brings bool: ...` | error |
| The same with narrowing, sign, pointer level or a copy (`StringView` -> `String`), or types that are only guessed | same text | warning |
| A value typed into a new node that changes kind (`true` into an `int`; `null` into a declared struct) | `'amount' takes int, but holds true: ...` | error |
| An overload picked between equally good ones (edited nodes) | `Several overloads of 'Pick' fit these arguments equally well. ...` | warning |
| A new call whose function is not known | `'Foo' is not a known function here. ...` | warning |

Never an error: anything the resolver could not resolve (unknown owner, unknown type of `this`, unknown
types), integer constants into any number type (Beef converts constants), and the types of wires read
from code (`Link.Parsed`; the compiler accepted them). The type of `this` is compared through `ITypeHierarchy`
(`TypeRules.Hierarchy`, bases and interfaces); without a resolver the static-context rule still
applies (it needs no types) and the "this is an X" rule does not.

The generator's own warnings that belong to a node ("not connected to the execution flow; it is
called where its value is used") are added to `Graph.Warnings` too.

### In the editor

* **Errors**: the node's header turns red, a red outline and an **ERROR!** badge with the message
  under the node; for a Receiver error the Receiver pin and its "this" turn red. The node tooltip starts
  with the error. The Output Log gets one entry per problem (category `Graph`, with the file and the
  node's line; not repeated while the same problems stay), and the status bar shows
  `Not written - <node>: <message>`.
* **Warnings**: a yellow outline and a **WARNING** badge.
* An unconnected member-call Receiver reads **this** in grey (no text field: there is nothing to type);
  a static call has no Receiver pin and the subtitle "Receiver is Console"; a member call's subtitle
  names the declaring class ("Receiver is Base"). Pin tooltips explain `ref`, `out` (its variable, `?`,
  or "writes b") and this. Properties has a **Call** category: binding, Receiver is, each out variable's
  spelling, the node's error or warning.
* **Saving refuses** while a built graph has errors (`SaveOutcome.GraphErrors`): the graph's edits
  are not in the text, so saving would store the old text as if they were saved. Compile saves first,
  so it stops too. See [Files-and-Safety.md](Files-and-Safety.md).

## Overload ties (6.6)

When `TypeService.ResolveCall` (or the type's own overloads) picks between candidates that score
the same on argument types that are **all known**, the node gets `Node.Ambiguous` and, once edited,
the warning above. The dropdown to pick an overload (writing a cast) is not done yet.

## Menu-made nodes

The factory makes exactly the node the code reads back as:

```beef
NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", flow, names, types, "void");   // Console.WriteLine(...)
NodeFactory.StaticCall(g, "Twice", "", "Base", flow, names, types, "int");                   // Twice(...) in Base or a subclass
NodeFactory.MemberCall(g, "Hit", "Base", flow, names, types, "void");                        // Hit(...) with this, or wire Receiver
NodeFactory.MemberCall(g, "TryGet", "Enemy", flow, names, types, "bool", mods);              // mods: "", "out", "ref"
NodeFactory.This(g, "Enemy");                                                                // this
```

`NodeFactory.Call` (the older entry point) still works: a dotted name without a qualifier is a static
call, `hasTarget` makes a member call with that text in the Receiver, otherwise an unresolved call.
Catalog entries (`FromSpec`) are static or member calls by the entry's `IsStatic`, with out pins
from `out` parameters and from `ref` parameters tagged `[Pin(Out=true)]`. The editor's own-class
entries (`MenuEntryKind.CallMethod` with `OnType` / `Static`), Outline drops and typed names
(`obj.Foo` on a variable wires `obj`) go through the same calls.

## Limits

* Pasting a node with an inline (`var a`) or `out b` out pin keeps the name; two pins declaring the
  same `var a` in one block do not compile. Generator-named pins (`OutAuto`) are renamed.
* A hoisted out declaration, like a hoisted call result, reads back as a local variable (one of
  the function's Local Variables when it is at the top of the body, else a Local Variable node) and
  `out name` (the code is right, the node shape differs).
* A pure call read only through its out pins is written as a statement and reads back as an impure
  call statement.
* The ambiguity marker has no overload dropdown yet.
* A `ref` parameter becomes an output pin only with `[Pin(Out=true)]` (or as an `out` parameter);
  untagged it is a `ref` input. UMP's SDK generator tags the parameters its functions only write
  (emitter v5).
