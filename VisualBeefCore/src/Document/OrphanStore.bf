using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Graph;

namespace VisualBeef.Document
{
	/// A link of a saved orphan subgraph that the code snippet does not express by itself:
	///  - External: between an orphan and a connected node of the method graph (OtherKey is that
	///    node's structural key in the method graph);
	///  - internal "wire": between two orphans, where the code would not carry the link (data read
	///    from an exec node's output - a local, a loop element, an impure call's value - or an exec
	///    link that merges into / loops back to an already written statement). OtherKey is then
	///    the other orphan's key in the snippet.
	/// When the orphan end is an input, Default holds that input's own default value (the snippet
	/// writes a placeholder there).
	class OrphanLinkRec
	{
		public bool External;
		public String NodeKey = new .() ~ delete _;
		public String Pin = new .() ~ delete _;
		public bool NodeIsFrom;
		public String OtherKey = new .() ~ delete _;
		public String OtherPin = new .() ~ delete _;
		public String Default = new .() ~ delete _;

		public OrphanLinkRec Clone()
		{
			OrphanLinkRec c = new .();
			c.External = External;
			c.NodeKey.Set(NodeKey);
			c.Pin.Set(Pin);
			c.NodeIsFrom = NodeIsFrom;
			c.OtherKey.Set(OtherKey);
			c.OtherPin.Set(OtherPin);
			c.Default.Set(Default);
			return c;
		}
	}

	/// The unconnected nodes of one method, as saved in the `.vblayout` side file: the nodes as
	/// Beef statements (a method body GraphBuilder reads back), their positions by the structural
	/// key the snippet produces, and the links the code can't carry.
	class OrphanRecord
	{
		public String MethodKey = new .() ~ delete _;
		/// Text between the method body's braces.
		public String Code = new .() ~ delete _;
		public Dictionary<String, NodePos> Positions = new .() ~ DeleteDictionaryAndKeys!(_);
		public List<OrphanLinkRec> Links = new .() ~ DeleteContainerAndItems!(_);
		/// Pin defaults that would read back from the code as nodes (a default `amount` reads
		/// back as a Get node): NodeKey, Pin and Default are used.
		public List<OrphanLinkRec> Defaults = new .() ~ DeleteContainerAndItems!(_);

		public OrphanRecord Clone()
		{
			OrphanRecord r = new .();
			r.MethodKey.Set(MethodKey);
			r.Code.Set(Code);
			for (let kv in Positions)
				r.Positions[new String(kv.key)] = kv.value;
			for (let l in Links)
				r.Links.Add(l.Clone());
			for (let d in Defaults)
				r.Defaults.Add(d.Clone());
			return r;
		}

		public void SetPosition(StringView key, NodePos pos)
		{
			String k = scope .(key);
			if (Positions.ContainsKey(k))
				Positions[k] = pos;
			else
				Positions[new String(key)] = pos;
		}

		/// Appends the record's lines (see OrphanCodec for the format).
		public void Write(String o)
		{
			o.AppendF("#orphans\t{}\t", MethodKey);
			LayoutText.Escape(Code, o, true);
			o.Append('\n');
			List<String> keys = scope .();
			for (let k in Positions.Keys)
				keys.Add(k);
			keys.Sort(scope (a, b) => String.Compare(a, b, false));
			for (let k in keys)
			{
				let pos = Positions[k];
				o.AppendF("#orphanpos\t{}\t{}\t{}\t{}\n", MethodKey, k, (int)pos.X, (int)pos.Y);
			}
			for (let l in Links)
			{
				o.AppendF("#orphanlink\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t", MethodKey, l.External ? "graph" : "orphan", l.NodeKey, l.Pin,
					l.NodeIsFrom ? "out" : "in", l.OtherKey, l.OtherPin);
				LayoutText.Escape(l.Default, o, true);
				o.Append('\n');
			}
			for (let d in Defaults)
			{
				o.AppendF("#orphandefault\t{}\t{}\t{}\t", MethodKey, d.NodeKey, d.Pin);
				LayoutText.Escape(d.Default, o, true);
				o.Append('\n');
			}
		}
	}

