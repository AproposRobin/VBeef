using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Overload choice on call nodes (CallOverloads, docs/Calls-and-Receivers.md#overloads), run by
	/// `textforms`, and the text pins (PinValue: bare text, escaping, quoted literals read from older
	/// projects, `$"` / `@"` expressions, char8*), run by `edits`.
	static class OverloadTests
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

		/// A project index + TypeService over the fixture and the document, installed like the editor.
		class Fixture
		{
			public ProjectIndex Index = new .() ~ delete _;
			public TypeService Service;
			ProjectIndex mOldIndex;

			public this()
			{
				Service = new .(Index);
				Service.AutoLoadLibraries = false;
				Service.Install();
				mOldIndex = GraphBuilder.Index;
				GraphBuilder.Index = Index;
				Add("Sys.bf", cSys);
			}

			public void Add(StringView path, StringView text)
			{
				let unit = Parser.Parse(text);
				Index.Update(path, unit);
				delete unit;
			}

			public void Update(SourceDocument doc) => Index.Update(doc.FilePath, doc.Unit);

			public ~this()
			{
				GraphBuilder.Index = mOldIndex;
				delete Service;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}
		}

		const String cSys =
			"""
			namespace System
			{
				class Object
				{
				}
				class String : Object
				{
				}
				struct StringView
				{
				}
				class Console
				{
					public static void WriteLine() {}
					public static void WriteLine(StringView line) {}
					public static void WriteLine(StringView fmt, params Object[] args) {}
					public static void WriteLine(Object obj) {}
				}
				static class Calc
				{
					public static int Abs(int v) => v;
					public static float Abs(float v) => v;
					public static double Abs(double v) => v;
					public static void Get(int v) {}
					public static void Get(out int v) { v = 0; }
					public static void Show(char8* s) {}
				}
			}

			""";

		const String cHost =
			"""
			using System;

			namespace Demo
			{
				class Host
				{
					float mF = 1.5f;

					public void Run(int n)
					{
						Console.WriteLine("Hello from NewProject");
						Console.WriteLine(n);
						int a = Calc.Abs(n);
						Calc.Get(2);
						Calc.Show("C string");
					}
				}
			}

			""";

		static Node FindCall(Graph g, StringView name, int nth = 0)
		{
			int i = 0;
			for (let n in g.Nodes)
			{
				if (n.Kind != .Call || n.Text != name)
					continue;
				if (i == nth)
					return n;
				i++;
			}
			return null;
		}

		static Pin EntryParam(Graph g, StringView name)
		{
			for (let p in g.Entry.Outputs)
				if (p.Kind == .Data && p.Label == name)
					return p;
			return null;
		}

		static SymbolMethod FindOverload(List<SymbolMethod> list, StringView sig)
		{
			for (let m in list)
			{
				String s = scope .();
				CallOverloads.Signature(m, s);
				if (s == sig)
					return m;
			}
			return null;
		}

		static StringView TypeOf(Node n, int arg)
		{
			let p = n?.FindArg(arg);
			return (p != null) ? (StringView)p.TypeName : "none";
		}

		// ------------------------------------------------------------------ overload choice (textforms)

		public static void RunTextForms()
		{
			Console.WriteLine("Text forms 9: overloads of a call node follow the values (CallOverloads)");
			Fixture fx = scope .();
			SourceDocument doc = scope .();
			doc.LoadFromText(cHost, "Host.bf");
			fx.Update(doc);
			doc.LoadFromText(cHost, "Host.bf");
			let ts = fx.Service;
			var mg = doc.FindMethod("Host.Run(int)");
			Check(mg != null, "fixture: Host.Run(int) has a graph");
			if (mg == null)
				return;
			var g = mg.Graph;

			// Read from code: the overload the arguments choose, never Object for a text literal.
			let hello = FindCall(g, "WriteLine", 0);
			let number = FindCall(g, "WriteLine", 1);
			let helloPin = hello?.FindArg(0);
			Check(helloPin != null && helloPin.TypeName == "StringView" && helloPin.Label == "Message" && helloPin.Default == "\"Hello from NewProject\"",
				scope $"`Console.WriteLine(\"Hello from NewProject\")` reads as WriteLine(StringView line), pin Message ({TypeOf(hello, 0)} {helloPin?.Label})");
			Check(number != null && TypeOf(number, 0) == "Object" && number.FindArg(0).Label == "Message", scope $"`Console.WriteLine(n)` with an int reads as WriteLine(Object obj) ({TypeOf(number, 0)})");
			Check(hello != null && hello.Binding == .Static && hello.FindInput("target") == null, "a static call: no Receiver pin");
			Check(CallOverloads.Count(g, hello, ts) == 4, scope $"WriteLine has 4 overloads ({CallOverloads.Count(g, hello, ts)})");
			String sig = scope .();
			CallOverloads.PinSignature(hello, sig);
			Check(sig == "WriteLine(StringView)", scope $"the subtitle names the overload: {sig}");
			List<SymbolMethod> list = scope .();
			CallOverloads.ListOf(g, hello, ts, list);
			let cur = CallOverloads.IndexOfCurrent(hello, list);
			String curSig = scope .();
			if (cur >= 0)
				CallOverloads.Signature(list[cur], curSig);
			Check(curSig == "WriteLine(StringView line)", scope $"Properties marks the current overload: {curSig}");
			let abs = FindCall(g, "Abs");
			Check(abs != null && TypeOf(abs, 0) == "int", scope $"`Calc.Abs(n)` with an int reads as Abs(int v) ({TypeOf(abs, 0)})");
			let show = FindCall(g, "Show");
			Check(show != null && TypeOf(show, 0) == "char8*" && PinValue.KindOf("char8*", show.FindArg(0).Default, "arg0", ts) == .Text,
				"`Calc.Show(\"C string\")`: a char8* pin with a text field");

			// A wired value picks the overload: an int wired into a text pin switches it to Object.
			doc.PushUndo();
			StringView[1] lineName = .("line");
			StringView[1] svType = .("StringView");
			let placed = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, lineName, svType, "void");
			let placedPin = placed.FindArg(0);
			Check(placedPin.Label == "Message", "a print placed from the Node menu labels its pin Message");
			let nOut = EntryParam(g, "n");
			Check(nOut != null && !Graph.CanConnectTyped(nOut, placedPin) && CallOverloads.CouldTake(g, placedPin, "int", ts),
				"an int does not fit StringView, but another overload takes it: the drop is allowed");
			g.Connect(nOut, placedPin);
			Check(CallOverloads.Refit(g, placed, ts) && TypeOf(placed, 0) == "Object" && placedPin.Label == "Message" && g.IsLinked(placedPin),
				scope $"wired with an int the node becomes WriteLine(Object obj), wire kept ({TypeOf(placed, 0)})");
			Check(!CallOverloads.Refit(g, placed, ts), "a second refit changes nothing");
			let oldNext = g.ExecTarget(number.Then);
			g.Connect(number.Then, placed.ExecIn);
			if (oldNext != null)
				g.Connect(placed.Then, oldNext.ExecIn);
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tConsole.WriteLine(n);\n\t\t\tConsole.WriteLine(n);\n"), "written `Console.WriteLine(n);` after the other print");
			doc.Undo();
			Check(doc.Text == cHost, "undo: the text is back");
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			// A typed value picks the overload: a text typed into the Object pin.
			let number2 = FindCall(g, "WriteLine", 1);
			doc.PushUndo();
			g.DisconnectPin(number2.FindArg(0));
			number2.FindArg(0).Default.Set("\"Hi\"");
			Check(CallOverloads.Refit(g, number2, ts) && TypeOf(number2, 0) == "StringView" && PinValue.KindOf("StringView", number2.FindArg(0).Default, "arg0", ts) == .Text,
				scope $"a text typed into the Object pin switches to WriteLine(StringView line), a text field again ({TypeOf(number2, 0)})");
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tConsole.WriteLine(\"Hi\");\n"), "written `Console.WriteLine(\"Hi\");`");
			doc.Undo();
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			// Nothing in it: never the Object overload by default.
			StringView[1] objName = .("obj");
			StringView[1] objType = .("Object");
			let bare = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, objName, objType, "void");
			Check(CallOverloads.Refit(g, bare, ts) && TypeOf(bare, 0) == "StringView", scope $"an empty WriteLine(Object) becomes WriteLine(StringView) ({TypeOf(bare, 0)})");
			g.RemoveNode(bare);

			// From the Node menu off an int: the overload whose input takes it.
			let fromMenu = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, lineName, svType, "void");
			Check(CallOverloads.FitForValue(g, fromMenu, "int", ts) && TypeOf(fromMenu, 0) == "Object", "made off an int wire: WriteLine(Object obj)");
			Check(!CallOverloads.FitForValue(g, fromMenu, "String", ts), "a text fits the pin already: no change");
			g.RemoveNode(fromMenu);

			// Numbers: Abs(double) placed, an int wired: Abs(int); a float: Abs(float).
			StringView[1] vName = .("v");
			StringView[1] dType = .("double");
			let absD = NodeFactory.StaticCall(g, "Abs", "Calc", "Calc", false, vName, dType, "double");
			g.Connect(EntryParam(g, "n"), absD.FindArg(0));
			Check(CallOverloads.Refit(g, absD, ts) && TypeOf(absD, 0) == "int" && g.IsLinked(absD.FindArg(0)), scope $"Abs(double) wired with an int becomes Abs(int v) ({TypeOf(absD, 0)})");
			g.DisconnectPin(absD.FindArg(0));
			let fGet = NodeFactory.Get(g, "mF", "float");
			g.Connect(fGet.Result, absD.FindArg(0));
			Check(CallOverloads.Refit(g, absD, ts) && TypeOf(absD, 0) == "float", scope $"wired with a float: Abs(float v) ({TypeOf(absD, 0)})");
			g.RemoveNode(absD);
			g.RemoveNode(fGet);

			// Properties: choosing an overload.
			list.Clear();
			CallOverloads.ListOf(g, FindCall(g, "WriteLine", 0), ts, list);
			doc.PushUndo();
			String why = scope .();
			let toObject = FindOverload(list, "WriteLine(Object obj)");
			Check(toObject != null && CallOverloads.Choose(g, FindCall(g, "WriteLine", 0), toObject, ts, why) && TypeOf(FindCall(g, "WriteLine", 0), 0) == "Object",
				"choosing WriteLine(Object obj) for a text literal");
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tConsole.WriteLine((Object)\"Hello from NewProject\");\n"),
				"written with a cast, the only way Beef calls WriteLine(Object) for a literal");
			let readBack = FindCall(doc.FindMethod("Host.Run(int)").Graph, "WriteLine", 0);
			Check(readBack != null && TypeOf(readBack, 0) == "Object", scope $"read back as WriteLine(Object obj) ({TypeOf(readBack, 0)})");
			doc.Undo();
			Check(doc.Text == cHost, "undo removes the cast");
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			doc.PushUndo();
			let toNone = FindOverload(list, "WriteLine()");
			let first = FindCall(g, "WriteLine", 0);
			Check(toNone != null && CallOverloads.Choose(g, first, toNone, ts, why) && first.ArgCount == 0, "choosing WriteLine(): the pin goes");
			Check(doc.Commit(mg) && doc.Text.Contains("\t\t\tConsole.WriteLine();\n\t\t\tConsole.WriteLine(n);\n"), "written `Console.WriteLine();`");
			let back = FindOverload(list, "WriteLine(StringView line)");
			Check(back != null && CallOverloads.Choose(g, first, back, ts, why) && first.ArgCount == 1 && first.FindArg(0).Label == "Message" && first.FindArg(0).Default.IsEmpty,
				"choosing WriteLine(StringView line) again: an empty Message pin");
			doc.Undo();
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			// A wire that still fits stays; a cast tells Beef which overload when the wire would choose another.
			list.Clear();
			let absN = FindCall(g, "Abs");
			CallOverloads.ListOf(g, absN, ts, list);
			Check(list.Count == 3, scope $"Abs has 3 overloads ({list.Count})");
			doc.PushUndo();
			let toFloat = FindOverload(list, "Abs(float v)");
			Check(toFloat != null && CallOverloads.Choose(g, absN, toFloat, ts, why) && TypeOf(absN, 0) == "float", "choosing Abs(float v) with an int wired");
			Check(doc.Commit(mg) && doc.Text.Contains("int a = Calc.Abs((float)n);"), "the wire is kept and cast: `Calc.Abs((float)n)`");
			doc.Undo();
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			// A typed number follows the new type.
			doc.PushUndo();
			StringView[1] iType = .("int");
			let absTyped = NodeFactory.StaticCall(g, "Abs", "Calc", "Calc", false, vName, iType, "int");
			absTyped.FindArg(0).Default.Set("2");
			Check(CallOverloads.Choose(g, absTyped, FindOverload(list, "Abs(float v)"), ts, why) && TypeOf(absTyped, 0) == "float",
				"a typed 2 on Abs(int): choosing Abs(float v)");
			Check(absTyped.FindArg(0).Default == "2f" || absTyped.FindArg(0).Default == "2.0f", scope $"the value is written for a float ({absTyped.FindArg(0).Default})");
			Check(absTyped.Inputs.Count == 1 && absTyped.FindArg(0).Default != "2", "no cast needed: the literal itself chooses it");
			g.RemoveNode(absTyped);
			doc.Undo();
			mg = doc.FindMethod("Host.Run(int)");
			g = mg.Graph;

			// An out parameter where the node has an input: refused with the reason.
			list.Clear();
			let get = FindCall(g, "Get");
			CallOverloads.ListOf(g, get, ts, list);
			let outOne = FindOverload(list, "Get(out int v)");
			why.Clear();
			Check(outOne != null && !CallOverloads.Applicable(get, outOne, why) && why.Contains("out"), scope $"Get(out int v) cannot replace an input: {why}");
			Check(!CallOverloads.CouldTake(g, get.FindArg(0), "bool", ts), "no overload of Get takes a bool: the drop stays refused");

			// Friendly labels.
			String label = scope .();
			CallOverloads.FriendlyLabel("System.Diagnostics.Debug", "WriteLine", "strFormat", 2, label);
			Check(label == "Format", "Debug.WriteLine(StringView strFormat, params ...): Format");
			CallOverloads.FriendlyLabel("Debug", "WriteLine", "args", 2, label);
			Check(label == "Values", "... and its params: Values");
			CallOverloads.FriendlyLabel("Calc", "Abs", "v", 1, label);
			Check(label == "v", "other functions keep the parameter name");
			Check(doc.Text == cHost, "the document is as loaded");
		}

		// ------------------------------------------------------------------ text pins (edits)

		static void Commit(SourceDocument doc, StringView key)
		{
			let mg = doc.FindMethod(key);
			for (let n in mg.Graph.Nodes)
				n.Edited = true;
			doc.Commit(mg);
		}

		public static void RunEdits()
		{
			Console.WriteLine("Scenario 25: text pins take bare text; the code gets the quotes");
			// The field rules.
			String lit = scope .();
			String why = scope .();
			void Typed(StringView typed, StringView want, StringView what)
			{
				lit.Clear();
				PinValue.Write(.Text, "StringView", typed, false, lit, why);
				Check(lit == want, scope $"{what}: {lit}");
			}
			Typed("Hello from NewProject", "\"Hello from NewProject\"", "bare text gets the quotes");
			Typed("say \"hi\"", "\"say \\\"hi\\\"\"", "a quote inside is escaped");
			Typed("C:\\dir\\file", "\"C:\\\\dir\\\\file\"", "backslashes are escaped");
			Typed("one\ntwo\tthree", "\"one\\ntwo\\tthree\"", "a line break and a tab are escaped");
			Typed("\"Hello\"", "\"Hello\"", "one pair of quotes around the whole text is taken off");
			Typed("\"\"Hello\"\"", "\"\\\"Hello\\\"\"", "a text in quotes is typed with the quotes doubled");
			Typed("$\"n = {n}\"", "$\"n = {n}\"", "`$\"` starts an expression: written as typed");
			Typed("@\"C:\\dir\"", "@\"C:\\dir\"", "`@\"` starts an expression: written as typed");
			// Bare round trip: what the field shows for the literal it wrote is what was typed.
			for (let text in StringView[?]("Hello from NewProject", "say \"hi\" \\ C:\\dir", "line one\nline two", "", "tab\there", "{braces} and $dollar"))
			{
				lit.Clear();
				PinValue.Write(.Text, "String", text, false, lit, why);
				String shown = scope .();
				PinValue.Display(.Text, "String", lit, shown);
				Check(shown == text && PinValue.KindOf("String", lit, "arg0", null) == .Text, scope $"round trip of `{text}` through {lit}");
			}
			// What shows a field and what shows the Expression badge.
			Check(PinValue.KindOf("StringView", "\"x\"", "arg0", null) == .Text, "a \"...\" literal in a StringView pin: a text field");
			Check(PinValue.KindOf("char8*", "\"x\"", "arg0", null) == .Text && PinValue.KindOf("char8*", "", "arg0", null) == .Text, "char8*: a text field");
			Check(PinValue.KindOf("char8*", "null", "arg0", null) == .None, "char8* holding null: no field (shown dim)");
			Check(PinValue.KindOf("String", "$\"n = {n}\"", "arg0", null) == .Custom, "an interpolated string: Expression badge");
			Check(PinValue.KindOf("String", "@\"C:\\dir\"", "arg0", null) == .Custom, "a verbatim string: Expression badge");
			Check(PinValue.KindOf("String", "name", "arg0", null) == .Custom, "a name: Expression badge");
			Check(PinValue.KindOf("Object", "\"x\"", "arg0", null) == .Custom, "a text literal in an Object pin: Expression badge");

			// The document: a print with a quoted literal (older projects) shows bare text and writes it back unchanged.
			const String cPrint =
				"""
				using System;

				namespace Demo
				{
					class Greeter
					{
						public void Hello()
						{
							Console.WriteLine("Hello from NewProject");
						}
					}
				}

				""";
			Fixture fx = scope .();
			SourceDocument doc = scope .();
			doc.LoadFromText(cPrint, "Greeter.bf");
			fx.Update(doc);
			doc.LoadFromText(cPrint, "Greeter.bf");
			var g = doc.FindMethod("Greeter.Hello()").Graph;
			var print = FindCall(g, "WriteLine");
			var pin = print?.FindArg(0);
			String shown = scope .();
			if (pin != null)
				PinValue.Display(.Text, pin.TypeName, pin.Default, shown);
			Check(pin != null && PinValue.KindOf(pin.TypeName, pin.Default, pin.Name, fx.Service) == .Text && shown == "Hello from NewProject",
				scope $"a quoted literal read from code: a text field showing `{shown}`");
			doc.PushUndo();
			Commit(doc, "Greeter.Hello()");
			Check(doc.Text == cPrint, "written back byte for byte");

			// Typing into it.
			g = doc.FindMethod("Greeter.Hello()").Graph;
			print = FindCall(g, "WriteLine");
			pin = print.FindArg(0);
			lit.Clear();
			PinValue.Write(.Text, pin.TypeName, "say \"hi\" \\ bye", false, lit, why);
			doc.PushUndo();
			pin.Default.Set(lit);
			print.Edited = true;
			Check(doc.Commit(doc.FindMethod("Greeter.Hello()")) && doc.Text.Contains("\t\t\tConsole.WriteLine(\"say \\\"hi\\\" \\\\ bye\");\n"), "typed bare text written escaped");
			SourceDocument again = scope .();
			again.LoadFromText(doc.Text, "Greeter.bf");
			let pin2 = FindCall(again.FindMethod("Greeter.Hello()").Graph, "WriteLine")?.FindArg(0);
			shown.Clear();
			if (pin2 != null)
				PinValue.Display(.Text, pin2.TypeName, pin2.Default, shown);
			Check(shown == "say \"hi\" \\ bye", scope $"reopened, the field shows what was typed ({shown})");
			doc.Undo();
			Check(doc.Text == cPrint, "undo");

			// An unconnected print in the side file (orphans keep their literal with its quotes).
			g = doc.FindMethod("Greeter.Hello()").Graph;
			doc.PushUndo();
			StringView[1] lineName = .("line");
			StringView[1] svType = .("StringView");
			let orphan = NodeFactory.StaticCall(g, "WriteLine", "Console", "Console", true, lineName, svType, "void");
			orphan.FindArg(0).Default.Set("\"Hi there\"");
			orphan.X = 400;
			orphan.Y = 300;
			orphan.HasPos = true;
			doc.Commit(doc.FindMethod("Greeter.Hello()"));
			String layout = scope .();
			doc.GetLayoutText(layout);
			Check(layout.Contains("#orphans\tGreeter.Hello()") && layout.Contains("Hi there"), "the unconnected print is in the side file");
			SourceDocument reopened = scope .();
			reopened.LoadFromText(doc.Text, "Greeter.bf", layout);
			Node orphanBack = null;
			for (let n in reopened.FindMethod("Greeter.Hello()").Graph.Nodes)
				if (n.Kind == .Call && n.Text == "WriteLine" && n.Key.StartsWith("orphan"))
					orphanBack = n;
			let op = orphanBack?.FindArg(0);
			shown.Clear();
			if (op != null)
				PinValue.Display(.Text, op.TypeName, op.Default, shown);
			Check(op != null && op.Default == "\"Hi there\"" && PinValue.KindOf(op.TypeName, op.Default, op.Name, fx.Service) == .Text && shown == "Hi there",
				scope $"reloaded from the side file: the literal with its quotes, the field shows `{shown}`");
			doc.Undo();

			// Expressions typed into a text field.
			g = doc.FindMethod("Greeter.Hello()").Graph;
			print = FindCall(g, "WriteLine");
			pin = print.FindArg(0);
			lit.Clear();
			PinValue.Write(.Text, pin.TypeName, "@\"C:\\dir\"", false, lit, why);
			doc.PushUndo();
			pin.Default.Set(lit);
			print.Edited = true;
			Check(doc.Commit(doc.FindMethod("Greeter.Hello()")) && doc.Text.Contains("\t\t\tConsole.WriteLine(@\"C:\\dir\");\n") &&
				PinValue.KindOf(pin.TypeName, pin.Default, pin.Name, fx.Service) == .Custom, "`@\"C:\\dir\"` typed: written as typed, shown as an expression");
			doc.Undo();
			Check(doc.Text == cPrint, "undo");

			// A char8* parameter takes a typed text; no type warning for the literal.
			const String cShow =
				"""
				using System;

				namespace Demo
				{
					class CStr
					{
						static void Show(char8* s)
						{
						}

						public void Run()
						{
						}
					}
				}

				""";
			SourceDocument cdoc = scope .();
			cdoc.LoadFromText(cShow, "CStr.bf");
			fx.Update(cdoc);
			cdoc.LoadFromText(cShow, "CStr.bf");
			let rg = cdoc.FindMethod("CStr.Run()").Graph;
			StringView[1] sName = .("s");
			StringView[1] cType = .("char8*");
			cdoc.PushUndo();
			let call = NodeFactory.StaticCall(rg, "Show", "", "CStr", true, sName, cType, "void");
			Check(PinValue.KindOf("char8*", call.FindArg(0).Default, "arg0", fx.Service) == .Text, "a placed call with a char8* pin: a text field");
			lit.Clear();
			PinValue.Write(.Text, "char8*", "C text", false, lit, why);
			call.FindArg(0).Default.Set(lit);
			rg.Connect(rg.Entry.Then, call.ExecIn);
			rg.ClearErrors();
			GraphValidator.Validate(rg);
			Check(rg.Errors.IsEmpty && rg.Warnings.IsEmpty, scope $"no error or warning for a text in a char8* pin ({rg.Errors.Count} / {rg.Warnings.Count})");
			Check(cdoc.Commit(cdoc.FindMethod("CStr.Run()")) && cdoc.Text.Contains("\t\t\tShow(\"C text\");\n"), "written `Show(\"C text\");`");
		}
	}
}
