using System;
using System.Collections;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=strings` on a project with a `Greeter` class: `Hello()` printing
	/// `Console.WriteLine("Hello from NewProject");`, `Show(int n)` printing a text, and `Paths()`
	/// printing a long verbatim string. Through the calls the UI makes: the print reads as
	/// WriteLine(StringView line) with a Message text field showing the text without quotes; text typed
	/// into it is written with the quotes and escapes; the verbatim string shows the Expression badge,
	/// its value cut with "..." before the badge at 100% and at a 1.5 zoom; an int wired into a print
	/// switches it to WriteLine(Object obj); Properties > Call > Overload lists the overloads and
	/// choosing WriteLine(Object obj) for a text writes a cast; undo restores the file.
	/// Captures `strings-first`, `strings-bare`, `strings-typed`, `strings-badge`, `strings-badge-zoom`,
	/// `strings-overloads` (docs/Testing.md > Verifying the UI).
	extension EditorApp
	{
		int mStStep;
		int mStWait;
		String mStPath = new .() ~ delete _;
		String mStSaved = new .() ~ delete _;

		SourceDocument StDoc => FindDoc(mStPath);

		MethodGraph StOpen(StringView key)
		{
			let doc = StDoc;
			let mg = (doc != null) ? doc.FindMethod(key) : null;
			if (mg != null)
				OpenTab(mg);
			return CurrentMethod;
		}

		void StSelect(Node n, int32 zoomLevel = Canvas.DefaultZoomLevel)
		{
			let tab = CurrentTab;
			if (tab == null || n == null)
				return;
			tab.SelectedNodes.Clear();
			tab.SelectedNodes.Add(n.Id);
			mSelClassActive = false;
			mSelVarActive = false;
			tab.ZoomLevel = zoomLevel;
			float s = Look.Scale;
			tab.CenterOn(n.X + 160 * s, n.Y + 40 * s);
			tab.NeedsFocus = false;
			Panels.Focus(Panels.PropertiesId);
			mStatus.Clear();
		}

		static Pin StParam(Graph g, StringView name)
		{
			for (let p in g.Entry.Outputs)
				if (p.Kind == .Data && p.Label == name)
					return p;
			return null;
		}

		/// The document's text (line breaks as `\n`) contains `part`.
		bool StHas(StringView part)
		{
			let doc = StDoc;
			if (doc == null)
				return false;
			String t = scope .(doc.Text);
			t.Replace("\r\n", "\n");
			return t.Contains(part);
		}

		/// Ctrl+Z on the file (what the shortcut does).
		bool StUndo()
		{
			let doc = StDoc;
			if (doc == null || !doc.CanUndo)
				return false;
			if (!GroupUndo(doc, false))
				doc.Undo();
			UpdateTitle();
			return true;
		}

		/// The badge was drawn this frame and the value text ends before it.
		bool StBadgeClear(String outNote)
		{
			let gp = mGraphPanel;
			outNote.AppendF("value ends at {:0.0}, badge starts at {:0.0}", gp.ExpressionValueRight, gp.ExpressionBadgeX);
			return gp.ExpressionBadgeX > 0 && gp.ExpressionValueRight > 0 && gp.ExpressionValueRight <= gp.ExpressionBadgeX - 2;
		}

		bool SelfTestStrings()
		{
			if (mStWait > 0)
			{
				mStWait--;
				return false;
			}
			const String cHello = "Greeter.Hello()";
			const String cShow = "Greeter.Show(int)";
			const String cPaths = "Greeter.Paths()";
			let step = mStStep++;
			switch (step)
			{
			case 0:
				for (let f in Index.Files)
				{
					let doc = OpenFile(f.Path, false);
					if (doc != null && doc.FindMethod(cHello) != null)
					{
						mStPath.Set(f.Path);
						break;
					}
				}
				let mg = StOpen(cHello);
				SelfTestCheck(mg != null && StDoc != null, "strings 1: Greeter.Hello opened");
				if (mg == null)
					return true;
				mStSaved.Set(StDoc.Text);
				StSelect(FindNodeOf(mg.Graph, .Call, "WriteLine"));
			case 1:
				// The first frame after opening the function.
				if (!SelfTestShot("strings-first"))
				{
					mStStep--;
					return false;
				}
				mStWait = 3;
			case 2:
				let mg = StOpen(cHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let pin = print?.FindArg(0);
				SelfTestCheck(pin != null && pin.TypeName == "StringView" && pin.Label == "Message" && pin.Default == "\"Hello from NewProject\"",
					scope $"strings 2: the template's print is WriteLine(StringView line), pin Message ({(pin != null) ? pin.TypeName : "none"} {(pin != null) ? pin.Label : ""})");
				if (pin == null)
					return true;
				let kind = PinValue.KindOf(pin.TypeName, pin.Default, pin.Name, TypeService.Current);
				String shown = scope .();
				PinValue.Display(kind, pin.TypeName, pin.Default, shown);
				SelfTestCheck(kind == .Text && shown == "Hello from NewProject", scope $"strings 2: a text field showing the text without quotes ({shown})");
				SelfTestCheck(print.Binding == .Static && print.FindInput("target") == null && print.Qualifier == "Console",
					"strings 2: static: no Receiver pin, the subtitle says Receiver is Console");
				String sig = scope .();
				CallOverloads.PinSignature(print, sig);
				SelfTestCheck(CallOverloads.Count(mg.Graph, print, TypeService.Current) >= 2 && sig == "WriteLine(StringView)",
					scope $"strings 2: the subtitle names the overload {sig}");
			case 3:
				if (!SelfTestShot("strings-bare"))
				{
					mStStep--;
					return false;
				}
			case 4:
				// What the field does when typing ends: the text with quotes and escapes.
				let mg = StOpen(cHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let pin = print.FindArg(0);
				String lit = scope .();
				String why = scope .();
				PinValue.Write(.Text, pin.TypeName, "say \"hi\" \\ done", false, lit, why);
				BeginEdit();
				pin.Default.Set(lit);
				print.Edited = true;
				RefitCall(mg.Graph, print);
				CommitCurrent();
				mStWait = 3;
			case 5:
				let mg = StOpen(cHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let pin = print.FindArg(0);
				String shown = scope .();
				PinValue.Display(.Text, pin.TypeName, pin.Default, shown);
				SelfTestCheck(StHas("\t\t\tConsole.WriteLine(\"say \\\"hi\\\" \\\\ done\");\n") && shown == "say \"hi\" \\ done" && pin.TypeName == "StringView",
					scope $"strings 3: typed `say \"hi\" \\ done`, written with quotes and escapes, the field shows it as typed ({shown})");
				StSelect(print);
				mStWait = 3;
			case 6:
				if (!SelfTestShot("strings-typed"))
				{
					mStStep--;
					return false;
				}
				SelfTestCheck(StUndo() && StDoc.Text == mStSaved, "strings 3: undo restores the text");
			case 7:
				// The Expression badge: a verbatim string is an expression, cut before the badge.
				let mg = StOpen(cPaths);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let pin = print?.FindArg(0);
				SelfTestCheck(pin != null && PinValue.KindOf(pin.TypeName, pin.Default, pin.Name, TypeService.Current) == .Custom && pin.Default.StartsWith("@\""),
					"strings 4: a verbatim string in the Message pin is an expression (badge, read-only)");
				mGraphPanel.ExpressionBadgeX = 0;
				mGraphPanel.ExpressionValueRight = 0;
				StSelect(print);
				mStWait = 3;
			case 8:
				String note = scope .();
				SelfTestCheck(StBadgeClear(note), scope $"strings 4: the value ends before the Expression badge at 100% ({note})");
			case 9:
				if (!SelfTestShot("strings-badge"))
				{
					mStStep--;
					return false;
				}
				let mg = StOpen(cPaths);
				mGraphPanel.ExpressionBadgeX = 0;
				mGraphPanel.ExpressionValueRight = 0;
				StSelect(FindNodeOf(mg.Graph, .Call, "WriteLine"), 15); // zoom 1.5
				mStWait = 3;
			case 10:
				String note = scope .();
				SelfTestCheck(StBadgeClear(note), scope $"strings 4: and at a 1.5 zoom ({note})");
			case 11:
				if (!SelfTestShot("strings-badge-zoom"))
				{
					mStStep--;
					return false;
				}
				StSelect(FindNodeOf(StOpen(cPaths).Graph, .Call, "WriteLine"));
			case 12:
				// The tab of Show in front first: a commit writes the function of the tab in front.
				StSelect(FindNodeOf(StOpen(cShow).Graph, .Call, "WriteLine"));
				mStWait = 3;
			case 13:
				// An int wired into a print: the drop is allowed and the print takes WriteLine(Object obj).
				let mg = StOpen(cShow);
				let g = mg.Graph;
				let print = FindNodeOf(g, .Call, "WriteLine");
				let n = StParam(g, "n");
				let pin = print?.FindArg(0);
				SelfTestCheck(pin != null && n != null && !Graph.CanConnectTyped(n, pin) && CallOverloads.CouldTake(g, pin, n.TypeName, TypeService.Current),
					"strings 5: an int dropped on the Message pin is accepted (another overload takes it)");
				if (pin == null || n == null)
					return true;
				BeginEdit();
				g.Connect(n, pin);
				RefitCall(g, print);
				CommitCurrent();
				mStWait = 3;
			case 14:
				let mg = StOpen(cShow);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				let pin = print.FindArg(0);
				SelfTestCheck(pin.TypeName == "Object" && pin.Label == "Message" && mg.Graph.IsLinked(pin) && StHas("\t\t\tConsole.WriteLine(n);\n") && mg.Graph.Errors.IsEmpty,
					scope $"strings 5: the print became WriteLine(Object obj), written `Console.WriteLine(n);` ({pin.TypeName})");
				// Properties > Call > Overload, opened.
				StSelect(print);
				SelfTestOpenOverloads = true;
				mStWait = 4;
			case 15:
				SelfTestCheck(SelfTestOverloadRows >= 2, scope $"strings 6: Properties > Call > Overload lists the overloads ({SelfTestOverloadRows})");
			case 16:
				if (!SelfTestShot("strings-overloads"))
				{
					mStStep--;
					return false;
				}
				SelfTestCloseOverloads = true;
				mStWait = 2;
			case 17:
				SelfTestCheck(StUndo() && StDoc.Text == mStSaved, "strings 5: undo removes the wire");
				StSelect(FindNodeOf(StOpen(cHello).Graph, .Call, "WriteLine"));
				mStWait = 3;
			case 18:
				// Choosing WriteLine(Object obj) for a text writes a cast.
				let mg = StOpen(cHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				if (ChooseOverload(mg, print, "WriteLine(Object obj)"))
					CommitCurrent();
				mStWait = 3;
			case 19:
				let mg = StOpen(cHello);
				let print = FindNodeOf(mg.Graph, .Call, "WriteLine");
				SelfTestCheck(StHas("\t\t\tConsole.WriteLine((Object)\"Hello from NewProject\");\n") && print?.FindArg(0)?.TypeName == "Object",
					"strings 6: choosing WriteLine(Object obj) writes `Console.WriteLine((Object)\"Hello from NewProject\");`");
				SelfTestCheck(StUndo() && StDoc.Text == mStSaved, "strings 6: undo restores the file");
			default:
				return true;
			}
			return false;
		}
	}
}
