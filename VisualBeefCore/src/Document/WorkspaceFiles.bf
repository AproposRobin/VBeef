using System;
using System.Collections;
using System.IO;
using VisualBeef.Update;

namespace VisualBeef.Document
{
	/// A TOML file (BeefSpace.toml, BeefProj.toml) edited as text: a value is replaced in place, a key is
	/// added after the last key of its table, and everything else (comments, blank lines, key order, keys
	/// VisualBeef does not know, the line endings) is kept byte for byte. It reads the TOML the Beef IDE
	/// writes: `[Table]` headers, `key = value` lines (quoted keys too), strings, arrays and inline tables,
	/// values that span lines inside brackets, and `#` comments.
	class TomlText
	{
		public enum StmtKind
		{
			/// A blank line, a comment, or a line that is not `key = value` (kept as it is).
			Other,
			/// `[Table]` or `[[Array]]`.
			Header,
			KeyValue
		}

		/// One line (or one multi-line value) of the text. Offsets are into `Text`; `End` is after the newline.
		public struct Stmt
		{
			public StmtKind Kind;
			public int Start;
			public int End;
			/// Header: the name between the brackets. KeyValue: the key as written (quotes included).
			public int KeyStart;
			public int KeyEnd;
			/// KeyValue: the value without the trailing comment and spaces.
			public int ValStart;
			public int ValEnd;
			/// Index into the table names; 0 is the root table.
			public int Table;
		}

		/// One `key = value` of an inline table `{...}`. Offsets are into the text that was parsed.
		public struct InlineEntry
		{
			public int Start;
			public int End;
			public int KeyStart;
			public int KeyEnd;
			public int ValStart;
			public int ValEnd;
		}

		public String Text = new .() ~ delete _;
		List<Stmt> mStmts = new .() ~ delete _;
		List<String> mTables = new .() ~ DeleteContainerAndItems!(_);

		public this()
		{
			Scan();
		}

		public void Set(StringView text)
		{
			Text.Set(text);
			Scan();
		}

		public StringView NewLine => Text.Contains("\r\n") ? "\r\n" : "\n";

		// ------------------------------------------------------------------ scanning

		static bool IsSpace(char8 c) => c == ' ' || c == '\t';

		/// Index after the end of a string starting at `i` (a quote), or the end of the line for an
		/// unterminated one. Handles "basic", 'literal', """multi-line""" and '''multi-line'''.
		static int SkipString(StringView text, int i)
		{
			char8 q = text[i];
			if (i + 2 < text.Length && text[i + 1] == q && text[i + 2] == q)
			{
				int k = i + 3;
				while (k + 2 < text.Length)
				{
					if (q == '"' && text[k] == '\\')
					{
						k += 2;
						continue;
					}
					if (text[k] == q && text[k + 1] == q && text[k + 2] == q)
						return k + 3;
					k++;
				}
				return text.Length;
			}
			int k = i + 1;
			while (k < text.Length && text[k] != '\n')
			{
				if (q == '"' && text[k] == '\\')
				{
					k += 2;
					continue;
				}
				if (text[k] == q)
					return k + 1;
				k++;
			}
			return k;
		}

		static void NormalizeName(StringView raw, String outName)
		{
			outName.Clear();
			int i = 0;
			while (i < raw.Length)
			{
				let c = raw[i];
				if (c == '"' || c == '\'')
				{
					int e = SkipString(raw, i);
					let inner = StringView(raw, i, e - i);
					String s = scope .();
					if (Unquote(inner, s))
						outName.Append(s);
					i = e;
					continue;
				}
				if (!IsSpace(c))
					outName.Append(c);
				i++;
			}
		}

		void Scan()
		{
			mStmts.Clear();
			ClearAndDeleteItems!(mTables);
			mTables.Add(new String());
			int table = 0;
			let text = Text;
			int i = 0;
			while (i < text.Length)
			{
				Stmt s = default;
				s.Start = i;
				s.Table = table;
				int j = i;
				while (j < text.Length && IsSpace(text[j]))
					j++;
				int eol = text.IndexOf('\n', j);
				int lineEnd = (eol < 0) ? text.Length : eol + 1;
				if (j >= text.Length || text[j] == '\n' || text[j] == '\r' || text[j] == '#')
				{
					s.Kind = .Other;
					s.End = lineEnd;
				}
				else if (text[j] == '[')
				{
					bool arr = j + 1 < text.Length && text[j + 1] == '[';
					int ns = j + (arr ? 2 : 1);
					int ne = ns;
					while (ne < text.Length && text[ne] != ']' && text[ne] != '\n')
					{
						if (text[ne] == '"' || text[ne] == '\'')
						{
							ne = SkipString(text, ne);
							continue;
						}
						ne++;
					}
					s.Kind = .Header;
					s.KeyStart = ns;
					s.KeyEnd = Math.Min(ne, text.Length);
					s.End = lineEnd;
					String name = new .();
					NormalizeName(StringView(text, s.KeyStart, s.KeyEnd - s.KeyStart), name);
					mTables.Add(name);
					table = mTables.Count - 1;
					s.Table = table;
				}
				else
				{
					// The key: up to the '=' outside quotes.
					int k = j;
					int eq = -1;
					while (k < text.Length && text[k] != '\n')
					{
						let c = text[k];
						if (c == '"' || c == '\'')
						{
							k = SkipString(text, k);
							continue;
						}
						if (c == '=')
						{
							eq = k;
							break;
						}
						k++;
					}
					if (eq < 0)
					{
						s.Kind = .Other;
						s.End = lineEnd;
					}
					else
					{
						s.Kind = .KeyValue;
						s.KeyStart = j;
						int ke = eq;
						while (ke > j && IsSpace(text[ke - 1]))
							ke--;
						s.KeyEnd = ke;
						int vs = eq + 1;
						while (vs < text.Length && IsSpace(text[vs]))
							vs++;
						s.ValStart = vs;
						s.ValEnd = vs;
						int depth = 0;
						int v = vs;
						while (v < text.Length)
						{
							let c = text[v];
							if (c == '"' || c == '\'')
							{
								v = SkipString(text, v);
								s.ValEnd = v;
								continue;
							}
							if (c == '#')
							{
								while (v < text.Length && text[v] != '\n')
									v++;
								continue;
							}
							if (c == '\n')
							{
								if (depth <= 0)
									break;
								v++;
								continue;
							}
							if (c == '[' || c == '{')
								depth++;
							else if (c == ']' || c == '}')
								depth--;
							if (!IsSpace(c) && c != '\r')
								s.ValEnd = v + 1;
							v++;
						}
						s.End = (v < text.Length) ? v + 1 : text.Length;
					}
				}
				mStmts.Add(s);
				i = s.End;
			}
		}

		// ------------------------------------------------------------------ strings and keys

		/// The text of a TOML string value ("basic" with escapes, or 'literal'); false when `raw` is not a string.
		public static bool Unquote(StringView rawIn, String outText)
		{
			var raw = rawIn;
			raw.Trim();
			outText.Clear();
			if (raw.Length < 2)
				return false;
			let q = raw[0];
			if ((q != '"' && q != '\'') || raw[raw.Length - 1] != q)
				return false;
			var inner = raw.Substring(1, raw.Length - 2);
			if (raw.Length >= 6 && raw[1] == q && raw[2] == q && raw[raw.Length - 2] == q && raw[raw.Length - 3] == q)
			{
				// """multi-line""": drop the extra quotes and a first newline.
				inner = raw.Substring(3, raw.Length - 6);
				if (inner.StartsWith("\r\n"))
					inner.RemoveFromStart(2);
				else if (inner.StartsWith('\n'))
					inner.RemoveFromStart(1);
			}
			if (q == '\'')
			{
				outText.Append(inner);
				return true;
			}
			for (int i = 0; i < inner.Length; i++)
			{
				let c = inner[i];
				if (c != '\\' || i + 1 >= inner.Length)
				{
					outText.Append(c);
					continue;
				}
				i++;
				switch (inner[i])
				{
				case 'n': outText.Append('\n');
				case 't': outText.Append('\t');
				case 'r': outText.Append('\r');
				case '"': outText.Append('"');
				case '\\': outText.Append('\\');
				default:
					outText.Append('\\');
					outText.Append(inner[i]);
				}
			}
			return true;
		}

