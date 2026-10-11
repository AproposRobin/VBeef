using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Syntax;

namespace VisualBeef.Document
{
	enum DiagnosticSeverity
	{
		Error,
		Warning
	}

	/// One compiler message with a source location, and where it lands in the graphs.
	class Diagnostic
	{
		public DiagnosticSeverity Severity;
		public String Text = new .() ~ delete _;
		/// Source file as the compiler printed it ("" when the message has no location).
		public String Path = new .() ~ delete _;
		/// 1-based; 0 = unknown.
		public int32 Line;
		public int32 Column;

		// Filled by DiagnosticMap.Locate.
		/// Method graph that owns the line ("" = outside every function: a field, a type
		/// declaration, another file: shown at document level).
		public String MethodKey = new .() ~ delete _;
		/// Content-keyed layout key of the node (`path#hash`, see LayoutKeys) ("" = no node).
		/// Survives edits and graph rebuilds, so the node is found again after the text changed.
		public String NodeKey = new .() ~ delete _;
		/// "Player.Tick" / "Player" for display.
		public String Where = new .() ~ delete _;
		/// Node id in the graph the diagnostic was last resolved against.
		public int32 NodeId = -1;
		/// Graph.Serial of that graph (0 = not resolved yet). A serial, not the object: the
		/// allocator may hand a deleted graph's address to a new one.
		public int32 ResolvedSerial;
		/// The node the message was about was deleted from the live graph after the compile
		/// (the Problems row says so; no other node takes the message over).
		public bool NodeGone;

		public bool IsError => Severity == .Error;
		public bool OnNode => !NodeKey.IsEmpty;
		public bool HasLocation => !Path.IsEmpty && Line > 0;
	}

	/// Parses compiler output lines into diagnostics.
	static class BuildOutput
	{
		/// Recognises
		///   `ERROR: <text> at line <L>:<C> in <path>` / `WARNING: ...` (BeefBuild),
		///   `<path>(<L>,<C>): error|warning [code]: <text>` (MSVC style),
		///   `<path>:<L>:<C>: error|warning: <text>` (clang / gcc style).
		/// Leading progress-bar noise is skipped. Returns null for any other line.
		public static Diagnostic Parse(StringView lineIn)
		{
			var l = lineIn;
			l.Trim();
			if (l.IsEmpty)
				return null;
			// BeefBuild may prefix messages with its progress bar ("[    ]***ERROR: ...").
			int errPos = l.IndexOf("ERROR:");
			int warnPos = l.IndexOf("WARNING");
			if (errPos > 0 && (warnPos < 0 || errPos < warnPos))
				l = l.Substring(errPos);
			else if (warnPos > 0 && (errPos < 0 || warnPos < errPos) && !LooksLikePathPrefix(l.Substring(0, warnPos)))
				l = l.Substring(warnPos);
			if (l.StartsWith("ERROR-SOFT"))
				return null;
			bool isError = l.StartsWith("ERROR:");
			bool isWarning = l.StartsWith("WARNING");
			if (isError || isWarning)
				return ParseBeef(l, isError);
			return ParseFileLineCol(l);
		}

		static bool LooksLikePathPrefix(StringView s) => s.Contains(':') && (s.Contains('\\') || s.Contains('/'));

		static Diagnostic ParseBeef(StringView l, bool isError)
		{
			int colon = l.IndexOf(':');
			if (colon < 0)
				return null;
			StringView rest = l.Substring(colon + 1);
			rest.Trim();
			Diagnostic d = new .();
			d.Severity = isError ? .Error : .Warning;
			int at = -1;
			for (int i = rest.Length - 9; i >= 0; i--)
			{
				if (rest.Substring(i).StartsWith(" at line "))
				{
					at = i;
					break;
				}
			}
			if (at >= 0)
			{
				d.Text.Set(rest.Substring(0, at));
				StringView loc = rest.Substring(at + " at line ".Length);
				int inPos = loc.IndexOf(" in ");
				if (inPos >= 0)
				{
					StringView lc = loc.Substring(0, inPos);
					var path = loc.Substring(inPos + 4);
					path.Trim();
					d.Path.Set(path);
					ParseLineCol(lc, ':', d);
				}
			}
			else
				d.Text.Set(rest);
			return d;
		}