	/// Saves the nodes of a method graph that are not reachable from its Entry (they produce no
	/// code) as Beef code plus layout data, and puts them back when the graph is built again.
	///
	/// Side file lines (tab separated; one group per method):
	///   #orphans    <tab> methodKey <tab> code (escaped: \\ \t \n \r)
	///   #orphanpos  <tab> methodKey <tab> nodeKey <tab> x <tab> y
	///   #orphanlink <tab> methodKey <tab> graph|orphan <tab> nodeKey <tab> pin <tab> in|out <tab> otherKey <tab> otherPin <tab> default (escaped)
	///   #orphandefault <tab> methodKey <tab> nodeKey <tab> pin <tab> default (escaped); the pin `@temp`
	///                  holds the `let` name of an impure call's result (Node.Text2)
	///
	/// The code is a method body: each orphan execution chain (from a chain head, an exec node
	/// whose input is not linked) is written as statements, chains separated by a
	/// `__vbOrphanChain();` marker statement; each pure node whose value feeds nothing is written
	/// last as `let __vbOrphanValue = <expr>;`. Inputs fed by a link listed in #orphanlink hold
	/// the placeholder `(0)` in the code. Node keys are the structural keys of the snippet's own
	/// graph (KeyAssigner), markers included. #orphandefault lists unlinked input defaults that
	/// are not plain literals: the code reads them back as nodes, which the load replaces by the
	/// default again.
	static class OrphanCodec
	{
		public const String ChainMarker = "__vbOrphanChain";
		public const String ValueMarker = "__vbOrphanValue";
		/// `#orphandefault` pseudo pin carrying the `let` name of an impure call's result (Node.Text2).
		public const String TempNamePin = "@temp";
		const String cPlaceholder = "(0)";

		class ExtRef
		{
			public Node Orphan;
			public String Pin = new .() ~ delete _;
			public bool OrphanIsFrom;
			public String OtherKey = new .() ~ delete _;
			public String OtherPin = new .() ~ delete _;
		}

		// ------------------------------------------------------------------ save

		/// The record for the unconnected nodes of a live graph, or null when it has none.
		public static OrphanRecord FromGraph(Graph graph, StringView braceIndent, StringView indentUnit, bool allman)
		{
			HashSet<Node> reachable = scope .();
			graph.GetReachable(reachable);
			if (reachable.Count >= graph.Nodes.Count)
				return null;
			KeyAssigner.Assign(graph);

			Graph t = scope .();
			Dictionary<Node, Node> map = scope .();
			int32 maxId = 0;
			for (let n in graph.Nodes)
			{
				maxId = Math.Max(maxId, n.Id);
				for (let p in n.Inputs)
					maxId = Math.Max(maxId, p.Id);
				for (let p in n.Outputs)
					maxId = Math.Max(maxId, p.Id);
				if (reachable.Contains(n) || n == graph.Entry)
					continue;
				let c = Graph.CloneNodeExact(n);
				t.Nodes.Add(c);
				map[n] = c;
			}
			if (map.IsEmpty)
				return null;
			List<ExtRef> ext = scope .();
			defer { ClearAndDeleteItems!(ext); }
			for (let l in graph.Links)
			{
				maxId = Math.Max(maxId, l.Id);
				bool fromOrphan = map.TryGetValue(l.From.Owner, let fromNode);
				bool toOrphan = map.TryGetValue(l.To.Owner, let toNode);
				if (fromOrphan && toOrphan)
				{
					let from = fromNode.Outputs[l.From.Owner.Outputs.IndexOf(l.From)];
					let to = toNode.Inputs[l.To.Owner.Inputs.IndexOf(l.To)];
					Link c = new .();
					c.Id = l.Id;
					c.From = from;
					c.To = to;
					t.Links.Add(c);
				}
				else if (fromOrphan || toOrphan)
				{
					ExtRef e = new .();
					e.OrphanIsFrom = fromOrphan;
					e.Orphan = fromOrphan ? fromNode : toNode;
					e.Pin.Set(fromOrphan ? l.From.Name : l.To.Name);
					let other = fromOrphan ? l.To : l.From;
					e.OtherKey.Set(other.Owner.Key);
					e.OtherPin.Set(other.Name);
					ext.Add(e);
				}
			}
			t.[Friend]mNextId = maxId + 1;
			return Encode(t, ext, graph.MethodKey, graph.Entry, braceIndent, indentUnit, allman);
		}

