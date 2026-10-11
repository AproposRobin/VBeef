using System;
using System.Collections;
using VisualBeef.Syntax;

namespace VisualBeef.Document
{
	/// One case of a simple enum, as shown by the Enum editor.
	class EnumCase
	{
		public String Name = new .() ~ delete _;
		/// Explicit value text ("4", "1 << 2"); empty when the case has none.
		public String Value = new .() ~ delete _;
		/// Comment text without the comment markers; empty when there is none.
		public String Comment = new .() ~ delete _;

		public this() { }

		public this(StringView name, StringView value = "", StringView comment = "")
		{
			Name.Set(name);
			Value.Set(value);
			Comment.Set(comment);
		}
	}

	/// Reads and writes the case list of an enum declaration. Only "simple" enums are handled:
	/// `Name`, `Name = value` and comments. Payload cases (`case A(int x)`), attributes on cases
	/// and similar are reported as not editable so the text is never damaged.
	static class EnumCases
	{
		/// The character range holding the case list (between `{` and the `;` or `}` that ends
		/// it) and whether the list ends with a `;` (methods follow).
		public struct Region
		{
			public int Start;        // just after '{'
			public int End;          // start of ';' or '}'
			public int SemiTok;      // token index of ';', or -1
			public bool Valid;
		}

		public static Region GetRegion(CompilationUnit unit, Member type)
		{
			Region r = default;
			r.SemiTok = -1;
			if (type == null || type.Kind != .Type || type.TypeKind != "enum" || type.OpenBrace < 0 || type.CloseBrace < 0)
				return r;
			r.Start = unit.Tokens[type.OpenBrace].End;
			if (type.Members != null && !type.Members.IsEmpty)
			{
				let first = type.Members[0];
				if (first.Kind != .Raw || first.FirstTok != type.OpenBrace + 1)
					return r; // members without a case list: not something the editor writes
				if (unit.TokenText(first.LastTok) == ";")
				{
					r.SemiTok = first.LastTok;
					r.End = unit.Tokens[first.LastTok].Start;
				}
				else
					r.End = unit.Tokens[type.CloseBrace].Start;
			}
			else
				r.End = unit.Tokens[type.CloseBrace].Start;
			r.Valid = r.End >= r.Start;
			return r;
		}

		static bool IsIdentStart(char8 c) => c.IsLetter || c == '_' || (uint8)c >= 0x80;
		static bool IsIdentChar(char8 c) => c.IsLetterOrDigit || c == '_' || (uint8)c >= 0x80;

		public static bool IsIdentifier(StringView s)
		{
			if (s.IsEmpty || !IsIdentStart(s[0]))
				return false;
			for (let c in s)
				if (!IsIdentChar(c))
					return false;
			return true;
		}

		static void AppendComment(String to, StringView text)
		{
			var t = text;
			t.Trim();
			if (t.IsEmpty)
				return;
			if (!to.IsEmpty)
				to.Append(' ');
			to.Append(t);
		}