		static void ParseLineCol(StringView lc, char8 sep, Diagnostic d)
		{
			var lc;
			lc.Trim();
			int c = lc.IndexOf(sep);
			if (c >= 0)
			{
				if (int32.Parse(lc.Substring(0, c)) case .Ok(let ln))
					d.Line = ln;
				var colText = lc.Substring(c + 1);
				colText.Trim();
				if (int32.Parse(colText) case .Ok(let col))
					d.Column = col;
			}
			else if (int32.Parse(lc) case .Ok(let ln))
				d.Line = ln;
		}

		/// `path(L,C): error X: text` or `path:L:C: error: text`.
		static Diagnostic ParseFileLineCol(StringView l)
		{
			int sevAt = -1;
			bool isError = false;
			StringView[4] words = .("): error", "): warning", ": error", ": warning");
			for (int w < 4)
			{
				int p = l.IndexOf(words[w]);
				if (p > 0 && (sevAt < 0 || p < sevAt))
				{
					sevAt = p;
					isError = (w % 2) == 0;
				}
			}
			if (sevAt < 0)
				return null;
			StringView head = l.Substring(0, sevAt + ((l[sevAt] == ')') ? 1 : 0));
			// The text after "error[ code]:": the first colon after the severity word.
			StringView tail = l.Substring(sevAt);
			int sevWord = tail.IndexOf(isError ? "error" : "warning");
			StringView afterWord = tail.Substring(sevWord);
			int msgColon = afterWord.IndexOf(':');
			if (msgColon < 0)
				return null;
			var text = afterWord.Substring(msgColon + 1);
			text.Trim();
			Diagnostic d = new .();
			d.Severity = isError ? .Error : .Warning;
			d.Text.Set(text);
			if (head.EndsWith(')'))
			{
				int open = head.LastIndexOf('(');
				if (open > 0)
				{
					d.Path.Set(head.Substring(0, open));
					ParseLineCol(head.Substring(open + 1, head.Length - open - 2), ',', d);
				}
			}
			else
			{
				// path:L:C (the path itself may hold a drive colon).
				int last = head.LastIndexOf(':');
				int prev = (last > 0) ? head.Substring(0, last).LastIndexOf(':') : -1;
				if (prev > 1 && IsNumber(head.Substring(prev + 1, last - prev - 1)) && IsNumber(head.Substring(last + 1)))
				{
					d.Path.Set(head.Substring(0, prev));
					ParseLineCol(head.Substring(prev + 1), ':', d);
				}
				else if (last > 1 && IsNumber(head.Substring(last + 1)))
				{
					d.Path.Set(head.Substring(0, last));
					ParseLineCol(head.Substring(last + 1), ':', d);
				}
			}
			if (d.Path.IsEmpty)
			{
				delete d;
				return null;
			}
			return d;
		}

		static bool IsNumber(StringView s)
		{
			var s;
			s.Trim();
			if (s.IsEmpty)
				return false;
			for (let c in s.RawChars)
				if (!c.IsDigit)
					return false;
			return true;
		}
	}

	/// Maps a source line to the graph node that owns it, using the content-keyed layout keys
	/// (`path#hash`, see LayoutKeys) so the mapping survives edits made after the compile.
	static class DiagnosticMap
	{
		/// The graphable method (or the Broken member, shown as its read-only error graph) whose
		/// span holds `line` (1-based), or null.
		public static MethodGraph MethodAt(SourceDocument doc, int32 line)
		{
			if (doc.Unit == null || line <= 0)
				return null;
			MethodGraph best = null;
			int bestSpan = int.MaxValue;
			for (let mg in doc.Methods)
			{
				if ((!mg.Graphable && !mg.IsBroken) || !mg.Method.HasSpan)
					continue;
				let first = doc.Unit.LineOf(doc.Unit.Tokens[mg.Method.FirstTok].Start);
				let last = doc.Unit.LineOf(doc.Unit.Tokens[mg.Method.LastTok].End);
				if (line < first || line > last)
					continue;
				// Local functions / nested declarations: the innermost span wins.
				if (last - first < bestSpan)
				{
					best = mg;
					bestSpan = last - first;
				}
			}
			return best;
		}

		/// The innermost node whose source lines hold `line`; statements win over pure nodes of
		/// the same size. Null when no node covers it.
		public static Node NodeAt(Graph graph, int32 line)
		{
			Node best = null;
			for (let n in graph.Nodes)
			{
				if (n.Line <= 0 || line < n.Line || line > n.LineEnd)
					continue;
				if (best == null || (n.LineEnd - n.Line) < (best.LineEnd - best.Line) ||
					((n.LineEnd - n.Line) == (best.LineEnd - best.Line) && !n.IsPure && best.IsPure))
					best = n;
			}
			return best;
		}