		/// The record for orphans kept aside for a graph that is not built (OrphanSet).
		public static OrphanRecord FromSet(OrphanSet set, StringView braceIndent, StringView indentUnit, bool allman)
		{
			Graph t = scope .();
			List<Node> added = scope .();
			set.InjectInto(t, 0, 0, false, added);
			if (added.IsEmpty)
				return null;
			List<Node> byIndex = scope .();
			{
				int ai = 0;
				for (let src in set.Nodes)
					byIndex.Add((src.Kind == .Entry) ? null : added[ai++]);
			}
			List<ExtRef> ext = scope .();
			defer { ClearAndDeleteItems!(ext); }
			for (let el in set.External)
			{
				let orphan = byIndex[el.OrphanNode];
				if (orphan == null)
					continue;
				ExtRef e = new .();
				e.Orphan = orphan;
				e.OrphanIsFrom = el.OrphanIsFrom;
				e.Pin.Set(el.OrphanPin);
				e.OtherKey.Set(el.OtherKey);
				e.OtherPin.Set(el.OtherPin);
				ext.Add(e);
			}
			return Encode(t, ext, set.MethodKey, null, braceIndent, indentUnit, allman);
		}

		static void Cut(Graph t, Link l, List<(Pin from, Pin to)> wires)
		{
			wires.Add((l.From, l.To));
			t.Links.Remove(l);
			delete l;
		}

