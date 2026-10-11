---
audience: user
title: Switch and flow nodes
summary: Switch, Sequence, loops, Return and the state macros, with the code each one writes.
order: 7
---

# Switch and flow nodes

Everything here is plain Beef. There is no hidden format: each node is written as ordinary
statements, and the same statements are recognised again when the file is read. Delete the
`.vblayout` file or edit the code by hand and you still have the same nodes. Code that only
*looks* similar (a different field name, a missing line) is not a macro; it stays a Branch,
Set or Code node.

Calls (Receiver / this / static, the This node, out and ref pins) are described in
[Calls-and-Receivers.md](Calls-and-Receivers.md); `new` / `scope`, `delete`, `defer`, `using` and
`if (x case .Ok(let v))` in [Lifetime-Nodes.md](Lifetime-Nodes.md).

Where it lives: the nodes are `NodeKind.Switch` and `NodeKind.Flow` (`Graph.bf`), their pins
and naming are in `FlowMacros.bf`, recognition is in `GraphBuilder.bf`, code is written by
`CodeGen.bf`, and the node menu / Properties panel are in `VisualBeefEditor`. Every node follows the same rule: only edited statements are
regenerated, and nothing is written that would change behaviour.

## Switch

```beef
switch (x)
{
case 1:
	Console.WriteLine("one");
case 2, 3:
	Console.WriteLine("two or three");
default:
	Console.WriteLine("other");
}
Console.WriteLine("after");
```

| Pin | Meaning |
|---|---|
| flow in | |
| `Value` (data in) | the `switch (value)` expression |
| one flow out per case | labelled with the case text: `1`, `2, 3`, `"name"`, `.Idle` |
| `Default` | the `default:` body |
| `Completed` | the code after the switch |

- **Reading code.** Every `case` / `default` clause becomes an output, and the statements of
  its body hang off it. An empty `case 1:` is an empty arm (Beef does not fall through).
  Case text is shown exactly as written, so `.Idle` stays `.Idle` and `Mode.Idle` stays
  `Mode.Idle`.