		/// Parses the enum's cases. Returns false (and leaves outCases partially filled) when the
		/// enum uses syntax the editor can't rewrite safely.
		public static bool Parse(CompilationUnit unit, Member type, List<EnumCase> outCases)
		{
			let region = GetRegion(unit, type);
			if (!region.Valid)
				return false;
			StringView text = StringView(unit.Text, region.Start, region.End - region.Start);

			// Split on top-level commas, separating code from comments.
			// Each segment: code text, comments before its code (split into "same line as the
			// previous comma" and "own lines") and comments after its code.
			List<String> codes = scope .();
			List<String> sameLineAsPrev = scope .();
			List<String> ownComments = scope .();
			defer { ClearAndDeleteItems!(codes); ClearAndDeleteItems!(sameLineAsPrev); ClearAndDeleteItems!(ownComments); }

			String code = new .();
			String prevLine = new .();
			String own = new .();
			bool sawNewline = false;
			int depth = 0;
			int i = 0;
			bool ok = true;
			while (i <= text.Length)
			{
				bool atEnd = i == text.Length;
				char8 c = atEnd ? '\0' : text[i];
				if (atEnd || (c == ',' && depth == 0))
				{
					codes.Add(code);
					sameLineAsPrev.Add(prevLine);
					ownComments.Add(own);
					code = new .();
					prevLine = new .();
					own = new .();
					sawNewline = false;
					i++;
					continue;
				}
				if (c == '/' && i + 1 < text.Length && (text[i + 1] == '/' || text[i + 1] == '*'))
				{
					int s = i;
					if (text[i + 1] == '/')
					{
						while (i < text.Length && text[i] != '\n')
							i++;
					}
					else
					{
						i += 2;
						while (i + 1 < text.Length && !(text[i] == '*' && text[i + 1] == '/'))
							i++;
						i = Math.Min(i + 2, text.Length);
					}
					var body = StringView(text, s, i - s);
					while (body.StartsWith('/'))
						body.RemoveFromStart(1);
					if (body.StartsWith('*'))
						body.RemoveFromStart(1);
					if (body.EndsWith("*/"))
						body.RemoveFromEnd(2);
					// Before any code on the first line: it trails the previous case.
					String target = (code.IsEmpty && !sawNewline) ? prevLine : own;
					AppendComment(target, body);
					continue;
				}
				if (c == '\n')
					sawNewline = true;
				if (c == '"' || c == '\'')
				{
					ok = false; // strings/chars in enum values are not expected
					break;
				}
				if (c == '(' || c == '[' || c == '{')
					depth++;
				else if (c == ')' || c == ']' || c == '}')
					depth--;
				if (!c.IsWhiteSpace || !code.IsEmpty)
					code.Append(c);
				i++;
			}
			delete code;
			delete prevLine;
			delete own;
			if (!ok)
				return false;

			// The `;` that ends the case list may carry a trailing comment.
			String semiComment = scope .();
			if (region.SemiTok >= 0)
			{
				var trail = unit.TrailingTrivia(region.SemiTok);
				trail.Trim();
				if (trail.StartsWith("//"))
				{
					while (trail.StartsWith('/'))
						trail.RemoveFromStart(1);
					AppendComment(semiComment, trail);
				}
			}

			for (int s < codes.Count)
			{
				var segCode = StringView(codes[s]);
				segCode.Trim();
				// Comment on the same line as this segment's leading comma belongs to the previous case.
				if (!sameLineAsPrev[s].IsEmpty)
				{
					if (!outCases.IsEmpty)
						AppendComment(outCases.Back.Comment, sameLineAsPrev[s]);
					else
						AppendComment(ownComments[s], sameLineAsPrev[s]);
				}
				if (segCode.IsEmpty)
				{
					// Trailing comma / empty list: loose comments go to the last case.
					if (!ownComments[s].IsEmpty && !outCases.IsEmpty)
						AppendComment(outCases.Back.Comment, ownComments[s]);
					continue;
				}
				StringView name = segCode;
				StringView value = "";
				int eq = segCode.IndexOf('=');
				if (eq >= 0)
				{
					name = segCode.Substring(0, eq);
					value = segCode.Substring(eq + 1);
					name.Trim();
					value.Trim();
					if (value.IsEmpty || value.StartsWith('='))
						return false;
				}
				if (!IsIdentifier(name) || name == "case")
					return false;
				EnumCase ec = new .(name, value, "");
				AppendComment(ec.Comment, ownComments[s]);
				outCases.Add(ec);
			}
			if (!semiComment.IsEmpty && !outCases.IsEmpty)
				AppendComment(outCases.Back.Comment, semiComment);
			return true;
		}

		/// Text that replaces [region.Start, replaceEnd) - see SourceDocument.SetEnumCases.
		public static void Generate(List<EnumCase> cases, StringView caseIndent, StringView closeIndent, bool semicolon, String outText)
		{
			outText.Append('\n');
			for (let ec in cases)
			{
				bool last = @ec.Index == cases.Count - 1;
				outText.Append(caseIndent);
				outText.Append(ec.Name);
				if (!ec.Value.IsEmpty)
					outText.AppendF(" = {}", ec.Value);
				if (!last)
					outText.Append(',');
				else if (semicolon)
					outText.Append(';');
				if (!ec.Comment.IsEmpty)
				{
					String comment = scope .(ec.Comment);
					comment.Replace('\n', ' ');
					comment.Replace('\r', ' ');
					outText.AppendF(" // {}", comment);
				}
				outText.Append('\n');
			}
			if (cases.IsEmpty && semicolon)
				outText.AppendF("{};\n", caseIndent);
			if (!semicolon)
				outText.Append(closeIndent);
		}
	}
}
