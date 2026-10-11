using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests compile [-out <dir>] [-v]`
	///
	/// Compile-and-run golden tests for the code generator. Each case is a small Beef program:
	/// build its graph, edit the graph the way the editor does, commit, write the file into a
	/// scratch workspace, build it with BeefBuild, run it and compare stdout with the expected
	/// output. Refusal cases check that graphs the generator can't express safely are not
	/// written, with the reason on the node at fault.
	static class CompileTests
	{
		/// Scratch workspace when no `-out` is given: `<temp>/vb-codegen`.
#if BF_PLATFORM_WINDOWS
		const String cBeefBuild = @"C:\Program Files\BeefLang\bin\BeefBuild.exe";
		const String cPlatform = "Win64";
		const String cExeSuffix = ".exe";
#else
		/// BeefBuild from VB_BEEFBUILD, else the first one on PATH (docs/Linux.md).
		static String cBeefBuild
		{
			get
			{
				if (sBeefBuild.IsEmpty && (Environment.GetEnvironmentVariable("VB_BEEFBUILD", sBeefBuild) case .Err || sBeefBuild.IsEmpty))
				{
					sBeefBuild.Set("BeefBuild");
					String pathVar = scope .();
					Environment.GetEnvironmentVariable("PATH", pathVar).IgnoreError(); // PATH unset: plain name
					for (let dir in pathVar.Split(':'))
					{
						let probe = scope String()..AppendF("{}/BeefBuild", dir);
						if (!dir.IsEmpty && File.Exists(probe))
						{
							sBeefBuild.Set(probe);
							break;
						}
					}
				}
				return sBeefBuild;
			}
		}
		static String sBeefBuild = new .() ~ delete _;
		const String cPlatform = "Linux64";
		const String cExeSuffix = "";
#endif

		typealias MutateFn = function void(Graph g);

		class Case
		{
			public String Name;
			/// Namespace of the case's `Test` class (its `Run()` is called by the test program).
			public String Namespace;
			public String Source;
			public String MethodKey;
			public MutateFn Mutate;
			public String Expected;
			/// Snippets the committed text must contain (style / structure checks).
			public List<String> MustContain = new .() ~ delete _;
			/// Snippets it must not contain.
			public List<String> MustNotContain = new .() ~ delete _;
			/// The committed text must equal the source (the edit doesn't change the code).
			public bool SameAsSource;
			/// Refusal case: Commit must fail with this text in an error on the graph.
			public String RefusalContains;
			/// Install a TypeService over the case's file while it is edited (class-level checks).
			public bool WithTypes;
			/// Class-level edits made before the graph is mutated (Type Settings, Override).
			public function void(SourceDocument doc) Prepare;

			public String Committed = new .() ~ delete _;
			public bool Written;
		}

		static int sFailures;
		static bool sVerbose;

		static void Check(bool cond, StringView what)
		{
			if (cond)
			{
				if (sVerbose)
					Console.WriteLine("  ok   {}", what);
			}
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		// ------------------------------------------------------------------ graph helpers

		static Node FindNode(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		/// The Console.WriteLine (or other call) whose first argument default is `arg0`.
		static Node FindCall(Graph g, StringView name, StringView arg0)
		{
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call || n.Text != name)
					continue;
				let p = n.FindInput("arg0");
				if (p != null && p.Default == arg0)
					return n;
			}
			return null;
		}

		static Node FindLocal(Graph g, StringView name) => FindNode(g, .LocalVar, name);

		static Node NewWriteLine(Graph g, StringView format)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
			NodeFactory.AddArgument(g, n).Default.Set(format);
			return n;
		}

		static Pin AddArg(Graph g, Node call, StringView def = "")
		{
			let p = NodeFactory.AddArgument(g, call);
			p.Default.Set(def);
			return p;
		}

		static Node PureCall(Graph g, StringView name, StringView target, StringView returnType, params StringView[] args)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, name, false, !target.IsEmpty, target, none, none, returnType);
			for (let a in args)
				AddArg(g, n, a);
			return n;
		}

		static Node ExecCall(Graph g, StringView name, StringView returnType, params StringView[] args)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, name, true, false, "", none, none, returnType);
			for (let a in args)
				AddArg(g, n, a);
			return n;
		}

		static Node Compare(Graph g, StringView op, StringView a, StringView b)
		{
			let n = NodeFactory.Operator(g, op, true);
			n.FindInput("a").Default.Set(a);
			n.FindInput("b").Default.Set(b);
			return n;
		}

		static Node NewBranch(Graph g, Node condition)
		{
			let b = NodeFactory.Branch(g);
			g.Connect(condition.Result, b.FindInput("condition"));
			return b;
		}

		// ------------------------------------------------------------------ cases

		static void MutateSharedPop(Graph g)
		{
			// One PopBack() node wired into two locals: it must pop once.
			let pop = PureCall(g, "PopBack", "list", "int");
			g.Connect(pop.Result, FindLocal(g, "a").FindInput("value"));
			g.Connect(pop.Result, FindLocal(g, "b").FindInput("value"));
		}

		static void MutateSharedSameStatement(Graph g)
		{
			let pop = PureCall(g, "PopBack", "list", "int");
			let add = NodeFactory.Operator(g, "+", true);
			g.Connect(pop.Result, add.FindInput("a"));
			g.Connect(pop.Result, add.FindInput("b"));
			g.Connect(add.Result, FindLocal(g, "s").FindInput("value"));
		}

		static void MutateDiamond(Graph g)
		{
			// Both arms of the outer Branch, and both arms of the inner one, continue to "done".
			let done = NewWriteLine(g, "\"done\"");
			g.Connect(FindCall(g, "WriteLine", "\"big\"").Then, done.ExecIn);
			g.Connect(FindCall(g, "WriteLine", "\"small\"").Then, done.ExecIn);
			g.Connect(FindCall(g, "WriteLine", "\"not positive\"").Then, done.ExecIn);
		}

		static void MutateHoist(Graph g)
		{
			// Compute() runs inside the if; its result is printed after the if.
			let compute = ExecCall(g, "Compute", "int", "4");
			g.Connect(FindCall(g, "WriteLine", "\"computing\"").Then, compute.ExecIn);
			let show = NewWriteLine(g, "\"value {}\"");
			g.Connect(compute.Result, AddArg(g, show));
			g.Connect(FindCall(g, "WriteLine", "\"end\"").Then, show.ExecIn);
		}

		static void MutateLoops(Graph g)
		{
			let forNode = FindNode(g, .For);
			let sumSet = FindNode(g, .Set, "+=");
			// for body: if (i == 3) continue;  if (i > 6) break;  sum += i;
			let b1 = NewBranch(g, Compare(g, "==", "i", "3"));
			let cont = NodeFactory.Jump(g, .Continue);
			g.Connect(b1.FindOutput("true"), cont.ExecIn);
			let b2 = NewBranch(g, Compare(g, ">", "i", "6"));
			let brk = NodeFactory.Jump(g, .Break);
			g.Connect(b2.FindOutput("true"), brk.ExecIn);
			g.Connect(forNode.FindOutput("body"), b1.ExecIn);
			g.Connect(b1.Then, b2.ExecIn);
			g.Connect(b2.Then, sumSet.ExecIn);
			// while body: k += 7; if (k > 20) break;
			Node kSet = null;
			for (let n in g.Nodes)
				if (n.Kind == .Set && n.FindInput("target").Default == "k")
					kSet = n;
			let b3 = NewBranch(g, Compare(g, ">", "k", "20"));
			let brk2 = NodeFactory.Jump(g, .Break);
			g.Connect(b3.FindOutput("true"), brk2.ExecIn);
			g.Connect(kSet.Then, b3.ExecIn);
		}

		static void MutateNested(Graph g)
		{
			// if (x < 0) neg  else if (x == 0) zero  else if (x > 50) huge  else pos;  then "end"
			let print = FindCall(g, "WriteLine", "\"x={}\"");
			let b1 = NewBranch(g, Compare(g, "<", "x", "0"));
			let b2 = NewBranch(g, Compare(g, "==", "x", "0"));
			let b3 = NewBranch(g, Compare(g, ">", "x", "50"));
			let neg = NewWriteLine(g, "\"neg\"");
			let zero = NewWriteLine(g, "\"zero\"");
			let huge = NewWriteLine(g, "\"huge\"");
			let pos = NewWriteLine(g, "\"pos\"");
			let fin = NewWriteLine(g, "\"end\"");
			g.Connect(print.Then, b1.ExecIn);
			g.Connect(b1.FindOutput("true"), neg.ExecIn);
			g.Connect(b1.FindOutput("false"), b2.ExecIn);
			g.Connect(b2.FindOutput("true"), zero.ExecIn);
			g.Connect(b2.FindOutput("false"), b3.ExecIn);
			g.Connect(b3.FindOutput("true"), huge.ExecIn);
			g.Connect(b3.FindOutput("false"), pos.ExecIn);
			for (let leaf in Node[4](neg, zero, huge, pos))
				g.Connect(leaf.Then, fin.ExecIn);
		}

		static void MutateOutParams(Graph g)
		{
			let start = FindCall(g, "WriteLine", "\"start\"");
			// A pure call with an out argument, shared by a Branch and a Select.
			let tryHalf = PureCall(g, "TryHalf", "", "bool", "10", "var h");
			let b = NodeFactory.Branch(g);
			g.Connect(tryHalf.Result, b.FindInput("condition"));
			let half = NewWriteLine(g, "\"half={}\"");
			AddArg(g, half, "h");
			g.Connect(b.FindOutput("true"), half.ExecIn);
			let sel = NodeFactory.Select(g);
			g.Connect(tryHalf.Result, sel.FindInput("condition"));
			sel.FindInput("a").Default.Set("\"even\"");
			sel.FindInput("b").Default.Set("\"odd\"");
			let parity = NewWriteLine(g, "\"{}\"");
			g.Connect(sel.Result, AddArg(g, parity));
			g.Connect(start.Then, b.ExecIn);
			g.Connect(b.Then, parity.ExecIn);
			// An impure call with an out argument whose result is used by the next statement.
			let seven = ExecCall(g, "TryHalf", "bool", "7", "var h2");
			let sel2 = NodeFactory.Select(g);
			g.Connect(seven.Result, sel2.FindInput("condition"));
			sel2.FindInput("a").Default.Set("\"even\"");
			sel2.FindInput("b").Default.Set("\"odd\"");
			let show = NewWriteLine(g, "\"seven {} {}\"");
			AddArg(g, show, "h2");
			g.Connect(sel2.Result, AddArg(g, show));
			g.Connect(parity.Then, seven.ExecIn);
			g.Connect(seven.Then, show.ExecIn);
		}

		static Node MemberCall(Graph g, StringView name, StringView owner, StringView paramName, StringView paramType, StringView mod = "", bool outRef = false)
		{
			StringView[1] names = .(paramName);
			StringView[1] types = .(paramType);
			StringView[1] mods = .(mod);
			bool[1] outRefs = .(outRef);
			return NodeFactory.MemberCall(g, name, owner, true, names, types, "void", mods, outRefs);
		}

		static Node TryHalfCall(Graph g, StringView v, bool exec = true)
		{
			StringView[2] names = .("v", "half");
			StringView[2] types = .("int", "int");
			StringView[2] mods = .("", "out");
			let n = NodeFactory.StaticCall(g, "TryHalf", "", "Test", exec, names, types, "bool", mods);
			n.FindInput("arg0").Default.Set(v);
			return n;
		}

		/// Self, static and out / ref calls (docs/Calls-and-Receivers.md), written and run.
		static void MutateCalls(Graph g)
		{
			let start = FindCall(g, "WriteLine", "\"start\"");
			Node last = start;
			void Then(Node n)
			{
				g.Connect(last.Then, n.ExecIn);
				last = n;
			}
			// A base-class member with self (unconnected Target), and with Self wired.
			let hit1 = MemberCall(g, "Hit", "Base", "amount", "int");
			hit1.FindInput("arg0").Default.Set("1");
			Then(hit1);
			let hit2 = MemberCall(g, "Hit", "Base", "amount", "int");
			hit2.FindInput("arg0").Default.Set("2");
			g.Connect(NodeFactory.This(g, "Test").Result, hit2.FindInput("target"));
			Then(hit2);
			// A static call with its qualifier, its value printed.
			StringView[1] xName = .("x");
			StringView[1] intType = .("int");
			let twice = NodeFactory.StaticCall(g, "Twice", "Base", "Base", false, xName, intType, "int");
			twice.FindInput("arg0").Default.Set("21");
			let showTwice = NewWriteLine(g, "\"twice {}\"");
			g.Connect(twice.Result, AddArg(g, showTwice));
			Then(showTwice);
			// out read by the next statement (`var half`), and an unread one (`?`).
			let t10 = TryHalfCall(g, "10");
			Then(t10);
			let showHalf = NewWriteLine(g, "\"half {}\"");
			g.Connect(t10.FindOutput("arg1"), AddArg(g, showHalf));
			Then(showHalf);
			Then(TryHalfCall(g, "3"));
			// out set in a branch, read after it: hoisted `int half2 = default;`.
			let b = NodeFactory.Branch(g);
			b.FindInput("condition").Default.Set("mHp > 5");
			let t8 = TryHalfCall(g, "8");
			g.Connect(b.FindOutput("true"), t8.ExecIn);
			Then(b);
			let showHoist = NewWriteLine(g, "\"hoisted {}\"");
			g.Connect(t8.FindOutput("arg1"), AddArg(g, showHoist));
			Then(showHoist);
			// A while condition that sets the out value, read after the loop: `int half3;` before it.
			let loop = NodeFactory.Loop(g, .While);
			let cond = TryHalfCall(g, "6", false);
			g.Connect(cond.Result, loop.FindInput("condition"));
			let brk = NodeFactory.Jump(g, .Break);
			g.Connect(loop.FindOutput("body"), brk.ExecIn);
			Then(loop);
			let showLoop = NewWriteLine(g, "\"loop {}\"");
			g.Connect(cond.FindOutput("arg1"), AddArg(g, showLoop));
			Then(showLoop);
			// ref from a field, and a [Pin(Out=true)] ref as an output pin.
			let fill = MemberCall(g, "Fill", "Test", "total", "int", "ref");
			g.Connect(NodeFactory.Get(g, "mHp", "int").Result, fill.FindInput("arg0"));
			Then(fill);
			let getAll = MemberCall(g, "GetAll", "Test", "count", "int", "ref", true);
			Then(getAll);
			let showRef = NewWriteLine(g, "\"hp {} count {}\"");
			g.Connect(NodeFactory.Get(g, "mHp", "int").Result, AddArg(g, showRef));
			g.Connect(getAll.FindOutput("arg0"), AddArg(g, showRef));
			Then(showRef);
		}

		static void MutateRefuseTargetStatic(Graph g)
		{
			StringView[0] none = .();
			let call = NodeFactory.MemberCall(g, "Tick", "Test", true, none, none, "void");
			g.Connect(g.Entry.Then, call.ExecIn);
		}

		static void MutateStrings(Graph g)
		{
			let begin = FindCall(g, "WriteLine", "\"begin\"");
			let name = PureCall(g, "GetName", "", "String");
			let both = NewWriteLine(g, "\"{} and {} ({})\"");
			g.Connect(name.Result, AddArg(g, both));
			g.Connect(name.Result, AddArg(g, both));
			AddArg(g, both, "sNameCalls");
			let interp = NewWriteLine(g, "$\"calls={sNameCalls}\"");
			let local = NodeFactory.LocalVar(g, "s", "String");
			local.FindInput("value").Default.Set("scope String()");
			StringView[0] none = .();
			let appendCall = NodeFactory.Call(g, "AppendF", true, true, "s", none, none, "void");
			AddArg(g, appendCall, "\"<{}|{}>\"");
			g.Connect(name.Result, AddArg(g, appendCall));
			AddArg(g, appendCall, "sNameCalls");
			let print = NewWriteLine(g, "s");
			g.Connect(begin.Then, both.ExecIn);
			g.Connect(both.Then, interp.ExecIn);
			g.Connect(interp.Then, local.ExecIn);
			g.Connect(local.Then, appendCall.ExecIn);
			g.Connect(appendCall.Then, print.ExecIn);
		}

		static void MutateArmIntoCompleted(Graph g)
		{
			// The true arm wired into the node the Branch completes into: same code as before.
			g.Connect(FindCall(g, "WriteLine", "\"on\"").Then, FindCall(g, "WriteLine", "\"end\"").ExecIn);
		}

		static void MutateStyle(Graph g)
		{
			// A statement inserted after `int n=0;` (whose exec output changes, text must not).
			let start = NewWriteLine(g, "\"start\"");
			let nLocal = FindLocal(g, "n");
			let loop = FindNode(g, .While);
			g.Connect(nLocal.Then, start.ExecIn);
			g.Connect(start.Then, loop.ExecIn);
			// Body edit inside `while(n < 3) {` and a new Branch after `if(n == 3) {...} else {...}`.
			let inc = FindNode(g, .Set, "++");
			let tick = NewWriteLine(g, "\"tick\"");
			g.Connect(inc.Then, tick.ExecIn);
			let ifNode = FindNode(g, .Branch);
			let b = NewBranch(g, Compare(g, ">", "n", "1"));
			g.Connect(b.FindOutput("true"), NewWriteLine(g, "\"big\"").ExecIn);
			g.Connect(b.FindOutput("false"), NewWriteLine(g, "\"small\"").ExecIn);
			g.Connect(ifNode.Then, b.ExecIn);
		}

		static void MutateRefuseLoopMerge(Graph g)
		{
			// The loop body continues into the node after the loop.
			g.Connect(FindNode(g, .Set, "++").Then, FindCall(g, "WriteLine", "\"after\"").ExecIn);
		}

		static void MutateRefuseSiblingUse(Graph g)
		{
			let compute = ExecCall(g, "Compute", "int", "1");
			g.Connect(FindCall(g, "WriteLine", "\"yes\"").Then, compute.ExecIn);
			let no = FindCall(g, "WriteLine", "\"no\"");
			no.FindInput("arg0").Default.Set("\"no {}\"");
			g.Connect(compute.Result, AddArg(g, no));
		}

		static void MutateRefuseLocalScope(Graph g)
		{
			let tmp = NodeFactory.LocalVar(g, "tmp", "int");
			tmp.FindInput("value").Default.Set("5");
			g.Connect(FindCall(g, "WriteLine", "\"yes\"").Then, tmp.ExecIn);
			let end = FindCall(g, "WriteLine", "\"end\"");
			end.FindInput("arg0").Default.Set("\"end {}\"");
			g.Connect(tmp.FindOutput("variable"), AddArg(g, end));
		}

		static void MutateRefuseSharedScopes(Graph g)
		{
			let compute = PureCall(g, "Compute", "", "int", "2");
			let yes = FindCall(g, "WriteLine", "\"yes\"");
			yes.FindInput("arg0").Default.Set("\"yes {}\"");
			g.Connect(compute.Result, AddArg(g, yes));
			let end = FindCall(g, "WriteLine", "\"end\"");
			end.FindInput("arg0").Default.Set("\"end {}\"");
			g.Connect(compute.Result, AddArg(g, end));
		}

		static void MutateRefuseLoopCondition(Graph g)
		{
			let compute = PureCall(g, "Compute", "", "int", "3");
			let cmp = NodeFactory.Operator(g, "<", true);
			cmp.FindInput("a").Default.Set("i");
			g.Connect(compute.Result, cmp.FindInput("b"));
			g.Connect(cmp.Result, FindNode(g, .While).FindInput("condition"));
			let after = FindCall(g, "WriteLine", "\"after\"");
			after.FindInput("arg0").Default.Set("\"after {}\"");
			g.Connect(compute.Result, AddArg(g, after));
		}

		static void MutateRefuseCycle(Graph g)
		{
			g.Connect(FindCall(g, "WriteLine", "\"end\"").Then, FindNode(g, .Branch).ExecIn);
		}

		static void MutateRefuseUnknownType(Graph g)
		{
			let compute = ExecCall(g, "Compute", "", "1");
			g.Connect(FindCall(g, "WriteLine", "\"yes\"").Then, compute.ExecIn);
			let end = FindCall(g, "WriteLine", "\"end\"");
			end.FindInput("arg0").Default.Set("\"end {}\"");
			g.Connect(compute.Result, AddArg(g, end));
		}

		const String cSharedPop =
			"""
			using System;
			using System.Collections;

			namespace CgSharedPop
			{
				class Test
				{
					public static void Run()
					{
						List<int> list = scope .() { 1, 2, 3, 4 };
						int a = 0;
						int b = 0;
						Console.WriteLine("{} {} {}", a, b, list.Count);
					}
				}
			}

			""";

		const String cSharedSame =
			"""
			using System;
			using System.Collections;

			namespace CgSharedSame
			{
				class Test
				{
					public static void Run()
					{
						List<int> list = scope .() { 5, 7 };
						int s = 0;
						Console.WriteLine("{} {}", s, list.Count);
					}
				}
			}

			""";

		const String cDiamond =
			"""
			using System;

			namespace CgDiamond
			{
				class Test
				{
					public static void Run()
					{
						Check(30);
						Check(3);
						Check(-2);
					}

					static void Check(int x)
					{
						if (x > 0)
						{
							if (x > 10)
							{
								Console.WriteLine("big");
							}
							else
							{
								Console.WriteLine("small");
							}
						}
						else
						{
							Console.WriteLine("not positive");
						}
					}
				}
			}

			""";

		const String cHoist =
			"""
			using System;

			namespace CgHoist
			{
				class Test
				{
					static int sCalls;

					static int Compute(int v)
					{
						sCalls++;
						return v * 10;
					}

					public static void Run()
					{
						Show(true);
						Show(false);
						Console.WriteLine("calls {}", sCalls);
					}

					static void Show(bool flag)
					{
						if (flag)
						{
							Console.WriteLine("computing");
						}
						Console.WriteLine("end");
					}
				}
			}

			""";

		const String cLoops =
			"""
			using System;

			namespace CgLoops
			{
				class Test
				{
					public static void Run()
					{
						int sum = 0;
						for (int i = 0; i < 10; i++)
						{
							sum += i;
						}
						int k = 0;
						while (k < 100)
						{
							k += 7;
						}
						Console.WriteLine("{} {}", sum, k);
					}
				}
			}

			""";

		const String cNested =
			"""
			using System;

			namespace CgNested
			{
				class Test
				{
					public static void Run()
					{
						Classify(-5);
						Classify(0);
						Classify(9);
						Classify(100);
					}

					static void Classify(int x)
					{
						Console.WriteLine("x={}", x);
					}
				}
			}

			""";

		const String cOutParams =
			"""
			using System;

			namespace CgOutParams
			{
				class Test
				{
					static bool TryHalf(int v, out int half)
					{
						half = v / 2;
						return v % 2 == 0;
					}

					public static void Run()
					{
						Console.WriteLine("start");
					}
				}
			}

			""";

		const String cCalls =
			"""
			using System;

			namespace CgCalls
			{
				struct PinAttribute : Attribute
				{
					public bool Out;
				}

				class Base
				{
					public int mHp = 10;

					public void Hit(int amount)
					{
						mHp -= amount;
						Console.WriteLine("hit {} -> {}", amount, mHp);
					}

					public static int Twice(int x)
					{
						return x * 2;
					}
				}

				class Test : Base
				{
					static bool TryHalf(int v, out int half)
					{
						half = v / 2;
						return v % 2 == 0;
					}

					void Fill(ref int total)
					{
						total += 5;
					}

					void GetAll([Pin(Out=true)] ref int count)
					{
						count = 3;
					}

					public void Go()
					{
						Console.WriteLine("start");
					}

					public static void Run()
					{
						CgCalls.Test t = scope .();
						t.Go();
					}
				}
			}

			""";

		const String cStrings =
			"""
			using System;

			namespace CgStrings
			{
				class Test
				{
					static int sNameCalls;

					static String GetName()
					{
						sNameCalls++;
						return "Ada";
					}

					public static void Run()
					{
						Console.WriteLine("begin");
					}
				}
			}

			""";

		const String cStyle =
			"""
			using System;

			namespace CgStyle {
				class Test {
					public static void Run() {
						int n=0;
						while(n < 3) {
							n++;
						}
						if(n == 3) {
							Console.WriteLine("three");
						} else {
							Console.WriteLine("other");
						}
					}
				}
			}

			""";

		const String cArm =
			"""
			using System;

			namespace CgArm
			{
				class Test
				{
					public static void Run()
					{
						Show(true);
						Show(false);
					}

					static void Show(bool flag)
					{
						if (flag)
						{
							Console.WriteLine("on");
						}
						Console.WriteLine("end");
					}
				}
			}

			""";

		const String cRefuse =
			"""
			using System;

			namespace CgRefuse
			{
				class Test
				{
					static int Compute(int v)
					{
						return v;
					}

					public static void Run()
					{
					}

					static void Loop(int n)
					{
						int i = 0;
						while (i < n)
						{
							i++;
						}
						Console.WriteLine("after");
					}

					static void Branchy(bool f)
					{
						if (f)
						{
							Console.WriteLine("yes");
						}
						else
						{
							Console.WriteLine("no");
						}
						Console.WriteLine("end");
					}
				}
			}

			""";

		// ------------------------------------------------------------------ switch and flow macros

		/// Sources made from templates; freed when the run ends.
		static List<String> sOwned = new .() ~ DeleteContainerAndItems!(_);

		const String cSwitchSimple =
			"""
			using System;

			namespace CgSwitch
			{
				class Test
				{
					public static void Run()
					{
						Pick(1);
						Pick(3);
						Pick(9);
					}

					static void Pick(int x)
					{
					}
				}
			}

			""";

		const String cSwitchEnum =
			"""
			using System;

			namespace CgSwitchEnum
			{
				enum Mode { Idle, Run, Jump }

				class Test
				{
					public static void Run()
					{
						Describe(.Idle);
						Describe(.Run);
						Describe(.Jump);
					}

					static void Describe(Mode m)
					{
					}
				}
			}

			""";

		const String cSwitchWords =
			"""
			using System;

			namespace CgSwitchWords
			{
				class Test
				{
					public static void Run()
					{
						Word("a");
						Word("c");
						Word("z");
					}

					static void Word(String s)
					{
						switch (s)
						{
						case "a":
							Console.WriteLine("A");
						case "b":
							Console.WriteLine("B");
						default:
							Console.WriteLine("?");
						}
					}
				}
			}

			""";

		const String cSwitchJoin =
			"""
			using System;

			namespace CgSwitchJoin
			{
				class Test
				{
					public static void Run()
					{
						Pick(1);
						Pick(2);
						Pick(7);
					}

					static void Pick(int x)
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
				}
			}

			""";

		/// Run() holds `for (int i = 0; i < @N@; i++) { }`; the macro goes into the body.
		const String cMacroLoop =
			"""
			using System;

			namespace @NS@
			{
				class Test
				{
					public static void Run()
					{
						for (int i = 0; i < @N@; i++)
						{
						}
						Console.WriteLine("end");
					}
				}
			}

			""";

		static String LoopSource(StringView ns, int n)
		{
			let s = new String(cMacroLoop);
			s.Replace("@NS@", ns);
			s.Replace("@N@", scope $"{n}");
			sOwned.Add(s);
			return s;
		}

		static void MutateSwitchSimple(Graph g)
		{
			StringView[2] labels = .("1", "2, 3");
			let sw = NodeFactory.Switch(g, "int", labels);
			g.Connect(NodeFactory.Get(g, "x", "int").Result, sw.FindInput("value"));
			g.Connect(sw.FindOutput("case0"), NewWriteLine(g, "\"one\"").ExecIn);
			g.Connect(sw.FindOutput("case1"), NewWriteLine(g, "\"two or three\"").ExecIn);
			g.Connect(sw.FindOutput("default"), NewWriteLine(g, "\"other\"").ExecIn);
			g.Connect(sw.Then, NewWriteLine(g, "\"done\"").ExecIn);
			g.Connect(g.Entry.Then, sw.ExecIn);
		}

		static void MutateSwitchEnum(Graph g)
		{
			StringView[2] labels = .(".Idle", ".Run");
			let sw = NodeFactory.Switch(g, "Mode", labels);
			g.Connect(NodeFactory.Get(g, "m", "Mode").Result, sw.FindInput("value"));
			g.Connect(sw.FindOutput("case0"), NewWriteLine(g, "\"idle\"").ExecIn);
			g.Connect(sw.FindOutput("case1"), NewWriteLine(g, "\"run\"").ExecIn);
			g.Connect(sw.FindOutput("default"), NewWriteLine(g, "\"other\"").ExecIn);
			g.Connect(g.Entry.Then, sw.ExecIn);
		}

		static void MutateSwitchAddCase(Graph g)
		{
			// A new `case "c":` with a body, before default.
			let sw = FindNode(g, .Switch);
			let p = NodeFactory.AddCase(g, sw, "\"c\"");
			g.Connect(p, NewWriteLine(g, "\"C\"").ExecIn);
		}

		static void MutateSwitchJoin(Graph g)
		{
			// Every arm, Default included, continues into one node written after the switch.
			let join = NewWriteLine(g, "\"joined\"");
			g.Connect(FindCall(g, "WriteLine", "\"one\"").Then, join.ExecIn);
			g.Connect(FindCall(g, "WriteLine", "\"two\"").Then, join.ExecIn);
			g.Connect(FindCall(g, "WriteLine", "\"other\"").Then, join.ExecIn);
		}

		static void MutateSequence(Graph g)
		{
			let loop = FindNode(g, .For);
			let seq = NodeFactory.Flow(g, FlowMacros.Sequence, null, 3);
			let a = NewWriteLine(g, "\"a {}\"");
			AddArg(g, a, "i");
			g.Connect(seq.FindOutput("seq0"), a.ExecIn);
			g.Connect(seq.FindOutput("seq1"), NewWriteLine(g, "\"b\"").ExecIn);
			g.Connect(seq.FindOutput("seq2"), NewWriteLine(g, "\"c\"").ExecIn);
			g.Connect(seq.Then, NewWriteLine(g, "\"after\"").ExecIn);
			g.Connect(loop.FindOutput("body"), seq.ExecIn);
		}

		static void MutateDoOnce(Graph g)
		{
			let loop = FindNode(g, .For);
			let once = NodeFactory.Flow(g, FlowMacros.DoOnce);
			let say = NewWriteLine(g, "\"once {}\"");
			AddArg(g, say, "i");
			g.Connect(once.FindOutput("body"), say.ExecIn);
			let reset = NodeFactory.Flow(g, FlowMacros.DoOnceReset);
			let b = NewBranch(g, Compare(g, "==", "i", "2"));
			g.Connect(b.FindOutput("true"), reset.ExecIn);
			g.Connect(loop.FindOutput("body"), once.ExecIn);
			g.Connect(once.Then, b.ExecIn);
		}

		static void MutateDoN(Graph g)
		{
			let loop = FindNode(g, .For);
			let don = NodeFactory.Flow(g, FlowMacros.DoN);
			don.FindInput("n").Default.Set("3");
			let say = NewWriteLine(g, "\"n {}\"");
			g.Connect(don.FindOutput("counter"), AddArg(g, say));
			g.Connect(don.FindOutput("body"), say.ExecIn);
			let reset = NodeFactory.Flow(g, FlowMacros.DoNReset);
			let b = NewBranch(g, Compare(g, "==", "i", "4"));
			g.Connect(b.FindOutput("true"), reset.ExecIn);
			g.Connect(loop.FindOutput("body"), don.ExecIn);
			g.Connect(don.Then, b.ExecIn);
		}

		static void MutateFlipFlop(Graph g)
		{
			let loop = FindNode(g, .For);
			let ff = NodeFactory.Flow(g, FlowMacros.FlipFlop);
			g.Connect(ff.FindOutput("a"), NewWriteLine(g, "\"A\"").ExecIn);
			g.Connect(ff.FindOutput("b"), NewWriteLine(g, "\"B\"").ExecIn);
			let show = NewWriteLine(g, "\"isA={}\"");
			g.Connect(ff.FindOutput("isA"), AddArg(g, show));
			g.Connect(ff.Then, show.ExecIn);
			g.Connect(loop.FindOutput("body"), ff.ExecIn);
		}

		static void MutateGate(Graph g)
		{
			// Starts closed. i == 1 opens it, i == 3 closes it, i == 4 toggles it.
			let loop = FindNode(g, .For);
			let gate = NodeFactory.Flow(g, FlowMacros.Gate);
			FlowMacros.SetGateStartClosed(gate, true);
			let say = NewWriteLine(g, "\"through {}\"");
			AddArg(g, say, "i");
			g.Connect(gate.FindOutput("body"), say.ExecIn);
			let open = NodeFactory.Flow(g, FlowMacros.GateOpen);
			let close = NodeFactory.Flow(g, FlowMacros.GateClose);
			let toggle = NodeFactory.Flow(g, FlowMacros.GateToggle);
			let b1 = NewBranch(g, Compare(g, "==", "i", "1"));
			let b3 = NewBranch(g, Compare(g, "==", "i", "3"));
			let b4 = NewBranch(g, Compare(g, "==", "i", "4"));
			g.Connect(b1.FindOutput("true"), open.ExecIn);
			g.Connect(b3.FindOutput("true"), close.ExecIn);
			g.Connect(b4.FindOutput("true"), toggle.ExecIn);
			g.Connect(loop.FindOutput("body"), b1.ExecIn);
			g.Connect(b1.Then, b3.ExecIn);
			g.Connect(b3.Then, b4.ExecIn);
			g.Connect(b4.Then, gate.ExecIn);
		}

		static void MutateGateOpen(Graph g)
		{
			// Starts open. i == 1 closes it, i == 3 opens it again.
			let loop = FindNode(g, .For);
			let gate = NodeFactory.Flow(g, FlowMacros.Gate);
			let say = NewWriteLine(g, "\"through {}\"");
			AddArg(g, say, "i");
			g.Connect(gate.FindOutput("body"), say.ExecIn);
			let close = NodeFactory.Flow(g, FlowMacros.GateClose);
			let open = NodeFactory.Flow(g, FlowMacros.GateOpen);
			let b1 = NewBranch(g, Compare(g, "==", "i", "1"));
			let b3 = NewBranch(g, Compare(g, "==", "i", "3"));
			g.Connect(b1.FindOutput("true"), close.ExecIn);
			g.Connect(b3.FindOutput("true"), open.ExecIn);
			g.Connect(loop.FindOutput("body"), b1.ExecIn);
			g.Connect(b1.Then, b3.ExecIn);
			g.Connect(b3.Then, gate.ExecIn);
		}

		static void MutateMultiGate(Graph g)
		{
			let loop = FindNode(g, .For);
			let mgate = NodeFactory.Flow(g, FlowMacros.MultiGate, null, 3);
			g.Connect(mgate.FindOutput("out0"), NewWriteLine(g, "\"m0\"").ExecIn);
			g.Connect(mgate.FindOutput("out1"), NewWriteLine(g, "\"m1\"").ExecIn);
			g.Connect(mgate.FindOutput("out2"), NewWriteLine(g, "\"m2\"").ExecIn);
			let reset = NodeFactory.Flow(g, FlowMacros.MultiGateReset);
			let b = NewBranch(g, Compare(g, "==", "i", "5"));
			g.Connect(b.FindOutput("true"), reset.ExecIn);
			g.Connect(loop.FindOutput("body"), mgate.ExecIn);
			g.Connect(mgate.Then, b.ExecIn);
		}

		static void MutateMultiGateLoop(Graph g)
		{
			let loop = FindNode(g, .For);
			let mgate = NodeFactory.Flow(g, FlowMacros.MultiGate, null, 3);
			mgate.Postfix = true;
			g.Connect(mgate.FindOutput("out0"), NewWriteLine(g, "\"m0\"").ExecIn);
			g.Connect(mgate.FindOutput("out1"), NewWriteLine(g, "\"m1\"").ExecIn);
			g.Connect(mgate.FindOutput("out2"), NewWriteLine(g, "\"m2\"").ExecIn);
			g.Connect(loop.FindOutput("body"), mgate.ExecIn);
		}

		static void MutateNestedFlow(Graph g)
		{
			// for i: switch (i % 2) { case 0: DoOnce { "even first" }  case 1: Sequence { "odd 1" "odd 2" } }
			let loop = FindNode(g, .For);
			StringView[2] labels = .("0", "1");
			let sw = NodeFactory.Switch(g, "int", labels);
			let mod = NodeFactory.Operator(g, "%", true);
			mod.FindInput("a").Default.Set("i");
			mod.FindInput("b").Default.Set("2");
			g.Connect(mod.Result, sw.FindInput("value"));
			let once = NodeFactory.Flow(g, FlowMacros.DoOnce);
			g.Connect(once.FindOutput("body"), NewWriteLine(g, "\"even first\"").ExecIn);
			g.Connect(sw.FindOutput("case0"), once.ExecIn);
			let seq = NodeFactory.Flow(g, FlowMacros.Sequence, null, 2);
			g.Connect(seq.FindOutput("seq0"), NewWriteLine(g, "\"odd 1\"").ExecIn);
			g.Connect(seq.FindOutput("seq1"), NewWriteLine(g, "\"odd 2\"").ExecIn);
			g.Connect(sw.FindOutput("case1"), seq.ExecIn);
			g.Connect(sw.Then, NewWriteLine(g, "\"tick\"").ExecIn);
			g.Connect(loop.FindOutput("body"), sw.ExecIn);
		}

		static Case AddCase(List<Case> cases, String name, String ns, String source, String key, MutateFn fn, String expected)
		{
			Case c = new .();
			c.Name = name;
			c.Namespace = ns;
			c.Source = source;
			c.MethodKey = key;
			c.Mutate = fn;
			c.Expected = expected;
			cases.Add(c);
			return c;
		}

		// ------------------------------------------------------------------ lifetime nodes
		// Construct (`new` / `scope`), Delete, Defer, Using and Result (docs/Lifetime-Nodes.md).

		/// Every lifetime construct read from code; the case regenerates every statement.
		const String cLifetimeCode =
			"""
			using System;

			namespace CgLifetime
			{
				class Tracker
				{
					public String mName = new .() ~ delete _;

					public this(String name)
					{
						mName.Set(name);
						Console.WriteLine("make {}", mName);
					}

					public ~this()
					{
						Console.WriteLine("free {}", mName);
					}

					public void Use()
					{
						Console.WriteLine("use {}", mName);
					}
				}

				struct Guard : IDisposable
				{
					String mName;

					public this(String name)
					{
						mName = name;
						Console.WriteLine("enter {}", name);
					}

					public void Dispose()
					{
						Console.WriteLine("leave {}", mName);
					}
				}

				class Test
				{
					static Result<int> Parse(StringView s)
					{
						if (int.Parse(s) case .Ok(let v))
						{
							return v;
						}
						return .Err;
					}

					static Result<int> Twice(StringView s)
					{
						int v = Try!(Parse(s));
						return v * 2;
					}

					public static void Run()
					{
						Console.WriteLine("start");
						{
							let a = scope Tracker("scoped");
							a.Use();
						}
						let b = new Tracker("owned");
						defer delete b;
						defer Console.WriteLine("defer 1");
						defer
						{
							Console.WriteLine("defer 2");
						}
						using (Guard("lock"))
						{
							Console.WriteLine("inside");
						}
						if (Parse("12") case .Ok(let n))
						{
							Console.WriteLine("ok {}", n);
						}
						if (Parse("x") case .Err)
						{
							Console.WriteLine("err");
						}
						if (Twice("21") case .Ok(let t))
						{
							Console.WriteLine("twice {}", t);
						}
						String s = scope $"name={b.mName}";
						Console.WriteLine(s);
						int[] arr = new int[3];
						arr[1] = 7;
						Console.WriteLine("arr {}", arr[1]);
						delete arr;
						Console.WriteLine("end");
					}
				}
			}

			""";

		static void MutateLifetimeRegenerate(Graph g)
		{
			for (let n in g.Nodes)
				n.Edited = true;
		}

		/// The same constructs made in the editor (NodeFactory), into an empty method.
		const String cLifetimeNew =
			"""
			using System;

			namespace CgLifetimeNew
			{
				class Tracker
				{
					public String mName = new .() ~ delete _;

					public this(String name)
					{
						mName.Set(name);
						Console.WriteLine("make {}", mName);
					}

					public ~this()
					{
						Console.WriteLine("free {}", mName);
					}

					public void Use()
					{
						Console.WriteLine("use {}", mName);
					}
				}

				struct Guard : IDisposable
				{
					String mName;

					public this(String name)
					{
						mName = name;
						Console.WriteLine("enter {}", name);
					}

					public void Dispose()
					{
						Console.WriteLine("leave {}", mName);
					}
				}

				class Test
				{
					static Result<int> Parse(StringView s)
					{
						if (int.Parse(s) case .Ok(let v))
						{
							return v;
						}
						return .Err;
					}

					public static void Run()
					{
						Console.WriteLine("start");
					}
				}
			}

			""";

		static void MutateLifetimeNew(Graph g)
		{
			StringView[0] none = .();
			StringView[1] nameParam = .("name");
			StringView[1] stringType = .("String");
			StringView[1] sParam = .("s");
			StringView[1] svType = .("StringView");
			let start = FindCall(g, "WriteLine", "\"start\"");

			// var tracker = new Tracker("made"); defer delete tracker; tracker.Use();
			let make = NodeFactory.Construct(g, "Tracker", "new", nameParam, stringType);
			make.FindInput("arg0").Default.Set("\"made\"");
			let local = NodeFactory.LocalVar(g, "tracker", "var");
			g.Connect(make.Result, local.FindInput("value"));
			let d = NodeFactory.Defer(g);
			let del = NodeFactory.Delete(g);
			g.Connect(local.FindOutput("variable"), del.FindInput("value"));
			g.Connect(d.FindOutput("body"), del.ExecIn);
			let use = NodeFactory.MemberCall(g, "Use", "Tracker", true, none, none, "void");
			g.Connect(local.FindOutput("variable"), use.FindInput("target"));

			// using (Guard("g")) { Console.WriteLine("in using"); }
			let guard = PureCall(g, "Guard", "", "Guard", "\"g\"");
			let u = NodeFactory.Using(g);
			g.Connect(guard.Result, u.FindInput("value"));
			g.Connect(u.FindOutput("body"), NewWriteLine(g, "\"in using\"").ExecIn);

			// if (Parse("5") case .Ok(let value)) ... else ...
			let p1 = NodeFactory.StaticCall(g, "Parse", "", "Test", false, sParam, svType, "Result<int>");
			p1.FindInput("arg0").Default.Set("\"5\"");
			let m1 = NodeFactory.ResultMatch(g, true, "Result<int>");
			g.Connect(p1.Result, m1.FindInput("value"));
			let parsed = NewWriteLine(g, "\"parsed {}\"");
			g.Connect(m1.FindOutput("payload"), AddArg(g, parsed));
			g.Connect(m1.FindOutput("ok"), parsed.ExecIn);
			g.Connect(m1.FindOutput("err"), NewWriteLine(g, "\"bad\"").ExecIn);

			// if (Parse("q") case .Err) ...
			let p2 = NodeFactory.StaticCall(g, "Parse", "", "Test", false, sParam, svType, "Result<int>");
			p2.FindInput("arg0").Default.Set("\"q\"");
			let m2 = NodeFactory.ResultMatch(g, false, "Result<int>");
			g.Connect(p2.Result, m2.FindInput("value"));
			g.Connect(m2.FindOutput("err"), NewWriteLine(g, "\"q is bad\"").ExecIn);

			// String text = scope .(); text.Append("abc"); Console.WriteLine(text);
			let inferred = NodeFactory.Construct(g, ".", "scope", none, none);
			let text = NodeFactory.LocalVar(g, "text", "String");
			g.Connect(inferred.Result, text.FindInput("value"));
			StringView[1] strParam = .("str");
			let appendCall = NodeFactory.MemberCall(g, "Append", "String", true, strParam, svType, "void");
			appendCall.FindInput("arg0").Default.Set("\"abc\"");
			g.Connect(text.FindOutput("variable"), appendCall.FindInput("target"));
			let show = NewWriteLine(g, "\"{}\"");
			g.Connect(text.FindOutput("variable"), AddArg(g, show));

			// A scope $"" string passed straight to a call.
			let str = NodeFactory.Construct(g, "$", "scope", none, none);
			str.FindInput("arg0").Default.Set("$\"count={3 + 4}\"");
			let count = NewWriteLine(g, "\"{}\"");
			g.Connect(str.Result, AddArg(g, count));

			let end = NewWriteLine(g, "\"end\"");
			Pin prev = start.Then;
			for (let n in Node[?](local, d, use, u, m1, m2, text, appendCall, show, count, end))
			{
				g.Connect(prev, n.ExecIn);
				prev = n.Then;
			}
		}

		const String cLifetimeRefuse =
			"""
			using System;

			namespace CgLifetimeRefuse
			{
				class Test
				{
					static Result<int> Parse(StringView s)
					{
						return .Err;
					}

					public static void Run()
					{
					}

					static void Branchy(bool f)
					{
						String s = null;
						if (f)
						{
							Console.WriteLine("yes");
						}
						Console.WriteLine(s);
					}
				}
			}

			""";

		/// `s = scope String();` inside the branch, `s` read after it.
		static void MutateRefuseScopeAfterBlock(Graph g)
		{
			StringView[0] none = .();
			let branch = FindNode(g, .Branch);
			let alloc = NodeFactory.Construct(g, "String", "scope", none, none);
			let set = NodeFactory.Set(g, "s", "String");
			g.Connect(alloc.Result, set.FindInput("value"));
			let first = g.ExecTarget(branch.FindOutput("true"));
			g.Connect(branch.FindOutput("true"), set.ExecIn);
			g.Connect(set.Then, first.ExecIn);
		}

		static void MutateRefuseReturnInDefer(Graph g)
		{
			let d = NodeFactory.Defer(g);
			g.Connect(d.FindOutput("body"), NodeFactory.Return(g, "void").ExecIn);
			g.Connect(g.Entry.Then, d.ExecIn);
		}

		static void MutateRefuseResultOutsideArm(Graph g)
		{
			StringView[1] sParam = .("s");
			StringView[1] svType = .("StringView");
			let p = NodeFactory.StaticCall(g, "Parse", "", "Test", false, sParam, svType, "Result<int>");
			p.FindInput("arg0").Default.Set("\"1\"");
			let m = NodeFactory.ResultMatch(g, true, "Result<int>");
			g.Connect(p.Result, m.FindInput("value"));
			let say = NewWriteLine(g, "\"{}\"");
			g.Connect(m.FindOutput("payload"), AddArg(g, say));
			g.Connect(g.Entry.Then, m.ExecIn);
			g.Connect(m.Then, say.ExecIn);
		}

		/// Every text form that became a node (Scope, const / ref locals, `(.)`, `.()`, repeat,
		/// local functions, lambdas with captures, delegates, events, a payload switch, Format,
		/// a statement attribute), every statement regenerated from the graph.
		const String cTextForms =
			"""
			using System;
			using System.Collections;

			namespace CgTextForms
			{
				struct Pair
				{
					public int A;
					public int B;
				}

				class Test
				{
					static Event<delegate void(int)> sOnValue ~ _.Dispose();

					static void Shout(int v)
					{
						Console.WriteLine("shout {}", v);
					}

					static Result<int> Half(int v)
					{
						if (v % 2 != 0)
							return .Err;
						return v / 2;
					}

					public static void Run()
					{
						const int kCount = 3;
						int total = 0;
						{
							int inner = kCount * 2;
							total += inner;
						}
						Console.WriteLine("total {}", total);
						ref int slot = ref total;
						slot = 10;
						Console.WriteLine("slot {}", total);
						float f = (.)total;
						Console.WriteLine("f {}", f);
						Pair p = .();
						p.A = 4;
						Console.WriteLine("p {} {}", p.A, p.B);
						int n = 0;
						repeat
						{
							n++;
						}
						while (n < 3);
						Console.WriteLine("n {}", n);
						int Twice(int x) => x * 2;
						void Say(String s)
						{
							Console.WriteLine("say {}", s);
						}
						Say("hi");
						Console.WriteLine("twice {}", Twice(21));
						List<int> list = scope .() { 3, 1, 2 };
						list.Sort(scope (a, b) => a <=> b);
						Console.WriteLine("sorted {} {} {}", list[0], list[1], list[2]);
						int sum = 0;
						delegate void(int) add = scope [&] (v) =>
						{
							sum += v;
							Console.WriteLine("add {}", v);
						};
						add(5);
						add(6);
						Console.WriteLine("sum {}", sum);
						sOnValue.Add(new => Shout);
						sOnValue(7);
						switch (Half(8))
						{
						case .Ok(let h):
							Console.WriteLine("half {}", h);
						case .Err:
							Console.WriteLine("odd");
						}
						String msg = scope $"total={total} hex={total:X2} next={total + 1}";
						Console.WriteLine(msg);
						[ConstSkip]
						{
							Console.WriteLine("end");
						}
					}
				}
			}

			""";

		const String cOverloadPick =
			"""
			using System;

			namespace CgOverload
			{
				class Test
				{
					static void Show(int v)
					{
						Console.WriteLine("int {}", v);
					}

					static void Show(float v)
					{
						Console.WriteLine("float {}", v);
					}

					public static void Run()
					{
						int8 small = 3;
						Show(small);
					}
				}
			}

			""";

		/// The overload dropdown: pick Show(float v) for an int8 argument (written as a cast).
		static void MutateOverloadPick(Graph g)
		{
			for (let n in g.Nodes)
			{
				if (n.Kind == .Call && n.Text == "Show" && n.Ambiguous)
				{
					String why = scope .();
					NodeFactory.PickOverload(g, n, "Show(float v)", why);
				}
			}
		}

		static void AddTextFormCases(List<Case> cases)
		{
			var oc = AddCase(cases, "OverloadPickCast", "CgOverload", cOverloadPick, "Test.Run()", => MutateOverloadPick, "float 3\n");
			oc.MustContain.Add("\t\t\tShow((float)small);\n");
			var c = AddCase(cases, "TextFormsFromCode", "CgTextForms", cTextForms, "Test.Run()", => MutateLifetimeRegenerate,
				"total 6\nslot 10\nf 10\np 4 0\nn 3\nsay hi\ntwice 42\nsorted 1 2 3\nadd 5\nadd 6\nsum 11\nshout 7\nhalf 4\ntotal=10 hex=0A next=11\nend\n");
			c.SameAsSource = true;
		}

		static void AddLifetimeCases(List<Case> cases)
		{
			var c = AddCase(cases, "LifetimeFromCode", "CgLifetime", cLifetimeCode, "Test.Run()", => MutateLifetimeRegenerate,
				"start\nmake scoped\nuse scoped\nfree scoped\nmake owned\nenter lock\ninside\nleave lock\nok 12\nerr\ntwice 42\nname=owned\narr 7\nend\ndefer 2\ndefer 1\nfree owned\n");
			c.SameAsSource = true;
			c = AddCase(cases, "LifetimeNewNodes", "CgLifetimeNew", cLifetimeNew, "Test.Run()", => MutateLifetimeNew,
				"start\nmake made\nuse made\nenter g\nin using\nleave g\nparsed 5\nq is bad\nabc\ncount=7\nend\nfree made\n");
			c.MustContain.Add("\t\t\tvar tracker = new Tracker(\"made\");\n\t\t\tdefer delete tracker;\n\t\t\ttracker.Use();\n");
			c.MustContain.Add("\t\t\tusing (Guard(\"g\"))\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"in using\");\n\t\t\t}\n");
			c.MustContain.Add("\t\t\tif (Parse(\"5\") case .Ok(let value))\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"parsed {}\", value);\n\t\t\t}\n\t\t\telse\n");
			c.MustContain.Add("\t\t\tif (Parse(\"q\") case .Err)\n");
			c.MustContain.Add("\t\t\tString text = scope .();\n\t\t\ttext.Append(\"abc\");\n");
			c.MustContain.Add("Console.WriteLine(\"{}\", scope $\"count={3 + 4}\");");
			c = AddCase(cases, "RefuseScopeAfterBlock", "CgLifetimeRefuse", cLifetimeRefuse, "Test.Branchy(bool)", => MutateRefuseScopeAfterBlock, null);
			c.RefusalContains = "allocated with `scope` in a block that has ended";
			c = AddCase(cases, "RefuseReturnInDefer", "CgLifetimeRefuse", cLifetimeRefuse, "Test.Run()", => MutateRefuseReturnInDefer, null);
			c.RefusalContains = "A deferred body can't return";
			c = AddCase(cases, "RefuseResultValueOutsideArm", "CgLifetimeRefuse", cLifetimeRefuse, "Test.Run()", => MutateRefuseResultOutsideArm, null);
			c.RefusalContains = "outside its Ok arm";
		}

		static Case AddRefusal(List<Case> cases, String name, String key, MutateFn fn, String reason)
		{
			let c = AddCase(cases, name, "CgRefuse", cRefuse, key, fn, null);
			c.RefusalContains = reason;
			return c;
		}


		// ------------------------------------------------------------------ classes (docs/Classes-and-Members.md)

		const String cClassHierarchy =
			"""
			using System;

			namespace CgClasses
			{
				interface IGreeter
				{
					void Greet(String name);
					int Times { get; }
				}

				abstract class Animal
				{
					public virtual void Speak()
					{
						Console.WriteLine("...");
					}

					public abstract String Kind();

					public virtual int Legs { get { return 4; } }

					protected virtual bool TryGet(int key, out int value)
					{
						value = key * 2;
						return true;
					}

					public bool Lookup(int key, out int value)
					{
						return TryGet(key, out value);
					}
				}

				class Dog : Animal, IGreeter
				{
				}

				class Test
				{
					public static void Run()
					{
						Animal a = new Dog();
						a.Speak();
						String k = a.Kind();
						Console.WriteLine((k == null) ? "none" : k);
						Console.WriteLine("{}", a.Legs);
						if (a.Lookup(7, var v))
							Console.WriteLine("{}", v);
						IGreeter g = (Dog)a;
						g.Greet("Ada");
						Console.WriteLine("{}", g.Times);
						delete a;
					}
				}
			}

			""";

		const String cOverrideTick =
			"""
			using System;

			namespace CgOverride
			{
				abstract class ModBase
				{
					public abstract String Info();
					public virtual Result<void> Initialize() => .Ok;
					public virtual void Tick(float DeltaSeconds) {}
				}

				class MyMod : ModBase
				{
					public override String Info() => "my mod";
				}

				class Test
				{
					public static void Run()
					{
						ModBase m = new MyMod();
						if (m.Initialize() case .Ok)
							Console.WriteLine("init ok");
						m.Tick(0.5f);
						Console.WriteLine(m.Info());
						delete m;
					}
				}
			}

			""";

		const String cOverrideNoBase =
			"""
			using System;

			namespace CgOverrideNoBase
			{
				class Base
				{
				}

				class Kid : Base
				{
					public override void Nope()
					{
					}
				}

				class Test
				{
					public static void Run()
					{
					}
				}
			}

			""";

		static Member TypeDecl(SourceDocument doc, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		/// Type Settings > Implement Missing Members, then three entries of the Override
		/// dropdown (with the call to the parent function), as the editor does them.
		static void PrepareDog(SourceDocument doc)
		{
			ClassInfo info = scope .();
			ClassModel.Analyze(doc.Unit, TypeDecl(doc, "Dog"), TypeService.Current, info);
			Check(info.Missing.Count == 3, "Dog misses Kind, Greet, Times");
			doc.AddStubs(TypeDecl(doc, "Dog"), info.Missing);
			String key = scope .();
			StringView[3] sigs = .("Speak()", "Legs", "TryGet(int,out int)");
			for (let sig in sigs)
			{
				ClassInfo again = scope .();
				ClassModel.Analyze(doc.Unit, TypeDecl(doc, "Dog"), TypeService.Current, again);
				let m = again.FindOverridable(sig);
				Check(m != null, scope $"Override dropdown offers {sig}");
				if (m != null)
					doc.AddOverride(TypeDecl(doc, "Dog"), m, true, key);
			}
		}

		/// After the parent call in Dog.Speak(): print "woof".
		static void MutateDogSpeak(Graph g)
		{
			Node parentCall = null;
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == "Speak" && g.DataSource(n.FindInput("target"))?.Kind == .Base)
					parentCall = n;
			Check(parentCall != null, "Dog.Speak() calls its parent through a Parent node");
			if (parentCall == null)
				return;
			let woof = NewWriteLine(g, "\"woof\"");
			g.Connect(parentCall.Then, woof.ExecIn);
		}

		static void PrepareMyMod(SourceDocument doc)
		{
			String key = scope .();
			StringView[2] sigs = .("Initialize()", "Tick(float)");
			for (let sig in sigs)
			{
				ClassInfo info = scope .();
				ClassModel.Analyze(doc.Unit, TypeDecl(doc, "MyMod"), TypeService.Current, info);
				let m = info.FindOverridable(sig);
				Check(m != null, scope $"Override dropdown offers {sig}");
				if (m != null)
					doc.AddOverride(TypeDecl(doc, "MyMod"), m, true, key);
			}
		}

		/// Event Tick: print the delta after the parent call.
		static void MutateMyModTick(Graph g)
		{
			Node parentCall = null;
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == "Tick")
					parentCall = n;
			if (parentCall == null)
			{
				Check(false, "MyMod.Tick has its parent call");
				return;
			}
			let show = NewWriteLine(g, "\"tick {}\"");
			AddArg(g, show, "DeltaSeconds");
			g.Connect(parentCall.Then, show.ExecIn);
		}

		static void MutateOverrideNoBase(Graph g)
		{
			let n = NewWriteLine(g, "\"never\"");
			g.Connect(g.Entry.Then, n.ExecIn);
		}

		static void MakeCases(List<Case> cases)
		{
			var c = AddCase(cases, "SharedPop", "CgSharedPop", cSharedPop, "Test.Run()", => MutateSharedPop, "4 4 3\n");
			c.MustContain.Add("\t\t\tlet __v1 = list.PopBack();\n\t\t\tint a = __v1;\n\t\t\tint b = __v1;\n");
			c = AddCase(cases, "SharedSameStatement", "CgSharedSame", cSharedSame, "Test.Run()", => MutateSharedSameStatement, "14 1\n");
			c.MustContain.Add("\t\t\tlet __v1 = list.PopBack();\n\t\t\tint s = __v1 + __v1;\n");
			c = AddCase(cases, "DiamondMerge", "CgDiamond", cDiamond, "Test.Check(int)", => MutateDiamond, "big\ndone\nsmall\ndone\nnot positive\ndone\n");
			c.MustContain.Add("\t\t\telse\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"not positive\");\n\t\t\t}\n\t\t\tConsole.WriteLine(\"done\");\n\t\t}");
			c = AddCase(cases, "ScopeHoist", "CgHoist", cHoist, "Test.Show(bool)", => MutateHoist, "computing\nend\nvalue 40\nend\nvalue 0\ncalls 1\n");
			c.MustContain.Add("\t\t\tint computeResult = default;\n\t\t\tif (flag)\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"computing\");\n\t\t\t\tcomputeResult = Compute(4);\n\t\t\t}\n");
			c = AddCase(cases, "LoopsBreakContinue", "CgLoops", cLoops, "Test.Run()", => MutateLoops, "18 21\n");
			c.MustContain.Add("for (int i = 0; i < 10; i++)\n\t\t\t{\n\t\t\t\tif (i == 3)\n\t\t\t\t{\n\t\t\t\t\tcontinue;\n\t\t\t\t}\n");
			c = AddCase(cases, "NestedBranches", "CgNested", cNested, "Test.Classify(int)", => MutateNested,
				"x=-5\nneg\nend\nx=0\nzero\nend\nx=9\npos\nend\nx=100\nhuge\nend\n");
			c.MustContain.Add("\t\t\telse if (x == 0)\n");
			c.MustContain.Add("\t\t\telse if (x > 50)\n");
			c = AddCase(cases, "OutParams", "CgOutParams", cOutParams, "Test.Run()", => MutateOutParams, "start\nhalf=5\neven\nseven 3 odd\n");
			c.MustContain.Add("\t\t\tlet __v1 = TryHalf(10, var h);\n\t\t\tif (__v1)\n");
			c = AddCase(cases, "CallsSelfStaticOutRef", "CgCalls", cCalls, "Test.Go()", => MutateCalls,
				"start\nhit 1 -> 9\nhit 2 -> 7\ntwice 42\nhalf 5\nhoisted 4\nloop 3\nhp 12 count 3\n");
			c.MustContain.Add("\t\t\tHit(1);\n\t\t\tthis.Hit(2);\n\t\t\tConsole.WriteLine(\"twice {}\", Base.Twice(21));\n");
			c.MustContain.Add("\t\t\tTryHalf(10, var half);\n\t\t\tConsole.WriteLine(\"half {}\", half);\n\t\t\tTryHalf(3, ?);\n");
			// (half2 went to the discarded pin of `TryHalf(3, ?)` when it was made.)
			c.MustContain.Add("\t\t\tint half3 = default;\n\t\t\tif (mHp > 5)\n\t\t\t{\n\t\t\t\tTryHalf(8, out half3);\n\t\t\t}\n\t\t\tConsole.WriteLine(\"hoisted {}\", half3);\n");
			c.MustContain.Add("\t\t\tint half4;\n\t\t\twhile (TryHalf(6, out half4))\n");
			c.MustContain.Add("\t\t\tFill(ref mHp);\n\t\t\tint count = default;\n\t\t\tGetAll(ref count);\n");
			c = AddCase(cases, "StringFormatting", "CgStrings", cStrings, "Test.Run()", => MutateStrings, "begin\nAda and Ada (1)\ncalls=1\n<Ada|1>\n");
			c.MustContain.Add("\t\t\tlet __v1 = GetName();\n\t\t\tConsole.WriteLine(\"{} and {} ({})\", __v1, __v1, sNameCalls);\n");
			c = AddCase(cases, "ArmIntoCompleted", "CgArm", cArm, "Test.Show(bool)", => MutateArmIntoCompleted, "on\nend\nend\n");
			c.SameAsSource = true;
			c = AddCase(cases, "StyleKeptAndMatched", "CgStyle", cStyle, "Test.Run()", => MutateStyle, "start\ntick\ntick\ntick\nthree\nbig\n");
			c.MustContain.Add("\t\t\tint n=0;\n\t\t\tConsole.WriteLine(\"start\");\n\t\t\twhile(n < 3) {\n");
			c.MustContain.Add("\t\t\twhile(n < 3) {\n\t\t\t\tn++;\n\t\t\t\tConsole.WriteLine(\"tick\");\n\t\t\t}\n");
			c.MustContain.Add("\t\t\tif(n == 3) {\n\t\t\t\tConsole.WriteLine(\"three\");\n\t\t\t} else {\n");
			c.MustContain.Add("\t\t\tif(n > 1) {\n\t\t\t\tConsole.WriteLine(\"big\");\n\t\t\t} else {\n\t\t\t\tConsole.WriteLine(\"small\");\n\t\t\t}\n");

			c = AddCase(cases, "SwitchOnInt", "CgSwitch", cSwitchSimple, "Test.Pick(int)", => MutateSwitchSimple,
				"one\ndone\ntwo or three\ndone\nother\ndone\n");
			c.MustContain.Add("\t\t\tswitch (x)\n\t\t\t{\n\t\t\tcase 1:\n\t\t\t\tConsole.WriteLine(\"one\");\n\t\t\tcase 2, 3:\n\t\t\t\tConsole.WriteLine(\"two or three\");\n\t\t\tdefault:\n\t\t\t\tConsole.WriteLine(\"other\");\n\t\t\t}\n\t\t\tConsole.WriteLine(\"done\");\n");
			c = AddCase(cases, "SwitchOnEnum", "CgSwitchEnum", cSwitchEnum, "Test.Describe(Mode)", => MutateSwitchEnum, "idle\nrun\nother\n");
			c.MustContain.Add("\t\t\tswitch (m)\n\t\t\t{\n\t\t\tcase .Idle:\n");
			c = AddCase(cases, "SwitchAddCase", "CgSwitchWords", cSwitchWords, "Test.Word(String)", => MutateSwitchAddCase, "A\nC\n?\n");
			c.MustContain.Add("\t\t\tcase \"b\":\n\t\t\t\tConsole.WriteLine(\"B\");\n\t\t\tcase \"c\":\n\t\t\t\tConsole.WriteLine(\"C\");\n\t\t\tdefault:\n");
			c = AddCase(cases, "SwitchJoin", "CgSwitchJoin", cSwitchJoin, "Test.Pick(int)", => MutateSwitchJoin, "one\njoined\ntwo\njoined\nother\njoined\n");
			c.MustContain.Add("\t\t\t\tConsole.WriteLine(\"other\");\n\t\t\t}\n\t\t\tConsole.WriteLine(\"joined\");\n");

			c = AddCase(cases, "FlowSequence", "CgSequence", LoopSource("CgSequence", 2), "Test.Run()", => MutateSequence,
				"a 0\nb\nc\nafter\na 1\nb\nc\nafter\nend\n");
			c.MustContain.Add("\t\t\t\t// vb:sequence\n\t\t\t\t{\n\t\t\t\t\tConsole.WriteLine(\"a {}\", i);\n\t\t\t\t}\n\t\t\t\t{\n\t\t\t\t\tConsole.WriteLine(\"b\");\n\t\t\t\t}\n");
			c = AddCase(cases, "FlowDoOnce", "CgDoOnce", LoopSource("CgDoOnce", 5), "Test.Run()", => MutateDoOnce, "once 0\nonce 3\nend\n");
			c.MustContain.Add("\t\t\t\tif (!__doOnce_1)\n\t\t\t\t{\n\t\t\t\t\t__doOnce_1 = true;\n");
			c.MustContain.Add("\t\tprivate static bool __doOnce_1;\n");
			c.MustContain.Add("\t\t\t\t\t__doOnce_1 = false;\n");
			c = AddCase(cases, "FlowDoN", "CgDoN", LoopSource("CgDoN", 7), "Test.Run()", => MutateDoN, "n 1\nn 2\nn 3\nn 1\nn 2\nend\n");
			c.MustContain.Add("\t\t\t\tif (__doN_1 < 3)\n\t\t\t\t{\n\t\t\t\t\t__doN_1++;\n\t\t\t\t\tConsole.WriteLine(\"n {}\", __doN_1);\n");
			c = AddCase(cases, "FlowFlipFlop", "CgFlipFlop", LoopSource("CgFlipFlop", 4), "Test.Run()", => MutateFlipFlop,
				"A\nisA=True\nB\nisA=False\nA\nisA=True\nB\nisA=False\nend\n");
			c.MustContain.Add("\t\t\t\tif (!__flipFlop_1)\n\t\t\t\t{\n\t\t\t\t\t__flipFlop_1 = true;\n\t\t\t\t\tConsole.WriteLine(\"A\");\n\t\t\t\t}\n\t\t\t\telse\n\t\t\t\t{\n\t\t\t\t\t__flipFlop_1 = false;\n");
			c = AddCase(cases, "FlowGateStartsClosed", "CgGate", LoopSource("CgGate", 6), "Test.Run()", => MutateGate,
				"through 1\nthrough 2\nthrough 4\nthrough 5\nend\n");
			c.MustContain.Add("\t\t\t\tif (__gateOpen_1)\n");
			c.MustContain.Add("\t\t\t\t\t__gateOpen_1 = !__gateOpen_1;\n");
			c = AddCase(cases, "FlowGateStartsOpen", "CgGateOpen", LoopSource("CgGateOpen", 5), "Test.Run()", => MutateGateOpen,
				"through 0\nthrough 3\nthrough 4\nend\n");
			c.MustContain.Add("\t\t\t\tif (!__gateClosed_1)\n");
			c = AddCase(cases, "FlowMultiGate", "CgMultiGate", LoopSource("CgMultiGate", 7), "Test.Run()", => MutateMultiGate, "m0\nm1\nm2\nm0\nend\n");
			c.MustContain.Add("\t\t\t\tif (__multiGate_1 == 0)\n\t\t\t\t{\n\t\t\t\t\t__multiGate_1 = 1;\n");
			c.MustContain.Add("\t\t\t\telse if (__multiGate_1 == 2)\n\t\t\t\t{\n\t\t\t\t\t__multiGate_1 = 3;\n");
			c = AddCase(cases, "FlowMultiGateLoop", "CgMultiGateLoop", LoopSource("CgMultiGateLoop", 5), "Test.Run()", => MutateMultiGateLoop,
				"m0\nm1\nm2\nm0\nm1\nend\n");
			c.MustContain.Add("\t\t\t\t\t__multiGate_1 = 0;\n");
			c = AddCase(cases, "FlowNested", "CgNestedFlow", LoopSource("CgNestedFlow", 4), "Test.Run()", => MutateNestedFlow,
				"even first\ntick\nodd 1\nodd 2\ntick\ntick\nodd 1\nodd 2\ntick\nend\n");

			AddRefusal(cases, "RefuseLoopBodyMerge", "Test.Loop(int)", => MutateRefuseLoopMerge, "Two flow wires");
			AddRefusal(cases, "RefuseSiblingBranchUse", "Test.Branchy(bool)", => MutateRefuseSiblingUse, "has not run");
			AddRefusal(cases, "RefuseLocalOutOfScope", "Test.Branchy(bool)", => MutateRefuseLocalScope, "outside the block that declares it");
			AddRefusal(cases, "RefuseSharedAcrossBlocks", "Test.Branchy(bool)", => MutateRefuseSharedScopes, "shared by nodes in different blocks");
			AddRefusal(cases, "RefuseSharedLoopCondition", "Test.Loop(int)", => MutateRefuseLoopCondition, "loop condition");
			AddRefusal(cases, "RefuseExecCycle", "Test.Branchy(bool)", => MutateRefuseCycle, "loops back");
			AddRefusal(cases, "RefuseHoistUnknownType", "Test.Branchy(bool)", => MutateRefuseUnknownType, "type is unknown");
			c = AddCase(cases, "ClassHierarchyInterface", "CgClasses", cClassHierarchy, "Dog.Speak()", => MutateDogSpeak, "...\nwoof\nnone\n4\n14\n0\n");
			c.WithTypes = true;
			c.Prepare = => PrepareDog;
			c.MustContain.Add("\t\tpublic override void Speak()\n\t\t{\n\t\t\tbase.Speak();\n\t\t\tConsole.WriteLine(\"woof\");\n\t\t}\n");
			c.MustContain.Add("\t\tpublic void Greet(String name)\n");
			c.MustContain.Add("\t\tprotected override bool TryGet(int key, out int value)\n\t\t{\n\t\t\treturn base.TryGet(key, out value);\n");
			c.MustContain.Add("\t\t\t\treturn base.Legs;\n");
			c = AddCase(cases, "OverrideTickFromDropdown", "CgOverride", cOverrideTick, "MyMod.Tick(float)", => MutateMyModTick, "init ok\ntick 0.5\nmy mod\n");
			c.WithTypes = true;
			c.Prepare = => PrepareMyMod;
			c.MustContain.Add("\t\tpublic override Result<void> Initialize()\n\t\t{\n\t\t\treturn base.Initialize();\n\t\t}\n");
			c = AddCase(cases, "RefuseOverrideWithoutBase", "CgOverrideNoBase", cOverrideNoBase, "Kid.Nope()", => MutateOverrideNoBase, null);
			c.WithTypes = true;
			c.RefusalContains = "is marked override, but no base class of Kid";

			AddRefusal(cases, "RefuseTargetSelfInStatic", "Test.Run()", => MutateRefuseTargetStatic, "Receiver must be a Test: this function is static, so there is no this.");
			AddLifetimeCases(cases);
			AddTextFormCases(cases);
		}

		// ------------------------------------------------------------------ running

		static void MethodText(SourceDocument doc, StringView key, String o)
		{
			let mg = doc.FindMethod(key);
			if (mg == null || !mg.Method.HasSpan)
				return;
			let start = doc.Unit.Tokens[mg.Method.FirstTok].Start;
			let end = doc.Unit.Tokens[mg.Method.LastTok].End;
			o.Append(StringView(doc.Text, start, end - start));
		}

		static bool HasError(Graph g, StringView contains)
		{
			for (let e in g.Errors)
				if (e.Message.Contains(contains))
					return true;
			return false;
		}

		/// Edit, commit and check the generated text of one case. Returns true when the file
		/// should be compiled.
		static bool RunEdit(Case c)
		{
			Console.WriteLine("Case {}", c.Name);
			SourceDocument doc = scope .();
			doc.LoadFromText(c.Source, scope $"{c.Name}.bf");
			// Class-level cases: a TypeService over the file, like the editor's.
			ProjectIndex typesIndex = null;
			TypeService typesSvc = null;
			let oldIndex = GraphBuilder.Index;
			defer
			{
				if (typesSvc != null)
				{
					GraphBuilder.Index = oldIndex;
					delete typesSvc;
					TypeService.Current = null;
					TypeRules.Hierarchy = null;
					delete typesIndex;
				}
			}
			if (c.WithTypes)
			{
				typesIndex = new .();
				typesIndex.Update(doc.FilePath, doc.Unit);
				typesSvc = new .(typesIndex);
				typesSvc.AutoLoadLibraries = false;
				typesSvc.Install();
				GraphBuilder.Index = typesIndex;
			}
			if (c.Prepare != null)
			{
				c.Prepare(doc);
				typesIndex?.Update(doc.FilePath, doc.Unit);
			}
			let mg = doc.FindMethod(c.MethodKey);
			if (mg == null)
			{
				Check(false, scope $"method {c.MethodKey} found");
				return false;
			}
			let g = mg.Graph;
			doc.PushUndo();
			c.Mutate(g);
			bool ok = doc.Commit(mg);

			if (c.RefusalContains != null)
			{
				Check(!ok, "commit refused");
				Check(doc.Text == c.Source, "file text unchanged");
				Check(HasError(g, c.RefusalContains), scope $"error on a node mentions \"{c.RefusalContains}\"");
				for (let e in g.Errors)
				{
					let n = g.FindNode(e.NodeId);
					String title = scope .();
					n?.GetTitle(title);
					Console.WriteLine("    refused: [{}] {}", title, e.Message);
				}
				Check(!doc.Messages.IsEmpty && doc.Messages[0].StartsWith("Not written"), "reason reported in Messages");
				return false;
			}

			Check(ok, "commit accepted");
			for (let e in g.Errors)
				Console.WriteLine("    error: {}", e.Message);
			c.Committed.Set(doc.Text);
			String method = scope .();
			MethodText(doc, c.MethodKey, method);
			if (sVerbose)
				Console.WriteLine("---- generated ----\n{}\n-------------------", method);
			for (let s in c.MustContain)
			{
				Check(doc.Text.Contains(s), scope $"text contains: {s}");
				if (!doc.Text.Contains(s) && !sVerbose)
					Console.WriteLine("---- generated ----\n{}\n-------------------", method);
			}
			if (c.SameAsSource)
			{
				Check(doc.Text == c.Source, "text unchanged by the edit");
				if (doc.Text != c.Source)
					Program.ShowDiff(c.Source, doc.Text);
			}
			for (let s in c.MustNotContain)
				Check(!doc.Text.Contains(s), scope $"text does not contain: {s}");

			// Stable: committing again changes nothing, and so does regenerating every node of
			// the method from a fresh parse of the written text.
			{
				doc.PushUndo();
				doc.Commit(doc.FindMethod(c.MethodKey));
				Check(doc.Text == c.Committed, "identity commit keeps the text");
				SourceDocument fresh = scope .();
				fresh.LoadFromText(c.Committed, scope $"{c.Name}.bf");
				let fmg = fresh.FindMethod(c.MethodKey);
				if (c.Committed.Contains("let __v"))
				{
					// `let __vN = ...;` reads back as the shared node, not as a local variable.
					bool folded = true;
					for (let n in fmg.Graph.Nodes)
						if (n.Kind == .LocalVar && n.Text.StartsWith("__v"))
							folded = false;
					Check(folded, "shared value temps read back as one shared node");
				}
				for (let n in fmg.Graph.Nodes)
					n.Edited = true;
				bool fok = fresh.Commit(fmg);
				Check(fok && fresh.Text == c.Committed, "regenerating the reparsed method reproduces the text");
				if (fresh.Text != c.Committed)
					Program.ShowDiff(c.Committed, fresh.Text);
			}
			return ok;
		}

		static int RunProcess(StringView exe, StringView args, StringView workDir, String outText)
		{
			ProcessStartInfo psi = scope .();
			psi.SetFileName(exe);
			psi.SetArguments(args);
			psi.SetWorkingDirectory(workDir);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = true;
			psi.CreateNoWindow = true;
			SpawnedProcess process = scope .();
			if (process.Start(psi) case .Err)
				return -1;
			FileStream stream = scope .();
			if (process.AttachStandardOutput(stream) case .Ok)
			{
				StreamReader reader = scope .(stream, null, false, 4096);
				reader.ReadToEnd(outText).IgnoreError();
			}
			process.WaitFor();
			return process.ExitCode;
		}

		static void WriteFile(StringView path, StringView text)
		{
			String dir = scope .();
			Path.GetDirectoryPath(path, dir).IgnoreError(); // no parent: dir stays empty
			Directory.CreateDirectory(dir).IgnoreError();
			if (File.WriteAllText(path, text) case .Err)
				Check(false, scope $"write {path}");
		}

		public static int Run(String[] args)
		{
			String outDir = scope .();
			Path.GetTempPath(outDir).IgnoreError(); // a failed temp lookup leaves the dir empty (relative scratch folder)
			outDir.Append("vb-codegen");
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-out" && i + 1 < args.Count)
					outDir.Set(args[++i]);
				else if (args[i] == "-v")
					sVerbose = true;
			}

			List<Case> cases = scope .();
			defer { ClearAndDeleteItems!(cases); }
			MakeCases(cases);

			for (let c in cases)
				c.Written = RunEdit(c);

			// Scratch workspace: one project, one file per case, Main dispatches on the name.
			String ws = scope .();
			ws.AppendF("{}/ws", outDir);
			String srcDir = scope .();
			srcDir.AppendF("{}/CgTest/src", ws);
			if (Directory.Exists(srcDir))
			{
				for (let entry in Directory.EnumerateFiles(srcDir))
				{
					String p = scope .();
					entry.GetFilePath(p);
					File.Delete(p).IgnoreError();
				}
			}
			WriteFile(scope String()..AppendF("{}/BeefSpace.toml", ws), "FileVersion = 1\nProjects = {CgTest = {Path = \"CgTest\"}}\n\n[Workspace]\nStartupProject = \"CgTest\"\n");
			WriteFile(scope String()..AppendF("{}/CgTest/BeefProj.toml", ws), "FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = \"CgTest\"\nStartupObject = \"CgTest.Program\"\n");
			String main = scope .();
			main.Append("using System;\n\nnamespace CgTest\n{\n\tclass Program\n\t{\n\t\tpublic static int Main(String[] args)\n\t\t{\n\t\t\tif (args.Count < 1)\n\t\t\t\treturn 2;\n");
			int compiled = 0;
			for (let c in cases)
			{
				if (!c.Written)
					continue;
				compiled++;
				WriteFile(scope String()..AppendF("{}/{}.bf", srcDir, c.Name), c.Committed);
				main.AppendF("\t\t\tif (args[0] == \"{}\")\n\t\t\t\t{}.Test.Run();\n", c.Name, c.Namespace);
			}
			main.Append("\t\t\treturn 0;\n\t\t}\n\t}\n}\n");
			WriteFile(scope String()..AppendF("{}/Program.bf", srcDir), main);

			if (compiled > 0)
			{
				String exe = scope .();
				exe.AppendF("{}/build/Debug_{}/CgTest/CgTest{}", ws, cPlatform, cExeSuffix);
				File.Delete(exe).IgnoreError();
				Console.WriteLine("Building {} cases in {} ...", compiled, ws);
				String buildOut = scope .();
				int code = RunProcess(cBeefBuild, scope $"\"-workspace={ws}\" -config=Debug -platform={cPlatform}", ws, buildOut);
				bool built = code == 0 && File.Exists(exe);
				Check(built, scope $"BeefBuild succeeded (exit {code})");
				if (!built || sVerbose)
				{
					for (let line in buildOut.Split('\n'))
						if (!built || line.Contains("ERROR") || line.Contains("WARNING"))
							Console.WriteLine("    | {}", line);
				}
				if (built)
				{
					for (let c in cases)
					{
						if (!c.Written)
							continue;
						String output = scope .();
						let exit = RunProcess(exe, c.Name, ws, output);
						output.Replace("\r\n", "\n");
						bool same = exit == 0 && output == c.Expected;
						Check(same, scope $"{c.Name}: program output matches");
						if (!same)
							Console.WriteLine("    expected:\n{}    got (exit {}):\n{}", c.Expected, exit, output);
						else
							Console.WriteLine("  {}: output ok", c.Name);
					}
				}
			}

			int refusals = 0;
			for (let c in cases)
				if (c.RefusalContains != null)
					refusals++;
			Console.WriteLine("compile: cases={} compiled={} refusals={} failures={}", cases.Count, compiled, refusals, sFailures);
			return (sFailures == 0) ? 0 : 1;
		}
	}
}
