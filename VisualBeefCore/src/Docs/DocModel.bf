using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Docs
{
	/// A run of text inside a block, with one style and perhaps a link target.
	class DocSpan
	{
		public const uint8 cBold = 1;
		public const uint8 cItalic = 2;
		public const uint8 cCode = 4;

		public String Text = new .() ~ delete _;
		public uint8 Style;
		/// The link target as written ("Getting-Started.md#install", "https://...", "#slug"); "" = not a link.
		public String Link = new .() ~ delete _;
	}

	class DocCell
	{
		public List<DocSpan> Spans = new .() ~ DeleteContainerAndItems!(_);
	}

	class DocRow
	{
		public List<DocCell> Cells = new .() ~ DeleteContainerAndItems!(_);
	}

	enum DocBlockKind
	{
		Heading,
		Paragraph,
		/// A list entry; `Level` is its nesting (0 = top), `Number` its number in an ordered list (0 = bullet).
		ListItem,
		Quote,
		/// A fenced code block; `Text` is the code.
		Code,
		Rule,
		/// `Rows[0]` is the header row.
		Table,
		/// `Target` is the image path as written, `Text` its description.
		Image
	}

	class DocBlock
	{
		public DocBlockKind Kind;
		/// Heading level (1-6) or list nesting (0-based).
		public int Level;
		public int Number;
		public List<DocSpan> Spans = new .() ~ DeleteContainerAndItems!(_);
		public String Text = new .() ~ delete _;
		public String Target = new .() ~ delete _;
		/// A heading's anchor ("override-a-parent-function"), unique within its page.
		public String Slug = new .() ~ delete _;
		public List<DocRow> Rows = new .() ~ DeleteContainerAndItems!(_);

		/// The text of the spans without styling.
		public void PlainText(String outText)
		{
			for (let s in Spans)
				outText.Append(s.Text);
		}
	}

	/// One documentation page: its front matter (audience, title, summary, order) and the blocks of its body.
	class DocPage
	{
		public String Path = new .() ~ delete _;
		/// The file name ("Getting-Started.md"): what links between pages use.
		public String FileName = new .() ~ delete _;
		public String Title = new .() ~ delete _;
		public String Summary = new .() ~ delete _;
		public String Audience = new .() ~ delete _;
		public int32 Order = 1000;
		public List<DocBlock> Blocks = new .() ~ DeleteContainerAndItems!(_);

		public bool IsUser => Audience == "user";

		/// Splits `---` front matter (key: value lines) from the text. Returns false when there is none.
		public static bool SplitFrontMatter(StringView text, Dictionary<String, String> outKeys, String outBody)
		{
			var rest = text;
			if (rest.StartsWith("\xEF\xBB\xBF"))
				rest.RemoveFromStart(3);
			int first = rest.IndexOf('\n');
			if (first < 0)
				return false;
			var firstLine = rest.Substring(0, first);
			firstLine.Trim();
			if (firstLine != "---")
				return false;
			int pos = first + 1;
			while (pos < rest.Length)
			{
				int eol = rest.IndexOf('\n', pos);
				var line = (eol < 0) ? rest.Substring(pos) : rest.Substring(pos, eol - pos);
				int next = (eol < 0) ? rest.Length : eol + 1;
				var t = line;
				t.Trim();
				if (t == "---")
				{
					outBody.Append(rest.Substring(next));
					return true;
				}
				int colon = t.IndexOf(':');
				if (colon > 0)
				{
					var key = t.Substring(0, colon);
					var value = t.Substring(colon + 1);
					key.Trim();
					value.Trim();
					String k = new String(key);
					String v = new String(value);
					if (outKeys.ContainsKey(k))
					{
						// the first one wins
						delete k;
						delete v;
					}
					else
						outKeys[k] = v;
				}
				pos = next;
			}
			return false;
		}

		/// Reads the page at `path`. False when the file is missing or has no front matter.
		public bool Load(StringView path)
		{
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
				return false;
			Path.Set(path);
			int cut = Math.Max(path.LastIndexOf('/'), path.LastIndexOf('\\'));
			FileName.Set(cut >= 0 ? path.Substring(cut + 1) : path);
			return Parse(text);
		}

		/// Parses page text (front matter, then the body).
		public bool Parse(StringView text)
		{
			Dictionary<String, String> keys = scope .();
			defer { for (let kv in keys) { delete kv.key; delete kv.value; } }
			String body = scope .();
			if (!SplitFrontMatter(text, keys, body))
				return false;
			if (keys.TryGetValue("audience", let a))
				Audience.Set(a);
			if (keys.TryGetValue("title", let t))
				Title.Set(t);
			if (keys.TryGetValue("summary", let s))
				Summary.Set(s);
			if (keys.TryGetValue("order", let o) && int32.Parse(o) case .Ok(let n))
				Order = n;
			if (Title.IsEmpty)
				Title.Set(FileName.EndsWith(".md") ? StringView(FileName, 0, FileName.Length - 3) : (StringView)FileName);
			Markdown.Parse(body, Blocks);
			return true;
		}

		public DocBlock FindHeading(StringView slug)
		{
			for (let b in Blocks)
				if (b.Kind == .Heading && b.Slug == slug)
					return b;
			return null;
		}
	}

	/// The Markdown the shipped pages use: headings, paragraphs, bullet and numbered lists (nested by indent), block
	/// quotes, fenced code, tables, rules, images on a line of their own, and the inline `code`, **bold**, *italic*,
	/// [links](target), <autolinks> and the entities &lt; &gt; &amp; &quot;.
	static class Markdown
	{
		/// The anchor of a heading: lower case, letters and digits kept, spaces and hyphens become `-`, the rest dropped.
		public static void Slug(StringView text, String outSlug)
		{
			for (let c in text.DecodedChars)
			{
				if (c == ' ' || c == '-')
					outSlug.Append('-');
				else if (c == '_' || c.IsLetterOrDigit)
					outSlug.Append(c.ToLower);
			}
		}

		static bool IsRuleLine(StringView line)
		{
			var t = line;
			t.Trim();
			if (t.Length < 3)
				return false;
			char8 c = t[0];
			if (c != '-' && c != '*' && c != '_')
				return false;
			for (let ch in t.RawChars)
				if (ch != c && ch != ' ')
					return false;
			return true;
		}

		static bool IsFence(StringView line)
		{
			var t = line;
			t.Trim();
			return t.StartsWith("```");
		}

		static bool IsTableSeparator(StringView line)
		{
			var t = line;
			t.Trim();
			if (!t.Contains('-') || !t.Contains('|'))
				return false;
			for (let c in t.RawChars)
				if (c != '|' && c != '-' && c != ':' && c != ' ')
					return false;
			return true;
		}

		/// A list line: its nesting, the number (0 for a bullet) and where the text starts. False for other lines.
		static bool ListMarker(StringView line, out int level, out int number, out int textAt)
		{
			level = 0;
			number = 0;
			textAt = 0;
			int i = 0;
			int indent = 0;
			while (i < line.Length && (line[i] == ' ' || line[i] == '\t'))
			{
				indent += (line[i] == '\t') ? 4 : 1;
				i++;
			}
			if (i >= line.Length)
				return false;
			char8 c = line[i];
			if ((c == '*' || c == '-' || c == '+') && i + 1 < line.Length && line[i + 1] == ' ')
			{
				if (IsRuleLine(line))
					return false;
				level = indent / 2;
				textAt = i + 2;
				return true;
			}
			if (c.IsDigit)
			{
				int j = i;
				int n = 0;
				while (j < line.Length && line[j].IsDigit && j - i < 6)
				{
					n = n * 10 + (int)(line[j] - '0');
					j++;
				}
				if (j + 1 < line.Length && (line[j] == '.' || line[j] == ')') && line[j + 1] == ' ')
				{
					level = indent / 2;
					number = Math.Max(n, 1);
					textAt = j + 2;
					return true;
				}
			}
			return false;
		}

		static bool IsImageLine(StringView line, String outAlt, String outTarget)
		{
			var t = line;
			t.Trim();
			if (!t.StartsWith("![") || !t.EndsWith(')'))
				return false;
			int close = t.IndexOf("](");
			if (close < 0)
				return false;
			// exactly one image: no further "![" after the first
			if (t.IndexOf("![", 2) >= 0)
				return false;
			outAlt.Append(t.Substring(2, close - 2));
			outTarget.Append(t.Substring(close + 2, t.Length - close - 3));
			return true;
		}

		static bool StartsBlock(StringView line)
		{
			var t = line;
			t.Trim();
			if (t.IsEmpty)
				return true;
			if (t.StartsWith('#') || t.StartsWith('>') || t.StartsWith('|') || IsFence(line) || IsRuleLine(line))
				return true;
			if (t.StartsWith("!["))
			{
				String a = scope .();
				String b = scope .();
				if (IsImageLine(line, a, b))
					return true;
			}
			ListMarker(line, let l, let n, let at);
			return at > 0;
		}

		public static void Parse(StringView body, List<DocBlock> outBlocks)
		{
			List<StringView> lines = scope .();
			for (var line in body.Split('\n'))
			{
				if (line.EndsWith('\r'))
					line.RemoveFromEnd(1);
				lines.Add(line);
			}
			HashSet<String> slugs = scope .();
			defer { for (let s in slugs) delete s; }
			int i = 0;
			while (i < lines.Count)
			{
				let line = lines[i];
				var t = line;
				t.Trim();
				if (t.IsEmpty)
				{
					i++;
					continue;
				}
				if (IsFence(line))
				{
					let b = new DocBlock();
					b.Kind = .Code;
					i++;
					bool firstLine = true;
					while (i < lines.Count && !IsFence(lines[i]))
					{
						if (!firstLine)
							b.Text.Append('\n');
						b.Text.Append(lines[i]);
						firstLine = false;
						i++;
					}
					i++; // the closing fence
					outBlocks.Add(b);
					continue;
				}
				if (t.StartsWith('#'))
				{
					int level = 0;
					while (level < t.Length && t[level] == '#')
						level++;
					if (level <= 6 && level < t.Length && t[level] == ' ')
					{
						let b = new DocBlock();
						b.Kind = .Heading;
						b.Level = level;
						var title = t.Substring(level + 1);
						title.Trim();
						while (title.EndsWith('#'))
							title.RemoveFromEnd(1);
						title.Trim();
						ParseInline(title, b.Spans, 0, "");
						String plain = scope .();
						b.PlainText(plain);
						Slug(plain, b.Slug);
						if (slugs.Contains(b.Slug))
						{
							int n = 1;
							String candidate = scope .();
							repeat
							{
								candidate.Clear();
								candidate.AppendF("{}-{}", b.Slug, n++);
							}
							while (slugs.Contains(candidate));
							b.Slug.Set(candidate);
						}
						slugs.Add(new String(b.Slug));
						outBlocks.Add(b);
						i++;
						continue;
					}
				}
				if (IsRuleLine(line))
				{
					let b = new DocBlock();
					b.Kind = .Rule;
					outBlocks.Add(b);
					i++;
					continue;
				}
				{
					String alt = scope .();
					String target = scope .();
					if (IsImageLine(line, alt, target))
					{
						let b = new DocBlock();
						b.Kind = .Image;
						b.Text.Set(alt);
						b.Target.Set(target);
						outBlocks.Add(b);
						i++;
						continue;
					}
				}
				if (t.StartsWith('|') && i + 1 < lines.Count && IsTableSeparator(lines[i + 1]))
				{
					let b = new DocBlock();
					b.Kind = .Table;
					b.Rows.Add(ParseRow(t));
					i += 2;
					while (i < lines.Count)
					{
						var r = lines[i];
						r.Trim();
						if (!r.StartsWith('|'))
							break;
						b.Rows.Add(ParseRow(r));
						i++;
					}
					outBlocks.Add(b);
					continue;
				}
				if (t.StartsWith('>'))
				{
					String para = scope .();
					while (i < lines.Count)
					{
						var q = lines[i];
						q.Trim();
						if (!q.StartsWith('>'))
							break;
						q.RemoveFromStart(1);
						q.Trim();
						if (q.IsEmpty)
						{
							if (!para.IsEmpty)
							{
								AddQuote(para, outBlocks);
								para.Clear();
							}
						}
						else
						{
							if (!para.IsEmpty)
								para.Append(' ');
							para.Append(q);
						}
						i++;
					}
					if (!para.IsEmpty)
						AddQuote(para, outBlocks);
					continue;
				}
				if (ListMarker(line, let level, let number, let textAt) && textAt > 0)
				{
					String item = scope .(line.Substring(textAt));
					item.Trim();
					i++;
					// Continuation lines: indented text, or text right under the item.
					while (i < lines.Count)
					{
						let next = lines[i];
						var nt = next;
						nt.Trim();
						if (nt.IsEmpty || StartsBlock(next))
							break;
						item.Append(' ');
						item.Append(nt);
						i++;
					}
					let b = new DocBlock();
					b.Kind = .ListItem;
					b.Level = level;
					b.Number = number;
					ParseInline(item, b.Spans, 0, "");
					outBlocks.Add(b);
					continue;
				}
				{
					String para = scope .(t);
					i++;
					while (i < lines.Count)
					{
						var nt = lines[i];
						nt.Trim();
						if (nt.IsEmpty || StartsBlock(lines[i]))
							break;
						para.Append(' ');
						para.Append(nt);
						i++;
					}
					let b = new DocBlock();
					b.Kind = .Paragraph;
					ParseInline(para, b.Spans, 0, "");
					outBlocks.Add(b);
				}
			}
		}

		static void AddQuote(StringView text, List<DocBlock> outBlocks)
		{
			let b = new DocBlock();
			b.Kind = .Quote;
			ParseInline(text, b.Spans, 0, "");
			outBlocks.Add(b);
		}

		static DocRow ParseRow(StringView line)
		{
			let row = new DocRow();
			var t = line;
			t.Trim();
			if (t.StartsWith('|'))
				t.RemoveFromStart(1);
			if (t.EndsWith('|') && !t.EndsWith("\\|"))
				t.RemoveFromEnd(1);
			// Split on '|' outside backticks; `\|` is a literal bar.
			String cell = scope .();
			bool inCode = false;
			for (int i = 0; i < t.Length; i++)
			{
				char8 ch = t[i];
				if (ch == '\\' && i + 1 < t.Length && t[i + 1] == '|')
				{
					cell.Append('|');
					i++;
				}
				else if (ch == '`')
				{
					inCode = !inCode;
					cell.Append(ch);
				}
				else if (ch == '|' && !inCode)
				{
					AddCell(row, cell);
					cell.Clear();
				}
				else
					cell.Append(ch);
			}
			AddCell(row, cell);
			return row;
		}

		static void AddCell(DocRow row, StringView text)
		{
			let c = new DocCell();
			var ct = text;
			ct.Trim();
			ParseInline(ct, c.Spans, 0, "");
			row.Cells.Add(c);
		}

		static void AddRun(List<DocSpan> spans, String run, uint8 style, StringView link)
		{
			if (run.IsEmpty)
				return;
			if (spans.Count > 0)
			{
				let last = spans.Back;
				if (last.Style == style && last.Link == link)
				{
					last.Text.Append(run);
					run.Clear();
					return;
				}
			}
			let s = new DocSpan();
			s.Text.Set(run);
			s.Style = style;
			s.Link.Set(link);
			spans.Add(s);
			run.Clear();
		}

		static bool Entity(StringView text, int at, String outRun, out int length)
		{
			length = 0;
			if (text[at] != '&')
				return false;
			StringView[4] names = .("&lt;", "&gt;", "&amp;", "&quot;");
			StringView[4] chars = .("<", ">", "&", "\"");
			for (int k < 4)
			{
				if (text.Length - at >= names[k].Length && text.Substring(at, names[k].Length) == names[k])
				{
					outRun.Append(chars[k]);
					length = names[k].Length;
					return true;
				}
			}
			return false;
		}

		/// Inline styling of `text` into `outSpans`.
		public static void ParseInline(StringView text, List<DocSpan> outSpans, uint8 style, StringView link)
		{
			String run = scope .();
			int i = 0;
			while (i < text.Length)
			{
				char8 c = text[i];
				if (c == '\\' && i + 1 < text.Length && "\\`*_{}[]()#+-.!|<>".Contains(text[i + 1]))
				{
					run.Append(text[i + 1]);
					i += 2;
					continue;
				}
				if (c == '`')
				{
					int ticks = 1;
					while (i + ticks < text.Length && text[i + ticks] == '`')
						ticks++;
					String fence = scope .();
					fence.Append('`', ticks);
					int close = text.IndexOf(fence, i + ticks);
					if (close > 0)
					{
						AddRun(outSpans, run, style, link);
						var code = text.Substring(i + ticks, close - i - ticks);
						if (code.StartsWith(' ') && code.EndsWith(' ') && code.Length > 2)
							code = code.Substring(1, code.Length - 2);
						String codeText = scope .(code);
						AddRun(outSpans, codeText, style | DocSpan.cCode, link);
						i = close + ticks;
						continue;
					}
				}
				if (c == '*' && i + 1 < text.Length && text[i + 1] == '*')
				{
					int close = text.IndexOf("**", i + 2);
					if (close > i + 2)
					{
						AddRun(outSpans, run, style, link);
						ParseInline(text.Substring(i + 2, close - i - 2), outSpans, style | DocSpan.cBold, link);
						i = close + 2;
						continue;
					}
				}
				if (c == '*' && i + 1 < text.Length && text[i + 1] != ' ' && text[i + 1] != '*')
				{
					int close = i + 1;
					while (close < text.Length && !(text[close] == '*' && text[close - 1] != ' ' && (close + 1 >= text.Length || text[close + 1] != '*')))
						close++;
					if (close < text.Length)
					{
						AddRun(outSpans, run, style, link);
						ParseInline(text.Substring(i + 1, close - i - 1), outSpans, style | DocSpan.cItalic, link);
						i = close + 1;
						continue;
					}
				}
				if (c == '[')
				{
					int close = FindClosingBracket(text, i);
					if (close > 0 && close + 1 < text.Length && text[close + 1] == '(')
					{
						int end = text.IndexOf(')', close + 2);
						if (end > 0)
						{
							var target = text.Substring(close + 2, end - close - 2);
							target.Trim();
							AddRun(outSpans, run, style, link);
							ParseInline(text.Substring(i + 1, close - i - 1), outSpans, style, target);
							i = end + 1;
							continue;
						}
					}
				}
				if (c == '<' && (text.Substring(i).StartsWith("<https://") || text.Substring(i).StartsWith("<http://")))
				{
					int end = text.IndexOf('>', i);
					if (end > 0)
					{
						AddRun(outSpans, run, style, link);
						var url = text.Substring(i + 1, end - i - 1);
						String urlText = scope .(url);
						AddRun(outSpans, urlText, style, url);
						i = end + 1;
						continue;
					}
				}
				if (c == '&' && Entity(text, i, run, let len))
				{
					i += len;
					continue;
				}
				run.Append(c);
				i++;
			}
			AddRun(outSpans, run, style, link);
		}

		static int FindClosingBracket(StringView text, int open)
		{
			int depth = 0;
			bool inCode = false;
			for (int i = open; i < text.Length; i++)
			{
				char8 c = text[i];
				if (c == '`')
					inCode = !inCode;
				if (inCode)
					continue;
				if (c == '[')
					depth++;
				else if (c == ']')
				{
					depth--;
					if (depth == 0)
						return i;
				}
			}
			return -1;
		}
	}
}
