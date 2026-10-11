using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using VisualBeef.Syntax;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Catalog;

namespace VisualBeef.Tests
{
	/// Node catalog, attributes, type resolution, conversions and search (`VisualBeefTests catalog`).
	static class CatalogTests
	{
		/// corlib of the Beef install: `C:\Program Files\BeefLang\BeefLibs\corlib` on Windows,
		/// LibraryIndex.BeefLibsDir + `/corlib` elsewhere (VB_BEEF_LIBS or the BeefBuild on PATH).
		static String CorlibDir
		{
			get
			{
#if BF_PLATFORM_WINDOWS
				return @"C:\Program Files\BeefLang\BeefLibs\corlib";
#else
				if (sCorlibDir.IsEmpty)
				{
					LibraryIndex.BeefLibsDir(sCorlibDir);
					sCorlibDir.Append("/corlib");
				}
				return sCorlibDir;
#endif
			}
		}
		static String sCorlibDir = new .() ~ delete _;

		static int sPass;
		static int sFail;

		static void Check(bool ok, StringView what)
		{
			if (ok)
				sPass++;
			else
			{
				sFail++;
				Console.WriteLine("  FAIL {}", what);
			}
		}

		static void CheckEq(StringView actual, StringView expected, StringView what)
		{
			if (actual == expected)
				sPass++;
			else
			{
				sFail++;
				Console.WriteLine("  FAIL {}: got \"{}\", expected \"{}\"", what, actual, expected);
			}
		}

		static void Here(String outDir, String path = Compiler.CallerFilePath)
		{
			Path.GetDirectoryPath(path, outDir).IgnoreError(); // ...\VisualBeefTests\src
		}

		static void FixtureDir(StringView name, String outDir)
		{
			String src = scope .();
			Here(src);
			Path.GetDirectoryPath(src, outDir).IgnoreError(); // ...\VisualBeefTests
			outDir.AppendF("{0}fixtures{0}{1}", Path.DirectorySeparatorChar, name);
		}

		static void TestCacheDir(String outDir)
		{
			String src = scope .();
			Here(src);
			String tests = scope .();
			Path.GetDirectoryPath(src, tests).IgnoreError();
			Path.GetDirectoryPath(tests, outDir).IgnoreError(); // worktree root
			outDir.AppendF("{0}build{0}vbtest-cache", Path.DirectorySeparatorChar);
			if (!Directory.Exists(outDir))
			{
				String build = scope .();
				Path.GetDirectoryPath(outDir, build).IgnoreError();
				Directory.CreateDirectory(build).IgnoreError();
				Directory.CreateDirectory(outDir).IgnoreError();
			}
		}

		static SymbolStore sCorlib ~ delete _;

		/// corlib from the test cache (parsed on the first run).
		static SymbolStore Corlib()
		{
			if (sCorlib != null)
				return sCorlib;
			LibraryRef lib = scope .();
			lib.Name.Set("corlib");
			lib.Dir.Set(CorlibDir);
			sCorlib = LibraryIndex.Load(lib);
			return sCorlib;
		}

		/// A spec by menu label (or display name) from a catalog; null when absent.
		static NodeSpec FindSpec(NodeCatalog cat, StringView label, NodeEntryKind kind = (NodeEntryKind)255)
		{
			for (int si < cat.Stores.Count)
			{
				let sc = cat.Stores[si];
				for (int ei < sc.Entries.Count)
				{
					let e = ref sc.Entries[ei];
					if (kind != (NodeEntryKind)255 && e.Kind != kind)
						continue;
					let display = sc.Str(e.Display);
					if (!label.StartsWith(display))
						continue;
					NodeSpec spec = new .();
					cat.GetSpec(NodeCatalog.MakeId(si, ei), spec);
					if (spec.Label == label || spec.DisplayName == label)
						return spec;
					delete spec;
				}
			}
			return null;
		}

		static int CountLabel(NodeCatalog cat, StringView display)
		{
			int n = 0;
			for (let sc in cat.Stores)
				for (let e in sc.Entries)
					if (sc.Str(e.Display) == display)
						n++;
			return n;
		}

		public static int Run()
		{
			sPass = 0;
			sFail = 0;
			let total = scope Stopwatch(true);
			String cache = scope .();
			TestCacheDir(cache);
			LibraryIndex.sCacheDirOverride.Set(cache);

			Console.WriteLine("attributes");
			TestAttributes();
			Console.WriteLine("literals and conversions");
			TestLiterals();
			TestConversions();
			Console.WriteLine("fuzzy ranking");
			TestRanking();
			Console.WriteLine("corlib cache");
			TestCorlibCache();
			Console.WriteLine("attributed catalog");
			TestAttributedCatalog();
			Console.WriteLine("plain catalog, #if dedupe, context");
			TestPlainCatalog();
			TestPrebuiltAndIncremental();
			Console.WriteLine("type resolution in graphs");
			TestGraphTypes();
			Console.WriteLine("wires: type check and wildcards");
			TestWires();
			Console.WriteLine("pin colours");
			TestColours();
			Console.WriteLine("library discovery");
			TestDiscovery();
			Console.WriteLine("merged category tree");
			TestMergedCategories();

			LibraryIndex.sCacheDirOverride.Clear();
			Console.WriteLine("catalog checks: {} passed, {} failed ({:0} ms)", sPass, sFail, total.Elapsed.TotalMilliseconds);
			return sFail;
		}

		static void TestMergedCategories()
		{
			// Two sources (corlib, an SDK) contribute System, interleaved with another top level.
			List<String> cats = scope .();
			defer { ClearAndDeleteItems!(cats); }
			for (let c in StringView[?]("System|IO", "MyMod|IO", "System|Collections", "System | IO", "System|IO|File", "MyMod|IO|File", "System", "System|IO|File.Open", "System|IO|File"))
				cats.Add(new String(c));
			let root = MergedCategory.Build(cats);
			defer delete root;
			CheckEq(scope $"{root.Children.Count}", "2", "merge: one System row and one MyMod row");
			CheckEq(root.Children[0].Name, "System", "merge: first-appearance order (System)");
			CheckEq(root.Children[1].Name, "MyMod", "merge: first-appearance order (MyMod)");
			let sys = root.Children[0];
			CheckEq(scope $"{sys.Children.Count}", "2", "merge: System holds IO and Collections");
			CheckEq(sys.Children[0].Path, "System|IO", "merge: System|IO full path");
			CheckEq(root.Children[1].Children[0].Path, "MyMod|IO", "merge: same leaf under another parent keeps its own path");
			Check(sys.Children[0] !== root.Children[1].Children[0], "merge: System.IO and MyMod.IO are different rows");
			CheckEq(scope $"{sys.Children[0].Cats.Count}", "2", "merge: both spellings of System|IO feed one row");
			CheckEq(scope $"{sys.Cats.Count}", "1", "merge: a namespace that is also a category of its own keeps its items");
			let file = sys.Children[0].Children[0];
			CheckEq(file.Name, "File", "merge: nested leaf");
			CheckEq(sys.Children[0].Children[1].Name, "File.Open", "merge: a dotted type name is one segment, not a namespace");
			List<String> paths = scope .();
			root.CollectPaths(paths);
			bool unique = true;
			for (int i < paths.Count)
				for (int j = i + 1; j < paths.Count; j++)
					if (paths[i] == paths[j])
						unique = false;
			Check(unique, "merge: every row path is distinct (distinct ImGui IDs)");
		}

