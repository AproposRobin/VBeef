using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;
using VisualBeef.Syntax;

namespace VisualBeef.Tests
{
	/// The 2026-10-12 owner requests (docs/Editor-UI.md#dragging-onto-pins,
	/// docs/Classes-and-Members.md#in-the-editor): a variable dragged onto a pin becomes a Get wired
	/// into an input or a Set fed by an output (VariableDrop), a drop the types refuse changes
	/// nothing, and undo removes the node and its wires in one step (RunEdits, run by `edits`).
	/// The Add Variable dialog's type: the picker's container row, a typed type it does not list,
	/// and the preview line that is exactly what Create writes (RunClasses, run by `classes`).
	static class DragVarTests
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

		static void CheckHas(SourceDocument doc, StringView want, StringView what)
		{
			bool ok = doc.Text.Contains(want);
			Check(ok, what);
			if (!ok)
				Console.WriteLine(scope $"  --- wanted `{want}` in:\n{doc.Text}");
		}

		const String cShop =
			"""
			using System;

			namespace Demo
			{
				class Shop
				{
					public int mCount = 0;
					public float mPrice = 1.5f;
					public String mName = "shop";

					public int Add(int a, int b)
					{
						return a + b;
					}

					public void Run()
					{
						int total = 0;
						Console.WriteLine("start");
						Add(1, 2);
						Console.WriteLine("done");
					}
				}
			}

			""";

