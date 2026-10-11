using System;
using System.Collections;

namespace VisualBeef.Graph
{
	/// Blueprint-style flow macros as plain Beef. A macro is a `NodeKind.Flow` node whose Text
	/// names it; the generator writes it as ordinary statements and GraphBuilder recognises that
	/// exact shape on the way back (see docs/Flow-Nodes.md for every form and its limits).
	///
	/// Stateful macros keep their state in a private field of the enclosing type whose name starts
	/// with a reserved prefix (`__doOnce_1`). The prefix is what identifies the shape when the
	/// file is read back, so ordinary `if` statements are never mistaken for macros.
	static class FlowMacros
	{
		public const String Sequence = "Sequence";
		public const String DoOnce = "DoOnce";
		public const String DoOnceReset = "DoOnce.Reset";
		public const String DoN = "DoN";
		public const String DoNReset = "DoN.Reset";
		public const String FlipFlop = "FlipFlop";
		public const String Gate = "Gate";
		public const String GateOpen = "Gate.Open";
		public const String GateClose = "Gate.Close";
		public const String GateToggle = "Gate.Toggle";
		public const String MultiGate = "MultiGate";
		public const String MultiGateReset = "MultiGate.Reset";

		public const String PrefixDoOnce = "__doOnce_";
		public const String PrefixDoN = "__doN_";
		public const String PrefixFlipFlop = "__flipFlop_";
		public const String PrefixGateOpen = "__gateOpen_";
		public const String PrefixGateClosed = "__gateClosed_";
		public const String PrefixMultiGate = "__multiGate_";

		/// Marker comment in front of a Sequence (consecutive `{ }` blocks).
		public const String SequenceMarker = "// vb:sequence";

		/// The macro owns a state field (Text2 names it).
		public static bool IsStateful(StringView macro)
		{
			return macro == DoOnce || macro == DoN || macro == FlipFlop || macro == Gate || macro == MultiGate;
		}

		/// The node acts on the state field of another macro (Text2 names that field).
		public static bool IsAction(StringView macro)
		{
			return macro == DoOnceReset || macro == DoNReset || macro == GateOpen || macro == GateClose ||
				macro == GateToggle || macro == MultiGateReset;
		}

		/// The stateful macro an action node works on.
		public static StringView TargetMacro(StringView action)
		{
			if (action == DoOnceReset) return DoOnce;
			if (action == DoNReset) return DoN;
			if (action == MultiGateReset) return MultiGate;
			return Gate;
		}

		public static StringView FieldType(StringView macro) => (macro == DoN || macro == MultiGate) ? "int" : "bool";

		/// The macro a field name belongs to (by prefix), or "".
		public static StringView MacroOfField(StringView name)
		{
			if (name.StartsWith(PrefixDoOnce)) return DoOnce;
			if (name.StartsWith(PrefixDoN)) return DoN;
			if (name.StartsWith(PrefixFlipFlop)) return FlipFlop;
			if (name.StartsWith(PrefixGateOpen) || name.StartsWith(PrefixGateClosed)) return Gate;
			if (name.StartsWith(PrefixMultiGate)) return MultiGate;
			return "";
		}

		public static StringView DefaultPrefix(StringView macro)
		{
			if (macro == DoOnce) return PrefixDoOnce;
			if (macro == DoN) return PrefixDoN;
			if (macro == FlipFlop) return PrefixFlipFlop;
			if (macro == Gate) return PrefixGateClosed;
			return PrefixMultiGate;
		}

		/// A Gate whose state field is `__gateOpen_N` starts closed (false = closed); one with
		/// `__gateClosed_N` starts open.
		public static bool GateStartsClosed(Node gate) => gate.Text2.StartsWith(PrefixGateOpen);

		/// Switches a Gate between starting closed / open by renaming its field prefix.
		public static void SetGateStartClosed(Node gate, bool closed)
		{
			if (GateStartsClosed(gate) == closed)
				return;
			String tag = scope .();
			StringView old = gate.Text2;
			if (old.StartsWith(PrefixGateOpen))
				tag.Append(old.Substring(PrefixGateOpen.Length));
			else if (old.StartsWith(PrefixGateClosed))
				tag.Append(old.Substring(PrefixGateClosed.Length));
			if (tag.IsEmpty)
				tag.Append('1');
			gate.Text2.Set(closed ? PrefixGateOpen : PrefixGateClosed);
			gate.Text2.Append(tag);
			gate.Edited = true;
		}

		public static void GetTitle(Node n, String o)
		{
			let t = n.Text;
			if (t == Sequence) o.Append("Sequence");
			else if (t == DoOnce) o.Append("Do Once");
			else if (t == DoOnceReset) o.Append("Reset Do Once");
			else if (t == DoN) o.Append("Do N");
			else if (t == DoNReset) o.Append("Reset Do N");
			else if (t == FlipFlop) o.Append("Flip Flop");
			else if (t == Gate) o.Append("Gate");
			else if (t == GateOpen) o.Append("Open Gate");
			else if (t == GateClose) o.Append("Close Gate");
			else if (t == GateToggle) o.Append("Toggle Gate");
			else if (t == MultiGate) o.Append("Multi Gate");
			else if (t == MultiGateReset) o.Append("Reset Multi Gate");
			else o.Append(t);
		}

