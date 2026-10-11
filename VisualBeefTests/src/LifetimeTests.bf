using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests lifetime`: Construct (`new` / `scope`), Delete, Defer, Using and the Result
	/// node (docs/Lifetime-Nodes.md): parsing, graph shapes, byte-exact round trips, code written
	/// for nodes made in the editor, and the lifetime rules (GraphValidator and the generator's
	/// planning pass). The Defer / Using body group also runs in `flow`; builds and runs of the
	/// same constructs are in `compile`.
	static class LifetimeTests
	{
		static int sFailures;
		static int sChecks;

		public static int Checks => sChecks;
		public static int Failures => sFailures;

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

		const String cSource =
			"""
			using System;
			using System.Collections;
			using System.Threading;

			namespace Demo
			{
				class Item
				{
					public int mValue;

					public this()
					{
					}

					public this(int value, String name)
					{
						mValue = value;
					}

					public void Use()
					{
					}
				}

				class Host
				{
					Monitor mLock = new .() ~ delete _;

					public Result<int> Parse(StringView s)
					{
						return 1;
					}

					public Result<int, String> Load(int id)
					{
						return .Err("no");
					}

					static void Take(String s)
					{
					}

					public void Allocs()
					{
						let a = new Item();
						let b = new Item(1, "one");
						let c = scope Item();
						let d = scope:: Item(2, "two");
						String e = scope .();
						let f = new int[4];
						let g = scope int[2];
						Take(scope String());
						Take(scope $"x={a.mValue}");
						let h = new String()..Append("h");
						let i = new List<int>() { 1, 2 };
						delete a;
						delete:gAlloc b;
						delete f;
						delete h;
						delete i;
					}

					public void Deletes(Item x, List<Item> list)
					{
						delete x;
						DeleteContainerAndItems!(list);
					}

					public void Defers(Item x)
					{
						defer delete x;
						defer
						{
							Console.WriteLine("b");
							Console.WriteLine("c");
						}
						defer:: Console.WriteLine("d");
						defer
						{
							Console.WriteLine("e");
						}
						Console.WriteLine("a");
					}

					public void Usings()
					{
						using (mLock.Enter())
						{
							Console.WriteLine("locked");
						}
						using (let m = mLock.Enter())
							Console.WriteLine("one line");
						using(mLock.Enter()) {
							Console.WriteLine("k&r");
						}
					}

					public Result<int> Results(StringView s)
					{
						if (Parse(s) case .Ok(let v))
							return v;
						if (Parse(s) case .Err)
							return .Err;
						if (Load(1) case .Err(let msg))
						{
							Console.WriteLine(msg);
						}
						else if (Load(2) case .Ok(var w))
						{
							Console.WriteLine(w);
						}
						else
						{
							Console.WriteLine("neither");
						}
						bool ok = Parse(s) case .Ok;
						if (Parse(s) case .Ok(let x) && x > 3)
							return x;
						int t = Try!(Parse(s));
						Parse(s).IgnoreError();
						return t;
					}
				}
			}

			""";

		// ------------------------------------------------------------------ helpers

		static Node FindNode(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
			return null;
		}

		static int CountKind(Graph g, NodeKind kind)
		{
			int c = 0;
			for (let n in g.Nodes)
				if (n.Kind == kind)
					c++;
			return c;
		}

		static Node FindConstruct(Graph g, StringView alloc, StringView type)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Construct && n.Alloc == alloc && n.Text == type)
					return n;
			return null;
		}

		static Node FindCall(Graph g, StringView name, StringView arg0 = "")
		{
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call || n.Text != name)
					continue;
				if (arg0.IsEmpty)
					return n;
				let p = n.FindInput("arg0");
				if (p != null && p.Default == arg0)
					return n;
			}
			return null;
		}

		static bool HasError(Graph g, StringView text, Node on = null)
		{
			for (let e in g.Errors)
				if (e.Message.Contains(text) && (on == null || e.NodeId == on.Id))
					return true;
			return false;
		}

		static bool HasWarning(Graph g, StringView text, Node on = null)
		{
			for (let e in g.Warnings)
				if (e.Message.Contains(text) && (on == null || e.NodeId == on.Id))
					return true;
			return false;
		}

		static void ShowProblems(Graph g)
		{
			for (let e in g.Errors)
				Console.WriteLine("       error: {}", e.Message);
			for (let e in g.Warnings)
				Console.WriteLine("       warning: {}", e.Message);
		}

		static void MethodText(SourceDocument doc, StringView key, String o)
		{
			let mg = doc.FindMethod(key);
			if (mg == null || !mg.Method.HasSpan)
				return;
			let start = doc.Unit.Tokens[mg.Method.FirstTok].Start;
			let end = doc.Unit.Tokens[mg.Method.LastTok].End;
			o.Append(StringView(doc.Text, start, end - start));
		}

		static Node WriteLine(Graph g, StringView format)
		{
			StringView[0] none = .();
			let n = NodeFactory.Call(g, "Console.WriteLine", true, false, "", none, none, "void");
			NodeFactory.AddArgument(g, n).Default.Set(format);
			return n;
		}

		/// Chains exec nodes after `from` (the entry's Then when null).
		static void Chain(Graph g, Pin from, params Node[] nodes)
		{
			Pin prev = from ?? g.Entry.Then;
			for (let n in nodes)
			{
				g.Connect(prev, n.ExecIn);
				prev = n.Then;
			}
		}

		/// The last node of the chain starting at `execOut`.
		static Node LastOf(Graph g, Pin execOut)
		{
			var n = g.ExecTarget(execOut);
			while (n != null && g.ExecTarget(n.Then) != null)
				n = g.ExecTarget(n.Then);
			return n;
		}

		/// Identity commit and forced regeneration of every method reproduce the text, and the
		/// regenerated graphs equal the graphs read from the code.
		static void CheckByteExact(StringView source, StringView what)
		{
			SourceDocument doc = scope .();
			doc.LoadFromText(source, "Lifetime.bf");
			List<String> keys = scope .();
			defer { ClearAndDeleteItems!(keys); }
			for (let mg in doc.Methods)
				if (mg.Graphable)
					keys.Add(new String(mg.Key));
			bool identity = true;
			for (let key in keys)
				if (!doc.Commit(doc.FindMethod(key)) || doc.Text != source)
					identity = false;
			bool forced = true;
			for (let key in keys)
			{
				let mg = doc.FindMethod(key);
				let g = mg.Graph;
				for (let n in g.Nodes)
					n.Edited = true;
				if (!doc.Commit(mg))
				{
					ShowProblems(g);
					forced = false;
				}
			}
			if (doc.Text != source)
			{
				forced = false;
				Program.ShowDiff(source, doc.Text);
			}
			Check(identity, scope $"{what}: an identity commit of every method changes nothing");
			Check(forced, scope $"{what}: regenerating every statement reproduces the file byte for byte");
		}

		// ------------------------------------------------------------------ 1. parsing

		static void RunParse()
		{
			Console.WriteLine("Lifetime: parsing");
			let unit = Parser.Parse(cSource);
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
			let allocs = Find("Allocs");
			Check(allocs != null && allocs.Body != null, "Allocs has a body");
			if (allocs == null || allocs.Body == null)
				return;
			let body = allocs.Body.Body;
			Expr Init(int i) => (i < body.Count && body[i].Kind == .LocalVar) ? body[i].Expr : null;
			let a = Init(0);
			Check(a != null && a.Kind == .New && a.Op == "new" && a.TypeText == "Item" && a.Args.Count == 0, "`new Item()`: a New expression");
			let b = Init(1);
			Check(b != null && b.Kind == .New && b.Args.Count == 2, "`new Item(1, \"one\")`: two arguments");
			let c = Init(2);
			Check(c != null && c.Kind == .New && c.Op == "scope", "`scope Item()`");
			let d = Init(3);
			Check(d != null && d.Kind == .New && d.Op == "scope::" && d.Args.Count == 2, "`scope:: Item(2, \"two\")`: the alloc text is `scope::`");
			let e = Init(4);
			Check(e != null && e.Kind == .New && e.TypeText == ".", "`scope .()`: inferred type");
			let f = Init(5);
			Check(f != null && f.Kind == .New && f.IsArray && f.TypeText == "int" && f.Args.Count == 1, "`new int[4]`: an array with one size");
			let h = (body.Count > 9 && body[9].Kind == .LocalVar) ? body[9].Expr : null;
			Check(h != null && h.Kind == .Call && h.A != null && h.A.Kind == .Member && h.A.Cascade && h.A.A != null && h.A.A.Kind == .New,
				"`new String()..Append(\"h\")`: the allocation is the cascade's target");
			let i = Init(10);
			Check(i != null && i.Kind == .Raw, "`new List<int>() { 1, 2 }` (an initialiser) stays raw text");
			let take = (body.Count > 8 && body[8].Kind == .Expr) ? body[8].Expr : null;
			Check(take != null && take.Kind == .Call && take.Args.Count == 1 && take.Args[0].Kind == .New && take.Args[0].TypeText == "$",
				"`scope $\"x={a.mValue}\"`: a String made from an interpolated string");
			int deletes = 0;
			for (let s in body)
				if (s.Kind == .Delete)
					deletes++;
			Check(deletes == 5, scope $"five `delete` statements (got {deletes})");
			let delAlloc = (body.Count > 12) ? body[12] : null;
			Check(delAlloc != null && delAlloc.Kind == .Delete && delAlloc.Alloc == "delete:gAlloc", "`delete:gAlloc b;` keeps its allocator");

			let defers = Find("Defers");
			if (defers != null && defers.Body != null)
			{
				let db = defers.Body.Body;
				Check(db.Count == 5 && db[0].Kind == .Defer && db[0].Then != null && db[0].Then.Kind == .Delete, "`defer delete x;`: Defer with a Delete body");
				Check(db.Count == 5 && db[1].Kind == .Defer && db[1].Then.Kind == .Block, "`defer { ... }`: Defer with a block");
				Check(db.Count == 5 && db[2].Kind == .Defer && db[2].Alloc == "defer::", "`defer:: ...` keeps its scope target");
			}
			let usings = Find("Usings");
			if (usings != null && usings.Body != null)
			{
				let ub = usings.Body.Body;
				Check(ub.Count == 3 && ub[0].Kind == .Using && ub[0].VarName == null, "`using (mLock.Enter())`");
				Check(ub.Count == 3 && ub[1].Kind == .Using && ub[1].VarName == "m" && ub[1].VarType == "let" && ub[1].Then.Kind == .Expr,
					"`using (let m = ...) stmt;`: declaration and one-line body");
			}
			let results = Find("Results");
			if (results != null && results.Body != null)
			{
				let rb = results.Body.Body;
				let cond = (rb.Count > 0 && rb[0].Kind == .If) ? rb[0].Expr : null;
				Check(cond != null && cond.Kind == .Binary && cond.Op == "case" && cond.B != null && unit.NodeText(cond.B) == ".Ok(let v)",
					"`Parse(s) case .Ok(let v)`: a `case` pattern test");
				let andCond = (rb.Count > 4 && rb[4].Kind == .If) ? rb[4].Expr : null;
				Check(andCond != null && andCond.Kind == .Binary && andCond.Op == "&&" && andCond.A.Kind == .Binary && andCond.A.Op == "case",
					"`... case .Ok(let x) && x > 3`: `case` binds tighter than `&&`");
			}
		}

		// ------------------------------------------------------------------ 2. graph shapes

		static void RunShapes()
		{
			Console.WriteLine("Lifetime: graph shapes");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSource, "Lifetime.bf");

			let ga = doc.FindMethod("Host.Allocs()").Graph;
			Check(CountKind(ga, .Construct) == 10, scope $"Allocs: ten Construct nodes (got {CountKind(ga, .Construct)})");
			let a = FindConstruct(ga, "new", "Item");
			Check(a != null && a.Result != null && a.Result.TypeName == "Item" && a.IsPure, "`new Item()`: a pure Construct typed Item");
			Node b = null;
			for (let n in ga.Nodes)
				if (n.Kind == .Construct && n.Text == "Item" && n.ArgCount == 2 && n.Alloc == "new")
					b = n;
			Check(b != null && b.FindInput("arg0")?.Label == "value" && b.FindInput("arg1")?.Label == "name",
				"`new Item(1, \"one\")`: constructor arguments named from `this(int value, String name)`");
			Check(FindConstruct(ga, "scope::", "Item") != null, "`scope:: Item(...)`: alloc scope::");
			let e = FindConstruct(ga, "scope", ".");
			Check(e != null && e.Result.TypeName == "String", "`String e = scope .();`: the inferred type comes from the local (String)");
			let f = FindConstruct(ga, "new", "int");
			Check(f != null && f.IsArray && f.Result.TypeName == "int[]" && f.FindInput("arg0")?.Default == "4", "`new int[4]`: array Construct, Count 4, typed int[]");
			let s = FindConstruct(ga, "scope", "$");
			let sFmt = (s != null) ? ga.DataSource(s.FindInput("arg0")) : null;
			Check(s != null && sFmt != null && sFmt.Kind == .Format && sFmt.Text == "$\"x={}\"" && ga.DataSource(sFmt.FindInput("arg0"))?.Text == "a.mValue" &&
				s.Result.TypeName == "String", "`scope $\"...\"`: Construct String whose Text is a Format node, the hole `a.mValue` wired in");
			let la = FindNode(ga, .LocalVar, "a");
			Check(la != null && ga.DataSource(la.FindInput("value")) == a, "`let a = new Item();`: the local's value is wired from the Construct");
			let cascade = FindCall(ga, "Append");
			Check(cascade != null && cascade.Cascade && ga.DataSource(cascade.FindInput("target"))?.Kind == .Construct, "`new String()..Append(\"h\")`: Construct wired into the cascade's Target");
			Check(CountKind(ga, .Delete) == 5, "Allocs: five Delete nodes");
			let delA = FindNode(ga, .Delete);
			Check(delA != null && ga.DataSource(delA.FindInput("value"))?.Text == "a", "`delete a;`: the Object input reads `a`");
			bool gAlloc = false;
			for (let n in ga.Nodes)
				if (n.Kind == .Delete && n.Alloc == "delete:gAlloc")
					gAlloc = true;
			Check(gAlloc, "`delete:gAlloc b;`: Delete keeps its allocator");
			bool initText = false;
			let li = FindNode(ga, .LocalVar, "i");
			if (li != null)
			{
				let v = li.FindInput("value");
				let src = ga.DataSource(v);
				initText = (src != null && src.Kind == .Expr) || v.Default.Contains("{ 1, 2 }");
			}
			Check(initText, "`new List<int>() { 1, 2 }`: the initialiser stays text");

			let gd = doc.FindMethod("Host.Deletes(Item,List<Item>)").Graph;
			Check(FindCall(gd, "DeleteContainerAndItems!") != null, "`DeleteContainerAndItems!(list)`: a call node (mixin)");

			let gf = doc.FindMethod("Host.Defers(Item)").Graph;
			Check(CountKind(gf, .Defer) == 4, "Defers: four Defer nodes");
			let d0 = gf.ExecTarget(gf.Entry.Then);
			Check(d0 != null && d0.Kind == .Defer && gf.ExecTarget(d0.FindOutput("body"))?.Kind == .Delete, "`defer delete x;` reads back as Defer -> Delete");
			let d1 = (d0 != null) ? gf.ExecTarget(d0.Then) : null;
			let d1a = (d1 != null) ? gf.ExecTarget(d1.FindOutput("body")) : null;
			Check(d1a != null && d1a.Kind == .Call && gf.ExecTarget(d1a.Then)?.Kind == .Call, "`defer { b; c; }`: two statements hang off Deferred");
			let d2 = (d1 != null) ? gf.ExecTarget(d1.Then) : null;
			Check(d2 != null && d2.Kind == .Defer && d2.Alloc == "defer::", "`defer:: ...`: Defer with alloc defer::");

			let gu = doc.FindMethod("Host.Usings()").Graph;
			Check(CountKind(gu, .Using) == 3, "Usings: three Using nodes");
			let u0 = gu.ExecTarget(gu.Entry.Then);
			Check(u0 != null && u0.Kind == .Using && gu.DataSource(u0.FindInput("value"))?.Text == "Enter" && gu.ExecTarget(u0.FindOutput("body"))?.Kind == .Call,
				"`using (mLock.Enter()) { ... }`: value wired from the call, body chained");
			let u1 = (u0 != null) ? gu.ExecTarget(u0.Then) : null;
			Check(u1 != null && u1.Kind == .Using && u1.Text == "m" && u1.Text2 == "let" && u1.FindOutput("variable") != null, "`using (let m = ...)`: the variable is an output");

			let gr = doc.FindMethod("Host.Results(StringView)").Graph;
			let r0 = gr.ExecTarget(gr.Entry.Then);
			Check(r0 != null && r0.Kind == .ResultMatch && r0.Text == "Ok", "`if (Parse(s) case .Ok(let v))`: a Result node testing Ok");
			let pay = r0?.FindOutput("payload");
			Check(pay != null && pay.IsOutArg && pay.OutName == "v" && pay.Form == .Inline && pay.TypeName == "int", "its payload pin is `v`, typed int (from Result<int>)");
			let ret = (r0 != null) ? gr.ExecTarget(r0.FindOutput("ok")) : null;
			Check(ret != null && ret.Kind == .Return && gr.FindLinkTo(ret.FindInput("value"))?.From == pay, "`return v;` in the Ok arm reads the payload by a wire");
			let r1 = (r0 != null) ? gr.ExecTarget(r0.Then) : null;
			Check(r1 != null && r1.Kind == .ResultMatch && r1.Text == "Err" && r1.FindOutput("payload").Form == .Discard && gr.ExecTarget(r1.FindOutput("err"))?.Kind == .Return,
				"`if (Parse(s) case .Err) return .Err;`: tests Err, no binding, the Err arm returns");
			let r2 = (r1 != null) ? gr.ExecTarget(r1.Then) : null;
			Check(r2 != null && r2.Kind == .ResultMatch && r2.Text == "Err" && r2.FindOutput("payload").OutName == "msg" && r2.FindOutput("payload").TypeName == "String",
				"`case .Err(let msg)` on a Result<int, String>: the error payload is typed String");
			let r3 = (r2 != null) ? gr.ExecTarget(r2.FindOutput("ok")) : null;
			Check(r3 != null && r3.Kind == .ResultMatch && r3.FindOutput("payload").OutDecl == "var", "`else if (Load(2) case .Ok(var w))`: a Result node in the other arm, `var` kept");
			let lok = FindNode(gr, .LocalVar, "ok");
			Check(lok != null && gr.DataSource(lok.FindInput("value"))?.Kind == .Operator && gr.DataSource(lok.FindInput("value")).Text == "case",
				"`bool ok = Parse(s) case .Ok;`: an Operator node `case`");
			let tryCall = FindCall(gr, "Try!");
			Check(tryCall != null && tryCall.Result != null && tryCall.Result.TypeName == "int", "`Try!(Parse(s))`: a call node typed int");
			Check(FindCall(gr, "IgnoreError") != null, "`.IgnoreError()`: a call node");
		}

		// ------------------------------------------------------------------ 3. round trips

		static void RunRoundTrip()
		{
			Console.WriteLine("Lifetime: byte-exact round trips");
			// Identity commits are byte-exact; regenerating every statement gives braces to
			// one-line bodies (as for if / while), so it is compared as graphs here and byte for
			// byte on the braced code below.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Lifetime.bf");
				List<String> keys = scope .();
				defer { ClearAndDeleteItems!(keys); }
				for (let mg in doc.Methods)
					if (mg.Graphable)
						keys.Add(new String(mg.Key));
				bool identity = true;
				for (let key in keys)
					if (!doc.Commit(doc.FindMethod(key)) || doc.Text != cSource)
						identity = false;
				Check(identity, "every lifetime form: an identity commit of every method changes nothing");
				bool forced = true;
				for (let key in keys)
				{
					let mg = doc.FindMethod(key);
					for (let n in mg.Graph.Nodes)
						n.Edited = true;
					if (!doc.Commit(mg))
					{
						ShowProblems(mg.Graph);
						forced = false;
					}
				}
				SourceDocument original = scope .();
				original.LoadFromText(cSource, "Lifetime.bf");
				SourceDocument reparsed = scope .();
				reparsed.LoadFromText(doc.Text, "Lifetime.bf");
				for (let key in keys)
				{
					String a = scope .();
					String b = scope .();
					Program.GraphSignature(original.FindMethod(key).Graph, a);
					Program.GraphSignature(reparsed.FindMethod(key).Graph, b);
					if (a != b)
					{
						forced = false;
						Console.WriteLine("    {} differs", key);
						Program.ShowDiff(a, b);
					}
				}
				Check(forced, "every lifetime form: regenerating every statement reads back as the same graphs");
			}
			CheckByteExact(cBodies, "Defer / Using / Result blocks in Allman and K&R style");

			// Forced regeneration rewrites each node: the result reads back as the same graph.
			SourceDocument doc = scope .();
			doc.LoadFromText(cSource, "Lifetime.bf");
			SourceDocument fresh = scope .();
			fresh.LoadFromText(cSource, "Lifetime.bf");
			bool same = true;
			for (let mg in doc.Methods)
			{
				if (!mg.Graphable)
					continue;
				String a = scope .();
				String b = scope .();
				Program.GraphSignature(mg.Graph, a);
				Program.GraphSignature(fresh.FindMethod(mg.Key).Graph, b);
				if (a != b)
					same = false;
			}
			Check(same, "two reads of the same file give the same graphs");
		}

		// ------------------------------------------------------------------ 4. code for new nodes

		const String cEmpty =
			"""
			using System;

			namespace Demo
			{
				class Item
				{
					public this(int value)
					{
					}

					public void Use()
					{
					}
				}

				class Host
				{
					Monitor mLock = new .() ~ delete _;

					public Result<int> Parse(StringView s)
					{
						return 1;
					}

					public void Run()
					{
					}

					public Result<int> Twice()
					{
						return .Err;
					}
				}
			}

			""";

		static bool Edit(SourceDocument doc, StringView key, delegate void(Graph g) make, StringView source = cEmpty)
		{
			doc.LoadFromText(source, "Lifetime.bf");
			let mg = doc.FindMethod(key);
			if (mg == null)
				return false;
			doc.PushUndo();
			make(mg.Graph);
			return doc.Commit(mg);
		}

		/// The committed text reads back as a graph that regenerates to the same text.
		static void CheckStable(SourceDocument doc, StringView key, StringView what)
		{
			SourceDocument fresh = scope .();
			fresh.LoadFromText(doc.Text, "Lifetime.bf");
			let mg = fresh.FindMethod(key);
			for (let n in mg.Graph.Nodes)
				n.Edited = true;
			bool ok = fresh.Commit(mg);
			Check(ok && fresh.Text == doc.Text, scope $"{what}: the written code reads back and regenerates to the same text");
			if (fresh.Text != doc.Text)
				Program.ShowDiff(doc.Text, fresh.Text);
		}

		static void RunGenerate()
		{
			Console.WriteLine("Lifetime: code for nodes made in the editor");
			StringView[0] none = .();
			StringView[1] valueName = .("value");
			StringView[1] intType = .("int");

			// Construct forms into locals, a Delete, a Defer with one statement and with two.
			{
				SourceDocument doc = scope .();
				Node defer1 = null;
				bool ok = Edit(doc, "Host.Run()", scope [&] (g) =>
					{
						let c1 = NodeFactory.Construct(g, "Item", "new", valueName, intType);
						c1.FindInput("arg0").Default.Set("3");
						let l1 = NodeFactory.LocalVar(g, "item", "var");
						g.Connect(c1.Result, l1.FindInput("value"));
						let c2 = NodeFactory.Construct(g, ".", "scope", none, none);
						let l2 = NodeFactory.LocalVar(g, "text", "String");
						g.Connect(c2.Result, l2.FindInput("value"));
						let c3 = NodeFactory.Construct(g, "int", "scope::", none, none, true);
						c3.FindInput("arg0").Default.Set("8");
						let l3 = NodeFactory.LocalVar(g, "buffer", "var");
						g.Connect(c3.Result, l3.FindInput("value"));
						let c4 = NodeFactory.Construct(g, "$", "scope", none, none);
						c4.FindInput("arg0").Default.Set("$\"n={text.Length}\"");
						let say = WriteLine(g, "\"{}\"");
						g.Connect(c4.Result, NodeFactory.AddArgument(g, say));
						defer1 = NodeFactory.Defer(g);
						let del = NodeFactory.Delete(g);
						g.Connect(l1.FindOutput("variable"), del.FindInput("value"));
						Chain(g, defer1.FindOutput("body"), del);
						let defer2 = NodeFactory.Defer(g, "defer::");
						Chain(g, defer2.FindOutput("body"), WriteLine(g, "\"x\""), WriteLine(g, "\"y\""));
						Chain(g, null, l1, l2, l3, say, defer1, defer2);
					});
				Check(ok, "a graph of Construct / Delete / Defer nodes is written");
				String text = scope .();
				MethodText(doc, "Host.Run()", text);
				Check(text.Contains("\t\t\tvar item = new Item(3);\n\t\t\tString text = scope .();\n\t\t\tvar buffer = scope:: int[8];\n"), "`new Item(3)`, `scope .()`, `scope:: int[8]`");
				Check(text.Contains("Console.WriteLine(\"{}\", scope $\"n={text.Length}\");"), "`scope $\"...\"` written as the string itself");
				if (!text.Contains("Console.WriteLine(\"{}\", scope $"))
					Console.WriteLine(text);
				Check(text.Contains("\t\t\tdefer delete item;\n"), "a Defer with one plain statement is written on one line");
				Check(text.Contains("\t\t\tdefer::\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"x\");\n\t\t\t\tConsole.WriteLine(\"y\");\n\t\t\t}\n"), "a Defer with two statements gets a block (Allman file)");
				if (!text.Contains("defer delete item;"))
					Console.WriteLine(text);
				CheckStable(doc, "Host.Run()", "Construct / Delete / Defer");
			}

			// Defer -> Delete of a Construct that a statement after the Defer reads too (the
			// newcomer's `new` + Defer -> Delete + use): the value is declared before the Defer.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Run()", scope [&] (g) =>
					{
						let c1 = NodeFactory.Construct(g, "Item", "new", valueName, intType);
						c1.FindInput("arg0").Default.Set("3");
						let d = NodeFactory.Defer(g);
						let del = NodeFactory.Delete(g);
						g.Connect(c1.Result, del.FindInput("value"));
						Chain(g, d.FindOutput("body"), del);
						let say = WriteLine(g, "\"{}\"");
						g.Connect(c1.Result, NodeFactory.AddArgument(g, say));
						Chain(g, null, d, say);
					});
				Check(ok, "a Construct read by a Delete in a Defer and by a statement after it is written (no 'different blocks' error)");
				String text = scope .();
				MethodText(doc, "Host.Run()", text);
				int made = text.IndexOf("= new Item(3);");
				int deferAt = text.IndexOf("defer delete __v");
				Check(made > 0 && deferAt > made && text.Contains("Console.WriteLine(\"{}\", __v"), "`let __vN = new Item(3);` before `defer delete __vN;`, then the read");
				if (deferAt < 0)
					Console.WriteLine(text);
				CheckStable(doc, "Host.Run()", "Defer -> Delete of a shared Construct");
			}

			// Using with and without a declaration; the variable read in the body.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Run()", scope [&] (g) =>
					{
						StringView[0] none2 = .();
						let enter = NodeFactory.Call(g, "Enter", false, true, "mLock", none2, none2, "MonitorLockScope");
						let u1 = NodeFactory.Using(g);
						g.Connect(enter.Result, u1.FindInput("value"));
						Chain(g, u1.FindOutput("body"), WriteLine(g, "\"locked\""));
						let enter2 = NodeFactory.Call(g, "Enter", false, true, "mLock", none2, none2, "MonitorLockScope");
						let u2 = NodeFactory.Using(g, "scope1", "let");
						g.Connect(enter2.Result, u2.FindInput("value"));
						let say = WriteLine(g, "\"{}\"");
						g.Connect(u2.FindOutput("variable"), NodeFactory.AddArgument(g, say));
						Chain(g, u2.FindOutput("body"), say);
						Chain(g, null, u1, u2);
					});
				Check(ok, "two Using nodes are written");
				String text = scope .();
				MethodText(doc, "Host.Run()", text);
				Check(text.Contains("\t\t\tusing (mLock.Enter())\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"locked\");\n\t\t\t}\n"), "`using (mLock.Enter()) { ... }`");
				Check(text.Contains("\t\t\tusing (let scope1 = mLock.Enter())\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"{}\", scope1);\n"), "`using (let scope1 = ...)`, the variable read in the body");
				CheckStable(doc, "Host.Run()", "Using");
			}

			// Result: Ok tested, the payload read in the Ok arm; Err tested without a binding.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Run()", scope [&] (g) =>
					{
						StringView[1] sName = .("s");
						StringView[1] sType = .("StringView");
						let parse = NodeFactory.MemberCall(g, "Parse", "Host", false, sName, sType, "Result<int>");
						parse.FindInput("arg0").Default.Set("\"12\"");
						let m = NodeFactory.ResultMatch(g, true, "Result<int>");
						g.Connect(parse.Result, m.FindInput("value"));
						let say = WriteLine(g, "\"ok {}\"");
						g.Connect(m.FindOutput("payload"), NodeFactory.AddArgument(g, say));
						Chain(g, m.FindOutput("ok"), say);
						Chain(g, m.FindOutput("err"), WriteLine(g, "\"bad\""));
						let parse2 = NodeFactory.MemberCall(g, "Parse", "Host", false, sName, sType, "Result<int>");
						parse2.FindInput("arg0").Default.Set("\"x\"");
						let m2 = NodeFactory.ResultMatch(g, false, "Result<int>");
						g.Connect(parse2.Result, m2.FindInput("value"));
						Chain(g, m2.FindOutput("err"), WriteLine(g, "\"x is bad\""));
						Chain(g, null, m, m2);
					});
				Check(ok, "two Result nodes are written");
				String text = scope .();
				MethodText(doc, "Host.Run()", text);
				Check(text.Contains("\t\t\tif (Parse(\"12\") case .Ok(let value))\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"ok {}\", value);\n\t\t\t}\n\t\t\telse\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"bad\");\n\t\t\t}\n"),
					"`if (Parse(\"12\") case .Ok(let value)) ... else ...`: the binding is named and read in the Ok arm");
				Check(text.Contains("\t\t\tif (Parse(\"x\") case .Err)\n\t\t\t{\n\t\t\t\tConsole.WriteLine(\"x is bad\");\n\t\t\t}\n"), "`case .Err` with nothing read: no binding, no else");
				if (!text.Contains("case .Ok(let value)"))
					Console.WriteLine(text);
				CheckStable(doc, "Host.Run()", "Result");
				// The payload unwired again: the binding goes away.
				let mg = doc.FindMethod("Host.Run()");
				let g = mg.Graph;
				let m = FindNode(g, .ResultMatch, "Ok");
				doc.PushUndo();
				g.DisconnectPin(m.FindOutput("payload"));
				let say = FindCall(g, "WriteLine", "\"ok {}\"");
				say.FindInput("arg1").Default.Set("0");
				ok = doc.Commit(mg);
				text.Clear();
				MethodText(doc, "Host.Run()", text);
				Check(ok && text.Contains("if (Parse(\"12\") case .Ok)"), "a payload nothing reads is written `case .Ok` (a binding the editor made)");
			}
		}

		// ------------------------------------------------------------------ 5. lifetime rules

		const String cRules =
			"""
			using System;

			namespace Demo
			{
				class Item
				{
					public void Use()
					{
					}
				}

				class Host
				{
					public Result<int> Parse(StringView s)
					{
						return 1;
					}

					public int Compute(int a)
					{
						return a;
					}

					public void Branchy(bool f)
					{
						String s = null;
						if (f)
						{
							Console.WriteLine("in");
						}
						Console.WriteLine(s);
					}

					public String Give()
					{
						return null;
					}

					public void Plain(Item x)
					{
						int n = 0;
						Console.WriteLine(n);
					}

					public void FromCode(bool f)
					{
						String s = null;
						if (f)
						{
							s = scope String();
						}
						Console.WriteLine(s);
					}
				}
			}

			""";

		static void RunRules()
		{
			Console.WriteLine("Lifetime: rules (GraphValidator and the planning pass)");
			StringView[0] none = .();

			// A `scope` value stored in an outer local inside a branch, read after the branch.
			{
				SourceDocument doc = scope .();
				Node alloc = null;
				bool ok = Edit(doc, "Host.Branchy(bool)", scope [&] (g) =>
					{
						let branch = FindNode(g, .Branch);
						alloc = NodeFactory.Construct(g, "String", "scope", none, none);
						let set = NodeFactory.Set(g, "s", "String");
						g.Connect(alloc.Result, set.FindInput("value"));
						let first = g.ExecTarget(branch.FindOutput("true"));
						g.Connect(branch.FindOutput("true"), set.ExecIn);
						g.Connect(set.Then, first.ExecIn);
					}, cRules);
				Check(!ok, "`s = scope String()` in a branch, `s` read after it: refused");
				Check(HasError(doc.FindMethod("Host.Branchy(bool)").Graph, "allocated with `scope` in a block that has ended", alloc), "the error is on the Construct: \"...allocated with `scope` in a block that has ended...\"");
				Check(HasError(doc.FindMethod("Host.Branchy(bool)").Graph, "after the block that allocated its value"), "and on the reader");
			}
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Branchy(bool)", scope [&] (g) =>
					{
						let branch = FindNode(g, .Branch);
						let alloc = NodeFactory.Construct(g, "String", "scope::", none, none);
						let set = NodeFactory.Set(g, "s", "String");
						g.Connect(alloc.Result, set.FindInput("value"));
						let first = g.ExecTarget(branch.FindOutput("true"));
						g.Connect(branch.FindOutput("true"), set.ExecIn);
						g.Connect(set.Then, first.ExecIn);
					}, cRules);
				Check(ok, "the same with `scope::` (lives until the method returns): written");
			}
			// Returning a `scope` value.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Give()", scope [&] (g) =>
					{
						let ret = g.ExecTarget(g.Entry.Then);
						let alloc = NodeFactory.Construct(g, "String", "scope", none, none);
						g.Connect(alloc.Result, ret.FindInput("value"));
					}, cRules);
				Check(!ok && HasError(doc.FindMethod("Host.Give()").Graph, "Returns a value allocated with `scope`"), "returning a `scope` value is refused");
			}
			// Deleting a `scope` value: a warning.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						let alloc = NodeFactory.Construct(g, "Item", "scope", none, none);
						let local = NodeFactory.LocalVar(g, "tmp", "var");
						g.Connect(alloc.Result, local.FindInput("value"));
						let del = NodeFactory.Delete(g);
						g.Connect(local.FindOutput("variable"), del.FindInput("value"));
						let first = g.ExecTarget(g.Entry.Then);
						Chain(g, null, local, del, first);
					}, cRules);
				let g = doc.FindMethod("Host.Plain(Item)").Graph;
				Check(ok && HasWarning(g, "Deletes a value allocated with `scope`"), "deleting a `scope` value: written, with a double-free warning");
			}
			// `new` with nothing that deletes it: a warning; with a Delete: none.
			for (int withDelete < 2)
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						let alloc = NodeFactory.Construct(g, "Item", "new", none, none);
						let local = NodeFactory.LocalVar(g, "it", "var");
						g.Connect(alloc.Result, local.FindInput("value"));
						let use = NodeFactory.MemberCall(g, "Use", "Item", true, none, none, "void");
						g.Connect(local.FindOutput("variable"), use.FindInput("target"));
						let first = g.ExecTarget(g.Entry.Then);
						if (withDelete == 1)
						{
							let del = NodeFactory.Delete(g);
							g.Connect(local.FindOutput("variable"), del.FindInput("value"));
							Chain(g, null, local, use, del, first);
						}
						else
							Chain(g, null, local, use, first);
					}, cRules);
				let g = doc.FindMethod("Host.Plain(Item)").Graph;
				if (withDelete == 0)
					Check(ok && HasWarning(g, "Nothing deletes this object"), "`new` used only through its members: written, with a warning");
				else
					Check(ok && !HasWarning(g, "Nothing deletes this object"), "the same with a Delete: no warning");
			}
			// The Result payload read outside its arm.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						StringView[1] sName = .("s");
						StringView[1] sType = .("StringView");
						let parse = NodeFactory.MemberCall(g, "Parse", "Host", false, sName, sType, "Result<int>");
						parse.FindInput("arg0").Default.Set("\"1\"");
						let m = NodeFactory.ResultMatch(g, true, "Result<int>");
						g.Connect(parse.Result, m.FindInput("value"));
						let say = WriteLine(g, "\"{}\"");
						g.Connect(m.FindOutput("payload"), NodeFactory.AddArgument(g, say));
						let first = g.ExecTarget(g.Entry.Then);
						Chain(g, null, m, say, first);
					}, cRules);
				Check(!ok && HasError(doc.FindMethod("Host.Plain(Item)").Graph, "outside its Ok arm"), "the Ok value read after the Result node (outside its Ok arm) is refused");
			}
			// A value computed in a Defer body, read after the Defer.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						StringView[1] aName = .("a");
						StringView[1] intType = .("int");
						let d = NodeFactory.Defer(g);
						let comp = NodeFactory.MemberCall(g, "Compute", "Host", true, aName, intType, "int");
						comp.FindInput("arg0").Default.Set("2");
						Chain(g, d.FindOutput("body"), comp);
						let say = WriteLine(g, "\"{}\"");
						g.Connect(comp.Result, NodeFactory.AddArgument(g, say));
						let first = g.ExecTarget(g.Entry.Then);
						Chain(g, null, d, say, first);
					}, cRules);
				Check(!ok && HasError(doc.FindMethod("Host.Plain(Item)").Graph, "inside a Defer body"), "a call result from a Defer body read after the Defer is refused");
			}
			// Return inside a Defer body.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						let d = NodeFactory.Defer(g);
						Chain(g, d.FindOutput("body"), NodeFactory.Return(g, "void"));
						let first = g.ExecTarget(g.Entry.Then);
						Chain(g, null, d, first);
					}, cRules);
				Check(!ok && HasError(doc.FindMethod("Host.Plain(Item)").Graph, "A deferred body can't return"), "Return inside a Defer body is refused");
			}
			// Defer order: a later Defer deleting what an earlier one reads.
			for (int swapped < 2)
			{
				SourceDocument doc = scope .();
				Node reader = null;
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						let dUse = NodeFactory.Defer(g);
						let use = NodeFactory.MemberCall(g, "Use", "Item", true, none, none, "void");
						g.Connect(NodeFactory.Get(g, "x", "Item").Result, use.FindInput("target"));
						Chain(g, dUse.FindOutput("body"), use);
						let dDel = NodeFactory.Defer(g);
						let del = NodeFactory.Delete(g);
						g.Connect(NodeFactory.Get(g, "x", "Item").Result, del.FindInput("value"));
						Chain(g, dDel.FindOutput("body"), del);
						let first = g.ExecTarget(g.Entry.Then);
						if (swapped == 0)
							Chain(g, null, dUse, dDel, first);
						else
							Chain(g, null, dDel, dUse, first);
						reader = dUse;
					}, cRules);
				let g = doc.FindMethod("Host.Plain(Item)").Graph;
				if (swapped == 0)
					Check(ok && HasWarning(g, "Deferred code runs last-first", reader), "`defer x.Use(); defer delete x;`: a warning on the first Defer (the delete runs first)");
				else
					Check(ok && !HasWarning(g, "Deferred code runs last-first"), "`defer delete x; defer x.Use();`: no warning");
			}
			// A Using variable read outside its body.
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Host.Plain(Item)", scope [&] (g) =>
					{
						let u = NodeFactory.Using(g, "guard", "let");
						u.FindInput("value").Default.Set("default");
						let say = WriteLine(g, "\"{}\"");
						g.Connect(u.FindOutput("variable"), NodeFactory.AddArgument(g, say));
						let first = g.ExecTarget(g.Entry.Then);
						Chain(g, null, u, say, first);
					}, cRules);
				Check(!ok && HasError(doc.FindMethod("Host.Plain(Item)").Graph, "outside its body"), "a Using variable read after the Using is refused");
			}
			// The same shape as the first refusal, read from code: a warning only (the compiler
			// accepted it), so real code is never refused.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cRules, "Rules.bf");
				let mg = doc.FindMethod("Host.FromCode(bool)");
				let g = mg.Graph;
				for (let n in g.Nodes)
					n.Edited = true;
				bool ok = doc.Commit(mg);
				Check(ok && HasWarning(g, "after the block that allocated its value"), "read from code: `s = scope String()` in a branch and read after it is a warning, not an error");
				Check(doc.Text == cRules, "and the code is written back unchanged");
			}
		}

		// ------------------------------------------------------------------ 6. bodies (also in `flow`)

		const String cBodies =
			"""
			using System;

			namespace Demo
			{
				class Item
				{
				}

				class Host
				{
					Monitor mLock = new .() ~ delete _;

					public void OneLine(Item x)
					{
						defer delete x;
						Console.WriteLine("a");
					}

					public void Block(Item x)
					{
						defer {
							Console.WriteLine("b");
						}
						using(mLock.Enter()) {
							Console.WriteLine("c");
						}
					}

					public Result<int> Chain(Result<int> r, Result<int> q)
					{
						if (r case .Err)
						{
							return .Err;
						}
						else if (q case .Ok(let v))
						{
							return v;
						}
						return 0;
					}
				}
			}

			""";

		/// Edits inside Defer / Using bodies: only the edited statements change, the headers and
		/// brace styles stay, merges into a body are refused.
		public static int RunBodies()
		{
			int failuresBefore = sFailures;
			Console.WriteLine("Lifetime: Defer / Using bodies");
			// A statement added to a one-line Defer: the Defer gets a block.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cBodies, "Bodies.bf");
				let mg = doc.FindMethod("Host.OneLine(Item)");
				let g = mg.Graph;
				let d = FindNode(g, .Defer);
				let del = g.ExecTarget(d.FindOutput("body"));
				doc.PushUndo();
				let say = WriteLine(g, "\"after\"");
				g.Connect(del.Then, say.ExecIn);
				bool ok = doc.Commit(mg);
				String text = scope .();
				MethodText(doc, "Host.OneLine(Item)", text);
				Check(ok && text.Contains("\t\t\tdefer\n\t\t\t{\n\t\t\t\tdelete x;\n\t\t\t\tConsole.WriteLine(\"after\");\n\t\t\t}\n\t\t\tConsole.WriteLine(\"a\");"),
					"a second statement in `defer delete x;` turns it into `defer { ... }`");
				if (!ok)
					ShowProblems(g);
			}
			// Statements added to K&R Defer / Using blocks keep their headers.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cBodies, "Bodies.bf");
				let mg = doc.FindMethod("Host.Block(Item)");
				let g = mg.Graph;
				let d = FindNode(g, .Defer);
				let u = FindNode(g, .Using);
				doc.PushUndo();
				let s1 = WriteLine(g, "\"b2\"");
				g.Connect(LastOf(g, d.FindOutput("body")).Then, s1.ExecIn);
				let s2 = WriteLine(g, "\"c2\"");
				g.Connect(LastOf(g, u.FindOutput("body")).Then, s2.ExecIn);
				bool ok = doc.Commit(mg);
				String text = scope .();
				MethodText(doc, "Host.Block(Item)", text);
				Check(ok && text.Contains("\t\t\tdefer {\n\t\t\t\tConsole.WriteLine(\"b\");\n\t\t\t\tConsole.WriteLine(\"b2\");\n\t\t\t}\n"), "`defer {` (K&R) keeps its header when its body changes");
				Check(ok && text.Contains("\t\t\tusing(mLock.Enter()) {\n\t\t\t\tConsole.WriteLine(\"c\");\n\t\t\t\tConsole.WriteLine(\"c2\");\n\t\t\t}\n"), "`using(mLock.Enter()) {` keeps its header when its body changes");
				CheckStable(doc, "Host.Block(Item)", "edited Defer / Using bodies");
			}
			// A statement wired into a Defer body from outside it: two exec wires, refused.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cBodies, "Bodies.bf");
				let mg = doc.FindMethod("Host.OneLine(Item)");
				let g = mg.Graph;
				let d = FindNode(g, .Defer);
				let say = g.ExecTarget(d.Then);
				doc.PushUndo();
				g.Connect(LastOf(g, d.FindOutput("body")).Then, say.ExecIn);
				bool ok = doc.Commit(mg);
				Check(!ok && HasError(g, "Two flow wires"), "a node both in a Defer body and after it is refused (two flow wires)");
			}
			// `else if (q case .Ok(let v))` keeps its `else if` when everything is regenerated.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cBodies, "Bodies.bf");
				let mg = doc.FindMethod("Host.Chain(Result<int>,Result<int>)");
				if (mg == null)
				{
					for (let m in doc.Methods)
						Console.WriteLine("    method {}", m.Key);
					Check(false, "Host.Chain found");
					return sFailures - failuresBefore;
				}
				let g = mg.Graph;
				for (let n in g.Nodes)
					n.Edited = true;
				bool ok = doc.Commit(mg);
				Check(ok && doc.Text == cBodies, "an `if ... else if` chain of Result nodes regenerates byte for byte");
				let m = FindNode(g, .ResultMatch, "Err");
				let inner = (m != null) ? g.ExecTarget(m.FindOutput("ok")) : null;
				Check(inner != null && inner.Kind == .ResultMatch && inner.Text == "Ok", "the `else if` is a Result node in the Ok arm of the first");
			}
			return sFailures - failuresBefore;
		}

		const String cSilence =
			"""
			using System;

			namespace Demo
			{
				class Other
				{
				}

				class Greeter
				{
					public this(int count, Other other)
					{
					}

					public void Ping()
					{
					}

					public void Hello()
					{
					}
				}
			}

			""";

		/// A graph the writer cannot express never ends in a silent no-op: the commit is refused with an
		/// error on the node (docs/Codegen.md > No silent writes), or it writes and says what it left out.
		static void RunSilence()
		{
			Console.WriteLine("Lifetime: no silent writes");
			StringView[2] pn = .("count", "other");
			StringView[2] pt = .("int", "Other");
			StringView[0] none = .();

			// A scope / new Construct wired into a Receiver is written as typed (`scope Greeter(1, null).Ping();` is
			// valid Beef: the scope applies to the construction, the call runs on it) and reads back.
			for (let alloc in StringView[?]("new", "scope", "scope::"))
			{
				SourceDocument doc = scope .();
				bool ok = Edit(doc, "Greeter.Hello()", scope (g) =>
					{
						let c = NodeFactory.Construct(g, "Greeter", alloc, pn, pt);
						c.FindInput("arg0").Default.Set("1");
						c.FindInput("arg1").Default.Set("null");
						let call = NodeFactory.MemberCall(g, "Ping", "Greeter", true, none, none, "void");
						g.Connect(c.Result, call.FindInput("target"));
						Chain(g, null, call);
					}, cSilence);
				String text = scope .();
				MethodText(doc, "Greeter.Hello()", text);
				Check(ok && text.Contains(scope $"\t\t\t{alloc} Greeter(1, null).Ping();\n"), scope $"`{alloc} Greeter(1, null)` wired into the Receiver of Ping is written as `{alloc} Greeter(1, null).Ping();`");
				CheckStable(doc, "Greeter.Hello()", scope $"Construct ({alloc}) into a Receiver");
			}

			// Switching a parsed `new Greeter(1, null).Ping();` to scope changes the file text.
			{
				SourceDocument doc = scope .();
				let src = scope String(cSilence);
				src.Replace("public void Hello()\n\t\t{\n", "public void Hello()\n\t\t{\n\t\t\tnew Greeter(1, null).Ping();\n");
				Node c = null;
				bool ok = Edit(doc, "Greeter.Hello()", scope [&] (g) =>
					{
						c = FindNode(g, .Construct);
						if (c != null)
						{
							c.Alloc.Set("scope");
							c.Edited = true;
						}
					}, src);
				String text = scope .();
				MethodText(doc, "Greeter.Hello()", text);
				Check(c != null && ok && text.Contains("\t\t\tscope Greeter(1, null).Ping();\n"), "a parsed `new Greeter(1, null).Ping();` switched to scope is written as `scope Greeter(1, null).Ping();`");
			}

			// Configurations the writer cannot express: refused with an error on the node, the file untouched.
			for (int kind < 6)
			{
				SourceDocument doc = scope .();
				Node bad = null;
				StringView what = "";
				bool ok = Edit(doc, "Greeter.Hello()", scope [&] (g) =>
					{
						switch (kind)
						{
						case 0:
							what = "a Construct without a Type as a Receiver";
							bad = NodeFactory.Construct(g, ".", "scope", pn, pt);
							bad.FindInput("arg0").Default.Set("1");
							bad.FindInput("arg1").Default.Set("null");
							let call = NodeFactory.MemberCall(g, "Ping", "Greeter", true, none, none, "void");
							g.Connect(bad.Result, call.FindInput("target"));
							Chain(g, null, call);
						case 1:
							what = "a Local Variable without a name";
							bad = NodeFactory.LocalVar(g, "", "int");
							Chain(g, null, bad);
						case 2:
							what = "a Call without a function name";
							bad = NodeFactory.Call(g, "", true, false, "", none, none, "void");
							Chain(g, null, bad);
						case 3:
							what = "a Get without a name";
							bad = NodeFactory.Get(g, "", "int");
							let local = NodeFactory.LocalVar(g, "x", "int");
							g.Connect(bad.Result, local.FindInput("value"));
							Chain(g, null, local);
						case 4:
							what = "a Cast without a type";
							bad = NodeFactory.Cast(g, "");
							bad.FindInput("value").Default.Set("1");
							let local = NodeFactory.LocalVar(g, "x", "int");
							g.Connect(bad.Result, local.FindInput("value"));
							Chain(g, null, local);
						default:
							what = "a Local Variable of type void";
							bad = NodeFactory.LocalVar(g, "x", "void");
							bad.Edited = true;
							Chain(g, null, bad);
						}
					}, cSilence);
				let mg = doc.FindMethod("Greeter.Hello()");
				bool onNode = mg != null && bad != null && mg.Graph.Errors.Count > 0;
				bool flagged = false;
				if (onNode)
					for (let e in mg.Graph.Errors)
						if (e.NodeId == bad.Id)
							flagged = true;
				Check(!ok && flagged && doc.Text == cSilence, scope $"{what}: refused, an error on the node, the file unchanged (ok {ok}, flagged {flagged})");
				if (!flagged && mg != null)
					ShowProblems(mg.Graph);
			}

			// A node the flow never reaches is kept in the Sheet but reported; an empty Code node too.
			{
				SourceDocument doc = scope .();
				Node loose = null;
				Node empty = null;
				bool ok = Edit(doc, "Greeter.Hello()", scope [&] (g) =>
					{
						loose = NodeFactory.Code(g, "int unreached = 1;");
						empty = NodeFactory.Code(g, "");
						Chain(g, null, empty);
					}, cSilence);
				let mg = doc.FindMethod("Greeter.Hello()");
				Check(ok && !doc.Text.Contains("unreached"), "a node the flow never reaches writes nothing...");
				Check(mg != null && HasWarning(mg.Graph, "Not connected to the execution flow", loose), "...and carries the warning \"Not connected to the execution flow\"");
				Check(mg != null && HasWarning(mg.Graph, "empty", empty), "an empty Code node carries the warning \"This Code node is empty\"");
				Check(!doc.Messages.IsEmpty, "and the commit messages (the status line, the Problems list) mention it");
			}
		}

		// ------------------------------------------------------------------ 7. deleting Locals

		const String cLocalLife =
			"""
			using System;

			namespace Demo
			{
				class Item
				{
					public int mValue;

					public void Use()
					{
					}
				}

				class Host
				{
					public void Run()
					{
						Item item = scope .();
						Item spare = scope .();
						int count = 0;
						int plain = 5;
						item.Use();
						count = count + 1;
						Console.WriteLine(count);
					}
				}
			}

			""";

		static void RunLocalLifetime()
		{
			Console.WriteLine("lifetime: deleting Locals");
			SourceDocument doc = scope .();
			doc.LoadFromText(cLocalLife, "Host.bf");
			var mg = doc.FindMethod("Host.Run()");
			let g = mg.Graph;
			Check(g.Locals.Count == 4, "four Locals: item, spare, count, plain");
			let item = g.FindLocal("item");
			let spare = g.FindLocal("spare");
			let count = g.FindLocal("count");
			let plain = g.FindLocal("plain");
			Check(g.IsLocalUsed(item) && g.IsLocalUsed(count) && !g.IsLocalUsed(spare) && !g.IsLocalUsed(plain), "used: item (a call on it), count (read and written); unused: spare, plain");
			String why = scope .();
			Check(!g.RemoveLocal(item, why) && g.Locals.Count == 4 && g.FindLocal("item") == item, "a `scope` Local that a later call uses is not deleted");
			Check(why.Contains("'item'") && why.Contains("`scope`") && why.Contains("until the function ends"), "...and the reason names the Local and its lifetime");
			why.Clear();
			Check(!g.RemoveLocal(count, why) && why.Contains("'count' is still used") && !why.Contains("`scope`"), "a plain Local that is read is refused too, without the `scope` wording");
			why.Clear();
			Check(!g.RemoveLocal(null, why) && why.IsEmpty, "no Local: nothing happens");
			doc.PushUndo();
			Check(g.RemoveLocal(spare, why) && g.Locals.Count == 3 && why.IsEmpty, "an unused `scope` Local is deleted");
			Check(doc.Commit(mg) && !doc.Text.Contains("spare") && doc.Text.Contains("Item item = scope .();"), "...and its declaration is gone from the text");
			doc.PushUndo();
			Check(g.RemoveLocal(g.FindLocal("plain"), why) && doc.Commit(doc.FindMethod("Host.Run()")) && !doc.Text.Contains("plain"), "an unused plain Local is deleted");
			// The uses go first, then the Local can follow.
			mg = doc.FindMethod("Host.Run()");
			let g2 = mg.Graph;
			Node use = null;
			for (let n in g2.Nodes)
				if (n.Kind == .Call && n.Text == "Use")
					use = n;
			Check(use != null, "the call `item.Use()` is a node");
			doc.PushUndo();
			if (use != null)
			{
				List<Node> feeders = scope .();
				for (let n in g2.Nodes)
					if (n.Kind == .Get && n.Text == "item")
						feeders.Add(n);
				for (let n in feeders)
					g2.RemoveNode(n);
				g2.RemoveNode(use);
			}
			why.Clear();
			Check(doc.Commit(doc.FindMethod("Host.Run()")), "the use removed and committed");
			let g3 = doc.FindMethod("Host.Run()").Graph;
			Check(!g3.IsLocalUsed(g3.FindLocal("item")) && g3.RemoveLocal(g3.FindLocal("item"), why), "with the use gone, the `scope` Local can be deleted");
			Check(doc.Commit(doc.FindMethod("Host.Run()")) && !doc.Text.Contains("Item item") && doc.Text.Contains("int count = 0;"), "...and the other Locals stay");
			// A name in a string or after a dot is not a use.
			SourceDocument d2 = scope .();
			String t2 = scope .(cLocalLife);
			t2.Replace("Console.WriteLine(count);", "Console.WriteLine(\"plain spare\");");
			d2.LoadFromText(t2, "Host.bf");
			let g4 = d2.FindMethod("Host.Run()").Graph;
			Check(!g4.IsLocalUsed(g4.FindLocal("spare")), "a name inside a string literal is not a use");
		}

		public static int Run()
		{
			sFailures = 0;
			sChecks = 0;
			RunParse();
			RunShapes();
			RunRoundTrip();
			RunGenerate();
			RunRules();
			RunBodies();
			RunSilence();
			RunLocalLifetime();
			Console.WriteLine("lifetime checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}
	}
}
