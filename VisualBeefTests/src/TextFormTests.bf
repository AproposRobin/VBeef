using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// The last text forms as nodes (docs/Flow-Nodes.md, docs/Lifetime-Nodes.md): nested blocks
	/// (Scope), `const` / `ref` locals, `(.)` casts, `.()` values, `repeat`, local functions,
	/// lambdas and delegates (with their captures), event `+=`, payload switches, interpolated
	/// strings (Format) and statement attributes. Parsing, graph shapes, byte-exact identity
	/// commits, forced regeneration byte for byte and back to the same graph, layout keys.
	static class TextFormTests
	{
		static int sChecks;
		static int sFailures;

		static void Check(bool ok, StringView what)
		{
			sChecks++;
			if (ok)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		const String cSource =
			"""
			using System;
			using System.Collections;

			namespace Demo
			{
				struct Pair
				{
					public int A;
					public int B;
				}

				class Host
				{
					public Event<delegate void(int)> mOnValue ~ _.Dispose();
					public delegate void() mLog ~ delete _;
					public List<int> mItems = new .() ~ delete _;
					int mValue;

					void OnTick()
					{
					}

					static Result<int> Half(int v)
					{
						if (v % 2 != 0)
							return .Err;
						return v / 2;
					}

					public void Blocks()
					{
						const int kCount = 3;
						int total = 0;
						{
							int inner = kCount * 2;
							total += inner;
						}
						ref int slot = ref total;
						slot = 10;
						float f = (.)total;
						Pair p = .();
						repeat
						{
							total++;
						}
						while (total < 20);
						[ConstSkip]
						{
							Console.WriteLine("skip");
						}
					}

					public void Lambdas(int factor)
					{
						int sum = 0;
						mItems.Sort(scope (a, b) => a <=> b);
						delegate void(int) add = scope [&] (v) =>
						{
							sum += v * factor;
							Console.WriteLine("add {}", v);
						};
						add(5);
						mLog = new => OnTick;
						mOnValue.Add(new => OnTick);
						mOnValue += new (x) => Console.WriteLine(x);
						let one = scope (int a) => a + 1;
					}

					public void Locals()
					{
						int Twice(int x) => x * 2;
						void Say(String s)
						{
							Console.WriteLine("say {}", s);
						}
						Say("hi");
						Console.WriteLine("twice {}", Twice(21));
					}

					public void Strings(int count, String name)
					{
						Console.WriteLine($"count={count} hex={count:X2} pad={name,8} next={count + 1}");
						Console.WriteLine($"{{literal}} {name.Length} {Half(count) case .Ok}");
						Console.WriteLine($@"C:\\{name}\\x");
						Console.WriteLine($"no holes");
						String s = scope $"{mValue} items";
					}

					public void Payload()
					{
						switch (Half(8))
						{
						case .Ok(let h):
							Console.WriteLine("half {}", h);
						case .Err:
							Console.WriteLine("odd");
						}
					}
				}
			}

			""";

		static Node Find(Graph g, NodeKind kind, StringView text = "", int skip = 0)
		{
			int seen = 0;
			for (let n in g.Nodes)
			{
				if (n.Kind != kind || (!text.IsEmpty && n.Text != text))
					continue;
				if (seen++ == skip)
					return n;
			}
			return null;
		}

		static int Count(Graph g, NodeKind kind)
		{
			int c = 0;
			for (let n in g.Nodes)
				if (n.Kind == kind)
					c++;
			return c;
		}

		static void RunParse()
		{
			Console.WriteLine("Text forms 1: parsing");
			let unit = Parser.Parse(cSource);
			defer delete unit;
			List<Member> methods = scope .();
			unit.CollectMethods(methods, null);
			Member Method(StringView name)
			{
				for (let m in methods)
					if (m.Name == name)
						return m;
				return null;
			}
			let blocks = Method("Blocks").Body.Body;
			Check(blocks[0].Kind == .LocalVar && blocks[0].Alloc == "const" && blocks[0].VarType == "int", "`const int kCount = 3;` is a LocalVar with the const modifier");
			Check(blocks[2].Kind == .Block && blocks[2].Body.Count == 2, "a nested `{ }` is a Block statement");
			Check(blocks[3].Kind == .LocalVar && blocks[3].Alloc == "ref", "`ref int slot = ref total;` is a LocalVar with the ref modifier");
			Check(blocks[5].Kind == .LocalVar && blocks[5].Expr.Kind == .Cast && blocks[5].Expr.TypeText == ".", "`(.)total` is a Cast to `.`");
			Check(blocks[6].Expr.Kind == .New && blocks[6].Expr.Op.IsEmpty && blocks[6].Expr.TypeText == ".", "`.()` is a New with no allocation");
			Check(blocks[7].Kind == .DoWhile && blocks[7].Alloc == "repeat", "`repeat { } while (x);` is a DoWhile spelled repeat");
			Check(blocks[8].Kind == .Block && blocks[8].Attributes != null && blocks[8].Attributes.StartsWith("[ConstSkip]"), "`[ConstSkip] { }` keeps its attribute");

			let lambdas = Method("Lambdas").Body.Body;
			let sortArg = lambdas[1].Expr.Args[0];
			Check(sortArg.Kind == .Lambda && sortArg.Op == "scope" && sortArg.Params == "a, b" && sortArg.A != null, "`scope (a, b) => a <=> b`: a Lambda with an expression body");
			let addInit = lambdas[2].Expr;
			Check(addInit.Kind == .Lambda && addInit.Captures == "[&]" && addInit.Body != null && addInit.Body.Body.Count == 2, "`scope [&] (v) => { ... }`: captures and a block body");
			let bind = lambdas[4].Expr;
			Check(bind.Kind == .Assign && bind.B.Kind == .Lambda && bind.B.Params == null && bind.B.Op == "new", "`mLog = new => OnTick;`: a delegate bound to a method");
			Check(lambdas[6].Expr.Kind == .Assign && lambdas[6].Expr.Op == "+=" && lambdas[6].Expr.B.Kind == .Lambda, "event `+= new (x) => ...` is an assignment of a Lambda");
			Check(lambdas[7].Expr.Kind == .Lambda && lambdas[7].Expr.Params == "int a", "typed parameters are kept (`int a`)");

			let locals = Method("Locals").Body.Body;
			Check(locals[0].Kind == .LocalFunc && locals[0].VarName == "Twice" && locals[0].Expr != null && locals[0].ForHeader == "int Twice(int x)", "`int Twice(int x) => x * 2;` is a local function with an expression body");
			Check(locals[1].Kind == .LocalFunc && locals[1].Then != null && locals[1].Then.Kind == .Block, "`void Say(String s) { ... }` is a local function with a block");

			let payload = Method("Payload").Body.Body[0];
			Check(payload.Kind == .Switch && payload.Cases[0].BindName == "h" && payload.Cases[0].BindCase == "Ok", "`case .Ok(let h):` is a modelled switch case with a binding");
		}

		static void RunShapes(SourceDocument doc)
		{
			Console.WriteLine("Text forms 2: graph shapes");
			let gb = doc.FindMethod("Host.Blocks()").Graph;
			let scopeNode = Find(gb, .Scope);
			Check(scopeNode != null && gb.ExecTarget(scopeNode.FindOutput("body"))?.Kind == .LocalVar && scopeNode.Attributes == null, "the nested block is a Scope node whose Body starts with `int inner`");
			let skip = Find(gb, .Scope, "", 1);
			Check(skip != null && skip.Attributes != null && skip.Attributes.StartsWith("[ConstSkip]"), "`[ConstSkip] { }` is a Scope node carrying the attribute");
			let k = Find(gb, .LocalVar, "kCount");
			Check(k != null && k.Alloc == "const" && k.FindInput("value").Default == "3", "const local: LocalVar kCount, modifier const, value 3");
			let cast = Find(gb, .Cast, ".");
			Check(cast != null && gb.DataSource(cast.FindInput("value"))?.Text == "total", "`(.)total`: Cast (inferred) reading total");
			let made = Find(gb, .Construct, ".");
			Check(made != null && made.Alloc != null && made.Alloc.IsEmpty && made.Result.TypeName == "Pair", "`Pair p = .();`: Construct with no allocation, typed Pair from the local");
			Check(Find(gb, .DoWhile)?.Alloc == "repeat", "repeat loop: DoWhile spelled repeat");
			Check(Count(gb, .Code) == 0 && Count(gb, .Expr) == 0, "no Code or Expression node left in Blocks()");

			let gl = doc.FindMethod("Host.Lambdas(int)").Graph;
			Check(Count(gl, .Code) == 0 && Count(gl, .Expr) == 0, "no Code or Expression node left in Lambdas()");
			let cmp = Find(gl, .Lambda, "(a, b)");
			Check(cmp != null && cmp.Alloc == "scope" && cmp.FindOutput("param0")?.Label == "a" && cmp.FindOutput("param1")?.Label == "b" &&
				gl.DataSource(cmp.FindInput("expr"))?.Kind == .Operator, "sort lambda: params a, b as outputs, the comparison wired into Returns");
			let add = Find(gl, .Lambda, "(v)");
			Check(add != null && add.Attributes == "[&]" && gl.ExecTarget(add.FindOutput("body"))?.Kind == .Set, "block lambda: captures [&], Body starts with the `+=`");
			List<String> caps = scope .();
			defer { ClearAndDeleteItems!(caps); }
			if (add != null)
				gl.GetCaptures(add, caps);
			String capText = scope .();
			for (let c in caps)
				capText.AppendF("{}{}", (@c.Index > 0) ? "," : "", c);
			Check(caps.Count == 2 && capText.Contains("sum") && capText.Contains("factor"), scope $"captures listed: sum, factor ({capText})");
			List<String> noCaps = scope .();
			defer { ClearAndDeleteItems!(noCaps); }
			if (cmp != null)
				gl.GetCaptures(cmp, noCaps);
			Check(noCaps.IsEmpty, "the sort lambda captures nothing (a, b are its own)");
			Node bound = null;
			for (let n in gl.Nodes)
				if (n.Kind == .Lambda && n.Text2 == "OnTick" && n.Alloc == "new")
					bound = n;
			Check(bound != null && bound.Text.IsEmpty, "`new => OnTick`: Create Delegate node bound to OnTick");
			Node ev = null;
			for (let n in gl.Nodes)
				if (n.Kind == .Set && n.Text == "+=")
					ev = n;
			Check(ev != null && gl.DataSource(ev.FindInput("value"))?.Kind == .Lambda, "event `+=`: a Set (+=) whose value is a Lambda");

			let gloc = doc.FindMethod("Host.Locals()").Graph;
			let twice = Find(gloc, .LocalFunc, "Twice");
			Check(twice != null && twice.Text2 == "int Twice(int x)" && twice.FindOutput("param0")?.Label == "x" && gloc.DataSource(twice.FindInput("expr")) != null,
				"local function Twice: header kept, param x, expression body wired into Returns");
			let say = Find(gloc, .LocalFunc, "Say");
			Check(say != null && gloc.ExecTarget(say.FindOutput("body"))?.Kind == .Call, "local function Say: Body holds the WriteLine call");

			let gs = doc.FindMethod("Host.Strings(int,String)").Graph;
			let f1 = Find(gs, .Format);
			Check(f1 != null && f1.Text == "$\"count={} hex={:X2} pad={,8} next={}\"" && f1.Inputs.Count == 4, "Format: holes taken out, format and alignment kept, four inputs");
			Check(f1 != null && gs.DataSource(f1.FindInput("arg3"))?.Kind == .Operator, "the `count + 1` hole is an Operator node");
			let f2 = Find(gs, .Format, "", 1);
			Check(f2 != null && f2.Text.StartsWith("$\"{{literal}} {}") && gs.DataSource(f2.FindInput("arg1"))?.Kind == .Operator, "`{{` stays text; `Half(count) case .Ok` is a `case` operator");
			let f3 = Find(gs, .Format, "", 2);
			Check(f3 != null && f3.Text == "$@\"C:\\{}\\x\"", "verbatim `$@` string: the backslashes are text");
			int formats = Count(gs, .Format);
			Check(formats == 4, scope $"a string with no hole stays a literal ({formats} Format nodes)");
			let sc = Find(gs, .Construct, "$");
			Check(sc != null && gs.DataSource(sc.FindInput("arg0"))?.Kind == .Format, "`scope $\"{mValue} items\"`: Construct String fed by a Format");

			let gp = doc.FindMethod("Host.Payload()").Graph;
			let sw = Find(gp, .Switch);
			let pay = sw?.FindOutput("case0.payload");
			Check(pay != null && pay.Label == "h" && pay.TypeName == "int" && pay.IsOutArg, "payload switch: pin `h` typed int (from Result<int>)");
			int reads = 0;
			for (let l in gp.Links)
				if (l.From == pay)
					reads++;
			Check(reads == 1, "the `h` read in the Ok case is a wire from the payload pin");
		}

		static void RunRoundTrip()
		{
			Console.WriteLine("Text forms 3: round trip");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSource, "Host.bf");
			for (let key in StringView[?]("Host.Blocks()", "Host.Lambdas(int)", "Host.Locals()", "Host.Strings(int,String)", "Host.Payload()"))
			{
				doc.PushUndo();
				bool ok = doc.Commit(doc.FindMethod(key));
				Check(ok && doc.Text == cSource, scope $"{key}: identity commit byte for byte");
				String before = scope .();
				Program.GraphSignature(doc.FindMethod(key).Graph, before);
				for (let n in doc.FindMethod(key).Graph.Nodes)
					n.Edited = true;
				ok = doc.Commit(doc.FindMethod(key));
				Check(ok && doc.Text == cSource, scope $"{key}: every node regenerated, byte for byte");
				if (doc.Text != cSource)
				{
					Program.ShowDiff(cSource, doc.Text);
					doc.LoadFromText(cSource, "Host.bf");
				}
				String after = scope .();
				Program.GraphSignature(doc.FindMethod(key).Graph, after);
				Check(before == after, scope $"{key}: the regenerated text reads back as the same graph");
			}

			// Edits: a statement added to a lambda body, a ternary wired into a hole.
			{
				let mg = doc.FindMethod("Host.Lambdas(int)");
				let g = mg.Graph;
				let add = Find(g, .Lambda, "(v)");
				var last = g.ExecTarget(add.FindOutput("body"));
				while (g.ExecTarget(last.Then) != null)
					last = g.ExecTarget(last.Then);
				StringView[0] none = .();
				let call = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
				NodeFactory.AddArgument(g, call).Default.Set("\"more\"");
				g.Connect(last.Then, call.ExecIn);
				doc.PushUndo();
				bool ok = doc.Commit(mg);
				Check(ok && doc.Text.Contains("\t\t\t\tConsole.WriteLine(\"add {}\", v);\n\t\t\t\tConsole.WriteLine(\"more\");\n\t\t\t};\n"),
					"a statement added at the end of a lambda body is written inside the lambda, indented");
				doc.Undo();
				Check(doc.Text == cSource, "undo restores the lambda");
			}
			{
				let mg = doc.FindMethod("Host.Strings(int,String)");
				let g = mg.Graph;
				let f1 = Find(g, .Format);
				let sel = NodeFactory.Select(g);
				sel.FindInput("condition").Default.Set("count > 0");
				sel.FindInput("a").Default.Set("1");
				sel.FindInput("b").Default.Set("2");
				g.Connect(sel.Result, f1.FindInput("arg0"));
				doc.PushUndo();
				bool ok = doc.Commit(mg);
				Check(ok && (doc.Text.Contains("$\"count={((count > 0) ? 1 : 2)} hex={count:X2}") || doc.Text.Contains("$\"count={(count > 0 ? 1 : 2)} hex={count:X2}")),
					"a ternary wired into a hole is written in parentheses (a ':' would end the hole)");
				doc.Undo();
			}
		}

		static void RunLayoutKeys()
		{
			Console.WriteLine("Text forms 4: layout keys");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSource, "Host.bf");
			let g = doc.FindMethod("Host.Lambdas(int)").Graph;
			KeyAssigner.Assign(g);
			Node addCall = null;
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == "Add")
					addCall = n;
			let body = g.ExecTarget(Find(g, .Lambda, "(v)").FindOutput("body"));
			Check(body != null && body.Key.Contains("/body/s0"), scope $"statements in a lambda body get structural keys ({body?.Key})");
			// The same call with its argument as text (what it was before Lambda nodes).
			let arg = addCall.FindArg(0);
			let link = g.FindLinkTo(arg);
			let lambda = link.From.Owner;
			uint32 asNode = LayoutKeys.ContentHash(g, addCall);
			g.Disconnect(link);
			arg.Default.Set(lambda.Original);
			uint32 asText = LayoutKeys.ContentHash(g, addCall);
			Check(asNode == asText, "a call whose argument is now a short Lambda hashes like it did with the text in its pin");
		}

		const String cConditional =
			"""
			namespace Demo
			{
				class Gc
				{
					public static void Plain()
					{
						Report();
					}

			#if VB_TEST_LEAK || VB_TEST_ALLOC
					public static void Report()
					{
						Console.WriteLine("real");
					}

					public static void OnlyHere()
					{
					}
			#else
					public static void Report()
					{
					}
			#endif

					public T Get<T>() where T : class
					{
						return default;
					}

					public T Get<T>() where T : struct
					{
						return default;
					}
				}
			}

			""";

		static void RunConditional()
		{
			Console.WriteLine("Text forms 5: methods in #if / #else arms");
			SourceDocument doc = scope .();
			doc.LoadFromText(cConditional, "Gc.bf");
			String keys = scope .();
			for (let mg in doc.Methods)
				keys.AppendF("{}\n", mg.Key);
			Check(doc.FindMethod("Gc.Plain()") != null && doc.FindMethod("Gc.OnlyHere()") != null,
				"methods with no twin keep their plain key, inside an #if too");
			let a = doc.FindMethod("Gc.Report() [if VB_TEST_LEAK or VB_TEST_ALLOC]");
			let b = doc.FindMethod("Gc.Report() [else VB_TEST_LEAK or VB_TEST_ALLOC]");
			Check(a != null && b != null && a != b, "the two Report() arms get their own keys");
			Check(doc.FindMethod("Gc.Get() [where T : class]") != null && doc.FindMethod("Gc.Get() [where T : struct]") != null,
				"overloads told apart only by `where` get it in their key");
			Check(a != null && a.Graph.CondPath == "if VB_TEST_LEAK || VB_TEST_ALLOC" && b != null && b.Graph.CondPath == "else VB_TEST_LEAK || VB_TEST_ALLOC",
				"each graph knows its arm (the Entry subtitle shows it)");
			if (a != null && b != null)
			{
				Preprocessor.Defines.Add(new String("VB_TEST_ALLOC"));
				Check(Preprocessor.IsActive(a.Graph.CondPath) && !Preprocessor.IsActive(b.Graph.CondPath), "with VB_TEST_ALLOC defined the #if arm is the active one");
				String name = scope .("VB_TEST_ALLOC");
				if (Preprocessor.Defines.GetAndRemove(name) case .Ok(let removed))
					delete removed;
				Check(!Preprocessor.IsActive(a.Graph.CondPath) && Preprocessor.IsActive(b.Graph.CondPath), "without either define the #else arm is active");
			}
			Check(Preprocessor.Eval("A || (true && !false)") && !Preprocessor.Eval("UNDEFINED_X && true"), "condition evaluation: || && ! ( ) true false, unknown words are false");
			List<String> graphable = scope .();
			defer { ClearAndDeleteItems!(graphable); }
			for (let mg in doc.Methods)
				if (mg.Graphable)
					graphable.Add(new String(mg.Key));
			for (let key in graphable)
			{
				let mg = doc.FindMethod(key);
				doc.PushUndo();
				bool ok = doc.Commit(mg);
				Check(ok && doc.Text == cConditional, scope $"{key}: identity commit byte for byte");
				for (let n in doc.FindMethod(key).Graph.Nodes)
					n.Edited = true;
				ok = doc.Commit(doc.FindMethod(key));
				Check(ok && doc.Text == cConditional, scope $"{key}: regenerated byte for byte");
				if (doc.Text != cConditional)
				{
					Program.ShowDiff(cConditional, doc.Text);
					doc.LoadFromText(cConditional, "Gc.bf");
				}
			}
			// An edit of one arm leaves the other alone.
			{
				let mg = doc.FindMethod("Gc.Report() [else VB_TEST_LEAK or VB_TEST_ALLOC]");
				StringView[0] none = .();
				let call = NodeFactory.Call(mg.Graph, "Console.WriteLine", true, false, "", none, none, "void");
				NodeFactory.AddArgument(mg.Graph, call).Default.Set("\"stub\"");
				mg.Graph.Connect(mg.Graph.Entry.Then, call.ExecIn);
				doc.PushUndo();
				bool ok = doc.Commit(mg);
				Check(ok && doc.Text.Contains("#else\n\t\tpublic static void Report()\n\t\t{\n\t\t\tConsole.WriteLine(\"stub\");\n\t\t}\n") &&
					doc.Text.Contains("Console.WriteLine(\"real\");"), "an edit of the #else arm writes into that arm only");
				doc.Undo();
			}
		}

		static void RunFindReferences()
		{
			Console.WriteLine("Text forms 6: Find References");
			String a = """
				namespace Demo
				{
					class Player
					{
						public int mHealth;
						public void Hit(int amount)
						{
							mHealth -= amount;
							Log(mHealth);
						}
						public void Log(int v) {}
						public void Log(String s) {}
					}
				}

				""";
			String b = """
				namespace Demo
				{
					class Game
					{
						Player mPlayer = new .() ~ delete _;
						public void Tick()
						{
							mPlayer.mHealth = 10;
							let p = scope Player();
							p.Hit(mPlayer.mHealth);
						}
					}
				}

				""";
			ProjectIndex index = scope .();
			TypeService svc = scope .(index);
			svc.AutoLoadLibraries = false;
			{
				let ua = Parser.Parse(a);
				index.Update("Player.bf", ua);
				delete ua;
				let ub = Parser.Parse(b);
				index.Update("Game.bf", ub);
				delete ub;
			}
			List<RenameService.Source> sources = scope .();
			RenameService.Source sa;
			sa.Path = "Player.bf";
			sa.Text = a;
			sources.Add(sa);
			RenameService.Source sb;
			sb.Path = "Game.bf";
			sb.Text = b;
			sources.Add(sb);
			{
				RenameTarget t = scope .();
				t.Kind = .Member;
				t.OldName.Set("mHealth");
				t.TypeName.Set("Player");
				t.FilePath.Set("Player.bf");
				RenamePlan plan = scope .();
				RenameService.FindReferences(t, sources, svc, plan);
				Check(plan.Refusal.IsEmpty && plan.Count == 5 && plan.Files.Count == 2, scope $"Player.mHealth: 5 references in 2 files ({plan.Count} in {plan.Files.Count})");
			}
			{
				RenameTarget t = scope .();
				t.Kind = .Member;
				t.OldName.Set("Log");
				t.TypeName.Set("Player");
				t.FilePath.Set("Player.bf");
				RenamePlan plan = scope .();
				RenameService.FindReferences(t, sources, svc, plan);
				Check(plan.Refusal.IsEmpty && plan.Count >= 3, scope $"an overloaded function is found (a rename is refused for it): {plan.Count} references");
				RenamePlan rename = scope .();
				t.NewName.Set("Write");
				RenameService.Plan(t, sources, svc, rename);
				Check(!rename.Refusal.IsEmpty, "the same target as a rename is still refused");
			}
			{
				RenameTarget t = scope .();
				t.Kind = .Type;
				t.OldName.Set("Player");
				t.FilePath.Set("Player.bf");
				RenamePlan plan = scope .();
				RenameService.FindReferences(t, sources, svc, plan);
				Check(plan.Refusal.IsEmpty && plan.Files.Count == 2 && plan.Count >= 3, scope $"type Player: declaration and uses in both files ({plan.Count})");
			}
			{
				RenameTarget t = scope .();
				t.Kind = .Parameter;
				t.OldName.Set("amount");
				t.TypeName.Set("Player");
				t.MethodKey.Set("Player.Hit(int)");
				t.FilePath.Set("Player.bf");
				RenamePlan plan = scope .();
				RenameService.FindReferences(t, sources, svc, plan);
				Check(plan.Refusal.IsEmpty && plan.Count == 2 && plan.Files.Count == 1, scope $"parameter amount: 2 references in its function ({plan.Count})");
			}
		}

		const String cOverloads =
			"""
			using System;

			namespace Demo
			{
				class Host
				{
					int8 mSmall = 3;

					static void Show(int v)
					{
						Console.WriteLine("int {}", v);
					}

					static void Show(float v)
					{
						Console.WriteLine("float {}", v);
					}

					public void Run()
					{
						Show(mSmall);
						Show(4);
					}
				}
			}

			""";

		static void RunOverloads()
		{
			Console.WriteLine("Text forms 7: overload choice");
			SourceDocument doc = scope .();
			doc.LoadFromText(cOverloads, "Host.bf");
			let mg = doc.FindMethod("Host.Run()");
			Node amb = null;
			Node exact = null;
			for (let n in mg.Graph.Nodes)
			{
				if (n.Kind != .Call || n.Text != "Show")
					continue;
				if (n.Ambiguous)
					amb = n;
				else
					exact = n;
			}
			Check(amb != null && amb.Overloads != null && amb.Overloads.Count == 2 && amb.Overloads.Contains("Show(int v)") && amb.Overloads.Contains("Show(float v)"),
				"`Show(mSmall)` (an int8) is ambiguous between Show(int v) and Show(float v), both listed");
			Check(exact != null && exact.Overloads == null, "`Show(4)` is not: int is exact");
			if (amb == null)
				return;
			doc.PushUndo();
			String why = scope .();
			bool picked = NodeFactory.PickOverload(mg.Graph, amb, "Show(float v)", why);
			Check(picked && !amb.Ambiguous && amb.Overloads[0] == "Show(float v)", "picking Show(float v) clears the ambiguity");
			bool ok = doc.Commit(mg);
			Check(ok && doc.Text.Contains("\t\t\tShow((float)mSmall);\n") && doc.Text.Contains("\t\t\tShow(4);\n"), "the choice is written as a cast on the argument");
			Node again = null;
			for (let n in doc.FindMethod("Host.Run()").Graph.Nodes)
				if (n.Kind == .Call && n.Text == "Show" && n.Ambiguous)
					again = n;
			Check(again == null, "read back, the call is no longer ambiguous");
			doc.Undo();
			Check(doc.Text == cOverloads, "undo removes the cast");
			// Overloads that differ only by an out parameter cannot be told apart by a cast.
			Node fake = scope .();
			fake.Kind = .Call;
			fake.Overloads = new .();
			fake.Overloads.Add(new String("Get(out int v)"));
			fake.Overloads.Add(new String("Get(out float v)"));
			why.Clear();
			Check(!NodeFactory.PickOverload(doc.FindMethod("Host.Run()").Graph, fake, "Get(out int v)", why) && why.Contains("out / ref"), scope $"out-only overloads: refused with a reason ({why})");
		}

		public static int Run()
		{
			sChecks = 0;
			sFailures = 0;
			RunOverloads();
			RunFindReferences();
			RunConditional();
			RunParse();
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Host.bf");
				RunShapes(doc);
			}
			RunRoundTrip();
			RunLayoutKeys();
			Console.WriteLine("text form checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}
	}
}