		/// `s` as a TOML basic string, quotes included.
		public static void Quote(StringView s, String outText)
		{
			outText.Append('"');
			for (let c in s)
			{
				switch (c)
				{
				case '"': outText.Append("\\\"");
				case '\\': outText.Append("\\\\");
				case '\n': outText.Append("\\n");
				case '\r': outText.Append("\\r");
				case '\t': outText.Append("\\t");
				default: outText.Append(c);
				}
			}
			outText.Append('"');
		}

		/// A key as TOML writes it: bare when it is letters, digits, `_` and `-`, else quoted.
		public static void FormatKey(StringView key, String outText)
		{
			bool bare = !key.IsEmpty;
			for (let c in key)
				if (!(c.IsLetterOrDigit || c == '_' || c == '-') || (uint8)c >= 0x80)
					bare = false;
			if (bare)
				outText.Append(key);
			else
				Quote(key, outText);
		}

		/// A key as written (bare or quoted) to its name.
		public static void KeyName(StringView rawIn, String outName)
		{
			var raw = rawIn;
			raw.Trim();
			if (!Unquote(raw, outName))
				outName.Set(raw);
		}

		/// The strings of an array value `["a", "b"]`; false when `raw` is not an array of strings.
		public static bool ParseStringArray(StringView rawIn, List<String> outItems)
		{
			var raw = rawIn;
			raw.Trim();
			if (!raw.StartsWith('[') || !raw.EndsWith(']'))
				return false;
			int i = 1;
			while (i < raw.Length - 1)
			{
				let c = raw[i];
				if (c == '"' || c == '\'')
				{
					int e = SkipString(raw, i);
					String s = new .();
					Unquote(StringView(raw, i, e - i), s);
					outItems.Add(s);
					i = e;
					continue;
				}
				if (c == '#')
				{
					while (i < raw.Length && raw[i] != '\n')
						i++;
					continue;
				}
				i++;
			}
			return true;
		}

		public static void FormatStringArray(List<String> items, String outText)
		{
			outText.Append('[');
			for (let s in items)
			{
				if (@s.Index > 0)
					outText.Append(", ");
				Quote(s, outText);
			}
			outText.Append(']');
		}

		// ------------------------------------------------------------------ reading

		public StringView TableOf(Stmt s) => mTables[s.Table];

		void KeyOf(Stmt s, String outKey)
		{
			KeyName(StringView(Text, s.KeyStart, s.KeyEnd - s.KeyStart), outKey);
		}

		int FindStmt(StringView table, StringView key)
		{
			String k = scope .();
			for (let s in mStmts)
			{
				if (s.Kind != .KeyValue || mTables[s.Table] != table)
					continue;
				k.Clear();
				KeyOf(s, k);
				if (k == key)
					return @s.Index;
			}
			return -1;
		}

		int HeaderIndex(StringView table)
		{
			for (let s in mStmts)
				if (s.Kind == .Header && mTables[s.Table] == table)
					return @s.Index;
			return -1;
		}

		public bool HasTable(StringView table) => table.IsEmpty || HeaderIndex(table) >= 0;

		/// The value of `table.key` as written, or false.
		public bool GetRaw(StringView table, StringView key, out StringView raw)
		{
			raw = default;
			int i = FindStmt(table, key);
			if (i < 0)
				return false;
			let s = mStmts[i];
			raw = StringView(Text, s.ValStart, s.ValEnd - s.ValStart);
			return true;
		}

		/// The string value of `table.key`; false when missing or not a string.
		public bool GetString(StringView table, StringView key, String outText)
		{
			outText.Clear();
			if (!GetRaw(table, key, let raw))
				return false;
			return Unquote(raw, outText);
		}

		public bool GetStringArray(StringView table, StringView key, List<String> outItems)
		{
			if (!GetRaw(table, key, let raw))
				return false;
			return ParseStringArray(raw, outItems);
		}

		/// Names of the `[Table]` headers in file order.
		public void Tables(List<String> outNames)
		{
			for (let s in mStmts)
				if (s.Kind == .Header)
					outNames.Add(new String(mTables[s.Table]));
		}

		/// Keys and raw values of a table, in file order.
		public void Entries(StringView table, List<(String key, String raw)> outEntries)
		{
			for (let s in mStmts)
			{
				if (s.Kind != .KeyValue || mTables[s.Table] != table)
					continue;
				String k = new .();
				KeyOf(s, k);
				outEntries.Add((k, new String(StringView(Text, s.ValStart, s.ValEnd - s.ValStart))));
			}
		}

		// ------------------------------------------------------------------ editing

		void Replace(int start, int end, StringView with)
		{
			Text.Remove(start, end - start);
			Text.Insert(start, with);
			Scan();
		}

		/// Sets `table.key` to the raw TOML value `raw`: in place when the key exists, else after the last
		/// key of the table (the table is added at the end of the file when it is missing).
		public void SetRaw(StringView table, StringView key, StringView raw)
		{
			int i = FindStmt(table, key);
			if (i >= 0)
			{
				let s = mStmts[i];
				if (StringView(Text, s.ValStart, s.ValEnd - s.ValStart) != raw)
					Replace(s.ValStart, s.ValEnd, raw);
				return;
			}
			let nl = NewLine;
			String line = scope .();
			FormatKey(key, line);
			line.Append(" = ");
			line.Append(raw);
			line.Append(nl);
			int hdr = table.IsEmpty ? -1 : HeaderIndex(table);
			if (!table.IsEmpty && hdr < 0)
			{
				String add = scope .();
				if (!Text.IsEmpty && !Text.EndsWith('\n'))
					add.Append(nl);
				if (!Text.IsEmpty && !Text.EndsWith(scope $"{nl}{nl}"))
					add.Append(nl);
				add.Append('[');
				add.Append(table);
				add.Append(']');
				add.Append(nl);
				add.Append(line);
				Text.Append(add);
				Scan();
				return;
			}
			int at = -1;
			for (let s in mStmts)
				if (s.Kind == .KeyValue && mTables[s.Table] == table)
					at = s.End;
			if (at < 0)
			{
				if (table.IsEmpty)
				{
					// No root key yet: before the first table.
					at = 0;
					for (let s in mStmts)
						if (s.Kind == .Header)
						{
							at = s.Start;
							break;
						}
				}
				else
					at = mStmts[hdr].End;
			}
			if (at > 0 && Text[at - 1] != '\n')
				line.Insert(0, nl);
			Text.Insert(at, line);
			Scan();
		}

		public void SetString(StringView table, StringView key, StringView value)
		{
			String raw = scope .();
			Quote(value, raw);
			SetRaw(table, key, raw);
		}

		public void SetStringArray(StringView table, StringView key, List<String> items)
		{
			String raw = scope .();
			FormatStringArray(items, raw);
			SetRaw(table, key, raw);
		}

		/// Removes the `table.key` line (with its comment). False when it was not there.
		public bool Remove(StringView table, StringView key)
		{
			int i = FindStmt(table, key);
			if (i < 0)
				return false;
			let s = mStmts[i];
			Replace(s.Start, s.End, "");
			return true;
		}

		/// Removes `[table]` when nothing but blank lines follow it (up to the next table).
		public bool RemoveTableIfEmpty(StringView table)
		{
			int h = HeaderIndex(table);
			if (h < 0)
				return false;
			int end = Text.Length;
			for (int i = h + 1; i < mStmts.Count; i++)
			{
				let s = mStmts[i];
				if (s.Kind == .Header)
				{
					end = s.Start;
					break;
				}
				if (s.Kind == .KeyValue)
					return false;
				var line = StringView(Text, s.Start, s.End - s.Start);
				line.Trim();
				if (!line.IsEmpty)
					return false; // a comment stays with its table
			}
			int start = mStmts[h].Start;
			// Also the blank line that separated it from the table before, when it is the last table.
			if (end == Text.Length)
			{
				while (start > 0 && (Text[start - 1] == '\n' || Text[start - 1] == '\r'))
				{
					int prevEol = start - 1;
					if (Text[prevEol] == '\n' && prevEol > 0 && Text[prevEol - 1] == '\r')
						prevEol--;
					int lineStart = Text.LastIndexOf('\n', Math.Max(prevEol - 1, 0));
					lineStart = (lineStart < 0 || prevEol == 0) ? 0 : lineStart + 1;
					var prev = StringView(Text, lineStart, prevEol - lineStart);
					prev.Trim();
					if (!prev.IsEmpty || lineStart == 0)
						break;
					start = lineStart;
				}
			}
			Replace(start, end, "");
			return true;
		}

