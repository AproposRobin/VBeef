using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Parser error recovery, literal classification and layout-key stability.
	///   VisualBeefTests parser
	static class ParserTests
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

		public static int Run()
		{
			Console.WriteLine("Literal kinds");
			Literals_();
			Console.WriteLine("Error recovery");
			Recovery();
			Console.WriteLine("Layout keys");
			LayoutKeyTests();
			Console.WriteLine("Destructor clauses");
			DestructorClauses();
			Console.WriteLine("Type fields");
			TypeFields();
			Console.WriteLine("parser checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}

		// ------------------------------------------------------------------ declaration scan

		static int sDeclFiles;
		static int sDeclErrors;

		static void ScanMembers(List<Member> members, StringView file, CompilationUnit unit)
		{
			for (let m in members)
			{
				String msg = scope .();
				if (m.Kind != .Broken && m.HasSpan && m.GetDeclError(msg))
				{
					sDeclErrors++;
					Console.WriteLine("  {}:{}: {} {}", file, unit.LineOf(unit.Tokens[m.FirstTok].Start), m.Name, msg);
				}
				if (m.Members != null)
					ScanMembers(m.Members, file, unit);
			}
		}

		/// `decls <folders or files>`: every declaration error (not parse failures) the editor would show.
		public static int RunDecls(String[] args)
		{
			for (int i = 1; i < args.Count; i++)
				ScanPath(args[i]);
			Console.WriteLine("decls: files={} declaration errors={}", sDeclFiles, sDeclErrors);
			return 0;
		}

		static void ScanPath(StringView path)
		{
			if (System.IO.Directory.Exists(path))
			{
				for (let e in System.IO.Directory.EnumerateFiles(path, "*.bf"))
				{
					String p = scope .();
					e.GetFilePath(p);
					ScanPath(p);
				}
				for (let e in System.IO.Directory.EnumerateDirectories(path))
				{
					String p = scope .();
					e.GetFilePath(p);
					ScanPath(p);
				}
				return;
			}
			String text = scope .();
			if (System.IO.File.ReadAllText(path, text, true) case .Err)
				return;
			let unit = Parser.Parse(text);
			defer delete unit;
			sDeclFiles++;
			ScanMembers(unit.Members, path, unit);
		}

		// ------------------------------------------------------------------ type fields

		static bool Fits(StringView type, TypeSlot slot, StringView generics = "", bool inType = true, bool comptime = false, bool isEnum = false)
		{
			TypeScope sc = default;
			sc.Generics = generics;
			sc.GenericsKnown = true;
			sc.InType = inType;
			sc.Comptime = comptime;
			sc.IsEnum = isEnum;
			String why = scope .();
			return TypeSlotRules.Check(type, slot, sc, why);
		}

		static bool Says(StringView type, TypeSlot slot, StringView expect, StringView generics = "", bool inType = true)
		{
			TypeScope sc = default;
			sc.Generics = generics;
			sc.GenericsKnown = true;
			sc.InType = inType;
			String why = scope .();
			return !TypeSlotRules.Check(type, slot, sc, why) && why.Contains(expect);
		}

		static bool DeclErrorOf(StringView src, StringView member, String outMsg)
		{
			let unit = Parser.Parse(src);
			defer delete unit;
			List<Member> all = scope .();
			Collect(unit.Members, all);
			for (let m in all)
				if (m.Name == member)
					return m.GetDeclError(outMsg);
			return false;
		}

		static void Collect(List<Member> members, List<Member> outAll)
		{
			for (let m in members)
			{
				outAll.Add(m);
				if (m.Members != null)
					Collect(m.Members, outAll);
			}
		}

		static void TypeFields()
		{
			// Return Type
			Check(Fits("void", .Return) && Fits("int", .Return) && Fits("Self", .Return) && Fits("ref int", .Return) && Fits("void*", .Return), "Return Type: void, a type, Self, ref T, void* fit");
			Check(Says("var", .Return, "'var'") && Says("let", .Return, "'let'") && Says("void[]", .Return, "'void'") && Says("class", .Return, "keyword"), "Return Type: var, let, void[], a keyword are refused with the word named");
			Check(Fits("var", .Return, "", true, true) && !Fits("let", .Return, "", true, true), "Return Type: var only on a [Comptime] function");
			Check(Fits("T", .Return, "T") && Says("T", .Return, "generic parameter") && Fits("Result<void, String>", .Return), "Return Type: T only when declared; Result<void, E> fits");
			Check(Says("Self", .Return, "no type", "", false), "Return Type: Self outside a type is refused");
			Check(Fits("SizedArray<int, 4>", .Member) && Fits("Vec<float, 3>", .Return) && Fits("Grid<int, -1>", .Param), "constant generic arguments (SizedArray<int, 4>) fit");
			// Parameter
			Check(Fits("int", .Param) && Fits("void*", .Param) && Fits("List<T>", .Param, "T") && Fits("delegate void(int a)", .Param), "Parameter: types, void*, List<T>, a delegate fit");
			Check(Says("void", .Param, "'void'") && Says("var", .Param, "'var'") && Says("let", .Param, "'let'") && Says("ref int", .Param, "Modifier field"), "Parameter: void, var, let and a modifier inside the type are refused");
			String why = scope .();
			TypeScope sc = default;
			sc.InType = true;
			Check(TypeSlotRules.CheckParamList("int a, ref Foo b, params int[] rest", sc, why), "Parameter list: ref and a last params array fit");
			Check(!TypeSlotRules.CheckParamList("params int[] rest, int a", sc, why) && why.Contains("only the last"), "Parameter list: params before the last parameter is refused");
			Check(!TypeSlotRules.CheckParamList("params int a", sc, why) && why.Contains("array or a Span"), "Parameter list: params on a non-array is refused");
			Check(!TypeSlotRules.CheckParamList("void a", sc, why) && why.Contains("'void'"), "Parameter list: void a is refused");
			Check(!TypeSlotRules.CheckParamModifier("static", why) && TypeSlotRules.CheckParamModifier("out", why), "Parameter modifier: out fits, static does not");
			// Member variable
			Check(Fits("int", .Member) && Fits("List<int>", .Member) && Fits("int[4]", .Member) && Fits("Foo?", .Member) && Fits("(int a, String b)", .Member), "Member variable: types, containers, tuples fit");
			Check(Says("void", .Member, "'void'") && Says("var", .Member, "only for local variables") && Says("let", .Member, "'let'") && Says("List<var>", .Member, "'var'"), "Member variable: void, var, let, List<var> are refused");
			// Local variable and For Each
			Check(Fits("var", .Local) && Fits("let", .Local) && Fits("int", .Local) && Fits("var", .ForEach) && Fits("let", .ForEach), "Local / For Each: var, let and types fit");
			Check(Says("void", .Local, "'void'") && Says("List<var>", .Local, "'var'") && Says("var[]", .Local, "'var'") && Says("void", .ForEach, "'void'"), "Local / For Each: void, List<var>, var[] are refused");
			// Cast, Construct
			Check(Fits("float", .Cast) && Fits("void*", .Cast) && Says("var", .Cast, "'var'") && Says("void", .Cast, "'void'"), "Cast To: a type or void*; var and void are refused");
			Check(Fits("List<int>", .Construct) && Says("var", .Construct, "'var'") && Says("void", .Construct, "'void'"), "Construct: a type fits; var and void are refused");
			// Base types
			Check(Fits("Foo", .Base) && Fits("IDisposable", .Base) && Fits("Base<T>", .Base, "T"), "Base type: a class or interface name (with arguments) fits");
			Check(Says("int", .Base, "only an enum or a struct") && Says("Self", .Base, "base list") && Says("Foo[]", .Base, "plain") && Says("void", .Base, "'void'"), "Base type: a basic type, Self, an array are refused");
			Check(Fits("int32", .Base, "", true, false, true) && !Fits("String", .Base, "", true, false, true), "Enum base: an integer fits, a class does not");
			// Generic parameter lists
			Check(TypeSlotRules.CheckGenericList("T, U", why) && TypeSlotRules.CheckGenericList("", why) && TypeSlotRules.CheckGenericList("T, const int N", why), "Generic list: T, U / empty / const int N fit");
			Check(!TypeSlotRules.CheckGenericList("T, T", why) && why.Contains("twice") && !TypeSlotRules.CheckGenericList("int", why) && !TypeSlotRules.CheckGenericList("T,", why) && !TypeSlotRules.CheckGenericList("var", why), "Generic list: a duplicate, a basic type, an empty entry, var are refused");

			// Declarations read from a file edited by hand.
			String msg = scope .();
			Check(DeclErrorOf("class C { public void F() { } }", "F", msg) == false, "decl: void F() has no error");
			msg.Clear();
			Check(DeclErrorOf("class C { public void F(void x) { } }", "F", msg) && msg.Contains("Parameter 'x'") && msg.Contains("'void'"), "decl: a void parameter is a declaration error");
			msg.Clear();
			Check(DeclErrorOf("class C { public void F(var x) { } }", "F", msg) && msg.Contains("'var'"), "decl: a var parameter is a declaration error");
			msg.Clear();
			Check(!DeclErrorOf("class C { public static mixin M(var x) { } }", "M", msg), "decl: a mixin may have var parameters");
			msg.Clear();
			Check(DeclErrorOf("class C { public void F(params int[] a, int b) { } }", "F", msg) && msg.Contains("last parameter"), "decl: params before the last parameter");
			msg.Clear();
			Check(DeclErrorOf("class C { public void mV = default; }", "mV", msg) && msg.Contains("Variable Type") && msg.Contains("'void'"), "decl: a void member variable shows 'Variable Type'");
			msg.Clear();
			Check(DeclErrorOf("class C { public var mV = 1; }", "mV", msg) && msg.Contains("not a valid type for a member variable"), "decl: a var member variable is reported (the parser keeps it as an unparsed member)");
			msg.Clear();
			Check(DeclErrorOf("class C { public T mT; }", "mT", msg) && msg.Contains("generic parameter"), "decl: an undeclared T on a member variable");
			msg.Clear();
			Check(!DeclErrorOf("class C<T> { public T mT; public List<T> F(T a) { return null; } }", "mT", msg) && !DeclErrorOf("class C<T> { public List<T> F(T a) { return null; } }", "F", msg), "decl: T declared on the type fits");
			msg.Clear();
			Check(!DeclErrorOf("class C { public T F<T>(T a) { return a; } }", "F", msg), "decl: T declared on the function fits");
			msg.Clear();
			Check(DeclErrorOf("class C { public U F<T>(T a) { return a; } }", "F", msg) && msg.Contains("'U'"), "decl: an undeclared U return type");
			msg.Clear();
			Check(!DeclErrorOf("class Outer<T> { class Inner { public T mT; } }", "mT", msg), "decl: an outer type has T in scope in a nested type");
			msg.Clear();
			Check(!DeclErrorOf("class C { [Comptime] public static var G() { return 1; } }", "G", msg), "decl: [Comptime] var G() fits");
			msg.Clear();
			Check(DeclErrorOf("class C { public static var G() { return 1; } }", "G", msg) && msg.Contains("Return Type 'var'") && msg.Contains("Comptime"), "decl: var G() outside [Comptime] names Comptime");

			// A typed signature that does not fit is refused: nothing is written.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText("class C\n{\n\tpublic void F(int a)\n\t{\n\t}\n\tint mCount;\n}\n", "C.bf");
				let before = scope String(doc.Text);
				let mg = doc.FindMethod("C.F(int)");
				Check(mg != null, "edit: F found");
				Check(!doc.SetSignature(mg.Method, "var", "int a") && doc.LastError.Contains("Return Type 'var'") && doc.Text == before, "edit: SetSignature with Return Type var is refused, text unchanged");
				Check(!doc.SetSignature(mg.Method, "void", "void a") && doc.LastError.Contains("Parameters") && doc.Text == before, "edit: SetSignature with a void parameter is refused, text unchanged");
				let type = doc.Unit.Members[0];
				Check(!doc.AddField(type, "void", "mBad") && doc.LastError.Contains("Variable Type 'void'") && doc.Text == before, "edit: AddField of type void is refused, text unchanged");
				Check(!doc.AddField(type, "var", "mBad2") && doc.Text == before, "edit: AddField of type var is refused");
				String key = scope .();
				Check(!doc.AddMethod(type, "let", "G", "", key) && doc.Text == before, "edit: AddMethod returning let is refused");
				Check(!doc.SetMemberType(type.Members[1], "void") && doc.LastError.Contains("'void'") && doc.Text == before, "edit: SetMemberType void is refused, text unchanged");
				Check(doc.SetSignature(mg.Method, "int", "int a, ref float b") && doc.Text.Contains("public int F(int a, ref float b)"), "edit: a legal signature is applied");
				Check(doc.AddField(doc.Unit.Members[0], "List<int>", "mItems") && doc.Text.Contains("List<int> mItems;"), "edit: AddField List<int> is applied");
				Check(!doc.SetGenericParams(doc.Unit.Members[0], "T, T") && doc.LastError.Contains("twice"), "edit: SetGenericParams T, T is refused");
				List<String> bases = scope .();
				bases.Add("int");
				Check(!doc.SetBaseList(doc.Unit.Members[0], bases) && doc.LastError.Contains("only an enum"), "edit: a base list with int on a class is refused");
			}

			// Problems list for what reaches the model.
			{
				List<UnreadableMember> problems = scope .();
				defer { ClearAndDeleteItems!(problems); }
				let unit = Parser.Parse("class C\n{\n\tpublic void mV = default;\n\tpublic void F(var x) { }\n}\n");
				ProjectIndex.CollectUnreadable(unit, problems);
				delete unit;
				Check(problems.Count == 2, scope $"Problems lists the void variable and the var parameter ({problems.Count})");
			}
		}

		// ------------------------------------------------------------------ destructor clauses

		/// `T x ~ delete _;` is a member variable (it was an unread member before ownership and
		/// initial values); DtorTok marks the `~` and never the bitwise not of a value.
		static void DestructorClauses()
		{
			let src = "class C\n{\n\tObject mA ~ delete _;\n\tObject mB = new .() ~ delete _;\n\tint mC = ~0;\n\tObject mD ~ { if (mOwns) delete _; };\n\tint mE = sStart ~ _.Dispose();\n\tint mF;\n}\n";
			let unit = Parser.Parse(src);
			defer delete unit;
			Member c = null;
			for (let m in unit.Members)
				if (m.Kind == .Type)
					c = m;
			Member Find(StringView name)
			{
				for (let m in c.Members)
					if (m.Name == name)
						return m;
				return null;
			}
			Check(c != null && c.Members.Count == 6, "six members read");
			if (c == null)
				return;
			let a = Find("mA");
			Check(a != null && a.Kind == .Field && a.InitTok < 0 && unit.TokenText(a.DtorTok) == "~" && unit.TokenText(a.LastTok) == ";", "`Object mA ~ delete _;`: a member variable, `~` marked, ends at `;`");
			let b = Find("mB");
			Check(b != null && b.Kind == .Field && b.InitTok > 0 && b.DtorTok > b.InitTok, "`= new .() ~ delete _`: `=` then `~`");
			let cc = Find("mC");
			Check(cc != null && cc.Kind == .Field && cc.DtorTok < 0, "`= ~0`: no destructor clause");
			let d = Find("mD");
			Check(d != null && d.Kind == .Field && d.DtorTok > 0 && unit.TokenText(d.LastTok) == ";", "`~ { ... }` block: a member variable through its `;`");
			let e = Find("mE");
			Check(e != null && e.Kind == .Field && e.DtorTok > 0 && unit.SpanText(e.DtorTok, e.LastTok - 1) == "~ _.Dispose()", "`= sStart ~ _.Dispose()`: the `~` after a value is the clause");
			Check(Find("mF") != null && Find("mF").DtorTok < 0, "plain member variable has none");
		}

		// ------------------------------------------------------------------ literals

		static void Lit(TokenKind k, StringView text, LiteralKind expected)
		{
			let got = Literals.Classify(k, text);
			Check(got == expected, scope $"{text} -> {expected} (got {got})");
		}

		static void LitFromSource(StringView exprText, LiteralKind expected)
		{
			// Through the real lexer and parser.
			String src = scope $"class C {{ void M() {{ let x = {exprText}; }} }}";
			let unit = Parser.Parse(src);
			defer delete unit;
			List<Member> methods = scope .();
			unit.CollectMethods(methods, null);
			LiteralKind got = .None;
			if (methods.Count == 1 && methods[0].Body != null && methods[0].Body.Body.Count == 1)
			{
				let e = methods[0].Body.Body[0].Expr;
				if (e != null && e.Kind == .Literal)
					got = e.LitKind;
			}
			Check(got == expected, scope $"parsed `{exprText}` is {expected} (got {got})");
		}

		static void Literals_()
		{
			Lit(.Number, "1", .Int);
			Lit(.Number, "1.0", .Double);
			Lit(.Number, "1.0f", .Float);
			Lit(.Number, "1f", .Float);
			Lit(.Number, "1F", .Float);
			Lit(.Number, "1.5d", .Double);
			Lit(.Number, "1e3", .Double);
			Lit(.Number, "1E-3", .Double);
			Lit(.Number, "2.5e3f", .Float);
			Lit(.Number, ".5", .Double);
			Lit(.Number, "0x10", .Int);
			Lit(.Number, "0xFF", .Int);
			Lit(.Number, "0xFFFFFFFF", .UInt);
			Lit(.Number, "0xFFFFFFFFFF", .Long);
			Lit(.Number, "0xFFFFFFFFFFFFFFFF", .ULong);
			Lit(.Number, "0x1F", .Int); // F is a hex digit, not a float suffix
			Lit(.Number, "0b1010", .Int);
			Lit(.Number, "0b1010u", .UInt);
			Lit(.Number, "1_000_000", .Int);
			Lit(.Number, "1'000", .Int);
			Lit(.Number, "5u", .UInt);
			Lit(.Number, "5U", .UInt);
			Lit(.Number, "5L", .Long);
			Lit(.Number, "5l", .Long);
			Lit(.Number, "5UL", .ULong);
			Lit(.Number, "5ul", .ULong);
			Lit(.Number, "3000000000", .Long);
			Lit(.Number, "9223372036854775807", .Long);
			Lit(.Number, "18446744073709551615", .ULong);
			Lit(.Char, "'a'", .Char8);
			Lit(.Char, "'\\n'", .Char8);
			Lit(.Char, "'\\u{1F600}'", .Char32);
			Lit(.String, "\"hi\"", .String);
			Lit(.String, "@\"C:\\dir\"", .VerbatimString);
			Lit(.String, "$\"x = {x}\"", .InterpolatedString);
			Lit(.String, "$@\"x = {x}\\\"", .InterpolatedString);
			Lit(.String, "@$\"x = {x}\"", .InterpolatedString);
			Lit(.String, "\"\"\"\nraw\n\"\"\"", .RawString);
			Lit(.Identifier, "true", .Bool);
			Lit(.Identifier, "null", .Null);

			LitFromSource("1.0", .Double);
			LitFromSource("1.0f", .Float);
			LitFromSource("0xFFu", .UInt);
			LitFromSource("1_000", .Int);
			LitFromSource("$\"a{1 + 2}b\"", .InterpolatedString);
			LitFromSource("@\"a\"\"b\"", .VerbatimString);
			LitFromSource("'x'", .Char8);
			LitFromSource("true", .Bool);
			LitFromSource("null", .Null);
		}

		// ------------------------------------------------------------------ recovery

		/// Parses `src`, then asserts: the listed methods are graphable, the named broken
		/// members exist, and loading + a no-op commit of every method reproduces the text.
		static void Recover(StringView name, StringView src, StringView okMethods, StringView brokenNames)
		{
			Console.WriteLine(" case: {}", name);
			let unit = Parser.Parse(src);
			defer delete unit;

			// Lexing is lossless.
			String rebuilt = scope .();
			for (let tok in unit.Tokens)
				rebuilt.Append(StringView(unit.Text, tok.LeadStart, tok.TrailEnd - tok.LeadStart));
			Check(rebuilt == src, "lexer reproduces the file");

			List<Member> all = scope .();
			unit.CollectMethods(all, null);
			for (let n in okMethods.Split(' '))
			{
				bool found = false;
				for (let m in all)
					if (m.Kind == .Method && m.Name == n && m.Body != null)
						found = true;
				Check(found, scope $"method {n} still parses");
			}
			int expectedBroken = 0;
			for (let n in brokenNames.Split(' '))
			{
				if (n.IsEmpty)
					continue;
				expectedBroken++;
				bool found = false;
				for (let m in all)
					if (m.Kind == .Broken && m.Name == n && m.Error != null && !m.Error.IsEmpty)
						found = true;
				Check(found, scope $"broken member {n} is reported");
			}
			int brokenCount = 0;
			for (let m in all)
				if (m.Kind == .Broken)
				{
					brokenCount++;
					// The broken member keeps its exact text.
					Check(m.HasSpan && unit.NodeText(m).Length > 0, "broken member keeps its text");
				}
			Check(brokenCount == expectedBroken, scope $"{expectedBroken} broken member(s) (got {brokenCount})");

			// Document level: broken members are listed, graphs of others build, commits are exact.
			SourceDocument doc = scope .();
			doc.LoadFromText(src, "test.bf");
			List<String> keys = scope .();
			for (let mg in doc.Methods)
				if (mg.Graphable)
					keys.Add(scope:: String(mg.Key));
			bool exact = true;
			for (let key in keys)
			{
				let mg = doc.FindMethod(key);
				if (mg == null)
					continue;
				doc.Commit(mg);
				if (doc.Text != src)
				{
					exact = false;
					doc.LoadFromText(src, "test.bf");
				}
			}
			Check(exact, "no-op commit of every method reproduces the file byte for byte");
			int brokenListed = 0;
			for (let mg in doc.Methods)
			{
				if (mg.Method.Kind != .Broken)
					continue;
				brokenListed++;
				Check(!mg.Graphable, "broken member is not graphable");
				let g = mg.Graph;
				bool red = false;
				for (let n in g.Nodes)
					if (n.Error != null)
					{
						String title = scope .();
						n.GetTitle(title);
						red = title.StartsWith("Broken: ");
					}
				Check(red && g.ReadOnly, "broken member shows a red 'Broken: <error>' node and is read-only");
			}
			Check(brokenListed == expectedBroken, "broken members are listed with the methods");
		}

		static void Recovery()
		{
			Recover("missing ) in a signature",
				"""
				namespace T
				{
					class C
					{
						public void Before() { }
						public void Mangled(int a
						{
							foo();
						}
						public void After() { }
						public int Last() { return 1; }
					}
				}

				""", "Before After Last", "Mangled");

			Recover("missing ) in a call inside the body",
				"""
				class C
				{
					public void Before() { }
					public void Bad()
					{
						Foo(1;
						bar();
					}
					public void After() { int x = 1; }
				}

				""", "Before After", "Bad");

			Recover("unbalanced braces inside a method (missing })",
				"""
				class C
				{
					public void Before() { }
					public void Open()
					{
						if (x)
						{
							foo();
					}
					public void After() { }
					public void Last() { }
				}

				""", "Before After Last", "Open");

			Recover("extra ] in a method (mismatched brackets)",
				"""
				class C
				{
					public void Before() { }
					public void Bad()
					{
						let x = a[1]];
						foo();
					}
					public void After() { }
				}

				""", "Before After", "Bad");

			Recover("bad expression (parses as code, nothing hidden)",
				"""
				class C
				{
					public void Before() { }
					public void Bad()
					{
						int x = 1 + ;
						foo();
					}
					public void After() { }
				}

				""", "Before Bad After", "");

			Recover("truncated file",
				"""
				class C
				{
					public void Before() { }
					public void After() { }
					public void Cut()
					{
						int x = 1;
						if (x > 0)
						{
							foo(
				""", "Before After", "Cut");

			Recover("two broken members",
				"""
				class C
				{
					public void A(int x { }
					public void Middle() { }
					public void B(int y
					{
						foo();
					}
					public void Last() { }
				}

				""", "Middle Last", "A B");

			Recover("broken member in a nested type",
				"""
				class Outer
				{
					public void Before() { }
					class Inner
					{
						public void X(int a { }
						public void Y() { }
					}
					public void After() { }
				}

				""", "Before Y After", "X");

			Recover("attribute above the broken member",
				"""
				class C
				{
					public void Before() { }
					[Inline]
					public void Bad(int a
					{
						foo();
					}
					[Inline]
					public void After() { }
				}

				""", "Before After", "Bad");

			Recover("valid file has no broken members",
				"""
				class C
				{
					public void A() { if (x) { foo(); } }
					public int B(int a, int b) { return a + b; }
				}

				""", "A B", "");

			// 2026-10-11: `var Main()` used to be a hidden Raw member (no Outline row, no graph,
			// no message). It is a function with an error on its entry node; Run() after it is read.
			Recover("var return type (2026-10-11 report)", SaveCheckTests.cReport, "Main Run", "");
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(SaveCheckTests.cReport, "Program.bf");
				let main = doc.FindMethod("Program.Main()");
				Check(main != null && main.Graphable && main.Method.TypeText == "var", "var Main() is a function with a graph");
				String msg = scope .();
				Check(main != null && main.Method.GetDeclError(msg) && msg.Contains("Return Type 'var'"), "var Main() has a declaration error");
				Check(main != null && main.Graph.Entry.Error != null && main.Graph.Entry.Error.Contains("Return Type"), "the entry node of var Main() shows the error");
				Check(doc.FindMethod("Program.Run()") != null, "Run() after it is read");
				// Fixing the return type through the signature clears the error on the kept graph.
				doc.SetSignature(main.Method, "void", "");
				let fixedMain = doc.FindMethod("Program.Main()");
				Check(fixedMain != null && fixedMain.Graph.Entry.Error == null && doc.Text.Contains("public static void Main()"), "Return Type void clears the entry error");
				List<UnreadableMember> problems = scope .();
				defer { ClearAndDeleteItems!(problems); }
				let unit = Parser.Parse(SaveCheckTests.cReport);
				ProjectIndex.CollectUnreadable(unit, problems);
				delete unit;
				Check(problems.Count == 1 && problems[0].Name == "Program.Main" && problems[0].Line == 11 && !problems[0].Broken, "Problems lists Program.Main at line 11");
			}
			Recover("[Comptime] var function is valid",
				"""
				class C
				{
					[Comptime(ConstEval=true)]
					public static var GetMin<T>() where T : Enum
					{
						return 1;
					}
					public void After() { }
				}

				""", "GetMin After", "");
			{
				let unit = Parser.Parse("class C\n{\n\t[Comptime]\n\tpublic static var F() { return 1; }\n}\n");
				List<UnreadableMember> problems = scope .();
				defer { ClearAndDeleteItems!(problems); }
				ProjectIndex.CollectUnreadable(unit, problems);
				delete unit;
				Check(problems.IsEmpty, "a [Comptime] var function has no declaration error");
			}
			Recover("a keyword as the return type is shown, the next function is read",
				"""
				class C
				{
					public void Before() { }
					public default Bad(int a)
					{
						foo();
					}
					public void After() { }
				}

				""", "Before After", "Bad");
			Recover("var member variable is shown",
				"""
				class C
				{
					public var mX = 1;
					public void Use() { }
				}

				""", "Use", "mX");
			Recover("a member with no name to recover",
				"""
				class C
				{
					public 42 = 7;
					public void After() { }
				}

				""", "After", "?");
			{
				let unit = Parser.Parse("class C\n{\n\tpublic 42 = 7;\n}\n");
				List<UnreadableMember> problems = scope .();
				defer { ClearAndDeleteItems!(problems); }
				ProjectIndex.CollectUnreadable(unit, problems);
				delete unit;
				Check(problems.Count == 1 && problems[0].Name == "unparsed member at line 3" && problems[0].Broken, "a nameless member is listed as 'unparsed member at line 3'");
			}
			Recover("valid forms kept as text are not shown as unreadable",
				"""
				class C<T>
				{
					public Event<Action> mOnChange ~ _.Dispose();
					protected Linux.DBus* mBus ~ if (_ != null) Linux.SdBusUnref(_);
					void ICollection<T>.Add(T value) { }
					public static Self operator+(Self a, Self b) => a;
					public typealias Handler = delegate void(int a);
					C(SerializationInfo info) { }
					public void Other() { }
				}

				""", "Other", "");
		}

		// ------------------------------------------------------------------ layout keys

		const String cLayoutSrc =
			"""
			class C
			{
				public void M()
				{
					a0();
					a1();
					if (flag)
					{
						b0();
						b1();
					}
					a2();
					a3();
				}
			}

			""";

		/// "Kind|Text" of statement nodes, numbered when repeated.
		static void Identify(Graph g, Dictionary<String, Node> outMap)
		{
			Dictionary<String, int> seen = scope .();
			defer { for (let k in seen.Keys) delete k; }
			for (let n in g.Nodes)
			{
				if (n.Kind == .Entry || n.IsPure)
					continue;
				String id = scope $"{n.Kind}|{n.Text}";
				if (seen.TryGetValue(id, var count))
				{
					seen[id] = count + 1;
					id.AppendF("#{}", count + 1);
				}
				else
					seen[new String(id)] = 1;
				outMap[new String(id)] = n;
			}
		}

		static void FreeMap(Dictionary<String, Node> map)
		{
			for (let k in map.Keys)
				delete k;
		}

		/// Loads `src` with a layout file and returns the positions by node identity.
		static void LoadAndGet(StringView src, StringView layoutText, SourceDocument doc, Dictionary<String, Node> outMap)
		{
			doc.LoadFromText(src, "layout.bf", layoutText);
			let mg = doc.FindMethod("C.M()");
			Identify(mg.Graph, outMap);
		}

		static void LayoutKeyTests()
		{
			// Original document with hand-placed nodes.
			SourceDocument doc0 = scope .();
			doc0.LoadFromText(cLayoutSrc, "layout.bf");
			Dictionary<String, Node> ids0 = scope .();
			defer FreeMap(ids0);
			Identify(doc0.FindMethod("C.M()").Graph, ids0);
			float x = 1000;
			for (let kv in ids0)
			{
				kv.value.X = x;
				kv.value.Y = x * 2 + 7;
				kv.value.HasPos = true;
				x += 111;
			}
			String layout = scope .();
			doc0.GetLayoutText(layout);
			Check(layout.Contains("#version\t2"), "layout file is written with version 2");
			Check(layout.Contains("#"), "layout keys carry a content hash");

			// Same text reloaded: everything exact.
			{
				SourceDocument doc = scope .();
				Dictionary<String, Node> ids = scope .();
				defer FreeMap(ids);
				LoadAndGet(cLayoutSrc, layout, doc, ids);
				bool same = ids.Count == ids0.Count;
				for (let kv in ids0)
					if (!ids.TryGetValue(kv.key, let n) || n.X != kv.value.X || n.Y != kv.value.Y)
						same = false;
				Check(same, "unchanged text keeps every position");
				Check(doc.LayoutPruned == 0, "nothing pruned");
			}

			// Insert a line above (shifts every later statement by one).
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta0();", "\t\tnewFirst();\n\t\ta0();");
				CheckPreserved("insert a line above", src, layout, ids0, "", "Call|newFirst", 0);
			}
			// Insert in the middle (inside the if body).
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\t\tb1();", "\t\t\tmid();\n\t\t\tb1();");
				CheckPreserved("insert a line inside the if", src, layout, ids0, "", "Call|mid", 0);
			}
			// Delete a statement.
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta1();\n", "");
				CheckPreserved("delete a statement", src, layout, ids0, "Call|a1", "", 1);
			}
			// Edit a statement: it keeps its position (same path, different hash).
			{
				String src = scope .(cLayoutSrc);
				src.Replace("a2();", "a2(5);");
				CheckPreserved("edit a statement", src, layout, ids0, "", "", 0, "Call|a2");
			}
			// Reorder two statements: positions follow the statements.
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta0();\n\t\ta1();\n", "\t\ta1();\n\t\ta0();\n");
				CheckPreserved("reorder two statements", src, layout, ids0, "", "", 0);
			}
			// Reformat + comment: whitespace and comments don't change the hash.
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta2();", "\t\t// note\n\t\ta2 (  ) ;   // trailing");
				CheckPreserved("reformat and comment a statement", src, layout, ids0, "", "", 0);
			}
			// Delete + edit at once (the edited statement keeps its path).
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\t\tb0();\n", "");
				src.Replace("a3();", "a3(1, 2);");
				CheckPreserved("delete + edit together", src, layout, ids0, "Call|b0", "", 1, "Call|a3");
			}
			// Insert + delete together.
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta0();", "\t\tnewFirst();\n\t\ta0();");
				src.Replace("\t\ta3();\n", "");
				CheckPreserved("insert + delete together", src, layout, ids0, "Call|a3", "Call|newFirst", 1);
			}

			// Old positional layout files: read once, rewritten in the new form.
			{
				String legacy = scope .();
				for (let line in layout.Split('\n'))
				{
					if (line.StartsWith("#") || line.IsEmpty)
						continue;
					let tab = line.IndexOf('\t');
					var key = line.Substring(0, tab);
					let hash = key.IndexOf('#');
					if (hash >= 0)
						key = key.Substring(0, hash);
					legacy.Append(key);
					legacy.Append(line.Substring(tab));
					legacy.Append('\n');
				}
				legacy.Insert(0, "# old file\n");
				SourceDocument doc = scope .();
				Dictionary<String, Node> ids = scope .();
				defer FreeMap(ids);
				LoadAndGet(cLayoutSrc, legacy, doc, ids);
				bool same = true;
				for (let kv in ids0)
					if (!ids.TryGetValue(kv.key, let n) || n.X != kv.value.X || n.Y != kv.value.Y)
						same = false;
				Check(same, "old positional entries still place the nodes");
				Check(doc.LayoutMigrated > 0, scope $"old entries counted as migrated ({doc.LayoutMigrated})");
				String again = scope .();
				doc.GetLayoutText(again);
				Check(again.Contains("#version\t2"), "migrated file is written as version 2");
				bool anyOld = false;
				for (let line in again.Split('\n'))
				{
					if (line.StartsWith("#") || line.IsEmpty)
						continue;
					let tab = line.IndexOf('\t');
					if (tab > 0 && !line.Substring(0, tab).Contains('#') && !line.Substring(0, tab).Contains("orphan"))
						anyOld = true;
				}
				Check(!anyOld, "migrated file has no positional-only entries");
			}

			// Unknown fields survive a load + save.
			{
				String withExtra = scope .(layout);
				withExtra.Append("#future\tsomething new\n");
				SourceDocument doc = scope .();
				doc.LoadFromText(cLayoutSrc, "layout.bf", withExtra);
				String again = scope .();
				doc.GetLayoutText(again);
				Check(again.Contains("#future\tsomething new"), "unknown layout lines are kept");
			}

			// Stale entries are pruned and counted.
			{
				String src = scope .(cLayoutSrc);
				src.Replace("\t\ta1();\n", "");
				src.Replace("\t\ta2();\n", "");
				SourceDocument doc = scope .();
				Dictionary<String, Node> ids = scope .();
				defer FreeMap(ids);
				LoadAndGet(src, layout, doc, ids);
				Check(doc.LayoutPruned >= 2, scope $"entries of deleted statements are pruned and counted ({doc.LayoutPruned})");
				String again = scope .();
				doc.GetLayoutText(again);
				Check(!again.Contains("Call|a1"), "pruned entries are not written back");
			}
		}

		/// Loads `src` with `layout` (saved for cLayoutSrc) and checks that every statement that
		/// exists in both versions kept its position, except those in `skipIds` (space separated)
		/// which only need to have a position. `gone` / `added`: identities that must be absent
		/// / present. expectPruned: minimum number of pruned entries.
		static void CheckPreserved(StringView name, StringView src, StringView layout, Dictionary<String, Node> ids0,
			StringView gone, StringView added, int expectPruned, StringView edited = "")
		{
			Console.WriteLine(" case: {}", name);
			SourceDocument doc = scope .();
			Dictionary<String, Node> ids = scope .();
			defer FreeMap(ids);
			LoadAndGet(src, layout, doc, ids);
			int moved = 0;
			String detail = scope .();
			for (let kv in ids0)
			{
				bool isGone = false;
				for (let g in gone.Split(' '))
					if (!g.IsEmpty && kv.key == g)
						isGone = true;
				if (isGone)
					continue;
				if (!ids.TryGetValue(kv.key, let n))
				{
					moved++;
					detail.AppendF(" [{} missing]", kv.key);
					continue;
				}
				if (n.X != kv.value.X || n.Y != kv.value.Y)
				{
					moved++;
					detail.AppendF(" [{} moved]", kv.key);
				}
			}
			Check(moved == 0, scope $"untouched and edited nodes keep their position{detail}");
			for (let a in added.Split(' '))
			{
				if (a.IsEmpty)
					continue;
				String key = scope .(a);
				Check(ids.ContainsKey(key), scope $"{a} is a new node");
			}
			Check(doc.LayoutPruned >= expectPruned, scope $"pruned {doc.LayoutPruned} stale entries (expected >= {expectPruned})");
			// Every node has a position (new ones from auto-layout).
			bool allPos = true;
			for (let kv in ids)
				if (!kv.value.HasPos)
					allPos = false;
			Check(allPos, "every node has a position");
		}
	}
}