		static void TestAttributes()
		{
			List<AttrInfo> attrs = scope .();
			defer { ClearAndDeleteItems!(attrs); }
			AttributeParser.Parse("[Pure, Node(\"Math|Vector\", DisplayName=\"Lerp (Vector)\", Keywords=\"a, b\", Pure=true)] [VisualBeef.ExposeAttribute(Min=0, Max=1.5f)]", attrs);
			Check(attrs.Count == 3, "three attributes");
			if (attrs.Count == 3)
			{
				CheckEq(attrs[0].Name, "Pure", "attr 0 name");
				CheckEq(attrs[1].Name, "Node", "attr 1 name");
				CheckEq(attrs[1].Get("Category", 0), "Math|Vector", "positional category");
				CheckEq(attrs[1].Get("DisplayName"), "Lerp (Vector)", "named string with parens");
				CheckEq(attrs[1].Get("Keywords"), "a, b", "string with comma");
				Check(attrs[1].GetBool("Pure"), "bool arg");
				CheckEq(attrs[2].Name, "Expose", "namespace + Attribute suffix stripped");
				Check(attrs[2].GetNumber("Max") == 1.5, "number with suffix");
			}
			ClearAndDeleteItems!(attrs);
			AttributeParser.Parse("[Node(Tooltip=\"say \\\"hi\\\"\\n\")]", attrs);
			if (attrs.Count == 1)
				CheckEq(attrs[0].Get("Tooltip"), "say \"hi\"\n", "escapes");

			// Parser keeps attribute text on members and parameters.
			let unit = Parser.Parse("class A { [Node(Category=\"X\")] public void F([Pin(Name=\"Alpha\")] float t = 0.5f, int b) {} }");
			defer delete unit;
			let type = unit.Members[0];
			let f = type.Members[0];
			CheckEq(f.Attributes ?? "", "[Node(Category=\"X\")]", "member attribute text");
			Check(f.Params.Count == 2, "two params");
			if (f.Params.Count == 2)
			{
				CheckEq(f.Params[0].Attributes ?? "", "[Pin(Name=\"Alpha\")]", "param attribute text");
				CheckEq(f.Params[0].Type, "float", "param type without attribute");
				CheckEq(f.Params[0].Name, "t", "param name");
				CheckEq(f.Params[0].Default ?? "", "0.5f", "param default");
			}

			String sum = scope .();
			DocComment.Summary("<summary>Adds two\n numbers.</summary>\n<param name=\"a\">First</param>", sum);
			CheckEq(sum, "Adds two numbers.", "doc summary");
			String pdoc = scope .();
			DocComment.Param("<summary>x</summary>\n<param name=\"a\">First\n one</param>", "a", pdoc);
			CheckEq(pdoc, "First one", "doc param");
		}

		static void Lit(StringView text, StringView expected)
		{
			String t = scope .();
			TypeRules.LiteralType(text, t);
			CheckEq(t, expected, scope $"literal {text}");
		}

		static void TestLiterals()
		{
			Lit("1", "int");
			Lit("1.0", "double");
			Lit("1.0f", "float");
			Lit("1e5", "double");
			Lit("2d", "double");
			Lit("1u", "uint");
			Lit("1L", "int64");
			Lit("1UL", "uint64");
			Lit("0xFF", "int");
			Lit("0xFFu", "uint");
			Lit("0b1010", "int");
			Lit("1'000'000", "int");
			Lit("'c'", "char8");
			Lit("'\\u{1F600}'", "char32");
			Lit("\"s\"", "String");
			Lit("$\"x{a}\"", "String");
			Lit("@\"c:\\x\"", "String");
			Lit("true", "bool");
			Lit("null", "null");
		}

		static void Conv(StringView from, StringView to, Conversion expected)
		{
			String why = scope .();
			let c = TypeRules.CanConvert(from, to, why);
			Check(c == expected, scope $"{from} -> {to}: got {c}, expected {expected} {why}");
		}

		static void TestConversions()
		{
			Conv("int", "int", .Exact);
			Conv("int32", "int64", .Implicit);
			Conv("int8", "int", .Implicit);
			Conv("uint8", "int16", .Implicit);
			Conv("int64", "int32", .Refused);
			Conv("int", "uint", .Refused);
			Conv("int", "float", .Implicit);
			Conv("float", "double", .Implicit);
			Conv("double", "float", .Refused);
			Conv("float", "int", .Refused);
			Conv("char8", "char32", .Implicit);
			Conv("String", "StringView", .Implicit);
			Conv("StringView", "String", .Refused);
			Conv("char8*", "StringView", .Implicit);
			Conv("bool", "int", .Refused);
			Conv("int", "bool", .Refused);
			Conv("int", "String", .Refused);
			Conv("int", "Object", .Implicit);
			Conv("null", "String", .Implicit);
			Conv("null", "int", .Refused);
			Conv("int", "int?", .Implicit);
			Conv("int?", "int", .Refused);
			Conv("T", "int", .Unchecked);
			Conv("int", "T", .Unchecked);
			Conv("", "int", .Unchecked);
			Conv("List<int>", "List<T>", .Implicit);
			Conv("List<int>", "List<float>", .Refused);
			Conv("int[]", "Span<int>", .Implicit);
			Conv("Foo*", "void*", .Implicit);
			// Same simple name, different types: array ranks and sizes, other namespaces.
			Conv("int[]", "int[,]", .Refused);
			Conv("int[]", "int[4]", .Refused);
			Conv("int[]", "int[]", .Exact);
			Conv("UI.Button", "Physics.Button", .Unchecked);
			Conv("ref int", "int", .Exact);
			String why = scope .();
			TypeRules.CanConvert("float", "int", why);
			Check(why.Contains("cast"), "reason mentions the cast");
		}

