using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Tests
{
	/// The vocabulary rule (docs/Vocabulary.md): no Unreal term appears anywhere a user can see
	/// it. This reads the string literals of the Core, Editor and Meta sources (comments and
	/// interpolation holes are not text a user sees) and the docs, and fails on any banned word.
	///
	///   VisualBeefTests vocabulary [<repo-root>] [-v]
	///
	/// A hit is a whole word (letters, digits and `_` around it do not count, so `SelfTest`,
	/// `TargetType` or `BlueprintType` are not hits). The allow-list holds only Beef keywords,
	/// internal ids that are never shown, and the SDK's own names.
	static class VocabularyTests
	{
		struct Lit
		{
			public String Text;
			public int Line;
		}

		static int sFailures;
		static bool sVerbose;

		/// Whole words that must not be seen. Compared case-insensitively.
		static StringView[?] sWords = .("blueprint", "blueprints", "unreal", "details", "target", "targets", "self",
			"action", "actions", "executable", "exec", "execs", "ue", "ue4", "ue5");

		/// Phrases (case-insensitive), checked between non-word characters.
		static StringView[?] sPhrases = .("event tick", "class settings", "content browser", "content drawer",
			"pure function", "return node", "action menu", "my blueprint", "ue:");

		/// String literals that are allowed whole: ids that no one reads, Beef type names the
		/// type rules compare against, and the pin ids (`target`, `exec`) the layout hashes keep.
		static StringView[?] sAllowedLiterals = .("target", "target=", "exec", "Self", "SelfBase", "Action<");

		/// Substrings that make a literal belong to the SDK / game data.
		static StringView[?] sAllowedParts = .("UnrealUMP", "Universal Unreal Mod Platform");

		/// Docs that record history or the mapping itself.
		static StringView[?] sExcludedDocs = .("CHANGELOG.md", "Roadmap.md", "Vocabulary.md", "udit-2026-10-10.md");

		static void Fail(StringView where_, int line, StringView term, StringView excerpt)
		{
			Console.WriteLine("  FAIL {}:{}: '{}' in \"{}\"", where_, line, term, excerpt);
			sFailures++;
		}

		static bool IsWordChar(char8 c) => c.IsLetterOrDigit || c == '_';

		/// The first banned word or phrase in `text`, or empty.
		public static void FindBanned(StringView text, String outTerm)
		{
			String lower = scope .(text);
			lower.ToLower();
			for (let w in sWords)
				if (HasWord(lower, w))
				{
					outTerm.Set(w);
					return;
				}
			for (let p in sPhrases)
				if (HasWord(lower, p))
				{
					outTerm.Set(p);
					return;
				}
		}

		static bool HasWord(StringView lower, StringView word)
		{
			int from = 0;
			while (from <= lower.Length - word.Length)
			{
				int at = lower.IndexOf(word, from);
				if (at < 0)
					return false;
				bool leftOk = at == 0 || !IsWordChar(lower[at - 1]);
				int end = at + word.Length;
				bool rightOk = end >= lower.Length || !IsWordChar(lower[end]) || word.EndsWith(':');
				if (leftOk && rightOk)
					return true;
				from = at + 1;
			}
			return false;
		}

		// ------------------------------------------------------------------ literals

		static void SkipCharLiteral(StringView src, ref int i)
		{
			i++; // opening quote
			while (i < src.Length && src[i] != '\'' && src[i] != '\n')
			{
				if (src[i] == '\\')
					i++;
				i++;
			}
			i++;
		}

		/// Reads one string literal that starts at the opening quote; its text (without the
		/// interpolation holes) is added to `lits`. Strings nested in a hole are added too.
		static void ReadString(StringView src, ref int i, ref int line, List<Lit> lits)
		{
			bool interp = i > 0 && (src[i - 1] == '$' || (i > 1 && src[i - 1] == '@' && src[i - 2] == '$') || (i > 1 && src[i - 1] == '$' && src[i - 2] == '@'));
			bool verbatim = i > 0 && (src[i - 1] == '@' || (i > 1 && src[i - 1] == '$' && src[i - 2] == '@'));
			int startLine = line;
			String buf = new .();
			if (i + 2 < src.Length && src[i + 1] == '"' && src[i + 2] == '"')
			{
				// triple-quoted multi-line text
				i += 3;
				while (i + 2 < src.Length && !(src[i] == '"' && src[i + 1] == '"' && src[i + 2] == '"'))
				{
					if (src[i] == '\n')
						line++;
					buf.Append(src[i]);
					i++;
				}
				i += 3;
				lits.Add(.() { Text = buf, Line = startLine });
				return;
			}
			i++; // opening quote
			while (i < src.Length)
			{
				char8 c = src[i];
				if (c == '\n')
					line++;
				if (c == '\\' && !verbatim)
				{
					if (i + 1 < src.Length)
						buf.Append(src[i + 1]);
					i += 2;
					continue;
				}
				if (c == '"')
				{
					if (verbatim && i + 1 < src.Length && src[i + 1] == '"')
					{
						buf.Append('"');
						i += 2;
						continue;
					}
					i++;
					break;
				}
				if (interp && c == '{')
				{
					if (i + 1 < src.Length && src[i + 1] == '{')
					{
						buf.Append('{');
						i += 2;
						continue;
					}
					int depth = 1;
					i++;
					while (i < src.Length && depth > 0)
					{
						char8 h = src[i];
						if (h == '\n')
							line++;
						if (h == '"')
						{
							ReadString(src, ref i, ref line, lits);
							continue;
						}
						if (h == '\'')
						{
							SkipCharLiteral(src, ref i);
							continue;
						}
						if (h == '{')
							depth++;
						else if (h == '}')
							depth--;
						i++;
					}
					buf.Append(' '); // the hole
					continue;
				}
				if (interp && c == '}' && i + 1 < src.Length && src[i + 1] == '}')
				{
					buf.Append('}');
					i += 2;
					continue;
				}
				buf.Append(c);
				i++;
			}
			lits.Add(.() { Text = buf, Line = startLine });
		}

		/// Every string literal outside comments, with the line it starts on.
		static void ExtractLiterals(StringView src, List<Lit> lits)
		{
			int i = 0;
			int line = 1;
			while (i < src.Length)
			{
				char8 c = src[i];
				if (c == '\n')
				{
					line++;
					i++;
				}
				else if (c == '/' && i + 1 < src.Length && src[i + 1] == '/')
				{
					while (i < src.Length && src[i] != '\n')
						i++;
				}
				else if (c == '/' && i + 1 < src.Length && src[i + 1] == '*')
				{
					i += 2;
					while (i + 1 < src.Length && !(src[i] == '*' && src[i + 1] == '/'))
					{
						if (src[i] == '\n')
							line++;
						i++;
					}
					i += 2;
				}
				else if (c == '\'')
					SkipCharLiteral(src, ref i);
				else if (c == '"')
					ReadString(src, ref i, ref line, lits);
				else
					i++;
			}
		}

		static bool Allowed(StringView lit)
		{
			for (let a in sAllowedLiterals)
				if (lit == a)
					return true;
			for (let p in sAllowedParts)
				if (lit.Contains(p))
					return true;
			return false;
		}

		// ------------------------------------------------------------------ files

		static void Collect(StringView dir, StringView ext, List<String> files)
		{
			for (let e in Directory.Enumerate(scope $"{dir}/*", .Files | .Directories))
			{
				String path = scope .();
				e.GetFilePath(path);
				if (e.IsDirectory)
				{
					String name = scope .();
					e.GetFileName(name);
					if (name == "build" || name.StartsWith('.'))
						continue;
					Collect(path, ext, files);
				}
				else if (path.EndsWith(ext, .OrdinalIgnoreCase))
					files.Add(new String(path));
			}
		}

		static int ScanSources(StringView root, StringView sub, ref int fileCount, ref int litCount)
		{
			List<String> files = scope .();
			Collect(scope $"{root}/{sub}", ".bf", files);
			defer { for (let f in files) delete f; }
			int hits = 0;
			for (let f in files)
			{
				String text = scope .();
				if (File.ReadAllText(f, text, true) case .Err)
					continue;
				fileCount++;
				List<Lit> lits = scope .();
				ExtractLiterals(text, lits);
				defer { for (let l in lits) delete l.Text; }
				for (let l in lits)
				{
					litCount++;
					if (Allowed(l.Text))
						continue;
					String term = scope .();
					FindBanned(l.Text, term);
					if (!term.IsEmpty)
					{
						String shown = scope .(l.Text);
						if (shown.Length > 90)
							shown.RemoveToEnd(90);
						Fail(f, l.Line, term, shown);
						hits++;
					}
				}
			}
			return hits;
		}

		static int ScanDocs(StringView root, ref int fileCount)
		{
			List<String> files = scope .();
			Collect(scope $"{root}/docs", ".md", files);
			files.Add(new String(scope $"{root}/README.md"));
			defer { for (let f in files) delete f; }
			int hits = 0;
			for (let f in files)
			{
				bool skip = false;
				for (let x in sExcludedDocs)
					if (f.EndsWith(x))
						skip = true;
				if (skip)
					continue;
				String text = scope .();
				if (File.ReadAllText(f, text, true) case .Err)
					continue;
				fileCount++;
				int line = 0;
				for (let l in text.Split('\n'))
				{
					line++;
					String term = scope .();
					String scrubbed = scope .(l);
					scrubbed.Replace("UnrealUMP.Unreal", ""); // the game SDK's namespace
					scrubbed.Replace("UnrealUMP|Unreal", ""); // and its node category
					scrubbed.Replace("Universal Unreal Mod Platform", ""); // the modding platform's product name
					FindBanned(scrubbed, term);
					if (!term.IsEmpty)
					{
						String shown = scope .(l);
						shown.Trim();
						if (shown.Length > 90)
							shown.RemoveToEnd(90);
						Fail(f, line, term, shown);
						hits++;
					}
				}
			}
			return hits;
		}

		// ------------------------------------------------------------------ run

		static void Check(bool cond, StringView what)
		{
			if (cond)
			{
				if (sVerbose)
					Console.WriteLine("  ok   {}", what);
			}
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		static void SelfCheck()
		{
			List<Lit> lits = scope .();
			String sample = scope .();
			sample.Append("// \"Blueprint in a comment\"\n");
			sample.Append("var a = \"Details panel\"; var b = $\"{x} and {(y ? \"Target\" : \"ok\")} {{Self}}\"; var c = '\"'; var d = \"SelfTest\";\n");
			ExtractLiterals(sample, lits);
			defer { for (let l in lits) delete l.Text; }
			String joined = scope .();
			for (let l in lits)
			{
				joined.Append('[');
				joined.Append(l.Text);
				joined.Append(']');
			}
			Check(joined.StartsWith("[Details panel][Target][ok][") && joined.EndsWith("{Self}][SelfTest]"), scope $"literal extraction ({joined})");
			String t = scope .();
			FindBanned("the Details panel", t);
			Check(t == "details", "a banned word is found");
			t.Clear();
			FindBanned("SelfTest, TargetType, BlueprintType, executed", t);
			Check(t.IsEmpty, "whole words only");
			t.Clear();
			FindBanned("Pure Function Call", t);
			Check(t == "pure function", "a banned phrase is found");
		}

		public static int Run(String[] args)
		{
			sFailures = 0;
			String root = scope .(".");
			for (int i = 1; i < args.Count; i++)
			{
				if (args[i] == "-v")
					sVerbose = true;
				else
					root.Set(args[i]);
			}
			SelfCheck();
			int files = 0;
			int lits = 0;
			int hits = 0;
			hits += ScanSources(root, "VisualBeefCore/src", ref files, ref lits);
			hits += ScanSources(root, "VisualBeefEditor/src", ref files, ref lits);
			hits += ScanSources(root, "VisualBeefMeta/src", ref files, ref lits);
			int docs = 0;
			hits += ScanDocs(root, ref docs);
			Console.WriteLine("vocabulary: source files={} string literals={} docs={} hits={} failures={}", files, lits, docs, hits, sFailures);
			return sFailures;
		}
	}
}
