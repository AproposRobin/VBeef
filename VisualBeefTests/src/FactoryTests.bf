using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// Nodes made by the action menu (NodeFactory) must look exactly like the nodes GraphBuilder
	/// makes from the code they generate, so a file reopened later shows what the user placed.
	/// Each case builds a small graph with NodeFactory, commits it, then checks that
	///  1. the live graph is the same object with the same nodes (no morph on commit), and
	///  2. a fresh GraphBuilder pass over the written code gives the same nodes: kind, title,
	///     pure/exec, pin names and kinds, and wiring.
	static class FactoryTests
	{
		static int sFailures;
		static int sCases;

		const String cHost =
			"""
			using System;
			using System.Collections;

			namespace Demo
			{
				enum Mode { Idle, Run }

				class Host
				{
					public Mode mMode;
					public int mValue = 1;
					public List<int> mItems = new .() ~ delete _;
					public bool mFlag;
					public Event<delegate void()> mOnTick ~ _.Dispose();

					public int Compute(int a)
					{
						return a;
					}

					public void Ping()
					{
					}

					public void Each(delegate void(int) f)
					{
					}

					public void SortBy(Comparison<int> c)
					{
					}

					public int Calc()
					{
					}

					public void Target()
					{
					}

					public bool TryGet(int key, out int value)
					{
						value = key;
						return true;
					}

					public void Fill(ref int total)
					{
						total++;
					}

					public static void Log(String text)
					{
					}

					public static void Stamp()
					{
					}

					public static Result<int> Parse(int a)
					{
						return a;
					}
				}
			}

			""";

		static void Fail(StringView what)
		{
			Console.WriteLine("  FAIL {}", what);
			sFailures++;
		}

		/// Kind, title, pure/exec, pins and wiring of every node in the flow, by structural key.
		public static void Describe(Graph g, String o)
		{
			KeyAssigner.Assign(g);
			Dictionary<Pin, Link> linkTo = scope .();
			for (let l in g.Links)
				linkTo[l.To] = l;
			List<Node> nodes = scope .();
			for (let n in g.Nodes)
				if (!n.Key.StartsWith("orphan"))
					nodes.Add(n);
			nodes.Sort(scope (a, b) => String.Compare(a.Key, b.Key, false));
			for (let l in g.Locals)
				o.AppendF("local {} {} = {}\n", l.Text2, l.Text, l.FindInput("value")?.Default);
			String title = scope .();
			for (let n in nodes)
			{
				title.Clear();
				n.GetTitle(title);
				o.AppendF("{} {} \"{}\" {}", n.Key, n.Kind, title, n.IsPure ? "pure" : "exec");
				if (n.Kind == .Call)
					o.AppendF(" {}{}", n.Binding, (n.Qualifier != null && !n.Qualifier.IsEmpty) ? scope:: $" {n.Qualifier}." : "");
				// Call.Text2 is the temp name CodeGen picks; other kinds keep a declared type there.
				if (n.Kind != .Call && !n.Text2.IsEmpty)
					o.AppendF(" [{}]", n.Text2);
				o.Append(" in(");
				for (let p in n.Inputs)
				{
					if (@p.Index > 0)
						o.Append(", ");
					o.AppendF("{}{}:{}", p.IsRefArg ? "ref " : "", p.Name, (p.Kind == .Exec) ? "x" : "d");
					if (p.Kind != .Data)
						continue;
					if (linkTo.TryGetValue(p, let l))
						o.AppendF("<{}.{}", l.From.Owner.Key, l.From.Name);
					else if (!p.Default.IsEmpty)
						o.AppendF("={}", p.Default);
				}
				o.Append(") out(");
				for (let p in n.Outputs)
				{
					if (@p.Index > 0)
						o.Append(", ");
					o.AppendF("{}:{}", p.Name, (p.Kind == .Exec) ? "x" : "d");
					// (How an out variable is spelled, `?` / `var v` / `T v;`, is chosen at commit like
					// a temp name; CallTests checks the spellings.)
					if (p.IsOutArg)
						o.AppendF(" out {}", p.TypeName);
				}
				o.Append(")\n");
			}
		}

		static Node Say(Graph g, StringView format)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
			NodeFactory.AddArgument(g, n).Default.Set(format);
			return n;
		}

		/// Construct / Delete / Defer / Using / Result nodes from the action menu read back as the
		/// same nodes (docs/Lifetime-Nodes.md).
		static void RunLifetimeCases()
		{
			StringView[0] none = .();
			StringView[1] aName = .("a");
			StringView[1] intType = .("int");

			Case("construct (scope) into a local", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.Construct(g, "List<int>", "scope", none, none);
					let l = NodeFactory.LocalVar(g, "list", "var");
					g.Connect(c.Result, l.FindInput("value"));
					Chain(g, l);
				});

			Case("construct (new) with an argument, deleted by a Defer", "Host.Target()", scope [&] (g) =>
				{
					StringView[1] cap = .("capacity");
					let c = NodeFactory.Construct(g, "String", "new", cap, intType);
					c.FindInput("arg0").Default.Set("16");
					let l = NodeFactory.LocalVar(g, "text", "var");
					g.Connect(c.Result, l.FindInput("value"));
					let d = NodeFactory.Defer(g);
					let del = NodeFactory.Delete(g);
					g.Connect(NodeFactory.Get(g, "text", "").Result, del.FindInput("value"));
					g.Connect(d.FindOutput("body"), del.ExecIn);
					Chain(g, l, d);
				});

			Case("construct array, inferred and string forms", "Host.Target()", scope [&] (g) =>
				{
					let arr = NodeFactory.Construct(g, "int", "scope::", none, none, true);
					arr.FindInput("arg0").Default.Set("4");
					let l1 = NodeFactory.LocalVar(g, "buffer", "var");
					g.Connect(arr.Result, l1.FindInput("value"));
					let inf = NodeFactory.Construct(g, ".", "scope", none, none);
					let l2 = NodeFactory.LocalVar(g, "name", "String");
					g.Connect(inf.Result, l2.FindInput("value"));
					let str = NodeFactory.Construct(g, "$", "scope", none, none);
					let fmt = NodeFactory.Format(g, "$\"v={}\"");
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, fmt.FindInput("arg0"));
					g.Connect(fmt.Result, str.FindInput("arg0"));
					let log = NodeFactory.StaticCall(g, "Log", "", "Host", true, aName, intType, "void");
					g.Connect(str.Result, log.FindInput("arg0"));
					Chain(g, l1, l2, log);
				});

			Case("defer with a block", "Host.Target()", scope [&] (g) =>
				{
					let d = NodeFactory.Defer(g, "defer::");
					let a = Say(g, "\"a\"");
					let b = Say(g, "\"b\"");
					g.Connect(d.FindOutput("body"), a.ExecIn);
					g.Connect(a.Then, b.ExecIn);
					Chain(g, d);
				});

			Case("using, with and without a variable", "Host.Target()", scope [&] (g) =>
				{
					let u1 = NodeFactory.Using(g);
					g.Connect(NodeFactory.Get(g, "mItems", "List<int>").Result, u1.FindInput("value"));
					g.Connect(u1.FindOutput("body"), Say(g, "\"in\"").ExecIn);
					let u2 = NodeFactory.Using(g, "items", "let");
					g.Connect(NodeFactory.Get(g, "mItems", "List<int>").Result, u2.FindInput("value"));
					g.Connect(u2.FindOutput("body"), Say(g, "\"in 2\"").ExecIn);
					Chain(g, u1, u2);
				});

			Case("result match (Ok, payload read) and (Err)", "Host.Target()", scope [&] (g) =>
				{
					let p1 = NodeFactory.StaticCall(g, "Parse", "", "Host", false, aName, intType, "Result<int>");
					p1.FindInput("arg0").Default.Set("1");
					let m = NodeFactory.ResultMatch(g, true, "Result<int>");
					g.Connect(p1.Result, m.FindInput("value"));
					let set = NodeFactory.Set(g, "mValue", "int");
					g.Connect(m.FindOutput("payload"), set.FindInput("value"));
					g.Connect(m.FindOutput("ok"), set.ExecIn);
					g.Connect(m.FindOutput("err"), Say(g, "\"bad\"").ExecIn);
					let p2 = NodeFactory.StaticCall(g, "Parse", "", "Host", false, aName, intType, "Result<int>");
					p2.FindInput("arg0").Default.Set("2");
					let m2 = NodeFactory.ResultMatch(g, false, "Result<int>");
					g.Connect(p2.Result, m2.FindInput("value"));
					g.Connect(m2.FindOutput("err"), Say(g, "\"bad 2\"").ExecIn);
					Chain(g, m, m2);
				});
		}

		/// Switch and flow-macro nodes from the action menu read back as the same nodes.
		static void RunFlowCases()
		{
			Case("switch on int", "Host.Target()", scope [&] (g) =>
				{
					StringView[2] labels = .("1", "2, 3");
					let sw = NodeFactory.Switch(g, "int", labels);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, sw.FindInput("value"));
					g.Connect(sw.FindOutput("case0"), Say(g, "\"one\"").ExecIn);
					g.Connect(sw.FindOutput("case1"), Say(g, "\"two\"").ExecIn);
					g.Connect(sw.FindOutput("default"), Say(g, "\"other\"").ExecIn);
					g.Connect(sw.Then, Say(g, "\"done\"").ExecIn);
					Chain(g, sw);
				});

			Case("switch on string without default", "Host.Target()", scope [&] (g) =>
				{
					StringView[2] labels = .("\"a\"", "\"b\"");
					let sw = NodeFactory.Switch(g, "String", labels);
					sw.FindInput("value").Default.Set("\"a\"");
					g.Connect(sw.FindOutput("case0"), Say(g, "\"A\"").ExecIn);
					g.Connect(sw.FindOutput("case1"), Say(g, "\"B\"").ExecIn);
					Chain(g, sw);
				});

			Case("switch on enum cases", "Host.Target()", scope [&] (g) =>
				{
					StringView[2] labels = .(".Idle", ".Run");
					let sw = NodeFactory.Switch(g, "Mode", labels);
					g.Connect(NodeFactory.Get(g, "mMode", "Mode").Result, sw.FindInput("value"));
					g.Connect(sw.FindOutput("case1"), Say(g, "\"run\"").ExecIn);
					Chain(g, sw);
				});

			Case("switch on enum with every arm empty", "Host.Target()", scope [&] (g) =>
				{
					StringView[3] labels = .(".Idle", ".Run", ".Jump");
					let sw = NodeFactory.Switch(g, "Mode", labels);
					g.Connect(NodeFactory.Get(g, "mMode", "Mode").Result, sw.FindInput("value"));
					Chain(g, sw);
				});

			Case("sequence of three", "Host.Target()", scope [&] (g) =>
				{
					let seq = NodeFactory.Flow(g, FlowMacros.Sequence, null, 3);
					g.Connect(seq.FindOutput("seq0"), Say(g, "\"a\"").ExecIn);
					g.Connect(seq.FindOutput("seq1"), Say(g, "\"b\"").ExecIn);
					g.Connect(seq.FindOutput("seq2"), Say(g, "\"c\"").ExecIn);
					g.Connect(seq.Then, Say(g, "\"after\"").ExecIn);
					Chain(g, seq);
				});

			Case("do once and its reset", "Host.Target()", scope [&] (g) =>
				{
					let once = NodeFactory.Flow(g, FlowMacros.DoOnce);
					g.Connect(once.FindOutput("body"), Say(g, "\"once\"").ExecIn);
					let reset = NodeFactory.Flow(g, FlowMacros.DoOnceReset);
					Chain(g, once, reset);
				});

			Case("do n", "Host.Target()", scope [&] (g) =>
				{
					let don = NodeFactory.Flow(g, FlowMacros.DoN);
					don.FindInput("n").Default.Set("2");
					g.Connect(don.FindOutput("body"), Say(g, "\"n\"").ExecIn);
					let reset = NodeFactory.Flow(g, FlowMacros.DoNReset);
					Chain(g, don, reset);
				});

			Case("flip flop", "Host.Target()", scope [&] (g) =>
				{
					let ff = NodeFactory.Flow(g, FlowMacros.FlipFlop);
					g.Connect(ff.FindOutput("a"), Say(g, "\"A\"").ExecIn);
					g.Connect(ff.FindOutput("b"), Say(g, "\"B\"").ExecIn);
					g.Connect(ff.Then, Say(g, "\"after\"").ExecIn);
					Chain(g, ff);
				});

			Case("gates: open, close, toggle", "Host.Target()", scope [&] (g) =>
				{
					let gate = NodeFactory.Flow(g, FlowMacros.Gate);
					FlowMacros.SetGateStartClosed(gate, true);
					g.Connect(gate.FindOutput("body"), Say(g, "\"through\"").ExecIn);
					let open = NodeFactory.Flow(g, FlowMacros.GateOpen);
					let close = NodeFactory.Flow(g, FlowMacros.GateClose);
					let toggle = NodeFactory.Flow(g, FlowMacros.GateToggle);
					Chain(g, gate, open, close, toggle);
				});

			Case("gate that starts open", "Host.Target()", scope [&] (g) =>
				{
					let gate = NodeFactory.Flow(g, FlowMacros.Gate);
					g.Connect(gate.FindOutput("body"), Say(g, "\"through\"").ExecIn);
					let close = NodeFactory.Flow(g, FlowMacros.GateClose);
					let open = NodeFactory.Flow(g, FlowMacros.GateOpen);
					Chain(g, gate, close, open);
				});

			Case("multi gate, looping", "Host.Target()", scope [&] (g) =>
				{
					let mgate = NodeFactory.Flow(g, FlowMacros.MultiGate, null, 3);
					mgate.Postfix = true;
					g.Connect(mgate.FindOutput("out0"), Say(g, "\"0\"").ExecIn);
					g.Connect(mgate.FindOutput("out1"), Say(g, "\"1\"").ExecIn);
					g.Connect(mgate.FindOutput("out2"), Say(g, "\"2\"").ExecIn);
					let reset = NodeFactory.Flow(g, FlowMacros.MultiGateReset);
					Chain(g, mgate, reset);
				});

			Case("multi gate, one shot each", "Host.Target()", scope [&] (g) =>
				{
					let mgate = NodeFactory.Flow(g, FlowMacros.MultiGate, null, 2);
					g.Connect(mgate.FindOutput("out0"), Say(g, "\"0\"").ExecIn);
					g.Connect(mgate.FindOutput("out1"), Say(g, "\"1\"").ExecIn);
					Chain(g, mgate);
				});

			Case("nested: do once inside a switch arm inside a sequence", "Host.Target()", scope [&] (g) =>
				{
					let seq = NodeFactory.Flow(g, FlowMacros.Sequence, null, 2);
					StringView[1] labels = .("0");
					let sw = NodeFactory.Switch(g, "int", labels);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, sw.FindInput("value"));
					let once = NodeFactory.Flow(g, FlowMacros.DoOnce);
					g.Connect(sw.FindOutput("case0"), once.ExecIn);
					g.Connect(once.FindOutput("body"), Say(g, "\"deep\"").ExecIn);
					g.Connect(seq.FindOutput("seq0"), sw.ExecIn);
					g.Connect(seq.FindOutput("seq1"), Say(g, "\"second\"").ExecIn);
					Chain(g, seq);
				});
		}

		static void Chain(Graph g, params Node[] nodes)
		{
			Pin prev = g.Entry.Then;
			for (let n in nodes)
			{
				g.Connect(prev, n.ExecIn);
				prev = n.Then;
			}
		}

		static void Case(StringView name, StringView methodKey, delegate void(Graph g) build)
		{
			sCases++;
			Console.WriteLine("Factory: {}", name);
			SourceDocument doc = scope .();
			doc.LoadFromText(cHost, "Host.bf");
			let mg = doc.FindMethod(methodKey);
			if (mg == null)
			{
				Fail(scope $"{name}: method {methodKey} not found");
				return;
			}
			let g = mg.Graph;
			doc.PushUndo();
			build(g);
			String placed = scope .();
			Describe(g, placed);
			List<Node> placedNodes = scope .();
			for (let n in g.Nodes)
				placedNodes.Add(n);

			doc.Commit(mg);

			let mg2 = doc.FindMethod(methodKey);
			if (mg2 == null || mg2.Graph != g)
			{
				Fail(scope $"{name}: the live graph was replaced by the commit");
				return;
			}
			for (let n in placedNodes)
			{
				if (!g.Nodes.Contains(n))
				{
					Fail(scope $"{name}: a placed node disappeared");
					return;
				}
			}
			String live = scope .();
			Describe(g, live);
			if (live != placed)
			{
				Fail(scope $"{name}: nodes changed on commit");
				Program.ShowDiff(placed, live);
			}

			// What reopening the file would show.
			let fresh = GraphBuilder.Build(doc.Unit, mg2.Method, mg2.Owner);
			defer delete fresh;
			String rebuilt = scope .();
			Describe(fresh, rebuilt);
			if (rebuilt != live)
			{
				Fail(scope $"{name}: code reads back as different nodes");
				Program.ShowDiff(live, rebuilt);
				String body = scope .();
				doc.GenerateMethodBody(mg2, body);
				Console.WriteLine("  code:{}", body);
			}
			else
				Console.WriteLine("  ok   {}", name);

			// A second commit with nothing changed must not change the text.
			String before = scope .(doc.Text);
			doc.Commit(mg2);
			if (doc.Text != before)
			{
				Fail(scope $"{name}: a no-op commit changed the text");
				Program.ShowDiff(before, doc.Text);
			}
		}

		public static int Run()
		{
			sFailures = 0;
			StringView[0] none = .();
			StringView[1] formatName = .("format");
			StringView[1] stringType = .("String");
			StringView[1] aName = .("a");
			StringView[1] intType = .("int");
			StringView[2] abNames = .("a", "b");
			StringView[2] varTypes = .("var", "var");

			Case("static call by dotted name (Console.WriteLine)", "Host.Target()", scope [&] (g) =>
				{
					let n = NodeFactory.Call(g, "Console.WriteLine", true, false, "", formatName, stringType, "void");
					n.FindInput("arg0").Default.Set("\"hi\"");
					Chain(g, n);
				});

			Case("static call with an explicit qualifier", "Host.Target()", scope [&] (g) =>
				{
					let n = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, formatName, stringType, "void");
					n.FindInput("arg0").Default.Set("\"hi\"");
					Chain(g, n);
				});

			Case("own static call (no qualifier, no Target)", "Host.Target()", scope [&] (g) =>
				{
					StringView[1] textName = .("text");
					let n = NodeFactory.StaticCall(g, "Log", "", "Host", true, textName, stringType, "void");
					n.FindInput("arg0").Default.Set("\"x\"");
					Chain(g, n, NodeFactory.StaticCall(g, "Stamp", "", "Host", true, none, none, "void"));
				});

			Case("call to own void method (Target = self)", "Host.Target()", scope [&] (g) =>
				{
					Chain(g, NodeFactory.MemberCall(g, "Ping", "Host", true, none, none, "void"));
				});

			Case("self node wired into Target (this.Ping())", "Host.Target()", scope [&] (g) =>
				{
					let n = NodeFactory.MemberCall(g, "Ping", "Host", true, none, none, "void");
					g.Connect(NodeFactory.This(g, "Host").Result, n.FindInput("target"));
					Chain(g, n);
				});

			Case("out parameter as an output pin", "Host.Target()", scope [&] (g) =>
				{
					StringView[2] names = .("key", "value");
					StringView[2] types = .("int", "int");
					StringView[2] mods = .("", "out");
					let n = NodeFactory.MemberCall(g, "TryGet", "Host", true, names, types, "bool", mods);
					n.FindInput("arg0").Default.Set("4");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(n.FindOutput("arg1"), s.FindInput("value"));
					Chain(g, n, s);
				});

			Case("unread out pin still declares its variable", "Host.Target()", scope [&] (g) =>
				{
					StringView[2] names = .("key", "value");
					StringView[2] types = .("int", "int");
					StringView[2] mods = .("", "out");
					let n = NodeFactory.MemberCall(g, "TryGet", "Host", true, names, types, "bool", mods);
					n.FindInput("arg0").Default.Set("1");
					Chain(g, n);
				});

			Case("ref parameter wired from a variable", "Host.Target()", scope [&] (g) =>
				{
					StringView[1] names = .("total");
					StringView[1] mods = .("ref");
					let n = NodeFactory.MemberCall(g, "Fill", "Host", true, names, intType, "void", mods);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, n.FindInput("arg0"));
					Chain(g, n);
				});

			Case("call to own method, result unused", "Host.Target()", scope [&] (g) =>
				{
					let n = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
					n.FindInput("arg0").Default.Set("1");
					Chain(g, n);
				});

			Case("impure call whose value is used", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
					c.FindInput("arg0").Default.Set("5");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(c.Result, s.FindInput("value"));
					Chain(g, c, s);
				});

			Case("impure call value used twice, two calls", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
					c.FindInput("arg0").Default.Set("5");
					let c2 = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
					g.Connect(c.Result, c2.FindInput("arg0"));
					let s = NodeFactory.Set(g, "mValue", "int");
					let add = NodeFactory.Operator(g, "+", true);
					g.Connect(c.Result, add.FindInput("a"));
					g.Connect(c2.Result, add.FindInput("b"));
					g.Connect(add.Result, s.FindInput("value"));
					Chain(g, c, c2, s);
				});

			Case("impure call value used as a call target", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
					c.FindInput("arg0").Default.Set("5");
					let w = NodeFactory.Call(g, "ToString", true, true, "", none, none, "var");
					g.Connect(c.Result, w.FindInput("target"));
					Chain(g, c, w);
				});

			Case("pure call", "Host.Target()", scope [&] (g) =>
				{
					let p = NodeFactory.MemberCall(g, "Compute", "Host", false, aName, intType, "int");
					p.FindInput("arg0").Default.Set("2");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(p.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("pure static call by dotted name (Math.Max)", "Host.Target()", scope [&] (g) =>
				{
					let p = NodeFactory.Call(g, "Math.Max", false, false, "", abNames, varTypes, "var");
					p.FindInput("arg0").Default.Set("1");
					p.FindInput("arg1").Default.Set("2");
					let l = NodeFactory.LocalVar(g, "m", "var");
					g.Connect(p.Result, l.FindInput("value"));
					Chain(g, l);
				});

			Case("member call with typed target", "Host.Target()", scope [&] (g) =>
				{
					let n = NodeFactory.Call(g, "Add", true, true, "", none, none, "var");
					g.Connect(NodeFactory.Get(g, "mItems", "List<int>").Result, n.FindInput("target"));
					NodeFactory.AddArgument(g, n).Default.Set("3");
					Chain(g, n);
				});

			Case("member call on a computed target", "Host.Target()", scope [&] (g) =>
				{
					let idx = NodeFactory.Index(g);
					idx.FindInput("target").Default.Set("mItems");
					idx.FindInput("arg0").Default.Set("0");
					let n = NodeFactory.Call(g, "ToString", true, true, "", none, none, "var");
					g.Connect(idx.Result, n.FindInput("target"));
					Chain(g, n);
				});

			Case("get / set", "Host.Target()", scope [&] (g) =>
				{
					let s = NodeFactory.Set(g, "mValue", "int");
					let add = NodeFactory.Operator(g, "+", true);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, add.FindInput("a"));
					add.FindInput("b").Default.Set("1");
					g.Connect(add.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("set with ++", "Host.Target()", scope [&] (g) =>
				{
					Chain(g, NodeFactory.Set(g, "mValue", "int", "++"));
				});

			Case("compound set (+=)", "Host.Target()", scope [&] (g) =>
				{
					let s = NodeFactory.Set(g, "mValue", "int", "+=");
					s.FindInput("value").Default.Set("2");
					Chain(g, s);
				});

			Case("local variable", "Host.Target()", scope [&] (g) =>
				{
					// One of the function's Locals, read by a Get.
					NodeFactory.AddLocal(g, "count", "int", "3");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(NodeFactory.Get(g, "count", "int").Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("branch", "Host.Target()", scope [&] (g) =>
				{
					let b = NodeFactory.Branch(g);
					let cmp = NodeFactory.Operator(g, ">", true);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, cmp.FindInput("a"));
					cmp.FindInput("b").Default.Set("0");
					g.Connect(cmp.Result, b.FindInput("condition"));
					let w = NodeFactory.Call(g, "Console.WriteLine", true, false, "", formatName, stringType, "void");
					w.FindInput("arg0").Default.Set("\"positive\"");
					g.Connect(b.FindOutput("true"), w.ExecIn);
					let p = NodeFactory.MemberCall(g, "Ping", "Host", true, none, none, "void");
					g.Connect(b.FindOutput("false"), p.ExecIn);
					let s = NodeFactory.Set(g, "mValue", "int");
					s.FindInput("value").Default.Set("0");
					Chain(g, b, s);
				});

			Case("while loop", "Host.Target()", scope [&] (g) =>
				{
					let w = NodeFactory.Loop(g, .While);
					let cmp = NodeFactory.Operator(g, "<", true);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, cmp.FindInput("a"));
					cmp.FindInput("b").Default.Set("10");
					g.Connect(cmp.Result, w.FindInput("condition"));
					let inc = NodeFactory.Set(g, "mValue", "int", "++");
					g.Connect(w.FindOutput("body"), inc.ExecIn);
					Chain(g, w);
				});

			Case("do-while loop", "Host.Target()", scope [&] (g) =>
				{
					let w = NodeFactory.Loop(g, .DoWhile);
					g.Connect(NodeFactory.Get(g, "mFlag", "bool").Result, w.FindInput("condition"));
					let p = NodeFactory.MemberCall(g, "Ping", "Host", true, none, none, "void");
					g.Connect(w.FindOutput("body"), p.ExecIn);
					Chain(g, w);
				});

			Case("for loop", "Host.Target()", scope [&] (g) =>
				{
					let f = NodeFactory.Loop(g, .For);
					// (An int wired into a String pin is refused; WriteLine(Object) takes it.)
					StringView[1] objType = .("Object");
					let w = NodeFactory.Call(g, "Console.WriteLine", true, false, "", formatName, objType, "void");
					g.Connect(NodeFactory.Get(g, "i", "int").Result, w.FindInput("arg0"));
					g.Connect(f.FindOutput("body"), w.ExecIn);
					Chain(g, f);
				});

			Case("for-each loop with break / continue", "Host.Target()", scope [&] (g) =>
				{
					let f = NodeFactory.Loop(g, .ForEach);
					// (A bare name typed as a pin default reads back as a Get node; wire one.)
					g.Connect(NodeFactory.Get(g, "mItems", "List<int>").Result, f.FindInput("collection"));
					let b = NodeFactory.Branch(g);
					g.Connect(NodeFactory.Get(g, "mFlag", "bool").Result, b.FindInput("condition"));
					g.Connect(b.FindOutput("true"), NodeFactory.Jump(g, .Continue).ExecIn);
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(NodeFactory.Get(g, "item", "int").Result, s.FindInput("value"));
					let brk = NodeFactory.Jump(g, .Break);
					g.Connect(f.FindOutput("body"), b.ExecIn);
					g.Connect(b.Then, s.ExecIn);
					g.Connect(s.Then, brk.ExecIn);
					Chain(g, f);
				});

			Case("return with a value", "Host.Calc()", scope [&] (g) =>
				{
					let r = NodeFactory.Return(g, "int");
					let mul = NodeFactory.Operator(g, "*", true);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, mul.FindInput("a"));
					mul.FindInput("b").Default.Set("2");
					g.Connect(mul.Result, r.FindInput("value"));
					Chain(g, r);
				});

			Case("return without a value", "Host.Target()", scope [&] (g) =>
				{
					Chain(g, NodeFactory.Return(g, "void"));
				});

			Case("unary operators", "Host.Target()", scope [&] (g) =>
				{
					let not = NodeFactory.Operator(g, "!", false);
					g.Connect(NodeFactory.Get(g, "mFlag", "bool").Result, not.FindInput("a"));
					let s = NodeFactory.Set(g, "mFlag", "bool");
					g.Connect(not.Result, s.FindInput("value"));
					let neg = NodeFactory.Operator(g, "-", false);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, neg.FindInput("a"));
					let s2 = NodeFactory.Set(g, "mValue", "int");
					g.Connect(neg.Result, s2.FindInput("value"));
					Chain(g, s, s2);
				});

			Case("binary operators with precedence", "Host.Target()", scope [&] (g) =>
				{
					let add = NodeFactory.Operator(g, "+", true);
					let mul = NodeFactory.Operator(g, "*", true);
					g.Connect(add.Result, mul.FindInput("a"));
					add.FindInput("a").Default.Set("1");
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, add.FindInput("b"));
					mul.FindInput("b").Default.Set("3");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(mul.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("select", "Host.Target()", scope [&] (g) =>
				{
					let sel = NodeFactory.Select(g);
					g.Connect(NodeFactory.Get(g, "mFlag", "bool").Result, sel.FindInput("condition"));
					sel.FindInput("a").Default.Set("1");
					sel.FindInput("b").Default.Set("2");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(sel.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("cast", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.Cast(g, "float");
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, c.FindInput("value"));
					let l = NodeFactory.LocalVar(g, "f", "float");
					g.Connect(c.Result, l.FindInput("value"));
					Chain(g, Say(g, "\"cast\""), l); // not first: a declaration at the top with a value of its own is one of the Locals
				});

			Case("index", "Host.Target()", scope [&] (g) =>
				{
					let idx = NodeFactory.Index(g);
					idx.FindInput("target").Default.Set("mItems");
					idx.FindInput("arg0").Default.Set("0");
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(idx.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("member get on a computed target", "Host.Target()", scope [&] (g) =>
				{
					let gm = NodeFactory.GetMember(g, "Count");
					let p = NodeFactory.MemberCall(g, "Compute", "Host", false, aName, intType, "int");
					p.FindInput("arg0").Default.Set("1");
					g.Connect(p.Result, gm.FindInput("target"));
					let s = NodeFactory.Set(g, "mValue", "int");
					g.Connect(gm.Result, s.FindInput("value"));
					Chain(g, s);
				});

			Case("code statement", "Host.Target()", scope [&] (g) =>
				{
					Chain(g, NodeFactory.Code(g, "let (a, b) = (1, 2);"));
				});

			Case("const and ref locals", "Host.Target()", scope [&] (g) =>
				{
					let c = NodeFactory.LocalVar(g, "kLimit", "int", "const");
					c.FindInput("value").Default.Set("3");
					let r = NodeFactory.LocalVar(g, "slot", "int", "ref");
					let refOp = NodeFactory.Operator(g, "ref", false);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, refOp.FindInput("a"));
					g.Connect(refOp.Result, r.FindInput("value"));
					Chain(g, c, r);
				});

			Case("scope block", "Host.Target()", scope [&] (g) =>
				{
					let s = NodeFactory.Scope(g);
					let a = Say(g, "\"inside\"");
					g.Connect(s.FindOutput("body"), a.ExecIn);
					let b = Say(g, "\"after\"");
					Chain(g, s, b);
				});

			Case("cast to the inferred type", "Host.Target()", scope [&] (g) =>
				{
					let l = NodeFactory.LocalVar(g, "f", "float");
					let c = NodeFactory.Cast(g, ".");
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, c.FindInput("value"));
					g.Connect(c.Result, l.FindInput("value"));
					Chain(g, Say(g, "\"cast\""), l);
				});

			Case("value made in place", "Host.Target()", scope [&] (g) =>
				{
					let l = NodeFactory.LocalVar(g, "m", "Mode");
					let v = NodeFactory.Construct(g, ".", "", none, none);
					v.Alloc.Clear();
					g.Connect(v.Result, l.FindInput("value"));
					Chain(g, l);
				});

			Case("delegate from a method, event +=", "Host.Target()", scope [&] (g) =>
				{
					let l = NodeFactory.LocalVar(g, "cb", "delegate void()");
					let d = NodeFactory.DelegateOf(g, "Ping", "scope");
					g.Connect(d.Result, l.FindInput("value"));
					let ev = NodeFactory.Set(g, "mOnTick", "Event<delegate void()>", "+=");
					let d2 = NodeFactory.DelegateOf(g, "Ping", "new");
					g.Connect(d2.Result, ev.FindInput("value"));
					Chain(g, l, ev);
				});

			Case("lambda with an expression body", "Host.Target()", scope [&] (g) =>
				{
					StringView[1] cName = .("c");
					StringView[1] cType = .("Comparison<int>");
					let sort = NodeFactory.Call(g, "SortBy", true, true, "", cName, cType, "void");
					let lam = NodeFactory.Lambda(g, "(a, b)", false, "scope");
					let cmp = NodeFactory.Operator(g, "-", true);
					g.Connect(NodeFactory.Get(g, "a", "").Result, cmp.FindInput("a"));
					g.Connect(NodeFactory.Get(g, "b", "").Result, cmp.FindInput("b"));
					g.Connect(cmp.Result, lam.FindInput("expr"));
					g.Connect(lam.Result, sort.FindArg(0));
					Chain(g, sort);
				});

			Case("lambda with a block body and captures", "Host.Target()", scope [&] (g) =>
				{
					NodeFactory.AddLocal(g, "total", "int", "0");
					StringView[1] fName = .("f");
					StringView[1] fType = .("delegate void(int)");
					let each = NodeFactory.Call(g, "Each", true, true, "", fName, fType, "void");
					let lam = NodeFactory.Lambda(g, "(x)", true, "scope", "[&]");
					let add = NodeFactory.Set(g, "total", "int", "+=");
					g.Connect(NodeFactory.Get(g, "x", "").Result, add.FindInput("value"));
					g.Connect(lam.FindOutput("body"), add.ExecIn);
					let say = Say(g, "\"item\"");
					g.Connect(add.Then, say.ExecIn);
					g.Connect(lam.Result, each.FindArg(0));
					Chain(g, each);
				});

			Case("local function", "Host.Target()", scope [&] (g) =>
				{
					let f = NodeFactory.LocalFunc(g, "void Twice(int n)");
					let a = Say(g, "\"one\"");
					let b = Say(g, "\"two\"");
					g.Connect(f.FindOutput("body"), a.ExecIn);
					g.Connect(a.Then, b.ExecIn);
					let e = NodeFactory.LocalFunc(g, "int Double(int n)", false);
					let mul = NodeFactory.Operator(g, "*", true);
					g.Connect(NodeFactory.Get(g, "n", "").Result, mul.FindInput("a"));
					mul.FindInput("b").Default.Set("2");
					g.Connect(mul.Result, e.FindInput("expr"));
					Chain(g, f, e);
				});

			Case("interpolated string with holes", "Host.Target()", scope [&] (g) =>
				{
					let log = NodeFactory.StaticCall(g, "Log", "", "Host", true, aName, intType, "void");
					let fmt = NodeFactory.Format(g, "$\"value {} hex {:X4} sum {}\"");
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, fmt.FindInput("arg0"));
					let call = NodeFactory.Call(g, "Compute", false, true, "", none, none, "int");
					NodeFactory.AddArgument(g, call);
					call.FindArg(0).Default.Set("2");
					g.Connect(call.Result, fmt.FindInput("arg1"));
					let sum = NodeFactory.Operator(g, "+", true);
					g.Connect(NodeFactory.Get(g, "mValue", "int").Result, sum.FindInput("a"));
					sum.FindInput("b").Default.Set("1");
					g.Connect(sum.Result, fmt.FindInput("arg2"));
					g.Connect(fmt.Result, log.FindInput("arg0"));
					Chain(g, log);
				});

			Case("repeat loop and statement attribute", "Host.Target()", scope [&] (g) =>
				{
					let loop = NodeFactory.Loop(g, .DoWhile);
					loop.Alloc = new String("repeat");
					loop.FindInput("condition").Default.Set("false");
					let inc = NodeFactory.Set(g, "mValue", "int", "++");
					g.Connect(loop.FindOutput("body"), inc.ExecIn);
					let block = NodeFactory.Scope(g);
					block.Attributes = new String("[ConstSkip] ");
					let say = Say(g, "\"x\"");
					g.Connect(block.FindOutput("body"), say.ExecIn);
					Chain(g, loop, block);
				});

			Case("expression node", "Host.Target()", scope [&] (g) =>
				{
					let e = NodeFactory.Expr(g, "mValue = 5");
					let l = NodeFactory.LocalVar(g, "v", "var");
					g.Connect(e.Result, l.FindInput("value"));
					Chain(g, l);
				});

			RunFlowCases();
			RunLifetimeCases();

			Console.WriteLine("factory cases: {}  failures: {}", sCases, sFailures);
			return sFailures;
		}
	}
}