		// ------------------------------------------------------------------ inline tables

		/// The entries of the inline table `text[vs..ve)` (`{...}`).
		public static void ParseInline(StringView text, int vs, int ve, List<InlineEntry> outEntries)
		{
			if (vs >= ve || text[vs] != '{')
				return;
			int close = ve - 1;
			while (close > vs && text[close] != '}')
				close--;
			if (close <= vs)
				close = ve;
			int segStart = vs + 1;
			int depth = 0;
			int i = vs + 1;
			while (i <= close)
			{
				bool atEnd = i == close;
				char8 c = atEnd ? ',' : text[i];
				if (!atEnd && (c == '"' || c == '\''))
				{
					i = SkipString(text, i);
					continue;
				}
				if (c == '{' || c == '[')
					depth++;
				else if (c == '}' || c == ']')
					depth--;
				else if (c == ',' && depth == 0)
				{
					int s = segStart;
					int e = i;
					while (s < e && (IsSpace(text[s]) || text[s] == '\r' || text[s] == '\n'))
						s++;
					while (e > s && (IsSpace(text[e - 1]) || text[e - 1] == '\r' || text[e - 1] == '\n'))
						e--;
					if (e > s)
					{
						InlineEntry en = default;
						en.Start = s;
						en.End = e;
						int eq = -1;
						int k = s;
						while (k < e)
						{
							if (text[k] == '"' || text[k] == '\'')
							{
								k = SkipString(text, k);
								continue;
							}
							if (text[k] == '=')
							{
								eq = k;
								break;
							}
							k++;
						}
						if (eq > s)
						{
							en.KeyStart = s;
							int ke = eq;
							while (ke > s && IsSpace(text[ke - 1]))
								ke--;
							en.KeyEnd = ke;
							int v = eq + 1;
							while (v < e && IsSpace(text[v]))
								v++;
							en.ValStart = v;
							en.ValEnd = e;
							outEntries.Add(en);
						}
					}
					segStart = i + 1;
				}
				i++;
			}
		}

		/// The raw value of `key` inside the inline table `raw` (`{Path = "x"}`).
		public static bool InlineGet(StringView raw, StringView key, String outRaw)
		{
			List<InlineEntry> entries = scope .();
			ParseInline(raw, 0, raw.Length, entries);
			String k = scope .();
			for (let en in entries)
			{
				k.Clear();
				KeyName(StringView(raw, en.KeyStart, en.KeyEnd - en.KeyStart), k);
				if (k == key)
				{
					outRaw.Set(StringView(raw, en.ValStart, en.ValEnd - en.ValStart));
					return true;
				}
			}
			return false;
		}

		/// Sets `key` inside the inline table text `raw` (in place, or added at the end).
		public static void InlineSet(String raw, StringView key, StringView valueRaw)
		{
			List<InlineEntry> entries = scope .();
			ParseInline(raw, 0, raw.Length, entries);
			String k = scope .();
			for (let en in entries)
			{
				k.Clear();
				KeyName(StringView(raw, en.KeyStart, en.KeyEnd - en.KeyStart), k);
				if (k == key)
				{
					raw.Remove(en.ValStart, en.ValEnd - en.ValStart);
					raw.Insert(en.ValStart, valueRaw);
					return;
				}
			}
			String add = scope .();
			FormatKey(key, add);
			add.Append(" = ");
			add.Append(valueRaw);
			if (entries.IsEmpty)
			{
				raw.Set("{");
				raw.Append(add);
				raw.Append('}');
				return;
			}
			raw.Insert(entries.Back.End, scope String()..Append(", ")..Append(add));
		}

		// ------------------------------------------------------------------ maps (Projects, Dependencies)

		/// How the file writes a map such as `Projects` or `Dependencies`: as a root inline table
		/// (`Dependencies = {corlib = "*"}`) or as a table (`[Dependencies]` with one key per line).
		public enum MapForm
		{
			None,
			Inline,
			Table
		}

		public MapForm FormOf(StringView name)
		{
			if (GetRaw("", name, let raw) && raw.StartsWith('{'))
				return .Inline;
			if (HeaderIndex(name) >= 0)
				return .Table;
			return .None;
		}

		/// Keys and raw values of the map `name`, in file order.
		public void MapEntries(StringView name, List<(String key, String raw)> outEntries)
		{
			switch (FormOf(name))
			{
			case .Inline:
				let s = mStmts[FindStmt("", name)];
				List<InlineEntry> entries = scope .();
				ParseInline(Text, s.ValStart, s.ValEnd, entries);
				for (let en in entries)
				{
					String k = new .();
					KeyName(StringView(Text, en.KeyStart, en.KeyEnd - en.KeyStart), k);
					outEntries.Add((k, new String(StringView(Text, en.ValStart, en.ValEnd - en.ValStart))));
				}
			case .Table:
				Entries(name, outEntries);
			case .None:
			}
		}

		bool FindInline(StringView name, StringView key, out InlineEntry outEntry, out int index, List<InlineEntry> entries)
		{
			outEntry = default;
			index = -1;
			let s = mStmts[FindStmt("", name)];
			ParseInline(Text, s.ValStart, s.ValEnd, entries);
			String k = scope .();
			for (let en in entries)
			{
				k.Clear();
				KeyName(StringView(Text, en.KeyStart, en.KeyEnd - en.KeyStart), k);
				if (k == key)
				{
					outEntry = en;
					index = @en.Index;
					return true;
				}
			}
			return false;
		}

		public bool MapGet(StringView name, StringView key, String outRaw)
		{
			List<(String key, String raw)> entries = scope .();
			defer { for (let e in entries) { delete e.key; delete e.raw; } }
			MapEntries(name, entries);
			for (let e in entries)
				if (e.key == key)
				{
					outRaw.Set(e.raw);
					return true;
				}
			return false;
		}

		/// Sets `name.key` to `raw` in the map's own form; a missing map is added as a root inline table.
		public void MapSet(StringView name, StringView key, StringView raw)
		{
			switch (FormOf(name))
			{
			case .Inline:
				List<InlineEntry> entries = scope .();
				if (FindInline(name, key, let en, ?, entries))
				{
					if (StringView(Text, en.ValStart, en.ValEnd - en.ValStart) != raw)
						Replace(en.ValStart, en.ValEnd, raw);
					return;
				}
				String add = scope .();
				FormatKey(key, add);
				add.Append(" = ");
				add.Append(raw);
				let s = mStmts[FindStmt("", name)];
				if (entries.IsEmpty)
				{
					String whole = scope .();
					whole.Append('{');
					whole.Append(add);
					whole.Append('}');
					Replace(s.ValStart, s.ValEnd, whole);
				}
				else
					Replace(entries.Back.End, entries.Back.End, scope String()..Append(", ")..Append(add));
			case .Table:
				SetRaw(name, key, raw);
			case .None:
				String whole = scope .();
				whole.Append('{');
				FormatKey(key, whole);
				whole.Append(" = ");
				whole.Append(raw);
				whole.Append('}');
				SetRaw("", name, whole);
			}
		}

		/// Removes `name.key`; false when it was not there.
		public bool MapRemove(StringView name, StringView key)
		{
			switch (FormOf(name))
			{
			case .Inline:
				List<InlineEntry> entries = scope .();
				if (!FindInline(name, key, let en, let index, entries))
					return false;
				if (index + 1 < entries.Count)
					Replace(en.Start, entries[index + 1].Start, "");
				else if (index > 0)
					Replace(entries[index - 1].End, en.End, "");
				else
					Replace(en.Start, en.End, "");
				return true;
			case .Table:
				return Remove(name, key);
			case .None:
				return false;
			}
		}

