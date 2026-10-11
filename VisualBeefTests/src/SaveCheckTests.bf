using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// "Nothing is written that would change behaviour" for whole files (docs/Files-and-Safety.md >
	/// Unparsed members are kept): a file is loaded from disk and saved, and
	///  1. with no edit, the file on disk is byte for byte what it was (also with members the
	///     parser could not read, and with a forced rewrite);
	///  2. after an edit of another member (a statement added to a function graph and committed,
	///     a member variable added), every other member is still in the file with its exact text.
	/// `safety` runs it on crafted files (one unreadable member each, and the 2026-10-11 report);
	/// `savecheck <paths>` runs it on every .bf file of a corpus (the roundtrip folders).
	static class SaveCheckTests
	{
		const String cDir = "vb_savecheck_tmp";
		static int sFailures;
		static int sFiles;
		static int sEdits;
		static bool sVerbose;

		static void Fail(StringView file, StringView what)
		{
			Console.WriteLine("  FAIL {}: {}", file, what);
			sFailures++;
		}

		/// Texts of every member that is not a namespace or type (those contain the edits),
		/// in source order, recursively.
		static void MemberTexts(CompilationUnit unit, List<Member> members, List<String> outTexts, List<String> outNames)
		{
			for (let m in members)
			{
				if ((m.Kind == .Namespace || m.Kind == .Type) && m.Members != null)
				{
					MemberTexts(unit, m.Members, outTexts, outNames);
					continue;
				}
				if (!m.HasSpan)
					continue;
				outTexts.Add(new String(unit.NodeText(m)));
				outNames.Add(new String(m.Name));
			}
		}

		static Member FirstClass(List<Member> members)
		{
			for (let m in members)
			{
				if (m.Kind == .Type && m.TypeKind != null && (m.TypeKind == "class" || m.TypeKind == "struct") && m.OpenBrace >= 0 && m.CloseBrace >= 0)
					return m;
				if ((m.Kind == .Namespace || m.Kind == .Type) && m.Members != null)
				{
					let inner = FirstClass(m.Members);
					if (inner != null)
						return inner;
				}
			}
			return null;
		}

		/// Every member text of `before` (except the edited function and the property holding it) is in `after`.
		static bool AllKept(List<String> before, StringView edited, StringView after, String outMissing)
		{
			for (int i < before.Count)
			{
				if (!edited.IsEmpty && before[i].Contains(edited))
					continue;
				if (after.IndexOf(before[i]) < 0)
				{
					outMissing.Set(before[i]);
					if (outMissing.Length > 80)
					{
						outMissing.RemoveToEnd(80);
						outMissing.Append("...");
					}
					return false;
				}
			}
			return true;
		}

		static String ReadAll(StringView path)
		{
			String s = new .();
			File.ReadAllText(path, s, true).IgnoreError();
			return s;
		}

		/// Writes `text` to a scratch file and runs both checks on it. `name` labels failures.
		/// Returns the number of failures it found.
		public static int CheckText(StringView name, StringView text)
		{
			int failuresBefore = sFailures;
			Directory.CreateDirectory(cDir).IgnoreError();
			String path = scope $"{cDir}/SaveCheck.bf";
			File.Delete(path).IgnoreError();
			File.Delete(scope $"{path}.bak").IgnoreError();
			File.Delete(scope $"{path}.vblayout").IgnoreError();
			if (File.WriteAllText(path, text) case .Err)
			{
				Fail(name, "cannot write the scratch file");
				return 1;
			}
			sFiles++;
			let original = ReadAll(path);
			defer delete original;

			// 1. No edit: a normal save writes nothing, a forced one writes the same bytes.
			{
				SourceDocument doc = scope .();
				if (doc.Load(path) case .Err)
				{
					Fail(name, "does not load");
					return 1;
				}
				// Opening every graph is what viewing does.
				for (let mg in doc.Methods)
					if ((mg.Graphable || mg.IsBroken) && mg.Graph == null)
						Fail(name, scope $"no graph for {mg.Key}");
				if (doc.TrySave() != .Saved)
					Fail(name, "unchanged save refused");
				if (doc.TrySave(true) != .Saved)
					Fail(name, "forced save refused");
				let disk = ReadAll(path);
				if (disk != original)
					Fail(name, "load + save without an edit changed the file");
				delete disk;
			}

			let unit = Parser.Parse(original);
			defer delete unit;
			List<String> texts = scope .();
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(texts); ClearAndDeleteItems!(names); }
			MemberTexts(unit, unit.Members, texts, names);
			String missing = scope .();

			// 2a. A statement added to one function graph and committed: every other member stays.
			{
				File.WriteAllText(path, original).IgnoreError();
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError();
				bool done = false;
				List<String> keys = scope .();
				defer { ClearAndDeleteItems!(keys); }
				for (let mg in doc.Methods)
					if (mg.Graphable)
						keys.Add(new String(mg.Key));
				// A commit or reload re-parses: the MethodGraph objects are replaced, so work by key.
				for (let key in keys)
				{
					let mg = doc.FindMethod(key);
					if (mg == null || !mg.Graphable || mg.Graph.ReadOnly || mg.Graph.Entry == null || mg.Graph.Entry.Then == null)
						continue;
					let g = mg.Graph;
					let first = g.ExecTarget(g.Entry.Then);
					let probe = NodeFactory.Code(g, "int vbSaveCheckProbe = 1;");
					g.Connect(g.Entry.Then, probe.ExecIn);
					if (first != null)
						g.Connect(probe.Then, first.ExecIn);
					String methodText = scope .(doc.Unit.NodeText(mg.Method));
					if (!doc.Commit(mg))
					{
						// A refused commit says why: an error on a node and a message (no silent no-op).
						if (mg.Graph.Errors.IsEmpty || doc.Messages.IsEmpty)
							Fail(name, scope $"the commit of {key} was refused without a reason");
						doc.Load(path).IgnoreError();
						continue;
					}
					if (doc.TrySave(true) != .Saved)
					{
						Fail(name, scope $"save after a graph edit of {key} refused: {doc.LastError}");
						break;
					}
					let disk = ReadAll(path);
					defer delete disk;

					if (!disk.Contains("vbSaveCheckProbe"))
						Fail(name, scope $"the graph edit of {key} is not in the file");
					else if (!AllKept(texts, methodText, disk, missing))
						Fail(name, scope $"after a graph edit of {key} a member is gone: {missing}");
					else
						sEdits++;
					done = true;
					break;
				}
				if (!done && sVerbose)
					Console.WriteLine("  (no committable function in {})", name);
			}

			// 2b. A member variable added to the first class: every member stays.
			{
				File.WriteAllText(path, original).IgnoreError();
				SourceDocument doc = scope .();
				doc.Load(path).IgnoreError();
				let type = FirstClass(doc.Unit.Members);
				if (type != null)
				{
					doc.AddField(type, "int", "vbSaveCheckField");
					if (doc.TrySave(true) != .Saved)
						Fail(name, scope $"save after adding a member variable refused: {doc.LastError}");
					else
					{
						let disk = ReadAll(path);
						defer delete disk;
						if (!disk.Contains("vbSaveCheckField"))
							Fail(name, "the added member variable is not in the file");
						else if (!AllKept(texts, "", disk, missing))
							Fail(name, scope $"after adding a member variable a member is gone: {missing}");
						else
							sEdits++;
					}
				}
			}
			if (sVerbose && sFailures == failuresBefore)
				Console.WriteLine("  ok   {}", name);
			return sFailures - failuresBefore;
		}

		static void CollectFiles(StringView path, List<String> outFiles)
		{
			if (File.Exists(path))
			{
				outFiles.Add(new String(path));
				return;
			}
			if (!Directory.Exists(path))
				return;
			for (let entry in Directory.EnumerateFiles(path))
			{
				String f = scope .();
				entry.GetFilePath(f);
				if (f.EndsWith(".bf", .OrdinalIgnoreCase))
					outFiles.Add(new String(f));
			}
			for (let entry in Directory.EnumerateDirectories(path))
			{
				String d = scope .();
				entry.GetFilePath(d);
				String dn = scope .();
				entry.GetFileName(dn);
				if (dn == "build" || dn == "recovery" || dn.StartsWith("."))
					continue;
				CollectFiles(d, outFiles);
			}
		}

		/// `savecheck [-v] <file-or-dir>...`
		public static int Run(String[] args)
		{
			sFailures = 0;
			sFiles = 0;
			sEdits = 0;
			sVerbose = false;
			FileSafety.ReadOnlyProject = false;
			bool keep = FileSafety.KeepBackup;
			FileSafety.KeepBackup = false;
			defer
			{
				FileSafety.KeepBackup = keep;
				Directory.DelTree(cDir).IgnoreError();
			}
			List<String> files = scope .();
			defer { ClearAndDeleteItems!(files); }
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v")
					sVerbose = true;
				else
					CollectFiles(args[i], files);
			}
			for (let f in files)
			{
				String text = scope .();
				if (File.ReadAllText(f, text, true) case .Err)
				{
					Fail(f, "cannot read");
					continue;
				}
				CheckText(f, text);
			}
			Console.WriteLine("savecheck: files={} edits={} failures={}", sFiles, sEdits, sFailures);
			return (sFailures == 0) ? 0 : 1;
		}

		/// Crafted files for `safety`: each has one member the parser cannot read (or a
		/// declaration error) between readable ones. Returns the failures.
		public static int RunCrafted(out int files, out int edits)
		{
			sFailures = 0;
			sFiles = 0;
			sEdits = 0;
			bool keep = FileSafety.KeepBackup;
			FileSafety.KeepBackup = false;
			defer
			{
				FileSafety.KeepBackup = keep;
				Directory.DelTree(cDir).IgnoreError();
			}
			for (let c in sCrafted)
				CheckText(c.name, c.text);
			files = sFiles;
			edits = sEdits;
			return sFailures;
		}

		/// The file from the 2026-10-11 report (before its `Run()` was deleted): `var Main()`.
		public const String cReport =
			"""
			using System;

			namespace TestVisual;

			class Program
			{
				public int Iteration = 0;
				public bool bRunning;
				public String ConsoleString = new .() ~ delete _;

				public static var Main()
				{
					Program Prog = new Program();
					defer delete Prog;
					Prog.Run();
				}

				public void Run()
				{
					return;
				}
			}
			""";

		static (StringView name, StringView text)[?] sCrafted = .(
			("report: var Main()", cReport),
			("a keyword as the return type", """
				namespace T
				{
					class C
					{
						public int mA = 1;
						public void Before() { mA = 2; }
						public default Bad(int a)
						{
							mA = 3;
						}
						public void After() { mA = 4; }
					}
				}

				"""),
			("var member variable", """
				class C
				{
					public var mX = 1;
					public void Use() { int y = 2; }
					public int Last() { return 1; }
				}

				"""),
			("unbalanced brackets in a body", """
				class C
				{
					public void Before() { }
					public void Open()
					{
						Foo(1;
						bar();
					}
					public void After() { int x = 1; }
				}

				"""),
			("missing } inside a method", """
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

				"""),
			("no name to recover", """
				class C
				{
					public int mA;
					public 42 = 7;
					public void After() { mA = 1; }
				}

				"""),
			("CRLF and a broken member", "class C\r\n{\r\n\tpublic void A() { int a = 1; }\r\n\tpublic default B(int x) { }\r\n\tpublic void D() { int d = 1; }\r\n}\r\n")
		);
	}
}
