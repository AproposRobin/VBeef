using System;
using System.Collections;
using System.IO;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Command-line test runner.
	///
	///   VisualBeefTests roundtrip [-out <dir>] [-v] <file-or-dir>...
	///       For every .bf file:
	///        1. Lexer is lossless (tokens + trivia reproduce the file).
	///        2. Graph -> code with no edits reproduces the file byte-for-byte.
	///        3. Forced regeneration (every node rewritten from the graph) parses back to an
	///           identical graph. With -out, the regenerated files are written for compiling.
	///   VisualBeefTests dump <file>     Prints the parsed structure.
	///   VisualBeefTests edits           Runs scripted graph-editing scenarios (and the factory ones).
	///   VisualBeefTests factory         Checks action-menu nodes read back from code unchanged.
	///   VisualBeefTests flow            Switch / flow-macro parsing, shapes, edits, refusals, and the call
	///                                   model (CallTests) (also part of `edits`).
	///   VisualBeefTests calls           Only the call model: Target / self / static, out / ref pins, GraphValidator.
	///   VisualBeefTests compile [-out <dir>] [-v]
	///       Code generator golden tests: edit graphs, commit, build the result with BeefBuild,
	///       run it and compare its output; plus graphs that must be refused (CompileTests.bf).
	///   VisualBeefTests catalog         Node catalog, attributes, type resolution, conversions,
	///                                   fuzzy search, corlib cache (CatalogTests).
	///   VisualBeefTests catalog-scale <lib-dir>   Index + search timings on a generated library.
	///   VisualBeefTests catalog-scale -root <dir> Opening a whole folder like the editor (background
	///                                   indexer, SDKs under the root as cached libraries), cold / warm.
	///   VisualBeefTests lifetime        Construct / Delete / Defer / Using / Result nodes and the lifetime
	///                                   rules (LifetimeTests; the Defer / Using bodies also run in `flow`).
	///   VisualBeefTests coverage [-notypes] [-v] <dir>...   What the graphs of real code contain (bodies
	///                                   with no text nodes, node kinds, text by construct).
	///   VisualBeefTests vocabulary [root]   No Unreal term in the string literals of the sources or in the docs, and
	///                                   no host product name anywhere in the sources, scripts or docs.
	///   VisualBeefTests hotkeys         Node hotkeys and favorites (defaults, conflicts, clear).
	///   VisualBeefTests update          The updater: signed descriptors, sequences, downloads, swap / restore.
	///   VisualBeefTests diagnostics     Compiler output parsing and error-line -> node mapping.
	///   VisualBeefTests debugmap [-v] <dir>...   The debugger's node <-> line map on a corpus (DebugTests).
	///   VisualBeefTests debug [-out <dir>] [-v]  Builds the Debuggee fixture and debugs it with Beef's engine.
	///   VisualBeefTests host [-lib <dir>] The host contract: command line, .vbproject, templates, attribute-declared
	///                                   node libraries, generated libraries through dependency paths (HostTests).
	///   VisualBeefTests loadall [-v] <dir>...   Opens every project file of a folder like the editor
	///                                   (index, libraries, side files, every graph laid out, a dry
	///                                   generation, layout text) and checks the graphs (LoadAllTests).
	///   VisualBeefTests textforms       Scope, const / ref locals, (.) casts, .() values, repeat, local
	///                                   functions, lambdas / delegates / events, payload switches,
	///                                   interpolated strings, statement attributes (TextFormTests).
	///   roundtrip -types ...            Same, with the TypeService (project + libraries) installed.
	///   VisualBeefTests savecheck [-v] <file-or-dir>...
	///   VisualBeefTests stress [-seed N] [-edits N] [-v] [file-or-dir]...
	///       For every .bf file: load + save without an edit is byte for byte, and after a graph
	///       edit / an added member variable every other member is still in the file (SaveCheckTests).
	///   VisualBeefTests inits [-v] [-noflip] <file-or-dir>...
	///       Every member variable's Ownership / Initial value read, written back byte for byte,
	///       flipped to another choice and back (InitTests); custom counts and top patterns per path.
	///   VisualBeefTests orphans [-v] <file-or-dir>...
	///       For every method: disconnect the body from the entry, save the layout, reload text +
	///       layout, compare the unconnected nodes, reconnect, and compare the rebuilt graph.
	class Program
	{
		static int sFiles;
		static int sMethods;
		static int sFailures;
		static int sBroken;
		static bool sVerbose;
		static String sOutDir = new .() ~ delete _;
		static String sRoot = new .() ~ delete _;

		public static int Main(String[] args)
		{
			if (args.Count == 0)
			{
				Console.WriteLine("usage: VisualBeefTests roundtrip [-out dir] [-v] <paths...> | dump <file> | edits");
				return 2;
			}
			if (args[0] == "dump")
			{
				String text = scope .();
				if (File.ReadAllText(args[1], text, true) case .Err)
					return 1;
				let unit = Parser.Parse(text);
				defer delete unit;
				String o = scope .();
				AstDump.DumpMembers(unit, unit.Members, 0, o);
				Console.Write(o);
				return 0;
			}
			if (args[0] == "edits")
			{
				int editResult = EditTests.Run();
				int factoryFailures = FactoryTests.Run();
				int flowFailures = FlowTests.Run();
				Console.WriteLine("total: edits {}, factory failures {}, flow failures {}", (editResult == 0) ? "ok" : "FAILED", factoryFailures, flowFailures);
				return (editResult == 0 && factoryFailures == 0 && flowFailures == 0) ? 0 : 1;
			}
			if (args[0] == "flow")
				return (FlowTests.Run() == 0) ? 0 : 1;
			if (args[0] == "textforms")
				return (TextFormTests.Run() == 0) ? 0 : 1;
			if (args[0] == "loadall")
				return LoadAllTests.Run(args);
			if (args[0] == "calls")
				return (CallTests.Run() == 0) ? 0 : 1;
			if (args[0] == "classes")
				return (ClassTests.Run() == 0) ? 0 : 1;
			if (args[0] == "inits")
				return InitTests.RunCorpus(args);
			if (args[0] == "savecheck")
				return SaveCheckTests.Run(args);
			if (args[0] == "stress")
				return StressTests.Run(args);
			if (args[0] == "safety")
				return (SafetyTests.Run() == 0) ? 0 : 1;
			if (args[0] == "parser")
				return (ParserTests.Run() == 0 && ClassTests.RunParser() == 0) ? 0 : 1;
			if (args[0] == "decls")
				return ParserTests.RunDecls(args);
			if (args[0] == "compile")
				return CompileTests.Run(args);
			if (args[0] == "coverage")
				return CoverageTests.Run(args);
			if (args[0] == "lifetime")
				return (LifetimeTests.Run() == 0) ? 0 : 1;
			if (args[0] == "host")
				return HostTests.Run(args);
			if (args[0] == "debugmap")
				return DebugTests.RunMap(args);
			if (args[0] == "debug")
				return DebugTests.RunSession(args);
			if (args[0] == "attachprobe")
				return DebugTests.RunProbe(args);
			if (args[0] == "hotkeys")
				return (HotkeyTests.Run() == 0) ? 0 : 1;
			if (args[0] == "update" && args.Count > 1 && args[1] == "-net")
				return (UpdateTests.RunNet() == 0) ? 0 : 1;
			if (args[0] == "update")
				return (UpdateTests.Run() == 0) ? 0 : 1;
			if (args[0] == "diagnostics")
				return (DiagnosticsTests.Run() == 0) ? 0 : 1;
			if (args[0] == "vocabulary")
				return (VocabularyTests.Run(args) == 0) ? 0 : 1;
			if (args[0] == "factory")
				return (FactoryTests.Run() == 0) ? 0 : 1;
			if (args[0] == "catalog")
				return (CatalogTests.Run() == 0) ? 0 : 1;
			if (args[0] == "catalog-scale")
			{
				if (args.Count > 2 && args[1] == "-root")
					return CatalogTests.ScaleRoot(args[2]);
				// Without a folder: VB_SCALE_LIB (a large generated library folder, docs/Testing.md).
				String libDir = scope .();
				if (args.Count > 1)
					libDir.Set(args[1]);
				else if (Environment.GetEnvironmentVariable("VB_SCALE_LIB", libDir) case .Err || libDir.IsEmpty)
				{
					Console.WriteLine("usage: VisualBeefTests catalog-scale <generated library folder> (or set VB_SCALE_LIB)");
					return 2;
				}
				return CatalogTests.Scale(libDir);
			}
			if (args[0] == "graph")
				return GraphDump(args[1]);
			if (args[0] == "orphans")
			{
				for (int i = 1; i < args.Count; i++)
				{
					if (args[i] == "-v")
						sVerbose = true;
					else if (Directory.Exists(args[i]))
						RunDir(args[i], true);
					else
						OrphanFile(args[i]);
				}
				Console.WriteLine("orphans: files={} methods={} failures={}", sFiles, sMethods, sFailures);
				return (sFailures == 0) ? 0 : 1;
			}
			if (args[0] == "bench")
			{
				String text = scope .();
				if (File.ReadAllText(args[1], text, true) case .Err)
					return 1;
				SourceDocument doc = scope .();
				let sw = scope System.Diagnostics.Stopwatch(true);
				doc.LoadFromText(text, args[1]);
				Console.WriteLine("load: {} ms, methods={}", sw.ElapsedMilliseconds, doc.Methods.Count);
				sw.Restart();
				for (let mg in doc.Methods)
				{
					if (mg.Graphable)
					{
						for (let n in mg.Graph.Nodes)
							n.Edited = true;
						doc.Commit(mg);
						break;
					}
				}
				Console.WriteLine("commit: {} ms", sw.ElapsedMilliseconds);
				return 0;
			}

			List<String> paths = scope .();
			bool withTypes = false;
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-out")
				{
					sOutDir.Set(args[++i]);
					continue;
				}
				if (args[i] == "-types")
				{
					withTypes = true;
					continue;
				}
				if (args[i] == "-v")
				{
					sVerbose = true;
					continue;
				}
				paths.Add(args[i]);
			}
			ProjectIndex typeIndex = null;
			TypeService types = null;
			defer { delete types; delete typeIndex; }
			for (let p in paths)
			{
				sRoot.Set(p);
				if (withTypes && Directory.Exists(p))
				{
					// The editor's setup: project index + resolver with corlib and dependencies.
					delete types;
					delete typeIndex;
					typeIndex = new .();
					typeIndex.Build(p);
					GraphBuilder.Index = typeIndex;
					types = new .(typeIndex);
					types.Install();
					types.Sync();
					Console.WriteLine("types: {} libraries in {:0.0} ms ({} from cache)", types.Libraries.Count, types.LibraryLoadMs, types.LibraryCacheHits);
				}
				if (Directory.Exists(p))
					RunDir(p);
				else
					RunFile(p);
			}
			GraphBuilder.Index = null;
			Console.WriteLine("files={} methods={} failures={} broken={}", sFiles, sMethods, sFailures, sBroken);
			return (sFailures == 0) ? 0 : 1;
		}

		static int GraphDump(StringView path)
		{
			SourceDocument doc = scope .();
			if (doc.Load(path) case .Err)
				return 1;
			for (let mg in doc.Methods)
			{
				String sig = scope .();
				GraphSignature(mg.Graph, sig);
				Console.WriteLine("== {}\n{}", mg.Key, sig);
			}
			return 0;
		}

		static void RunDir(StringView dir, bool orphans = false)
		{
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				if (path.EndsWith(".bf"))
				{
					if (orphans)
						OrphanFile(path);
					else
						RunFile(path);
				}
			}
			for (let entry in Directory.EnumerateDirectories(dir))
			{
				String path = scope .();
				entry.GetFilePath(path);
				RunDir(path, orphans);
			}
		}

		/// For every method: disconnect the whole body from the entry (Alt+click), save the
		/// layout, reload text + layout, compare the orphans, reconnect, and compare the graph
		/// the code then builds with the original one.
		static void OrphanFile(StringView path)
		{
			sFiles++;
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
			{
				Fail(path, "cannot read");
				return;
			}
			List<String> keys = scope .();
			defer { ClearAndDeleteItems!(keys); }
			{
				SourceDocument probe = scope .();
				probe.LoadFromText(text, path);
				for (let mg in probe.Methods)
				{
					if (!mg.Graphable || probe.FindMethod(mg.Key) != mg)
						continue;
					if (mg.Graph.ExecTarget(mg.Graph.Entry.Then) != null)
						keys.Add(new String(mg.Key));
				}
			}
			for (let key in keys)
			{
				sMethods++;
				SourceDocument doc = new .();
				defer delete doc;
				doc.LoadFromText(text, path);
				let g = doc.FindMethod(key).Graph;
				String sigFull = scope .();
				GraphSignature(g, sigFull);
				EditTests.PlaceAll(g);
				let head = g.ExecTarget(g.Entry.Then);
				float hx = head.X;
				float hy = head.Y;
				doc.PushUndo();
				g.Disconnect(g.FindLinkFrom(g.Entry.Then));
				doc.Commit(doc.FindMethod(key));
				String sigA = scope .();
				EditTests.OrphanSig(g, sigA);
				String layout = scope .();
				doc.GetLayoutText(layout);

				SourceDocument doc2 = new .();
				defer delete doc2;
				doc2.LoadFromText(doc.Text, path, layout);
				let mg2 = doc2.FindMethod(key);
				if (mg2 == null)
				{
					Fail(path, scope $"{key}: method gone after emptying it");
					continue;
				}
				let g2 = mg2.Graph;
				String sigB = scope .();
				EditTests.OrphanSig(g2, sigB);
				if (sigA != sigB)
				{
					Fail(path, scope $"{key}: orphans differ after reload ({EditTests.OrphanCount(g)} -> {EditTests.OrphanCount(g2)})");
					if (sVerbose)
						ShowDiff(sigA, sigB);
					continue;
				}
				Node head2 = null;
				for (let n in g2.Nodes)
					if (!n.IsPure && n.X == hx && n.Y == hy && n != g2.Entry)
						head2 = n;
				if (head2 == null)
				{
					Fail(path, scope $"{key}: head not found");
					continue;
				}
				doc2.PushUndo();
				g2.Connect(g2.Entry.Then, head2.ExecIn);
				if (!doc2.Commit(doc2.FindMethod(key)))
				{
					Refused(path, key, "reconnect commit", g2);
					continue;
				}
				SourceDocument doc3 = new .();
				defer delete doc3;
				doc3.LoadFromText(doc2.Text, path);
				let mg3 = doc3.FindMethod(key);
				String sigC = scope .();
				if (mg3 != null)
					GraphSignature(mg3.Graph, sigC);
				if (sigC != sigFull)
				{
					Fail(path, scope $"{key}: reconnected graph differs");
					if (sVerbose)
						ShowDiff(sigFull, sigC);
				}
			}
		}

		static void Fail(StringView path, StringView what)
		{
			sFailures++;
			Console.WriteLine("FAIL {}: {}", path, what);
		}

		/// Valid code must never be refused: a refusal on real sources is a false error (from
		/// GraphValidator or the generator), and it would also hide a regeneration difference.
		static void Refused(StringView path, StringView key, StringView what, Graph g)
		{
			String msg = scope .();
			for (let e in g.Errors)
			{
				let node = g.FindNode(e.NodeId);
				String title = scope .();
				node?.GetTitle(title);
				msg.AppendF("\n    {} (line {}): {}", title, (node != null) ? node.Line : 0, e.Message);
				if (sVerbose && node != null)
				{
					// The pins of the refused node and what feeds them (types as the graph holds them).
					for (let p in node.Inputs)
					{
						let src = g.DataSource(p);
						msg.AppendF("\n      in {} : {} = '{}'", p.Name, p.TypeName, p.Default);
						if (src != null)
						{
							let from = g.FindLinkTo(p).From;
							msg.AppendF(" <- {} [{}] {} : {}", src.Kind, src.Text, from.Name, from.TypeName);
						}
					}
				}
			}
			Fail(path, scope $"{what} of {key} was refused:{msg}");
		}

		/// A canonical description of a graph's semantics (ignores ids, positions, and text
		/// formatting).
		public static void GraphSignature(Graph g, String o)
		{
			KeyAssigner.Assign(g);
			List<Node> nodes = scope .();
			for (let n in g.Nodes)
				if (!n.Key.StartsWith("orphan"))
					nodes.Add(n);
			nodes.Sort(scope (a, b) => String.Compare(a.Key, b.Key, false));
			for (let n in nodes)
			{
				o.AppendF("{} {} [{}] [{}]{}{}{}{}", n.Key, n.Kind, n.Text, n.Text2, n.NullCond ? " ?." : "", n.Cascade ? " .." : "", n.Postfix ? " post" : "",
					(n.LeadingComments != null) ? " +lc" : "");
				if (n.Kind == .Call)
					o.AppendF(" {}{}", n.Binding, (n.Qualifier != null) ? scope:: $" q={n.Qualifier}" : "");
				o.Append('\n');
				for (let p in n.Inputs)
				{
					if (p.Kind != .Data)
						continue;
					let src = g.DataSource(p);
					StringView mode = p.IsRefArg ? "ref " : "";
					if (src != null)
						o.AppendF("  {}{} <- {}.{}{}\n", mode, p.Name, src.Key, g.FindLinkTo(p).From.Name, "");
					else
						o.AppendF("  {}{} = {}\n", mode, p.Name, p.Default);
				}
				for (let p in n.Outputs)
					if (p.IsOutArg)
						o.AppendF("  out {} -> {} ({} {})\n", p.Name, (p.Form == .Discard) ? "" : p.OutName, p.Form, p.OutDecl);
				if (n.TrailingComment != null)
					o.AppendF("  // {}\n", n.TrailingComment);
				for (let p in n.Outputs)
					if (p.EndComments != null)
						o.AppendF("  end {}: {}\n", p.Name, p.EndComments);
			}
		}

		static void RunFile(StringView path)
		{
			sFiles++;
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
			{
				Fail(path, "cannot read");
				return;
			}

			// 1. Lossless lexing
			{
				let unit = Parser.Parse(text);
				defer delete unit;
				String rebuilt = scope .();
				for (let tok in unit.Tokens)
					rebuilt.Append(StringView(unit.Text, tok.LeadStart, tok.TrailEnd - tok.LeadStart));
				if (rebuilt != text)
				{
					Fail(path, "lexer is not lossless");
					return;
				}
				// Valid sources must not produce Broken members.
				List<Member> all = scope .();
				List<Member> owners = scope .();
				unit.CollectMethods(all, owners);
				for (let m in all)
				{
					if (m.Kind != .Broken)
						continue;
					sBroken++;
					Console.WriteLine("BROKEN member in {}: {}", path, m.Error);
				}
			}

			SourceDocument doc = scope .();
			doc.LoadFromText(text, path);

			// 2. No-edit commit of every method reproduces the file exactly.
			{
				List<String> keys = scope .();
				for (let mg in doc.Methods)
					if (mg.Graphable)
						keys.Add(scope:: String(mg.Key));
				for (let key in keys)
				{
					let mg = doc.FindMethod(key);
					if (mg == null)
					{
						Fail(path, scope $"method {key} vanished");
						continue;
					}
					sMethods++;
					// Mark nothing; generation must reuse the original text.
					let graphBefore = mg.Graph;
					if (!doc.Commit(mg))
						Refused(path, key, "identity commit", graphBefore);
					// The live graph object survives a commit.
					let mgAfter = doc.FindMethod(key);
					if (mgAfter == null || !mgAfter.IsBuilt || mgAfter.Graph != graphBefore)
						Fail(path, scope $"commit replaced the graph of {key}");
					if (doc.Text != text)
					{
						Fail(path, scope $"identity commit changed text in {key}");
						if (sVerbose)
							ShowDiff(text, doc.Text);
						doc.LoadFromText(text, path);
					}
				}
			}

			// 3. Forced regeneration -> same graph.
			{
				SourceDocument original = scope .();
				original.LoadFromText(text, path);
				doc.LoadFromText(text, path);
				List<String> keys = scope .();
				for (let mg in doc.Methods)
					if (mg.Graphable)
						keys.Add(scope:: String(mg.Key));
				for (let key in keys)
				{
					let mg = doc.FindMethod(key);
					if (mg == null)
					{
						Fail(path, scope $"method {key} vanished after regeneration");
						continue;
					}
					for (let n in mg.Graph.Nodes)
						n.Edited = true;
					let g = mg.Graph;
					if (!doc.Commit(mg))
						Refused(path, key, "forced regeneration", g);
				}
				// The graphs of `doc` are the live ones (kept across commits); what matters is what
				// the regenerated text builds, so compare against a fresh parse of it.
				SourceDocument reparsed = scope .();
				reparsed.LoadFromText(doc.Text, path);
				for (let key in keys)
				{
					let before = original.FindMethod(key);
					let after = reparsed.FindMethod(key);
					let live = doc.FindMethod(key);
					if (before == null || after == null || live == null)
					{
						Fail(path, scope $"method {key} missing");
						continue;
					}
					String sigA = scope .();
					String sigB = scope .();
					String sigC = scope .();
					GraphSignature(before.Graph, sigA);
					GraphSignature(after.Graph, sigB);
					GraphSignature(live.Graph, sigC);
					if (sigA != sigB)
					{
						Fail(path, scope $"regenerated graph differs in {key}");
						if (sVerbose)
							ShowDiff(sigA, sigB);
					}
					else if (sigC != sigB)
					{
						Fail(path, scope $"live graph differs from its code in {key}");
						if (sVerbose)
							ShowDiff(sigC, sigB);
					}
				}
				if (!sOutDir.IsEmpty)
				{
					String rel = scope .(path);
					if (rel.StartsWith(sRoot))
						rel.Remove(0, sRoot.Length);
					if (rel.IsEmpty)
						Path.GetFileName(path, rel);
					String outPath = scope .();
					outPath.Append(sOutDir);
					if (!rel.StartsWith('/'))
						outPath.Append('/');
					outPath.Append(rel);
					String dir = scope .();
					Path.GetDirectoryPath(outPath, dir).IgnoreError(); // best effort: the Check on the write reports failure
					Directory.CreateDirectory(dir).IgnoreError();
					File.WriteAllText(outPath, doc.Text).IgnoreError();
				}
			}
		}

		public static void ShowDiff(StringView a, StringView b)
		{
			List<StringView> la = scope .();
			List<StringView> lb = scope .();
			for (let l in a.Split('\n')) la.Add(l);
			for (let l in b.Split('\n')) lb.Add(l);
			int i = 0;
			while (i < la.Count && i < lb.Count && la[i] == lb[i])
				i++;
			int ea = la.Count - 1;
			int eb = lb.Count - 1;
			while (ea > i && eb > i && la[ea] == lb[eb])
			{
				ea--;
				eb--;
			}
			Console.WriteLine("  --- first difference at line {}", i + 1);
			for (int k = Math.Max(0, i - 2); k <= Math.Min(ea, i + 12); k++)
				Console.WriteLine("  - {}", la[k]);
			for (int k = Math.Max(0, i - 2); k <= Math.Min(eb, i + 12); k++)
				Console.WriteLine("  + {}", lb[k]);
		}
	}
}