		/// Renames the key `oldKey` of the map to `newKey`, keeping its value; false when it was not there.
		public bool MapRenameKey(StringView name, StringView oldKey, StringView newKey)
		{
			String formatted = scope .();
			FormatKey(newKey, formatted);
			switch (FormOf(name))
			{
			case .Inline:
				List<InlineEntry> entries = scope .();
				if (!FindInline(name, oldKey, let en, ?, entries))
					return false;
				Replace(en.KeyStart, en.KeyEnd, formatted);
				return true;
			case .Table:
				int i = FindStmt(name, oldKey);
				if (i < 0)
					return false;
				let s = mStmts[i];
				Replace(s.KeyStart, s.KeyEnd, formatted);
				return true;
			case .None:
				return false;
			}
		}
	}

	/// A project of a workspace (one entry of BeefSpace.toml `Projects`).
	class WorkspaceProject
	{
		public String Name = new .() ~ delete _;
		/// The path as BeefSpace.toml writes it ("Core", ".", "../Lib"); empty for a library listed by version (`SDL2 = "*"`).
		public String RelPath = new .() ~ delete _;
		/// The absolute folder (platform separators, no trailing separator); empty when there is no path.
		public String Dir = new .() ~ delete _;

		public bool HasPath => !Dir.IsEmpty;
	}

	/// BeefSpace.toml read: its projects and the startup project.
	class BeefWorkspace
	{
		public String FilePath = new .() ~ delete _;
		public String Dir = new .() ~ delete _;
		public String Startup = new .() ~ delete _;
		public List<WorkspaceProject> Projects = new .() ~ DeleteContainerAndItems!(_);

		public bool Load(StringView wsFile)
		{
			FilePath.Set(wsFile);
			Dir.Clear();
			Startup.Clear();
			ClearAndDeleteItems!(Projects);
			WorkspaceFiles.ParentDir(wsFile, Dir);
			String text = scope .();
			if (File.ReadAllText(wsFile, text, true) case .Err)
				return false;
			TomlText t = scope .();
			t.Set(text);
			Read(t);
			return true;
		}

		public void Read(TomlText t)
		{
			ClearAndDeleteItems!(Projects);
			t.GetString("Workspace", "StartupProject", Startup);
			List<(String key, String raw)> entries = scope .();
			defer { for (let e in entries) { delete e.key; delete e.raw; } }
			t.MapEntries("Projects", entries);
			for (let e in entries)
			{
				WorkspaceProject p = new .();
				p.Name.Set(e.key);
				String pathRaw = scope .();
				if (e.raw.StartsWith('{') && TomlText.InlineGet(e.raw, "Path", pathRaw))
				{
					TomlText.Unquote(pathRaw, p.RelPath);
					WorkspaceFiles.Resolve(Dir, p.RelPath, p.Dir);
				}
				Projects.Add(p);
			}
		}

		public WorkspaceProject Find(StringView name)
		{
			for (let p in Projects)
				if (p.Name == name)
					return p;
			for (let p in Projects)
				if (StringView.Compare(p.Name, name, true) == 0)
					return p;
			return null;
		}

		public WorkspaceProject FindDir(StringView dir)
		{
			for (let p in Projects)
				if (p.HasPath && ProjectIndex.SamePath(p.Dir, dir))
					return p;
			return null;
		}

		/// The project whose folder holds `path` (the deepest one), or null.
		public WorkspaceProject ProjectOf(StringView path)
		{
			WorkspaceProject best = null;
			for (let p in Projects)
			{
				if (!p.HasPath)
					continue;
				if (ProjectIndex.SamePath(p.Dir, path) || WorkspaceFiles.IsUnder(path, p.Dir))
					if (best == null || p.Dir.Length > best.Dir.Length)
						best = p;
			}
			return best;
		}
	}

	/// What a project builds, as Project Settings shows it.
	enum ProjectBuildKind
	{
		/// `TargetType = "BeefConsoleApplication"` (also the default when TargetType is missing).
		Console,
		/// `TargetType = "BeefGUIApplication"`.
		Windows,
		/// `TargetType = "BeefLib"`.
		Library,
		/// `TargetType = "BeefLib"` with `BuildKind = "DynamicLib"` in its configurations: a DLL.
		DynamicLibrary,
		/// Any other TargetType (kept as it is).
		Other
	}

	/// A project's BeefProj.toml, read and edited as text.
	class BeefProjectFile
	{
		public String Dir = new .() ~ delete _;
		public String FilePath = new .() ~ delete _;
		public TomlText Toml = new .() ~ delete _;
		/// The text as read (for "did anything change").
		public String Original = new .() ~ delete _;

		public const String FileName = "BeefProj.toml";

		public bool Load(StringView dir)
		{
			Dir.Set(dir);
			FilePath.Clear();
			WorkspaceFiles.Join(dir, FileName, FilePath);
			String text = scope .();
			if (File.ReadAllText(FilePath, text, true) case .Err)
				return false;
			Original.Set(text);
			Toml.Set(text);
			return true;
		}

		public bool Changed => Toml.Text != Original;

		/// `[Project] Name`, else the folder name.
		public void GetName(String outName)
		{
			if (Toml.GetString("Project", "Name", outName) && !outName.IsEmpty)
				return;
			outName.Clear();
			Path.GetFileName(Dir, outName);
		}

		public void GetTargetType(String outType)
		{
			if (!Toml.GetString("Project", "TargetType", outType) || outType.IsEmpty)
				outType.Set("BeefConsoleApplication");
		}

		/// `Configs.<Config>.<Platform>` tables as "<Config>.<Platform>", in file order.
		public void ConfigSections(List<String> outSections)
		{
			List<String> tables = scope .();
			defer { ClearAndDeleteItems!(tables); }
			Toml.Tables(tables);
			for (let t in tables)
				if (t.StartsWith("Configs."))
				{
					let rest = t.Substring(8);
					bool dup = false;
					for (let s in outSections)
						if (s == rest)
							dup = true;
					if (!dup)
						outSections.Add(new String(rest));
				}
		}

		public ProjectBuildKind Kind
		{
			get
			{
				String tt = scope .();
				GetTargetType(tt);
				switch (tt)
				{
				case "BeefConsoleApplication": return .Console;
				case "BeefGUIApplication": return .Windows;
				case "BeefDynLib": return .DynamicLibrary;
				case "BeefLib":
					List<String> sections = scope .();
					defer { ClearAndDeleteItems!(sections); }
					ConfigSections(sections);
					String bk = scope .();
					for (let s in sections)
						if (Toml.GetString(scope $"Configs.{s}", "BuildKind", bk) && bk == "DynamicLib")
							return .DynamicLibrary;
					return .Library;
				default: return .Other;
				}
			}
		}

		/// Names of the projects and libraries this project depends on (`Dependencies`).
		public void Dependencies(List<String> outNames)
		{
			List<(String key, String raw)> entries = scope .();
			defer { for (let e in entries) { delete e.key; delete e.raw; } }
			Toml.MapEntries("Dependencies", entries);
			for (let e in entries)
				outNames.Add(new String(e.key));
		}

		public bool DependsOn(StringView name)
		{
			String raw = scope .();
			return Toml.MapGet("Dependencies", name, raw);
		}
	}

	/// Edits of BeefSpace.toml and BeefProj.toml: each operation changes only the lines it is about, says
	/// what it changed (one line per change, for the Output Log) and writes the files atomically
	/// (FileSafety.AtomicWrite). An operation that touches several files writes them in order and, when
	/// one write fails, puts the ones already written back.
	static class WorkspaceFiles
	{
		public const String WorkspaceFileName = "BeefSpace.toml";

		// ------------------------------------------------------------------ paths

		static bool IsSep(char8 c) => c == '/' || c == '\\';

		public static void Join(StringView dir, StringView name, String outPath)
		{
			outPath.Append(dir);
			if (!outPath.IsEmpty && !IsSep(outPath[outPath.Length - 1]))
				outPath.Append(Path.DirectorySeparatorChar);
			outPath.Append(name);
		}

