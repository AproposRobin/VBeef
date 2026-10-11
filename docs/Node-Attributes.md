---
audience: user
title: Node attributes
summary: Tag your own Beef code with attributes to choose which functions and variables become nodes.
order: 8
---

# Node attributes

You can choose which parts of your Beef code VisualBeef offers as nodes, and how they look, by
adding attributes to it. They are ordinary Beef attributes with no runtime cost.

The attributes are in the small `VisualBeefMeta` library (namespace `VisualBeef`). It has no
dependencies besides corlib. They are ordinary Beef attributes and cost nothing at runtime, so
your code builds the same with or without VisualBeef. VisualBeef reads them from the source text,
so it doesn't need the compiler.

## Setup

Add the library to your workspace and your project:

```toml
# BeefSpace.toml
[Projects]
VisualBeefMeta = {Path = "path/to/VisualBeef/VisualBeefMeta"}

# BeefProj.toml of your project
[Dependencies]
corlib = "*"
VisualBeefMeta = "*"
```

Then add `using VisualBeef;` to the files that use the attributes.

VisualBeef recognises an attribute by its simple name (`Node`, `NodeAttribute`, `VisualBeef.Node`
and `Some.Other.NodeAttribute` are all `Node`) and reads the fields below. A library that should
not depend on `VisualBeefMeta` may therefore declare its own attribute types with these names and
fields: UnrealUMP's game SDKs do (`UnrealUMP.Unreal.NodeMeta`). Do not import both sets into one
file, or the names become ambiguous for the compiler.

## What becomes a node

| Your code | What the node menu offers |
|---|---|
| A project or library with **no** VisualBeef attributes | Every `public` member (`internal` ones too, inside your own project). Categories are `Namespace\|Type`. |
| A project or library that uses **any** VisualBeef attribute | Only members tagged `[Node]`, `[Pure]`, `[Expose]` or `[Conversion]`, plus the `public static` functions of `[NodeLibrary]` classes. |
| The class whose graph is open | All of its own functions and variables, private ones included. |
| Anything tagged `[NodeHidden]` (a member, or a whole type) | Nothing. |

A library such as corlib uses no attributes, so all of its public API is offered.

Tooltips come from the attribute when it sets one. Otherwise they come from the `///` doc
comment above the member: plain text, or the `<summary>` / `<param name="x">` form. A pin's
default value comes from the Beef default parameter value (`float t = 0.5f`).

## The attributes

### `[Node]`: offer a function as a node

```beef
[Node(Category="Gameplay|Health", DisplayName="Apply Damage", Keywords="hurt hit", Tooltip="Subtracts health.")]
public void ApplyDamage(int amount) { ... }

[Node("Math|Vector")]            // the category can be the first argument
public static Vector3 Up() => .(0, 1, 0);
```

| Field | Meaning | Default |
|---|---|---|
| `Category` | Menu path. `\|` separates submenus. | `[NodeLibrary]` category, else `Namespace\|Type` |
| `DisplayName` | Title in the menu | The name split into words (`ApplyDamage` → "Apply Damage") |
| `Keywords` | Extra search words | none |
| `Tooltip` | Hover text | The `///` doc comment |
| `Pure` | No flow pins (same as `[Pure]`) | `false` |
| `Compact`, `CompactTitle` | Draw as a small operator-style node | `false` |
| `Advanced` | Ranked last in search results | `false` |

### `[Pure]`: a node without flow pins

Use it for functions that only compute a value.

```beef
[Pure] public bool IsAlive() => Health > 0;
[Pure("Math")] public static float Square(float x) => x * x;
```

### `[Expose]`: a variable in the palette

Use it on fields and properties.

```beef
[Expose(Category="Stats", Min=0, Max=100, Tooltip="Hit points")]
public int Health = 100;

[Expose(ReadOnly=true)]          // Get only
public static int MaxPlayers = 4;
```

