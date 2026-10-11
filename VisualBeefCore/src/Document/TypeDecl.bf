using System;
using System.Collections;
using VisualBeef.Syntax;

namespace VisualBeef.Document
{
	/// Modifier words of a declaration (`public static override`): reading them and changing one
	/// word at a time while keeping the others where they are (minimal diffs). See
	/// docs/Classes-and-Members.md.
	static class Mods
	{
		/// The order new words are inserted in (Beef accepts any order; this is the usual one).
		static String[?] sOrder = .("public", "protected", "internal", "private", "new", "static", "extern",
			"abstract", "virtual", "override", "sealed", "readonly", "const", "mut", "unsafe", "volatile", "partial",
			"implicit", "explicit", "concrete", "append", "inline");

		public static String[?] Visibilities = .("public", "protected", "internal", "private");

		static int Rank(StringView word)
		{
			for (int i < sOrder.Count)
				if (sOrder[i] == word)
					return i;
			return sOrder.Count;
		}

		public static void Split(StringView mods, List<StringView> outWords)
		{
			for (var w in mods.Split(' ', '\t', '\r', '\n'))
			{
				w.Trim();
				if (!w.IsEmpty)
					outWords.Add(w);
			}
		}

		public static bool Has(StringView mods, StringView word)
		{
			List<StringView> words = scope .();
			Split(mods, words);
			return words.Contains(word);
		}

		/// "public", "protected internal", ... ("" when none is written).
		public static void GetVisibility(StringView mods, String outVis)
		{
			List<StringView> words = scope .();
			Split(mods, words);
			for (let w in words)
			{
				if (IsVisibility(w))
				{
					if (!outVis.IsEmpty)
						outVis.Append(' ');
					outVis.Append(w);
				}
			}
		}

		public static bool IsVisibility(StringView w) => w == "public" || w == "protected" || w == "internal" || w == "private";

		static void Join(List<StringView> words, String outText)
		{
			for (let w in words)
			{
				if (!outText.IsEmpty)
					outText.Append(' ');
				outText.Append(w);
			}
		}

		/// Adds or removes one word. An added word goes before the first word that ranks after it.
		public static void SetWord(StringView mods, StringView word, bool on, String outMods)
		{
			List<StringView> words = scope .();
			Split(mods, words);
			int at = words.IndexOf(word);
			if (on && at < 0)
			{
				int rank = Rank(word);
				int insert = words.Count;
				for (int i < words.Count)
				{
					if (Rank(words[i]) > rank)
					{
						insert = i;
						break;
					}
				}
				words.Insert(insert, word);
			}
			else if (!on)
			{
				while (at >= 0)
				{
					words.RemoveAt(at);
					at = words.IndexOf(word);
				}
			}
			Join(words, outMods);
		}

		/// Sets exactly one of `group` (or none when `word` is empty), keeping the position of the
		/// word it replaces.
		public static void SetExclusive(StringView mods, StringView groupCsv, StringView word, String outMods)
		{
			List<StringView> words = scope .();
			Split(mods, words);
			int firstAt = -1;
			for (int i = words.Count - 1; i >= 0; i--)
			{
				bool inGroup = false;
				for (let g in groupCsv.Split(','))
					if (g == words[i])
						inGroup = true;
				if (inGroup)
				{
					firstAt = i;
					words.RemoveAt(i);
				}
			}
			if (!word.IsEmpty)
			{
				List<StringView> parts = scope .();
				Split(word, parts);
				if (firstAt >= 0)
				{
					for (int i < parts.Count)
						words.Insert(firstAt + i, parts[i]);
				}
				else
				{
					String tmp = scope .();
					Join(words, tmp);
					for (let p in parts)
					{
						String next = scope:: .();
						SetWord(tmp, p, true, next);
						tmp.Set(next);
					}
					outMods.Append(tmp);
					return;
				}
			}
			Join(words, outMods);
		}

		/// Replaces the visibility ("" = none written, i.e. the default).
		public static void SetVisibility(StringView mods, StringView vis, String outMods)
		{
			SetExclusive(mods, "public,protected,internal,private", vis, outMods);
		}
	}

	/// Attribute lists: `[A, B(1)][C]` <-> "A", "B(1)", "C".
	static class AttrList
	{
		/// Splits attribute text into its attributes (top-level commas inside each `[...]`).
		public static void Parse(StringView text, List<String> outAttrs)
		{
			int depth = 0;
			int start = -1;
			bool inString = false;
			for (int i < text.Length)
			{
				char8 c = text[i];
				if (inString)
				{
					if (c == '\\')
						i++;
					else if (c == '"')
						inString = false;
					continue;
				}
				if (c == '"')
				{
					inString = true;
					continue;
				}
				if (c == '[' || c == '(' || c == '{' || c == '<')
				{
					depth++;
					if (depth == 1 && c == '[')
						start = i + 1;
					continue;
				}
				if (c == ']' || c == ')' || c == '}' || c == '>')
				{
					depth--;
					if (depth == 0 && c == ']' && start >= 0)
					{
						Add(text.Substring(start, i - start), outAttrs);
						start = -1;
					}
					continue;
				}
				if (c == ',' && depth == 1 && start >= 0)
				{
					Add(text.Substring(start, i - start), outAttrs);
					start = i + 1;
				}
			}
		}