		public static void ParentDir(StringView path, String outDir)
		{
			outDir.Clear();
			if (Path.GetDirectoryPath(path, outDir) case .Err)
				outDir.Clear();
		}

		public static bool IsUnder(StringView path, StringView dir)
		{
			if (dir.IsEmpty || path.Length <= dir.Length)
				return false;
			if (!ProjectIndex.SamePath(path.Substring(0, dir.Length), dir))
				return false;
			return IsSep(path[dir.Length]) || IsSep(dir[dir.Length - 1]);
		}

		/// Splits a path into its folder names ("." dropped, ".." folded).
		static void Segments(StringView path, List<StringView> outSegs)
		{
			for (let seg in path.Split('/', '\\'))
			{
				if (seg.IsEmpty || seg == ".")
				{
					if (outSegs.IsEmpty && seg.IsEmpty && !path.IsEmpty && IsSep(path[0]))
						outSegs.Add(""); // a rooted path ("/home/...")
					continue;
				}
				if (seg == ".." && !outSegs.IsEmpty && outSegs.Back != ".." && !outSegs.Back.IsEmpty && !outSegs.Back.EndsWith(':'))
				{
					outSegs.PopBack();
					continue;
				}
				outSegs.Add(seg);
			}
		}

		/// An absolute, normalized folder: `rel` against `baseDir` (an absolute `rel` is kept), with the
		/// platform's separators and no trailing separator.
		public static void Resolve(StringView baseDir, StringView rel, String outPath)
		{
			outPath.Clear();
			String joined = scope .();
			bool rooted = rel.StartsWith('/') || rel.StartsWith('\\') || (rel.Length >= 2 && rel[1] == ':');
			if (rooted)
				joined.Set(rel);
			else
			{
				joined.Set(baseDir);
				joined.Append('/');
				joined.Append(rel);
			}
			List<StringView> segs = scope .();
			Segments(joined, segs);
			for (let s in segs)
			{
				if ((@s.Index > 0 || s.IsEmpty) && !(outPath.EndsWith('/') || outPath.EndsWith('\\')))
					outPath.Append(Path.DirectorySeparatorChar);
				outPath.Append(s);
			}
			if (outPath.IsEmpty)
				outPath.Set(baseDir);
		}

		/// `toPath` relative to `fromDir` with `/` (".." where needed, "." for the same folder); an
		/// absolute path with `/` when they are on different drives.
		public static void RelativePath(StringView fromDir, StringView toPath, String outRel)
		{
			outRel.Clear();
			List<StringView> a = scope .();
			List<StringView> b = scope .();
			Segments(fromDir, a);
			Segments(toPath, b);
			int common = 0;
			while (common < a.Count && common < b.Count && StringView.Compare(a[common], b[common], true) == 0)
				common++;
			if (common == 0)
			{
				outRel.Set(toPath);
				outRel.Replace('\\', '/');
				return;
			}
			for (int i = common; i < a.Count; i++)
			{
				if (!outRel.IsEmpty)
					outRel.Append('/');
				outRel.Append("..");
			}
			for (int i = common; i < b.Count; i++)
			{
				if (!outRel.IsEmpty)
					outRel.Append('/');
				outRel.Append(b[i]);
			}
			if (outRel.IsEmpty)
				outRel.Set(".");
		}

		/// The nearest BeefSpace.toml at or above `folder`, not above `stopAt` (when given); empty when none.
		public static void FindWorkspace(StringView folder, String outFile, StringView stopAt = default)
		{
			outFile.Clear();
			String dir = scope .(folder);
			while (dir.Length > 1 && IsSep(dir[dir.Length - 1]))
				dir.RemoveFromEnd(1);
			for (int depth = 0; depth < 32 && !dir.IsEmpty; depth++)
			{
				String probe = scope .();
				Join(dir, WorkspaceFileName, probe);
				if (File.Exists(probe))
				{
					outFile.Set(probe);
					return;
				}
				if (!stopAt.IsEmpty && ProjectIndex.SamePath(dir, stopAt))
					return;
				String parent = scope .();
				ParentDir(dir, parent);
				if (parent.IsEmpty || parent.Length >= dir.Length)
					return;
				dir.Set(parent);
			}
		}

		/// A name the workspace and BeefBuild accept for a project: letters, digits, `_`, `-` and `.`, not
		/// starting with a digit or a dot.
		public static bool ValidProjectName(StringView name, String outError)
		{
			if (name.IsEmpty)
			{
				outError?.Set("Enter a name.");
				return false;
			}
			if (name[0].IsDigit || name[0] == '.' || name[0] == '-')
			{
				outError?.Set("A project name starts with a letter or '_'.");
				return false;
			}
			for (let c in name)
				if (!(c.IsLetterOrDigit || c == '_' || c == '-' || c == '.') || (uint8)c >= 0x80)
				{
					outError?.Set(scope $"'{c}' can't be used in a project name (letters, digits, _ - and . only).");
					return false;
				}
			return true;
		}

		// ------------------------------------------------------------------ writing

		/// The files one operation writes: (path, text before, text after).
		public class Batch
		{
			public List<(String path, String before, String after)> Files = new .() ~ { for (let f in _) { delete f.path; delete f.before; delete f.after; } delete _; };

			/// Adds (or updates) the new text of a file; a file whose text did not change is left out.
			public void Put(StringView path, StringView before, StringView after)
			{
				for (let f in Files)
					if (ProjectIndex.SamePath(f.path, path))
					{
						f.after.Set(after);
						return;
					}
				if (before == after)
					return;
				Files.Add((new String(path), new String(before), new String(after)));
			}

			public Result<void> Commit(String outError)
			{
				if (FileSafety.ReadOnlyProject)
				{
					outError.Set(FileSafety.ReadOnlyMessage);
					return .Err;
				}
				for (let f in Files)
				{
					if (f.before == f.after)
						continue;
					String err = scope .();
					if (FileSafety.AtomicWrite(f.path, f.after, FileSafety.KeepBackup, err) case .Err)
					{
						// Put back what this operation already wrote.
						for (int i < @f.Index)
							if (File.Exists(Files[i].path))
								FileSafety.AtomicWrite(Files[i].path, Files[i].before, false).IgnoreError();
						outError.Set(err.IsEmpty ? scope $"Could not write {f.path}" : err);
						return .Err;
					}
				}
				return .Ok;
			}
		}

		static void FileLabel(StringView path, String outLabel)
		{
			String name = scope .();
			Path.GetFileName(path, name);
			String dir = scope .();
			ParentDir(path, dir);
			String folder = scope .();
			Path.GetFileName(dir, folder);
			outLabel.AppendF("{}/{}", folder, name);
		}

		static void Note(List<String> changes, StringView file, StringView what)
		{
			if (changes == null)
				return;
			String label = scope .();
			FileLabel(file, label);
			changes.Add(new String()..AppendF("{}: {}", label, what));
		}

		static bool LoadToml(StringView path, TomlText outToml, String outText, String outError)
		{
			if (File.ReadAllText(path, outText, true) case .Err)
			{
				outError.Set(scope $"Could not read {path}");
				return false;
			}
			outToml.Set(outText);
			return true;
		}

		static void ShowRaw(StringView raw, String outText)
		{
			if (raw.IsEmpty)
				outText.Append("(not set)");
			else
				outText.Append(raw);
		}

		// ------------------------------------------------------------------ workspace edits

