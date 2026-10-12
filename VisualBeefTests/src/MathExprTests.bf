using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Math Expression nodes (docs/Math-Expression.md) and the Expression initial value
	/// (docs/Classes-and-Members.md > Ownership and initial values). RunNode is part of `calls`
	/// (and so of `flow` and `edits`): reading, pins, types, the node, the code and the checks.
	/// RunRoundTrip is part of `classes`: the side file's `#math` records, orphans, undo, code
	/// without a record. RunInit is part of `textforms`: Initial Value set to Expression.
	static class MathExprTests
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

		static void CheckHas(StringView text, StringView want, StringView what)
		{
			bool ok = text.Contains(want);
			Check(ok, what);
			if (!ok)
				Console.WriteLine("  --- wanted:\n{}\n  --- text:\n{}", want, text);
		}

		static String Pins(StringView text)
		{
			String o = new .();
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			String why = scope .();
			if (!MathExpression.PinNames(text, names, why))
			{
				o.AppendF("refused: {}", why);
				return o;
			}
			for (let n in names)
				o.AppendF("{}{}", (@n.Index > 0) ? "," : "", n);
			return o;
		}

		static String Infer(StringView text, params StringView[] pinTypes)
		{
			let p = MathExpression.Parse(text);
			defer delete p;
			String o = new .();
			Dictionary<String, String> types = scope .();
			defer { for (let kv in types) { delete kv.key; delete kv.value; } }
			for (int i = 0; i + 1 < pinTypes.Count; i += 2)
				types[new String(pinTypes[i])] = new String(pinTypes[i + 1]);
			if (!MathExpression.InferType(p, scope (pin, t) =>
				{
					if (types.TryGetValueAlt(pin, let v))
						t.Set(v);
					return !t.IsEmpty;
				}, o))
				o.Set("?");
			return o;
		}

		static Node Find(Graph g, NodeKind kind, StringView text = "")
		{
			for (let n in g.Nodes)
				if (n.Kind == kind && (text.IsEmpty || n.Text == text))
					return n;
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

		static Pin Param(Graph g, StringView name)
		{
			for (let p in g.Entry.Outputs)
				if (p.Kind == .Data && p.Label == name)
					return p;
			return null;
		}

		const String cSource =
			"""
			using System;

			namespace MathDemo
			{
				class Shapes
				{
					static int Twice(int v) => v * 2;

					public static float Length(int x, float y, float scale)
					{
						return 0;
					}

					public static int Square(int x, int y)
					{
						return 0;
					}

					public static void Check(int a, int b, bool flag)
					{
						Console.WriteLine("start");
					}

					public static double Root(int n)
					{
						return 0;
					}
				}
			}

			""";

		/// A Math Expression wired from the parameters into the Return of `key`.
		static Node MathIntoReturn(SourceDocument doc, StringView key, StringView expression)
		{
			let mg = doc.FindMethod(key);
			let g = mg.Graph;
			let ret = Find(g, .Return);
			let m = NodeFactory.MathExpr(g, expression);
			for (let pin in m.Inputs)
			{
				let src = Param(g, pin.Name);
				if (src != null)
					g.Connect(src, pin);
			}
			// The literal `0` read from `return 0;` is the pin's typed value: the wire replaces it.
			g.Connect(m.Result, ret.FindInput("value"));
			return m;
		}

		// ------------------------------------------------------------------ the node (calls)

		public static void RunNode()
		{
			Console.WriteLine("Math Expression: reading, pins, types, code");

			// Pins: every free name once, in the order it first appears.
			StringView[?] texts = .("a * a + b", "Math.Sqrt(x * x + y * y) * scale", "Twice(v) + 1", "(float)n / 2", "p.X + p.Y * p.X",
				"Math.PI_f * r * r", "a > b && flag", "cond ? hi : lo", "int.MaxValue - n", "1 + 2");
			StringView[?] wants = .("a,b", "x,y,scale", "v", "n", "p", "r", "a,b,flag", "cond,hi,lo", "n", "");
			for (int i < texts.Count)
			{
				let got = Pins(texts[i]);
				defer delete got;
				Check(got == wants[i], scope $"pins of `{texts[i]}`: {wants[i]} (got {got})");
			}

			// Refused: what is not one Beef expression that gives a value.
			for (let c in StringView[?]("a +", "x = 5", "i++", "new .()", "", "a; b", "this.x + 1", "(.)a", "() => 1"))
			{
				String why = scope .();
				Check(!MathExpression.Check(c, why) && !why.IsEmpty, scope $"refused: `{c}` ({why})");
			}

			// Result types where Beef's rules make them certain.
			{
				String t;
				t = Infer("Math.Sqrt(x * x + y * y) * scale", "x", "int", "y", "float", "scale", "float");
				Check(t == "float", scope $"type: Math.Sqrt over int and float, times a float is float (got {t})");
				delete t;
				t = Infer("a + b * 2", "a", "int", "b", "int");
				Check(t == "int", scope $"type: int arithmetic is int (got {t})");
				delete t;
				t = Infer("a + b", "a", "int", "b", "double");
				Check(t == "double", scope $"type: int + double is double (got {t})");
				delete t;
				t = Infer("a > b", "a", "float", "b", "int");
				Check(t == "bool", scope $"type: a comparison is bool (got {t})");
				delete t;
				t = Infer("Math.Sqrt(n)", "n", "int");
				Check(t == "?", scope $"type: Math.Sqrt of an int can't be told (float or double version) (got {t})");
				delete t;
				t = Infer("(double)n / 3", "n", "int");
				Check(t == "double", scope $"type: a cast gives its type (got {t})");
				delete t;
				t = Infer("Math.Min(a, b)", "a", "int", "b", "int");
				Check(t == "int", scope $"type: Math.Min of ints is int (got {t})");
				delete t;
				t = Infer("Math.PI_f * 2", "", "");
				Check(t == "float", scope $"type: Math.PI_f is float (got {t})");
				delete t;
				t = Infer("a / b", "a", "int8", "b", "int8");
				Check(t == "?", scope $"type: small integer arithmetic is left to the choice (got {t})");
				delete t;
				t = Infer("a * b", "a", "int32", "b", "int");
				Check(t == "int", scope $"type: int32 with the wider int is int (got {t})");
				delete t;
				t = Infer("a + b");
				Check(t == "?", scope $"type: inputs without a type give no type (got {t})");
				delete t;
			}

			// The node: pins follow the text; wires and values stay with their names.
			{
				Graph g = scope .();
				let m = NodeFactory.MathExpr(g, "a * a + b");
				Check(m.Kind == .MathExpr && m.IsPure && m.Inputs.Count == 2 && m.Inputs[0].Name == "a" && m.Inputs[1].Name == "b" && m.Result != null,
					"new node: one input per name (a twice is one pin), a Result output");
				Node v = NodeFactory.Get(g, "speed", "float");
				g.Connect(v.Result, m.FindInput("a"));
				m.FindInput("b").Default.Set("1.5f");
				MathExpression.Sync(g, m);
				Check(m.Result.TypeName == "float" && m.FindInput("a").TypeName == "float" && m.FindInput("b").TypeName == "float",
					scope $"pin types from the wire and the typed value; the result type follows (got {m.Result.TypeName})");
				m.Text.Set("c + a");
				Check(NodeFactory.SyncMath(g, m), "the text changed: synced");
				Check(m.Inputs.Count == 2 && m.Inputs[0].Name == "c" && m.Inputs[1].Name == "a" && g.FindLinkTo(m.FindInput("a")) != null && m.FindInput("b") == null,
					"a pin no longer named goes, a new name gets a pin, `a` keeps its wire, in the order they appear");
				m.Text.Set("c + (");
				String why = scope .();
				Check(!NodeFactory.SyncMath(g, m, why) && m.Inputs.Count == 2 && !why.IsEmpty, scope $"a broken text keeps the pins ({why})");
				String problem = scope .();
				MathExpression.Problem(g, m, problem);
				Check(!problem.IsEmpty, scope $"the node says what is wrong: {problem}");
			}

			// The code: the expression with the values in place.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let m = MathIntoReturn(doc, "Shapes.Length(int,float,float)", "Math.Sqrt(x * x + y * y) * scale");
				doc.PushUndo();
				bool ok = doc.Commit(doc.FindMethod("Shapes.Length(int,float,float)"));
				CheckHas(doc.Text, "\t\t\treturn Math.Sqrt(x * x + y * y) * scale;\n", "code: the expression with the parameters in place");
				Check(ok && m.Result.TypeName == "float", scope $"committed; the Result is float (got {m.Result.TypeName})");
				doc.Undo();
				Check(doc.Text == cSource, "undo restores the code");
			}
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let key = "Shapes.Square(int,int)";
				let m = MathIntoReturn(doc, key, "a * a + b");
				let g = doc.FindMethod(key).Graph;
				let sum = NodeFactory.Operator(g, "+", true);
				g.Connect(Param(g, "x"), sum.FindInput("a"));
				sum.FindInput("b").Default.Set("1");
				g.Connect(sum.Result, m.FindInput("a"));
				g.Connect(Param(g, "y"), m.FindInput("b"));
				bool ok = doc.Commit(doc.FindMethod(key));
				CheckHas(doc.Text, "\t\t\treturn (x + 1) * (x + 1) + y;\n", "code: a value that is an operation is put in parentheses, once per use");
				Check(ok, "committed");
			}
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let key = "Shapes.Square(int,int)";
				let m = MathIntoReturn(doc, key, "a * a");
				let g = doc.FindMethod(key).Graph;
				StringView[1] pn = .("v");
				StringView[1] pt = .("int");
				let twice = NodeFactory.Call(g, "Twice", false, false, "", pn, pt, "int");
				g.Connect(Param(g, "x"), twice.FindInput("arg0"));
				g.Connect(twice.Result, m.FindInput("a"));
				bool ok = doc.Commit(doc.FindMethod(key));
				Check(ok && doc.Text.Contains("Twice(x);") && doc.Text.Contains(" * __v") && !doc.Text.Contains("Twice(x) * Twice(x)"),
					"code: a call read by a name used twice runs once (kept in a variable)");
				if (!(ok && doc.Text.Contains(" * __v")))
					Console.WriteLine(doc.Text);
			}
			{
				// Into a Branch: `if (a > b && flag)`.
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let key = "Shapes.Check(int,int,bool)";
				let mg = doc.FindMethod(key);
				let g = mg.Graph;
				let first = g.ExecTarget(g.Entry.Then);
				let br = NodeFactory.Branch(g);
				let m = NodeFactory.MathExpr(g, "a > b && flag");
				for (let pin in m.Inputs)
					g.Connect(Param(g, pin.Name), pin);
				g.Connect(m.Result, br.FindInput("condition"));
				g.Connect(g.Entry.Then, br.ExecIn);
				g.Connect(br.FindOutput("true"), first.ExecIn);
				bool ok = doc.Commit(mg);
				CheckHas(doc.Text, "\t\t\tif (a > b && flag)\n", "code: a Math Expression as a Branch condition");
				Check(ok && m.Result.TypeName == "bool", "the condition is bool");
			}

			// Checks: nothing is written for a node that can't be read or misses a value.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let key = "Shapes.Square(int,int)";
				let m = MathIntoReturn(doc, key, "x * y + z");
				let g = doc.FindMethod(key).Graph;
				bool ok = doc.Commit(doc.FindMethod(key));
				bool said = false;
				for (let e in g.Errors)
					if (e.NodeId == m.Id && e.Message.Contains("'z' needs a value"))
						said = true;
				Check(!ok && said && doc.Text == cSource, "an input without a wire or a value: an error on the node, nothing written");
				m.FindInput("z").Default.Set("3");
				m.Edited = true;
				ok = doc.Commit(doc.FindMethod(key));
				CheckHas(doc.Text, "\t\t\treturn x * y + 3;\n", "a typed value is written in place");
			}
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				let key = "Shapes.Root(int)";
				let m = MathIntoReturn(doc, key, "Math.Sqrt(n)");
				let g = doc.FindMethod(key).Graph;
				bool ok = doc.Commit(doc.FindMethod(key));
				bool said = false;
				for (let e in g.Errors)
					if (e.NodeId == m.Id && e.Message.Contains("Result Type"))
						said = true;
				Check(!ok && said, "a result type that can't be told: the node asks for it, nothing written");
				Graph.CopyStr(ref m.MathType, "double");
				m.Edited = true;
				ok = doc.Commit(doc.FindMethod(key));
				Check(ok && m.Result.TypeName == "double" && doc.Text.Contains("\t\t\treturn Math.Sqrt(n);\n"), "the chosen type: written, the Result has it");
			}
		}

		// ------------------------------------------------------------------ side file (classes)

		public static void RunRoundTrip()
		{
			Console.WriteLine("Math Expression: side file round trip");
			String code = scope .();
			String layout = scope .();
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cSource, "Shapes.bf");
				MathIntoReturn(doc, "Shapes.Length(int,float,float)", "Math.Sqrt(x * x + y * y) * scale");
				Check(doc.Commit(doc.FindMethod("Shapes.Length(int,float,float)")), "committed");
				let key = "Shapes.Square(int,int)";
				let m = MathIntoReturn(doc, key, "a * a + b");
				let g = doc.FindMethod(key).Graph;
				let sum = NodeFactory.Operator(g, "+", true);
				g.Connect(Param(g, "x"), sum.FindInput("a"));
				sum.FindInput("b").Default.Set("1");
				g.Connect(sum.Result, m.FindInput("a"));
				g.Connect(Param(g, "y"), m.FindInput("b"));
				Check(doc.Commit(doc.FindMethod(key)), "committed");
				// An unconnected Math Expression (an orphan) with typed values.
				let lone = NodeFactory.MathExpr(g, "p - q / 2");
				lone.FindInput("p").Default.Set("10");
				lone.FindInput("q").Default.Set("4");
				lone.X = 400;
				lone.Y = 300;
				lone.HasPos = true;
				doc.LayoutTouched = true;
				// A chosen result type.
				let r = MathIntoReturn(doc, "Shapes.Root(int)", "Math.Sqrt(n)");
				Graph.CopyStr(ref r.MathType, "double");
				Check(doc.Commit(doc.FindMethod("Shapes.Root(int)")), "committed");
				code.Set(doc.Text);
				doc.GetLayoutText(layout);
			}
			CheckHas(layout, "\tMath.Sqrt(x * x + y * y) * scale\n", "the side file has a #math record of the expression");
			CheckHas(layout, "#math\tShapes.Root(int)\t", "a record per function");
			CheckHas(layout, "\tdouble\tMath.Sqrt(n)\n", "the chosen result type is in the record");
			CheckHas(layout, "#orphanmath\t", "an unconnected Math Expression has its own record");
			CheckHas(code, "\t\t\treturn (x + 1) * (x + 1) + y;\n", "the code is the plain expression");

			// Read back with the side file: the nodes come back.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(code, "Shapes.bf", layout);
				let g = doc.FindMethod("Shapes.Length(int,float,float)").Graph;
				let m = Find(g, .MathExpr);
				Check(m != null && m.Text == "Math.Sqrt(x * x + y * y) * scale", "reload: the Math Expression is back with its text");
				if (m != null)
				{
					bool wired = true;
					for (let pin in m.Inputs)
						if (g.FindLinkTo(pin) == null)
							wired = false;
					Check(m.Inputs.Count == 3 && wired, "reload: its three inputs are wired to what the code reads");
					let ret = Find(g, .Return);
					Check(ret != null && g.DataSource(ret.FindInput("value")) == m, "reload: its Result feeds the Return");
					Check(Count(g, .Operator) == 0, "reload: no operator nodes are left over from the code");
				}
				let g2 = doc.FindMethod("Shapes.Square(int,int)").Graph;
				let m2 = Find(g2, .MathExpr, "a * a + b");
				Check(m2 != null && m2.Inputs.Count == 2, "reload: `a * a + b` from `(x + 1) * (x + 1) + y` (one pin for both uses)");
				let lone = Find(g2, .MathExpr, "p - q / 2");
				Check(lone != null && lone.FindInput("p")?.Default == "10" && lone.FindInput("q")?.Default == "4" && lone.X == 400,
					"reload: the unconnected Math Expression is back with its values and place");
				let g3 = doc.FindMethod("Shapes.Root(int)").Graph;
				let m3 = Find(g3, .MathExpr);
				Check(m3 != null && m3.MathType == "double" && m3.Result.TypeName == "double", "reload: the chosen result type is back");
				// Committing the reloaded graphs writes the same code.
				for (let key in StringView[?]("Shapes.Length(int,float,float)", "Shapes.Square(int,int)", "Shapes.Root(int)"))
				{
					bool ok = doc.Commit(doc.FindMethod(key));
					Check(ok && doc.Text == code, scope $"{key}: identity commit byte for byte");
					for (let n in doc.FindMethod(key).Graph.Nodes)
						n.Edited = true;
					ok = doc.Commit(doc.FindMethod(key));
					Check(ok && doc.Text == code, scope $"{key}: every node regenerated, byte for byte");
					if (doc.Text != code)
						Program.ShowDiff(code, doc.Text);
				}
				String layout2 = scope .();
				doc.GetLayoutText(layout2);
				Check(layout2.Contains("\tMath.Sqrt(x * x + y * y) * scale\n") && layout2.Contains("#orphanmath\t"), "saved again: the records are written again");
			}

			// Without the side file the code is still plain Beef: a generic expression.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(code, "Shapes.bf");
				let g = doc.FindMethod("Shapes.Length(int,float,float)").Graph;
				Check(Count(g, .MathExpr) == 0, "no side file: no Math Expression, the code reads as usual");
				Check(doc.Commit(doc.FindMethod("Shapes.Length(int,float,float)")) && doc.Text == code, "no side file: identity commit");
			}

			// The code changed in a text editor: a record that does not match any more is ignored.
			{
				String edited = scope .(code);
				edited.Replace("* scale;", "/ scale;");
				SourceDocument doc = scope .();
				doc.LoadFromText(edited, "Shapes.bf", layout);
				let g = doc.FindMethod("Shapes.Length(int,float,float)").Graph;
				Check(Count(g, .MathExpr) == 0, "the code no longer is the expression: read as usual");
				let g2 = doc.FindMethod("Shapes.Square(int,int)").Graph;
				Check(Find(g2, .MathExpr, "a * a + b") != null, "the other records still apply");
			}

			// A text edit elsewhere keeps the node; a text edit of its function rebuilds it from the record.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(code, "Shapes.bf", layout);
				let mg = doc.FindMethod("Shapes.Length(int,float,float)");
				Check(Find(mg.Graph, .MathExpr) != null, "before the text edit");
				String edited = scope .(code);
				edited.Replace("\t\t\treturn Math.Sqrt(x * x + y * y) * scale;\n", "\t\t\tConsole.WriteLine(\"len\");\n\t\t\treturn Math.Sqrt(x * x + y * y) * scale;\n");
				doc.ApplyText(edited);
				let g = doc.FindMethod("Shapes.Length(int,float,float)").Graph;
				Check(Count(g, .MathExpr) == 0, "a line added above it moves its place: the record no longer matches (read as usual)");
				doc.Undo();
				let g2 = doc.FindMethod("Shapes.Length(int,float,float)").Graph;
				Check(doc.Text == code && Find(g2, .MathExpr) != null, "undo: the Math Expression is back");
			}
		}

		// ------------------------------------------------------------------ initial values (textforms)

		const String cInit =
			"""
			namespace Demo
			{
				class Counter
				{
					int a = 1;
					int b = 2;
					int x = 0;
					float speed;

					void Run()
					{
						int y = 0;
					}
				}
			}

			""";

		static Member FindField(SourceDocument doc, StringView type, StringView name)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
			{
				if (t.Name != type || t.Members == null)
					continue;
				for (let m in t.Members)
					if (m.Name == name)
						return m;
			}
			return null;
		}

		static Member FindTypeMember(SourceDocument doc, StringView type)
		{
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == type)
					return t;
			return null;
		}

		public static void RunInit()
		{
			Console.WriteLine("Initial Value: Expression");
			SourceDocument doc = scope .();
			doc.LoadFromText(cInit, "Counter.bf");
			let field = FindField(doc, "Counter", "x");
			let t = MemberInit.TypeOf("int");
			MemberInit init = scope .();
			Check(field != null && doc.ReadMemberInit(field, t, init) && init.ValueKind == .Literal && init.Value == "0", "`int x = 0;` reads as Number 0");

			// The bug: Expression started as `default`, which reads back as default, so the chooser
			// jumped back. Now the choice is remembered and the expression starts with the value.
			{
				MemberInit before = scope .();
				before.ClassifyValue("default", t);
				Check(before.ValueKind == .Default, "`default` reads back as the default mode (why the choice has to be remembered)");
			}
			InitExpressionChoice choice = scope .();
			let key = "Counter.bf|Counter|x";
			MemberInit.StartValue(.Custom, t, init, null);
			choice.Choose(key);
			Check(init.ValueKind == .Custom && init.Value == "0", scope $"choosing Expression starts with the value there is now (got `{init.Value}`)");
			{
				MemberInit again = scope .();
				doc.ReadMemberInit(field, t, again);
				Check(again.ValueKind == .Literal && choice.Apply(key, again) && again.ValueKind == .Custom && again.Value == "0",
					"the next frame reads Number again; the remembered choice shows it as Expression");
				MemberInit other = scope .();
				doc.ReadMemberInit(FindField(doc, "Counter", "a"), t, other);
				Check(!choice.Apply("Counter.bf|Counter|a", other) && other.ValueKind == .Literal, "the choice is for that variable only");
			}

			// Typing `a + b` writes it, and it reads back as an Expression.
			String text = scope .();
			String why = scope .();
			Check(MemberInit.CheckExpression("  a + b ", text, why) && text == "a + b", "`a + b` is a Beef expression");
			init.ValueKind = .Custom;
			init.Value.Set(text);
			Check(doc.SetMemberInit(field, init, "", FindTypeMember(doc, "Counter")), "written");
			CheckHas(doc.Text, "\t\tint x = a + b;\n", "the declaration becomes `int x = a + b;`");
			{
				SourceDocument doc2 = scope .();
				doc2.LoadFromText(doc.Text, "Counter.bf");
				MemberInit back = scope .();
				Check(doc2.ReadMemberInit(FindField(doc2, "Counter", "x"), t, back) && back.ValueKind == .Custom && back.Value == "a + b",
					"read again (a reload): Expression `a + b`");
			}

			// Back to Number.
			{
				let f = FindField(doc, "Counter", "x");
				MemberInit cur = scope .();
				doc.ReadMemberInit(f, t, cur);
				MemberInit.StartValue(.Literal, t, cur, null);
				choice.Forget();
				Check(doc.SetMemberInit(f, cur, "", FindTypeMember(doc, "Counter")), "switched back to Number: written");
				CheckHas(doc.Text, "\t\tint x = 0;\n", "the declaration is `int x = 0;` again");
				MemberInit back = scope .();
				doc.ReadMemberInit(FindField(doc, "Counter", "x"), t, back);
				Check(back.ValueKind == .Literal && !choice.Apply(key, back) && back.ValueKind == .Literal, "it reads as Number; no Expression is remembered");
			}

			// A variable without an initial value: Expression starts empty and nothing is written yet.
			{
				let f = FindField(doc, "Counter", "speed");
				let ft = MemberInit.TypeOf("float");
				MemberInit cur = scope .();
				doc.ReadMemberInit(f, ft, cur);
				MemberInit.StartValue(.Custom, ft, cur, null);
				Check(cur.ValueKind == .Custom && cur.Value.IsEmpty, "no value yet: the Expression box starts empty");
				String typedText = scope .();
				String typedWhy = scope .();
				Check(MemberInit.CheckExpression("", typedText, typedWhy) && typedText.IsEmpty, "an empty Expression is no initial value");
			}

			// Refused: not a Beef expression (the red frame; nothing is written).
			for (let bad in StringView[?]("a +", "a; b", "(a", "x = = 1"))
			{
				String o = scope .();
				String w = scope .();
				Check(!MemberInit.CheckExpression(bad, o, w) && w.Contains("not written"), scope $"refused: `{bad}` ({w})");
			}
			for (let good in StringView[?]("new .() { X = 1 }", "Math.Max(a, b) * 2", "(int)speed", ".Red", "\"text\""))
			{
				String o = scope .();
				String w = scope .();
				Check(MemberInit.CheckExpression(good, o, w), scope $"accepted: `{good}`");
			}

			// A Local Variable node: the same, written into its value.
			{
				let mg = doc.FindMethod("Counter.Run()");
				let g = mg.Graph;
				Node local = null;
				for (let l in g.Locals)
					if (l.Text == "y")
						local = l;
				if (local == null)
					local = Find(g, .LocalVar, "y");
				let valuePin = local?.FindInput("value");
				Check(valuePin != null, "the Local Variable y");
				if (valuePin != null)
				{
					MemberInit li = scope .();
					li.ClassifyValue(valuePin.Default, t);
					let localKey = scope $"local|{mg.Key}|{local.Id}";
					MemberInit.StartValue(.Custom, t, li, null);
					choice.Choose(localKey);
					MemberInit again = scope .();
					again.ClassifyValue(valuePin.Default, t);
					Check(choice.Apply(localKey, again) && again.ValueKind == .Custom && again.Value == "0", "a Local: Expression stays chosen over `0`");
					li.Value.Set("a + b");
					String v = scope .();
					li.ValueText(v);
					doc.PushUndo();
					valuePin.Default.Set(v);
					local.Edited = true;
					Check(doc.Commit(mg), "the Local's value written");
					CheckHas(doc.Text, "\t\t\tint y = a + b;\n", "the Local becomes `int y = a + b;`");
				}
			}
		}
	}
}