		static void TestRanking()
		{
			List<StringView> w = scope .();
			w.Add("get");
			let prefix = NodeCatalog.ScoreKey("get actor location getactorlocation", "Get Actor Location", w);
			let wordStart = NodeCatalog.ScoreKey("set target get mode settargetgetmode", "Set Target Get Mode", w);
			let substring = NodeCatalog.ScoreKey("budget budget", "Budget", w);
			w.Clear();
			w.Add("gal");
			let acronym = NodeCatalog.ScoreKey("get actor location getactorlocation", "Get Actor Location", w);
			w.Clear();
			w.Add("gtn");
			let fuzzy = NodeCatalog.ScoreKey("get actor location getactorlocation", "Get Actor Location", w);
			let none = NodeCatalog.ScoreKey("set mode setmode", "Set Mode", w);
			Check(prefix > wordStart, "prefix beats word start");
			Check(wordStart > substring, "word start beats substring");
			Check(acronym > substring, "acronym (gal = Get Actor Location) beats substring");
			Check(substring > fuzzy && fuzzy > 0, "substring beats fuzzy, fuzzy matches");
			w.Clear();
			w.Add("get");
			w.Add("actor");
			let inOrder = NodeCatalog.ScoreKey("get actor location", "Get Actor Location", w);
			let reordered = NodeCatalog.ScoreKey("actor get location", "Actor Get Location", w);
			Check(inOrder > reordered, "words in the typed order rank first");
			Check(none == 0, "no match scores 0");
			String words = scope .();
			NodeCatalog.Words("GetHTTPCode", words);
			CheckEq(words, "Get HTTP Code", "display words");
			words.Clear();
			NodeCatalog.Words("mHealth", words);
			CheckEq(words, "Health", "m prefix dropped");
		}

		static void TestCorlibCache()
		{
			LibraryRef lib = scope .();
			lib.Name.Set("corlib");
			lib.Dir.Set(CorlibDir);
			String cachePath = scope .();
			LibraryIndex.CachePath(lib.Dir, cachePath);
			if (File.Exists(cachePath))
				File.Delete(cachePath).IgnoreError();
			DeleteContentCaches();
			let miss = LibraryIndex.Load(lib);
			let missMs = LibraryIndex.LastMs;
			Check(miss != null && !LibraryIndex.LastWasCacheHit, "first corlib load parses");
			let hit = LibraryIndex.Load(lib);
			let hitMs = LibraryIndex.LastMs;
			Check(hit != null && LibraryIndex.LastWasCacheHit, "second corlib load hits the cache");
			if (miss != null && hit != null)
			{
				Check(miss.Types.Count == hit.Types.Count && miss.Members.Count == hit.Members.Count && miss.Params.Count == hit.Params.Count, "cache round-trips every record");
				Check(!hit.TypesNamed("Math").IsEmpty, "corlib has Math");
				Console.WriteLine("    corlib: {} files, {} types, {} members; parse+index {:0} ms, cache hit {:0.0} ms",
					hit.Files.Count, hit.Types.Count, hit.Members.Count, missMs, hitMs);
			}
			// A different signature (file changed) is a miss.
			SymbolStore probe = scope .();
			Check(probe.Load(cachePath, 12345) case .Err, "stale signature rejected");
			// The path-keyed entry gone (files touched, SDK regenerated with the same output): the
			// content-keyed cache still avoids the parse.
			File.Delete(cachePath).IgnoreError();
			let byContent = LibraryIndex.Load(lib);
			Check(byContent != null && LibraryIndex.LastWasCacheHit, "path cache gone: content-hash cache hit, no parse");
			Check(byContent != null && hit != null && byContent.Types.Count == hit.Types.Count && byContent.Files.Count == hit.Files.Count, "content cache holds the same records");
			Check(File.Exists(cachePath), "content hit re-keys the path cache (next start is stat-only)");
			delete byContent;
			delete miss;
			delete sCorlib;
			sCorlib = hit;
			TestContentCacheCopy();
		}

		static void DeleteContentCaches()
		{
			String dir = scope .();
			LibraryIndex.CacheDir(dir);
			if (!Directory.Exists(dir))
				return;
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String name = scope .();
				entry.GetFileName(name);
				if (name.StartsWith("sdk-"))
				{
					String p = scope .();
					entry.GetFilePath(p);
					File.Delete(p).IgnoreError();
				}
			}
		}