		static void Add(StringView s, List<String> outAttrs)
		{
			var s;
			s.Trim();
			if (!s.IsEmpty)
				outAttrs.Add(new String(s));
		}

		/// `[A, B(1)]` ("" for none).
		public static void Format(List<String> attrs, String outText)
		{
			if (attrs.IsEmpty)
				return;
			outText.Append('[');
			for (let a in attrs)
			{
				if (@a.Index > 0)
					outText.Append(", ");
				outText.Append(a);
			}
			outText.Append(']');
		}

		/// The attribute's name without arguments ("Reflect" for `Reflect(.All)`).
		public static void NameOf(StringView attr, String outName)
		{
			var a = attr;
			int p = a.IndexOf('(');
			if (p >= 0)
				a = a.Substring(0, p);
			a.Trim();
			outName.Append(a);
		}
	}

	/// What Type Settings shows for a type declaration, read from the parse.
	class TypeDeclInfo
	{
		public String Kind = new .() ~ delete _;          // class, struct, interface, enum, extension
		public String Name = new .() ~ delete _;
		public String Modifiers = new .() ~ delete _;     // as written
		public List<String> Attributes = new .() ~ DeleteContainerAndItems!(_);
		public String GenericParams = new .() ~ delete _; // "T, U" (without the brackets)
		public List<String> Bases = new .() ~ DeleteContainerAndItems!(_);  // as written
		public String Constraints = new .() ~ delete _;   // "where T : class" (as written)
		public String Namespace = new .() ~ delete _;     // the enclosing namespace(s), dotted

		public void Read(CompilationUnit unit, Member type)
		{
			Kind.Set(type.TypeKind ?? "");
			Name.Set(type.Name);
			Modifiers.Set(type.Modifiers);
			ClearAndDeleteItems!(Attributes);
			if (type.Attributes != null)
				AttrList.Parse(type.Attributes, Attributes);
			GenericParams.Clear();
			if (type.GenericOpenTok >= 0 && type.GenericCloseTok > type.GenericOpenTok + 1)
				GenericParams.Set(unit.SpanText(type.GenericOpenTok + 1, type.GenericCloseTok - 1));
			ClearAndDeleteItems!(Bases);
			if (type.BaseColonTok >= 0 && type.BaseLastTok > type.BaseColonTok)
				SplitTopLevel(unit, type.BaseColonTok + 1, type.BaseLastTok, Bases);
			Constraints.Clear();
			if (type.WhereFirstTok >= 0)
				Constraints.Set(unit.SpanText(type.WhereFirstTok, type.WhereLastTok));
			Namespace.Clear();
			NamespaceOf(unit.Members, type, Namespace);
		}

		/// Comma-separated items between two tokens, at bracket depth 0.
		public static void SplitTopLevel(CompilationUnit unit, int first, int last, List<String> outItems)
		{
			int depth = 0;
			int segStart = first;
			for (int i = first; i <= last + 1; i++)
			{
				bool atEnd = i > last;
				StringView tx = atEnd ? "" : unit.TokenText(i);
				if (!atEnd && (tx == "<" || tx == "(" || tx == "["))
					depth++;
				else if (!atEnd && (tx == ">" || tx == ")" || tx == "]"))
					depth--;
				else if (!atEnd && tx == ">>")
					depth -= 2;
				if (atEnd || (depth == 0 && tx == ","))
				{
					if (i > segStart)
					{
						var s = unit.SpanText(segStart, i - 1);
						s.Trim();
						if (!s.IsEmpty)
							outItems.Add(new String(s));
					}
					segStart = i + 1;
				}
			}
		}

		/// The dotted namespace that encloses `target` ("" when none).
		public static bool NamespaceOf(List<Member> members, Member target, String outNs)
		{
			for (let m in members)
			{
				if (m == target)
					return true;
				if (m.Members == null || !m.HasSpan || !target.HasSpan || target.FirstTok < m.FirstTok || target.LastTok > m.LastTok)
					continue;
				if (m.Kind == .Namespace)
				{
					int len = outNs.Length;
					var nm = StringView(m.Name);
					nm.Trim();
					if (!outNs.IsEmpty && !nm.IsEmpty)
						outNs.Append('.');
					outNs.Append(nm);
					if (NamespaceOf(m.Members, target, outNs))
						return true;
					outNs.RemoveToEnd(len);
				}
				else if (m.Kind == .Type)
				{
					if (NamespaceOf(m.Members, target, outNs))
						return true;
				}
			}
			return false;
		}

		/// The innermost namespace member that holds `target` (null when none).
		public static Member NamespaceMemberOf(List<Member> members, Member target)
		{
			for (let m in members)
			{
				if (m.Members == null || !m.HasSpan || !target.HasSpan || target.FirstTok < m.FirstTok || target.LastTok > m.LastTok || m == target)
					continue;
				let inner = NamespaceMemberOf(m.Members, target);
				if (inner != null)
					return inner;
				if (m.Kind == .Namespace)
					return m;
			}
			return null;
		}
	}
}
