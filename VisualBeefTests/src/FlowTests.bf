using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// Switch and flow-macro scenarios that need no compiler: parsing, graph shapes, generated
	/// text, byte-exact round trips, scripted edits, refusals. (Behaviour of the generated code
	/// is checked by `compile`.)
	static class FlowTests
	{
		static int sFailures;
		static int sChecks;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		static Node FindNode(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		static Node NewWriteLine(Graph g, StringView format)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
			NodeFactory.AddArgument(g, n).Default.Set(format);
			return n;
		}

		static Node FindWrite(Graph g, StringView arg0)
		{
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call || n.Text != "WriteLine")
					continue;
				let p = n.FindInput("arg0");
				if (p != null && p.Default == arg0)
					return n;
			}
			return null;
		}

		static void ForceRegenerate(Graph g)
		{
			for (let n in g.Nodes)
				n.Edited = true;
		}

		// ------------------------------------------------------------------ sources

		const String cSwitch =
			"""
			using System;

			namespace Demo
			{
				enum Mode { Idle, Run, Jump }

				class Host
				{
					public void Pick(int x)
					{
						Console.WriteLine("start");
						switch (x)
						{
						case 1:
							Console.WriteLine("one");
						// two or three
						case 2, 3: // grouped
							Console.WriteLine("two/three");
							break;
						default:
							Console.WriteLine("other");
						}
						Console.WriteLine("end");
					}

					public void Indented(Mode m)
					{
						switch (m) {
							case .Idle:
								Console.WriteLine("idle");
							case .Run:
								Console.WriteLine("run");
							default:
						}
					}

					public void Declined(int x, Mode m)
					{
						switch (x)
						{
						case 1:
							Console.WriteLine("one");
							fallthrough;
						case 2:
							Console.WriteLine("two");
						}
						switch (x)
						{
						case 1 when m == .Run:
							Console.WriteLine("guarded");
						default:
						}
						switch (x)
						{
						case 1...5:
							Console.WriteLine("range");
						default:
						}
						switch (Result<int>.Ok(x))
						{
						case .Ok(let v):
							Console.WriteLine("ok {}", v);
						case .Err:
						}
					}

					public void Empty()
					{
					}
				}
			}

			""";

		const String cMacros =
			"""
			using System;

			namespace Demo
			{
				class Host
				{
					private bool __doOnce_1;
					private int __doN_1;
					private bool __flipFlop_1;
					private bool __gateOpen_1;
					private bool __gateClosed_2;
					private int __multiGate_1;

					public void Run()
					{
						// vb:sequence
						{
							Console.WriteLine("a");
							Console.WriteLine("b");
						}
						{
							Console.WriteLine("c");
						}
						if (!__doOnce_1)
						{
							__doOnce_1 = true;
							Console.WriteLine("once");
						}
						if (__doN_1 < 3)
						{
							__doN_1++;
							Console.WriteLine("n {}", __doN_1);
						}
						if (!__flipFlop_1)
						{
							__flipFlop_1 = true;
							Console.WriteLine("A");
						}
						else
						{
							__flipFlop_1 = false;
							Console.WriteLine("B");
						}
						if (__gateOpen_1)
						{
							Console.WriteLine("open");
						}
						if (!__gateClosed_2)
						{
							Console.WriteLine("open too");
						}
						__gateOpen_1 = true;
						__gateClosed_2 = !__gateClosed_2;
						__doOnce_1 = false;
						__doN_1 = 0;
						if (__multiGate_1 == 0)
						{
							__multiGate_1 = 1;
							Console.WriteLine("m0");
						}
						else if (__multiGate_1 == 1)
						{
							__multiGate_1 = 0;
							Console.WriteLine("m1");
						}
					}

					public static void Lookalikes(bool x)
					{
						// Not macros: wrong prefix or shape.
						if (!x)
						{
							x = true;
							Console.WriteLine("plain");
						}
						if (!__doOnce_1b)
						{
							Console.WriteLine("missing the assignment");
						}
						{
							Console.WriteLine("a plain block");
						}
					}

					static bool __doOnce_1b;
				}
			}

			""";

		// ------------------------------------------------------------------ cases

		static void RunParse()
		{
			Console.WriteLine("Flow 1: switch parsing");
			let unit = Parser.Parse(cSwitch);
			defer delete unit;
			List<Member> methods = scope .();
			unit.CollectMethods(methods, null);
			Member Find(StringView name)
			{
				for (let m in methods)
					if (m.Name == name)
						return m;
				return null;
			}
			let pick = Find("Pick");
			Check(pick != null && pick.Body.Body[1].Kind == .Switch, "switch (x) { ... } parses as a Switch statement");
			let sw = pick.Body.Body[1];
			Check(sw.Cases.Count == 3, scope $"three clauses ({sw.Cases.Count})");
			Check(sw.Cases[0].Label == "1" && sw.Cases[1].Label == "2, 3" && sw.Cases[2].IsDefault, "labels are the source text, default is flagged");
			Check(sw.Cases[1].Body.Count == 2 && sw.Cases[1].Body[1].Kind == .Break, "clause statements are real statements (break stays a Break)");
			let ind = Find("Indented");
			Check(ind.Body.Body[0].Kind == .Switch && ind.Body.Body[0].Cases[0].Label == ".Idle", "enum cases keep their dotted text");
			Check(ind.Body.Body[0].Cases[2].IsDefault && ind.Body.Body[0].Cases[2].Body.Count == 0, "an empty default is kept");

			let dec = Find("Declined");
			int rawSwitches = 0;
			List<String> reasons = scope .();
			for (let s in dec.Body.Body)
			{
				if (s.Kind == .Raw && s.RawReason != null)
				{
					rawSwitches++;
					reasons.Add(s.RawReason);
				}
			}
			Check(rawSwitches == 3, scope $"fallthrough / when / range switches stay raw ({rawSwitches})");
			Stmt payloadSwitch = null;
			for (let s in dec.Body.Body)
				if (s.Kind == .Switch)
					payloadSwitch = s;
			Check(payloadSwitch != null && payloadSwitch.Cases[0].BindCase == "Ok" && payloadSwitch.Cases[0].BindDecl == "let" &&
				payloadSwitch.Cases[0].BindName == "v" && payloadSwitch.Cases[1].BindName == null,
				"a payload switch (`case .Ok(let v):`) is a Switch whose case records the binding");
			bool has(StringView part)
			{
				for (let r in reasons)
					if (r.Contains(part))
						return true;
				return false;
			}
			Check(has("fallthrough"), "reason names fallthrough");
			Check(has("'when' guard"), "reason names the when guard");
			Check(has("range"), "reason names the range");

		}

		static void RunSwitchGraph()
		{
			Console.WriteLine("Flow 2: switch graph and byte-exact round trip");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSwitch, "Switch.bf");
			let mg = doc.FindMethod("Host.Pick(int)");
			let g = mg.Graph;
			let sw = FindNode(g, .Switch);
			Check(sw != null, "the method has a Switch node");
			Check(sw.FindInput("value") != null && sw.FindInput("value").Kind == .Data, "value input");
			Check(sw.FindOutput("case0").Label == "1" && sw.FindOutput("case1").Label == "2, 3", "one output per case, labelled with the case text");
			Check(sw.FindOutput("default") != null && sw.FindOutput("default").Optional, "Default output (explicit in the source)");
			Check(g.ExecTarget(sw.FindOutput("case0")) != null && g.ExecTarget(sw.Then) == FindWrite(g, "\"end\""), "arm bodies and the Completed output are wired");
			String before = scope .(doc.Text);
			doc.PushUndo();
			bool ok = doc.Commit(mg);
			Check(ok && doc.Text == before, "an untouched commit changes nothing");
			ForceRegenerate(doc.FindMethod("Host.Pick(int)").Graph);
			ok = doc.Commit(doc.FindMethod("Host.Pick(int)"));
			Check(ok && doc.Text == before, "regenerating the whole switch reproduces the source byte for byte (comments, grouped label, layout)");
			if (doc.Text != before)
				Program.ShowDiff(before, doc.Text);

			let ind = doc.FindMethod("Host.Indented(Mode)");
			ForceRegenerate(ind.Graph);
			ok = doc.Commit(ind);
			Check(ok && doc.Text == before, "regenerating an indented K&R switch keeps its style");
			if (doc.Text != before)
				Program.ShowDiff(before, doc.Text);

			let dec = doc.FindMethod("Host.Declined(int,Mode)");
			int codeNodes = 0;
			bool reasons = true;
			for (let n in dec.Graph.Nodes)
			{
				if (n.Kind == .Code && n.Text.StartsWith("switch"))
				{
					codeNodes++;
					if (n.Reason == null || !n.Reason.StartsWith("switch:"))
						reasons = false;
				}
			}
			Check(codeNodes == 3 && reasons, "switches that cannot be modelled are Code nodes that say why");
			{
				Node psw = null;
				for (let n in dec.Graph.Nodes)
					if (n.Kind == .Switch)
						psw = n;
				let payload = psw?.FindOutput("case0.payload");
				int reads = 0;
				for (let l in dec.Graph.Links)
					if (l.From == payload)
						reads++;
				Check(payload != null && payload.Label == "v" && payload.IsOutArg && reads == 1,
					"the payload switch has a `v` pin wired to its reader in the Ok case");
			}
			ForceRegenerate(dec.Graph);
			ok = doc.Commit(dec);
			Check(ok && doc.Text == before, "Code-node switches and the payload switch round trip byte for byte");
			if (doc.Text != before)
				Program.ShowDiff(before, doc.Text);
		}

		static void RunSwitchEdits()
		{
			Console.WriteLine("Flow 3: scripted switch edits");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSwitch, "Switch.bf");
			var mg = doc.FindMethod("Host.Pick(int)");
			var g = mg.Graph;
			var sw = FindNode(g, .Switch);

			// Add `case 4:` with a body before Default.
			doc.PushUndo();
			let p = NodeFactory.AddCase(g, sw, "4");
			let four = NewWriteLine(g, "\"four\"");
			g.Connect(p, four.ExecIn);
			bool ok = doc.Commit(mg);
			Check(ok, "adding a case commits");
			Check(doc.Text.Contains("\t\t\t\tConsole.WriteLine(\"two/three\");\n\t\t\t\tbreak;\n\t\t\tcase 4:\n\t\t\t\tConsole.WriteLine(\"four\");\n\t\t\tdefault:\n"), "new case lands before default, in the file's layout");
			Check(doc.Text.Contains("\t\t// two or three\n\t\tcase 2, 3: // grouped\n") || doc.Text.Contains("\t\t\t// two or three\n\t\t\tcase 2, 3: // grouped\n"), "the other clauses keep their comments");

			// Relabel, reorder, remove.
			mg = doc.FindMethod("Host.Pick(int)");
			g = mg.Graph;
			sw = FindNode(g, .Switch);
			doc.PushUndo();
			sw.FindOutput("case2").Label.Set("5");
			sw.Edited = true;
			NodeFactory.MoveCase(g, sw, sw.FindOutput("case2"), -1);
			ok = doc.Commit(mg);
			Check(ok && doc.Text.IndexOf("case 5:") >= 0 && doc.Text.IndexOf("case 5:") < doc.Text.IndexOf("case 2, 3:"), "relabelled and moved up");
			mg = doc.FindMethod("Host.Pick(int)");
			g = mg.Graph;
			sw = FindNode(g, .Switch);
			doc.PushUndo();
			NodeFactory.RemoveCase(g, sw, sw.FindOutput("case0"));
			ok = doc.Commit(mg);
			Check(ok && doc.Text.IndexOf("\"one\"") > doc.Text.IndexOf("void Indented"), "removing a case removes its body");
			Check(doc.Text.Contains("// two or three") && doc.Text.Contains("// grouped"), "comments survive the reorder");
			Check(sw.FindOutput("case0").Label == "5" && sw.FindOutput("case1").Label == "2, 3", "pins are renumbered in order");

			// A fresh parse of the written code gives the same shape.
			SourceDocument fresh = scope .();
			fresh.LoadFromText(doc.Text, "Switch2.bf");
			let fsw = FindNode(fresh.FindMethod("Host.Pick(int)").Graph, .Switch);
			Check(fsw != null && fsw.Outputs.Count == sw.Outputs.Count, "re-parse sees the same outputs");
			bool same = true;
			for (int i < Math.Min(fsw.Outputs.Count, sw.Outputs.Count))
				if (fsw.Outputs[i].Name != sw.Outputs[i].Name || fsw.Outputs[i].Label != sw.Outputs[i].Label)
					same = false;
			Check(same, "same pin names and labels after the edits");
		}

		static void RunMerge()
		{
			Console.WriteLine("Flow 4: switch merges");
			const String src =
				"""
				using System;

				namespace Demo
				{
					class Host
					{
						public void Pick(int x)
						{
							switch (x)
							{
							case 1:
								Console.WriteLine("one");
							case 2:
								Console.WriteLine("two");
							default:
								Console.WriteLine("other");
							}
						}

						public void Half(int x)
						{
							switch (x)
							{
							case 1:
								Console.WriteLine("one");
							case 2:
								Console.WriteLine("two");
							}
						}
					}
				}

				""";
			SourceDocument doc = scope .();
			doc.LoadFromText(src, "Merge.bf");
			var mg = doc.FindMethod("Host.Pick(int)");
			var g = mg.Graph;
			doc.PushUndo();
			let join = NewWriteLine(g, "\"joined\"");
			g.Connect(FindWrite(g, "\"one\"").Then, join.ExecIn);
			g.Connect(FindWrite(g, "\"two\"").Then, join.ExecIn);
			g.Connect(FindWrite(g, "\"other\"").Then, join.ExecIn);
			bool ok = doc.Commit(mg);
			Check(ok, "every arm and Default into one node commits");
			Check(doc.Text.Contains("\t\t\t\tConsole.WriteLine(\"other\");\n\t\t\t}\n\t\t\tConsole.WriteLine(\"joined\");\n"), "the shared node is written once, after the switch");

			mg = doc.FindMethod("Host.Half(int)");
			g = mg.Graph;
			doc.PushUndo();
			let j2 = NewWriteLine(g, "\"joined2\"");
			g.Connect(FindWrite(g, "\"one\"").Then, j2.ExecIn);
			g.Connect(FindWrite(g, "\"two\"").Then, j2.ExecIn);
			String before = scope .(doc.Text);
			ok = doc.Commit(mg);
			Check(!ok && doc.Text == before, "with Default unwired the merge is refused and the file is untouched");
			bool hasError = false;
			for (let e in g.Errors)
				if (e.Message.Contains("Two flow wires"))
					hasError = true;
			Check(hasError, "the refusal is on the node");
		}

		static void RunMacroParse()
		{
			Console.WriteLine("Flow 5: macro shapes are recognised and round trip");
			SourceDocument doc = scope .();
			doc.LoadFromText(cMacros, "Macros.bf");
			let mg = doc.FindMethod("Host.Run()");
			let g = mg.Graph;
			int[] counts = scope .(0, 0, 0, 0, 0, 0, 0);
			for (let n in g.Nodes)
			{
				if (n.Kind != .Flow)
					continue;
				if (n.Text == FlowMacros.Sequence) counts[0]++;
				else if (n.Text == FlowMacros.DoOnce) counts[1]++;
				else if (n.Text == FlowMacros.DoN) counts[2]++;
				else if (n.Text == FlowMacros.FlipFlop) counts[3]++;
				else if (n.Text == FlowMacros.Gate) counts[4]++;
				else if (n.Text == FlowMacros.MultiGate) counts[5]++;
				else counts[6]++;
			}
			Check(counts[0] == 1 && counts[1] == 1 && counts[2] == 1 && counts[3] == 1 && counts[4] == 2 && counts[5] == 1, "Sequence, DoOnce, DoN, FlipFlop, 2x Gate, MultiGate");
			Check(counts[6] == 4, scope $"Gate.Open, Gate.Toggle, DoOnce.Reset, DoN.Reset ({counts[6]})");
			let seq = FindNode(g, .Flow, FlowMacros.Sequence);
			Check(seq.FindOutput("seq0") != null && seq.FindOutput("seq1") != null && seq.FindOutput("seq2") == null, "the Sequence has one output per block");
			let mgate = FindNode(g, .Flow, FlowMacros.MultiGate);
			Check(mgate.Postfix && FlowMacros.ArmCount(mgate) == 2, "MultiGate loops when the last arm wraps to 0");
			bool startsClosed = false;
			bool startsOpen = false;
			for (let n in g.Nodes)
				if (n.Kind == .Flow && n.Text == FlowMacros.Gate)
				{
					if (FlowMacros.GateStartsClosed(n)) startsClosed = true; else startsOpen = true;
				}
			Check(startsClosed && startsOpen, "both gate polarities are read");
			let counter = FindNode(g, .Get, "__doN_1");
			Check(counter != null, "reading the DoN counter in its body is an ordinary Get");

			String before = scope .(doc.Text);
			doc.PushUndo();
			Check(doc.Commit(mg) && doc.Text == before, "an untouched commit changes nothing");
			ForceRegenerate(doc.FindMethod("Host.Run()").Graph);
			bool ok = doc.Commit(doc.FindMethod("Host.Run()"));
			Check(ok && doc.Text == before, "regenerating every macro reproduces the source byte for byte");
			if (doc.Text != before)
				Program.ShowDiff(before, doc.Text);

			let look = doc.FindMethod("Host.Lookalikes(bool)").Graph;
			Check(FindNode(look, .Flow) == null, "lookalikes (wrong prefix, missing assignment, plain block) are not macros");
		}

		static void RunMacroFields()
		{
			Console.WriteLine("Flow 6: state fields");
			const String src =
				"""
				using System;

				namespace Demo
				{
					class Host
					{
						private int mValue;

						public void Tick()
						{
						}

						public static void STick()
						{
						}
					}
				}

				""";
			SourceDocument doc = scope .();
			doc.LoadFromText(src, "Fields.bf");
			var mg = doc.FindMethod("Host.Tick()");
			var g = mg.Graph;
			HashSet<String> owner = scope .();
			defer { for (let s in owner) delete s; }
			doc.GetOwnerFieldNames(mg, owner);
			doc.PushUndo();
			let once = NodeFactory.Flow(g, FlowMacros.DoOnce, owner);
			let say = NewWriteLine(g, "\"hi\"");
			g.Connect(g.Entry.Then, once.ExecIn);
			g.Connect(once.FindOutput("body"), say.ExecIn);
			bool ok = doc.Commit(mg);
			Check(ok, "a new Do Once commits");
			Check(once.Text2 == "__doOnce_1", "it got a free state name");
			Check(doc.Text.Contains("\t\tprivate int mValue;\n\t\tprivate bool __doOnce_1;\n"), "the field is added after the existing fields");
			Check(doc.Text.Contains("\t\t\tif (!__doOnce_1)\n\t\t\t{\n\t\t\t\t__doOnce_1 = true;\n\t\t\t\tConsole.WriteLine(\"hi\");\n\t\t\t}\n"), "the macro is written as plain Beef");

			// A second Do Once in another method gets the next name; a static method gets a static field.
			mg = doc.FindMethod("Host.STick()");
			g = mg.Graph;
			for (let s in owner)
				delete s;
			owner.Clear();
			doc.GetOwnerFieldNames(mg, owner);
			doc.PushUndo();
			let once2 = NodeFactory.Flow(g, FlowMacros.DoOnce, owner);
			let say2 = NewWriteLine(g, "\"hi2\"");
			g.Connect(g.Entry.Then, once2.ExecIn);
			g.Connect(once2.FindOutput("body"), say2.ExecIn);
			ok = doc.Commit(mg);
			Check(ok && once2.Text2 == "__doOnce_2", "the next Do Once avoids the first one's field");
			Check(doc.Text.Contains("private static bool __doOnce_2;"), "a static method gets a static field");

			// Committing again adds nothing.
			String before = scope .(doc.Text);
			doc.PushUndo();
			ForceRegenerate(doc.FindMethod("Host.STick()").Graph);
			doc.Commit(doc.FindMethod("Host.STick()"));
			Check(doc.Text == before, "a second commit does not duplicate fields");

			// Two nodes with one name in a graph: the second is renamed.
			mg = doc.FindMethod("Host.Tick()");
			g = mg.Graph;
			doc.PushUndo();
			let dup = NodeFactory.Flow(g, FlowMacros.DoOnce);
			dup.Text2.Set("__doOnce_1");
			let say3 = NewWriteLine(g, "\"dup\"");
			g.Connect(once.Then, dup.ExecIn);
			g.Connect(dup.FindOutput("body"), say3.ExecIn);
			ok = doc.Commit(mg);
			Check(ok && dup.Text2 != "__doOnce_1" && dup.Text2.StartsWith("__doOnce_"), "a duplicate state name is replaced");

			// Gate polarity.
			mg = doc.FindMethod("Host.Tick()");
			g = mg.Graph;
			doc.PushUndo();
			let gate = NodeFactory.Flow(g, FlowMacros.Gate);
			Check(!FlowMacros.GateStartsClosed(gate), "a new gate starts open");
			FlowMacros.SetGateStartClosed(gate, true);
			Check(gate.Text2.StartsWith("__gateOpen_"), "starting closed uses the __gateOpen_ field");
			let say4 = NewWriteLine(g, "\"gated\"");
			g.Connect(dup.Then, gate.ExecIn);
			g.Connect(gate.FindOutput("body"), say4.ExecIn);
			let open = NodeFactory.Flow(g, FlowMacros.GateOpen);
			Check(open.Text2 == gate.Text2, "an Open node aims at the gate in the graph");
			g.Connect(gate.Then, open.ExecIn);
			ok = doc.Commit(mg);
			Check(ok && doc.Text.Contains(scope $"if ({gate.Text2})") && doc.Text.Contains(scope $"{gate.Text2} = true;"), "gate and Open written");
		}

		static void RunMacroRefusals()
		{
			Console.WriteLine("Flow 7: macro refusals");
			const String src =
				"""
				using System;

				namespace Demo
				{
					class Host
					{
						public void Tick()
						{
						}
					}
				}

				""";
			SourceDocument doc = scope .();
			doc.LoadFromText(src, "Refuse.bf");
			var mg = doc.FindMethod("Host.Tick()");
			var g = mg.Graph;
			doc.PushUndo();
			let reset = NodeFactory.Flow(g, FlowMacros.DoOnceReset);
			g.Connect(g.Entry.Then, reset.ExecIn);
			String before = scope .(doc.Text);
			bool ok = doc.Commit(mg);
			Check(!ok && doc.Text == before, "a Reset with no target is refused");
			bool onNode = false;
			for (let e in g.Errors)
				if (e.NodeId == reset.Id)
					onNode = true;
			Check(onNode, "the error is on the Reset node");

			reset.Text2.Set("mSomething");
			ok = doc.Commit(mg);
			Check(!ok, "a target that is not a Do Once field is refused");
		}

		// ------------------------------------------------------------------ counting loops

		const String cLoops =
			"""
			using System;

			namespace Demo
			{
				class Host
				{
					public static void Count(int count)
					{
						for (int i = 0; i < count; i++)
						{
							Console.WriteLine(i);
						}
						for (int  k=1 ;k<10;k++)
						{
						}
						for (int j < 3)
						{
						}
						for (int a = 0; a <= 3; a++)
						{
						}
						for (int b = 0; b < 3; ++b)
						{
						}
						for (;;)
						{
							break;
						}
					}
				}
			}
			""";

		/// For Loops read from a counting header get a counter output pin and Start / Count inputs
		/// (docs/Flow-Nodes.md > For Loop); every other header stays text.
		static void RunCountingLoops()
		{
			Console.WriteLine("Flow 8: counting For Loops");
			SourceDocument doc = scope .();
			doc.LoadFromText(cLoops, "Loops.bf");
			var mg = doc.FindMethod("Host.Count(int)");
			var g = mg.Graph;
			Node first = null, second = null, shortForm = null;
			int texts = 0;
			for (let n in g.Nodes)
			{
				if (n.Kind != .For)
					continue;
				if (n.IsCountingLoop && n.Text == "i") first = n;
				else if (n.IsCountingLoop && n.Text == "k") second = n;
				else if (n.IsCountingLoop && n.Text == "j") shortForm = n;
				else if (!n.IsCountingLoop) texts++;
			}
			Check(first != null && first.FindOutput("counter").Label == "i" && first.FindOutput("counter").TypeName == "int", "for (int i = 0; i < count; i++): a counter pin named i, typed int");
			Check(first != null && first.FindInput("start") != null && first.FindInput("start").Default == "0", "Start is an input pin holding 0");
			let countSrc = (first != null) ? g.DataSource(first.FindInput("count")) : null;
			Check(countSrc != null && countSrc.Kind == .Get && countSrc.Text == "count", "Count is an input pin wired from the count parameter");
			Check(second != null && second.FindInput("count").Default == "10", "for (int  k=1 ;k<10;k++): a counting loop too");
			Check(shortForm != null && shortForm.FindInput("start") == null && shortForm.FindInput("count").Default == "3", "for (int j < 3): Count only");
			Check(texts == 3, "<=, ++b and (;;) stay header text");

			// Identity and forced regeneration are byte for byte.
			doc.PushUndo();
			first.Edited = true;
			let idOk = doc.Commit(mg);
			Check(idOk && doc.Text == cLoops, "identity commit is byte for byte");
			mg = doc.FindMethod("Host.Count(int)");
			ForceRegenerate(mg.Graph);
			doc.PushUndo();
			let rgOk = doc.Commit(mg);
			Check(rgOk && doc.Text == cLoops, "forced regeneration is byte for byte");

			// A new For Loop with the counter wired into a print.
			mg = doc.FindMethod("Host.Count(int)");
			g = mg.Graph;
			doc.PushUndo();
			let loop = NodeFactory.Loop(g, .For);
			Check(loop.IsCountingLoop && loop.FindOutput("counter").Label == "i" && loop.FindInput("count").Default == "10", "a new For Loop counts with i from 0 to 10");
			let print = NewWriteLine(g, "");
			g.Connect(loop.FindOutput("counter"), print.FindInput("arg0"));
			g.Connect(loop.FindOutput("body"), print.ExecIn);
			let last = g.ExecTarget(g.Entry.Then);
			g.Connect(g.Entry.Then, loop.ExecIn);
			g.Connect(loop.Then, last.ExecIn);
			loop.FindInput("count").Default.Set("5");
			bool ok = doc.Commit(mg);
			Check(ok && doc.Text.Contains("\t\t\tfor (int i = 0; i < 5; i++)\n\t\t\t{\n\t\t\t\tConsole.WriteLine(i);\n\t\t\t}\n\t\t\tfor (int i = 0; i < count; i++)"), "the wired counter is written as i");

			// Read back: the same node shape.
			SourceDocument fresh = scope .();
			fresh.LoadFromText(doc.Text, "Loops2.bf");
			let fg = fresh.FindMethod("Host.Count(int)").Graph;
			let ffirst = fg.ExecTarget(fg.Entry.Then);
			Check(ffirst != null && ffirst.IsCountingLoop && ffirst.FindOutput("counter").Label == "i" && ffirst.FindInput("count").Default == "5", "reads back as a counting loop with the pin named i");

			// Renaming the counter (Properties > Counter Name) renames the header and the wire's reads.
			mg = doc.FindMethod("Host.Count(int)");
			g = mg.Graph;
			let again = g.ExecTarget(g.Entry.Then);
			doc.PushUndo();
			again.Text.Set("n");
			again.FindOutput("counter").Label.Set("n");
			again.Text2.Set("uint8");
			again.Edited = true;
			let reader = NewWriteLine(g, "");
			g.Connect(again.FindOutput("counter"), reader.FindInput("arg0"));
			let inBody = g.ExecTarget(again.FindOutput("body"));
			g.Connect(again.FindOutput("body"), reader.ExecIn);
			if (inBody != null)
				g.Connect(reader.Then, inBody.ExecIn);
			ok = doc.Commit(mg);
			Check(ok && doc.Text.Contains("for (uint8 n = 0; n < 5; n++)") && doc.Text.Contains("Console.WriteLine(n);"), "a renamed, retyped counter writes the header and its reads");
			doc.Undo();
			doc.Undo();
			Check(doc.Text == cLoops, "undo restores the file");
		}

		public static int Run()
		{
			RunParse();
			RunSwitchGraph();
			RunSwitchEdits();
			RunMerge();
			RunMacroParse();
			RunMacroFields();
			RunMacroRefusals();
			RunCountingLoops();
			PinTests.Run();
			// The call model (Target / self / static, out and ref pins, GraphValidator).
			let callFailures = CallTests.Run();
			// Edits inside Defer / Using bodies (docs/Lifetime-Nodes.md).
			let checksBefore = LifetimeTests.Checks;
			let bodyFailures = LifetimeTests.RunBodies();
			let bodyChecks = LifetimeTests.Checks - checksBefore;
			// Locals and a Set spliced after a statement (docs/Classes-and-Members.md#locals).
			LocalsTests.Checks = 0;
			LocalsTests.Failures = 0;
			LocalsTests.RunFlow();
			let localChecks = LocalsTests.Checks;
			let localFailures = LocalsTests.Failures;
			Console.WriteLine("flow checks: {}  failures: {}", sChecks + CallTests.Checks + bodyChecks + localChecks + PinTests.Checks, sFailures + callFailures + bodyFailures + localFailures + PinTests.Failures);
			return sFailures + callFailures + bodyFailures + localFailures + PinTests.Failures;
		}
	}
}
