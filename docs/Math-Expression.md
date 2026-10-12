---
audience: user
title: Math Expression
summary: Type a formula on one node; every name in it becomes an input, the code is the formula itself.
order: 7
---

# Math Expression

A **Math Expression** node holds a formula you type, such as `Math.Sqrt(x * x + y * y) * scale`.
Every name in it becomes an input pin named after it, and the value is its one **Result**. One
node replaces the chain of operator nodes the same formula would need.

```beef
public static float Length(int x, float y, float scale)
{
	return Math.Sqrt(x * x + y * y) * scale;
}
```

The code is the formula with the values in place: nothing else is written. A value that is an
operation is put in parentheses (`(x + 1) * (x + 1) + y`), so the formula means what it says.

## Making one

* **Node menu**: **Math | Operators > Math Expression** (search `math` or `expression`). Opened from
  a pin it is wired to that pin; it starts as `a + b`.
* **Typing the formula**: in the field on the node, or in **Properties > Expression**. It is taken
  when you press Enter or click away.

## The inputs

* Every name that is not a function, a type or a member read becomes one input: `a * a + b` has
  the inputs `a` and `b` (a name used twice is one input).
* Not inputs: what follows a `.` (`p.X`, `Math.PI_f`), a type in front of a `.` (`Math.Sqrt`,
  `int.MaxValue`), a function called by name (`Twice(v)`: `v` is an input, `Twice` is not), casts
  (`(float)n`) and literals.
* Wire a value into an input, or type one in its field. Changing the formula keeps the wires and
  values of the names that stay; a name that is gone takes its input with it.

## What it gives

The Result type is worked out where Beef's rules make it certain:

| Formula | Result |
|---|---|
| int with int (`+ - * / %`) | int |
| an int with a float, or float with float | float |
| anything with a double | double |
| comparisons, `&&`, `||`, `!` | bool |
| `(float)x`, `(double)x` | the cast type |
| `Math.Sqrt`, `Math.Pow`, `Math.Sin`, ... of a float / a double | float / double |
| `Math.Min`, `Math.Max`, `Math.Abs`, `Math.Clamp` | the type of the arguments |
| `Math.PI_f` / `Math.PI_d` | float / double |

When the formula does not tell (an input without a wire or a typed value, `Math.Sqrt` of a
whole number, which fits the float and the double version alike, small integer types), choose
the **Result Type** in Properties. A type is never assumed.

## When something is wrong

The node turns red with a plain message, and nothing is written until it is fixed:

* a formula that is not one Beef expression (`a +`, a `;`, an assignment, `++`, `new`): the field
  turns red while you type and the text is not taken;
* an input without a wire or a value: `'r' needs a value: connect a wire to it or type one in.`;
* a Result type that can't be told and was not chosen.

## Saving and reading back

The file holds only the plain formula. The `.vblayout` file next to it remembers which
expressions are Math Expressions (the formula as typed and the chosen Result type), so the node
comes back when the file is opened again, with its inputs wired to what the code reads.

Without the `.vblayout` file, or after the formula was changed by hand in the code, the code is
still ordinary Beef and is read as the usual value nodes.