| Field | Meaning |
|---|---|
| `Category`, `DisplayName`, `Tooltip` | As for `[Node]` |
| `ReadOnly` | Only a Get node is offered |
| `Min`, `Max` | Slider range for the Properties panel (recorded; the slider is the shell's job) |

Static fields get a Get and a Set node. Instance fields get a Get node that takes the object on
its Receiver pin. A Set node writes a variable by name, so instance fields are set from their own
class's graphs.

### `[Pin]`: per-parameter label, tooltip and default

```beef
public static float Lerp(float a, float b, [Pin(Name="Alpha", Tooltip="0 to 1")] float t = 0.5f) => ...;
public void Fire([Pin(Default="1")] int count) { ... }   // when the signature can't have a default
```

| Field | Meaning |
|---|---|
| `Name` | The pin's label. The code keeps the parameter name. Without it the label is the parameter name, without a leading `@`. |
| `Tooltip` | Hover text. Default: the `<param>` doc comment. |
| `Default` | The value placed in the unconnected pin of a new node. Default: the Beef default value. |
| `Advanced` | Recorded for a future "show advanced pins" arrow |
| `Out` | On a `ref` parameter: the function only writes it (an out parameter of a game function passed by reference). The node shows it as an **output pin**, like an `out` parameter, and the code passes a fresh variable: `T name = default; Foo(ref name);` (see [Calls-and-Receivers.md](Calls-and-Receivers.md#out-parameters-output-pins)) |

`out` parameters are output pins without any attribute.

### `[NodeLibrary]`: a function library class

Every `public static` function of the class becomes a node. Non-void functions without
`ref`/`out` parameters are pure by default. Void functions have flow pins.

```beef
[NodeLibrary(Category="Math|Vector")]
public static class VectorLib
{
	/// Dot product.
	public static float Dot(Vector3 a, Vector3 b) => ...;           // pure, "Math|Vector"
	public static void Normalize(ref Vector3 v) { ... }             // flow pins
	[Node(Category="Math|Interpolation")]                           // overrides the category,
	public static Vector3 Lerp(Vector3 a, Vector3 b, float t) => ...; // and has flow pins
}
```

### `[NodeHidden]`: keep something out of the menu

```beef
[NodeHidden] public static void InternalThunk() { }

[NodeHidden] static class Internals { ... }   // hides every member
```

### `[Conversion]`: an automatic conversion

This marks a one-argument function that converts its parameter's type into its return type.
The catalog records it and flags it in the menu. Inserting it automatically when you drop a wire
between those two types is planned.

```beef
[Conversion] public static String ToText(Vector3 v) => ...;
```

### `[ExpandEnumAsFlow]`: one flow output per case

(Formerly `[ExpandEnumAsExecs]`; the old name is still read and means the same.)

This applies to an enum or `Result` value. `Param` names the parameter, or `"return"` for the
return value. The catalog records the cases (`Ok`/`Err` for `Result<T>`, the enum's cases
otherwise). Until the Switch node lands, the node is created as an ordinary call.

```beef
[Node, ExpandEnumAsFlow("return")]
public Result<int> Parse(StringView s) { ... }
```

### `[ExposeType]`: a type for variables and pins

(Formerly `[BlueprintType]`; the old name is still read and means the same.)

This marks a class, struct, enum or interface that is meant to be used as a variable type.
`MakeBreak = true` asks for Make/Break nodes on a struct. Both are recorded for the type picker
and the struct nodes.

```beef
[ExposeType] public struct DamageInfo { public int Amount; public bool Critical; }
```

## Overloads

Overloads stay separate entries. When two share a name, their menu labels show the parameter
types: "Clamp (int, int, int)" and "Clamp (float, float, float)". A call that is already in the
code is matched first by its number of arguments (default and `params` arguments count), then by
the types of its arguments.

## Full example

`VisualBeefTests/src/MetaSample.bf` uses every attribute and is compiled with the tests, so the
examples on this page are known to build.
