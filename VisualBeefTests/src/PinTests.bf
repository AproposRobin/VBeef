using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// The typed value rules of unwired input pins (PinValue) and the one Switch node whose
	/// switched type can change (NodeFactory.SetSwitchType). Run as part of `flow`.
	static class PinTests
	{
		public static int Failures;
		public static int Checks;

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

		const String cSample =
			"""
			using System;

			namespace Demo
			{
				enum Mode { Idle, Run, Jump }

				class Foo
				{
				}

				class Host
				{
					public void Pick(Mode m)
					{
						switch (m)
						{
						case .Idle:
							Console.WriteLine("idle");
						default:
							Console.WriteLine("other");
						}
					}

					public void PickInt(int x)
					{
						switch (x)
						{
						case 1:
							Console.WriteLine("one");
						case 2, 3:
							Console.WriteLine("few");
						}
					}
				}
			}
			""";

		static PinValueKind K(StringView type, StringView def, TypeService ts, StringView pin = "arg0") => PinValue.KindOf(type, def, pin, ts);

		public static void Run()
		{
			Console.WriteLine("Pins: typed value rules and the one Switch node");
			ProjectIndex index = scope .();
			TypeService ts = new .(index);
			ts.AutoLoadLibraries = false;
			ts.Install();
			let oldIndex = GraphBuilder.Index;
			GraphBuilder.Index = index;
			defer
			{
				GraphBuilder.Index = oldIndex;
				delete ts;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}
			{
				let unit = Parser.Parse(cSample);
				index.Update("Pins.bf", unit);
				delete unit;
			}
			ts.Sync();

			// ---- which control
			Check(K("bool", "", ts) == .Bool && K("bool", "true", ts) == .Bool && K("bool", "flag", ts) == .Custom, "bool: checkbox, an expression is Custom");
			Check(K("Mode", "", ts) == .Enum && K("Mode", ".Run", ts) == .Enum && K("Mode", "Mode.Run", ts) == .Enum && K("Mode", "m", ts) == .Custom, "enum: dropdown for .Member and Enum.Member, a variable is Custom");
			Check(K("String", "\"hi\"", ts) == .Text && K("StringView", "", ts) == .Text && K("String", "name", ts) == .Custom, "text: plain literal is a text field, an expression is Custom");
			Check(K("int", "5", ts) == .Number && K("float", "1.5f", ts) == .Number && K("int", "0xFF", ts) == .Number && K("int", "a + 1", ts) == .Custom, "numbers: literals are fields, an expression is Custom");
			Check(K("char8", "'a'", ts) == .Char && K("char32", "", ts) == .Char && K("char8", "c", ts) == .Custom, "characters: one-character field");
			Check(K("Foo", "", ts) == .None && K("Foo", "null", ts) == .None && K("Foo*", "default", ts) == .None && K("Foo", "Foo()", ts) == .Custom, "classes and pointers: no editor, null/default dim");
			Check(K("Foo", "x", ts, "target") == .Expr && K("T", "x", ts) == .Expr && K("", "x", ts) == .Expr, "receivers and unknown types stay expression text");

			// ---- reading and writing
			String lit = scope .();
			String why = scope .();
			Check(PinValue.Write(.Text, "String", "say \"hi\"\n", false, lit, why) && lit == "\"say \\\"hi\\\"\\n\"", scope $"text: quotes added and escaped ({lit})");
			String disp = scope .();
			PinValue.Display(.Text, "String", lit, disp);
			Check(disp == "say \"hi\"\n", "text: quotes stripped and escapes resolved on read");
			lit.Clear();
			Check(PinValue.Write(.Number, "uint8", "300", false, lit, why) == false && why.Contains("does not fit uint8") && lit.IsEmpty, scope $"uint8 refuses 300 ({why})");
			why.Clear();
			Check(PinValue.Write(.Number, "int", "1.5", false, lit, why) == false && why.Contains("no decimals"), scope $"int refuses decimals ({why})");
			why.Clear();
			Check(PinValue.Write(.Number, "uint", "-3", false, lit, why) == false && why.Contains("negative"), scope $"uint refuses a negative ({why})");
			why.Clear();
			Check(PinValue.Write(.Number, "int", "abc", false, lit, why) == false, "int refuses text");
			lit.Clear();
			Check(PinValue.Write(.Number, "float", "1.5", false, lit, why) && lit == "1.5f", scope $"float gets the f suffix ({lit})");
			lit.Clear();
			Check(PinValue.Write(.Number, "float", "2", false, lit, why) && lit == "2.0f", scope $"float from a whole number ({lit})");
			lit.Clear();
			Check(PinValue.Write(.Number, "double", "2", false, lit, why) && lit == "2.0", scope $"double ({lit})");
			disp.Clear();
			PinValue.Display(.Number, "float", "1.5f", disp);
			Check(disp == "1.5", "the suffix is not shown");
			lit.Clear();
			why.Clear();
			Check(PinValue.Write(.Char, "char8", "x", false, lit, why) && lit == "'x'", "char8: 'x'");
			lit.Clear();
			Check(!PinValue.Write(.Char, "char8", "ab", false, lit, why), "char: two characters refused");
			lit.Clear();
			Check(PinValue.Write(.Enum, "Mode", "Run", false, lit, why) && lit == ".Run", "enum: written as .Member");
			disp.Clear();
			PinValue.Display(.Enum, "Mode", "Mode.Run", disp);
			Check(disp == "Run", "enum: Mode.Run reads back as Run");
			List<String> ms = scope .();
			PinValue.Members("Mode", ts, ms);
			Check(ms.Count == 3 && ms[0] == "Idle" && ms[2] == "Jump", "enum members come from the index");
			ClearAndDeleteItems!(ms);

			// ---- switch type rules
			TypeScope sc = default;
			sc.InType = true;
			sc.IsEnumType = scope (n) => n == "Mode";
			String sw1 = scope .();
			Check(TypeSlotRules.Check("int", .SwitchValue, sc, sw1) && TypeSlotRules.Check("String", .SwitchValue, sc, sw1) &&
				TypeSlotRules.Check("char8", .SwitchValue, sc, sw1) && TypeSlotRules.Check("Mode", .SwitchValue, sc, sw1), "a switch can be on int, String, char8 and an enum");
			sw1.Clear();
			Check(!TypeSlotRules.Check("float", .SwitchValue, sc, sw1) && !TypeSlotRules.Check("Foo", .SwitchValue, sc, sw1) && !TypeSlotRules.Check("bool", .SwitchValue, sc, sw1), "not on float, bool or a class");

			// ---- the Switch node
			SourceDocument doc = scope .();
			doc.LoadFromText(cSample, "Pins.bf");
			String before = scope .(doc.Text);
			var mg = doc.FindMethod("Host.Pick(Mode)");
			var sw = Find(mg.Graph);
			Check(sw != null && NodeFactory.SwitchType(sw) == "Mode", scope $"an existing switch reads its type from the switched value ({(sw == null) ? "?" : NodeFactory.SwitchType(sw)})");
			Check(sw != null && NodeFactory.SwitchMembersStale(sw, ts), "the enum switch is missing two members");
			doc.PushUndo();
			String r = scope .();
			Check(NodeFactory.SetSwitchType(mg.Graph, sw, "Mode", ts, r), "Update members works");
			Check(sw.FindOutput("case0").Label == ".Idle" && sw.FindOutput("case1").Label == ".Run" && sw.FindOutput("case2").Label == ".Jump", "one exec output per member, existing case kept first");
			Check(!NodeFactory.SwitchMembersStale(sw, ts), "nothing is stale after the update");
			Check(doc.Commit(mg), "commit");
			Check(doc.Text.Contains("case .Run:") && doc.Text.Contains("case .Jump:") && doc.Text.Contains("default:"), "the Beef has case .A / .B / default");
			if (!doc.Text.Contains("case .Jump:"))
				Console.WriteLine("{}", doc.Text);
			SourceDocument fresh = scope .();
			fresh.LoadFromText(doc.Text, "Pins2.bf");
			let fsw = Find(fresh.FindMethod("Host.Pick(Mode)").Graph);
			Check(fsw != null && fsw.Outputs.Count == sw.Outputs.Count && NodeFactory.SwitchType(fsw) == "Mode" && !NodeFactory.SwitchMembersStale(fsw, ts), "re-reading gives the same switch");

			// Switch on int: the enum cases do not fit, one starter case appears.
			mg = doc.FindMethod("Host.Pick(Mode)");
			sw = Find(mg.Graph);
			doc.PushUndo();
			Check(NodeFactory.SetSwitchType(mg.Graph, sw, "int", ts, r) && sw.FindOutput("case0").Label == "0" && sw.FindOutput("case1") == null, "to int: enum cases dropped, `0` starts");
			Check(!NodeFactory.SetSwitchType(mg.Graph, sw, "float", ts, r) && !r.IsEmpty, scope $"float is refused ({r})");

			// Int cases survive a change to another number type; to String they go.
			var mg2 = doc.FindMethod("Host.PickInt(int)");
			var sw2 = Find(mg2.Graph);
			doc.PushUndo();
			Check(NodeFactory.SetSwitchType(mg2.Graph, sw2, "uint8", ts, r) && sw2.FindOutput("case0").Label == "1" && sw2.FindOutput("case1").Label == "2, 3", "int cases stay on a change to uint8");
			Check(NodeFactory.SetSwitchType(mg2.Graph, sw2, "String", ts, r) && sw2.FindOutput("case0").Label == "\"\"" && sw2.FindOutput("case1") == null, "to String: the cases are replaced with an empty text case");
			Check(doc.Commit(mg2) && doc.Text.Contains("case \"\":"), "the Beef has case \"\":");
			if (!doc.Text.Contains("case \"\":"))
				Console.WriteLine("{}", doc.Text);
			mg2 = doc.FindMethod("Host.PickInt(int)");
			sw2 = Find(mg2.Graph);
			Check(NodeFactory.SetSwitchType(mg2.Graph, sw2, "char8", ts, r) && sw2.FindOutput("case0").Label == "'a'", "to char8: 'a'");
		}

		static Node Find(Graph g)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Switch)
					return n;
			return null;
		}
	}
}