		/// `t` holds only the orphans and the links between them; it gets an Entry and markers.
		static OrphanRecord Encode(Graph t, List<ExtRef> ext, StringView methodKey, Node realEntry, StringView braceIndent, StringView indentUnit, bool allman)
		{
			List<Node> orphans = scope .();
			orphans.AddRange(t.Nodes);

			// Links the code can't carry: data read from exec nodes.
			List<(Pin from, Pin to)> wires = scope .();
			for (int i = t.Links.Count - 1; i >= 0; i--)
			{
				let l = t.Links[i];
				if (l.From.Kind == .Data && !l.From.Owner.IsPure)
					Cut(t, l, wires);
			}

			// Execution chains: claim each statement once, from the chain heads. Links into a
			// statement already written (merges, loops) become wires.
			HashSet<Node> claimed = scope .();
			List<Node> heads = scope .();
			List<Node> stack = scope .();
			// A lambda's body is written inside the lambda (a data node): never a chain of its own.
			for (let n in orphans)
			{
				if (!n.IsPure)
					continue;
				for (let p in n.Outputs)
				{
					if (p.Kind != .Exec)
						continue;
					var b = t.ExecTarget(p);
					while (b != null && claimed.Add(b))
					{
						for (let bp in b.Outputs)
						{
							if (bp.Kind != .Exec || bp.Name == "then")
								continue;
							let inner = t.ExecTarget(bp);
							if (inner != null)
								stack.Add(inner);
						}
						b = t.ExecTarget(b.Then);
					}
				}
			}
			while (!stack.IsEmpty)
			{
				var b = stack.PopBack();
				while (b != null && claimed.Add(b))
				{
					for (let bp in b.Outputs)
					{
						if (bp.Kind != .Exec || bp.Name == "then")
							continue;
						let inner = t.ExecTarget(bp);
						if (inner != null)
							stack.Add(inner);
					}
					b = t.ExecTarget(b.Then);
				}
			}
			for (int pass < 2)
			{
				for (let n in orphans)
				{
					if (n.IsPure || n.ExecIn == null || claimed.Contains(n))
						continue;
					if (pass == 0 && t.FindLinkTo(n.ExecIn) != null)
						continue;
					heads.Add(n);
					claimed.Add(n);
					stack.Add(n);
					while (!stack.IsEmpty)
					{
						let cur = stack.PopBack();
						for (let p in cur.Outputs)
						{
							if (p.Kind != .Exec)
								continue;
							let l = t.FindLinkFrom(p);
							if (l == null)
								continue;
							let target = l.To.Owner;
							if (claimed.Contains(target))
								Cut(t, l, wires);
							else
							{
								claimed.Add(target);
								stack.Add(target);
							}
						}
					}
				}
			}

			// Placeholders for inputs fed by a link the code doesn't carry; such nodes (and their
			// statements) are regenerated rather than reusing their original text.
			Dictionary<Pin, String> savedDefaults = scope .();
			defer { for (let kv in savedDefaults) delete kv.value; }
			void UsePlaceholder(Pin input)
			{
				if (input.Kind != .Data || savedDefaults.ContainsKey(input))
					return;
				savedDefaults[input] = new String(input.Default);
				input.Default.Set(cPlaceholder);
			}
			for (let w in wires)
			{
				w.from.Owner.Edited = true;
				w.to.Owner.Edited = true;
				UsePlaceholder(w.to);
			}
			for (let e in ext)
			{
				e.Orphan.Edited = true;
				if (!e.OrphanIsFrom)
				{
					let pin = e.Orphan.FindInput(e.Pin);
					if (pin != null)
						UsePlaceholder(pin);
				}
			}

			// Entry (with the method's parameters, so temp names avoid them) and the chains.
			Node entry = t.AddNode(.Entry);
			entry.Text.Set("orphans");
			t.AddExecOut(entry, "then");
			if (realEntry != null)
			{
				for (let p in realEntry.Outputs)
					if (p.Kind == .Data)
						t.AddDataOut(entry, p.Name, p.Label);
			}
			t.Entry = entry;

			Pin cur = entry.Then;
			for (let head in heads)
			{
				if (cur == null)
					break;
				if (@head.Index > 0)
				{
					Node sep = t.AddNode(.Call);
					sep.Text.Set(ChainMarker);
					t.AddExecIn(sep);
					t.AddExecOut(sep, "then");
					t.Connect(cur, sep.ExecIn);
					cur = sep.Then;
				}
				t.Connect(cur, head.ExecIn);
				var last = head;
				int guard = 0;
				while (guard++ < 1000000)
				{
					let next = t.ExecTarget(last.Then);
					if (next == null)
						break;
					last = next;
				}
				cur = last.Then;
			}

			// Pure values that feed nothing.
			for (let n in orphans)
			{
				if (!n.IsPure || cur == null)
					continue;
				Pin result = null;
				bool feeds = false;
				for (let p in n.Outputs)
				{
					if (p.Kind != .Data)
						continue;
					if (result == null)
						result = p;
					if (t.FindLinkFrom(p) != null)
						feeds = true;
				}
				if (feeds || result == null)
					continue;
				Node marker = t.AddNode(.LocalVar);
				marker.Text.Set(ValueMarker);
				marker.Text2.Set("let");
				t.AddExecIn(marker);
				t.AddExecOut(marker, "then");
				t.AddDataOut(marker, "variable", ValueMarker);
				let value = t.AddDataIn(marker, "value", "Value");
				t.Connect(cur, marker.ExecIn);
				t.Connect(result, value);
				cur = marker.Then;
			}

			// Write every statement with its exact original trivia where it has one: normalized
			// comments can't reproduce every layout (a block comment ending on the statement's line).
			for (let n in orphans)
				n.Moved = false;

			KeyAssigner.Assign(t);

			OrphanRecord rec = new .();
			rec.MethodKey.Set(methodKey);
			for (let n in orphans)
			{
				if (!n.HasPos || n.Key.StartsWith("orphan"))
					continue;
				NodePos pos;
				pos.X = n.X;
				pos.Y = n.Y;
				rec.SetPosition(n.Key, pos);
			}
			for (let w in wires)
			{
				if (w.from.Owner.Key.StartsWith("orphan") || w.to.Owner.Key.StartsWith("orphan"))
					continue;
				OrphanLinkRec l = new .();
				l.External = false;
				l.NodeKey.Set(w.to.Owner.Key);
				l.Pin.Set(w.to.Name);
				l.NodeIsFrom = false;
				l.OtherKey.Set(w.from.Owner.Key);
				l.OtherPin.Set(w.from.Name);
				if (savedDefaults.TryGetValue(w.to, let def))
					l.Default.Set(def);
				rec.Links.Add(l);
			}
			for (let e in ext)
			{
				if (e.Orphan.Key.StartsWith("orphan"))
					continue;
				OrphanLinkRec l = new .();
				l.External = true;
				l.NodeKey.Set(e.Orphan.Key);
				l.Pin.Set(e.Pin);
				l.NodeIsFrom = e.OrphanIsFrom;
				l.OtherKey.Set(e.OtherKey);
				l.OtherPin.Set(e.OtherPin);
				if (!e.OrphanIsFrom)
				{
					let pin = e.Orphan.FindInput(e.Pin);
					if (pin != null && savedDefaults.TryGetValue(pin, let def))
						l.Default.Set(def);
				}
				rec.Links.Add(l);
			}

			for (let n in orphans)
			{
				if (n.Key.StartsWith("orphan"))
					continue;
				if (n.Kind == .Call && !n.IsPure && !n.Text2.IsEmpty)
				{
					// The `let` name of a call's result: the snippet reads the value through a
					// placeholder, so the name would be lost (and regenerated) otherwise.
					OrphanLinkRec d = new .();
					d.NodeKey.Set(n.Key);
					d.Pin.Set(TempNamePin);
					d.Default.Set(n.Text2);
					rec.Defaults.Add(d);
				}
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data || p.Default.IsEmpty || IsLiteral(p.Default) || savedDefaults.ContainsKey(p) || t.FindLinkTo(p) != null)
						continue;
					OrphanLinkRec d = new .();
					d.NodeKey.Set(n.Key);
					d.Pin.Set(p.Name);
					d.Default.Set(p.Default);
					rec.Defaults.Add(d);
				}
			}

