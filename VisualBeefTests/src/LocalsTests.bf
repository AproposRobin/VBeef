using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// The function's Locals (Graph.Locals), its Outputs (out parameters on the Return node) and
	/// variables made from a pin (docs/Classes-and-Members.md#locals, #outputs). Run by `classes`
	/// (RunClasses) and `flow` (RunFlow).
	static class LocalsTests
	{
		public static int Checks;
		public static int Failures;

		static void Check(bool cond, StringView what)
		{
			Checks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				Failures++;
			}
		}

		static void CheckText(StringView got, StringView want, StringView what)
		{
			Check(got == want, what);
			if (got != want)
				Program.ShowDiff(want, got);
		}

		/// `text` contains `want`; on failure the text is printed.
		static void CheckHas(bool ok, StringView text, StringView want, StringView what)
		{
			Check(ok && text.Contains(want), what);
			if (!(ok && text.Contains(want)))
				Console.WriteLine(scope $"  --- text:\n{text}");
		}

		static Node FindNode(Graph g, NodeKind kind, StringView text = default)
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

		/// Every function commits back byte for byte, and regenerating every statement too.
		static bool IdentityAll(StringView text)
		{
			SourceDocument doc = scope .();
			doc.LoadFromText(text, "T.bf");
			List<String> keys = scope .();
			defer { ClearAndDeleteItems!(keys); }
			for (let mg in doc.Methods)
				if (mg.Graphable)
					keys.Add(new String(mg.Key));
			for (let key in keys)
			{
				var mg = doc.FindMethod(key);
				let g = mg.Graph;
				doc.Commit(mg);
				if (doc.Text != text)
				{
					Console.WriteLine("  identity commit of {} changed the text:", key);
					Program.ShowDiff(text, doc.Text);
					return false;
				}
				mg = doc.FindMethod(key);
				for (let n in g.Nodes)
					n.Edited = true;
				for (let n in g.Locals)
					n.Edited = true;
				String body = scope .();
				if (!doc.GenerateMethodBody(mg, body))
					return false;
				String now = scope .();
				let b = mg.Method.Body;
				now.Append(StringView(doc.Unit.Text, doc.Unit.Tokens[b.FirstTok].End, doc.Unit.Tokens[b.LastTok].Start - doc.Unit.Tokens[b.FirstTok].End));
				if (body != now)
				{
					Program.ShowDiff(now, body);
					return false;
				}
			}
			return true;
		}

		const String cLocals =
			"""
			using System;

			namespace Mod
			{
				class Counter
				{
					public int mTotal;

					public void Run(int start)
					{
						// how many
						int count = 0;
						String name = scope .();
						float speed = 2.5f;
						count = start + 1;
						Console.WriteLine(count);
						int later = count * 2;
						mTotal = later;
					}

					public void Mixed()
					{
						let fixedValue = 3;
						int after = 4;
						mTotal = fixedValue + after;
					}

					public void Called()
					{
						int got = Compute();
						mTotal = got;
					}

					int Compute()
					{
						return 3;
					}
				}
			}

			""";

		static void TestRead()
		{
			Console.WriteLine("locals: read from code");
			SourceDocument doc = scope .();
			doc.LoadFromText(cLocals, "Counter.bf");
			let run = doc.FindMethod("Counter.Run(int)").Graph;
			Check(run.Locals.Count == 3 && run.Locals[0].Text == "count" && run.Locals[1].Text == "name" && run.Locals[2].Text == "speed",
				scope $"the three declarations at the top are Run's Locals, in order ({run.Locals.Count})");
			Check(run.Locals[0].Text2 == "int" && run.Locals[0].FindInput("value").Default == "0", "count: int, value 0");
			Check(run.Locals[1].Text2 == "String" && run.Locals[1].FindInput("value").Default == "scope .()", "name: String made here (`scope .()` as its value)");
			Check(CountKind(run, .Construct) == 0, "no Construct node is left for `scope .()`");
			Check(FindNode(run, .LocalVar, "later") != null && run.FindLocal("later") == null, "`int later` in the middle of the body stays a node in the flow");
			Check(run.CanBeLocal(FindNode(run, .LocalVar, "later"), ?), "...and Move to Locals is offered for it");
			Check(FindNode(run, .LocalVar, "count") == null, "no Local Variable node for a Local");
			let mixed = doc.FindMethod("Counter.Mixed()").Graph;
			Check(mixed.Locals.IsEmpty && FindNode(mixed, .LocalVar, "fixedValue") != null && FindNode(mixed, .LocalVar, "after") != null,
				"`let` first: not a Local, and the typed declaration after it stays in the flow too (Locals are the top run)");
			let called = doc.FindMethod("Counter.Called()").Graph;
			Check(called.Locals.IsEmpty && FindNode(called, .LocalVar, "got") != null, "`int got = Compute();` (a call) stays a node: its value needs a node");
			Check(IdentityAll(cLocals), "identity commit and regeneration of every function are byte for byte");
			// The Get of a Local reads it by name; a Set writes it.
			doc.PushUndo();
			let set = NodeFactory.Set(run, "count", "int");
			set.FindInput("value").Default.Set("10");
			let first = run.ExecTarget(run.Entry.Then);
			run.Connect(run.Entry.Then, set.ExecIn);
			run.Connect(set.Then, first.ExecIn);
			Check(doc.Commit(doc.FindMethod("Counter.Run(int)")) && doc.Text.Contains("\t\t\tfloat speed = 2.5f;\n\t\t\tcount = 10;\n\t\t\tcount = start + 1;"),
				"a Set of a Local after Entry is written after the Locals");
			doc.Undo();
			Check(doc.Text == cLocals, "undo restores the text");
		}

		static void TestEdits()
		{
			Console.WriteLine("locals: add, rename, retype, reorder, remove, move");
			SourceDocument doc = scope .();
			doc.LoadFromText(cLocals, "Counter.bf");
			var mg = doc.FindMethod("Counter.Run(int)");
			let g = mg.Graph;
			doc.PushUndo();
			let added = NodeFactory.AddLocal(g, "steps", "int", "0");
			Check(g.Locals.Count == 4 && g.Locals[3] == added && !g.Nodes.Contains(added), "AddLocal: last of the Locals, not a node of the Sheet");
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tfloat speed = 2.5f;\n\t\t\tint steps = 0;\n\t\t\tcount = start + 1;"), "written after the other Locals: `int steps = 0;`");
			Check(g.Locals.Count == 4 && g.Locals[3].Text == "steps" && !g.Locals[3].Edited, "read back as the fourth Local, clean");
			String afterAdd = scope .(doc.Text);
			{
				SourceDocument d2 = scope .();
				d2.LoadFromText(afterAdd, "Counter.bf");
				Check(d2.FindMethod("Counter.Run(int)").Graph.Locals.Count == 4, "a fresh read has the same four Locals");
			}
			doc.PushUndo();
			g.Locals[3].Text.Set("stepCount");
			g.Locals[3].Edited = true;
			Check(doc.Commit(doc.FindMethod("Counter.Run(int)")) && doc.Text.Contains("\t\t\tint stepCount = 0;\n"), "renamed (no uses): `int stepCount = 0;`");
			doc.PushUndo();
			g.Locals[3].Text2.Set("int64");
			g.Locals[3].Edited = true;
			Check(doc.Commit(doc.FindMethod("Counter.Run(int)")) && doc.Text.Contains("\t\t\tint64 stepCount = 0;\n"), "type changed: `int64 stepCount = 0;`");
			doc.PushUndo();
			let a = g.Locals[0];
			g.Locals[0] = g.Locals[1];
			g.Locals[1] = a;
			g.Locals[0].Moved = g.Locals[1].Moved = true;
			g.Locals[0].Edited = g.Locals[1].Edited = true;
			Check(doc.Commit(doc.FindMethod("Counter.Run(int)")) && doc.Text.Contains("\t\t\t// how many\n\t\t\tString name = scope .();\n\t\t\tint count = 0;\n") || doc.Text.Contains("\t\t\tString name = scope .();\n\t\t\t// how many\n\t\t\tint count = 0;\n"),
				"reordered: name before count (the comment goes with its declaration)");
			doc.PushUndo();
			let gone = g.Locals.PopBack();
			delete gone;
			Check(doc.Commit(doc.FindMethod("Counter.Run(int)")) && !doc.Text.Contains("stepCount"), "removed: the declaration is gone");
			doc.Undo();
			doc.Undo();
			doc.Undo();
			doc.Undo();
			Check(doc.Text == afterAdd, "four undos: back to the text after the add");
			doc.Undo();
			Check(doc.Text == cLocals, "and the add undone");

			// Move to Locals: the declaration in the middle moves to the top, only when asked.
			mg = doc.FindMethod("Counter.Run(int)");
			let g2 = mg.Graph;
			doc.PushUndo();
			let later = FindNode(g2, .LocalVar, "later");
			Check(g2.MoveToLocals(later) && g2.Locals.Count == 4 && !g2.Nodes.Contains(later), "Move to Locals: `later` is the fourth Local");
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tfloat speed = 2.5f;\n\t\t\tint later = count * 2;\n\t\t\tcount = start + 1;\n\t\t\tConsole.WriteLine(count);\n\t\t\tmTotal = later;"),
				"written at the top, the statements around it joined");
			doc.Undo();
			Check(doc.Text == cLocals, "undo puts it back in the middle");
		}

		const String cOutputs =
			"""
			namespace Mod
			{
				class Store
				{
					public bool TryGet(int key, out int value, out String name)
					{
						if (key < 0)
						{
							value = 0;
							name = null;
							return false;
						}
						value = key * 2;
						// the name
						name = "found";
						return true;
					}

					public void Fill(out int a, out int b)
					{
						b = 2;
						a = 1;
						return;
					}

					public void Use()
					{
						if (TryGet(3, var v, var n))
						{
							Console.WriteLine(n);
						}
					}
				}
			}

			""";

		static void TestOutputs()
		{
			Console.WriteLine("outputs: out parameters on the Return node");
			SourceDocument doc = scope .();
			doc.LoadFromText(cOutputs, "Store.bf");
			let mg = doc.FindMethod("Store.TryGet(int,int,String)");
			let g = mg?.Graph;
			Check(g != null, "TryGet has a graph");
			if (g == null)
				return;
			int returns = 0;
			bool pinsOk = true;
			for (let n in g.Nodes)
			{
				if (n.Kind != .Return)
					continue;
				returns++;
				let pv = n.FindInput("out:value");
				let pn = n.FindInput("out:name");
				if (pv == null || pn == null || pv.Label != "value" || pv.TypeName != "int" || pn.TypeName != "String")
					pinsOk = false;
			}
			Check(returns == 2 && pinsOk, "both Returns have an input per output (value: int, name: String)");
			Check(CountKind(g, .Set) == 0, "the assignments right before each return are part of the Return (no Set nodes)");
			Node second = null;
			for (let n in g.Nodes)
				if (n.Kind == .Return && n.FindInput("value").Default == "true")
					second = n;
			Check(second != null && second.FindInput("out:name").Default == "\"found\"" && g.DataSource(second.FindInput("out:value")) != null,
				"the second Return: name = \"found\", value wired from key * 2");
			let fill = doc.FindMethod("Store.Fill(int,int)").Graph;
			let fillRet = FindNode(fill, .Return);
			Check(fillRet != null && fillRet.FindInput("out:a").Default == "1" && fillRet.FindInput("out:b").Default.IsEmpty && CountKind(fill, .Set) == 1,
				"`b = 2; a = 1; return;`: only the assignments in parameter order fold (a), b stays a Set");
			let use = doc.FindMethod("Store.Use()").Graph;
			Node call = null;
			for (let n in use.Nodes)
				if (n.Kind == .Call && n.Text == "TryGet")
					call = n;
			int outPins = 0;
			if (call != null)
				for (let p in call.Outputs)
					if (p.IsOutArg)
						outPins++;
			Check(outPins == 2, scope $"a call of TryGet has one output pin per output ({outPins})");
			Check(IdentityAll(cOutputs), "identity commit and regeneration of every function are byte for byte");

			// An edited Return writes the assignments then the return.
			doc.PushUndo();
			second.FindInput("out:name").Default.Set("\"other\"");
			second.Edited = true;
			Check(doc.Commit(doc.FindMethod("Store.TryGet(int,int,String)")) && doc.Text.Contains("\t\t\tvalue = key * 2;\n\t\t\tname = \"other\";\n\t\t\treturn true;"),
				"edited: `value = key * 2; name = \"other\"; return true;` (one line each)");
			{
				SourceDocument d2 = scope .();
				d2.LoadFromText(doc.Text, "Store.bf");
				let g2 = d2.FindMethod("Store.TryGet(int,int,String)").Graph;
				Check(CountKind(g2, .Return) == 2 && CountKind(g2, .Set) == 0, "read back: still two Returns and no Set");
			}
			doc.Undo();
			Check(doc.Text == cOutputs, "undo");

			// A Return placed in a function with outputs starts with each output's default.
			SourceDocument fresh = scope .();
			fresh.LoadFromText("namespace Mod\n{\n\tclass Box\n\t{\n\t\tpublic bool TryGet(out int value, out String name)\n\t\t{\n\t\t}\n\t}\n}\n", "Box.bf");
			let fmg = fresh.FindMethod("Box.TryGet(int,String)");
			let fg = fmg.Graph;
			fresh.PushUndo();
			let ret = NodeFactory.Return(fg, "bool");
			NodeFactory.AddReturnOutPins(fg, ret, fmg.Method, true);
			fg.Connect(fg.Entry.Then, ret.ExecIn);
			Check(fresh.Commit(fmg), "a placed Return commits");
			CheckText(fresh.Text, "namespace Mod\n{\n\tclass Box\n\t{\n\t\tpublic bool TryGet(out int value, out String name)\n\t\t{\n\t\t\tvalue = 0;\n\t\t\tname = null;\n\t\t\treturn false;\n\t\t}\n\t}\n}\n",
				"written: `value = 0; name = null; return false;`");
			let fg2 = fresh.FindMethod("Box.TryGet(int,String)").Graph;
			Check(CountKind(fg2, .Return) == 1 && CountKind(fg2, .Set) == 0, "read back as one Return");

			// Outputs added through the signature: the Return gets the new pin.
			fresh.PushUndo();
			Check(fresh.SetSignature(fresh.FindMethod("Box.TryGet(int,String)").Method, "bool", "out int value, out String name, out float weight"), "an output added (out float weight)");
			let fg3 = fresh.FindMethod("Box.TryGet(int,String,float)")?.Graph;
			let r3 = (fg3 != null) ? FindNode(fg3, .Return) : null;
			Check(r3 != null && r3.FindInput("out:weight") != null && r3.FindInput("out:weight").TypeName == "float", "the Return has a weight input");
			CheckHas(true, fresh.Text, "\t\t\tvalue = 0;\n\t\t\tname = null;\n\t\t\tweight = 0;\n\t\t\treturn false;", "...written with its default in the same step: `weight = 0;`");
			fresh.Undo();
			Check(fresh.Text.Contains("TryGet(out int value, out String name)\n\t\t{\n\t\t\tvalue = 0;\n\t\t\tname = null;\n\t\t\treturn false;"), "one undo removes the output and its assignment");
			Check(fresh.LastSignatureKey == "Box.TryGet(int,String,float)", "SetSignature names the function's new key (the Sheet follows it)");
		}

		/// Two overloads: the signature change of one keeps its key, never the other's.
		static void TestSignatureKey()
		{
			Console.WriteLine("inputs: a signature change names the same function");
			SourceDocument doc = scope .();
			doc.LoadFromText("namespace Mod\n{\n\tclass A\n\t{\n\t\tpublic void Go()\n\t\t{\n\t\t}\n\n\t\tpublic void Go(int a)\n\t\t{\n\t\t}\n\t}\n}\n", "A.bf");
			let m = doc.FindMethod("A.Go(int)").Method;
			Check(doc.SetSignature(m, "void", "int a, int newParam") && doc.LastSignatureKey == "A.Go(int,int)", "Add Input on the second Go: its new key A.Go(int,int)");
			let first = doc.FindMethod("A.Go()").Method;
			Check(doc.SetSignature(first, "void", "float x") && doc.LastSignatureKey == "A.Go(float)" && doc.FindMethod("A.Go(int,int)") != null, "the first Go changed: A.Go(float); the other is untouched");
		}

		/// Make variable from a pin: the member variable, then a Set fed by the pin; one undo step.
		static void TestPinVariable()
		{
			Console.WriteLine("variables made from a pin");
			const String text = "namespace Mod\n{\n\tclass Hero\n\t{\n\t\tpublic int Damage()\n\t\t{\n\t\t\treturn 3;\n\t\t}\n\n\t\tpublic void Hit()\n\t\t{\n\t\t\tDamage();\n\t\t}\n\t}\n}\n";
			SourceDocument doc = scope .();
			doc.LoadFromText(text, "Hero.bf");
			var mg = doc.FindMethod("Hero.Hit()");
			let g = mg.Graph;
			let call = FindNode(g, .Call, "Damage");
			let pinId = (call?.Result != null) ? call.Result.Id : 0;
			Check(pinId != 0 && call.Result.TypeName == "int", "the call's result pin is an int");
			// What the pin menu does: the member (its own edit), then the nodes in the same step.
			Check(doc.AddField(mg.Owner, "int", "mDamage", ""), "member variable mDamage added with the pin's type");
			mg = doc.FindMethod("Hero.Hit()");
			Check(mg.Graph == g, "the Sheet's graph is kept (its text did not change)");
			doc.PushUndo();
			doc.DropLastUndo();
			let pin = g.FindPin(pinId);
			let set = NodeFactory.Set(g, "mDamage", "int");
			g.Connect(pin, set.FindInput("value"));
			let next = g.ExecTarget(call.Then);
			g.Connect(call.Then, set.ExecIn);
			if (next != null)
				g.Connect(set.Then, next.ExecIn);
			Check(doc.Commit(mg), "the Set commits");
			CheckHas(doc.Text.Contains("mDamage;"), doc.Text, "\t\t\tlet damageResult = Damage();\n\t\t\tmDamage = damageResult;\n", "written: the member and `mDamage = Damage();` (the call spliced into the Set)");
			doc.Undo();
			Check(doc.Text == text, "one undo removes both");

			// Make local variable: a Local and the Set, one step.
			SourceDocument d2 = scope .();
			d2.LoadFromText(text, "Hero.bf");
			let mg2 = d2.FindMethod("Hero.Hit()");
			let g2 = mg2.Graph;
			let call2 = FindNode(g2, .Call, "Damage");
			d2.PushUndo();
			NodeFactory.AddLocal(g2, "damage", "int", "0");
			let set2 = NodeFactory.Set(g2, "damage", "int");
			g2.Connect(call2.Result, set2.FindInput("value"));
			g2.Connect(call2.Then, set2.ExecIn);
			CheckHas(d2.Commit(mg2), d2.Text, "\t\tpublic void Hit()\n\t\t{\n\t\t\tint damage = 0;\n\t\t\tlet damageResult = Damage();\n\t\t\tdamage = damageResult;\n\t\t}", "Make local variable: `int damage = 0; damage = Damage();`");
			d2.Undo();
			Check(d2.Text == text, "one undo");
		}

		public static void RunClasses()
		{
			TestRead();
			TestEdits();
			TestOutputs();
			TestSignatureKey();
			TestPinVariable();
		}

		/// `flow`: a Set placed after a statement is spliced into the flow (the statement's next one
		/// follows the Set), and a Set placed after Entry comes after the Locals.
		public static void RunFlow()
		{
			Console.WriteLine("locals: flow splice");
			const String text = "namespace Mod\n{\n\tclass Hero\n\t{\n\t\tpublic int Damage()\n\t\t{\n\t\t\treturn 3;\n\t\t}\n\n\t\tpublic void Hit()\n\t\t{\n\t\t\tint total = 1;\n\t\t\tDamage();\n\t\t\tConsole.WriteLine(total);\n\t\t}\n\t}\n}\n";
			SourceDocument doc = scope .();
			doc.LoadFromText(text, "Hero.bf");
			let mg = doc.FindMethod("Hero.Hit()");
			let g = mg.Graph;
			let call = FindNode(g, .Call, "Damage");
			Check(g.ExecTarget(g.Entry.Then) == call, "Entry leads to the first statement after the Locals");
			doc.PushUndo();
			let set = NodeFactory.Set(g, "total", "int");
			g.Connect(call.Result, set.FindInput("value"));
			let next = g.ExecTarget(call.Then);
			g.Connect(call.Then, set.ExecIn);
			g.Connect(set.Then, next.ExecIn);
			CheckHas(doc.Commit(mg), doc.Text, "\t\t\tint total = 1;\n\t\t\tlet damageResult = Damage();\n\t\t\ttotal = damageResult;\n\t\t\tConsole.WriteLine(total);\n", "spliced: `total = Damage();` between the Local and the print");
			doc.Undo();
			Check(doc.Text == text, "undo");
		}
	}
}