		/// One-line description for tooltips / the Properties panel.
		public static void GetSummary(Node n, String o)
		{
			let t = n.Text;
			if (t == Sequence) o.Append("Runs each Then block in order, then continues.");
			else if (t == DoOnce) o.Append("Runs the Once block the first time only (until reset).");
			else if (t == DoN) o.Append("Runs the Do block the first N times (until reset).");
			else if (t == FlipFlop) o.Append("Alternates between A and B on every run.");
			else if (t == Gate) o.Append("Runs the Exit block only while the gate is open.");
			else if (t == MultiGate) o.Append("Runs the next output each time; stops after the last (or loops).");
			else if (IsAction(t)) o.Append("Changes the state of a macro elsewhere in this type.");
		}

		/// Nodes whose arms are exclusive, so arms that all lead to one node merge after the node.
		public static bool HasMerge(Node n)
		{
			switch (n.Kind)
			{
			case .Branch, .Switch, .ResultMatch: return true;
			case .Flow: return n.Text == FlipFlop || (n.Text == MultiGate && n.Postfix);
			default: return false;
			}
		}

		/// Adds the pins a macro has (the exec input exists already). `arms` is the number of
		/// Then / Out outputs for Sequence and MultiGate.
		public static void Setup(Graph g, Node n, StringView macro, int arms = 2)
		{
			n.Text.Set(macro);
			if (macro == Sequence)
			{
				for (int i < arms)
					g.AddExecOut(n, scope $"seq{i}", scope $"Then {i}");
			}
			else if (macro == DoOnce)
				g.AddExecOut(n, "body", "Once");
			else if (macro == DoN)
			{
				let np = g.AddDataIn(n, "n", "N");
				np.TypeName.Set("int");
				np.Default.Set("3");
				g.AddExecOut(n, "body", "Do");
			}
			else if (macro == FlipFlop)
			{
				g.AddExecOut(n, "a", "A");
				g.AddExecOut(n, "b", "B");
			}
			else if (macro == Gate)
				g.AddExecOut(n, "body", "Exit");
			else if (macro == MultiGate)
			{
				for (int i < arms)
					g.AddExecOut(n, scope $"out{i}", scope $"Out {i}");
			}
			g.AddExecOut(n, "then", IsAction(macro) ? "" : "Completed");
			if (macro == DoN)
			{
				let c = g.AddDataOut(n, "counter", "Counter");
				c.TypeName.Set("int");
			}
			else if (macro == FlipFlop)
			{
				let c = g.AddDataOut(n, "isA", "Is A");
				c.TypeName.Set("bool");
			}
		}

		/// Names the arm outputs of a Sequence / MultiGate `seq0..` / `out0..` in order, so the
		/// node matches what a fresh parse of its code would build.
		public static void Renumber(Node n)
		{
			StringView stem = (n.Text == Sequence) ? "seq" : ((n.Text == MultiGate) ? "out" : "");
			StringView labelStem = (n.Text == Sequence) ? "Then " : "Out ";
			if (stem.IsEmpty)
				return;
			int i = 0;
			for (let p in n.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				p.Name.Clear();
				p.Name.AppendF("{}{}", stem, i);
				p.Label.Clear();
				p.Label.AppendF("{}{}", labelStem, i);
				i++;
			}
		}

		public static int ArmCount(Node n)
		{
			int c = 0;
			for (let p in n.Outputs)
				if (p.Kind == .Exec && p.Name != "then")
					c++;
			return c;
		}

		/// Adds an arm (Sequence Then / MultiGate Out) before `then`.
		public static Pin AddArm(Graph g, Node n)
		{
			let stem = (n.Text == Sequence) ? "seq" : "out";
			let p = g.AddExecOut(n, scope $"{stem}{ArmCount(n)}", "");
			// Keep `then` last.
			let then = n.FindOutput("then");
			if (then != null)
			{
				n.Outputs.Remove(p);
				int at = n.Outputs.IndexOf(then);
				n.Outputs.Insert(at, p);
			}
			Renumber(n);
			n.Edited = true;
			g.Version++;
			return p;
		}

		/// Removes the last arm (keeps at least one).
		public static void RemoveArm(Graph g, Node n)
		{
			if (ArmCount(n) <= 1)
				return;
			Pin last = null;
			for (let p in n.Outputs)
				if (p.Kind == .Exec && p.Name != "then")
					last = p;
			if (last != null)
			{
				g.RemovePin(last);
				Renumber(n);
			}
		}

		/// The first free `<prefix>N` for a state field, avoiding other macros in the graph and
		/// the names `reserved` (fields the owner type already has).
		public static void FreshFieldName(Graph g, StringView prefix, HashSet<String> reserved, String outName)
		{
			for (int k = 1; ; k++)
			{
				outName.Clear();
				outName.AppendF("{}{}", prefix, k);
				bool used = reserved != null && reserved.ContainsAlt(StringView(outName));
				if (!used)
				{
					for (let o in g.Nodes)
						if (o.Kind == .Flow && o.Text2 == outName)
							used = true;
				}
				if (!used)
					return;
			}
		}
	}
}