			CodeGen gen = scope .(t, indentUnit, allman);
			gen.GenerateBody(braceIndent, rec.Code);
			return rec;
		}

		/// Number, string or char literal, true/false/null: these read back as the same default.
		static bool IsLiteral(StringView text)
		{
			var t = text;
			t.Trim();
			if (t.IsEmpty)
				return true;
			if (t == "true" || t == "false" || t == "null")
				return true;
			let c = t[0];
			if (c == '"' || c == '\'' || CharUtil.IsDigit(c))
				return true;
			if ((c == '-' || c == '+') && t.Length > 1 && CharUtil.IsDigit(t[1]))
				return true;
			return false;
		}

		// ------------------------------------------------------------------ load

		/// Parses the record's code as the body of `method` (in the context of the whole file, so
		/// fields, parameters and sibling methods resolve as in the real body) and adds the nodes
		/// to `graph` as unconnected nodes. Whatever can't be matched is dropped; never fails.
		/// Returns the number of nodes added. `graph` must have its keys assigned.
		public static int Restore(Graph graph, OrphanRecord rec, CompilationUnit unit, Member method)
		{
			let body = method.Body;
			if (body == null || !body.HasSpan || body.CloseTok < 0 || rec.Code.IsEmpty)
				return 0;
			String text = scope .();
			text.Append(StringView(unit.Text, 0, unit.Tokens[body.FirstTok].End));
			text.Append(rec.Code);
			// Keep the code from running into the closing brace's line.
			if (!rec.Code.EndsWith('\n') && !rec.Code.EndsWith('\t') && !rec.Code.EndsWith(' '))
				text.Append('\n');
			text.Append(StringView(unit.Text, unit.Tokens[body.CloseTok].Start));

			let unit2 = Parser.Parse(text);
			defer delete unit2;
			List<Member> methods = scope .();
			List<Member> owners = scope .();
			unit2.CollectMethods(methods, owners);
			Member m2 = null;
			Member o2 = null;
			String key = scope .();
			for (int i < methods.Count)
			{
				key.Clear();
				GraphBuilder.MakeMethodKey(methods[i], owners[i], key);
				if (key == graph.MethodKey && methods[i].Body != null)
				{
					m2 = methods[i];
					o2 = owners[i];
					break;
				}
			}
			if (m2 == null)
				return 0;

			let s = GraphBuilder.Build(unit2, m2, o2);
			defer delete s;
			if (s.Entry == null)
				return 0;
			KeyAssigner.Assign(s);

			// Markers: chain separators go, value markers leave their value behind.
			List<Node> markers = scope .();
			List<(String key, String text)> literalRoots = scope .();
			defer { for (let r in literalRoots) { delete r.key; delete r.text; } }
			for (let n in s.Nodes)
			{
				if (n.Kind == .Call && !n.IsPure && n.Text == ChainMarker && n.FindInput("target") == null)
					markers.Add(n);
				else if (n.Kind == .LocalVar && n.Text == ValueMarker)
				{
					let v = n.FindInput("value");
					if (v != null && s.FindLinkTo(v) == null && !v.Default.IsEmpty)
						literalRoots.Add((new String(scope $"{n.Key}/value"), new String(v.Default)));
					markers.Add(n);
				}
			}
			for (let n in markers)
				s.RemoveNode(n);
			for (let r in literalRoots)
			{
				// A literal value reads back as a pin default; it was an Expression node.
				Node e = s.AddNode(.Expr);
				e.Text.Set(r.text);
				e.Key.Set(r.key);
				s.AddDataOut(e, "result", "");
			}
			s.DisconnectPin(s.Entry.Then);

			// Defaults that read back as nodes: drop those nodes, put the default back.
			for (let d in rec.Defaults)
			{
				Node owner = null;
				for (let n in s.Nodes)
					if (n != s.Entry && n.Key == d.NodeKey)
						owner = n;
				if (d.Pin == TempNamePin)
				{
					if (owner != null && owner.Kind == .Call && !owner.IsPure)
						owner.Text2.Set(d.Default);
					continue;
				}
				let pin = owner?.FindInput(d.Pin);
				if (pin == null || pin.Kind != .Data)
					continue;
				let link = s.FindLinkTo(pin);
				if (link != null)
				{
					if (!link.From.Owner.IsPure)
						continue;
					String prefix = scope $"{d.NodeKey}/{d.Pin}";
					List<Node> drop = scope .();
					for (let n in s.Nodes)
						if (n.Key == prefix || (n.Key.StartsWith(prefix) && n.Key.Length > prefix.Length && n.Key[prefix.Length] == '/'))
							drop.Add(n);
					if (!drop.Contains(link.From.Owner))
						s.Disconnect(link);
					for (let n in drop)
						s.RemoveNode(n);
				}
				pin.Default.Set(d.Default);
			}

			List<Node> nodes = scope .();
			Dictionary<StringView, int> byKey = scope .();
			for (let n in s.Nodes)
			{
				if (n == s.Entry)
					continue;
				byKey.TryAdd(n.Key, nodes.Count);
				nodes.Add(n);
				if (rec.Positions.TryGetAlt(n.Key, var matchKey, var pos))
				{
					n.X = pos.X;
					n.Y = pos.Y;
					n.HasPos = true;
				}
				else
					n.HasPos = false;
			}
			if (nodes.IsEmpty)
				return 0;

			let set = OrphanSet.CaptureNodes(s, nodes);
			defer delete set;
			set.MethodKey.Set(graph.MethodKey);
			for (let el in set.External)
			{
				delete el.OrphanPin;
				delete el.OtherKey;
				delete el.OtherPin;
			}
			set.External.Clear();
			for (let l in rec.Links)
			{
				if (!l.External)
					continue;
				if (!byKey.TryGetValue(l.NodeKey, let idx))
					continue;
				OrphanSet.ExternalLink el;
				el.OrphanNode = idx;
				el.OrphanPin = new .(l.Pin);
				el.OrphanIsFrom = l.NodeIsFrom;
				el.OtherKey = new .(l.OtherKey);
				el.OtherPin = new .(l.OtherPin);
				set.External.Add(el);
			}

			List<Node> added = scope .();
			set.InjectInto(graph, 0, 0, true, added);
			if (added.Count != nodes.Count)
				return added.Count;

			// Trivia: as for nodes disconnected while the editor runs, statements that keep their
			// place in a chain keep their exact surrounding text; chain heads are "moved".
			for (int i < added.Count)
			{
				Graph.CopyStr(ref added[i].LeadingComments, nodes[i].LeadingComments);
				Graph.CopyStr(ref added[i].TrailingComment, nodes[i].TrailingComment);
				Graph.CopyStr(ref added[i].RawLead, nodes[i].RawLead);
				Graph.CopyStr(ref added[i].RawTrail, nodes[i].RawTrail);
				added[i].Moved = nodes[i].Moved;
				for (let p in added[i].Outputs)
				{
					let sp = nodes[i].FindOutput(p.Name);
					if (sp != null)
						Graph.CopyStr(ref p.EndComments, sp.EndComments);
				}
			}

			for (let l in rec.Links)
			{
				if (!byKey.TryGetValue(l.NodeKey, let idx))
					continue;
				let node = added[idx];
				if (!l.External && byKey.TryGetValue(l.OtherKey, let otherIdx))
				{
					let other = added[otherIdx];
					let from = l.NodeIsFrom ? node.FindOutput(l.Pin) : other.FindOutput(l.OtherPin);
					let to = l.NodeIsFrom ? other.FindInput(l.OtherPin) : node.FindInput(l.Pin);
					if (from != null && to != null && from.Kind == to.Kind && (to.Kind == .Exec || graph.FindLinkTo(to) == null))
						graph.Connect(from, to);
				}
				if (!l.NodeIsFrom)
				{
					let pin = node.FindInput(l.Pin);
					if (pin != null && pin.Kind == .Data)
						pin.Default.Set(l.Default);
				}
			}
			for (let n in added)
				n.Edited = true;
			graph.Version++;
			return added.Count;
		}
	}
}