		/// Fills d.MethodKey / NodeKey / NodeId / Where from the document the diagnostic points
		/// into (the document must hold the text that was compiled). A line inside a function
		/// but on no statement (the signature, a brace) maps to the function's entry node.
		/// Returns true when a node was found.
		public static bool Locate(SourceDocument doc, Diagnostic d)
		{
			d.MethodKey.Clear();
			d.NodeKey.Clear();
			d.Where.Clear();
			d.NodeId = -1;
			d.ResolvedSerial = 0;
			d.NodeGone = false;
			let mg = MethodAt(doc, d.Line);
			if (mg == null)
			{
				// Document level: name the type that holds the line, when there is one.
				if (doc.Unit != null && d.Line > 0)
				{
					List<Member> types = scope .();
					doc.Unit.CollectTypes(types);
					Member owner = null;
					int ownerSpan = int.MaxValue;
					for (let t in types)
					{
						if (!t.HasSpan)
							continue;
						let first = doc.Unit.LineOf(doc.Unit.Tokens[t.FirstTok].Start);
						let last = doc.Unit.LineOf(doc.Unit.Tokens[t.LastTok].End);
						if (d.Line >= first && d.Line <= last && last - first < ownerSpan)
						{
							owner = t;
							ownerSpan = last - first;
						}
					}
					if (owner != null)
						d.Where.Set(owner.Name);
				}
				return false;
			}
			d.MethodKey.Set(mg.Key);
			if (mg.Owner != null)
				d.Where.AppendF("{}.", mg.Owner.Name);
			d.Where.Append(mg.Method.Name);
			let graph = mg.Graph;
			var node = NodeAt(graph, d.Line);
			if (node == null)
				node = graph.Entry;
			if (node == null)
				return false;
			LayoutKeys.Compose(node, d.NodeKey);
			d.NodeId = node.Id;
			d.ResolvedSerial = graph.Serial;
			return true;
		}

		/// Finds the node a located diagnostic belongs to in the method's current graph. Null when
		/// that node is gone.
		///
		/// While the graph object is the one the message was resolved against (Graph.Serial), the
		/// node is followed by identity: the node id, which the graph never hands out twice. A
		/// node edited in the graph keeps its message until the next compile; a deleted node's
		/// message goes nowhere (no new or neighbouring node inherits it, even one that now sits
		/// at the deleted statement's place). In a different graph object (rebuilt from the file,
		/// an undo step) it is found by its content key: the same statement (exact), or the same
		/// statement moved (same hash, another place). A different statement at the old place
		/// is not the same node, so it is never matched by position alone.
		public static Node Resolve(MethodGraph mg, Diagnostic d)
		{
			if (d.NodeKey.IsEmpty || mg.Key != d.MethodKey)
				return null;
			let graph = mg.Graph;
			if (d.ResolvedSerial == graph.Serial)
			{
				if (d.NodeId < 0)
					return null;
				for (let n in graph.Nodes)
					if (n.Id == d.NodeId)
						return n;
				d.NodeId = -1;
				d.NodeGone = true;
				return null;
			}
			let node = FindByKey(graph, d.NodeKey, false);
			d.ResolvedSerial = graph.Serial;
			d.NodeId = (node != null) ? node.Id : -1;
			d.NodeGone = node == null;
			return node;
		}

		/// The node a saved layout key names (see LayoutKeys.Reconcile). `samePlaceEdited` also
		/// accepts a different statement at the same structural place (an edited statement; right
		/// for breakpoints, wrong for compiler messages, which describe the text they were about).
		public static Node FindByKey(Graph graph, StringView nodeKey, bool samePlaceEdited = true)
		{
			String key = scope .();
			for (let n in graph.Nodes)
			{
				key.Clear();
				LayoutKeys.Compose(n, key);
				if (key == nodeKey)
					return n;
			}
			List<StringView> saved = scope .();
			saved.Add(nodeKey);
			List<Node> nodes = scope .();
			for (let n in graph.Nodes)
				nodes.Add(n);
			List<int> match = scope .();
			LayoutKeys.Reconcile(saved, nodes, match, samePlaceEdited);
			if (!match.IsEmpty && match[0] >= 0)
				return nodes[match[0]];
			return null;
		}
	}
}
