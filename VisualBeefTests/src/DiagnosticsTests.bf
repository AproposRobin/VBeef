using System;
using System.Collections;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests diagnostics`: compiler output parsing (file:line:col) and the mapping of an
	/// error / warning line to the graph node that owns it (DiagnosticMap), including after edits
	/// that move or change the statement.
	static class DiagnosticsTests
	{
		static int sChecks;
		static int sFailures;

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

		const String cSample =
			"""
			using System;

			namespace Demo
			{
				class Player
				{
					public int mHealth = 100;

					public void TakeDamage(int amount)
					{
						mHealth -= amount;
						if (mHealth <= 0)
						{
							Die(amount);
						}
						Console.WriteLine("hit");
					}

					public void Die(int reason)
					{
						Console.WriteLine("Player died");
					}
				}
			}

			""";

		/// 1-based line of the first line holding `text`.
		static int32 LineOf(StringView source, StringView text)
		{
			int32 n = 1;
			for (let line in source.Split('\n'))
			{
				if (line.Contains(text))
					return n;
				n++;
			}
			return -1;
		}

		static Diagnostic Make(DiagnosticSeverity sev, int32 line)
		{
			Diagnostic d = new .();
			d.Severity = sev;
			d.Text.Set("message");
			d.Path.Set("Player.bf");
			d.Line = line;
			return d;
		}

		static void Parsing()
		{
			Console.WriteLine("output parsing");
			{
				let d = BuildOutput.Parse(@"ERROR: Unable to find 'Foo' at line 12:8 in C:\proj\src\Player.bf");
				defer delete d;
				Check(d != null && d.IsError, "BeefBuild ERROR line is an error");
				Check(d != null && d.Text == "Unable to find 'Foo'" && d.Path == @"C:\proj\src\Player.bf" && d.Line == 12 && d.Column == 8, "BeefBuild ERROR: text, path, line 12, column 8");
			}
			{
				let d = BuildOutput.Parse(@"[    ]****ERROR: Bad thing at line 3:1 in D:\a b\X.bf");
				defer delete d;
				Check(d != null && d.Path == @"D:\a b\X.bf" && d.Line == 3 && d.Column == 1 && d.Text == "Bad thing", "progress-bar prefix skipped, path with a space kept");
			}
			{
				let d = BuildOutput.Parse(@"WARNING: Unused variable 'x' at line 40:12 in C:\p\A.bf");
				defer delete d;
				Check(d != null && !d.IsError && d.Line == 40 && d.Column == 12, "BeefBuild WARNING line is a warning with line:col");
			}
			{
				let d = BuildOutput.Parse(@"C:\p\B.bf(7,15): error CS1002: ; expected");
				defer delete d;
				Check(d != null && d.IsError && d.Path == @"C:\p\B.bf" && d.Line == 7 && d.Column == 15 && d.Text == "; expected", "file(line,col): error code: text");
			}
			{
				let d = BuildOutput.Parse(@"C:\p\C.bf:21:4: warning: shadowed name");
				defer delete d;
				Check(d != null && !d.IsError && d.Path == @"C:\p\C.bf" && d.Line == 21 && d.Column == 4 && d.Text == "shadowed name", "file:line:col: warning: text (drive colon kept in the path)");
			}
			{
				let d = BuildOutput.Parse("ERROR: Build failed");
				defer delete d;
				Check(d != null && d.IsError && d.Path.IsEmpty && d.Line == 0, "an error without a location has no path");
			}
			Check(BuildOutput.Parse("ERROR-SOFT: Compile failed. Total build time: 1.23s") == null, "ERROR-SOFT summary is not a diagnostic");
			Check(BuildOutput.Parse("Compiling project VisualBeefCore") == null, "ordinary output is not a diagnostic");
			Check(BuildOutput.Parse("") == null, "empty line");
		}

		static void Mapping()
		{
			Console.WriteLine("line -> node mapping");
			SourceDocument doc = scope .();
			doc.LoadFromText(cSample, "Player.bf");

			// A statement line maps to that statement's node.
			let lineSub = LineOf(cSample, "mHealth -= amount;");
			let d1 = Make(.Error, lineSub);
			defer delete d1;
			Check(DiagnosticMap.Locate(doc, d1), "error on `mHealth -= amount;` lands on a node");
			Check(d1.MethodKey == "Player.TakeDamage(int)", "it belongs to Player.TakeDamage(int)");
			Check(d1.Where == "Player.TakeDamage", "where = Player.TakeDamage");
			let mg = doc.FindMethod("Player.TakeDamage(int)");
			let n1 = DiagnosticMap.Resolve(mg, d1);
			Check(n1 != null && n1.Line == lineSub && n1.LineEnd == lineSub, "resolved node covers exactly that line");
			Check(d1.NodeKey.Contains('#'), "node key is content-keyed (path#hash)");

			// A line inside a nested block maps to the innermost statement, not the `if`.
			let lineDie = LineOf(cSample, "Die(amount);");
			let d2 = Make(.Warning, lineDie);
			defer delete d2;
			Check(DiagnosticMap.Locate(doc, d2), "warning inside the if body lands on a node");
			let n2 = DiagnosticMap.Resolve(mg, d2);
			Check(n2 != null && n2.Kind == .Call && n2.Text.Contains("Die"), "innermost node: the Die call, not the Branch");

			// The `if` line: the smallest node on it, the condition (`<=`), not the whole Branch
			// (which spans the body too).
			let lineIf = LineOf(cSample, "if (mHealth <= 0)");
			let d3 = Make(.Error, lineIf);
			defer delete d3;
			DiagnosticMap.Locate(doc, d3);
			let n3 = DiagnosticMap.Resolve(mg, d3);
			Check(n3 != null && n3.Line == lineIf && n3.LineEnd == lineIf && n3.Kind != .Branch, "the if line maps to its one-line condition node, not the multi-line Branch");

			// The signature maps to the function entry.
			let lineSig = LineOf(cSample, "public void TakeDamage(int amount)");
			let d4 = Make(.Error, lineSig);
			defer delete d4;
			Check(DiagnosticMap.Locate(doc, d4), "signature line lands on a node");
			let n4 = DiagnosticMap.Resolve(mg, d4);
			Check(n4 != null && n4 == mg.Graph.Entry, "signature error goes to the entry node");

			// A field is outside every graph: document level, named by its type.
			let lineField = LineOf(cSample, "public int mHealth = 100;");
			let d5 = Make(.Error, lineField);
			defer delete d5;
			Check(!DiagnosticMap.Locate(doc, d5), "field error has no node");
			Check(d5.MethodKey.IsEmpty && d5.NodeKey.IsEmpty && d5.Where == "Player", "field error is document level, in Player");

			// Outside every type (the using line).
			let d6 = Make(.Error, 1);
			defer delete d6;
			Check(!DiagnosticMap.Locate(doc, d6) && d6.Where.IsEmpty, "line 1 (using) is document level with no type");

			// Another method in the same file.
			let lineDied = LineOf(cSample, "Console.WriteLine(\"Player died\");");
			let d7 = Make(.Error, lineDied);
			defer delete d7;
			DiagnosticMap.Locate(doc, d7);
			Check(d7.MethodKey == "Player.Die(int)", "second method: Player.Die(int)");

			// Edits after the compile: lines inserted above move every statement down; the node is
			// found again by its content key, not by the stale line number.
			String moved = scope .(cSample);
			moved.Replace("\tclass Player\n\t{\n", "\tclass Player\n\t{\n\t\t// added\n\t\t// two lines\n");
			doc.ApplyText(moved);
			let mgMoved = doc.FindMethod("Player.TakeDamage(int)");
			let n1b = DiagnosticMap.Resolve(mgMoved, d1);
			Check(n1b != null && n1b.Line == lineSub + 2, "after inserting two lines above, the error follows the statement (line +2)");
			let n2b = DiagnosticMap.Resolve(mgMoved, d2);
			Check(n2b != null && n2b.Kind == .Call && n2b.Text.Contains("Die"), "the warning still sits on the Die call");

			// The statement itself edited: the same structural path still finds it.
			String edited = scope .(moved);
			edited.Replace("Die(amount);", "Die(amount + 1);");
			doc.ApplyText(edited);
			let mgEdited = doc.FindMethod("Player.TakeDamage(int)");
			let n2c = DiagnosticMap.Resolve(mgEdited, d2);
			Check(n2c != null && n2c.Kind == .Call && n2c.Text.Contains("Die"), "after editing the call's argument (a node of its own) the call itself is still found by its content");

			// A node that no longer exists resolves to nothing (shown at document level).
			String removed = scope .(edited);
			removed.Replace("\t\t\tConsole.WriteLine(\"hit\");\n", "");
			let lineHit = LineOf(edited, "Console.WriteLine(\"hit\");");
			let d8 = Make(.Error, lineHit);
			defer delete d8;
			DiagnosticMap.Locate(doc, d8);
			let before = DiagnosticMap.Resolve(doc.FindMethod("Player.TakeDamage(int)"), d8);
			Check(before != null && before.Kind == .Call, "the WriteLine(\"hit\") statement is found before it is removed");
			doc.ApplyText(removed);
			let after = DiagnosticMap.Resolve(doc.FindMethod("Player.TakeDamage(int)"), d8);
			Check(after == null || !after.Text.Contains("WriteLine") || after.Line != lineHit, "after removing it, the diagnostic does not land on an unrelated node at the old line");

			// A return type typed into the header (the body text unchanged) reaches the kept graph:
			// `var` shows the declaration error on the entry, `void` clears it again.
			String viaVar = scope .(removed);
			viaVar.Replace("void TakeDamage(int amount)", "var TakeDamage(int amount)");
			doc.ApplyText(viaVar);
			let mgVar = doc.FindMethod("Player.TakeDamage(int)");
			Check(mgVar != null && mgVar.Graphable && mgVar.Graph.Entry.Error != null && mgVar.Graph.Entry.Text2 == "var", "a header edited to `var` (body unchanged) puts the declaration error on the kept graph");
			doc.ApplyText(removed);
			let mgVoid = doc.FindMethod("Player.TakeDamage(int)");
			Check(mgVoid != null && mgVoid.Graph.Entry.Error == null && mgVoid.Graph.Entry.Text2 == "void", "typed back to `void` clears it");
		}

		const String cStale =
			"""
			using System;

			namespace Demo
			{
				class Player
				{
					public int mHealth = 100;

					public void Tick()
					{
						mHealth = 1;
						Console.WriteLine(foo);
						mHealth = 2;
					}
				}
			}

			""";

		/// The WriteLine statement whose code mentions `word`.
		static Node FindCall(Graph g, StringView text, StringView word)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == text && n.Original != null && n.Original.Contains(word))
					return n;
			return null;
		}

		static Node FindSet(Graph g, StringView value)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Set && n.FindInput("value") != null && n.FindInput("value").Default == value)
					return n;
			return null;
		}

		/// Which nodes of the graph show the message (what GraphPanel draws: Resolve per frame).
		static int ShownOn(MethodGraph mg, Diagnostic d, out Node node)
		{
			node = DiagnosticMap.Resolve(mg, d);
			return (node != null) ? 1 : 0;
		}

		static Node NewWriteLine(Graph g, StringView arg)
		{
			StringView[1] names = .("value");
			StringView[1] types = .("String");
			let call = NodeFactory.Call(g, "Console.WriteLine", true, false, "", names, types, "void");
			call.FindInput("arg0").Default.Set(arg);
			return call;
		}

		/// The user's report (0.1.3): a node with a compile error is deleted and a new node is
		/// placed; the new node showed the deleted node's error. The message must stay with the
		/// node it was about and go nowhere when that node is gone.
		static void StaleErrors()
		{
			Console.WriteLine("node errors stay where they belong");
			const String key = "Player.Tick()";
			let line = LineOf(cStale, "Console.WriteLine(foo);");

			// Delete the erroring node, then place a new node at its place and one elsewhere.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cStale, "Player.bf");
				let g = doc.FindMethod(key).Graph;
				let d = Make(.Error, line);
				defer delete d;
				d.Text.Set("The name 'foo' does not exist in the current context");
				Check(DiagnosticMap.Locate(doc, d), "the error lands on a node");
				let x = FindCall(g, "WriteLine", "foo");
				Check(x != null && DiagnosticMap.Resolve(doc.FindMethod(key), d) == x, "it is shown on WriteLine(foo)");

				let set1 = FindSet(g, "1");
				let set2 = FindSet(g, "2");
				doc.PushUndo();
				g.RemoveNode(x);
				g.Connect(set1.Then, set2.ExecIn);
				doc.Commit(doc.FindMethod(key));
				Check(!doc.Text.Contains("WriteLine(foo)"), "WriteLine(foo) deleted");
				Check(ShownOn(doc.FindMethod(key), d, ?) == 0, "after the delete no node shows the error");
				Check(d.NodeGone, "the message knows its node is gone (Problems says so)");

				// A new node at the deleted node's place (between the two Sets).
				doc.PushUndo();
				let y = NewWriteLine(g, "\"ok\"");
				g.DisconnectPin(set1.Then);
				g.Connect(set1.Then, y.ExecIn);
				g.Connect(y.Then, set2.ExecIn);
				doc.Commit(doc.FindMethod(key));
				Check(doc.Text.Contains("mHealth = 1;\n\t\t\tConsole.WriteLine(\"ok\");\n\t\t\tmHealth = 2;"), "the new WriteLine(\"ok\") is written where the old one was");
				Check(ShownOn(doc.FindMethod(key), d, let onY) == 0, "the new node at the same place shows no error");
				Check(onY != y, "in particular not the new node");

				// A new node placed elsewhere (unconnected) and one at the end of the flow.
				doc.PushUndo();
				let z = NewWriteLine(g, "\"loose\"");
				z.X = 900;
				let w = NewWriteLine(g, "\"end\"");
				g.Connect(set2.Then, w.ExecIn);
				doc.Commit(doc.FindMethod(key));
				Check(ShownOn(doc.FindMethod(key), d, let onZ) == 0 && onZ != z && onZ != w, "new nodes elsewhere show no error either");

				// Undo back to before the delete: the very node comes back, with its error.
				doc.Undo();
				doc.Undo();
				doc.Undo();
				Check(doc.Text.Contains("Console.WriteLine(foo);"), "undo brings WriteLine(foo) back");
				let back = DiagnosticMap.Resolve(doc.FindMethod(key), d);
				Check(back != null && back.Kind == .Call && back.Original != null && back.Original.Contains("foo"), "and its error with it (until the next compile)");
				Check(!d.NodeGone, "it is no longer marked gone");
			}

			// Delete the erroring node: the statement that moves up into its place stays clean.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cStale, "Player.bf");
				let g = doc.FindMethod(key).Graph;
				let d = Make(.Error, line);
				defer delete d;
				DiagnosticMap.Locate(doc, d);
				let x = FindCall(g, "WriteLine", "foo");
				let set1 = FindSet(g, "1");
				let set2 = FindSet(g, "2");
				doc.PushUndo();
				g.RemoveNode(x);
				g.Connect(set1.Then, set2.ExecIn);
				doc.Commit(doc.FindMethod(key));
				Check(DiagnosticMap.Resolve(doc.FindMethod(key), d) != set2, "the neighbour that took the deleted statement's place does not inherit the error");
			}

			// Insert a node before the erroring one: the error stays on it.
			{
				SourceDocument doc = scope .();
				doc.LoadFromText(cStale, "Player.bf");
				let g = doc.FindMethod(key).Graph;
				let d = Make(.Error, line);
				defer delete d;
				DiagnosticMap.Locate(doc, d);
				let x = FindCall(g, "WriteLine", "foo");
				let set1 = FindSet(g, "1");
				doc.PushUndo();
				let y = NewWriteLine(g, "\"before\"");
				g.DisconnectPin(set1.Then);
				g.Connect(set1.Then, y.ExecIn);
				g.Connect(y.Then, x.ExecIn);
				doc.Commit(doc.FindMethod(key));
				Check(doc.Text.Contains("Console.WriteLine(\"before\");\n\t\t\tConsole.WriteLine(foo);"), "a node inserted before it");
				Check(DiagnosticMap.Resolve(doc.FindMethod(key), d) == x, "the error stays on WriteLine(foo), not on the inserted node");
				String reopenText = scope .(doc.Text);

				// Fixed (foo -> 1) in the graph: the old message stays on that node until the next
				// compile; the next compile (no messages) leaves no node with an error.
				doc.PushUndo();
				let arg = x.FindInput("arg0");
				g.DisconnectPin(arg);
				arg.Default.Set("1");
				x.Edited = true;
				doc.Commit(doc.FindMethod(key));
				Check(DiagnosticMap.Resolve(doc.FindMethod(key), d) == x, "edited in the graph: the node keeps its own message until the next compile");
				int errors = 0;
				for (let n in doc.FindMethod(key).Graph.Nodes)
					if (n.Error != null)
						errors++;
				Check(errors == 0, "no node carries an error of its own after the fix");

				// The same file reopened (a different graph object): found by content, moved.
				SourceDocument re = scope .();
				re.LoadFromText(reopenText, "Player.bf");
				let rx = DiagnosticMap.Resolve(re.FindMethod(key), d);
				Check(rx != null && rx.Kind == .Call && rx.Original != null && rx.Original.Contains("foo"), "in a rebuilt graph it is found again by what the statement says");
			}
		}

		public static int Run()
		{
			Parsing();
			Mapping();
			StaleErrors();
			Console.WriteLine("diagnostics checks: {}  failures: {}", sChecks, sFailures);
			return sFailures;
		}
	}
}