		static Node FindCall(Graph g, StringView name)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == name)
					return n;
			return null;
		}

		static Graph RunGraph(SourceDocument doc) => doc.FindMethod("Shop.Run()").Graph;

		/// Edits through VariableDrop, each in its own undo step, as the editor's drop does it.
		public static void RunEdits()
		{
			Console.WriteLine("Scenario 26: variables dropped on pins (Get into an input, Set from an output, refusals, undo)");
			SourceDocument doc = scope .();
			doc.LoadFromText(cShop, "Shop.bf");
			String original = scope .(doc.Text);
			var g = RunGraph(doc);
			int baseNodes = g.Nodes.Count;
			int baseLinks = g.Links.Count;
			var add = FindCall(g, "Add");
			Check(add != null && add.FindInput("arg0") != null && add.Result != null, "the fixture: Run calls Add with two inputs and a Return Value");
			if (add == null || add.FindInput("arg0") == null || add.Result == null)
				return;
			String why = scope .();

			// 1: a member variable onto an input: a Get wired into it.
			Check(VariableDrop.Fits(g, add.FindInput("arg0"), "int", null, why), "mCount (int) fits Add's int input");
			doc.PushUndo();
			let get = VariableDrop.Place(g, add.FindInput("arg0"), "mCount", "int", null, why);
			Check(get != null && get.Kind == .Get && get.Text == "mCount" && g.FindLinkTo(add.FindInput("arg0"))?.From == get.Result,
				"onto an input: a Get of mCount, its value wired into the pin");
			int32 getId = (get != null) ? get.Id : 0;
			doc.Commit(doc.FindMethod("Shop.Run()"));
			CheckHas(doc, "\t\t\tAdd(mCount, 2);\n", "written: Add(mCount, 2);");
			String afterGet = scope .(doc.Text);

			// 2: undo is one step: the node and its wire go, the text is as loaded.
			doc.Undo();
			g = RunGraph(doc);
			bool getGone = true;
			for (let n in g.Nodes)
				if (n.Id == getId)
					getGone = false;
			Check(getGone && g.Nodes.Count == baseNodes && g.Links.Count == baseLinks && doc.Text == original, "undo once: the Get and its wire are gone, the text is as loaded");
			doc.Redo();
			Check(doc.Text == afterGet, "redo: Add(mCount, 2); again");

			// 3: a type that does not fit is refused, with the reason; nothing changes.
			g = RunGraph(doc);
			add = FindCall(g, "Add");
			int nodesBefore = g.Nodes.Count;
			int linksBefore = g.Links.Count;
			why.Clear();
			let refused = VariableDrop.Place(g, add.FindInput("arg1"), "mName", "String", null, why);
			Check(refused == null && !why.IsEmpty && g.Nodes.Count == nodesBefore && g.Links.Count == linksBefore,
				scope $"mName (String) onto an int input: refused, nothing placed ({why})");
			why.Clear();
			Check(!VariableDrop.Fits(g, add.FindInput("arg1"), "float", null, why) && why.Contains("cast"), scope $"mPrice (float) onto an int input: refused, a cast is needed ({why})");
			why.Clear();
			Check(!VariableDrop.Fits(g, add.ExecIn, "int", null, why) && !why.IsEmpty, scope $"onto a flow pin: refused ({why})");
			why.Clear();
			Check(!VariableDrop.Fits(g, add.Result, "String", null, why) && !why.IsEmpty, scope $"a String variable set from an int output: refused ({why})");
			Check(VariableDrop.Fits(g, add.Result, "float", null, null), "a float variable set from an int output: fits (int widens to float)");

			// 4: a local variable onto an output of a statement: a Set fed by it, in the flow right after it.
			doc.PushUndo();
			why.Clear();
			let set = VariableDrop.Place(g, add.Result, "total", "int", null, why);
			Check(set != null && set.Kind == .Set && g.FindLinkTo(set.FindInput("value"))?.From == add.Result && g.ExecTarget(add.Then) == set,
				"onto an output: a Set of total fed by the Return Value, run right after Add");
			Check(set != null && g.ExecTarget(set.Then) != null && g.ExecTarget(set.Then).Kind == .Call, "the statement after Add now follows the Set");
			doc.Commit(doc.FindMethod("Shop.Run()"));
			{
				int iAdd = doc.Text.IndexOf("Add(mCount, 2)");
				int iSet = doc.Text.IndexOf("\t\t\ttotal = ");
				int iDone = doc.Text.IndexOf("\"done\"");
				Check(iAdd >= 0 && iSet > iAdd && iDone > iSet, "written: Add's value set into total, before the last print");
				if (!(iAdd >= 0 && iSet > iAdd && iDone > iSet))
					Console.WriteLine(doc.Text);
			}
			String afterSet = scope .(doc.Text);
			doc.Undo();
			Check(doc.Text == afterGet, "undo once: the Set and its wires are gone (the Get stays)");
			doc.Redo();
			Check(doc.Text == afterSet, "redo: the Set is back");

			// 5: onto a value node's output (the Get of step 1): the Set runs before the statement using it.
			g = RunGraph(doc);
			Node mCountGet = null;
			for (let n in g.Nodes)
				if (n.Kind == .Get && n.Text == "mCount")
					mCountGet = n;
			Check(mCountGet != null, "the Get of mCount is on the Sheet");
			if (mCountGet != null)
			{
				doc.PushUndo();
				let set2 = VariableDrop.Place(g, mCountGet.Result, "total", "int", null, why);
				add = FindCall(g, "Add");
				Check(set2 != null && g.ExecTarget(set2.Then) == add, "onto a value node's output: the Set runs right before Add, which uses the value");
				doc.Commit(doc.FindMethod("Shop.Run()"));
				int iSet = doc.Text.IndexOf("total = mCount;");
				int iAdd = doc.Text.IndexOf("Add(mCount, 2)");
				Check(iSet >= 0 && iAdd > iSet, "written: total = mCount; before the call");
				if (!(iSet >= 0 && iAdd > iSet))
					Console.WriteLine(doc.Text);
				doc.Undo();
				Check(doc.Text == afterSet, "undo once: back to the text before the drop");
			}

			// 6: the Set's Variable pin names what is set: a variable dropped there is refused.
			g = RunGraph(doc);
			Node anySet = null;
			for (let n in g.Nodes)
				if (n.Kind == .Set)
					anySet = n;
			why.Clear();
			Check(anySet != null && !VariableDrop.Fits(g, anySet.FindInput("target"), "int", null, why) && !why.IsEmpty, scope $"onto a Set's Variable pin: refused ({why})");

			// 7: an input that is wired already: the dropped variable's Get takes its place.
			add = FindCall(g, "Add");
			doc.PushUndo();
			let get2 = VariableDrop.Place(g, add.FindInput("arg0"), "total", "int", null, why);
			int linksTo = 0;
			for (let l in g.Links)
				if (l.To == add.FindInput("arg0"))
					linksTo++;
			Check(get2 != null && linksTo == 1 && g.FindLinkTo(add.FindInput("arg0")).From == get2.Result, "onto a wired input: the new Get replaces the wire (one wire into the pin)");
			doc.Commit(doc.FindMethod("Shop.Run()"));
			CheckHas(doc, "Add(total, 2)", "written: Add(total, 2)");
			doc.Undo();
			Check(doc.Text == afterSet, "undo once: the old wire is back");

			// 8: a read-only Sheet takes nothing.
			g = RunGraph(doc);
			add = FindCall(g, "Add");
			g.ReadOnly = true;
			why.Clear();
			Check(!VariableDrop.Fits(g, add.FindInput("arg1"), "int", null, why) && !why.IsEmpty, "a read-only Sheet: refused");
			g.ReadOnly = false;
		}

		/// The Add Variable dialog's type: the picker's container row and typed types, and the preview.
		public static void RunClasses()
		{
			Console.WriteLine("---- Add Variable: the type picker and the preview line");
			{
				String el = scope .();
				TypeRules.SplitContainer("List<int>", el, let c1);
				Check(el == "int" && c1 == 2, "List<int>: element int, container List");
				el.Clear();
				TypeRules.SplitContainer(" Foo[] ", el, let c2);
				Check(el == "Foo" && c2 == 1, "Foo[]: element Foo, container Array");
				el.Clear();
				TypeRules.SplitContainer("int?", el, let c3);
				Check(el == "int" && c3 == 3, "int?: element int, container Nullable");
				el.Clear();
				TypeRules.SplitContainer("Dictionary<String, int>", el, let c4);
				Check(el == "Dictionary<String, int>" && c4 == 0, "a typed Dictionary<String, int> stays as typed (Single)");
				StringView[?] round = .("bool", "List<Shop>", "float[]", "char8?", "Dictionary<int, List<String>>");
				bool allBack = true;
				for (let t in round)
				{
					String e = scope .();
					TypeRules.SplitContainer(t, e, let c);
					String back = scope .();
					TypeRules.JoinContainer(e, c, back);
					if (back != t)
					{
						allBack = false;
						Console.WriteLine("  {} -> {} ({})", t, back, c);
					}
				}
				Check(allBack, "split and joined back: the same text for five types");
				String joined = scope .();
				TypeRules.JoinContainer("bool", 2, joined);
				Check(joined == "List<bool>", "bool with the List container: List<bool>");
			}
			{
				// A type the picker does not list, typed into its search box: taken when it fits a member.
				TypeScope sc = default;
				sc.InType = true;
				String why = scope .();
				Check(TypeSlotRules.Check("Dictionary<String, int>", .Member, sc, why), "typed Dictionary<String, int>: taken for a member variable");
				why.Clear();
				Check(!TypeSlotRules.Check("void", .Member, sc, why) && !why.IsEmpty, scope $"typed void: refused with the reason ({why})");
				why.Clear();
				Check(!TypeSlotRules.Check("var", .Member, sc, why) && !why.IsEmpty, "typed var: refused for a member variable");
			}
			{
				// The preview follows the pick and is the line Create writes.
				String line = scope .();
				SourceDocument.FieldDeclarationText("bool", "bRunning", "", false, line);
				Check(line == "public bool bRunning;", scope $"preview of bool bRunning: {line}");
				line.Clear();
				SourceDocument.FieldDeclarationText("List<int>", "mItems", " = new .() ~ delete _", true, line);
				Check(line == "public static List<int> mItems = new .() ~ delete _;", scope $"preview of a static owned list: {line}");

				SourceDocument doc = scope .();
				doc.LoadFromText(cShop, "Shop.bf");
				Member FindShop()
				{
					List<Member> types = scope .();
					doc.Unit.CollectTypes(types);
					for (let t in types)
						if (t.Name == "Shop")
							return t;
					return null;
				}
				let shop = FindShop();
				Check(shop != null, "the fixture has Shop");
				if (shop != null)
				{
					String preview = scope .();
					SourceDocument.FieldDeclarationText("bool", "bRunning", "", false, preview);
					Check(doc.AddField(shop, "bool", "bRunning") && doc.Text.Contains(scope $"\t\t{preview}\n"), "Create writes the preview line: public bool bRunning;");
					preview.Clear();
					SourceDocument.FieldDeclarationText("float", "mRate", " = 2.5f", false, preview);
					Check(doc.AddField(FindShop(), "float", "mRate", "2.5f") && doc.Text.Contains(scope $"\t\t{preview}\n"), "Create writes the preview line: public float mRate = 2.5f;");
					doc.Undo();
					doc.Undo();
					Check(doc.Text == cShop, "undo twice: the two variables are gone");
				}
			}
		}
	}
}
