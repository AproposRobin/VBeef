using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Debug
{
	/// Node <-> source line, for breakpoints and for showing where a program stopped
	/// (docs/Debugging.md). Lines are 1-based, the lines of the saved text the program was built
	/// from (Node.Line is kept in step with the text by every commit).
	///
	/// Which line a node stands for:
	/// - a statement node (call, Set, Local, Branch, loops, Return, Code, ...): its first line;
	/// - the function's entry node: the line of the body's `{` (stops when the function starts);
	/// - a value node (Get, operators, a pure call, Construct, Lambda, ...): the line of the
	///   statement that uses its value (it runs as part of that statement);
	/// - no line (the breakpoint control is disabled, `outWhyNot` says why): a node not written
	///   to the code yet (unconnected, or edited and not committed), a value nothing uses, a local
	///   declared without a value and a local function's declaration (they produce no code), code
	///   that could not be read.
	static class DebugMap
	{
		/// The line a breakpoint on `n` goes to, or 0 (see the type comment).
		public static int32 LineOf(Graph g, Node n, String outWhyNot = null)
		{
			HashSet<Node> seen = scope .();
			return LineOfRec(g, n, seen, outWhyNot);
		}

		static int32 LineOfRec(Graph g, Node n, HashSet<Node> seen, String outWhyNot)
		{
			if (!seen.Add(n))
				return 0;
			if (n.Line <= 0)
			{
				outWhyNot?.Set("Not in the code yet: connect it to the flow and compile.");
				return 0;
			}
			if (n.Error != null)
			{
				outWhyNot?.Set("Code that could not be read has no breakpoint.");
				return 0;
			}
			if (n == g.Entry || n.Kind == .Entry)
				return (n.LineEnd > 0) ? n.LineEnd : n.Line;
			if (n.Kind == .LocalFunc)
			{
				outWhyNot?.Set("A local function's declaration runs no code; put the breakpoint on a node in its body.");
				return 0;
			}
			if (n.Kind == .LocalVar)
			{
				let v = n.FindInput("value");
				if (v == null || (g.FindLinkTo(v) == null && v.Default.IsEmpty))
				{
					outWhyNot?.Set("A local declared without a value runs no code.");
					return 0;
				}
			}
			if (!n.IsPure)
				return n.Line;
			// A value runs as part of the statement that uses it.
			List<Link> links = scope .();
			for (let p in n.Outputs)
			{
				if (p.Kind != .Data)
					continue;
				links.Clear();
				g.FindLinksFrom(p, links);
				for (let l in links)
				{
					let line = LineOfRec(g, l.To.Owner, seen, null);
					if (line > 0)
						return line;
				}
			}
			outWhyNot?.Set("Nothing uses this value, so it runs no code.");
			return 0;
		}

		/// The graph and node a stop at `line` of `doc` belongs to: the innermost statement whose
		/// lines hold it; a line of the function that is on no statement (the signature, a brace)
		/// gives the entry node. Null when no function holds the line.
		public static Node NodeAt(SourceDocument doc, int32 line, out MethodGraph outMg)
		{
			outMg = DiagnosticMap.MethodAt(doc, line);
			if (outMg == null)
				return null;
			return StatementAt(outMg.Graph, line);
		}

		/// See NodeAt. Statements win over values; among statements the smallest span wins, and
		/// on a tie the one whose own line is `line`.
		public static Node StatementAt(Graph g, int32 line)
		{
			let entry = g.Entry;
			if (entry != null && entry.LineEnd > 0 && line <= entry.LineEnd && line >= entry.Line)
			{
				// The signature and the `{` line: unless a statement starts on that same line.
				bool stmtHere = false;
				for (let n in g.Nodes)
					if (n != entry && !n.IsPure && n.Line == line)
						stmtHere = true;
				if (!stmtHere)
					return entry;
			}
			Node best = null;
			for (let n in g.Nodes)
			{
				if (n == entry || n.IsPure || n.Line <= 0 || line < n.Line || line > n.LineEnd)
					continue;
				if (best == null)
				{
					best = n;
					continue;
				}
				let span = n.LineEnd - n.Line;
				let bestSpan = best.LineEnd - best.Line;
				if (span < bestSpan || (span == bestSpan && n.Line == line && best.Line != line))
					best = n;
			}
			return (best != null) ? best : entry;
		}

		/// The expression whose value a pin shows while stopped, or false with the reason. Values
		/// are read, never computed by calling into the program: a pin fed by a call shows the
		/// variable the call's result was kept in, or nothing.
		public static bool PinExpr(Graph g, Pin p, String outExpr, String outWhyNot = null)
		{
			int depth = 0;
			return PinExprRec(g, p, outExpr, outWhyNot, ref depth);
		}

		static bool PinExprRec(Graph g, Pin p, String outExpr, String outWhyNot, ref int depth)
		{
			if (++depth > 64)
				return false;
			if (p.Kind == .Exec)
			{
				outWhyNot?.Set("Flow pins have no value.");
				return false;
			}
			if (p.IsInput)
			{
				let link = g.FindLinkTo(p);
				if (link != null)
					return PinExprRec(g, link.From, outExpr, outWhyNot, ref depth);
				if (p.Default.IsEmpty)
				{
					outWhyNot?.Set("Not set.");
					return false;
				}
				outExpr.Append(p.Default);
				return true;
			}
			let n = p.Owner;
			if (p.IsOutArg)
			{
				if (p.OutName == null || p.OutName.IsEmpty || p.Form == .Discard)
				{
					outWhyNot?.Set("The value is discarded (`?`).");
					return false;
				}
				outExpr.Append(p.OutName);
				return true;
			}
			switch (n.Kind)
			{
			case .Entry:
				outExpr.Append(p.Label);
				return !p.Label.IsEmpty;
			case .LocalVar, .ForEach, .Using:
				outExpr.Append(n.Text);
				return !n.Text.IsEmpty;
			case .For:
				if (!n.IsCountingLoop)
					return false;
				outExpr.Append(n.Text);
				return !n.Text.IsEmpty;
			case .Flow:
				if (n.Text2.IsEmpty)
					return false;
				outExpr.Append(n.Text2);
				return true;
			default:
			}
			if (!n.IsPure)
			{
				if (n.Kind == .Call && !n.Text2.IsEmpty)
				{
					outExpr.Append(n.Text2);
					return true;
				}
				outWhyNot?.Set("The result is not kept in a variable, so there is nothing to read.");
				return false;
			}
			if (n.Kind == .Call || n.Kind == .Construct || n.Kind == .Lambda || n.Kind == .Format)
			{
				outWhyNot?.Set("Shown only by running code (a call); values are read, never computed.");
				return false;
			}
			if (n.Original != null && g.IsClean(n))
			{
				outExpr.Append(n.Original);
				return true;
			}
			switch (n.Kind)
			{
			case .This:
				outExpr.Append("this");
				return true;
			case .Base:
				outExpr.Append("base");
				return true;
			case .Expr:
				outExpr.Append(n.Text);
				return !n.Text.IsEmpty;
			case .Get:
				let target = n.FindInput("target");
				if (target != null && (g.FindLinkTo(target) != null || !target.Default.IsEmpty))
				{
					String t = scope .();
					if (!PinExprRec(g, target, t, outWhyNot, ref depth))
						return false;
					outExpr.AppendF("({}).", t);
				}
				outExpr.Append(n.Text);
				return true;
			case .Cast:
				String v = scope .();
				if (!PinExprRec(g, n.FindInput("value"), v, outWhyNot, ref depth))
					return false;
				outExpr.AppendF("({})({})", n.Text, v);
				return true;
			case .Operator:
				let a = n.FindInput("a");
				let b = n.FindInput("b");
				String av = scope .();
				if (a == null || !PinExprRec(g, a, av, outWhyNot, ref depth))
					return false;
				if (b == null)
				{
					if (n.Postfix || n.Text == "++" || n.Text == "--")
						return false; // reading it would change the variable
					outExpr.AppendF("{}({})", n.Text, av);
					return true;
				}
				String bv = scope .();
				if (n.Text == "is" || n.Text == "as" || n.Text == "case")
					bv.Set(b.Default);
				else if (!PinExprRec(g, b, bv, outWhyNot, ref depth))
					return false;
				outExpr.AppendF("({}) {} ({})", av, n.Text, bv);
				return true;
			default:
				outWhyNot?.Set("This value cannot be read on its own.");
				return false;
			}
		}
	}
}