		static void CopyTree(StringView from, StringView to)
		{
			Directory.CreateDirectory(to).IgnoreError();
			for (let entry in Directory.EnumerateFiles(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				entry.GetFilePath(src);
				String dst = scope $"{to}{Path.DirectorySeparatorChar}{name}";
				File.Copy(src, dst, true).IgnoreError();
			}
			for (let entry in Directory.EnumerateDirectories(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				entry.GetFilePath(src);
				CopyTree(src, scope $"{to}{Path.DirectorySeparatorChar}{name}");
			}
		}

		/// The same library in another folder (a second checkout, a copied SDK) loads from the
		/// content-keyed cache, with its file records pointing at the copy.
		static void TestContentCacheCopy()
		{
			String fixture = scope .();
			FixtureDir("Attributed", fixture);
			String copy = scope .();
			TestCacheDir(copy);
			copy.AppendF("{0}copy-test{0}Attributed", Path.DirectorySeparatorChar);
			String copyParent = scope .();
			Path.GetDirectoryPath(copy, copyParent).IgnoreError();
			if (Directory.Exists(copyParent))
				Directory.DelTree(copyParent).IgnoreError();
			Directory.CreateDirectory(copyParent).IgnoreError();
			CopyTree(fixture, copy);
			LibraryRef a = scope .();
			a.Name.Set("Attributed");
			a.Dir.Set(fixture);
			LibraryRef b = scope .();
			b.Name.Set("Attributed");
			b.Dir.Set(copy);
			for (let r in LibraryRef[2](a, b))
			{
				String p = scope .();
				LibraryIndex.CachePath(r.Dir, p);
				File.Delete(p).IgnoreError();
			}
			let original = LibraryIndex.Load(a);
			let copied = LibraryIndex.Load(b);
			Check(copied != null && LibraryIndex.LastWasCacheHit, "a copy of a library elsewhere loads from the content cache");
			bool rebased = copied != null && !copied.Files.IsEmpty;
			if (copied != null)
				for (int i < copied.Files.Count)
					if (!copied.Str(copied.Files[i].Path).StartsWith(copy))
						rebased = false;
			Check(rebased, "its file records point at the copy, not the original");
			Check(original != null && copied != null && original.Members.Count == copied.Members.Count, "same members as the original");
			delete original;
			delete copied;
			Directory.DelTree(copyParent).IgnoreError();
		}

		static void TestAttributedCatalog()
		{
			String dir = scope .();
			FixtureDir("Attributed", dir);
			ProjectIndex index = scope .();
			index.Build(dir);
			TypeService svc = scope .(index);
			svc.AutoLoadLibraries = false;
			let cat = svc.Catalog;
			cat.Refresh();
			Check(svc.ProjectStore.UsesNodeAttributes, "store is attributed");

			let dot = FindSpec(cat, "Dot");
			defer delete dot;
			Check(dot != null, "Dot offered ([NodeLibrary] public static)");
			if (dot != null)
			{
				CheckEq(dot.Category, "Math|Vector", "NodeLibrary category");
				Check(dot.Kind == .Pure, "NodeLibrary non-void function is pure");
				Check(dot.Tooltip.StartsWith("Dot product of two vectors."), "tooltip from doc comment");
				Check(dot.Pins.Count == 2 && dot.Pins[0].Tooltip == "The first vector", "pin tooltip from <param>");
				CheckEq(dot.CallName, "VectorLib.Dot", "static call name");
			}
			let lerp = FindSpec(cat, "Lerp (Vector)");
			defer delete lerp;
			Check(lerp != null, "DisplayName used");
			if (lerp != null)
			{
				Check(lerp.Keywords.Contains("blend"), "keywords");
				Check(lerp.Kind == .Call, "[Node] without Pure has exec pins");
				Check(lerp.Pins.Count == 3 && lerp.Pins[2].Label == "Alpha", "[Pin(Name)] label");
				Check(lerp.Pins.Count == 3 && lerp.Pins[2].Default == "0.5f", "Beef default -> pin default");
				Check(lerp.Pins.Count == 3 && lerp.Pins[2].Tooltip == "0 to 1", "[Pin(Tooltip)]");
				Check(lerp.Tooltip.StartsWith("Blends two vectors."), "doc tooltip with [Node]");
			}
			let norm = FindSpec(cat, "Normalize");
			defer delete norm;
			Check(norm != null && norm.Kind == .Call, "void NodeLibrary function has exec pins");
			Check(CountLabel(cat, "Internal Thunk") == 0, "[NodeHidden] member hidden");
			Check(CountLabel(cat, "Private Helper") == 0, "private member hidden");
			Check(CountLabel(cat, "Clamp") == 2, "two Clamp overloads kept");
			let clampI = FindSpec(cat, "Clamp (int, int, int)");
			let clampF = FindSpec(cat, "Clamp (float, float, float)");
			defer { delete clampI; delete clampF; }
			Check(clampI != null && clampF != null, "overload labels show parameter types");
			let toText = FindSpec(cat, "To Text");
			defer delete toText;
			Check(toText != null && toText.IsConversion, "[Conversion]");

			let health = FindSpec(cat, "Get Health");
			defer delete health;
			Check(health != null && health.Category == "Stats" && !health.IsStatic, "[Expose] instance field: Get in its category");
			Check(CountLabel(cat, "Set Health") == 0, "no Set node for instance fields");
			Check(CountLabel(cat, "Get Max Players") == 1 && CountLabel(cat, "Set Max Players") == 0, "[Expose(ReadOnly)] has Get only");
			Check(CountLabel(cat, "Set Score") == 1, "[Expose] static field has Set");
			Check(CountLabel(cat, "Get Not Exposed") == 0, "untagged field hidden in an attributed store");
			let dmg = FindSpec(cat, "Take Damage");
			defer delete dmg;
			Check(dmg != null, "[Node] instance method");
			if (dmg != null)
			{
				CheckEq(dmg.Category, "Gameplay", "[Node(Category)]");
				Check(dmg.Tooltip.StartsWith("Hurts the player."), "[Node(Tooltip)]");
				Check(dmg.Pins.Count == 2 && dmg.Pins[1].Default == "1", "[Pin(Default)]");
				CheckEq(dmg.OwnerType, "Player", "target type");
			}
			let alive = FindSpec(cat, "Is Alive");
			defer delete alive;
			Check(alive != null && alive.Kind == .Pure, "[Pure]");
			Check(CountLabel(cat, "Untagged") == 0, "untagged method hidden");
			let parse = FindSpec(cat, "Parse");
			defer delete parse;
			Check(parse != null && parse.Kind == .Flow && parse.EnumCases.Count == 2, "[ExpandEnumAsFlow] on Result: Ok/Err");
			Check(CountLabel(cat, "Platform") == 1, "#if arms listed once");
			Check(CountLabel(cat, "Not Shown") == 0, "[NodeHidden] type hides its members");

			// Search over the catalog
			List<SearchHit> hits = scope .();
			cat.Search("blend", hits, 10);
			Check(!hits.IsEmpty && FirstLabel(cat, hits) == "Lerp (Vector)", "keyword search");
			hits.Clear();
			cat.Search("dot", hits, 10);
			Check(!hits.IsEmpty && FirstLabel(cat, hits) == "Dot", "prefix search");
			hits.Clear();
			cat.Search("tdmg", hits, 10);
			Check(!hits.IsEmpty && FirstLabel(cat, hits) == "Take Damage", "fuzzy search");
		}

		static String sLabelBuf = new .() ~ delete _;
		static StringView FirstLabel(NodeCatalog cat, List<SearchHit> hits)
		{
			NodeSpec spec = scope .();
			cat.GetSpec(hits[0].Id, spec);
			sLabelBuf.Set(spec.Label);
			return sLabelBuf;
		}

		/// The catalog built on the indexing worker and adopted equals the one built in place,
		/// and searching letter by letter (incremental) gives exactly the from-scratch results.
		static void TestPrebuiltAndIncremental()
		{
			Console.WriteLine("prebuilt catalog and incremental search");
			let corlib = Corlib();
			if (corlib == null)
			{
				Check(false, "corlib loads");
				return;
			}
			ProjectIndex emptyA = scope .();
			TypeService direct = scope .(emptyA);
			direct.AutoLoadLibraries = false;
			direct.AddLibrary(corlib);
			defer direct.Libraries.Clear(); // corlib belongs to the test cache
			direct.Catalog.Refresh();

			ProjectIndex emptyB = scope .();
			TypeService adopted = scope .(emptyB);
			adopted.AutoLoadLibraries = false;
			List<SymbolStore> libs = scope .();
			libs.Add(corlib);
			adopted.Catalog.Adopt(NodeCatalog.Prebuild(libs));
			adopted.AddLibrary(corlib);
			defer adopted.Libraries.Clear();
			adopted.Catalog.Refresh();
			Check(adopted.Catalog.LastAdoptMs > 0 || adopted.Catalog.TotalEntries == 0, "the first Refresh adopts the prebuilt catalog");
			bool same = direct.Catalog.TotalEntries == adopted.Catalog.TotalEntries && direct.Catalog.Stores.Count == adopted.Catalog.Stores.Count;
			for (int si < direct.Catalog.Stores.Count)
			{
				if (!same)
					break;
				let a = direct.Catalog.Stores[si];
				let b = adopted.Catalog.Stores[si];
				for (int ei < a.Entries.Count)
				{
					let ea = ref a.Entries[ei];
					let eb = ref b.Entries[ei];
					if (a.Str(ea.Display) != b.Str(eb.Display) || direct.Catalog.Categories[ea.Category] != adopted.Catalog.Categories[eb.Category])
					{
						same = false;
						break;
					}
				}
			}
			Check(same, scope $"adopted catalog = catalog built in place ({adopted.Catalog.TotalEntries} entries, names and categories)");
			Check(adopted.Catalog.Tree.Total == direct.Catalog.Tree.Total, "same category tree totals");

			int mismatches = 0;
			int steps = 0;
			for (let query in StringView[?]("get value", "string append", "math.min", "parse int", "dictionary try get"))
			{
				adopted.Catalog.ResetSearchCache();
				String typed = scope .();
				for (let c in query.RawChars)
				{
					typed.Append(c);
					List<SearchHit> inc = scope .();
					adopted.Catalog.Search(typed, inc, 50);
					List<SearchHit> fresh = scope .();
					direct.Catalog.ResetSearchCache();
					direct.Catalog.Search(typed, fresh, 50);
					steps++;
					bool eq = inc.Count == fresh.Count;
					for (int i < Math.Min(inc.Count, fresh.Count))
						if (inc[i].Id != fresh[i].Id || Math.Abs(inc[i].Score - fresh[i].Score) > 0.001f)
							eq = false;
					if (!eq)
					{
						mismatches++;
						Console.WriteLine("    differs at \"{}\"", typed);
					}
				}
			}
			Check(mismatches == 0, scope $"letter-by-letter (incremental) search = from-scratch search ({steps} keystrokes)");
		}

		static void TestPlainCatalog()
		{
			String dir = scope .();
			FixtureDir("Plain", dir);
			ProjectIndex index = scope .();
			index.Build(dir);
			// #if dedupe at the index level
			let calc = index.FindType("Calc");
			Check(calc != null, "Calc indexed");
			if (calc != null)
			{
				int ctors = 0;
				int twice = 0;
				for (let m in calc.Methods)
				{
					if (m.IsCtor) ctors++;
					if (m.Name == "Twice") twice++;
				}
				Check(ctors == 1 && twice == 1, "members inside #if/#else indexed once");
				let scale = calc.FindMethod("Scale");
				Check(scale != null && scale.ParamDefaults[1] == "2.0", "default parameter value indexed");
				CheckEq(calc.Namespace, "Plain", "namespace indexed");
				let pick = calc.FindMethod("Pick");
				Check(pick != null && pick.GenericParams == "T", "method generic parameters");
			}
			let circle = index.FindType("Circle");
			Check(circle != null && circle.BaseTypes.Count == 1 && circle.BaseTypes[0] == "Shape", "base types indexed");

			TypeService svc = scope .(index);
			svc.AutoLoadLibraries = false;
			let cat = svc.Catalog;
			cat.Refresh();
			Check(!svc.ProjectStore.UsesNodeAttributes, "plain store is not attributed");
			Check(CountLabel(cat, "Add") == 3, "three Add overloads");
			Check(CountLabel(cat, "Hidden") == 0, "private hidden in fallback mode");
			Check(CountLabel(cat, "Internal") == 1, "internal shown inside the project");
			Check(CountLabel(cat, "Twice") == 1, "#if duplicates offered once");
			let area = FindSpec(cat, "Get Area");
			defer delete area;
			Check(area != null && area.Category == "Plain|Shape", "fallback category Namespace|Type");

			// Hierarchy
			Check(svc.IsSubtype("Circle", "Shape"), "Circle is a Shape");
			Check(svc.IsSubtype("Circle", "IDamageable"), "Circle implements IDamageable (through Shape)");
			Check(!svc.IsSubtype("Shape", "Circle"), "Shape is not a Circle");
			Conv2(svc, "Circle", "Shape", .Implicit);
			Conv2(svc, "Shape", "Circle", .Refused);
			Conv2(svc, "Circle", "IDamageable", .Implicit);
			// Generics are invariant: a List of a derived class is not a List of its base.
			Conv2(svc, "List<Circle>", "List<Shape>", .Refused);
			Conv2(svc, "List<Circle>", "List<Circle>", .Exact);

			// Context relevance (dragging off pins)
			let damage = FindId(cat, "Damage");
			let addInt = FindId(cat, "Add (int, int)");
			let addFloat = FindId(cat, "Add (float, float)");
			Check(damage >= 0 && cat.ContextRelevance(damage, .TakesValue, "Circle") == 3, "Circle pin -> Shape.Damage (target)");
			Check(addInt >= 0 && cat.ContextRelevance(addInt, .TakesValue, "bool") == 0, "bool pin doesn't offer Add(int,int)");
			Check(addInt >= 0 && cat.ContextRelevance(addInt, .TakesValue, "int") == 3, "int pin offers Add(int,int)");
			Check(addInt >= 0 && cat.ContextRelevance(addInt, .GivesValue, "int") == 3, "Add(int,int) gives an int");
			Check(addFloat >= 0 && cat.ContextRelevance(addFloat, .GivesValue, "int") == 0, "Add(float,float) doesn't give an int");
			Check(addFloat >= 0 && cat.ContextRelevance(addFloat, .TakesValue, "int") == 2, "int converts into Add(float,float)");

			// Overload resolution
			List<String> args = scope .();
			defer { ClearAndDeleteItems!(args); }
			args.Add(new String("float"));
			args.Add(new String("float"));
			let r1 = svc.ResolveCall("Calc", "", "Add", 2, args, null);
			Check(r1 != null && r1.ReturnType == "float", "Add(float, float) chosen by argument types");
			let r2 = svc.ResolveCall("Calc", "", "Add", 3, null, null);
			Check(r2 != null && r2.ParamNames.Count == 3, "Add(a, b, c) chosen by arity");
			let r3 = svc.ResolveCall("Calc", "", "Scale", 1, null, null);
			Check(r3 != null && r3.ReturnType == "double", "defaults count for arity");
			let r4 = svc.ResolveCall("Calc", "", "Add", 5, null, null);
			Check(r4 == null, "no overload takes 5 arguments");
			// A params array passed as the array itself: the params overload in normal form wins.
			List<String> arr = scope .();
			defer { ClearAndDeleteItems!(arr); }
			arr.Add(new String("int[]"));
			let r5 = svc.ResolveCall("Calc", "", "Sum", 1, arr, null);
			Check(r5 != null && r5.ParamNames.Count == 1 && r5.ParamNames[0] == "values", "Sum(int[]) picks Sum(params int[]) over Sum(Object)");
			arr[0].Set("int");
			let r6 = svc.ResolveCall("Calc", "", "Sum", 1, arr, null);
			Check(r6 != null && r6.ParamNames[0] == "values", "Sum(int) picks the params overload in expanded form");
		}

		static void Conv2(TypeService svc, StringView from, StringView to, Conversion expected)
		{
			let c = TypeRules.CanConvert(from, to, null, svc);
			Check(c == expected, scope $"{from} -> {to} with hierarchy: got {c}, expected {expected}");
		}

		static int32 FindId(NodeCatalog cat, StringView label)
		{
			for (int si < cat.Stores.Count)
			{
				let sc = cat.Stores[si];
				for (int ei < sc.Entries.Count)
				{
					let id = NodeCatalog.MakeId(si, ei);
					NodeSpec spec = scope .();
					cat.GetSpec(id, spec);
					if (spec.Label == label)
						return id;
				}
			}
			return -1;
		}

		static Node FindLocal(Graph g, StringView name)
		{
			for (let n in g.Nodes)
				if (n.Kind == .LocalVar && n.Text == name)
					return n;
			return null;
		}

		static void LocalType(Graph g, StringView name, StringView expected)
		{
			let n = FindLocal(g, name);
			if (n == null)
			{
				Check(false, scope $"local {name} exists");
				return;
			}
			CheckEq(n.FindOutput("variable").TypeName, expected, scope $"type of local {name}");
		}

		static Node FindCall(Graph g, StringView name, int argCount)
		{
			for (let n in g.Nodes)
				if (n.Kind == .Call && n.Text == name && n.ArgCount == argCount)
					return n;
			return null;
		}

		static void TestGraphTypes()
		{
			String dir = scope .();
			FixtureDir("Plain", dir);
			ProjectIndex index = scope .();
			index.Build(dir);
			TypeService svc = scope .(index);
			svc.AutoLoadLibraries = false;
			let corlib = Corlib();
			if (corlib != null)
			{
				// The test owns sCorlib: hand the service a copy of its records.
				SymbolStore copy = new .();
				String cachePath = scope .();
				LibraryIndex.CachePath(CorlibDir, cachePath);
				copy.Load(cachePath, 0).IgnoreError();
				copy.Name.Set("corlib");
				copy.IsLibrary = true;
				svc.AddLibrary(copy);
			}
			svc.Install();
			let oldIndex = GraphBuilder.Index;
			GraphBuilder.Index = index;
			defer
			{
				GraphBuilder.Index = oldIndex;
				TypeService.Current = null;
				TypeRules.Hierarchy = null;
			}

			String text = scope .();
			String path = scope $"{dir}{Path.DirectorySeparatorChar}src{Path.DirectorySeparatorChar}Plain.bf";
			File.ReadAllText(path, text, true).IgnoreError();
			let unit = Parser.Parse(text);
			defer delete unit;
			List<Member> methods = scope .();
			List<Member> owners = scope .();
			unit.CollectMethods(methods, owners);
			Graph run = null;
			Graph run2 = null;
			defer { delete run; delete run2; }
			for (int i < methods.Count)
			{
				if (methods[i].Name == "Run")
					run = GraphBuilder.Build(unit, methods[i], owners[i]);
				if (methods[i].Name == "Run2")
					run2 = GraphBuilder.Build(unit, methods[i], owners[i]);
			}
			Check(run != null && run2 != null, "fixture graphs built");
			if (run == null || run2 == null)
				return;
			LocalType(run, "d", "double");
			LocalType(run, "f", "float");
			LocalType(run, "u", "uint");
			LocalType(run, "h", "int");
			LocalType(run, "l", "int64");
			LocalType(run, "str", "String");
			LocalType(run, "ch", "char8");
			LocalType(run, "sum", "int");
			LocalType(run, "fsum", "float");
			LocalType(run, "three", "int");
			LocalType(run, "scaled", "double");
			LocalType(run, "parsed", "int");
			LocalType(run, "area", "float");
			let add3 = FindCall(run, "Add", 3);
			Check(add3 != null && add3.FindInput("arg2")?.Label == "c", "3-argument Add labelled from its own overload");
			let addf = FindCall(run, "Add", 2);
			Check(addf != null, "Add call node");
			// list.Add(4): List<int>.Add(T) -> the pin is an int (corlib + generic substitution)
			let listAdd = FindCall(run, "Add", 1);
			Check(listAdd != null && listAdd.FindInput("arg0")?.TypeName == "int", "List<int>.Add(T item) pin is int");
			Check(listAdd != null && listAdd.FindInput("arg0")?.Label == "item", "corlib parameter name on the pin (not Arg 0)");

			LocalType(run2, "n", "int");      // Try!(int.Parse(s))
			LocalType(run2, "len", "int");    // StringView.Length from Span<char8>
			LocalType(run2, "m", "int");      // Math.Max<T>(1, 2)
			LocalType(run2, "mf", "float");   // Math.Max<T>(1.0f, 2.0f)
			let parseNode = FindCall(run2, "Parse", 1);
			Check(parseNode != null && parseNode.FindInput("arg0")?.Label == "val", "int.Parse pin labelled from corlib");
			Check(parseNode != null && parseNode.Result != null && parseNode.Result.TypeName.StartsWith("Result<int"), "int.Parse returns Result<int, ...>");

			// Namespace-aware: `Shape` in namespace Plain is Plain.Shape even with `using Other;`.
			ResolveContext ctx = scope .();
			ctx.Namespace.Set("Plain");
			ctx.Usings.Add(new String("Other"));
			let shape = svc.FindType("Shape", ctx);
			Check(shape.IsValid && shape.Store.Str(shape.Rec.Namespace) == "Plain", "own namespace beats using");
			ResolveContext ctx2 = scope .();
			ctx2.Namespace.Set("Elsewhere");
			ctx2.Usings.Add(new String("Other"));
			let shape2 = svc.FindType("Shape", ctx2);
			Check(shape2.IsValid && shape2.Store.Str(shape2.Rec.Namespace) == "Other", "using picks the namespace");
			let intType = svc.FindType("int", null);
			Check(intType.IsValid && intType.Store.Str(intType.Rec.Name) == "Int", "int resolves to corlib's Int");
			// Generic arity: a tuple argument is one argument, not two.
			{
				String nm = scope .();
				Check(TypeService.GenericArgs("Dictionary<int, (int, int)>", nm..Clear()) == 2 && nm == "Dictionary", "arity of Dictionary<int, (int, int)> is 2");
				Check(TypeService.GenericArgs("List<(int, int)>", nm..Clear()) == 1 && TypeService.GenericArgs("Dictionary<String, (int a, List<int> b)>", nm..Clear()) == 2 && TypeService.GenericArgs("Dictionary<(int, int), (int, int)>", nm..Clear()) == 2, "tuples are one argument each");
				Check(TypeService.GenericArgs("Dictionary<int, Dictionary<int, int>>", nm..Clear()) == 2 && TypeService.GenericArgs("List<int>", nm..Clear()) == 1 && TypeService.GenericArgs("String", nm..Clear()) == 0 && TypeService.GenericArgs("(int, int)", nm..Clear()) == 0 && nm == "(int, int)", "nested generics, none, a bare tuple");
				let dict = svc.FindType("Dictionary<int, (int, int)>", null);
				Check(dict.IsValid && dict.Store.Str(dict.Rec.Name) == "Dictionary", "Dictionary<int, (int, int)> resolves (2 arguments, the tuple is one)");
				let dict2 = svc.FindType("System.Collections.Dictionary<String, (int a, List<int> b)>", null);
				Check(dict2.IsValid && dict2.Store.Str(dict2.Rec.Name) == "Dictionary", "a named tuple holding a generic is one argument too");
				let list = svc.FindType("List<(int, int)>", null);
				Check(list.IsValid && list.Store.Str(list.Rec.Name) == "List", "List<(int, int)> resolves as List (1 argument)");
				let dict3 = svc.FindType("Dictionary<int, int>", null);
				Check(dict3.IsValid && dict3.Store.Str(dict3.Rec.Name) == "Dictionary", "Dictionary<int, int> still resolves");
			}
		}

		static void TestWires()
		{
			Graph g = scope .();
			let a = g.AddNode(.Get);
			let aOut = g.AddDataOut(a, "result", "");
			aOut.TypeName.Set("int");
			let b = g.AddNode(.Get);
			let bOut = g.AddDataOut(b, "result", "");
			bOut.TypeName.Set("bool");
			let call = g.AddNode(.Call);
			let x = g.AddDataIn(call, "arg0", "a");
			x.TypeName.Set("T");
			let y = g.AddDataIn(call, "arg1", "b");
			y.TypeName.Set("T");
			let r = g.AddDataOut(call, "result", "Return Value");
			r.TypeName.Set("List<T>");
			let br = g.AddNode(.Branch);
			let cond = g.AddDataIn(br, "condition", "Condition");
			cond.TypeName.Set("bool");

			String why = scope .();
			Check(!Graph.CanConnectTyped(aOut, cond, why), "int -> bool condition refused");
			Check(!why.IsEmpty, "refusal has a reason");
			Check(Graph.CanConnectTyped(bOut, cond), "bool -> bool allowed");
			Check(Graph.CanConnectTyped(aOut, x), "int -> T allowed");
			g.Connect(aOut, x);
			CheckEq(y.TypeName, "int", "wildcard unified on the other T pin");
			CheckEq(r.TypeName, "List<int>", "wildcard unified inside generic result");
			Check(!Graph.CanConnectTyped(bOut, y), "bool -> unified int pin refused");
			let link = g.FindLinkTo(x);
			g.Disconnect(link);
			CheckEq(y.TypeName, "T", "wildcard restored after disconnect");
			CheckEq(r.TypeName, "List<T>", "generic result restored");
			// Unknown types never block (graphs from code always load).
			let u = g.AddNode(.Get);
			let uOut = g.AddDataOut(u, "result", "");
			Check(Graph.CanConnectTyped(uOut, cond), "unknown type -> bool allowed");
		}

		static void TestColours()
		{
			Check(TypeRules.Family("bool") == .Bool, "bool family");
			Check(TypeRules.Family("int32") == .Int, "int family");
			Check(TypeRules.Family("double") == .Float, "double family");
			Check(TypeRules.Family("StringView") == .String, "string family");
			Check(TypeRules.Family("T") == .Wildcard, "generic family");
			Check(TypeRules.Family("") == .Unknown, "unknown family");
			Check(TypeRules.Family("ETickTiming") == .Enum, "enum by name without index");
			Check(TypeRules.FamilyColor(.Bool) != TypeRules.FamilyColor(.Int), "distinct colours");
			Check((TypeRules.FamilyColor(.Bool) & 0xFF) == 146, "bool is UE red (R=146)");
		}

		static void TestDiscovery()
		{
			String dir = scope .();
			FixtureDir("Attributed", dir);
			List<LibraryRef> libs = scope .();
			defer { ClearAndDeleteItems!(libs); }
			// The worktree's BeefSpace.toml lists VisualBeefMeta: the fixture's dependency on it
			// resolves to the workspace project; corlib to BeefLibs.
			LibraryIndex.Discover(dir, libs);
			bool corlib = false;
			for (let l in libs)
				if (l.Name == "corlib")
					corlib = true;
			Check(corlib, "corlib discovered");
			MiniToml t = scope .();
			t.Parse("[Projects]\nA = {Path = \"x/y\"}\nB = {Path = \".\"}\n[Dependencies]\ncorlib = \"*\"\nDependencies2 = {X = \"*\", Y = \"*\"}");
			CheckEq(t.Get("Projects.A.Path"), "x/y", "toml inline table");
			List<StringView> names = scope .();
			t.Children("Projects", names);
			Check(names.Count == 2, "toml children");
			CheckEq(t.Get("Dependencies.corlib"), "*", "toml table key");
		}

		/// `VisualBeefTests catalog-scale -root <dir>`: opening a whole folder the way the editor
		/// does (project index + every library it needs), twice: cold (empty cache) and warm.
		public static int ScaleRoot(StringView root)
		{
			String cache = scope .();
			TestCacheDir(cache);
			cache.AppendF("{}root", Path.DirectorySeparatorChar);
			if (Directory.Exists(cache))
				Directory.DelTree(cache).IgnoreError();
			LibraryIndex.sCacheDirOverride.Set(cache);
			defer LibraryIndex.sCacheDirOverride.Clear();
			ProjectIndex live = scope .();
			for (int pass < 2)
			{
				// Exactly what the editor's background indexer runs (here on this thread).
				let sw = scope Stopwatch(true);
				IndexJob job = scope .(root);
				job.Run();
				let total = sw.Elapsed.TotalMilliseconds;
				int libTypes = 0;
				String libNames = scope .();
				for (let l in job.Libraries)
				{
					libTypes += l.Types.Count;
					libNames.AppendF("{}{}", libNames.IsEmpty ? "" : ", ", l.Name);
				}
				Console.WriteLine("open root ({}): {:0} ms total; project index {:0} ms, {} files ({} generated SDK folders skipped); libraries {:0} ms, {} stores [{}] ({} from cache, {} parsed, {} types)",
					(pass == 0) ? "cold" : "warm", total, job.ProjectMs, job.Project.Files.Count, job.Project.GeneratedLibraries.Count,
					job.LibraryMs, job.Libraries.Count, libNames, job.CacheHits, job.LibrariesParsed, libTypes);
				if (pass == 1)
					live.TakeFrom(job.Project);
			}
			// A rescan of the same root (after creating / renaming a file): unchanged files are reused.
			let sw = scope Stopwatch(true);
			live.Build(root);
			Console.WriteLine("rescan same root: {:0} ms ({} parsed, {} reused)", sw.Elapsed.TotalMilliseconds, live.LastParsed, live.LastReused);
			// Content-keyed cache: drop the path-keyed entries, the SDK must still load without parsing.
			for (let entry in Directory.EnumerateFiles(cache))
			{
				String name = scope .();
				entry.GetFileName(name);
				if (!name.StartsWith("sdk-"))
				{
					String p = scope .();
					entry.GetFilePath(p);
					File.Delete(p).IgnoreError();
				}
			}
			sw.Restart();
			IndexJob job3 = scope .(root);
			job3.Run();
			Console.WriteLine("open root (path cache dropped, content cache only): {:0} ms; libraries {:0} ms ({} from cache, {} parsed)",
				sw.Elapsed.TotalMilliseconds, job3.LibraryMs, job3.CacheHits, job3.LibrariesParsed);
			// Cancelling stops the worker quickly.
			IndexJob job4 = scope .(root);
			job4.Start();
			Thread.Sleep(50);
			sw.Restart();
			job4.Cancel();
			job4.Wait();
			Console.WriteLine("cancel: worker stopped {:0.0} ms after Cancel (done={})", sw.Elapsed.TotalMilliseconds, job4.IsDone);
			return 0;
		}

		/// `VisualBeefTests catalog-scale [dir]`: a generated SDK as a library: parse + cache,
		/// cache hit, catalog build, searches and a context filter, with timings.
		public static int Scale(StringView sdkDir)
		{
			String cache = scope .();
			TestCacheDir(cache);
			LibraryIndex.sCacheDirOverride.Set(cache);
			defer LibraryIndex.sCacheDirOverride.Clear();
			LibraryRef lib = scope .();
			lib.Name.Set("SDK");
			lib.Dir.Set(sdkDir);
			String cachePath = scope .();
			LibraryIndex.CachePath(lib.Dir, cachePath);
			if (File.Exists(cachePath))
				File.Delete(cachePath).IgnoreError();
			DeleteContentCaches();
			let first = LibraryIndex.Load(lib);
			if (first == null)
			{
				Console.WriteLine("no sources in {}", sdkDir);
				return 1;
			}
			Console.WriteLine("parse + index + write cache: {:0} ms  ({} files, {} types, {} members, {} params)",
				LibraryIndex.LastMs, first.Files.Count, first.Types.Count, first.Members.Count, first.Params.Count);
			delete first;
			// Path-keyed entry dropped (files touched / SDK regenerated identically): content-hash hit.
			File.Delete(cachePath).IgnoreError();
			let byContent = LibraryIndex.Load(lib);
			Console.WriteLine("content-hash cache load (path cache dropped): {:0} ms ({})", LibraryIndex.LastMs, LibraryIndex.LastWasCacheHit ? "hit" : "MISS");
			delete byContent;
			let store = LibraryIndex.Load(lib);
			Console.WriteLine("cache hit load: {:0.0} ms ({})", LibraryIndex.LastMs, LibraryIndex.LastWasCacheHit ? "hit" : "MISS");
			int64 size = 0;
			if (File.GetLastWriteTime(cachePath) case .Ok)
			{
				List<uint8> bytes = scope .();
				File.ReadAll(cachePath, bytes).IgnoreError();
				size = bytes.Count;
			}
			Console.WriteLine("cache file: {:0.0} MB", size / (1024.0 * 1024.0));

			ProjectIndex empty = scope .();
			TypeService svc = scope .(empty);
			svc.AutoLoadLibraries = false;
			svc.AddLibrary(store);
			let sw = scope Stopwatch(true);
			svc.Catalog.Refresh();
			Console.WriteLine("catalog build: {:0} ms, {} entries, {} categories", sw.Elapsed.TotalMilliseconds, svc.Catalog.TotalEntries, svc.Catalog.Categories.Count);
			sw.Restart();
			let tree = svc.Catalog.Tree;
			Console.WriteLine("category tree: {:0.0} ms ({} top-level, {} nodes)", sw.Elapsed.TotalMilliseconds, tree.Children.Count, tree.Total);

			// What the editor does now: the indexer thread builds the library catalog, the UI
			// thread adopts it (categories renumbered) on the first Refresh.
			{
				ProjectIndex empty2 = scope .();
				TypeService svc2 = scope .(empty2);
				svc2.AutoLoadLibraries = false;
				List<SymbolStore> libs = scope .();
				libs.Add(store);
				let pre = NodeCatalog.Prebuild(libs);
				Console.WriteLine("catalog prebuild (indexer thread): {:0} ms", pre.BuildMs);
				svc2.Catalog.Adopt(pre);
				svc2.Libraries.Add(store); // shared with svc: removed again below
				svc2.Generation++;
				sw.Restart();
				svc2.Catalog.Refresh();
				Console.WriteLine("catalog adopt (UI thread, first node menu): {:0.0} ms, {} entries (adopting {:0.0} ms)", sw.Elapsed.TotalMilliseconds, svc2.Catalog.TotalEntries, svc2.Catalog.LastAdoptMs);
				sw.Restart();
				let tree2 = svc2.Catalog.Tree;
				Console.WriteLine("category tree after adopt: {:0.0} ms ({} nodes)", sw.Elapsed.TotalMilliseconds, tree2.Total);
				svc2.Libraries.Clear();
			}

			// Typing "get actor location" one key at a time: every keystroke searched from
			// scratch, then incrementally (each query only adds to the last one).
			for (int pass < 2)
			{
				double total = 0;
				double worstKey = 0;
				int scanned = 0;
				String typed = scope .();
				svc.Catalog.ResetSearchCache();
				for (let c in "get actor location".RawChars)
				{
					typed.Append(c);
					if (pass == 0)
						svc.Catalog.ResetSearchCache();
					List<SearchHit> hits = scope .();
					sw.Restart();
					svc.Catalog.Search(typed, hits, 300);
					let ms = sw.Elapsed.TotalMilliseconds;
					total += ms;
					worstKey = Math.Max(worstKey, ms);
					scanned += svc.Catalog.LastScanned;
					if (pass == 1)
						Console.WriteLine("  \"{}\": {:0.0} ms, {} scanned", typed, ms, svc.Catalog.LastScanned);
				}
				Console.WriteLine("typing \"get actor location\" ({}): {:0} ms in all, worst keystroke {:0.0} ms, {} entries scanned",
					(pass == 0) ? "each key from scratch" : "incremental", total, worstKey, scanned);
			}

			for (let q in StringView[?]("pause", "get actor location", "spawn actor", "k2 set", "gal", "zzzq"))
			{
				List<SearchHit> hits = scope .();
				sw.Restart();
				svc.Catalog.Search(q, hits, 300);
				let ms = sw.Elapsed.TotalMilliseconds;
				String best = scope .();
				if (!hits.IsEmpty)
				{
					NodeSpec spec = scope .();
					svc.Catalog.GetSpec(hits[0].Id, spec);
					best.AppendF("{}  [{}]", spec.Label, spec.Category);
				}
				Console.WriteLine("search \"{}\": {:0.0} ms, {} hits, best: {}", q, ms, hits.Count, best);
			}
			// Context filter: everything that takes a UActorComponent* (target or parameter).
			sw.Restart();
			int matches = 0;
			for (int si < svc.Catalog.Stores.Count)
				for (int ei < svc.Catalog.Stores[si].Entries.Count)
					if (svc.Catalog.ContextRelevance(NodeCatalog.MakeId(si, ei), .TakesValue, "UActorComponent*") >= 2)
						matches++;
			Console.WriteLine("context filter (takes UActorComponent*): {:0} ms, {} entries", sw.Elapsed.TotalMilliseconds, matches);
			return 0;
		}
	}
}