		/// Adds the project folder `projDir` (named `name`) to the workspace `wsFile`, by a path relative
		/// to the workspace folder. A missing BeefSpace.toml is created with the project as startup project.
		public static Result<void> AddProject(StringView wsFile, StringView name, StringView projDir, List<String> changes, String outError)
		{
			String wsDir = scope .();
			ParentDir(wsFile, wsDir);
			String rel = scope .();
			RelativePath(wsDir, projDir, rel);
			TomlText t = scope .();
			String before = scope .();
			bool create = !File.Exists(wsFile);
			if (create)
			{
				t.Set("FileVersion = 1\n");
			}
			else if (!LoadToml(wsFile, t, before, outError))
				return .Err;
			BeefWorkspace ws = scope .();
			ws.Dir.Set(wsDir);
			ws.Read(t);
			if (ws.Find(name) != null)
			{
				outError.Set(scope $"The workspace already has a project named '{name}'.");
				return .Err;
			}
			let same = ws.FindDir(projDir);
			if (same != null)
			{
				outError.Set(scope $"That folder is already in the workspace as '{same.Name}'.");
				return .Err;
			}
			String value = scope .();
			value.Append("{Path = ");
			TomlText.Quote(rel, value);
			value.Append('}');
			t.MapSet("Projects", name, value);
			Note(changes, wsFile, scope $"added project {name} (Path = \"{rel}\")");
			if (create || !t.HasTable("Workspace") || ws.Startup.IsEmpty)
			{
				t.SetString("Workspace", "StartupProject", name);
				Note(changes, wsFile, scope $"startup project {name}");
			}
			if (create)
				Note(changes, wsFile, "created");
			Batch b = scope .();
			b.Put(wsFile, before, t.Text);
			if (create && b.Files.IsEmpty)
				b.Files.Add((new String(wsFile), new String(), new String(t.Text)));
			return b.Commit(outError);
		}

		/// Makes `name` the workspace's startup project.
		public static Result<void> SetStartup(StringView wsFile, StringView name, List<String> changes, String outError)
		{
			TomlText t = scope .();
			String before = scope .();
			if (!LoadToml(wsFile, t, before, outError))
				return .Err;
			String old = scope .();
			t.GetString("Workspace", "StartupProject", old);
			if (old == name)
				return .Ok;
			t.SetString("Workspace", "StartupProject", name);
			Note(changes, wsFile, scope $"StartupProject = \"{name}\" (was {(old.IsEmpty ? "not set" : old)})");
			Batch b = scope .();
			b.Put(wsFile, before, t.Text);
			return b.Commit(outError);
		}

