using System;
using System.Collections;
using System.IO;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// Scripted editing scenarios that exercise the graph -> code direction the way the editor
	/// does: edit the graph, commit, check the generated Beef.
	static class EditTests
	{
		static int sFailures;

		const String cSample =
			"""
			using System;

			namespace Demo
			{
				class Player
				{
					public int mHealth = 100;

					public void TakeDamage(int amount)
					{
						// Apply damage
						mHealth -= amount;
						if (mHealth <= 0)
						{
							Die();
						}
					}

					public void Die()
					{
						Console.WriteLine("Player died");
					}
				}
			}

			""";

		static void Check(bool cond, StringView what)
		{
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		static MethodGraph Method(SourceDocument doc, StringView key)
		{
			let mg = doc.FindMethod(key);
			if (mg == null)
				Console.WriteLine("  (method {} not found)", key);
			return mg;
		}

		static Node FindNode(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		const String cMorph =
			"""
			using System;

			namespace Demo
			{
				class Unit
				{
					public int mValue;

					public int Compute(int a)
					{
						return a * 2;
					}

					public void Update()
					{
						mValue = 1;
						if (mValue > 0)
						{
							Console.WriteLine("positive");
						}
					}

					public void Other()
					{
						Console.WriteLine("other");
					}
				}
			}

			""";

		static Node FindById(Graph g, int32 id)
		{
			for (let n in g.Nodes)
				if (n.Id == id)
					return n;
			return null;
		}

		/// Scenario 24: undo removes placed nodes, whether or not the placement wrote any text.
		static void RunUndoPlaceScenarios()
		{
			Console.WriteLine("Scenario 24: undo removes placed nodes (connected, unconnected, no text written)");
			StringView[1] aName = .("a");
			StringView[1] intType = .("int");
			SourceDocument doc = scope .();
			doc.LoadFromText(cMorph, "Unit.bf");
			let g = Method(doc, "Unit.Update()").Graph;
			int baseNodes = g.Nodes.Count;
			int baseLinks = g.Links.Count;
			String original = scope .(doc.Text);

			// 1: an unconnected Branch (the hotkey click path): no text written.
			doc.PushUndo();
			let br = NodeFactory.Branch(g);
			br.X = 900;
			br.Y = 900;
			br.HasPos = true;
			int32 brId = br.Id;
			doc.Commit(Method(doc, "Unit.Update()"));
			Check(doc.Text == original, "unconnected Branch: the code is unchanged");

			// 2: a print wired after the entry with no value: the commit is refused (error), the text stays.
			doc.PushUndo();
			let g1 = Method(doc, "Unit.Update()").Graph;
			let pr = NodeFactory.Call(g1, "WriteLine", true, false, "Console", aName, intType, "void");
			pr.X = 1200;
			pr.Y = 900;
			pr.HasPos = true;
			int32 prId = pr.Id;
			doc.Commit(Method(doc, "Unit.Update()"));

			// 3: a connected call that does write text.
			doc.PushUndo();
			let g2 = Method(doc, "Unit.Update()").Graph;
			let call = NodeFactory.Call(g2, "Compute", true, false, "", aName, intType, "int");
			call.FindInput("arg0").Default.Set("4");
			call.X = 321;
			call.Y = 123;
			call.HasPos = true;
			g2.Connect(g2.Entry.Then, call.ExecIn);
			int32 callId = call.Id;
			doc.Commit(Method(doc, "Unit.Update()"));
			String afterCall = scope .(doc.Text);
			Check(afterCall != original, "connected call: text written");

			// Undo until the document has nothing left to undo, counting steps; check at each step.
			doc.Undo();
			var gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, callId) == null && FindById(gu, brId) != null && FindById(gu, prId) != null && doc.Text == original, "undo 1: the call is gone, text back, Branch and print still there");
			doc.Undo();
			gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, prId) == null && FindById(gu, brId) != null && doc.Text == original, "undo 2: the print placed without a value is gone");
			doc.Undo();
			gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, brId) == null && gu.Nodes.Count == baseNodes && gu.Links.Count == baseLinks && doc.Text == original, "undo 3: the unconnected Branch is gone, the graph is as loaded");

			doc.Redo();
			gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, brId) != null && FindById(gu, prId) == null && doc.Text == original, "redo 1: the Branch is back");
			doc.Redo();
			gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, prId) != null && doc.Text == original, "redo 2: the print is back");
			doc.Redo();
			gu = Method(doc, "Unit.Update()").Graph;
			Check(FindById(gu, callId) != null && doc.Text == afterCall, "redo 3: the call is back, text written again");
		}

		/// Nodes must never change into other nodes on their own: commits, undo and redo keep the
		/// live graph, and code written for action-menu nodes reads back as the same nodes.
		static void RunMorphScenarios()
		{
			StringView[1] aName = .("a");
			StringView[1] intType = .("int");

			Console.WriteLine("Scenario 12: a commit keeps the live graph and its nodes");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cMorph, "Unit.bf");
				let mg = Method(doc, "Unit.Update()");
				let g = mg.Graph;
				let other = Method(doc, "Unit.Other()").Graph;
				let set = FindNode(g, .Set);
				doc.PushUndo();
				StringView[0] none = .();
				let call = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
				NodeFactory.AddArgument(g, call).Default.Set("\"start\"");
				g.Connect(g.Entry.Then, call.ExecIn);
				g.Connect(call.Then, set.ExecIn);
				doc.Commit(mg);
				let mg2 = Method(doc, "Unit.Update()");
				Check(mg2.Graph == g, "edited graph object survives the commit");
				Check(Method(doc, "Unit.Other()").Graph == other, "other built graphs survive the commit");
				Check(g.Nodes.Contains(call) && call.Kind == .Call && call.Text == "WriteLine" && call.Binding == .Static && call.Qualifier == "Console",
					"placed Console.WriteLine node is still that node");
				Check(mg2.Method.Body != null && mg2.Graph.Entry.Text == "Update", "MethodGraph points into the new parse");
				Check(doc.Text.Contains("{\n\t\t\tConsole.WriteLine(\"start\");\n\t\t\tmValue = 1;"), "call written first");

				// Lines follow the new text: the set moved down one line, Other() too.
				let fresh = GraphBuilder.Build(doc.Unit, mg2.Method, mg2.Owner);
				KeyAssigner.Assign(fresh);
				KeyAssigner.Assign(g);
				bool linesOk = true;
				for (let n in g.Nodes)
				{
					for (let f in fresh.Nodes)
						if (f.Key == n.Key && (f.Line != n.Line || f.LineEnd != n.LineEnd))
							linesOk = false;
				}
				delete fresh;
				Check(linesOk, "node lines refreshed from the new parse");
				let otherCall = FindNode(other, .Call, "WriteLine");
				Check(otherCall != null && otherCall.Line == 26, scope $"lines of other graphs shifted (line {otherCall?.Line})");
				Check(!call.Edited && call.Original == "Console.WriteLine(\"start\")" + ";", "node confirmed by the re-parse is clean with fresh original text");

				// Insert-then-remove gives back the original text exactly.
				doc.PushUndo();
				g.RemoveNode(call);
				g.Connect(g.Entry.Then, set.ExecIn);
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text == cMorph, "removing the node restores the original text exactly");
			}

			Console.WriteLine("Scenario 13: edited nodes don't reuse stale text");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cMorph, "Unit.bf");
				let g = Method(doc, "Unit.Update()").Graph;
				let cmp = FindNode(g, .Operator, ">");
				let branch = FindNode(g, .Branch);
				doc.PushUndo();
				cmp.FindInput("b").Default.Set("10");
				cmp.Edited = true;
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text.Contains("if (mValue > 10)"), "condition rewritten");
				Check(!branch.Edited && branch.Original != null && branch.Original.Contains("mValue > 10"), "branch takes the new original text");
				// Edit something else: the branch is reused verbatim and must not revert.
				let set = FindNode(g, .Set);
				doc.PushUndo();
				set.FindInput("value").Default.Set("2");
				set.Edited = true;
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text.Contains("mValue = 2;") && doc.Text.Contains("if (mValue > 10)"), "earlier edit kept by a later commit");
			}

			Console.WriteLine("Scenario 14: impure call with a used value but no exec stays impure");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cMorph, "Unit.bf");
				let g = Method(doc, "Unit.Update()").Graph;
				let set = FindNode(g, .Set);
				doc.PushUndo();
				let call = NodeFactory.Call(g, "Compute", true, false, "", aName, intType, "int");
				call.FindInput("arg0").Default.Set("3");
				g.Connect(call.Result, set.FindInput("value"));
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text.Contains("mValue = Compute(3);"), "value computed where it is used");
				Check(!doc.Messages.IsEmpty, "warning about the unconnected call");
				let g2 = Method(doc, "Unit.Update()").Graph;
				Check(g2 == g && g.Nodes.Contains(call) && !call.IsPure && call.ExecIn != null && call.Then != null, "node is still the impure call");
				// Connect it to the flow: now it's a statement with a temp, still the same node.
				doc.PushUndo();
				g.Connect(g.Entry.Then, call.ExecIn);
				g.Connect(call.Then, set.ExecIn);
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text.Contains("let computeResult = Compute(3);\n\t\t\tmValue = computeResult;"), "temp written for the connected call");
				Check(g.Nodes.Contains(call) && !call.IsPure && g.DataSource(set.FindInput("value")) == call, "same impure call, result still wired");
				// Reopening the file shows the same impure call, not a local variable.
				SourceDocument reopened = scope .();
				reopened.LoadFromText(doc.Text, "Unit.bf");
				let rg = Method(reopened, "Unit.Update()").Graph;
				let rcall = FindNode(rg, .Call, "Compute");
				let rset = FindNode(rg, .Set);
				Check(FindNode(rg, .LocalVar) == null && rcall != null && !rcall.IsPure && rg.DataSource(rset.FindInput("value")) == rcall,
					"reopened: `let computeResult = Compute(3);` is the impure Call with its result wired");
				// Disconnecting the value turns it back into a plain call statement.
				doc.PushUndo();
				g.DisconnectPin(call.Result);
				set.FindInput("value").Default.Set("0");
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text.Contains("\t\t\tCompute(3);\n\t\t\tmValue = 0;"), "no temp once the value is unused");
				Check(g.Nodes.Contains(call) && !call.IsPure, "still the same impure call");
			}

			Console.WriteLine("Scenario 15: undo / redo restore the exact graph");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cMorph, "Unit.bf");
				let g = Method(doc, "Unit.Update()").Graph;
				let set = FindNode(g, .Set);
				doc.PushUndo();
				let call = NodeFactory.Call(g, "Compute", true, false, "", aName, intType, "int");
				call.FindInput("arg0").Default.Set("4");
				call.X = 321;
				call.Y = 123;
				call.HasPos = true;
				g.Connect(g.Entry.Then, call.ExecIn);
				g.Connect(call.Then, set.ExecIn);
				g.Connect(call.Result, set.FindInput("value"));
				// An unconnected impure node too.
				let loose = NodeFactory.Call(g, "Compute", true, false, "", aName, intType, "int");
				loose.X = 50;
				loose.Y = 700;
				loose.HasPos = true;
				int32 callId = call.Id;
				int32 looseId = loose.Id;
				int32 resultPinId = call.Result.Id;
				doc.Commit(Method(doc, "Unit.Update()"));
				String afterAdd = scope .(doc.Text);
				int nodeCount = g.Nodes.Count;
				int linkCount = g.Links.Count;

				doc.PushUndo();
				set.FindInput("value").Default.Set("7");
				g.DisconnectPin(call.Result);
				doc.Commit(Method(doc, "Unit.Update()"));

				doc.Undo();
				let gu = Method(doc, "Unit.Update()").Graph;
				let callU = FindById(gu, callId);
				let looseU = FindById(gu, looseId);
				Check(doc.Text == afterAdd, "undo restores the text");
				Check(gu.Nodes.Count == nodeCount && gu.Links.Count == linkCount, "undo restores the same nodes and links");
				Check(callU != null && callU.Kind == .Call && !callU.IsPure && callU.X == 321 && callU.Result.Id == resultPinId &&
					gu.FindLinkFrom(callU.Result) != null, "undo brings back the impure call (same id, position, wired result)");
				Check(looseU != null && looseU.Kind == .Call && !looseU.IsPure && looseU.X == 50 && looseU.Y == 700, "unconnected node restored with its id");

				doc.Undo();
				let g0 = Method(doc, "Unit.Update()").Graph;
				Check(doc.Text == cMorph && FindById(g0, callId) == null && FindById(g0, looseId) == null, "second undo removes them");

				doc.Redo();
				let gr = Method(doc, "Unit.Update()").Graph;
				let callR = FindById(gr, callId);
				Check(doc.Text == afterAdd && callR != null && !callR.IsPure && FindById(gr, looseId) != null, "redo restores the exact nodes");
				// The restored graph keeps working: an identity commit leaves the text alone.
				doc.PushUndo();
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text == afterAdd, "identity commit after redo");
			}

			Console.WriteLine("Scenario 16: temps in real code");
			{
				SourceDocument doc = scope .();
				String text = scope .(cMorph);
				text.Replace("\t\t\tmValue = 1;\n", "\t\t\tlet computeResult = Compute(1);\n\t\t\tmValue = computeResult + computeResult.GetHashCode();\n\t\t\tlet keepResult = Compute(2);\n\t\t\tConsole.WriteLine($\"{keepResult}\");\n");
				doc.LoadFromText(text, "Unit.bf");
				let g = Method(doc, "Unit.Update()").Graph;
				let call = FindNode(g, .Call, "Compute");
				int links = 0;
				for (let l in g.Links)
					if (l.From == call?.Result)
						links++;
				Check(call != null && !call.IsPure && call.Text2 == "computeResult" && links == 2, "`let computeResult = Compute(1);` folds into the call");
				Node keep = null;
				for (let n in g.Nodes)
					if (n.Kind == .Call && n.Text2 == "keepResult")
						keep = n;
				let fmt = FindNode(g, .Format);
				Check(keep != null && keep.Text2 == "keepResult" && fmt != null && g.DataSource(fmt.FindInput("arg0")) == keep,
					"a temp read inside a string's hole folds too: the hole is a wire from the call");
				for (let n in g.Nodes)
					n.Edited = true;
				doc.Commit(Method(doc, "Unit.Update()"));
				Check(doc.Text == text, "regenerated temps reproduce the text");
			}

			Console.WriteLine("Scenario 17: text edits and renames keep unrelated graphs");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cMorph, "Unit.bf");
				let gUpdate = Method(doc, "Unit.Update()").Graph;
				Check(Method(doc, "Unit.Other()").Graph != null, "Other() graph built");
				String text = scope .(doc.Text);
				text.Replace("Console.WriteLine(\"other\");", "Console.WriteLine(\"changed\");");
				doc.ApplyText(text);
				Check(Method(doc, "Unit.Update()").Graph == gUpdate, "unchanged method keeps its graph on a text edit");
				let gOther2 = Method(doc, "Unit.Other()").Graph;
				// (The old graph is freed, so its address may be reused: compare content.)
				Check(FindNode(gOther2, .Call).FindInput("arg0").Default == "\"changed\"", "edited method is rebuilt from the text");
				doc.RenameMember(Method(doc, "Unit.Update()").Method, "Tick");
				let mgTick = Method(doc, "Unit.Tick()");
				Check(mgTick != null && mgTick.Graph == gUpdate && gUpdate.MethodKey == "Unit.Tick()" && gUpdate.Entry.Text == "Tick", "rename keeps and re-keys the graph");
				doc.SetSignature(mgTick.Method, "void", "int speed");
				let mgSig = Method(doc, "Unit.Tick(int)");
				Check(mgSig != null && mgSig.Graph == gUpdate && gUpdate.Entry.FindOutput("param0")?.Label == "speed", "signature change keeps the graph and updates the entry pins");
				let type = doc.Unit.Members[1].Members[0];
				doc.AddField(type, "float", "mSpeed");
				Check(Method(doc, "Unit.Tick(int)").Graph == gUpdate, "adding a field keeps graphs");
				doc.Undo();
				Check(Method(doc, "Unit.Tick(int)").Graph.Entry.Text == "Tick" && !doc.Text.Contains("mSpeed"), "undo of the field");
			}
		}

		const String cAssets =
			"""
			using System;

			namespace Demo
			{
				enum Color
				{
					Red, // warm
					Green = 4,
					// cool
					Blue
				}

				enum Mode : uint8 { A, B }

				enum WithMethods
				{
					One,
					Two;

					public bool IsOne => this == .One;
				}

				struct Point
				{
					public int X;
					public float Y = 0;

					public int Sum()
					{
						return X;
					}
				}
			}

			""";

		static Member FindTypeIn(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		static void RunAssetScenarios()
		{
			Console.WriteLine("Asset scenarios (enum editor, type rename, field type)");
			SourceDocument doc = scope .();
			doc.LoadFromText(cAssets);

			List<EnumCase> cases = scope .();
			defer { ClearAndDeleteItems!(cases); }
			Check(EnumCases.Parse(doc.Unit, FindTypeIn(doc, "Color"), cases), "simple enum parses");
			Check(cases.Count == 3 && cases[0].Name == "Red" && cases[0].Comment == "warm" && cases[1].Value == "4" && cases[2].Comment == "cool",
				"names, values and comments read");
			// Unchanged write is a no-op.
			String before = scope .(doc.Text);
			doc.SetEnumCases(FindTypeIn(doc, "Color"), cases);
			Check(doc.Text == before || doc.Text.Contains("\t\tRed, // warm\n\t\tGreen = 4,\n\t\tBlue // cool\n\t}"), "rewrite of unchanged cases is clean");
			cases.Add(new EnumCase("Yellow", "", "new one"));
			let tmp = cases[0];
			cases[0] = cases[1];
			cases[1] = tmp;
			doc.SetEnumCases(FindTypeIn(doc, "Color"), cases);
			Check(doc.Text.Contains("\tenum Color\n\t{\n\t\tGreen = 4,\n\t\tRed, // warm\n\t\tBlue, // cool\n\t\tYellow // new one\n\t}\n"), "cases reordered and added");
			Check(doc.Text.Contains("enum Mode : uint8 { A, B }"), "other enums untouched");

			ClearAndDeleteItems!(cases);
			Check(EnumCases.Parse(doc.Unit, FindTypeIn(doc, "Mode"), cases) && cases.Count == 2, "single-line enum parses");
			cases.Add(new EnumCase("C", "8"));
			doc.SetEnumCases(FindTypeIn(doc, "Mode"), cases);
			Check(doc.Text.Contains("enum Mode : uint8 {\n\t\tA,\n\t\tB,\n\t\tC = 8\n\t}"), "single-line enum expanded");

			ClearAndDeleteItems!(cases);
			Check(EnumCases.Parse(doc.Unit, FindTypeIn(doc, "WithMethods"), cases) && cases.Count == 2, "enum with members parses");
			delete cases.PopBack();
			doc.SetEnumCases(FindTypeIn(doc, "WithMethods"), cases);
			Check(doc.Text.Contains("\t{\n\t\tOne;\n\n\t\tpublic bool IsOne => this == .One;"), "case removed, members kept");
			doc.Undo();
			Check(doc.Text.Contains("\t\tOne,\n\t\tTwo;"), "enum edit undoes");

			// Field type change and type rename
			let point = FindTypeIn(doc, "Point");
			Member yField = null;
			for (let m in point.Members)
				if (m.Name == "Y")
					yField = m;
			Check(doc.SetMemberType(yField, "double") && doc.Text.Contains("public double Y = 0;"), "field retyped");
			let sum = Method(doc, "Point.Sum()");
			for (let n in sum.Graph.Nodes)
				n.X = 555;
			doc.RenameType(FindTypeIn(doc, "Point"), "Vec2");
			Check(doc.Text.Contains("struct Vec2\n"), "type renamed");
			let sum2 = Method(doc, "Vec2.Sum()");
			Check(sum2 != null && sum2.Graph.Entry.X == 555, "method layout follows the type rename");
		}

		const String cOrphan =
			"""
			using System;

			namespace Demo
			{
				class Hero
				{
					public int mHp;

					public int Heal(int amount)
					{
						// Remember the old value
						int before = mHp;
						mHp = mHp + amount * 2;
						Console.WriteLine("healed");
						if (mHp > 100)
						{
							mHp = 100;
						}
						return mHp - before;
					}

					public void Tick()
					{
						int step = 1;
						mHp = mHp + step;
					}
				}
			}

			""";

		/// The unconnected nodes of a graph, in position order: kind, texts, position, pin
		/// defaults, and links (to other orphans by index, to connected nodes by key).
		public static void OrphanSig(Graph g, String o)
		{
			KeyAssigner.Assign(g);
			HashSet<Node> reach = scope .();
			g.GetReachable(reach);
			List<Node> orphans = scope .();
			for (let n in g.Nodes)
				if (!reach.Contains(n))
					orphans.Add(n);
			orphans.Sort(scope (a, b) =>
				{
					if ((int)a.X != (int)b.X)
						return (int)a.X - (int)b.X;
					return (int)a.Y - (int)b.Y;
				});
			for (let n in orphans)
			{
				o.AppendF("{} [{}] [{}] @{},{}{}{}\n", n.Kind, n.Text, (n.Kind == .Call) ? "" : n.Text2, (int)n.X, (int)n.Y,
					(n.LeadingComments != null) ? " +lc:" : "", n.LeadingComments ?? "");
				if (n.Kind == .Call)
					o.AppendF("  binding {}{}\n", n.Binding, (n.Qualifier != null) ? scope:: $" {n.Qualifier}" : "");
				for (let p in n.Outputs)
					if (p.IsOutArg)
						o.AppendF("  out {} -> {} ({})\n", p.Name, p.OutName, p.Form);
				for (let p in n.Inputs)
				{
					if (p.Kind == .Exec)
						continue;
					let l = g.FindLinkTo(p);
					if (l == null)
						o.AppendF("  {} = {}\n", p.Name, p.Default);
					else
					{
						int idx = orphans.IndexOf(l.From.Owner);
						if (idx >= 0)
							o.AppendF("  {} <- #{}.{} ({})\n", p.Name, idx, l.From.Name, p.Default);
						else
							o.AppendF("  {} <- {}.{} ({})\n", p.Name, l.From.Owner.Key, l.From.Name, p.Default);
					}
				}
				for (let p in n.Outputs)
				{
					if (p.Kind != .Exec)
						continue;
					for (let l in g.Links)
					{
						if (l.From != p)
							continue;
						int idx = orphans.IndexOf(l.To.Owner);
						if (idx >= 0)
							o.AppendF("  {} -> #{}\n", p.Name, idx);
						else
							o.AppendF("  {} -> {}\n", p.Name, l.To.Owner.Key);
					}
				}
			}
		}

		public static int OrphanCount(Graph g)
		{
			HashSet<Node> reach = scope .();
			g.GetReachable(reach);
			return g.Nodes.Count - reach.Count;
		}

		public static void PlaceAll(Graph g)
		{
			for (let n in g.Nodes)
			{
				n.X = 100 + 37 * @n.Index;
				n.Y = 50 + 11 * @n.Index;
				n.HasPos = true;
			}
		}

		/// Unconnected nodes are saved in the layout side file and come back on reload.
		static void RunOrphanPersistScenarios()
		{
			Console.WriteLine("Scenario 18: a disconnected method body survives save / reload");
			// `var before` stays a node in the flow (a typed declaration at the top would be one of
			// Heal's Locals, which stay when the flow is disconnected).
			String cOrphanHeal = scope .(cOrphan);
			cOrphanHeal.Replace("int before = mHp;", "var before = mHp;");
			String layoutA = scope .();
			int healOrphans = 0;
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cOrphanHeal, "Hero.bf");
				let g = Method(doc, "Hero.Heal(int)").Graph;
				PlaceAll(g);
				doc.PushUndo();
				g.Disconnect(g.FindLinkFrom(g.Entry.Then));
				doc.Commit(Method(doc, "Hero.Heal(int)"));
				Check(!doc.Text.Contains("healed") && doc.Text.Contains("public int Heal(int amount)\n\t\t{\n\t\t}"), "body code is gone");
				String sigBefore = scope .();
				OrphanSig(g, sigBefore);
				healOrphans = OrphanCount(g);
				doc.GetLayoutText(layoutA);
				Check(layoutA.Contains("#orphans\tHero.Heal(int)\t") && !layoutA.Contains("#orphans\tHero.Tick()"), "record written for the method with orphans only");

				SourceDocument doc2 = scope .();
				doc2.LoadFromText(doc.Text, "Hero.bf", layoutA);
				let g2 = Method(doc2, "Hero.Heal(int)").Graph;
				String sigAfter = scope .();
				OrphanSig(g2, sigAfter);
				Check(OrphanCount(g2) == OrphanCount(g) && OrphanCount(g) == 16, scope $"orphan nodes restored ({OrphanCount(g2)} of {OrphanCount(g)})");
				Check(sigAfter == sigBefore, "same kinds, texts, positions, pin defaults, links and comments");
				if (sigAfter != sigBefore)
					Program.ShowDiff(sigBefore, sigAfter);
				Check(doc2.Text == doc.Text && doc2.OrphanRecords.IsEmpty, "loading changes no code; the record is consumed");

				// Reconnect: the code comes back exactly.
				Node head = null;
				for (let n in g2.Nodes)
					if (n.Kind == .LocalVar && n.Text == "before")
						head = n;
				doc2.PushUndo();
				g2.Connect(g2.Entry.Then, head.ExecIn);
				doc2.Commit(Method(doc2, "Hero.Heal(int)"));
				Check(doc2.Text == cOrphanHeal, "reconnecting restores the code exactly");
				if (doc2.Text != cOrphanHeal)
					Program.ShowDiff(cOrphanHeal, doc2.Text);
				String layoutC = scope .();
				doc2.GetLayoutText(layoutC);
				Check(!layoutC.Contains("#orphan"), "record removed once the method has no orphans");

				// Undo / redo: saving writes the orphans of the restored graphs.
				doc.Undo();
				String layoutU = scope .();
				doc.GetLayoutText(layoutU);
				Check(doc.Text == cOrphanHeal && !layoutU.Contains("#orphan"), "after undo: no orphans saved");
				doc.Redo();
				String layoutR = scope .();
				doc.GetLayoutText(layoutR);
				Check(layoutR.Contains("#orphans\tHero.Heal(int)\t"), "after redo: orphans saved again");

				// Through the real files: Save writes File.bf.vblayout, Load reads it.
				{
					const String path = "vb_orphan_test.bf";
					SourceDocument dd = scope .();
					dd.LoadFromText(doc.Text, path, layoutA);
					Check(dd.Save() case .Ok, "saved to disk");
					SourceDocument dl = scope .();
					Check(dl.Load(path) case .Ok, "loaded from disk");
					Check(OrphanCount(Method(dl, "Hero.Heal(int)").Graph) == healOrphans, "orphans restored from the side file on disk");
					File.Delete(path).IgnoreError();
					File.Delete("vb_orphan_test.bf.vblayout").IgnoreError();
				}

				// A record not built yet survives undo to before its graph was built.
				SourceDocument doc3 = scope .();
				doc3.LoadFromText(doc.Text, "Hero.bf", layoutA);
				doc3.PushUndo();
				Check(OrphanCount(Method(doc3, "Hero.Heal(int)").Graph) == healOrphans, "built from the record");
				doc3.AddField(doc3.Unit.Members[1].Members[0], "int", "mMana");
				doc3.Undo();
				doc3.Undo();
				Check(OrphanCount(Method(doc3, "Hero.Heal(int)").Graph) == healOrphans, "undo to before the build brings the record back");

				// Orphans of a graph dropped by a text edit (kept aside, not built) are saved too.
				String edited = scope .(doc.Text);
				edited.Replace("public int Heal(int amount)\n\t\t{\n\t\t}", "public int Heal(int amount)\n\t\t{\n\t\t\tmHp = 0;\n\t\t}");
				doc.ApplyText(edited);
				Check(!Method(doc, "Hero.Heal(int)").IsBuilt && !doc.Orphans.IsEmpty, "graph dropped, orphans kept aside");
				String layoutP = scope .();
				doc.GetLayoutText(layoutP);
				SourceDocument doc4 = scope .();
				doc4.LoadFromText(doc.Text, "Hero.bf", layoutP);
				let g4 = Method(doc4, "Hero.Heal(int)").Graph;
				Check(OrphanCount(g4) == healOrphans && FindNode(g4, .Branch) != null && FindNode(g4, .Return) != null, "pending orphans saved and restored");
			}

			Console.WriteLine("Scenario 19: orphan pure nodes, wires between orphans, lone values");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cOrphan, "Hero.bf");
				let g = Method(doc, "Hero.Tick()").Graph;
				doc.PushUndo();
				let tmp = NodeFactory.LocalVar(g, "tmp", "int");
				tmp.FindInput("value").Default.Set("5");
				let set = NodeFactory.Set(g, "mHp", "int");
				g.Connect(tmp.Then, set.ExecIn);
				let add = NodeFactory.Operator(g, "+", true);
				let get = NodeFactory.Get(g, "mHp", "int");
				g.Connect(tmp.FindOutput("variable"), add.FindInput("a"));
				g.Connect(get.Result, add.FindInput("b"));
				g.Connect(add.Result, set.FindInput("value"));
				NodeFactory.Get(g, "mHp", "int");
				NodeFactory.Expr(g, "42");
				let mul = NodeFactory.Operator(g, "*", true);
				mul.FindInput("a").Default.Set("amount");
				mul.FindInput("b").Default.Set("3");
				PlaceAll(g);
				doc.Commit(Method(doc, "Hero.Tick()"));
				Check(doc.Text == cOrphan, "orphans generate no code");
				String sigBefore = scope .();
				OrphanSig(g, sigBefore);
				String layout = scope .();
				doc.GetLayoutText(layout);
				Check(layout.Contains("#orphanlink\tHero.Tick()\torphan\t"), "local -> operator wire stored as a link");

				SourceDocument doc2 = scope .();
				doc2.LoadFromText(doc.Text, "Hero.bf", layout);
				let g2 = Method(doc2, "Hero.Tick()").Graph;
				String sigAfter = scope .();
				OrphanSig(g2, sigAfter);
				Check(OrphanCount(g2) == 7 && sigAfter == sigBefore, "pure nodes, statement chain, wire and lone values restored");
				if (sigAfter != sigBefore)
					Program.ShowDiff(sigBefore, sigAfter);
				Node add2 = null;
				for (let n in g2.Nodes)
					if (n.Kind == .Operator && n.Text == "+" && (int)n.X == (int)add.X && (int)n.Y == (int)add.Y)
						add2 = n;
				let src = (add2 != null) ? g2.DataSource(add2.FindInput("a")) : null;
				Check(src != null && src.Kind == .LocalVar && src.Text == "tmp", "operator still reads the local's output pin (not a Get)");

				// Wire it in: entry -> tmp -> set -> (old first statement)
				doc2.PushUndo();
				let tmp2 = FindNode(g2, .LocalVar, "tmp");
				let first = g2.ExecTarget(g2.Entry.Then);
				Node set2 = null;
				for (let n in g2.Nodes)
					if (n.Kind == .Set && g2.DataSource(n.FindInput("value")) == add2)
						set2 = n;
				g2.Connect(g2.Entry.Then, tmp2.ExecIn);
				g2.Connect(set2.Then, first.ExecIn);
				doc2.Commit(Method(doc2, "Hero.Tick()"));
				// `int step = 1;` is one of Tick's Locals: written first, then the flow from Entry.
				Check(doc2.Text.Contains("{\n\t\t\tint step = 1;\n\t\t\tint tmp = 5;\n\t\t\tmHp = tmp + mHp;\n"), "reconnected chain generates its code (after the Locals)");
			}

			Console.WriteLine("Scenario 20: orphans linked to connected nodes");
			String layoutExt = scope .();
			String textExt = scope .();
			// `var step` is a Local Variable node in the flow (a `var` declaration is not one of
			// the function's Locals), so its output pin can be wired.
			String cOrphanVar = scope .(cOrphan);
			cOrphanVar.Replace("int step = 1;", "var step = 1;");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cOrphanVar, "Hero.bf");
				let g = Method(doc, "Hero.Tick()").Graph;
				doc.PushUndo();
				let local = FindNode(g, .LocalVar, "step");
				let set = FindNode(g, .Set);
				StringView[1] names = .("value");
				StringView[1] types = .("String");
				let call = NodeFactory.Call(g, "Console.WriteLine", true, false, "", names, types, "void");
				call.FindInput("arg0").Default.Set("\"fallback\"");
				g.Connect(local.FindOutput("variable"), call.FindInput("arg0"));
				g.Connect(call.Then, set.ExecIn); // a second exec link into a connected statement
				let neg = NodeFactory.Operator(g, "-", false);
				g.Connect(local.FindOutput("variable"), neg.FindInput("a"));
				PlaceAll(g);
				doc.Commit(Method(doc, "Hero.Tick()"));
				Check(doc.Text == cOrphanVar, "orphans generate no code");
				String sigBefore = scope .();
				OrphanSig(g, sigBefore);
				doc.GetLayoutText(layoutExt);
				textExt.Set(doc.Text);
				Check(layoutExt.Contains("#orphanlink\tHero.Tick()\tgraph\t"), "external links stored");

				SourceDocument doc2 = scope .();
				doc2.LoadFromText(doc.Text, "Hero.bf", layoutExt);
				let g2 = Method(doc2, "Hero.Tick()").Graph;
				String sigAfter = scope .();
				OrphanSig(g2, sigAfter);
				Check(OrphanCount(g2) == 2 && sigAfter == sigBefore, "orphans re-linked to the connected nodes");
				if (sigAfter != sigBefore)
					Program.ShowDiff(sigBefore, sigAfter);
				let call2 = FindNode(g2, .Call, "WriteLine");
				Check(call2 != null && g2.DataSource(call2.FindInput("arg0"))?.Text == "step" && call2.FindInput("arg0").Default == "\"fallback\"",
					"input fed by the connected local, own default kept");
				Check(call2 != null && g2.ExecTarget(call2.Then) == FindNode(g2, .Set), "exec link into the connected statement restored");
				doc2.PushUndo();
				doc2.Commit(Method(doc2, "Hero.Tick()"));
				Check(doc2.Text == cOrphanVar, "identity commit with restored orphans");
			}

			Console.WriteLine("Scenario 21: broken records never fail the load");
			{
				String broken = scope .(layoutExt);
				// Retarget the external links to keys that don't exist.
				String fixedLinks = scope .();
				for (let line in broken.Split('\n'))
				{
					if (line.IsEmpty)
						continue;
					String l = scope .(line);
					if (l.StartsWith("#orphanlink"))
					{
						List<StringView> f = scope .();
						for (let part in line.Split('\t'))
							f.Add(part);
						l.Clear();
						for (int i < f.Count)
						{
							if (i > 0)
								l.Append('\t');
							l.Append((i == 6) ? "s99" : f[i]);
						}
					}
					fixedLinks.Append(l);
					fixedLinks.Append('\n');
				}
				SourceDocument doc = scope .();
				doc.LoadFromText(textExt, "Hero.bf", fixedLinks);
				let g = Method(doc, "Hero.Tick()").Graph;
				let call = FindNode(g, .Call, "WriteLine");
				Check(OrphanCount(g) == 2 && call != null && g.FindLinkTo(call.FindInput("arg0")) == null && call.FindInput("arg0").Default == "\"fallback\"",
					"nodes kept, unmatched links dropped");

				String garbage = scope .();
				garbage.Append("#orphans\tHero.Tick()\t}}} {{ (( if while = ;;\\n\\t)\n#orphanpos\tHero.Tick()\ts0\tx\t\n#orphanlink\tHero.Tick()\tgraph\ts9\targ0\tin\n");
				garbage.Append("#orphans\tHero.Heal(int)\tint x = ;\\nFoo(\n#orphanlink\tHero.Heal(int)\torphan\ts0\tvalue\tin\ts5\tvariable\t\n");
				SourceDocument doc2 = scope .();
				doc2.LoadFromText(cOrphan, "Hero.bf", garbage);
				let gt = Method(doc2, "Hero.Tick()").Graph;
				let gh = Method(doc2, "Hero.Heal(int)").Graph;
				Check(gt != null && gh != null && FindNode(gt, .Set) != null, "garbage records load without failing");
				doc2.PushUndo();
				doc2.Commit(Method(doc2, "Hero.Tick()"));
				doc2.PushUndo();
				doc2.Commit(Method(doc2, "Hero.Heal(int)"));
				Check(doc2.Text == cOrphan, "code untouched by garbage records");
			}

			Console.WriteLine("Scenario 22: orphans follow renames and signature changes");
			{
				// Unbuilt: the record is re-keyed.
				SourceDocument doc = scope .();
				String bodyless = scope .();
				{
					SourceDocument d0 = scope .();
					d0.LoadFromText(cOrphan, "Hero.bf");
					let g0 = Method(d0, "Hero.Heal(int)").Graph;
					d0.PushUndo();
					g0.Disconnect(g0.FindLinkFrom(g0.Entry.Then));
					d0.Commit(Method(d0, "Hero.Heal(int)"));
					bodyless.Set(d0.Text);
				}
				doc.LoadFromText(bodyless, "Hero.bf", layoutA);
				doc.RenameMember(Method(doc, "Hero.Heal(int)").Method, "Mend");
				Check(doc.OrphanRecords.Count == 1 && doc.OrphanRecords[0].MethodKey == "Hero.Mend(int)", "unbuilt record re-keyed by the rename");
				let g = Method(doc, "Hero.Mend(int)").Graph;
				Check(OrphanCount(g) == healOrphans, "orphans restored under the new name");
				// Built: the graph is re-keyed and saving writes the new key.
				doc.SetSignature(Method(doc, "Hero.Mend(int)").Method, "int", "int amount, int bonus");
				String layout = scope .();
				doc.GetLayoutText(layout);
				Check(layout.Contains("#orphans\tHero.Mend(int,int)\t") && !layout.Contains("Hero.Heal(int)\t") && !layout.Contains("#orphans\tHero.Mend(int)\t"),
					"saved under the new signature");
				SourceDocument doc2 = scope .();
				doc2.LoadFromText(doc.Text, "Hero.bf", layout);
				Check(OrphanCount(Method(doc2, "Hero.Mend(int,int)").Graph) == healOrphans, "reloaded after rename + signature change");
				// Type rename of an unbuilt method's record.
				SourceDocument doc3 = scope .();
				doc3.LoadFromText(doc.Text, "Hero.bf", layout);
				doc3.RenameType(FindTypeIn(doc3, "Hero"), "Champion");
				Check(doc3.OrphanRecords.Count == 1 && doc3.OrphanRecords[0].MethodKey == "Champion.Mend(int,int)", "record follows a type rename");
				Check(OrphanCount(Method(doc3, "Champion.Mend(int,int)").Graph) == healOrphans, "orphans restored after the type rename");

				// Deleting the method deletes its saved orphans; undo brings them back.
				for (int built < 2)
				{
					SourceDocument doc4 = scope .();
					doc4.LoadFromText(bodyless, "Hero.bf", layoutA);
					if (built == 1)
						Check(OrphanCount(Method(doc4, "Hero.Heal(int)").Graph) == healOrphans, "built before the delete");
					doc4.DeleteMember(Method(doc4, "Hero.Heal(int)").Method);
					String l1 = scope .();
					doc4.GetLayoutText(l1);
					Check(Method(doc4, "Hero.Heal(int)") == null && !l1.Contains("#orphan"), scope $"deleted method leaves no record (built: {built})");
					doc4.Undo();
					String l2 = scope .();
					doc4.GetLayoutText(l2);
					Check(l2.Contains("#orphans\tHero.Heal(int)\t") && OrphanCount(Method(doc4, "Hero.Heal(int)").Graph) == healOrphans, scope $"undo of the delete restores them (built: {built})");
				}
			}
		}

		const String cTypes =
			"""
			using System;

			namespace Demo
			{
				class Foo
				{
					public int A;
				}

				class Bar
				{
					public int A;
				}

				class Unit
				{
					public void Make()
					{
						let a = scope Foo();
						Bar b = .();
						var c = Get();
						Console.WriteLine(a.A + b.A);
						Console.WriteLine(c);
					}

					public Foo Get()
					{
						return null;
					}
				}
			}

			""";

		/// Scenario 23: a type changed in Properties (or in a signature elsewhere in the file)
		/// reaches the kept graph's pins at once: a local's variable pin, the value it holds, the
		/// header colour that comes from them. Undo restores the old types.
		static StringView VarType(Node n) => n.FindOutput("variable").TypeName;
		static StringView ValType(Node n) => n.FindInput("value").TypeName;

		static void RunTypeEditScenarios()
		{
			Console.WriteLine("Scenario 23: nodes follow type edits");
			SourceDocument doc = scope .();
			doc.LoadFromText(cTypes, "Unit.bf");
			let g = Method(doc, "Unit.Make()").Graph;
			let con = FindNode(g, .Construct, "Foo");
			let a = FindNode(g, .LocalVar, "a");
			Check(con != null && a != null && a.FindOutput("variable").TypeName == "Foo", "`let a = scope Foo();` reads as a Local a of type Foo");

			// The Construct's type changed (Properties > Type): the local holding it follows.
			doc.PushUndo();
			con.Text.Set("Bar");
			con.Result.TypeName.Clear();
			NodeFactory.ConstructResultType(con.Text, con.IsArray, con.Result.TypeName);
			con.Edited = true;
			doc.Commit(Method(doc, "Unit.Make()"));
			Check(doc.Text.Contains("let a = scope Bar();"), "the construct writes `scope Bar()`");
			Check(Method(doc, "Unit.Make()").Graph == g && g.Nodes.Contains(a), "the graph and the local node are kept");
			Check(a.FindOutput("variable").TypeName == "Bar", scope $"the local's variable pin follows: Bar (got {VarType(a)})");
			Check(a.FindInput("value").TypeName == "Bar", scope $"the local's value pin follows: Bar (got {ValType(a)})");
			Check(!a.Edited && !con.Edited, "both nodes are clean after the commit");

			// Undo brings the old type back on the pins too.
			doc.Undo();
			let gu = Method(doc, "Unit.Make()").Graph;
			let au = FindNode(gu, .LocalVar, "a");
			Check(doc.Text.Contains("let a = scope Foo();") && au != null && au.FindOutput("variable").TypeName == "Foo", "undo restores `scope Foo()` and the Foo pin");
			doc.Redo();
			let gr = Method(doc, "Unit.Make()").Graph;
			let ar = FindNode(gr, .LocalVar, "a");
			Check(ar != null && ar.FindOutput("variable").TypeName == "Bar", "redo brings Bar back");

			// A declared type changed (Properties > Variable Type): `Bar b = .();` -> `Foo b = .();`.
			let g2 = Method(doc, "Unit.Make()").Graph;
			let b = FindNode(g2, .LocalVar, "b");
			Check(b != null && b.FindOutput("variable").TypeName == "Bar", "`Bar b = .();` is a Local b of type Bar");
			doc.PushUndo();
			b.Text2.Set("Foo");
			b.Edited = true;
			doc.Commit(Method(doc, "Unit.Make()"));
			Check(doc.Text.Contains("Foo b = .();"), "the local writes `Foo b = .();`");
			Check(b.FindOutput("variable").TypeName == "Foo" && b.FindInput("value").TypeName == "Foo", scope $"its pins follow: Foo (got {VarType(b)} / {ValType(b)})");
			let inferred = Method(doc, "Unit.Make()").Graph.DataSource(b.FindInput("value"));
			Check(inferred == null || inferred.Result == null || inferred.Result.TypeName.IsEmpty || inferred.Result.TypeName == "Foo", "the `.()` it holds shows Foo, not Bar");

			// A `var` local from a call whose return type changes elsewhere (the signature of Get).
			let g3 = Method(doc, "Unit.Make()").Graph;
			let get = FindNode(g3, .Call, "Get");
			let c = FindNode(g3, .LocalVar, "c");
			StringView cType = (c != null) ? c.FindOutput("variable").TypeName : ((get?.Result != null) ? get.Result.TypeName : "");
			Check(cType == "Foo", scope $"`var c = Get();` is a Foo (got {cType})");
			doc.SetSignature(Method(doc, "Unit.Get()").Method, "Bar", "");
			Check(doc.Text.Contains("public Bar Get()"), "Get returns Bar now");
			let g4 = Method(doc, "Unit.Make()").Graph;
			Check(g4 == g3, "Make's graph is kept (its body did not change)");
			let get4 = FindNode(g4, .Call, "Get");
			let c4 = FindNode(g4, .LocalVar, "c");
			Check(get4 != null && get4.Result != null && get4.Result.TypeName == "Bar", scope $"the Get call's Return Value follows: Bar (got {get4?.Result?.TypeName})");
			if (c4 != null)
				Check(c4.FindOutput("variable").TypeName == "Bar", scope $"the var local follows: Bar (got {VarType(c4)})");

			// Reload Node / Reload Sheet (the safety valves) on a node whose pin was knocked out
			// of step by hand.
			let g5 = Method(doc, "Unit.Make()").Graph;
			let a5 = FindNode(g5, .LocalVar, "a");
			a5.FindOutput("variable").TypeName.Set("Stale");
			Check(doc.ReloadNode(Method(doc, "Unit.Make()"), a5) && a5.FindOutput("variable").TypeName == "Bar", "Reload Node puts the type the function says back on the pin");
			a5.FindOutput("variable").TypeName.Set("Stale");
			String before = scope .(doc.Text);
			doc.ReloadGraph(Method(doc, "Unit.Make()"));
			// No pointer comparison with the old graph: it was deleted, and the allocator is free to
			// hand the new one the same address (glibc does). The Stale pin coming back as Bar shows the rebuild.
			let g6 = Method(doc, "Unit.Make()").Graph;
			let a6 = FindNode(g6, .LocalVar, "a");
			Check(a6 != null && a6.FindOutput("variable").TypeName == "Bar" && doc.Text == before, "Reload Sheet builds the Sheet again (text unchanged, Bar on the pin)");
			doc.Undo();
			Check(doc.Text == before, "Reload Sheet is one undo step and leaves the text alone");
		}

		public static int Run()
		{
			SourceDocument doc = scope .();
			doc.LoadFromText(cSample, "Player.bf");

			Console.WriteLine("Scenario 1: insert a call between two statements");
			{
				let mg = Method(doc, "Player.TakeDamage(int)");
				let g = mg.Graph;
				let set = FindNode(g, .Set);
				let branch = FindNode(g, .Branch);
				doc.PushUndo();
				StringView[1] names = .("value");
				StringView[1] types = .("String");
				let call = NodeFactory.Call(g, "Console.WriteLine", true, false, "", names, types, "void");
				call.FindInput("arg0").Default.Set("\"ouch\"");
				call.X = 500;
				call.Y = 300;
				call.HasPos = true;
				g.Connect(set.Then, call.ExecIn);   // replaces set -> branch
				g.Connect(call.Then, branch.ExecIn);
				doc.Commit(mg);
				Check(doc.Text.Contains("mHealth -= amount;\n\t\t\tConsole.WriteLine(\"ouch\");\n\t\t\tif (mHealth <= 0)"), "call inserted in order");
				Check(doc.Text.Contains("// Apply damage"), "comment preserved");
				let mg2 = Method(doc, "Player.TakeDamage(int)");
				let call2 = FindNode(mg2.Graph, .Call, "WriteLine");
				Check(call2 != null && call2.X == 500 && call2.Y == 300, "new node keeps its position after regeneration");
			}

			Console.WriteLine("Scenario 2: edit a pin default inside an expression");
			{
				let mg = Method(doc, "Player.TakeDamage(int)");
				let op = FindNode(mg.Graph, .Operator, "<=");
				doc.PushUndo();
				op.FindInput("b").Default.Set("10");
				op.Edited = true;
				doc.Commit(mg);
				Check(doc.Text.Contains("if (mHealth <= 10)"), "condition rewritten");
			}

			Console.WriteLine("Scenario 3: delete a node");
			{
				let mg = Method(doc, "Player.TakeDamage(int)");
				let die = FindNode(mg.Graph, .Call, "Die");
				doc.PushUndo();
				mg.Graph.RemoveNode(die);
				doc.Commit(mg);
				Check(!doc.Text.Contains("Die();"), "Die() call removed");
				Check(doc.Text.Contains("public void Die()"), "Die method itself untouched");
			}

			Console.WriteLine("Scenario 4: undo / redo");
			{
				doc.Undo();
				Check(doc.Text.Contains("\t\t\t\tDie();"), "undo restores the call");
				doc.Redo();
				Check(!doc.Text.Contains("\t\t\t\tDie();"), "redo removes it again");
				doc.Undo();
			}

			Console.WriteLine("Scenario 5: unconnected nodes survive regeneration");
			{
				let mg = Method(doc, "Player.TakeDamage(int)");
				doc.PushUndo();
				let get = NodeFactory.Get(mg.Graph, "mHealth", "int");
				get.X = 10;
				get.Y = 600;
				get.HasPos = true;
				let op = FindNode(mg.Graph, .Operator, "<=");
				op.FindInput("b").Default.Set("5");
				op.Edited = true;
				doc.Commit(mg);
				let mg2 = Method(doc, "Player.TakeDamage(int)");
				let orphan = FindNode(mg2.Graph, .Get, "mHealth");
				// The condition's own mHealth Get is part of the code; find the orphan by position.
				bool found = false;
				for (let n in mg2.Graph.Nodes)
					if (n.Kind == .Get && n.X == 10 && n.Y == 600)
						found = true;
				Check(orphan != null && found, "orphan Get node kept");
			}

			Console.WriteLine("Scenario 6: wire a new local variable from an orphan node");
			{
				let mg = Method(doc, "Player.TakeDamage(int)");
				let g = mg.Graph;
				doc.PushUndo();
				let local = NodeFactory.LocalVar(g, "before", "int");
				Node orphanGet = null;
				for (let n in g.Nodes)
					if (n.Kind == .Get && n.X == 10 && n.Y == 600)
						orphanGet = n;
				g.Connect(orphanGet.Result, local.FindInput("value"));
				// Insert at the start: entry -> local -> (old first)
				let first = g.ExecTarget(g.Entry.Then);
				g.Connect(g.Entry.Then, local.ExecIn);
				g.Connect(local.Then, first.ExecIn);
				doc.Commit(mg);
				Check(doc.Text.Contains("{\n\t\t\tint before = mHealth;\n\t\t\t// Apply damage"), "local var inserted first, comment kept with its statement");
			}

			Console.WriteLine("Scenario 7: impure call result used later becomes a temp");
			{
				let mg = Method(doc, "Player.Die()");
				let g = mg.Graph;
				doc.PushUndo();
				StringView[0] none = .();
				let call = NodeFactory.Call(g, "GetScore", true, false, "", none, none, "int");
				let ret = NodeFactory.Return(g, "void");
				let wl = FindNode(g, .Call, "WriteLine");
				g.Connect(wl.Then, call.ExecIn);
				g.Connect(call.Then, ret.ExecIn);
				let local = NodeFactory.LocalVar(g, "score", "let");
				g.Connect(call.Then, local.ExecIn);
				g.Connect(local.Then, ret.ExecIn);
				g.Connect(call.Result, local.FindInput("value"));
				doc.Commit(mg);
				Check(doc.Text.Contains("GetScore();\n\t\t\tlet score = getScoreResult;") || doc.Text.Contains("let getScoreResult = GetScore();"), "temp generated for impure result");
			}

			Console.WriteLine("Scenario 8: control flow from scratch");
			{
				String outKey = scope .();
				let type = doc.Unit.Members[1].Members[0];
				doc.AddMethod(type, "int", "Clamp", "int value, int max", outKey);
				Check(doc.Text.Contains("public int Clamp(int value, int max)"), "method added");
				let mg = Method(doc, outKey);
				let g = mg.Graph;
				doc.PushUndo();
				let branch = NodeFactory.Branch(g);
				let cmp = NodeFactory.Operator(g, ">", true);
				let getV = NodeFactory.Get(g, "value", "int");
				let getM = NodeFactory.Get(g, "max", "int");
				g.Connect(getV.Result, cmp.FindInput("a"));
				g.Connect(getM.Result, cmp.FindInput("b"));
				g.Connect(cmp.Result, branch.FindInput("condition"));
				g.Connect(g.Entry.Then, branch.ExecIn);
				let retMax = NodeFactory.Return(g, "int");
				retMax.FindInput("value").Default.Set("max");
				g.Connect(branch.FindOutput("true"), retMax.ExecIn);
				let retV = NodeFactory.Return(g, "int");
				retV.FindInput("value").Default.Set("value");
				g.Connect(branch.Then, retV.ExecIn);
				let each = NodeFactory.Loop(g, .ForEach);
				each.FindInput("collection").Default.Set("mItems");
				g.Connect(branch.FindOutput("false"), each.ExecIn);
				let add = NodeFactory.Operator(g, "+", true);
				let mul = NodeFactory.Operator(g, "*", true);
				mul.FindInput("a").Default.Set("item");
				mul.FindInput("b").Default.Set("2");
				add.FindInput("a").Default.Set("value");
				g.Connect(mul.Result, add.FindInput("b"));
				let setV = NodeFactory.Set(g, "value", "int");
				g.Connect(add.Result, setV.FindInput("value"));
				g.Connect(each.FindOutput("body"), setV.ExecIn);
				doc.Commit(mg);
				Check(doc.Text.Contains("if (value > max)\n\t\t\t{\n\t\t\t\treturn max;\n\t\t\t}\n\t\t\telse\n\t\t\t{\n\t\t\t\tfor (let item in mItems)\n\t\t\t\t{\n\t\t\t\t\tvalue = value + item * 2;"), "branch/loop/expression generated");
				Check(doc.Text.Contains("\t\t\treturn value;\n\t\t}"), "completed path generated");
			}

			Console.WriteLine("Scenario 9: text -> graph");
			{
				String text = scope .(doc.Text);
				text.Replace("Console.WriteLine(\"Player died\");", "Console.WriteLine(\"Player died\");\n\t\t\tmHealth = 0;");
				doc.ApplyText(text);
				let mg = Method(doc, "Player.Die()");
				let set = FindNode(mg.Graph, .Set);
				Check(set != null && set.FindInput("target").Default == "mHealth" && set.FindInput("value").Default == "0", "typed code shows up as a Set node");
			}

			Console.WriteLine("Scenario 10: rename and signature change keep layout");
			{
				let mg = Method(doc, "Player.Die()");
				for (let n in mg.Graph.Nodes)
				{
					n.X = 1234;
					n.Y = 77;
				}
				doc.RenameMember(mg.Method, "Kill");
				let mg2 = Method(doc, "Player.Kill()");
				Check(mg2 != null && mg2.Graph.Entry.X == 1234, "positions follow a rename");
				doc.SetSignature(mg2.Method, "bool", "int reason");
				Check(doc.Text.Contains("public bool Kill(int reason)"), "signature rewritten");
				let mg3 = Method(doc, "Player.Kill(int)");
				Check(mg3 != null && mg3.Graph.Entry.X == 1234, "positions follow a signature change");
			}

			Console.WriteLine("Scenario 11: add field");
			{
				let type = doc.Unit.Members[1].Members[0];
				doc.AddField(type, "float", "mSpeed", "1.5f");
				Check(doc.Text.Contains("\t\tpublic int mHealth = 100;\n\t\tpublic float mSpeed = 1.5f;\n"), "field added after existing fields");
			}

			Console.WriteLine("---- final text ----");
			Console.Write(doc.Text);

			RunMorphScenarios();
			RunUndoPlaceScenarios();
			RunAssetScenarios();
			RunOrphanPersistScenarios();
			RunTypeEditScenarios();
			// Text pins: bare text, escaping, quoted literals of older projects (docs/Editor-UI.md#pin-values).
			OverloadTests.Checks = 0;
			OverloadTests.Failures = 0;
			OverloadTests.RunEdits();
			sFailures += OverloadTests.Failures;
			// Variables dropped on pins (docs/Editor-UI.md#dragging-onto-pins).
			DragVarTests.Checks = 0;
			DragVarTests.Failures = 0;
			DragVarTests.RunEdits();
			sFailures += DragVarTests.Failures;

			Console.WriteLine("edit failures: {}", sFailures);
			return (sFailures == 0) ? 0 : 1;
		}
	}
}