- **Over a Result**: `switch (r) { case .Ok: ... case .Err: ... }` is a Switch like any enum.
  A **payload case** `case .Ok(let v):` / `case .Err(var e):` (one binding) is a Switch case too,
  with a **payload pin** named after the binding (`case0.payload`, label `v`, typed `T` / `E` of
  `Result<T, E>`): readers inside that case are wired from it (an out-style pin, like the Result
  node's Value), and the label is written as it reads, binding included. The `if (r case .Ok(let v))`
  form is the **Result: match** node ([Lifetime-Nodes.md](Lifetime-Nodes.md#result-match)).
- **Stays a Code node** (the Properties panel says why): `fallthrough` anywhere in the switch, `when`
  guards, range cases (`1...5`), tuple / multi-binding patterns (`case (1, 2)`, `.Pair(let a, let b)`),
  code before the first case, two `default`s, preprocessor lines inside, a header that is not
  `switch (value) { ... }`.
- **Writing.** Unchanged switches are copied. An edited switch keeps the header, the brace
  style, each clause's leading comments, the label spacing and trailing comment of every clause
  that still reads the same, and the indentation of the `case` lines. A new clause or a
  new switch uses the layout of the other switches in the method (cases level with the braces by
  default). `default:` is written when it has a body, was in the source, or "write `default:`
  even when empty" is ticked.
- **Several arms into one node.** If every output including Default leads to the same node,
  that node is written once after the switch. If
  Default is not wired the merge is refused with "Two execution wires lead into this node";
  wire Default as well, or connect the arms to *Completed* instead.
- **Properties.** The case list: edit each case's text, move it up or down, remove it, add one
  (inserted before Default), and the "write `default:` even when empty" option.
- **Node menu** (Flow Control): *Switch on Int*, *Switch on String*, *Switch on Enum*
  (no cases; add them in Properties) and *Switch on `<Enum>`* for every simple enum in the current
  file, with one case per value.
- **Limits.** Pins are named `case0`, `case1`, ... in order; the names change when cases are
  moved or removed (the node is the same node). `break;` in a case is a Break node and leaves
  the switch (Beef's rule): the generator warns when that is inside a loop.

## Sequence

```beef
// vb:sequence
{
	Console.WriteLine("a");
}
{
	Console.WriteLine("b");
}
```

Runs each *Then n* output in order, then continues with *Completed*. The marker comment is
what makes the blocks a Sequence; the plain `{ }` blocks right after the marked one are its
other outputs (a block with its own marker starts another Sequence). Each output is its own
block, so a local declared (or a call result computed) in one output is not visible in
another output or after the Sequence: such a graph is refused with the reason on the node.
Store the value in a Local Variable before the Sequence instead.
Properties: add / remove outputs. A Sequence with one output is just a nested block.

## State macros

State lives in a field of the enclosing type, named with a reserved prefix. The prefix is
what identifies the shape; the number is only there to keep names apart.

| Node | Prefix | Field type | Beef |
|---|---|---|---|
| Do Once | `__doOnce_` | `bool` | `if (!F) { F = true; <Once> }` |
| Do N | `__doN_` | `int` | `if (F < n) { F++; <Do> }` |
| Flip Flop | `__flipFlop_` | `bool` | `if (!F) { F = true; <A> } else { F = false; <B> }` |
| Gate (starts open) | `__gateClosed_` | `bool` | `if (!F) { <Exit> }` |
| Gate (starts closed) | `__gateOpen_` | `bool` | `if (F) { <Exit> }` |
| Multi Gate | `__multiGate_` | `int` | `if (F == 0) { F = 1; <Out 0> } else if (F == 1) { F = 2; <Out 1> } ...` |

Every one has *Completed* (the code after it, always runs). Their state nodes are plain
assignments to the same field:

| Node | Beef |
|---|---|
| Reset Do Once | `F = false;` |
| Reset Do N, Reset Multi Gate | `F = 0;` |
| Open Gate | `F = true;` (starts-closed gate) / `F = false;` (starts-open gate) |
| Close Gate | the opposite |
| Toggle Gate | `F = !F;` |

A Reset / Open / Close / Toggle node names its state field in Properties (a list of the macros of
that kind in this graph and in the type). A plain `F = false;` statement with such a field
name is read as the state node, and the other way round.

Semantics:

- **Do Once** runs *Once* the first time it is reached, then never, until Reset.
- **Do N** runs *Do* the first N times (N is a value pin; it can be wired). The *Counter*
  output is the field, so inside *Do* it counts 1, 2, ... N.
- **Flip Flop** runs A, then B, then A... *Is A* is the field: true while A runs, false while B
  runs, and keeps that value afterwards.
- **Gate** runs *Exit* only while open. "Start closed" in Properties picks the prefix
  (`__gateOpen_` starts closed because a `bool` field starts `false`). Open / Close / Toggle
  change it from anywhere in the type.
- **Multi Gate** runs the next *Out* each call. After the last one it runs nothing, or starts
  over when "Loop" is ticked (the last arm then sets the field back to 0). "Is Random" and
  "Start Index" are not offered.

How the state field is handled when the graph is written:

- A new node gets a free name (`__doOnce_1`, `_2`, ...), avoiding the fields the type already
  has and the other macros in the graph. The field (`private bool __doOnce_1;`, or
  `private static ...` when the method is static) is added to the type in the same commit,
  after the existing fields. Nothing is added for macros that were only read from the source
  and not edited.
- Copies of a node (paste) get a name of their own the next time the graph is written, so a
  copy never shares state with the original.
- A macro whose name has the wrong prefix, or a second macro with a name already used, is
  given a fresh name.
- Deleting a macro node leaves its field in the type (it may still be read elsewhere).

Limits:

- A macro that is recognised only by shape and prefix: change the shape by hand (a different
  condition, an extra statement before the bookkeeping line) and it reads back as a Branch and
  Set nodes. Code written for them keeps working.
- State is per object (or static for static methods). It is not per call, per thread, or saved.
  A `struct` method that mutates a field needs `mut`; the editor does not add it.
- *Delay*, *Retriggerable Delay* and timers are not offered: they need a scheduler the language
  does not have. They would belong to a host library (a `Timer` / `Delay` call node), not to a
  macro.
- The *Counter* / *Is A* outputs are read as the field name; after the file is re-read the use
  shows as a Get node of that field (same code, different node).

## For Loop

A For Loop read from a counting header, `for (int i = 0; i < count; i++)` or Beef's short
`for (int i < count)`, has a **Counter** output pin named after the loop variable (`i`, typed
`int` or the header's whole-number type) and **Start** / **Count** input pins (no Start for the
short form: it starts at 0). Printing or using the counter is a wire from that pin, written as
`i`; Count can be a literal on the pin or a wire (it is read on every pass, like a While
condition). A new For Loop from the Node menu is `for (int i = 0; i < 10; i++)`. Properties
edits the **Counter Name** and the **Counter Type** (a chooser of whole-number types); the header
is written from the pins, and an unchanged header keeps its exact text (spacing such as
`int  k=1 ;k<10;k++` included). Any other header (`<=`, `++i`, `i += 2`, two variables, `(;;)`)
stays the editable **Loop Header** text it was. As with For Each, a read of the counter in the
body comes back from the file as a Get node of `i` (same code).

## Return

A Return placed from the Node menu in a function that returns a value starts with that type's
default value on its Return Value pin, so a fresh function compiles: `false` for `bool`, `0` for
numbers, `null` for classes, interfaces, delegates, arrays, pointers and nullables, `default` for
structs, enums, characters and types the editor does not know. A `ref` return starts empty (it
needs a variable).

## Loops with Break

*For Each Loop with Break* and *For Loop with Break* in the node menu create the loop with
`if (false) break;` already in its body (a Branch and a Break node). Change the condition and
wire more nodes in as usual. There is no separate "Break" input pin on loops: the Break node
is the loop's break, and several of them can be wired anywhere in the body. Inside a
`switch` case a `break;` leaves the switch, not the loop (see Switch above).

`while`, `do while`, `for` and `for (let x in xs)` are the existing loop nodes.

## Defer, Using and Result

These three are flow nodes with bodies too ([Lifetime-Nodes.md](Lifetime-Nodes.md)):

| Node | Outputs | Beef |
|---|---|---|
| Defer | *Deferred*, *Completed* | `defer <statement>` / `defer { ... }` (`defer::`, `defer:label`) |
| Using | *Body*, *Completed* (and *variable* with a declaration) | `using (value) { ... }` / `using (let x = value) { ... }` |
| Result: match | *Ok*, *Err*, *Completed*, *Value* / *Error* (the payload) | `if (value case .Ok(let v)) { ... } else { ... }` |

- Each body is its own block, like a loop body. A node wired both into a Defer body and after it
  is refused ("Two execution wires..."), as for any body.
- Deferred code runs when the enclosing block ends, the last Defer first, so a Defer may only read
  values that exist before it; `return` and jumps out of a Defer body are refused, and a Defer
  whose body reads `x` before a later Defer deletes it gets a warning.
- A Result node merges like a Branch (both arms into one node: written once after the `if`), and
  in an else arm it continues an `else if` chain.
- Editing a body keeps the header and brace style (`defer {`, `using(lock.Enter()) {`); a second
  statement in a one-line `defer delete x;` turns it into a block.

## Scope, repeat and statement attributes

| Node | Pins | Code |
|---|---|---|
| Scope | *Body*, *Completed* | a nested block `{ ... }`: its locals and `scope` values end with it |
| Do While Loop spelled `repeat` | as Do While | `repeat { ... } while (x);` (Node.Alloc = `repeat`; `do` otherwise) |

* A nested block used to be a Code node; it is a **Scope** node now (54 in the UMP sources). The
  block is a block for the generator's scope analysis, so `scope` lifetimes and locals declared in
  it follow the same rules as in an `if` arm.
* **Statement attributes** (`[ConstSkip] { ... }`, `[IgnoreErrors] { ... }`, an attribute in front
  of a call / local / return / delete) are kept on the node (Node.Attributes, the text with the
  gap that followed it) and written back in front of the statement. On a Scope node Properties
  edits them; Beef 0.43.6 accepts `[ConstSkip]` / `[IgnoreErrors]` on blocks only.