		/// Registers an existing project folder (holding BeefProj.toml) in the workspace; `outName` is its name.
		public static Result<void> AddExistingProject(StringView wsFile, StringView projDir, String outName, List<String> changes, String outError)
		{
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"{projDir} has no BeefProj.toml: choose the folder of a Beef project.");
				return .Err;
			}
			pf.GetName(outName);
			if (!ValidProjectName(outName, null))
			{
				outError.Set(scope $"The project's name '{outName}' can't be used in a workspace.");
				return .Err;
			}
			return AddProject(wsFile, outName, projDir, changes, outError);
		}

		/// Writes a new project `name` in `location/name` (BeefProj.toml and one source file) and registers it in
		/// the workspace (`wsFile`, created when missing). A program gets `src/Program.bf` with a `Main`; a library
		/// `src/<name>.bf` with a static class. `outMainFile` is the source file written. Nothing is overwritten.
		public static Result<void> CreateProject(StringView wsFile, StringView location, StringView name, bool library, String outMainFile, List<String> changes, String outError)
		{
			if (!ValidProjectName(name, outError))
				return .Err;
			if (FileSafety.ReadOnlyProject)
			{
				outError.Set(FileSafety.ReadOnlyMessage);
				return .Err;
			}
			String projDir = scope .();
			Join(location, name, projDir);
			if (Directory.Exists(projDir) || File.Exists(projDir))
			{
				outError.Set(scope $"'{name}' already exists in {location}.");
				return .Err;
			}
			if (File.Exists(wsFile))
			{
				BeefWorkspace ws = scope .();
				if (ws.Load(wsFile) && ws.Find(name) != null)
				{
					outError.Set(scope $"The workspace already has a project named '{name}'.");
					return .Err;
				}
			}
			String ident = scope .();
			for (let c in name)
				ident.Append((c.IsLetterOrDigit || c == '_') ? c : '_');
			String srcDir = scope .();
			Join(projDir, "src", srcDir);
			if (Directory.CreateDirectory(srcDir) case .Err)
			{
				outError.Set(scope $"Could not create {srcDir}");
				return .Err;
			}
			String toml = scope .();
			toml.Append("FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = ");
			TomlText.Quote(name, toml);
			toml.Append('\n');
			if (library)
				toml.Append("TargetType = \"BeefLib\"\n");
			else
				toml.AppendF("TargetType = \"BeefConsoleApplication\"\nStartupObject = \"{}.Program\"\n", ident);
			String code = scope .();
			if (library)
			{
				code.AppendF(
					"""
					using System;

					namespace {0}
					{{
						public static class {0}
						{{
						}}
					}}

					""", ident);
				Join(srcDir, scope $"{ident}.bf", outMainFile);
			}
			else
			{
				code.AppendF(
					"""
					using System;

					namespace {0}
					{{
						class Program
						{{
							public static int Main(String[] args)
							{{
								Console.WriteLine("Hello from {0}");
								return 0;
							}}
						}}
					}}

					""", ident);
				Join(srcDir, "Program.bf", outMainFile);
			}
			String tomlPath = scope .();
			Join(projDir, BeefProjectFile.FileName, tomlPath);
			if ((FileSafety.AtomicWrite(tomlPath, toml, false, outError) case .Err) || (FileSafety.AtomicWrite(outMainFile, code, false, outError) case .Err))
			{
				if (outError.IsEmpty)
					outError.Set(scope $"Could not write the project files in {projDir}");
				return .Err;
			}
			Note(changes, tomlPath, scope $"created ({(library ? "library" : "program")})");
			Note(changes, outMainFile, "created");
			return AddProject(wsFile, name, projDir, changes, outError);
		}

		// ------------------------------------------------------------------ project edits

		static StringView TargetTypeOf(ProjectBuildKind kind)
		{
			switch (kind)
			{
			case .Console: return "BeefConsoleApplication";
			case .Windows: return "BeefGUIApplication";
			case .Library, .DynamicLibrary: return "BeefLib";
			case .Other: return "";
			}
		}

		/// What Project Settings calls a build kind.
		public static StringView KindLabel(ProjectBuildKind kind)
		{
			switch (kind)
			{
			case .Console: return "Console application";
			case .Windows: return "Windows application";
			case .Library: return "Library";
			case .DynamicLibrary: return "Dynamic library";
			case .Other: return "Other";
			}
		}

		/// Sets what the project builds: TargetType, and `BuildKind = "DynamicLib"` in every configuration
		/// (Debug and Release for Win64 at least) for a dynamic library, removed again for the other kinds.
		public static Result<void> SetBuildKind(StringView projDir, ProjectBuildKind kind, List<String> changes, String outError)
		{
			if (kind == .Other)
				return .Ok;
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"Could not read {projDir}/BeefProj.toml");
				return .Err;
			}
			String oldType = scope .();
			pf.Toml.GetString("Project", "TargetType", oldType);
			let newType = TargetTypeOf(kind);
			if (oldType != newType)
			{
				pf.Toml.SetString("Project", "TargetType", newType);
				Note(changes, pf.FilePath, scope $"TargetType = \"{newType}\" (was {(oldType.IsEmpty ? "not set" : oldType)})");
			}
			List<String> sections = scope .();
			defer { ClearAndDeleteItems!(sections); }
			pf.ConfigSections(sections);
			if (kind == .DynamicLibrary)
			{
				for (let def in StringView[?]("Debug.Win64", "Release.Win64"))
				{
					bool has = false;
					for (let s in sections)
						if (s == def)
							has = true;
					if (!has)
						sections.Add(new String(def));
				}
			}
			String bk = scope .();
			for (let s in sections)
			{
				String table = scope $"Configs.{s}";
				bk.Clear();
				pf.Toml.GetString(table, "BuildKind", bk);
				if (kind == .DynamicLibrary && bk != "DynamicLib" && (bk.IsEmpty || bk == "Normal" || bk == "StaticLib"))
				{
					pf.Toml.SetString(table, "BuildKind", "DynamicLib");
					Note(changes, pf.FilePath, scope $"[{table}] BuildKind = \"DynamicLib\"");
				}
				else if (kind != .DynamicLibrary && bk == "DynamicLib")
				{
					pf.Toml.Remove(table, "BuildKind");
					pf.Toml.RemoveTableIfEmpty(table);
					Note(changes, pf.FilePath, scope $"[{table}] BuildKind removed");
				}
			}
			Batch b = scope .();
			b.Put(pf.FilePath, pf.Original, pf.Toml.Text);
			return b.Commit(outError);
		}

		/// Adds or removes the dependency `dep` (`dep = "*"`).
		public static Result<void> SetDependency(StringView projDir, StringView dep, bool on, List<String> changes, String outError)
		{
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"Could not read {projDir}/BeefProj.toml");
				return .Err;
			}
			bool has = pf.DependsOn(dep);
			if (has == on)
				return .Ok;
			if (on)
			{
				pf.Toml.MapSet("Dependencies", dep, "\"*\"");
				Note(changes, pf.FilePath, scope $"dependency {dep} added");
			}
			else
			{
				pf.Toml.MapRemove("Dependencies", dep);
				Note(changes, pf.FilePath, scope $"dependency {dep} removed");
			}
			Batch b = scope .();
			b.Put(pf.FilePath, pf.Original, pf.Toml.Text);
			return b.Commit(outError);
		}

		/// Sets a string value of the project file (`[table] key`); empty removes the key (and an empty
		/// configuration table).
		public static Result<void> SetValue(StringView projDir, StringView table, StringView key, StringView value, List<String> changes, String outError)
		{
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"Could not read {projDir}/BeefProj.toml");
				return .Err;
			}
			String old = scope .();
			bool had = pf.Toml.GetRaw(table, key, let oldRaw);
			if (had)
				old.Set(oldRaw);
			if (value.IsEmpty)
			{
				if (!had)
					return .Ok;
				pf.Toml.Remove(table, key);
				if (table.StartsWith("Configs."))
					pf.Toml.RemoveTableIfEmpty(table);
				Note(changes, pf.FilePath, scope $"[{table}] {key} removed (was {old})");
			}
			else
			{
				String raw = scope .();
				TomlText.Quote(value, raw);
				if (had && raw == old)
					return .Ok;
				pf.Toml.SetRaw(table, key, raw);
				String was = scope .();
				ShowRaw(old, was);
				Note(changes, pf.FilePath, scope $"[{table}] {key} = {raw} (was {was})");
			}
			Batch b = scope .();
			b.Put(pf.FilePath, pf.Original, pf.Toml.Text);
			return b.Commit(outError);
		}

		/// Sets a list value (`PreBuildCmds = ["...", "..."]`); an empty list removes the key.
		public static Result<void> SetList(StringView projDir, StringView table, StringView key, List<String> items, List<String> changes, String outError)
		{
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"Could not read {projDir}/BeefProj.toml");
				return .Err;
			}
			List<String> old = scope .();
			defer { ClearAndDeleteItems!(old); }
			bool had = pf.Toml.GetStringArray(table, key, old);
			bool same = had && old.Count == items.Count;
			if (same)
				for (int i < items.Count)
					if (old[i] != items[i])
						same = false;
			if (same || (!had && items.IsEmpty))
				return .Ok;
			if (items.IsEmpty)
			{
				pf.Toml.Remove(table, key);
				if (table.StartsWith("Configs."))
					pf.Toml.RemoveTableIfEmpty(table);
				Note(changes, pf.FilePath, scope $"[{table}] {key} removed");
			}
			else
			{
				pf.Toml.SetStringArray(table, key, items);
				String raw = scope .();
				TomlText.FormatStringArray(items, raw);
				Note(changes, pf.FilePath, scope $"[{table}] {key} = {raw}");
			}
			Batch b = scope .();
			b.Put(pf.FilePath, pf.Original, pf.Toml.Text);
			return b.Commit(outError);
		}

		// ------------------------------------------------------------------ folder moves

		/// Replaces the JSON string `old` by `now` in a `.vbproject` text (main, libraries).
		static bool ReplaceJsonString(String text, StringView old, StringView now)
		{
			String a = scope .();
			String b = scope .();
			UpdateJson.WriteString(old, a);
			UpdateJson.WriteString(now, b);
			if (!text.Contains(a))
				return false;
			text.Replace(a, b);
			return true;
		}

		/// Points `.vbproject` (in `root`) at the moved folder: `main` and relative `libraries` under `oldDir`.
		static void MoveManifestPaths(StringView root, StringView oldDir, StringView newDir, Batch batch, List<String> changes)
		{
			if (root.IsEmpty)
				return;
			String path = scope .();
			Join(root, ProjectManifest.FileName, path);
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return;
			ProjectManifest m = scope .();
			if (!m.Parse(text, scope String()))
				return;
			String before = scope .(text);
			String oldRel = scope .();
			String newRel = scope .();
			RelativePath(root, oldDir, oldRel);
			RelativePath(root, newDir, newRel);
			if (oldRel.StartsWith("..") || oldRel == ".")
				return;
			void Move(StringView value, StringView what)
			{
				String v = scope .(value);
				v.Replace('\\', '/');
				if (v.StartsWith(oldRel) && (v.Length == oldRel.Length || v[oldRel.Length] == '/'))
				{
					String moved = scope .(newRel);
					moved.Append(StringView(v, oldRel.Length));
					if (ReplaceJsonString(text, value, moved))
						Note(changes, path, scope $"{what} = \"{moved}\" (was \"{value}\")");
				}
			}
			if (!m.Main.IsEmpty)
				Move(m.Main, "main");
			for (let l in m.Libraries)
				Move(l, "library");
			batch.Put(path, before, text);
		}

		/// The name `oldName` of a project becomes `newName` in the workspace text `t` (read as `ws`): the key of its
		/// `Projects` entry, `StartupProject`, the `Locked` / `Unlocked` lists, and the `Dependencies` entry of every
		/// other project (their files go into `batch`; a project whose folder moved from `oldDir` to `newDir` is
		/// read from its new place). Every change is noted.
		static void RenameInSpace(StringView wsFile, TomlText t, BeefWorkspace ws, StringView oldName, StringView newName, StringView oldDir, StringView newDir, Batch batch, List<String> changes)
		{
			t.MapRenameKey("Projects", oldName, newName);
			Note(changes, wsFile, scope $"project {oldName} renamed to {newName}");
			if (ws.Startup == oldName)
			{
				t.SetString("Workspace", "StartupProject", newName);
				Note(changes, wsFile, scope $"StartupProject = \"{newName}\"");
			}
			for (let listKey in StringView[?]("Locked", "Unlocked"))
			{
				List<String> items = scope .();
				defer { ClearAndDeleteItems!(items); }
				if (!t.GetStringArray("", listKey, items))
					continue;
				bool hit = false;
				for (let it in items)
					if (it == oldName)
					{
						it.Set(newName);
						hit = true;
					}
				if (hit)
				{
					t.SetStringArray("", listKey, items);
					Note(changes, wsFile, scope $"{listKey}: {oldName} -> {newName}");
				}
			}
			// The other projects that depend on it.
			for (let q in ws.Projects)
			{
				if (!q.HasPath || q.Name == oldName)
					continue;
				String qDir = scope .(q.Dir);
				if (!oldDir.IsEmpty && (ProjectIndex.SamePath(qDir, oldDir) || IsUnder(qDir, oldDir)))
				{
					qDir.Set(newDir);
					qDir.Append(StringView(q.Dir, oldDir.Length));
				}
				BeefProjectFile qf = scope .();
				if (!qf.Load(qDir))
					continue;
				if (qf.Toml.MapRenameKey("Dependencies", oldName, newName))
				{
					Note(changes, qf.FilePath, scope $"dependency {oldName} -> {newName}");
					batch.Put(qf.FilePath, qf.Original, qf.Toml.Text);
				}
			}
		}

		/// Renames the project `oldName` (the folder `projDir`) to `newName`: `[Project] Name` in its BeefProj.toml
		/// and, when the workspace `wsFile` lists it, everything RenameInSpace changes. The folder is not touched.
		/// All files are written or none (a `.bak` is kept of each).
		public static Result<void> RenameProject(StringView wsFile, StringView projDir, StringView oldName, StringView newName, List<String> changes, String outError)
		{
			if (!ValidProjectName(newName, outError))
				return .Err;
			if (newName == oldName)
				return .Ok;
			BeefProjectFile pf = scope .();
			if (!pf.Load(projDir))
			{
				outError.Set(scope $"{projDir} has no BeefProj.toml.");
				return .Err;
			}
			Batch batch = scope .();
			if (!wsFile.IsEmpty && File.Exists(wsFile))
			{
				TomlText t = scope .();
				String before = scope .();
				if (!LoadToml(wsFile, t, before, outError))
					return .Err;
				BeefWorkspace ws = scope .();
				ParentDir(wsFile, ws.Dir);
				ws.Read(t);
				if (ws.Find(newName) != null)
				{
					outError.Set(scope $"The workspace already has a project named '{newName}'.");
					return .Err;
				}
				if (ws.Find(oldName) != null)
				{
					RenameInSpace(wsFile, t, ws, oldName, newName, default, default, batch, changes);
					batch.Put(wsFile, before, t.Text);
				}
			}
			pf.Toml.SetString("Project", "Name", newName);
			Note(changes, pf.FilePath, scope $"Name = \"{newName}\" (was \"{oldName}\")");
			batch.Put(pf.FilePath, pf.Original, pf.Toml.Text);
			return batch.Commit(outError);
		}

		/// After the folder `oldDir` was moved or renamed to `newDir`: the workspace paths of the projects in it
		/// follow, and a renamed project folder renames its project when the project was named like its folder
		/// (Name in BeefProj.toml, the workspace entry and startup project, the other projects' dependencies),
		/// and `.vbproject` main / libraries in `manifestRoot` follow. Call it after the move; on an error the
		/// caller moves the folder back (the files are then untouched).
		public static Result<void> FolderMoved(StringView wsFile, StringView oldDir, StringView newDir, StringView manifestRoot, List<String> changes, String outError)
		{
			Batch batch = scope .();
			if (!wsFile.IsEmpty && File.Exists(wsFile))
			{
				TomlText t = scope .();
				String before = scope .();
				if (!LoadToml(wsFile, t, before, outError))
					return .Err;
				BeefWorkspace ws = scope .();
				ParentDir(wsFile, ws.Dir);
				ws.Read(t);
				String oldName = scope .();
				String newName = scope .();
				for (let p in ws.Projects)
				{
					if (!p.HasPath || p.RelPath == ".")
						continue;
					bool self = ProjectIndex.SamePath(p.Dir, oldDir);
					if (!self && !IsUnder(p.Dir, oldDir))
						continue;
					String movedDir = scope .(newDir);
					movedDir.Append(StringView(p.Dir, oldDir.Length));
					String rel = scope .();
					RelativePath(ws.Dir, movedDir, rel);
					String raw = scope .();
					t.MapGet("Projects", p.Name, raw);
					String q = scope .();
					TomlText.Quote(rel, q);
					TomlText.InlineSet(raw, "Path", q);
					t.MapSet("Projects", p.Name, raw);
					Note(changes, wsFile, scope $"{p.Name} Path = \"{rel}\" (was \"{p.RelPath}\")");
					if (!self)
						continue;
					// The project folder itself: its name follows when it was named like the folder.
					String oldFolder = scope .();
					String newFolder = scope .();
					Path.GetFileName(oldDir, oldFolder);
					Path.GetFileName(newDir, newFolder);
					BeefProjectFile pf = scope:: .();
					if (!pf.Load(movedDir))
						continue;
					String projName = scope .();
					pf.GetName(projName);
					if (projName != p.Name || StringView.Compare(projName, oldFolder, true) != 0 || newFolder == projName)
						continue;
					if (!ValidProjectName(newFolder, null))
					{
						Note(changes, wsFile, scope $"the project keeps the name {projName} ('{newFolder}' is not a project name)");
						continue;
					}
					let clash = ws.Find(newFolder);
					if (clash != null && clash != p)
					{
						Note(changes, wsFile, scope $"the project keeps the name {projName} (the workspace already has a project {newFolder})");
						continue;
					}
					oldName.Set(projName);
					newName.Set(newFolder);
					if (pf.Toml.GetRaw("Project", "Name", ?))
						pf.Toml.SetString("Project", "Name", newName);
					Note(changes, pf.FilePath, scope $"Name = \"{newName}\" (was \"{oldName}\")");
					batch.Put(pf.FilePath, pf.Original, pf.Toml.Text);
				}
				if (!newName.IsEmpty)
					RenameInSpace(wsFile, t, ws, oldName, newName, oldDir, newDir, batch, changes);
				batch.Put(wsFile, before, t.Text);
				String wsDir = scope .();
				ParentDir(wsFile, wsDir);
				MoveManifestPaths(wsDir, oldDir, newDir, batch, changes);
				if (!manifestRoot.IsEmpty && !ProjectIndex.SamePath(manifestRoot, wsDir))
					MoveManifestPaths(manifestRoot, oldDir, newDir, batch, changes);
			}
			else
				MoveManifestPaths(manifestRoot, oldDir, newDir, batch, changes);
			return batch.Commit(outError);
		}

		/// After the folder `dir` was deleted: the projects in it leave the workspace, the other projects'
		/// dependencies on them go, and a startup project that went is replaced by the first one left.
		public static Result<void> FolderRemoved(StringView wsFile, StringView dir, List<String> changes, String outError)
		{
			return RemoveProjects(wsFile, dir, default, changes, outError);
		}

		/// Removes the project `name` from the workspace (its files stay), with the other projects'
		/// dependencies on it; a startup project that went is replaced by the first one left.
		public static Result<void> RemoveProject(StringView wsFile, StringView name, List<String> changes, String outError)
		{
			return RemoveProjects(wsFile, default, name, changes, outError);
		}

		static Result<void> RemoveProjects(StringView wsFile, StringView dir, StringView name, List<String> changes, String outError)
		{
			if (wsFile.IsEmpty || !File.Exists(wsFile))
				return .Ok;
			TomlText t = scope .();
			String before = scope .();
			if (!LoadToml(wsFile, t, before, outError))
				return .Err;
			BeefWorkspace ws = scope .();
			ParentDir(wsFile, ws.Dir);
			ws.Read(t);
			List<String> gone = scope .();
			defer { ClearAndDeleteItems!(gone); }
			for (let p in ws.Projects)
			{
				bool hit = name.IsEmpty ? (p.HasPath && p.RelPath != "." && (ProjectIndex.SamePath(p.Dir, dir) || IsUnder(p.Dir, dir))) : p.Name == name;
				if (hit)
				{
					t.MapRemove("Projects", p.Name);
					gone.Add(new String(p.Name));
					Note(changes, wsFile, name.IsEmpty ? scope $"project {p.Name} removed (its folder was deleted)" : scope $"project {p.Name} removed from the workspace (its files are kept)");
				}
			}
			if (gone.IsEmpty)
				return .Ok;
			Batch batch = scope .();
			bool startupGone = false;
			for (let g in gone)
				if (g == ws.Startup)
					startupGone = true;
			for (let q in ws.Projects)
			{
				if (!q.HasPath || gone.Contains(q.Name))
					continue;
				if (startupGone)
				{
					t.SetString("Workspace", "StartupProject", q.Name);
					Note(changes, wsFile, scope $"StartupProject = \"{q.Name}\"");
					startupGone = false;
				}
				BeefProjectFile qf = scope:: .();
				if (!qf.Load(q.Dir))
					continue;
				bool hit = false;
				for (let g in gone)
					if (qf.Toml.MapRemove("Dependencies", g))
					{
						hit = true;
						Note(changes, qf.FilePath, scope $"dependency {g} removed");
					}
				if (hit)
					batch.Put(qf.FilePath, qf.Original, qf.Toml.Text);
			}
			if (startupGone)
			{
				t.Remove("Workspace", "StartupProject");
				Note(changes, wsFile, "StartupProject removed (no project left)");
			}
			batch.Put(wsFile, before, t.Text);
			return batch.Commit(outError);
		}
	}
}
