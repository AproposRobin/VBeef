using System;
using System.Collections;
using VisualBeef.Catalog;

namespace VisualBeef.Graph
{
	/// A variable (a member variable, a local variable or a parameter) dropped on a pin of a Sheet:
	/// on an input it becomes a Get wired into the pin, on an output a Set fed by the pin and placed
	/// in the flow after the pin's node. A drop the types refuse is refused with the reason, before
	/// anything changes (docs/Editor-UI.md#dragging-onto-pins).
	static class VariableDrop
	{
		/// Whether a variable of `type` can be dropped on `pin`. False with the reason (the same words
		/// a refused wire gets) when it cannot. `ts` lets a call's other overload take the value (an
		/// int dropped on a text pin of Console.WriteLine), as a wire does.
		public static bool Fits(Graph g, Pin pin, StringView type, TypeService ts, String outWhy)
		{
			if (pin == null || g == null)
				return false;
			if (g.ReadOnly)
			{
				outWhy?.Set("This Sheet cannot be edited.");
				return false;
			}
			if (pin.Kind != .Data)
			{
				outWhy?.Set("A variable is a value: drop it on a data pin, not on a flow pin");
				return false;
			}
			if (pin.IsInput && pin.Owner != null && pin.Owner.Kind == .Set && pin.Name == "target")
			{
				outWhy?.Set("The Variable pin names what is set: drop the variable on the Value pin, or onto the Sheet for a Set of it");
				return false;
			}
			// A stand-in for the variable's pin: the output of its Get, or the input of its Set.
			Pin stand = scope .();
			stand.Kind = .Data;
			stand.IsInput = !pin.IsInput;
			stand.TypeName.Set(type);
			String why = scope .();
			if (Graph.CanConnectTyped(stand, pin, why))
				return true;
			if (pin.IsInput && ts != null && CallOverloads.CouldTake(g, pin, type, ts))
				return true;
			outWhy?.Set(why);
			return false;
		}

		/// Places the node for a variable dropped on `pin` and wires it: a Get into an input pin
		/// (an existing wire there is replaced, as a dragged wire replaces it), or a Set fed by an
		/// output pin and spliced into the flow (see SpliceSet). Null with the reason when `Fits`
		/// refuses; then nothing changed. The caller takes the undo step around it and positions
		/// the node.
		public static Node Place(Graph g, Pin pin, StringView name, StringView type, TypeService ts, String outWhy)
		{
			if (!Fits(g, pin, type, ts, outWhy))
				return null;
			if (pin.IsInput)
			{
				let get = NodeFactory.Get(g, name, type);
				g.Connect(get.Result, pin);
				get.X = pin.Owner.X - 220;
				get.Y = pin.Owner.Y + 20;
				get.HasPos = true;
				return get;
			}
			let set = NodeFactory.Set(g, name, type);
			let value = set.FindInput("value");
			if (value != null)
				g.Connect(pin, value);
			set.X = pin.Owner.X + 260;
			set.Y = pin.Owner.Y;
			set.HasPos = true;
			SpliceSet(g, set, pin);
			return set;
		}

		/// Puts `set` (a Set fed by `pin`) in the flow: after the pin's node when that node runs in
		/// the flow (after its Body for a loop's Element / Counter), else before the first statement
		/// that uses the pin's value. Returns that statement in the second case (the caller places
		/// the Set near it), null otherwise. A pin of a node no statement uses leaves the Set
		/// unconnected (written nowhere until it is wired).
		public static Node SpliceSet(Graph g, Node set, Pin pin)
		{
			let owner = pin.Owner;
			if (owner.IsExecNode && owner.Then != null)
			{
				let after = ((pin.Name == "element" || pin.Name == "counter") && owner.FindOutput("body") != null) ? owner.FindOutput("body") : owner.Then;
				let oldNext = g.ExecTarget(after);
				g.Connect(after, set.ExecIn);
				if (oldNext != null)
					g.Connect(set.Then, oldNext.ExecIn);
				return null;
			}
			if (owner.IsExecNode)
				return null;
			// A value node: the Set runs right before the first statement that uses the value.
			Node before = null;
			List<Node> stack = scope .();
			HashSet<Node> seen = scope .();
			stack.Add(owner);
			while (!stack.IsEmpty && before == null)
			{
				let cur = stack.PopBack();
				if (!seen.Add(cur))
					continue;
				for (let l in g.Links)
				{
					if (l.From.Owner != cur || l.From.Kind != .Data)
						continue;
					let user = l.To.Owner;
					if (user == set)
						continue;
					if (user.IsExecNode && user != g.Entry && user.ExecIn != null && g.IsLinked(user.ExecIn))
					{
						before = user;
						break;
					}
					stack.Add(user);
				}
			}
			if (before == null)
				return null;
			let inLink = g.FindLinkTo(before.ExecIn);
			let prev = inLink.From;
			g.Connect(prev, set.ExecIn);
			g.Connect(set.Then, before.ExecIn);
			return before;
		}
	}
}
