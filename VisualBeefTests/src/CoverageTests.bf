using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests coverage [-notypes] [-v] <dir>...`: what the graphs of real code contain.
	///
	/// Loads every `.bf` file under each folder with the editor's setup (ProjectIndex +
	/// TypeService installed, unless -notypes), builds every method graph and counts:
	///  - method bodies with no Code node (a statement shown as text) and with neither a Code nor
	///    an Expression node (no text at all);
	///  - every node kind;
	///  - the Code / Expression nodes grouped by the construct they start with;
	///  - pin defaults (text typed into a pin) holding `scope ...`, `new ...`, a lambda, a `case`
	///    pattern test.
	/// This is the coverage probe of the 2026-10-10 production audit,
	/// kept as a command so the numbers can be measured again.
	static class CoverageTests
	{
		class Totals
		{
			public int Files;
			public int Members;
			public int Bodies;
			public int NoCode;
			public int NoText;
			public int Nodes;
			public int PinsWithType;
			public int DataInputs;
			public Dictionary<String, int> Kinds = new .() ~ DeleteDictionaryAndKeys!(_);
			public Dictionary<String, int> CodeGroups = new .() ~ DeleteDictionaryAndKeys!(_);
			public Dictionary<String, int> ExprGroups = new .() ~ DeleteDictionaryAndKeys!(_);
			public Dictionary<String, int> PinGroups = new .() ~ DeleteDictionaryAndKeys!(_);
			/// Problems a dry generation reports on code as read (the editor's first check).
			public Dictionary<String, int> Issues = new .() ~ DeleteDictionaryAndKeys!(_);
		}

		static void Count(Dictionary<String, int> d, StringView key)
		{
			if (d.TryGetAlt(key, var matchKey, var value))
				d[matchKey] = value + 1;
			else
				d[new String(key)] = 1;
		}

		/// The first word of a statement / expression text, ignoring leading comments.
		static void FirstWord(StringView text, String outWord)
		{
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			if (toks.IsEmpty || toks[0].Kind == .EOF)
				return;
			outWord.Append(StringView(text, toks[0].Start, toks[0].End - toks[0].Start));
		}

		static bool HasCaseTest(StringView text)
		{
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			for (int i < toks.Count - 1)
			{
				let t = StringView(text, toks[i].Start, toks[i].End - toks[i].Start);
				if (t == "case" && i > 0)
					return true;
			}
			return false;
		}

		static void Group(StringView text, String outGroup, bool statement)
		{
			String w = scope .();
			FirstWord(text, w);
			if (w == "scope" || w == "new" || w == "append" || w == "using" || w == "defer" || w == "delete" || w == "const" ||
				w == "switch" || w == "repeat" || w == "throw" || w == "static")
			{
				outGroup.Append(w);
				return;
			}
			if (text.Contains("=>"))
			{
				outGroup.Append("lambda");
				return;
			}
			if (HasCaseTest(text))
			{
				outGroup.Append("case pattern");
				return;
			}
			if (statement && w == "{")
			{
				outGroup.Append("block");
				return;
			}
			outGroup.Append("other");
		}

		public static int Run(String[] args)
		{
			bool withTypes = true;
			bool verbose = false;
			List<String> dirs = scope .();
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-notypes")
					withTypes = false;
				else if (args[i] == "-v")
					verbose = true;
				else
					dirs.Add(args[i]);
			}
			if (dirs.IsEmpty)
			{
				Console.WriteLine("usage: VisualBeefTests coverage [-notypes] [-v] <dir>...");
				return 2;
			}
			Totals all = scope .();
			let sw = scope System.Diagnostics.Stopwatch(true);
			for (let dir in dirs)
			{
				Totals t = scope .();
				ProjectIndex index = null;
				TypeService types = null;
				if (withTypes)
				{
					index = new .();
					index.Build(dir);
					GraphBuilder.Index = index;
					types = new .(index);
					types.Install();
					types.Sync();
				}
				RunDir(dir, t, all, verbose);
				GraphBuilder.Index = null;
				delete types;
				delete index;
				Console.WriteLine("{}: files={} bodies={} no Code node={} ({:0.0} %) no text node={} ({:0.0} %)", dir, t.Files, t.Bodies, t.NoCode,
					Pct(t.NoCode, t.Bodies), t.NoText, Pct(t.NoText, t.Bodies));
			}
			Console.WriteLine("coverage: files={} members={} bodies={}", all.Files, all.Members, all.Bodies);
			Console.WriteLine("  bodies with no Code node: {} ({:0.0} %)", all.NoCode, Pct(all.NoCode, all.Bodies));
			Console.WriteLine("  bodies with no Code and no Expression node: {} ({:0.0} %)", all.NoText, Pct(all.NoText, all.Bodies));
			Console.WriteLine("  nodes: {}; data inputs with a type: {} of {} ({:0.0} %)", all.Nodes, all.PinsWithType, all.DataInputs, Pct(all.PinsWithType, all.DataInputs));
			Print("  node kinds", all.Kinds);
			Print("  Code nodes by construct", all.CodeGroups);
			Print("  Expression nodes by construct", all.ExprGroups);
			Print("  pin texts by construct", all.PinGroups);
			Print("  checks on code as read (dry generation)", all.Issues);
			Console.WriteLine("  time: {} ms", sw.ElapsedMilliseconds);
			return 0;
		}

		static double Pct(int a, int b) => (b == 0) ? 0 : 100.0 * a / b;

		static void Print(StringView title, Dictionary<String, int> d)
		{
			List<(String key, int count)> rows = scope .();
			for (let kv in d)
				rows.Add((kv.key, kv.value));
			rows.Sort(scope (a, b) => (a.count != b.count) ? (b.count <=> a.count) : String.Compare(a.key, b.key, false));
			String line = scope .();
			for (let r in rows)
			{
				if (!line.IsEmpty)
					line.Append(", ");
				line.AppendF("{} {}", r.key, r.count);
			}
			Console.WriteLine("{}: {}", title, line);
		}

		static void RunDir(StringView dir, Totals t, Totals all, bool verbose)
		{
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				if (path.EndsWith(".bf"))
					RunFile(path, t, all, verbose);
			}
			for (let entry in Directory.EnumerateDirectories(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				RunDir(path, t, all, verbose);
			}
		}

		static void RunFile(StringView path, Totals t, Totals all, bool verbose)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return;
			t.Files++;
			all.Files++;
			SourceDocument doc = scope .();
			doc.LoadFromText(text, path);
			for (let mg in doc.Methods)
			{
				t.Members++;
				all.Members++;
				if (!mg.Graphable || mg.IsBroken)
					continue;
				t.Bodies++;
				all.Bodies++;
				let g = mg.Graph;
				int code = 0;
				int expr = 0;
				for (let n in g.Nodes)
				{
					all.Nodes++;
					String kind = scope .();
					n.Kind.ToString(kind);
					Count(all.Kinds, kind);
					if (n.Kind == .Code)
					{
						code++;
						String grp = scope .();
						Group(n.Text, grp, true);
						Count(all.CodeGroups, grp);
						if (verbose)
							Console.WriteLine("  code {}:{}: {}", path, n.Line, StringView(n.Text, 0, Math.Min(n.Text.Length, 100)));
					}
					else if (n.Kind == .Expr)
					{
						expr++;
						String grp = scope .();
						Group(n.Text, grp, false);
						Count(all.ExprGroups, grp);
						if (verbose)
							Console.WriteLine("  expr {}:{}: {}", path, n.Line, StringView(n.Text, 0, Math.Min(n.Text.Length, 100)));
					}
					for (let p in n.Inputs)
					{
						if (p.Kind != .Data)
							continue;
						all.DataInputs++;
						if (!p.TypeName.IsEmpty)
							all.PinsWithType++;
						if (p.Default.IsEmpty || g.FindLinkTo(p) != null)
							continue;
						String grp = scope .();
						Group(p.Default, grp, false);
						if (grp != "other")
						{
							Count(all.PinGroups, grp);
							if (verbose)
								Console.WriteLine("  pin {}:{}: {}", path, n.Line, StringView(p.Default, 0, Math.Min(p.Default.Length, 100)));
						}
					}
				}
				{
					// What the editor reports when the graph is first shown (nothing is written).
					CodeGen gen = scope .(g, "\t", true);
					String scratch = scope .();
					gen.GenerateBody("", scratch);
					for (int side < 2)
					{
						for (let e in (side == 0) ? g.Errors : g.Warnings)
						{
							String key = scope .();
							key.Append((side == 0) ? "error: " : "warning: ");
							key.Append(StringView(e.Message, 0, Math.Min(e.Message.Length, 40)));
							Count(all.Issues, key);
							if (verbose)
								Console.WriteLine("  {} {}:{}: {}", (side == 0) ? "error" : "warning", path, g.FindNode(e.NodeId)?.Line ?? 0, e.Message);
						}
					}
					g.ClearErrors();
				}
				if (code == 0)
				{
					t.NoCode++;
					all.NoCode++;
				}
				if (code == 0 && expr == 0)
				{
					t.NoText++;
					all.NoText++;
				}
			}
		}
	}
}
