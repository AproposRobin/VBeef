using System;
using System.Collections;

namespace VisualBeef.Syntax
{
	/// Recursive-descent parser for the subset of Beef that the visual editor understands.
	/// Anything it does not understand is captured as a Raw node spanning the original tokens,
	/// so parsing never loses information and never fails.
	class Parser
	{
		CompilationUnit mUnit;
		List<Token> mTokens;
		String mText;
		int mPos;
		/// Error recovery state. mFailCount goes up whenever the parser meets structurally
		/// broken code (unbalanced or mismatched brackets, a block cut off by the end of the
		/// file); ParseMembers turns the member being parsed into a Broken member.
		int mFailCount;
		String mFailMsg = new .() ~ delete _;
		List<int32> mBalStack = new .() ~ delete _;
		/// Why the last `switch` was not modelled (handed to the Raw statement that replaces it).
		String mSwitchDecline ~ delete _;

		static String[?] sModifiers = .("public", "private", "protected", "internal", "static", "abstract", "virtual",
			"override", "sealed", "extern", "readonly", "const", "unsafe", "volatile", "mut", "concrete", "implicit",
			"explicit", "partial", "new", "inline", "append", "ref");

		/// Words that can never start a type or name an expression variable.
		static String[?] sReserved = .("if", "else", "for", "while", "do", "return", "break", "continue", "switch",
			"case", "default", "new", "scope", "delete", "defer", "using", "namespace", "class", "struct", "interface",
			"enum", "extension", "public", "private", "protected", "internal", "static", "abstract", "virtual",
			"override", "sealed", "extern", "readonly", "const", "is", "as", "in", "out", "ref", "mut", "params",
			"true", "false", "null", "this", "base", "typeof", "sizeof", "alignof", "strideof", "nameof", "operator",
			"let", "var", "mixin", "append", "repeat", "fallthrough", "where", "delegate", "function", "throw", "try",
			"catch", "finally", "checked", "unchecked", "fixed", "goto", "typealias", "offsetof");

		/// A word that can't be used as a plain variable name.
		public static bool IsReservedWord(StringView word)
		{
			for (let w in sReserved)
				if (w == word)
					return true;
			return false;
		}

		public static CompilationUnit Parse(StringView text)
		{
			CompilationUnit unit = new .();
			unit.Text.Set(text);
			Lexer.Tokenize(unit.Text, unit.Tokens);
			Parser parser = scope .();
			parser.mUnit = unit;
			parser.mTokens = unit.Tokens;
			parser.mText = unit.Text;
			parser.mPos = 0;
			parser.ParseMembers(unit.Members, false);
			AssignCondKeys(unit);
			AssignScopes(unit, unit.Members, null);
			return unit;
		}


		/// Sets Member.Owner and Member.OwnGenerics down the tree (what a declaration check
		/// needs to know: the enclosing type and the generic parameters in scope).
		static void AssignScopes(CompilationUnit unit, List<Member> members, Member owner)
		{
			for (let m in members)
			{
				m.Owner = owner;
				if ((m.Kind == .Type || m.Kind == .Method) && m.GenericOpenTok >= 0 && m.GenericCloseTok > m.GenericOpenTok)
				{
					String names = new .();
					int depth = 0;
					bool expectName = false;
					for (int i = m.GenericOpenTok; i <= m.GenericCloseTok; i++)
					{
						let tx = unit.TokenText(i);
						if (tx == "<") { depth++; if (depth == 1) expectName = true; continue; }
						if (tx == ">") { depth--; continue; }
						if (tx == ">>") { depth -= 2; continue; }
						if (depth == 1 && tx == ",") { expectName = true; continue; }
						if (depth == 1 && expectName && unit.Tokens[i].Kind == .Identifier && tx != "const")
						{
							if (!names.IsEmpty)
								names.Append(',');
							names.Append(tx);
							expectName = false;
						}
					}
					if (names.IsEmpty)
						delete names;
					else
						m.OwnGenerics = names;
				}
				if (m.Members != null)
					AssignScopes(unit, m.Members, (m.Kind == .Type) ? m : m.Owner);
			}
		}
		/// Methods declared in different `#if` / `#else` arms with the same name and parameters
		/// (corlib's `GC.Report()` extern in one arm, a stub in the other) get the arm path in
		/// their key so each has a graph of its own; every other method keeps its plain key.
		static void AssignCondKeys(CompilationUnit unit)
		{
			List<Member> methods = scope .();
			List<Member> owners = scope .();
			unit.CollectMethods(methods, owners);
			Dictionary<String, int> counts = scope .();
			List<String> keys = scope .();
			defer
			{
				for (let k in keys)
					delete k;
			}
			for (int i < methods.Count)
			{
				let m = methods[i];
				let path = unit.CondPathAt(m.HasSpan ? m.FirstTok : 0);
				if (!path.IsEmpty)
					m.CondPath = new String(path);
				String key = new .();
				if (owners[i] != null)
					key.AppendF("{}.", owners[i].Name);
				key.AppendF("{}(", m.Name);
				if (m.Params != null)
					for (let p in m.Params)
						key.AppendF("{}{}", (@p.Index > 0) ? "," : "", p.Type);
				key.Append(')');
				keys.Add(key);
				if (counts.TryAdd(key, let keyPtr, let valuePtr))
					*valuePtr = 1;
				else
					(*valuePtr)++;
			}
			for (int i < methods.Count)
			{
				let m = methods[i];
				if (counts[keys[i]] < 2 || m.CondPath == null)
					continue;
				// Layout keys are `methodKey|node`: no '|' or '#' in a method key.
				String s = scope .(m.CondPath);
				s.Replace("||", " or ");
				s.Replace("&&", " and ");
				while (s.Contains("  "))
					s.Replace("  ", " ");
				s.Replace('|', '/');
				s.Replace("#", "");
				s.Replace('\t', ' ');
				m.KeySuffix = new $" [{s}]";
			}

			// Other same-name, same-parameter methods: overloads told apart by their `where`
			// clause (`Get<T>() where T : struct`) or declared in different `extension` blocks of
			// one type. Their constraints go in the key, then a number as a last resort.
			for (int round < 3)
			{
				Dictionary<String, int> fullCounts = scope .();
				List<String> fulls = scope .();
				defer { for (let f in fulls) delete f; }
				for (int i < methods.Count)
				{
					String full = new .(keys[i]);
					if (methods[i].KeySuffix != null)
						full.Append(methods[i].KeySuffix);
					fulls.Add(full);
					if (fullCounts.TryAdd(full, let kp, let vp))
						*vp = 1;
					else
						(*vp)++;
				}
				bool any = false;
				Dictionary<String, int> ordinals = scope .();
				for (int i < methods.Count)
				{
					if (fullCounts[fulls[i]] < 2)
						continue;
					let m = methods[i];
					let owner = owners[i];
					String extra = scope .();
					if (round == 0 && m.ParamsCloseTok >= 0)
					{
						// The method's own constraints: `where ...` up to its body.
						int first = -1;
						int last = -1;
						for (int t = m.ParamsCloseTok + 1; t < unit.Tokens.Count; t++)
						{
							let tt = unit.TokenText(t);
							if (unit.Tokens[t].Kind == .EOF || tt == "{" || tt == "=>" || tt == ";")
								break;
							if (first < 0 && tt == "where")
								first = t;
							if (first >= 0)
								last = t;
						}
						if (first >= 0)
							extra.Append(unit.SpanText(first, last));
					}
					else if (round == 1 && owner != null && owner.WhereFirstTok >= 0)
						extra.Append(unit.SpanText(owner.WhereFirstTok, owner.WhereLastTok));
					else if (round == 2)
					{
						int n = 1;
						if (ordinals.TryAdd(fulls[i], let kp, let vp))
							*vp = 1;
						else
							n = ++(*vp);
						if (n == 1)
							continue; // the first one keeps its key
						extra.AppendF("{}", n);
					}
					if (extra.IsEmpty)
						continue;
					extra.Replace("||", " or ");
					extra.Replace("&&", " and ");
					while (extra.Contains("  "))
						extra.Replace("  ", " ");
					extra.Replace('|', '/');
					extra.Replace("#", "");
					extra.Replace('\t', ' ');
					extra.Replace('\n', ' ');
					extra.Replace('\r', ' ');
					if (m.KeySuffix == null)
						m.KeySuffix = new $" [{extra}]";
					else
					{
						m.KeySuffix.RemoveFromEnd(1);
						m.KeySuffix.AppendF("; {}]", extra);
					}
					any = true;
				}
				if (!any && round == 2)
					break;
			}
		}

		/// Parses `text` as one whole expression (a hole of an interpolated string): the unit owns
		/// the text and tokens the expression's spans refer to. Null (and no unit) when the text
		/// is not exactly one structured expression.
		public static Expr ParseExpression(StringView text, out CompilationUnit outUnit)
		{
			outUnit = null;
			CompilationUnit unit = new .();
			unit.Text.Set(text);
			Lexer.Tokenize(unit.Text, unit.Tokens);
			Parser parser = scope .();
			parser.mUnit = unit;
			parser.mTokens = unit.Tokens;
			parser.mText = unit.Text;
			parser.mPos = 0;
			Expr e = parser.ParseExpr();
			if (e == null || !parser.AtEnd || parser.mFailCount > 0)
			{
				delete e;
				delete unit;
				return null;
			}
			outUnit = unit;
			return e;
		}

		// ------------------------------------------------------------------ token helpers

		TokenKind Kind(int idx)
		{
			if (idx >= mTokens.Count)
				return .EOF;
			return mTokens[idx].Kind;
		}

		StringView Text(int idx)
		{
			if (idx >= mTokens.Count)
				return "";
			let tok = mTokens[idx];
			return StringView(mText, tok.Start, tok.End - tok.Start);
		}

		bool AtEnd => Kind(mPos) == .EOF;

		bool Is(StringView s) => Kind(mPos) != .EOF && Kind(mPos) != .String && Kind(mPos) != .Char && Text(mPos) == s;
		bool IsAt(int idx, StringView s) => Kind(idx) != .EOF && Kind(idx) != .String && Kind(idx) != .Char && Text(idx) == s;

		bool Accept(StringView s)
		{
			if (Is(s))
			{
				mPos++;
				return true;
			}
			return false;
		}

		/// True when tokens a and b touch with no trivia in between ("> >" vs ">>").
		bool Adjacent(int a, int b)
		{
			if (b >= mTokens.Count)
				return false;
			return mTokens[a].TrailEnd == mTokens[b].LeadStart && mTokens[a].End == mTokens[b].Start;
		}

		static bool IsReserved(StringView s)
		{
			for (let r in sReserved)
				if (s == r)
					return true;
			return false;
		}

		static bool IsModifier(StringView s)
		{
			for (let r in sModifiers)
				if (s == r)
					return true;
			return false;
		}

		bool IsIdent(int idx)
		{
			return Kind(idx) == .Identifier && !IsReserved(Text(idx));
		}

		bool IsOpen(int idx) => IsAt(idx, "(") || IsAt(idx, "[") || IsAt(idx, "{");
		bool IsClose(int idx) => IsAt(idx, ")") || IsAt(idx, "]") || IsAt(idx, "}");

		/// mPos at an opening bracket; skips to just past its partner. Returns false at EOF.
		bool SkipBalanced()
		{
			// Brackets must close in order: `(` needs `)`, `[` needs `]`, `{` needs `}`.
			int baseCount = mBalStack.Count;
			defer { if (mBalStack.Count > baseCount) mBalStack.RemoveRange(baseCount, mBalStack.Count - baseCount); }
			while (!AtEnd)
			{
				if (IsOpen(mPos))
					mBalStack.Add((int32)mPos);
				else if (IsClose(mPos))
				{
					if (mBalStack.Count <= baseCount)
					{
						// Closer without an opener (the call started inside a bracket).
						mPos++;
						return true;
					}
					let open = mBalStack[mBalStack.Count - 1];
					if (!Matches(open, mPos))
					{
						Fail(scope $"'{Text(mPos)}' on line {mUnit.LineOf(mTokens[mPos].Start)} does not match '{Text(open)}' opened on line {mUnit.LineOf(mTokens[open].Start)}");
						return false;
					}
					mBalStack.RemoveAt(mBalStack.Count - 1);
					if (mBalStack.Count == baseCount)
					{
						mPos++;
						return true;
					}
				}
				mPos++;
			}
			if (mBalStack.Count > baseCount)
			{
				let open = mBalStack[baseCount];
				Fail(scope $"'{Text(open)}' opened on line {mUnit.LineOf(mTokens[open].Start)} is never closed");
			}
			return false;
		}

		bool Matches(int open, int close)
		{
			let o = Text(open)[0];
			let c = Text(close)[0];
			return (o == '(' && c == ')') || (o == '[' && c == ']') || (o == '{' && c == '}');
		}

		void Fail(StringView msg)
		{
			mFailCount++;
			if (mFailMsg.IsEmpty)
				mFailMsg.Set(msg);
		}

		String NewText(int first, int last)
		{
			return new String(mUnit.SpanText(first, last));
		}

		// ------------------------------------------------------------------ types

		/// Skips a type reference without allocating. Restores position on failure.
		bool SkipType()
		{
			int start = mPos;
			if (Is("("))
			{
				// Tuple type
				if (!SkipBalanced())
				{
					mPos = start;
					return false;
				}
			}
			else if (Is("delegate") || Is("function"))
			{
				mPos++;
				if (!SkipType() || !Is("("))
				{
					mPos = start;
					return false;
				}
				SkipBalanced();
			}
			else if (Is("decltype") || Is("comptype") || Is("alloctype") || Is("nullable") || Is("rettype"))
			{
				mPos++;
				if (!Is("(") || !SkipBalanced())
				{
					mPos = start;
					return false;
				}
			}
			else
			{
				if (!IsIdent(mPos))
				{
					mPos = start;
					return false;
				}
				while (true)
				{
					if (!IsIdent(mPos))
					{
						mPos = start;
						return false;
					}
					mPos++;
					if (Is("<"))
					{
						if (!SkipGenericArgs())
						{
							mPos = start;
							return false;
						}
					}
					if ((Is(".") || Is("::")) && IsIdent(mPos + 1))
					{
						mPos++;
						continue;
					}
					break;
				}
			}

			// Suffixes
			while (true)
			{
				if (Is("*"))
				{
					mPos++;
					continue;
				}
				if (Is("?") && !IsAt(mPos + 1, "?") && !IsAt(mPos + 1, "."))
				{
					// Nullable marker. Avoid eating a ternary "x ? a : b" by requiring that what
					// follows looks like the end of a type.
					let next = mPos + 1;
					if (IsIdent(next) || IsAt(next, ">") || IsAt(next, ",") || IsAt(next, ")") || IsAt(next, "[") || IsAt(next, "*"))
					{
						mPos++;
						continue;
					}
					break;
				}
				if (Is("["))
				{
					if (!SkipBalanced())
					{
						mPos = start;
						return false;
					}
					continue;
				}
				if (Is("..."))
				{
					mPos++;
					continue;
				}
				break;
			}
			return true;
		}

		/// mPos at '<'. Skips `<T, U<V>>` including split '>' tokens.
		bool SkipGenericArgs()
		{
			int start = mPos;
			if (!Accept("<"))
				return false;
			if (Accept(">"))
				return true; // open generic `Foo<>`
			while (true)
			{
				if (Kind(mPos) == .Number)
					mPos++;
				else if (Is("const"))
				{
					mPos++;
					if (!SkipType())
					{
						mPos = start;
						return false;
					}
				}
				else if (!SkipType())
				{
					mPos = start;
					return false;
				}
				if (Accept(","))
					continue;
				if (Accept(">"))
					return true;
				mPos = start;
				return false;
			}
		}

		// ------------------------------------------------------------------ members

		void ParseMembers(List<Member> list, bool untilBrace)
		{
			while (!AtEnd)
			{
				if (untilBrace && Is("}"))
					return;
				int start = mPos;
				int failBefore = mFailCount;
				mFailMsg.Clear();
				Member m = ParseMember();
				bool broken = mFailCount != failBefore;
				String error = scope .();
				if (broken)
					error.Set(mFailMsg);
				else if (m != null && m.Kind == .Method)
				{
					// Brackets balanced but a declaration starts inside the member: its braces
					// swallowed the next members.
					int intruder = FindIntruder(start, m.LastTok);
					if (intruder >= 0)
					{
						broken = true;
						error.AppendF("the member is not closed before the declaration on line {}", mUnit.LineOf(mTokens[intruder].Start));
					}
				}
				if (!broken && m == null)
				{
					mPos = start;
					m = ParseRawMember();
					if (m.LastTok + 1 >= mTokens.Count - 1 && !IsAt(m.LastTok, ";") && !IsAt(m.LastTok, "}"))
					{
						broken = true;
						error.Set("unexpected end of file");
					}
					else if (UnreadableDeclaration(m, error))
					{
						// A function or variable the parser could not read (`default F()`,
						// `var mX = 1;`): it must not vanish from the editor. It becomes a
						// Broken member with exactly the raw text (byte exact, nothing dropped).
						m.Kind = .Broken;
						m.Params = new .();
						m.TypeText = new .();
						SetBrokenName(m);
						m.Error = new String();
						m.Error.AppendF("line {}: {}", mUnit.LineOf(mTokens[m.FirstTok].Start), error);
						list.Add(m);
						if (mPos <= start)
							mPos = start + 1;
						continue;
					}
				}
				if (broken)
				{
					delete m;
					m = MakeBroken(start, error);
					mFailCount = failBefore; // handled
					mFailMsg.Clear();
				}
				list.Add(m);
				if (mPos <= start)
					mPos = start + 1; // safety
			}
		}

		/// Indentation (characters) of the line a token starts, or -1 when the token is not the
		/// first on its line.
		int LineLeadIndent(int tokIdx)
		{
			int p = mTokens[tokIdx].Start;
			int n = 0;
			while (p > 0)
			{
				let c = mText[p - 1];
				if (c == '\n')
					return n;
				if (c != ' ' && c != '\t')
					return -1;
				n++;
				p--;
			}
			return n;
		}

		bool IsAccessModifier(int idx)
		{
			return Kind(idx) == .Identifier && (Text(idx) == "public" || Text(idx) == "private" || Text(idx) == "protected" || Text(idx) == "internal");
		}

		/// First token after the member's header attributes.
		int SkipAttrTokens(int start)
		{
			int i = start;
			while (IsAt(i, "["))
			{
				int depth = 0;
				while (i < mTokens.Count && Kind(i) != .EOF)
				{
					if (IsAt(i, "[")) depth++;
					else if (IsAt(i, "]"))
					{
						depth--;
						if (depth == 0)
						{
							i++;
							break;
						}
					}
					i++;
				}
			}
			return i;
		}

		/// A line-leading access modifier inside tokens first+1..last at or left of the member's
		/// own indentation can only be the next member: returns its index, or -1.
		int FindIntruder(int first, int last)
		{
			int bodyStart = SkipAttrTokens(first);
			int indent = LineLeadIndent(first);
			if (indent < 0)
				indent = LineLeadIndent(bodyStart);
			if (indent < 0)
				return -1;
			for (int i = bodyStart + 1; i <= last && i < mTokens.Count; i++)
			{
				if (!IsAccessModifier(i))
					continue;
				let ind = LineLeadIndent(i);
				if (ind >= 0 && ind <= indent)
					return i;
			}
			return -1;
		}

		/// Builds a Broken member for the text starting at `start` and moves mPos past it.
		/// The extent is found by counting only braces: up to the matching '}' of the first body,
		/// or the first ';', but never into the next declaration (a line-leading access modifier
		/// at or left of the member's indentation) or past a '}' that closes the parent.
		Member MakeBroken(int start, StringView error)
		{
			int bodyStart = SkipAttrTokens(start);
			int indent = LineLeadIndent(start);
			if (indent < 0)
				indent = LineLeadIndent(bodyStart);
			int last = start;
			int depth = 0;
			int i = start;
			bool seenBrace = false;
			while (i < mTokens.Count && Kind(i) != .EOF)
			{
				if (i > bodyStart && indent >= 0)
				{
					let ind = LineLeadIndent(i);
					if (ind >= 0 && ((IsAccessModifier(i) && ind <= indent) || (IsAt(i, "}") && ind < indent && depth > 0)))
						break;
				}
				if (IsAt(i, "{"))
				{
					depth++;
					seenBrace = true;
				}
				else if (IsAt(i, "}"))
				{
					depth--;
					if (depth < 0)
						break; // closes the parent
					if (depth == 0)
					{
						last = i;
						i++;
						break;
					}
				}
				else if (IsAt(i, ";") && depth == 0 && !seenBrace)
				{
					last = i;
					i++;
					break;
				}
				last = i;
				i++;
			}
			// A `;` directly after the closing brace belongs to the member.
			if (depth == 0 && seenBrace && IsAt(i, ";") && Kind(i) != .EOF && i == last + 1)
			{
				last = i;
				i++;
			}
			Member m = new .(.Broken);
			m.FirstTok = (int32)start;
			m.LastTok = (int32)Math.Max(last, start);
			m.Params = new .();
			m.TypeText = new .();
			SetBrokenName(m);
			m.Error = new String();
			m.Error.AppendF("line {}: {}", mUnit.LineOf(mTokens[Math.Min(start, mTokens.Count - 1)].Start), error);
			mPos = m.LastTok + 1;
			return m;
		}

		/// Best-effort name of a Broken member: the identifier before the first '(' (a function),
		/// else the identifier before the first '=' / ';' (a variable), else "?".
		void SetBrokenName(Member m)
		{
			int bodyStart = SkipAttrTokens(m.FirstTok);
			int lastIdent = -1;
			for (int k = bodyStart; k <= m.LastTok && k < mTokens.Count; k++)
			{
				if (IsAt(k, "(") && k > bodyStart && Kind(k - 1) == .Identifier)
				{
					m.Name.Set(Text(k - 1));
					m.NameTok = (int32)(k - 1);
					return;
				}
				if (IsAt(k, "{") || IsAt(k, ";") || IsAt(k, "=") || IsAt(k, "=>"))
					break;
				if (IsAt(k, "(") || IsAt(k, "<"))
					break; // `Bad<>(...)`: the name is the identifier before the generic list
				if (Kind(k) == .Identifier && !IsModifier(Text(k)))
					lastIdent = k;
			}
			if (lastIdent > bodyStart || (lastIdent >= 0 && IsAt(lastIdent + 1, "=")))
			{
				m.Name.Set(Text(lastIdent));
				m.NameTok = (int32)lastIdent;
			}
			else
				m.Name.Set("?");
		}

		/// A Raw member (ParseMember gave up on it without a bracket error) that is really a
		/// function or variable declaration the parser could not read. Declarations the editor
		/// keeps as text on purpose (`using`, `typealias`, `delegate` / `function` types, enum
		/// `case`s, operators) are not. Sets `outError` to the reason.
		bool UnreadableDeclaration(Member raw, String outError)
		{
			int i = SkipAttrTokens(raw.FirstTok);
			while (i <= raw.LastTok && Kind(i) == .Identifier && IsModifier(Text(i)))
				i++;
			if (i > raw.LastTok || IsAt(i, ";") || IsAt(i, "}") || IsAt(i, "[") || IsAt(i, "("))
				return false; // `;`, a stray brace, an attribute on its own, a tuple type
			if (Kind(i) != .Identifier)
			{
				outError.Append("this declaration could not be read");
				return true;
			}
			let first = Text(i);
			if (first == "using" || first == "typealias" || first == "delegate" || first == "function" || first == "case" ||
				first == "operator" || first == "mixin" || first == "this" || first == "namespace")
				return false;
			// Up to the body / initializer / end: operators are kept as text; a '(' means a function.
			int paren = -1;
			int angle = 0;
			for (int k = i; k <= raw.LastTok; k++)
			{
				if (IsAt(k, "operator"))
					return false;
				if (IsAt(k, "{") || IsAt(k, "=>") || IsAt(k, ";") || IsAt(k, "=") || IsAt(k, "~"))
					break;
				if (IsAt(k, "<"))
					angle++;
				else if (IsAt(k, ">"))
					angle--;
				else if (IsAt(k, ">>"))
					angle -= 2;
				// `Event<delegate void(int)> mOnX`: a '(' inside generic arguments is a type.
				if (IsAt(k, "(") && paren < 0 && angle <= 0)
					paren = k;
			}
			bool isFunction = paren > i;
			if ((first == "var" || first == "let") && !isFunction)
			{
				outError.AppendF("'{}' is not a valid type for a member variable: name its type", first);
				return true;
			}
			if (!isFunction)
				return false;
			// Something that looks like `Type Name(...)` but did not parse. Not: a constructor
			// written without `this` (`Name(...)`, C# style, usually in an inactive `#if`), an
			// explicit generic interface member (`IFoo<T>.Bar(...)`).
			if (IsAt(paren - 1, ">"))
			{
				// `Type Name<...>(`: a generic function whose generic list did not parse.
			}
			else if (Kind(paren - 1) != .Identifier || paren - 1 <= i || IsAt(paren - 2, "."))
				return false;
			outError.Append("this function's declaration could not be read (check the return type and the parameter list)");
			return true;
		}

		/// A field's `~` starts its destructor clause (`T x = new .() ~ delete _;`) when it
		/// follows the name or a complete value; after `=`, `(`, `,` or an operator it is the
		/// bitwise not of a value (`int x = ~0;`).
		bool IsDtorTilde(int i)
		{
			if (i <= 0)
				return false;
			let prev = Kind(i - 1);
			if (prev == .Identifier || prev == .Number || prev == .String || prev == .Char)
				return true;
			let t = Text(i - 1);
			return t == ")" || t == "]" || t == "}" || t == ">";
		}

		Member ParseRawMember()
		{
			Member m = new .(.Raw);
			m.FirstTok = (int32)mPos;
			int depth = 0;
			while (!AtEnd)
			{
				if (depth == 0 && Is("}"))
				{
					if (mPos == m.FirstTok)
						mPos++; // stray brace: consume it so we make progress
					break;
				}
				if (IsOpen(mPos))
					depth++;
				else if (IsClose(mPos))
				{
					depth--;
					if (depth == 0 && Is("}"))
					{
						mPos++;
						if (Is(";"))
							mPos++;
						break;
					}
				}
				else if (depth == 0 && Is(";"))
				{
					mPos++;
					break;
				}
				mPos++;
			}
			m.LastTok = (int32)Math.Max(m.FirstTok, mPos - 1);
			return m;
		}

		static String[?] cDeclStarts = .("using", "namespace", "class", "struct", "enum", "interface", "extension", "typealias", "delegate",
			"function", "public", "private", "protected", "abstract", "sealed", "extern");

		/// A using with no `;` yet: token `i` starts the next declaration instead of continuing the
		/// using. It is the first on its line and either a declaration keyword or a name right after a
		/// complete name (`using System` then `Foo.Bar x;` on the next line).
		bool UsingEndsBefore(int i)
		{
			if (Kind(i) != .Identifier || LineLeadIndent(i) < 0)
				return false;
			for (let w in cDeclStarts)
				if (Text(i) == w)
					return true;
			let prev = i - 1;
			return Kind(prev) == .Identifier && !IsAt(prev, "using") && !IsAt(prev, "static") && !IsAt(prev, "internal");
		}

		void SkipAttributes()
		{
			while (Is("["))
			{
				if (!SkipBalanced())
					return;
			}
		}

		Member ParseMember()
		{
			int start = mPos;

			if (Is("using") && !IsAt(mPos + 1, "("))
			{
				Member m = new .(.Using);
				m.FirstTok = (int32)mPos;
				mPos++;
				// A using ends at its `;`. Without one it ends where something that cannot be part of
				// it starts (a bracket, a declaration on a later line): the rest of the file is not
				// swallowed, and the using is listed as unreadable.
				bool closed = false;
				while (!AtEnd)
				{
					if (Is(";"))
					{
						mPos++;
						closed = true;
						break;
					}
					if (Is("{") || Is("}") || Is("[") || Is("(") || Is(")") || UsingEndsBefore(mPos))
						break;
					mPos++;
				}
				m.LastTok = (int32)(mPos - 1);
				if (!closed)
				{
					m.Kind = .Broken;
					m.Params = new .();
					m.TypeText = new .();
					for (int i = m.FirstTok; i <= m.LastTok; i++)
					{
						if (i > m.FirstTok && !IsAt(i, ".") && !IsAt(i - 1, "."))
							m.Name.Append(' ');
						m.Name.Append(Text(i));
					}
					m.Error = new String();
					m.Error.AppendF("line {}: this using is not closed by ;", mUnit.LineOf(mTokens[m.FirstTok].Start));
				}
				return m;
			}

			if (Is("namespace"))
			{
				Member m = new .(.Namespace);
				m.FirstTok = (int32)mPos;
				mPos++;
				int nameStart = mPos;
				while (!AtEnd && !Is("{") && !Is(";"))
					mPos++;
				m.Name.Set(mUnit.SpanText(nameStart, mPos - 1));
				m.Members = new .();
				if (Accept(";"))
				{
					// File-scoped namespace: everything that follows belongs to it.
					ParseMembers(m.Members, false);
					m.LastTok = (int32)(mPos - 1);
					return m;
				}
				if (!Is("{"))
				{
					delete m;
					return null;
				}
				m.OpenBrace = (int32)mPos;
				mPos++;
				ParseMembers(m.Members, true);
				if (!Is("}"))
				{
					m.LastTok = (int32)(mPos - 1);
					return m;
				}
				m.CloseBrace = (int32)mPos;
				mPos++;
				m.LastTok = (int32)(mPos - 1);
				return m;
			}

			SkipAttributes();
			int attrEnd = mPos;
			int modStart = mPos;
			bool isStatic = false;
			while (Kind(mPos) == .Identifier && IsModifier(Text(mPos)))
			{
				// `new` / `append` / `ref` are only modifiers when followed by more declaration
				if ((Is("new") || Is("append") || Is("ref")) && !IsIdent(mPos + 1) && !(Kind(mPos + 1) == .Identifier && IsModifier(Text(mPos + 1))))
					break;
				if (Is("static"))
					isStatic = true;
				mPos++;
			}
			int modEnd = mPos;

			if (Is("class") || Is("struct") || Is("interface") || Is("enum") || Is("extension"))
				return WithAttributes(ParseTypeDecl(start, modStart, modEnd), start, attrEnd);

			// Beef global block: `static { ... }` holds namespace-level functions and fields.
			if (Is("{") && isStatic)
			{
				Member t = new .(.Type);
				t.FirstTok = (int32)start;
				SetMods(t, modStart, modEnd);
				t.TypeKind = new String("static");
				t.Name.Set("Globals");
				t.IsStatic = true;
				t.Members = new .();
				t.OpenBrace = (int32)mPos;
				mPos++;
				ParseMembers(t.Members, true);
				if (Is("}"))
				{
					t.CloseBrace = (int32)mPos;
					mPos++;
				}
				t.LastTok = (int32)(mPos - 1);
				// Everything declared in a global block is static.
				for (let m in t.Members)
					m.IsStatic = true;
				return t;
			}

			if (Is("delegate") || Is("function") || Is("typealias") || Is("case") || Is("operator") || Is("using"))
				return null;

			Member method = null;
			if (Is("this") && IsAt(mPos + 1, "("))
			{
				method = new .(.Method);
				method.IsCtor = true;
				method.Name.Set("this");
				method.NameTok = (int32)mPos;
				method.TypeText = new .();
				mPos++;
			}
			else if (Is("~") && IsAt(mPos + 1, "this"))
			{
				method = new .(.Method);
				method.IsDtor = true;
				method.Name.Set("~this");
				method.NameTok = (int32)(mPos + 1);
				method.TypeText = new .();
				mPos += 2;
			}
			else if (Is("mixin") && IsIdent(mPos + 1))
			{
				method = new .(.Method);
				method.IsMixin = true;
				mPos++;
				method.NameTok = (int32)mPos;
				method.Name.Set(Text(mPos));
				method.TypeText = new .();
				mPos++;
			}
			else
			{
				int typeStart = mPos;
				// `var F()` / `let F()`: only valid on [Comptime] functions (corlib's
				// Enum.GetMinValue<T>), but read as a function either way so it stays visible;
				// GraphBuilder puts the error on the entry node when it is not allowed.
				if ((Is("var") || Is("let")) && IsIdent(mPos + 1) && (IsAt(mPos + 2, "(") || IsAt(mPos + 2, "<")))
					mPos++;
				else if (!SkipType())
					return null;
				int typeEnd = mPos;
				// Indexer: `int this[int i] { get ... set ... }`
				if (Is("this") && IsAt(mPos + 1, "[") && typeEnd > typeStart)
				{
					Member idx = new .(.Property);
					idx.IsIndexer = true;
					idx.FirstTok = (int32)start;
					idx.TypeText = NewText(typeStart, typeEnd - 1);
					idx.Name.Set("this");
					idx.NameTok = (int32)mPos;
					idx.IsStatic = isStatic;
					SetMods(idx, modStart, modEnd);
					mPos++;
					idx.ParamsOpenTok = (int32)mPos;
					idx.Params = new .();
					if (!ParseParams(idx.Params))
					{
						delete idx;
						return null;
					}
					idx.ParamsCloseTok = (int32)(mPos - 1);
					if (Is("{"))
					{
						if (!ParseAccessors(idx))
						{
							delete idx;
							return null;
						}
					}
					else if (Is("=>"))
					{
						while (!AtEnd && !Is(";"))
						{
							if (IsOpen(mPos))
								SkipBalanced();
							else
								mPos++;
						}
						Accept(";");
					}
					else
					{
						delete idx;
						return null;
					}
					idx.LastTok = (int32)(mPos - 1);
					return WithAttributes(idx, start, attrEnd);
				}
				// Name (allow explicit interface implementation `IFoo.Bar`)
				if (!IsIdent(mPos))
					return null;
				int nameStart = mPos;
				mPos++;
				while (Is(".") && IsIdent(mPos + 1))
					mPos += 2;
				int nameEnd = mPos;

				if (Is("(") || Is("<"))
				{
					method = new .(.Method);
					method.TypeText = NewText(typeStart, typeEnd - 1);
					method.Name.Set(mUnit.SpanText(nameStart, nameEnd - 1));
					method.NameTok = (int32)(nameEnd - 1);
					if (Is("<"))
					{
						if (!SkipGenericParams(method))
						{
							delete method;
							return null;
						}
					}
				}
				else if (Is("=") || Is(";") || Is(",") || Is("~"))
				{
					Member field = new .(.Field);
					field.FirstTok = (int32)start;
					field.TypeText = NewText(typeStart, typeEnd - 1);
					field.Name.Set(mUnit.SpanText(nameStart, nameEnd - 1));
					field.NameTok = (int32)nameStart;
					SetMods(field, modStart, modEnd);
					field.IsStatic = isStatic;
					if (Is("="))
						field.InitTok = (int32)mPos;
					int depth = 0;
					while (!AtEnd)
					{
						if (IsOpen(mPos)) depth++;
						else if (IsClose(mPos))
						{
							if (depth == 0)
								break;
							depth--;
						}
						else if (depth == 0 && Is(";"))
						{
							mPos++;
							break;
						}
						else if (depth == 0 && Is("~") && field.DtorTok < 0 && IsDtorTilde(mPos))
							field.DtorTok = (int32)mPos;
						mPos++;
					}
					field.LastTok = (int32)(mPos - 1);
					return WithAttributes(field, start, attrEnd);
				}
				else if (Is("{") || Is("=>"))
				{
					Member prop = new .(.Property);
					prop.FirstTok = (int32)start;
					prop.TypeText = NewText(typeStart, typeEnd - 1);
					prop.Name.Set(mUnit.SpanText(nameStart, nameEnd - 1));
					prop.NameTok = (int32)nameStart;
					SetMods(prop, modStart, modEnd);
					prop.IsStatic = isStatic;
					if (Is("{"))
					{
						ParseAccessors(prop);
						if (Is("="))
						{
							prop.InitTok = (int32)mPos;
							// auto-property initializer
							while (!AtEnd && !Is(";"))
								mPos++;
							Accept(";");
						}
					}
					else
					{
						while (!AtEnd && !Is(";"))
						{
							if (IsOpen(mPos))
								SkipBalanced();
							else
								mPos++;
						}
						Accept(";");
					}
					prop.LastTok = (int32)(mPos - 1);
					return WithAttributes(prop, start, attrEnd);
				}
				else
					return null;
			}

			method.FirstTok = (int32)start;
			SetMods(method, modStart, modEnd);
			method.IsStatic = isStatic;
			if (!Is("("))
			{
				delete method;
				return null;
			}
			method.ParamsOpenTok = (int32)mPos;
			method.Params = new .();
			if (!ParseParams(method.Params))
			{
				delete method;
				return null;
			}
			method.ParamsCloseTok = (int32)(mPos - 1);

			// Constraints / ctor chaining, up to the body
			while (!AtEnd && !Is("{") && !Is(";") && !Is("=>"))
			{
				if (Is("("))
					SkipBalanced();
				else if (Is("}"))
				{
					delete method;
					return null;
				}
				else
					mPos++;
			}

			if (Is("{"))
			{
				method.Body = ParseBlock();
				if (method.Body == null)
				{
					delete method;
					return null;
				}
			}
			else if (Is("=>"))
			{
				while (!AtEnd && !Is(";"))
				{
					if (IsOpen(mPos))
						SkipBalanced();
					else
						mPos++;
				}
				Accept(";");
			}
			else
				Accept(";");
			method.LastTok = (int32)(mPos - 1);
			return WithAttributes(method, start, attrEnd);
		}

		/// Keeps the attribute text `[...]` that precedes a declaration (additive: nothing else
		/// reads it; the member's span already covers it).
		Member WithAttributes(Member m, int first, int attrEnd)
		{
			if (m != null && attrEnd > first)
			{
				m.Attributes = NewText(first, attrEnd - 1);
				m.AttrFirstTok = (int32)first;
				m.AttrLastTok = (int32)(attrEnd - 1);
			}
			return m;
		}

		/// The modifier words of a declaration: their text and their token span.
		void SetMods(Member m, int modStart, int modEnd)
		{
			m.Modifiers.Set(mUnit.SpanText(modStart, modEnd - 1));
			if (modEnd > modStart)
			{
				m.ModFirstTok = (int32)modStart;
				m.ModLastTok = (int32)(modEnd - 1);
			}
		}

		/// mPos at '<': records the span of a generic parameter list and skips it.
		bool SkipGenericParams(Member m)
		{
			int open = mPos;
			if (!SkipGenericArgs())
				return false;
			m.GenericOpenTok = (int32)open;
			m.GenericCloseTok = (int32)(mPos - 1);
			return true;
		}

		/// mPos at the '{' of a property or indexer: parses `get` / `set` accessors into
		/// `prop.Members` (bodies become graphs). Anything it does not recognise (attributes are
		/// fine, `get;`, `get => x;` too) leaves the accessors unparsed and the block skipped, as
		/// before. Returns false only when the braces themselves do not balance.
		bool ParseAccessors(Member prop)
		{
			int save = mPos;
			int failSave = mFailCount;
			List<Member> list = new .();
			bool ok = true;
			mPos++;
			while (ok && !AtEnd && !Is("}"))
			{
				int aStart = mPos;
				SkipAttributes();
				int attrEnd = mPos;
				int modStart = mPos;
				while (Kind(mPos) == .Identifier && (IsModifier(Text(mPos)) || Is("mut")) && !Is("get") && !Is("set"))
					mPos++;
				int modEnd = mPos;
				if (!(Is("get") || Is("set")) || Kind(mPos) != .Identifier)
				{
					ok = false;
					break;
				}
				bool isGet = Is("get");
				Member acc = new .(.Method);
				acc.IsAccessor = true;
				acc.AccessorOf = prop;
				acc.FirstTok = (int32)aStart;
				acc.NameTok = (int32)mPos;
				acc.Name.AppendF("{}.{}", prop.IsIndexer ? "this[]" : prop.Name, isGet ? "get" : "set");
				acc.TypeText = new String(isGet ? (prop.TypeText ?? "") : "void");
				acc.IsStatic = prop.IsStatic;
				SetMods(acc, modStart, modEnd);
				WithAttributes(acc, aStart, attrEnd);
				acc.Params = new .();
				if (prop.Params != null)
				{
					for (let p in prop.Params)
					{
						Param c = new .();
						c.Modifier.Set(p.Modifier);
						c.Type.Set(p.Type);
						c.Name.Set(p.Name);
						if (p.Default != null)
							c.Default = new String(p.Default);
						acc.Params.Add(c);
					}
				}
				if (!isGet)
				{
					Param v = new .();
					v.Type.Set(prop.TypeText ?? "");
					v.Name.Set("value");
					acc.Params.Add(v);
				}
				mPos++;
				list.Add(acc);
				if (Is("{"))
				{
					int failBefore = mFailCount;
					acc.Body = ParseBlock();
					if (acc.Body == null || mFailCount != failBefore)
						ok = false;
				}
				else if (Is("=>"))
				{
					while (!AtEnd && !Is(";") && !Is("}"))
					{
						if (IsOpen(mPos))
						{
							if (!SkipBalanced())
							{
								ok = false;
								break;
							}
						}
						else
							mPos++;
					}
					if (!Accept(";"))
						ok = false;
				}
				else if (!Accept(";"))
					ok = false;
				acc.LastTok = (int32)(mPos - 1);
			}
			if (ok && Is("}"))
			{
				prop.OpenBrace = (int32)save;
				prop.CloseBrace = (int32)mPos;
				prop.Members = list;
				mPos++;
				return true;
			}
			DeleteContainerAndItems!(list);
			mPos = save;
			mFailCount = failSave;
			return SkipBalanced();
		}

		/// mPos at '('. Splits the parameter list on top-level commas.
		bool ParseParams(List<Param> outParams)
		{
			int open = mPos;
			if (!SkipBalanced())
				return false;
			int close = mPos - 1;
			int segStart = open + 1;
			int depth = 0;
			int angle = 0;
			for (int i = open + 1; i <= close; i++)
			{
				bool atEnd = (i == close);
				if (!atEnd)
				{
					if (IsOpen(i)) { depth++; continue; }
					if (IsClose(i)) { depth--; continue; }
					if (IsAt(i, "<")) { angle++; continue; }
					if (IsAt(i, ">")) { if (angle > 0) angle--; continue; }
				}
				if (atEnd || (depth == 0 && angle == 0 && IsAt(i, ",")))
				{
					if (i > segStart)
						outParams.Add(MakeParam(segStart, i - 1));
					segStart = i + 1;
				}
			}
			return true;
		}

		Param MakeParam(int first, int last)
		{
			var first;
			Param p = new .();
			// Leading attributes (`[Pin(Name="x")] float t`): kept as text, not part of the type.
			if (IsAt(first, "["))
			{
				int attrStart = first;
				int depth = 0;
				int i = first;
				while (i <= last)
				{
					if (IsOpen(i))
						depth++;
					else if (IsClose(i))
					{
						depth--;
						if (depth == 0 && !IsAt(i + 1, "["))
						{
							i++;
							break;
						}
					}
					i++;
				}
				if (i <= last)
				{
					p.Attributes = NewText(attrStart, i - 1);
					first = i;
				}
			}
			int defaultTok = -1;
			for (int i = first; i <= last; i++)
			{
				if (IsAt(i, "="))
				{
					defaultTok = i;
					break;
				}
			}
			int declEnd = (defaultTok >= 0) ? defaultTok - 1 : last;
			if (defaultTok >= 0)
				p.Default = NewText(defaultTok + 1, last);

			int typeStart = first;
			while (typeStart < declEnd && Kind(typeStart) == .Identifier &&
				(Text(typeStart) == "ref" || Text(typeStart) == "out" || Text(typeStart) == "in" || Text(typeStart) == "params" ||
				Text(typeStart) == "mut" || Text(typeStart) == "scope" || Text(typeStart) == "readonly"))
				typeStart++;
			if (typeStart > first)
				p.Modifier.Set(mUnit.SpanText(first, typeStart - 1));
			if (declEnd > typeStart && Kind(declEnd) == .Identifier)
			{
				p.Type.Set(mUnit.SpanText(typeStart, declEnd - 1));
				p.Name.Set(Text(declEnd));
			}
			else
				p.Type.Set(mUnit.SpanText(typeStart, declEnd));
			return p;
		}

		void AddRawMember(List<Member> list, int first, int last)
		{
			Member raw = new .(.Raw);
			raw.FirstTok = (int32)first;
			raw.LastTok = (int32)last;
			list.Add(raw);
		}

		/// Spans of a type header between the name and `{` / `;` (last = the token before it):
		/// generic parameters, the base list after ':', the `where` constraints.
		void ScanTypeHeader(Member t, int last)
		{
			if (t.NameTok < 0)
				return;
			int i = t.NameTok + 1;
			if (i <= last && IsAt(i, "<"))
			{
				int depth = 0;
				for (int j = i; j <= last; j++)
				{
					if (IsAt(j, "<")) depth++;
					else if (IsAt(j, ">")) depth--;
					else if (IsAt(j, ">>")) depth -= 2;
					if (depth <= 0)
					{
						t.GenericOpenTok = (int32)i;
						t.GenericCloseTok = (int32)j;
						i = j + 1;
						break;
					}
				}
			}
			int depth = 0;
			for (int j = i; j <= last; j++)
			{
				if (IsAt(j, "<") || IsAt(j, "(") || IsAt(j, "["))
					depth++;
				else if (IsAt(j, ">") || IsAt(j, ")") || IsAt(j, "]"))
					depth--;
				else if (IsAt(j, ">>"))
					depth -= 2;
				else if (depth == 0 && IsAt(j, ":") && t.BaseColonTok < 0 && t.WhereFirstTok < 0)
					t.BaseColonTok = (int32)j;
				else if (depth == 0 && IsAt(j, "where") && t.WhereFirstTok < 0)
				{
					t.WhereFirstTok = (int32)j;
					t.WhereLastTok = (int32)last;
					if (t.BaseColonTok >= 0)
						t.BaseLastTok = (int32)(j - 1);
					return;
				}
			}
			if (t.BaseColonTok >= 0)
				t.BaseLastTok = (int32)last;
		}

		Member ParseTypeDecl(int start, int modStart, int modEnd)
		{
			Member t = new .(.Type);
			t.FirstTok = (int32)start;
			SetMods(t, modStart, modEnd);
			t.KindTok = (int32)mPos;
			t.TypeKind = new String(Text(mPos));
			mPos++;
			if (IsIdent(mPos))
			{
				t.NameTok = (int32)mPos;
				t.Name.Set(Text(mPos));
				mPos++;
			}
			// generics, base list, constraints
			while (!AtEnd && !Is("{") && !Is(";"))
			{
				if (Is("("))
					SkipBalanced();
				else if (Is("}"))
				{
					delete t;
					return null;
				}
				else
					mPos++;
			}
			ScanTypeHeader(t, mPos - 1);
			t.Members = new .();
			if (Accept(";"))
			{
				t.LastTok = (int32)(mPos - 1);
				return t;
			}
			t.OpenBrace = (int32)mPos;
			if (t.TypeKind == "enum")
			{
				// Enum cases are kept as raw text; members after the case list are parsed.
				mPos++;
				int rawStart = mPos;
				int depth = 0;
				while (!AtEnd)
				{
					if (depth == 0 && Is("}"))
						break;
					if (depth == 0 && Is(";"))
					{
						mPos++;
						AddRawMember(t.Members, rawStart, mPos - 1);
						rawStart = -1;
						ParseMembers(t.Members, true);
						break;
					}
					if (IsOpen(mPos)) depth++;
					else if (IsClose(mPos)) depth--;
					mPos++;
				}
				if (rawStart >= 0 && mPos > rawStart)
					AddRawMember(t.Members, rawStart, mPos - 1);
			}
			else
			{
				mPos++;
				ParseMembers(t.Members, true);
				// A Node Library (`static class`): every member is static, written or not.
				if (t.IsNodeLibrary)
					MarkAllStatic(t.Members);
			}
			if (Is("}"))
			{
				t.CloseBrace = (int32)mPos;
				mPos++;
			}
			t.LastTok = (int32)(mPos - 1);
			return t;
		}

		static void MarkAllStatic(List<Member> members)
		{
			if (members == null)
				return;
			for (let m in members)
			{
				if (m.Kind == .Type)
					continue;
				m.IsStatic = true;
				MarkAllStatic(m.Members);
			}
		}

		// ------------------------------------------------------------------ statements

		/// mPos at '{'.
		Stmt ParseBlock()
		{
			if (!Is("{"))
				return null;
			Stmt block = new .(.Block);
			block.FirstTok = (int32)mPos;
			block.Body = new .();
			mPos++;
			while (!AtEnd && !Is("}"))
			{
				int start = mPos;
				Stmt s = ParseStatement();
				if (s == null)
				{
					mPos = start;
					s = ParseRawStatement();
				}
				block.Body.Add(CheckDirectives(s));
				if (mPos == start)
					mPos++;
			}
			if (!Is("}"))
			{
				Fail(scope $"the '{{' on line {mUnit.LineOf(mTokens[block.FirstTok].Start)} is never closed (end of file)");
				delete block;
				return null;
			}
			block.CloseTok = (int32)mPos;
			block.LastTok = (int32)mPos;
			mPos++;
			return block;
		}

		Stmt ParseRawStatement()
		{
			Stmt s = new .(.Raw);
			s.FirstTok = (int32)mPos;
			if (Is("switch") && mSwitchDecline != null)
			{
				s.RawReason = mSwitchDecline;
				mSwitchDecline = null;
			}
			int depth = 0;
			while (!AtEnd)
			{
				if (depth == 0 && Is("}"))
				{
					if (mPos == s.FirstTok)
						mPos++;
					break;
				}
				if (IsOpen(mPos))
					depth++;
				else if (IsClose(mPos))
				{
					depth--;
					if (depth == 0 && Is("}"))
					{
						mPos++;
						// Continue when the block is part of a larger expression `() => { };`
						if (Is(";") || Is(")") || Is(",") || Is(".") || Is("else") || Is("while") || Is("catch") || Is("finally"))
						{
							if (Is(";"))
							{
								mPos++;
								break;
							}
							continue;
						}
						// `case` labels and statements following a switch body
						break;
					}
				}
				else if (depth == 0 && Is(";"))
				{
					mPos++;
					break;
				}
				mPos++;
			}
			s.LastTok = (int32)Math.Max(s.FirstTok, mPos - 1);
			return s;
		}

		Stmt ParseEmbeddedStatement()
		{
			int start = mPos;
			Stmt s = ParseStatement();
			if (s == null)
			{
				mPos = start;
				s = ParseRawStatement();
			}
			return CheckDirectives(s);
		}

		/// Counts conditional-compilation directives in a token's leading trivia.
		/// depthDelta: +1 per #if, -1 per #endif. Returns true if any directive is present.
		bool TriviaDirectives(int tokIdx, ref int depthDelta)
		{
			let trivia = mUnit.LeadingTrivia(tokIdx);
			bool any = false;
			for (let line in trivia.Split('\n'))
			{
				var l = line;
				l.Trim();
				if (!l.StartsWith('#'))
					continue;
				any = true;
				if (l.StartsWith("#if"))
					depthDelta++;
				else if (l.StartsWith("#endif"))
					depthDelta--;
			}
			return any;
		}

		/// Preprocessor directives that cut through a statement can't survive being rebuilt from
		/// a graph, so such statements are kept as raw code.
		Stmt CheckDirectives(Stmt s)
		{
			if (s == null || s.Kind == .Raw || !s.HasSpan)
				return s;
			int depth = 0;
			bool any = false;
			for (int i = s.FirstTok + 1; i <= s.LastTok; i++)
				any |= TriviaDirectives(i, ref depth);
			if (!any)
				return s;
			bool makeRaw = (depth != 0) || s.Kind != .Block && s.Kind != .If && s.Kind != .While && s.Kind != .DoWhile &&
				s.Kind != .For && s.Kind != .ForEach;
			if (!makeRaw)
			{
				// A directive right before an un-braced body splits the statement.
				for (let body in Stmt[2](s.Then, s.Else))
				{
					if (body != null && body.Kind != .Block && body.HasSpan)
					{
						int d = 0;
						if (TriviaDirectives(body.FirstTok, ref d))
							makeRaw = true;
					}
				}
				// `else` preceded by a directive
				if (s.Else != null && s.Else.HasSpan && s.Else.FirstTok > 0)
				{
					int d = 0;
					if (TriviaDirectives(s.Else.FirstTok - 1, ref d))
						makeRaw = true;
				}
			}
			if (!makeRaw)
				return s;
			Stmt raw = new .(.Raw);
			raw.FirstTok = s.FirstTok;
			raw.LastTok = s.LastTok;
			if (s.Kind == .Switch)
				raw.RawReason = new String("switch: preprocessor lines inside");
			delete s;
			return raw;
		}

		/// Parses `( expr )`; returns null on failure.
		Expr ParseParenCondition()
		{
			if (!Accept("("))
				return null;
			Expr e = ParseExprOrRaw(.CloseParen);
			if (e == null || !Accept(")"))
			{
				delete e;
				return null;
			}
			return e;
		}

		Stmt ParseStatement()
		{
			int start = mPos;

			if (Is("{"))
				return ParseBlock();

			if (Is("if"))
			{
				mPos++;
				Stmt s = new .(.If);
				s.FirstTok = (int32)start;
				s.Expr = ParseParenCondition();
				if (s.Expr == null)
				{
					delete s;
					return null;
				}
				s.Then = ParseEmbeddedStatement();
				if (Is("else"))
				{
					mPos++;
					s.Else = ParseEmbeddedStatement();
				}
				s.LastTok = (int32)(mPos - 1);
				return s;
			}

			if (Is("while"))
			{
				mPos++;
				Stmt s = new .(.While);
				s.FirstTok = (int32)start;
				s.Expr = ParseParenCondition();
				if (s.Expr == null)
				{
					delete s;
					return null;
				}
				s.Then = ParseEmbeddedStatement();
				s.LastTok = (int32)(mPos - 1);
				return s;
			}

			if (Is("do") || (Is("repeat") && !IsAt(mPos + 1, ";")))
			{
				bool isRepeat = Is("repeat");
				mPos++;
				Stmt s = new .(.DoWhile);
				s.FirstTok = (int32)start;
				if (isRepeat)
					s.Alloc = new String("repeat");
				s.Then = ParseEmbeddedStatement();
				if (!Accept("while"))
				{
					delete s;
					return null;
				}
				s.Expr = ParseParenCondition();
				if (s.Expr == null || !Accept(";"))
				{
					delete s;
					return null;
				}
				s.LastTok = (int32)(mPos - 1);
				return s;
			}

			if (Is("for"))
				return ParseFor();

			if (Is("switch"))
				return ParseSwitch();

			if (Is("return"))
			{
				mPos++;
				Stmt s = new .(.Return);
				s.FirstTok = (int32)start;
				if (!Is(";"))
				{
					s.Expr = ParseExprOrRaw(.Semicolon);
					if (s.Expr == null)
					{
						delete s;
						return null;
					}
				}
				if (!Accept(";"))
				{
					delete s;
					return null;
				}
				s.LastTok = (int32)(mPos - 1);
				return s;
			}

			if ((Is("break") || Is("continue")) && IsAt(mPos + 1, ";"))
			{
				Stmt s = new .(Is("break") ? .Break : .Continue);
				s.FirstTok = (int32)start;
				mPos += 2;
				s.LastTok = (int32)(mPos - 1);
				return s;
			}

			// Labeled statement `Label: { ... }` is kept as raw code
			if (IsIdent(mPos) && IsAt(mPos + 1, ":") && !IsAt(mPos + 2, ":"))
				return null;

			// Lifetime statements (see docs/Lifetime-Nodes.md); null keeps the statement as raw code.
			if (Is("delete"))
				return ParseDelete();
			if (Is("defer"))
				return ParseDefer();
			if (Is("using") && IsAt(mPos + 1, "("))
				return ParseUsing();

			// `const T x = ...;` and `ref T x = ref ...;` locals
			if (Is("const") || Is("ref"))
			{
				String modifier = scope .(Text(mPos));
				mPos++;
				Stmt decl = TryParseLocalVar();
				if (decl != null && (modifier != "const" || decl.Expr != null))
				{
					decl.FirstTok = (int32)start;
					decl.Alloc = new String(modifier);
					return decl;
				}
				delete decl;
				mPos = start;
				return null;
			}

			// `[Attr] statement` / `[ConstSkip] { ... }`: the attributes are kept as text (with the
			// gap after them) in front of a simple statement or a block.
			if (Is("["))
			{
				int save = mPos;
				if (SkipBalanced() && !Is("[") && !Is(";"))
				{
					int stmtStart = mPos;
					Stmt inner = ParseStatement();
					if (inner != null && inner.FirstTok == stmtStart &&
						(inner.Kind == .Expr || inner.Kind == .LocalVar || inner.Kind == .Return || inner.Kind == .Delete || inner.Kind == .Block))
					{
						inner.Attributes = new String(StringView(mText, mTokens[save].Start, mTokens[stmtStart].Start - mTokens[save].Start));
						inner.FirstTok = (int32)save;
						return inner;
					}
					delete inner;
				}
				mPos = save;
				return null;
			}

			// Statements we keep as raw code
			if (Is("using") || Is("defer") || Is("delete") || Is("repeat") || Is("fallthrough") ||
				Is("case") || Is("default") || Is("const") || Is("static") || Is(";") || Is("goto") || Is("throw") || Is("try"))
				return null;

			// Local function `void Foo(int a) { ... }` / `bool Foo(int a) => expr;`
			{
				if (SkipType() && IsIdent(mPos) && IsAt(mPos + 1, "("))
				{
					int typeEnd = mPos - 1;
					int nameTok = mPos;
					mPos++;
					if (SkipBalanced() && (Is("{") || Is("=>") || Is("where")))
					{
						if (Is("where"))
						{
							mPos = start;
							return null;
						}
						Stmt f = new .(.LocalFunc);
						f.FirstTok = (int32)start;
						f.VarType = NewText(start, typeEnd);
						f.VarName = new String(Text(nameTok));
						f.ForHeader = NewText(start, mPos - 1);
						if (Is("{"))
						{
							f.Then = ParseBlock();
							if (f.Then == null)
							{
								delete f;
								mPos = start;
								return null;
							}
						}
						else
						{
							mPos++; // =>
							f.Expr = ParseExprOrRaw(.Semicolon);
							if (f.Expr == null || !Accept(";"))
							{
								delete f;
								mPos = start;
								return null;
							}
						}
						f.LastTok = (int32)(mPos - 1);
						return f;
					}
				}
				mPos = start;
			}

			// Local variable declaration
			{
				Stmt decl = TryParseLocalVar();
				if (decl != null)
					return decl;
				mPos = start;
			}

			// Expression statement
			Expr e = ParseExprOrRaw(.Semicolon);
			if (e == null || !Accept(";"))
			{
				delete e;
				return null;
			}
			Stmt s = new .(.Expr);
			s.FirstTok = (int32)start;
			s.Expr = e;
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		/// After `delete` / `defer`: an optional `::` or `:name` (an allocator or a scope target).
		void SkipScopeSuffix()
		{
			if (Is("::"))
				mPos++;
			else if (Is(":") && Kind(mPos + 1) == .Identifier && Adjacent(mPos, mPos + 1))
				mPos += 2;
		}

		/// The tokens first..last joined without their trivia (`scope::`, `delete:alloc`).
		String JoinTokens(int first, int last)
		{
			String s = new .();
			for (int i = first; i <= last; i++)
				s.Append(Text(i));
			return s;
		}

		/// `delete x;`, `delete:alloc x;`. Null for any other shape (kept as raw code).
		Stmt ParseDelete()
		{
			int start = mPos;
			mPos++;
			SkipScopeSuffix();
			int allocLast = mPos - 1;
			if (AtEnd || Is(";") || Is("}"))
				return null;
			Expr e = ParseExprOrRaw(.Semicolon);
			if (e == null || !Accept(";"))
			{
				delete e;
				return null;
			}
			Stmt s = new .(.Delete);
			s.FirstTok = (int32)start;
			s.Alloc = JoinTokens(start, allocLast);
			s.Expr = e;
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		/// `defer <statement>`, `defer { ... }`, `defer:: ...`, `defer:mixin ...`.
		Stmt ParseDefer()
		{
			int start = mPos;
			mPos++;
			SkipScopeSuffix();
			int allocLast = mPos - 1;
			if (AtEnd || Is(";") || Is("}"))
				return null;
			Stmt body = ParseEmbeddedStatement();
			if (body == null)
				return null;
			Stmt s = new .(.Defer);
			s.FirstTok = (int32)start;
			s.Alloc = JoinTokens(start, allocLast);
			s.Then = body;
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		/// `using (expr) <statement>` and `using (let x = expr) <statement>` (also `var`, a type).
		Stmt ParseUsing()
		{
			int start = mPos;
			mPos += 2; // using (
			Stmt s = new .(.Using);
			s.FirstTok = (int32)start;
			{
				int save = mPos;
				int typeStart = mPos;
				bool ok = false;
				if ((Is("let") || Is("var")) && IsIdent(mPos + 1))
				{
					mPos++;
					ok = true;
				}
				else if (SkipType())
					ok = true;
				int typeEnd = mPos;
				if (ok && IsIdent(mPos) && IsAt(mPos + 1, "="))
				{
					s.VarType = NewText(typeStart, typeEnd - 1);
					s.VarName = new String(Text(mPos));
					mPos += 2;
				}
				else
					mPos = save;
			}
			s.Expr = ParseExprOrRaw(.CloseParen);
			if (s.Expr == null || !Accept(")"))
			{
				delete s;
				return null;
			}
			s.Then = ParseEmbeddedStatement();
			if (s.Then == null)
			{
				delete s;
				return null;
			}
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		void DeclineSwitch(StringView reason)
		{
			delete mSwitchDecline;
			mSwitchDecline = new String(reason);
		}

		/// Labels the switch node cannot show as plain text: guards, bindings, ranges, tuples.
		bool CaseLabelUnsupported(int first, int last, String outReason)
		{
			for (int i = first; i <= last; i++)
			{
				let t = Text(i);
				if (Kind(i) == .String || Kind(i) == .Char)
					continue;
				if (t == "when")
				{
					outReason.Set("switch: a case has a 'when' guard");
					return true;
				}
				if (t == "let" || t == "var" || t == "ref" || t == "is")
				{
					outReason.Set("switch: a case binds a value or tests a type");
					return true;
				}
				if (t == "..." || t == "..<" || t == "<..." || t == "..")
				{
					outReason.Set("switch: a case is a range");
					return true;
				}
				if (t == "(")
				{
					outReason.Set("switch: a case is a tuple, payload or call pattern");
					return true;
				}
			}
			return false;
		}

		/// Fallthrough anywhere in the statement that belongs to the switch being parsed.
		bool HasFallthrough(Stmt s)
		{
			if (s == null)
				return false;
			switch (s.Kind)
			{
			case .Raw:
				if (!s.HasSpan || Text(s.FirstTok) == "switch")
					return false;
				for (int i = s.FirstTok; i <= s.LastTok; i++)
					if (Kind(i) == .Identifier && Text(i) == "fallthrough")
						return true;
				return false;
			case .Block:
				for (let b in s.Body)
					if (HasFallthrough(b))
						return true;
				return false;
			case .Switch:
				return false;
			default:
				return HasFallthrough(s.Then) || HasFallthrough(s.Else);
			}
		}

		/// `switch (x) { case A: ... case B, C: ... default: ... }`. Returns null (and records why)
		/// when a clause cannot be modelled: fallthrough, `when` guards, ranges, tuple / payload
		/// patterns, preprocessor lines. The statement then stays raw code.
		Stmt ParseSwitch()
		{
			int start = mPos;
			mPos++; // switch
			Expr subject = ParseParenCondition();
			if (subject == null || !Is("{"))
			{
				delete subject;
				mPos = start;
				DeclineSwitch("switch: the header is not a simple 'switch (value)'");
				return null;
			}
			Stmt sw = new .(.Switch);
			sw.FirstTok = (int32)start;
			sw.Expr = subject;
			sw.Cases = new .();
			sw.OpenTok = (int32)mPos;
			mPos++;
			String reason = scope .();
			bool hasDefault = false;
			while (!AtEnd && !Is("}"))
			{
				SwitchCase c = new .();
				c.FirstTok = (int32)mPos;
				int colon = -1;
				if (Is("case"))
				{
					mPos++;
					int labelStart = mPos;
					int depth = 0;
					while (!AtEnd)
					{
						if (depth == 0 && (Is(":") || Is("}") || Is(";")))
							break;
						if (IsOpen(mPos))
							depth++;
						else if (IsClose(mPos))
							depth--;
						mPos++;
					}
					if (!Is(":") || mPos == labelStart)
					{
						delete c;
						reason.Set("switch: a case label could not be read");
						break;
					}
					colon = mPos;
					// `case .Ok(let v):` - a payload bound to a name: the Switch shows it as a pin.
					if (colon - labelStart == 6 && IsAt(labelStart, ".") && IsIdent(labelStart + 1) && IsAt(labelStart + 2, "(") &&
						(IsAt(labelStart + 3, "let") || IsAt(labelStart + 3, "var")) && IsIdent(labelStart + 4) && IsAt(labelStart + 5, ")"))
					{
						c.BindCase = new String(Text(labelStart + 1));
						c.BindDecl = new String(Text(labelStart + 3));
						c.BindName = new String(Text(labelStart + 4));
					}
					else if (CaseLabelUnsupported(labelStart, colon - 1, reason))
					{
						delete c;
						break;
					}
					c.Label.Set(mUnit.SpanText(labelStart, colon - 1));
				}
				else if (Is("default") && IsAt(mPos + 1, ":"))
				{
					if (hasDefault)
					{
						delete c;
						reason.Set("switch: two default clauses");
						break;
					}
					hasDefault = true;
					c.IsDefault = true;
					colon = mPos + 1;
				}
				else
				{
					delete c;
					reason.Set("switch: code before the first case");
					break;
				}
				c.ColonTok = (int32)colon;
				mPos = colon + 1;
				while (!AtEnd && !Is("}") && !Is("case") && !(Is("default") && IsAt(mPos + 1, ":")))
				{
					int bstart = mPos;
					Stmt s = ParseStatement();
					if (s == null)
					{
						mPos = bstart;
						s = ParseRawStatement();
					}
					c.Body.Add(CheckDirectives(s));
					if (mPos == bstart)
						mPos++;
				}
				c.LastTok = (int32)(mPos - 1);
				sw.Cases.Add(c);
				for (let b in c.Body)
					if (HasFallthrough(b))
						reason.Set("switch: uses fallthrough");
				if (!reason.IsEmpty)
					break;
			}
			if (reason.IsEmpty && !Is("}"))
				reason.Set("switch: the closing brace is missing");
			if (!reason.IsEmpty)
			{
				delete sw;
				mPos = start;
				DeclineSwitch(reason);
				return null;
			}
			sw.CloseTok = (int32)mPos;
			sw.LastTok = (int32)mPos;
			mPos++;
			return sw;
		}

		Stmt TryParseLocalVar()
		{
			int start = mPos;
			int typeStart = mPos;
			int typeEnd;
			if ((Is("let") || Is("var")) && IsIdent(mPos + 1))
			{
				mPos++;
				typeEnd = mPos;
			}
			else
			{
				if (!SkipType())
					return null;
				typeEnd = mPos;
			}
			if (!IsIdent(mPos))
			{
				mPos = start;
				return null;
			}
			int nameTok = mPos;
			mPos++;
			if (!Is("=") && !Is(";"))
			{
				mPos = start;
				return null;
			}
			Stmt s = new .(.LocalVar);
			s.FirstTok = (int32)start;
			s.VarType = NewText(typeStart, typeEnd - 1);
			s.VarName = new String(Text(nameTok));
			if (Accept("="))
			{
				s.Expr = ParseExprOrRaw(.Semicolon);
				if (s.Expr == null)
				{
					delete s;
					mPos = start;
					return null;
				}
			}
			if (!Accept(";"))
			{
				delete s;
				mPos = start;
				return null;
			}
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		/// Whether `e` can be the right-hand side of `i < e` without a parenthesis: it binds tighter
		/// than `<`. `i < 10000 && !done` is not a count (the `&&` is the loop's own condition), and
		/// neither is `i < a == b`, `i < a ? b : c` or `i < x = y`; those headers stay text.
		static bool BindsTighterThanLess(Expr e)
		{
			switch (e.Kind)
			{
			case .Assign, .Conditional:
				return false;
			case .Binary:
				switch (e.Op)
				{
				case "+", "-", "*", "/", "%", "<<", ">>":
					return true;
				default:
					return false;
				}
			default:
				return true;
			}
		}

		/// A counting loop header: `T i = start; i < count; i++` or Beef's `T i < count`. Fills
		/// VarType, VarName, Expr (the start, null for the short form) and Expr2 (the count);
		/// any other header leaves them null (the header stays text).
		void ParseCountedHeader(Stmt s, int open, int close)
		{
			mPos = open + 1;
			int typeStart = mPos;
			if (Is("var"))
				mPos++;
			else if (!SkipType())
				return;
			int typeEnd = mPos;
			if (typeEnd == typeStart || !IsIdent(mPos))
				return;
			int nameTok = mPos;
			let name = Text(nameTok);
			mPos++;
			Expr start = null;
			if (Is("="))
			{
				mPos++;
				start = ParseExpr();
				if (start == null || start.Kind == .Raw || !Is(";") || !IsAt(mPos + 1, name) || !IsAt(mPos + 2, "<"))
				{
					delete start;
					return;
				}
				mPos += 3;
			}
			else if (Is("<"))
				mPos++;
			else
				return;
			Expr count = ParseExpr();
			bool ok = count != null && count.Kind != .Raw && BindsTighterThanLess(count);
			if (ok && start != null)
				ok = Is(";") && IsAt(mPos + 1, name) && IsAt(mPos + 2, "++") && mPos + 3 == close;
			else if (ok)
				ok = mPos == close;
			if (!ok)
			{
				delete start;
				delete count;
				return;
			}
			s.VarType = NewText(typeStart, typeEnd - 1);
			s.VarName = new String(name);
			s.Expr = start;
			s.Expr2 = count;
		}

		Stmt ParseFor()
		{
			int start = mPos;
			mPos++; // for
			if (!Is("("))
				return null;
			int open = mPos;

			// foreach: for (let x in coll) / for (var x in coll) / for (Type x in coll)
			{
				mPos = open + 1;
				int typeStart = mPos;
				bool ok = false;
				int typeEnd = 0;
				if ((Is("let") || Is("var")) && IsIdent(mPos + 1))
				{
					mPos++;
					typeEnd = mPos;
					ok = true;
				}
				else if (SkipType())
				{
					typeEnd = mPos;
					ok = true;
				}
				if (ok && IsIdent(mPos) && IsAt(mPos + 1, "in"))
				{
					int nameTok = mPos;
					mPos += 2;
					Expr coll = ParseExprOrRaw(.CloseParen);
					if (coll != null && Accept(")"))
					{
						Stmt s = new .(.ForEach);
						s.FirstTok = (int32)start;
						s.VarType = NewText(typeStart, typeEnd - 1);
						s.VarName = new String(Text(nameTok));
						s.Expr = coll;
						s.Then = ParseEmbeddedStatement();
						s.LastTok = (int32)(mPos - 1);
						return s;
					}
					delete coll;
				}
			}

			// C-style or Beef shorthand `for (int i < count)`; header kept as text.
			mPos = open;
			if (!SkipBalanced())
				return null;
			int close = mPos - 1;
			Stmt s = new .(.For);
			s.FirstTok = (int32)start;
			s.ForHeader = (close > open + 1) ? NewText(open + 1, close - 1) : new String();
			ParseCountedHeader(s, open, close);
			mPos = close + 1;
			s.Then = ParseEmbeddedStatement();
			s.LastTok = (int32)(mPos - 1);
			return s;
		}

		// ------------------------------------------------------------------ expressions

		enum Terminator
		{
			Semicolon,   // statement level
			CloseParen,  // inside ( )
			ArgList,     // , or )
			IndexList    // , or ]
		}

		bool IsTerminator(Terminator term)
		{
			switch (term)
			{
			case .Semicolon: return Is(";");
			case .CloseParen: return Is(")");
			case .ArgList: return Is(",") || Is(")");
			case .IndexList: return Is(",") || Is("]");
			}
		}

		/// Parses a structured expression; if that fails or does not end at the terminator,
		/// falls back to a Raw expression spanning up to the terminator.
		Expr ParseExprOrRaw(Terminator term)
		{
			int start = mPos;
			Expr e = ParseExpr();
			if (e != null && IsTerminator(term))
				return e;
			delete e;
			mPos = start;
			return ParseRawExpr(term);
		}

		Expr ParseRawExpr(Terminator term)
		{
			int start = mPos;
			int depth = 0;
			while (!AtEnd)
			{
				if (depth == 0)
				{
					if (IsTerminator(term))
						break;
					if (Is(";") || Is("}") || Is(")") || Is("]"))
						break; // unbalanced: give up here
				}
				if (IsOpen(mPos))
					depth++;
				else if (IsClose(mPos))
				{
					depth--;
					// A `{ }` block ending at depth 0 inside a statement-level expression means we've
					// run into statement syntax; stop so the statement is handled as raw code.
					if (depth == 0 && term == .Semicolon && Is("}"))
					{
						mPos++;
						if (!Is(";") && !Is(")") && !Is(",") && !Is("."))
							break;
						continue;
					}
				}
				mPos++;
			}
			if (mPos == start)
				return null;
			Expr e = new .(.Raw);
			e.FirstTok = (int32)start;
			e.LastTok = (int32)(mPos - 1);
			return e;
		}

		Expr ParseExpr()
		{
			return ParseAssign();
		}

		static bool IsAssignOp(StringView s)
		{
			return s == "=" || s == "+=" || s == "-=" || s == "*=" || s == "/=" || s == "%=" || s == "&=" || s == "|=" ||
				s == "^=" || s == "<<=" || s == "??=" || s == "&+=" || s == "&-=" || s == "&*=";
		}

		Expr ParseAssign()
		{
			int start = mPos;
			Expr lhs = ParseConditional();
			if (lhs == null)
				return null;
			String op = scope .();
			int opToks = 0;
			if (Kind(mPos) == .Symbol && IsAssignOp(Text(mPos)))
			{
				op.Set(Text(mPos));
				opToks = 1;
			}
			else if (Is(">") && IsAt(mPos + 1, ">=") && Adjacent(mPos, mPos + 1))
			{
				op.Set(">>=");
				opToks = 2;
			}
			if (opToks > 0)
			{
				mPos += opToks;
				Expr rhs = ParseAssign();
				if (rhs == null)
				{
					delete lhs;
					return null;
				}
				Expr e = new .(.Assign);
				e.Op.Set(op);
				e.A = lhs;
				e.B = rhs;
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			return lhs;
		}

		Expr ParseConditional()
		{
			int start = mPos;
			Expr c = ParseBinary(1);
			if (c == null)
				return null;
			if (Is("?"))
			{
				mPos++;
				Expr a = ParseAssign();
				if (a == null || !Accept(":"))
				{
					delete a;
					delete c;
					return null;
				}
				Expr b = ParseAssign();
				if (b == null)
				{
					delete a;
					delete c;
					return null;
				}
				Expr e = new .(.Conditional);
				e.A = c;
				e.B = a;
				e.C = b;
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			return c;
		}

		/// Binary operator precedence; higher binds tighter. 0 = not a binary operator.
		/// This mirrors the Beef compiler (BfGetBinaryOpPrecendence), which differs from C#:
		/// bitwise operators bind tighter than comparisons, so `a & b != 0` is `(a & b) != 0`.
		public static int BinaryPrecedence(StringView op)
		{
			switch (op)
			{
			case "??": return 1;
			case "||": return 2;
			case "&&": return 3;
			case "==", "!=", "===", "!==": return 4;
			case "<", ">", "<=", ">=": return 5;
			case "<=>": return 6;
			case "is", "as", "case": return 7;
			case "..<", "...": return 8;
			case "|": return 9;
			case "^": return 10;
			case "&": return 11;
			case "<<", ">>": return 12;
			case "+", "-", "&+", "&-": return 13;
			case "*", "/", "%", "&*": return 14;
			default: return 0;
			}
		}

		/// Precedence of prefix unary operators and casts, and of postfix operators / member access.
		public const int UnaryPrecedence = 15;
		public const int PostfixPrecedence = 16;

		/// Returns the binary operator at mPos (and how many tokens it uses), or 0 precedence.
		int PeekBinaryOp(String outOp, out int tokCount)
		{
			tokCount = 1;
			let kind = Kind(mPos);
			if (kind == .Identifier)
			{
				if (Is("is") || Is("as"))
				{
					outOp.Set(Text(mPos));
					return 7;
				}
				// `x case .Ok(let v)`: a pattern test (see docs/Lifetime-Nodes.md).
				if (Is("case"))
				{
					outOp.Set("case");
					return 7;
				}
				return 0;
			}
			if (kind != .Symbol)
				return 0;
			if (Is(">") && IsAt(mPos + 1, ">") && Adjacent(mPos, mPos + 1))
			{
				if (IsAt(mPos + 2, "=") || IsAt(mPos + 2, ">=") )
					return 0;
				outOp.Set(">>");
				tokCount = 2;
				return 12;
			}
			// `x >>= n` lexes as `>` `>=`: an assignment (ParseAssign), not a comparison.
			if (Is(">") && IsAt(mPos + 1, ">=") && Adjacent(mPos, mPos + 1))
				return 0;
			let text = Text(mPos);
			int prec = BinaryPrecedence(text);
			if (prec > 0)
				outOp.Set(text);
			return prec;
		}

		Expr ParseBinary(int minPrec)
		{
			int start = mPos;
			Expr left = ParseUnary();
			if (left == null)
				return null;
			while (true)
			{
				String op = scope .();
				int tokCount;
				int prec = PeekBinaryOp(op, out tokCount);
				if (prec == 0 || prec < minPrec)
					break;
				mPos += tokCount;
				Expr right;
				if (op == "is" || op == "as")
				{
					int typeStart = mPos;
					if (!SkipType())
					{
						delete left;
						return null;
					}
					right = new .(.Name);
					right.FirstTok = (int32)typeStart;
					right.LastTok = (int32)(mPos - 1);
					right.Op.Set(mUnit.SpanText(typeStart, mPos - 1));
				}
				else if (op == "case")
				{
					// Only `<postfix expression> case <pattern>`; anything else stays raw text, so
					// the structured form never guesses how Beef groups it.
					int patStart = mPos;
					if (!IsPatternOperand(left) || !SkipPattern())
					{
						delete left;
						return null;
					}
					right = new .(.Name);
					right.FirstTok = (int32)patStart;
					right.LastTok = (int32)(mPos - 1);
					right.Op.Set(mUnit.SpanText(patStart, mPos - 1));
				}
				else
				{
					// '??' is right-associative; everything else left-associative
					right = ParseBinary((op == "??") ? prec : prec + 1);
				}
				if (right == null)
				{
					delete left;
					return null;
				}
				Expr e = new .(.Binary);
				e.Op.Set(op);
				e.A = left;
				e.B = right;
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				left = e;
			}
			return left;
		}

		static bool IsPatternOperand(Expr e)
		{
			switch (e.Kind)
			{
			case .Name, .Member, .Call, .Index, .Paren, .Literal: return true;
			default: return false;
			}
		}

		/// A `case` pattern: `.Ok`, `.Ok(let v)`, `.Err(var e)`, `Result<int>.Ok(?)`, ... (an enum
		/// case, optionally qualified, with an optional balanced payload list).
		bool SkipPattern()
		{
			int start = mPos;
			if (Is(".") && Kind(mPos + 1) == .Identifier)
				mPos += 2;
			else if (!SkipType() || mUnit.SpanText(start, mPos - 1).IndexOf('.') < 0)
			{
				mPos = start;
				return false;
			}
			if (Is("("))
			{
				if (!SkipBalanced())
				{
					mPos = start;
					return false;
				}
			}
			return true;
		}

		/// True if the token at idx can begin an operand (used to recognize casts).
		bool CanStartOperand(int idx)
		{
			let kind = Kind(idx);
			if (kind == .Number || kind == .String || kind == .Char)
				return true;
			if (kind == .Identifier)
			{
				let t = Text(idx);
				return !(t == "is" || t == "as" || t == "in");
			}
			let t = Text(idx);
			// `=>`: a cast of a method reference, `(function void())=> OnTick`.
			return t == "(" || t == "!" || t == "~" || t == "." || t == "=>";
		}

		Expr ParseUnary()
		{
			int start = mPos;
			if (Kind(mPos) == .Symbol)
			{
				let t = Text(mPos);
				if (t == "-" || t == "+" || t == "!" || t == "~" || t == "++" || t == "--" || t == "&" || t == "*")
				{
					String op = scope .(t);
					mPos++;
					Expr operand = ParseUnary();
					if (operand == null)
						return null;
					Expr e = new .(.Unary);
					e.Op.Set(op);
					e.A = operand;
					e.FirstTok = (int32)start;
					e.LastTok = (int32)(mPos - 1);
					return e;
				}
				if (t == "(" && IsAt(mPos + 1, ".") && IsAt(mPos + 2, ")") && Kind(mPos + 3) != .EOF && !IsAt(mPos + 3, ")") &&
					!IsAt(mPos + 3, ";") && !IsAt(mPos + 3, ",") && !IsAt(mPos + 3, "]") && !IsAt(mPos + 3, "}"))
				{
					// `(.)x`: a cast to the type the value goes to (nothing else can follow `(.)`).
					mPos += 3;
					Expr operand = ParseUnary();
					if (operand == null)
						return null;
					Expr e = new .(.Cast);
					e.TypeText = new String(".");
					e.A = operand;
					e.FirstTok = (int32)start;
					e.LastTok = (int32)(mPos - 1);
					return e;
				}
				if (t == "(")
				{
					// Cast?
					int save = mPos;
					mPos++;
					int typeStart = mPos;
					bool isType = SkipType() && Is(")");
					// `(T)*p`, `(T)-x`, `(T)&x` read as casts to the Beef compiler when T is a type and
					// as arithmetic when it's a value; we can't tell, so keep the expression as text.
					if (isType && (IsAt(mPos + 1, "*") || IsAt(mPos + 1, "-") || IsAt(mPos + 1, "&") || IsAt(mPos + 1, "+")) &&
						Adjacent(mPos + 1, mPos + 2))
						return null;
					if (isType && CanStartOperand(mPos + 1))
					{
						int typeEnd = mPos;
						mPos++;
						Expr operand = ParseUnary();
						if (operand != null)
						{
							Expr e = new .(.Cast);
							e.TypeText = NewText(typeStart, typeEnd - 1);
							e.A = operand;
							e.FirstTok = (int32)start;
							e.LastTok = (int32)(mPos - 1);
							return e;
						}
					}
					mPos = save;
				}
			}
			else if (Kind(mPos) == .Identifier)
			{
				let t = Text(mPos);
				if ((t == "ref" || t == "out" || t == "mut" || t == "in") && !IsAt(mPos + 1, "let") && !IsAt(mPos + 1, "var"))
				{
					String op = scope .(t);
					mPos++;
					Expr operand = ParseUnary();
					if (operand == null)
						return null;
					Expr e = new .(.Unary);
					e.Op.Set(op);
					e.A = operand;
					e.FirstTok = (int32)start;
					e.LastTok = (int32)(mPos - 1);
					return e;
				}
			}
			return ParsePostfix();
		}

		Expr ParsePostfix()
		{
			int start = mPos;
			Expr e = ParsePrimary();
			if (e == null)
				return null;
			if (e.Kind == .Lambda)
				return e; // the body took everything that belongs to it
			while (true)
			{
				if ((Is(".") || Is("?.") || Is("..")) && (Kind(mPos + 1) == .Identifier || Kind(mPos + 1) == .Number))
				{
					bool nullCond = Is("?.");
					bool cascade = Is("..");
					mPos++;
					Expr m = new .(.Member);
					m.A = e;
					m.NullCond = nullCond;
					m.Cascade = cascade;
					m.Op.Set(Text(mPos));
					mPos++;
					// generic member `a.Foo<T>(...)`
					if (Is("<"))
					{
						int save = mPos;
						if (SkipGenericArgs() && (Is("(") || Is(".")))
							m.Op.Append(mUnit.SpanText(save, mPos - 1));
						else
							mPos = save;
					}
					if (Is("!") && IsAt(mPos + 1, "(") && Adjacent(mPos - 1, mPos))
					{
						m.Op.Append("!");
						mPos++;
					}
					m.FirstTok = (int32)start;
					m.LastTok = (int32)(mPos - 1);
					e = m;
					continue;
				}
				if (Is("("))
				{
					Expr call = new .(.Call);
					call.A = e;
					call.Args = new .();
					mPos++;
					if (!ParseArgs(call.Args, .ArgList, ")"))
					{
						delete call;
						return null;
					}
					call.FirstTok = (int32)start;
					call.LastTok = (int32)(mPos - 1);
					e = call;
					continue;
				}
				if (Is("["))
				{
					Expr idx = new .(.Index);
					idx.A = e;
					idx.Args = new .();
					mPos++;
					if (!ParseArgs(idx.Args, .IndexList, "]"))
					{
						delete idx;
						return null;
					}
					idx.FirstTok = (int32)start;
					idx.LastTok = (int32)(mPos - 1);
					e = idx;
					continue;
				}
				if (Is("++") || Is("--"))
				{
					Expr u = new .(.Unary);
					u.Op.Set(Text(mPos));
					u.Postfix = true;
					u.A = e;
					mPos++;
					u.FirstTok = (int32)start;
					u.LastTok = (int32)(mPos - 1);
					e = u;
					continue;
				}
				break;
			}
			return e;
		}

		/// mPos just after the opener. Consumes through the closer.
		bool ParseArgs(List<Expr> args, Terminator term, StringView closer)
		{
			if (Accept(closer))
				return true;
			while (true)
			{
				Expr arg = ParseExprOrRaw(term);
				if (arg == null)
					return false;
				args.Add(arg);
				if (Accept(","))
					continue;
				if (Accept(closer))
					return true;
				return false;
			}
		}

		Expr ParsePrimary()
		{
			int start = mPos;
			let kind = Kind(mPos);
			if (kind == .Number || kind == .String || kind == .Char)
			{
				Expr e = new .(.Literal);
				e.Op.Set(Text(mPos));
				e.LitKind = Literals.Classify(kind, Text(mPos));
				e.FirstTok = e.LastTok = (int32)mPos;
				mPos++;
				return e;
			}
			if (kind == .Identifier)
			{
				let t = Text(mPos);
				if (t == "true" || t == "false" || t == "null" || t == "this" || t == "base" || (t == "default" && !IsAt(mPos + 1, "(")))
				{
					Expr e = new .(.Literal);
					e.Op.Set(t);
					e.LitKind = Literals.Classify(.Identifier, t);
					e.FirstTok = e.LastTok = (int32)mPos;
					mPos++;
					return e;
				}
				if ((t == "typeof" || t == "sizeof" || t == "alignof" || t == "strideof" || t == "nameof" || t == "default" ||
					t == "decltype" || t == "offsetof" || t == "comptype") && IsAt(mPos + 1, "("))
				{
					mPos++;
					SkipBalanced();
					Expr e = new .(.Raw);
					e.FirstTok = (int32)start;
					e.LastTok = (int32)(mPos - 1);
					return e;
				}
				if (t == "new" || t == "scope" || t == "append")
					return ParseNewExpr();
				if (IsReserved(t))
					return null;
				// Lambda `x => ...`
				if (IsAt(mPos + 1, "=>"))
					return TryParseLambda(start, start - 1);

				Expr e = new .(.Name);
				e.Op.Set(t);
				mPos++;
				// Generic name `Foo<T>(...)` / `Foo<T>.Bar`
				if (Is("<"))
				{
					int save = mPos;
					if (SkipGenericArgs() && (Is("(") || Is(".") || Is("::")))
						e.Op.Append(mUnit.SpanText(save, mPos - 1));
					else
						mPos = save;
				}
				// Mixin invocation `Foo!(...)`
				if (Is("!") && IsAt(mPos + 1, "(") && Adjacent(mPos - 1, mPos))
				{
					e.Op.Append("!");
					mPos++;
				}
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			if (Is("=>"))
				return TryParseLambda(start, start - 1); // `=> Method`
			if (Is("("))
			{
				// Lambda `(a, b) => ...`
				int save = mPos;
				SkipBalanced();
				if (Is("=>"))
				{
					mPos = save;
					return TryParseLambda(start, start - 1);
				}
				mPos = save + 1;
				Expr inner = ParseExpr();
				if (inner == null || !Accept(")"))
				{
					delete inner;
					return null;
				}
				Expr e = new .(.Paren);
				e.A = inner;
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			if (Is(".") && IsAt(mPos + 1, "("))
			{
				// `.(args)`: a value of the type it goes to, made in place (no allocation).
				mPos += 2;
				Expr e = new .(.New);
				e.Args = new .();
				e.TypeText = new String(".");
				e.FirstTok = (int32)start;
				if (!ParseArgs(e.Args, .ArgList, ")") || Is("{"))
				{
					// Initialiser blocks `.() { x = 1 }` stay text.
					delete e;
					return null;
				}
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			if (Is(".") && Kind(mPos + 1) == .Identifier)
			{
				// Implicit member `.EnumCase`
				Expr e = new .(.Literal);
				e.LitKind = .EnumCase;
				e.Op.Append(".");
				e.Op.Append(Text(mPos + 1));
				mPos += 2;
				e.FirstTok = (int32)start;
				e.LastTok = (int32)(mPos - 1);
				return e;
			}
			return null;
		}

		/// `new T(args)`, `scope .(args)`, `new:alloc T[n]`... as an ExprKind.New; anything else
		/// (initialiser blocks, `new [Friend]`, `new T[] (...)`) as before.
		Expr ParseNewExpr()
		{
			int start = mPos;
			let structured = TryParseNew();
			if (structured != null)
				return structured;
			mPos = start;
			return ParseNewExprRaw();
		}

		/// At a lambda's capture list, parameter list, single parameter or `=>` (after the
		/// allocation `allocFirst..allocLast`, if any): a Lambda expression, or null (the caller
		/// keeps the expression as text).
		Expr TryParseLambda(int allocFirst, int allocLast)
		{
			int start = mPos;
			Expr e = new .(.Lambda);
			e.FirstTok = (int32)((allocLast >= allocFirst) ? allocFirst : start);
			for (int i = allocFirst; i <= allocLast; i++)
				e.Op.Append(Text(i));
			if (Is("["))
			{
				int capStart = mPos;
				if (!SkipBalanced())
				{
					delete e;
					return null;
				}
				e.Captures = JoinTokens(capStart, mPos - 1);
			}
			if (Is("("))
			{
				int open = mPos;
				if (!SkipBalanced() || !Is("=>"))
				{
					delete e;
					return null;
				}
				e.Params = (mPos - 2 >= open + 1) ? NewText(open + 1, mPos - 2) : new String();
				e.ParamParens = true;
			}
			else if (IsIdent(mPos) && IsAt(mPos + 1, "=>"))
			{
				e.Params = new String(Text(mPos));
				mPos++;
			}
			if (!Accept("=>"))
			{
				delete e;
				return null;
			}
			if (e.Params == null)
			{
				// `=> Method` / `=> obj.Method`: a delegate bound to a method.
				Expr target = ParsePostfix();
				var root = target;
				while (root != null && root.Kind == .Member && !root.NullCond && !root.Cascade)
					root = root.A;
				if (target == null || root == null || !(root.Kind == .Name || (root.Kind == .Literal && (root.Op == "this" || root.Op == "base"))))
				{
					delete target;
					delete e;
					return null;
				}
				e.A = target;
			}
			else if (Is("{"))
			{
				e.Body = ParseBlock();
				if (e.Body == null)
				{
					delete e;
					return null;
				}
			}
			else
			{
				e.A = ParseAssign();
				if (e.A == null)
				{
					delete e;
					return null;
				}
			}
			e.LastTok = (int32)(mPos - 1);
			return e;
		}

		/// After `new` / `scope` (and a scope suffix): a lambda follows.
		bool LambdaAhead()
		{
			if (Is("=>") || Is("["))
				return true;
			if (IsIdent(mPos) && IsAt(mPos + 1, "=>"))
				return true;
			if (Is("("))
			{
				int save = mPos;
				bool ok = SkipBalanced() && Is("=>");
				mPos = save;
				return ok;
			}
			return false;
		}

		Expr TryParseNew()
		{
			int start = mPos;
			mPos++; // new / scope / append
			SkipScopeSuffix();
			int allocLast = mPos - 1;
			if (LambdaAhead())
				return TryParseLambda(start, allocLast);
			Expr e = new .(.New);
			e.Args = new .();
			e.FirstTok = (int32)start;
			if (Kind(mPos) == .String && (Text(mPos).StartsWith('$') || Text(mPos).StartsWith("@$")))
			{
				// `scope $"x = {x}"`: a String made from an interpolated string (TypeText `$`).
				e.TypeText = new String("$");
				Expr lit = new .(.Literal);
				lit.Op.Set(Text(mPos));
				lit.LitKind = Literals.Classify(.String, Text(mPos));
				lit.FirstTok = lit.LastTok = (int32)mPos;
				e.Args.Add(lit);
				mPos++;
			}
			else if (Is(".") && IsAt(mPos + 1, "("))
			{
				// `scope .()`: the type comes from where the value goes.
				e.TypeText = new String(".");
				mPos += 2;
				if (!ParseArgs(e.Args, .ArgList, ")"))
				{
					delete e;
					return null;
				}
			}
			else
			{
				if (!IsIdent(mPos))
				{
					delete e;
					return null;
				}
				int typeStart = mPos;
				if (!SkipType())
				{
					delete e;
					return null;
				}
				int typeEnd = mPos;
				let typeText = mUnit.SpanText(typeStart, typeEnd - 1);
				if (Is("(") && !typeText.EndsWith(']'))
				{
					e.TypeText = NewText(typeStart, typeEnd - 1);
					mPos++;
					if (!ParseArgs(e.Args, .ArgList, ")"))
					{
						delete e;
						return null;
					}
				}
				else if (!Is("(") && typeText.EndsWith(']'))
				{
					// `T[n]`: the last bracket pair holds the sizes.
					int open = -1;
					int depth = 0;
					for (int i = typeEnd - 1; i > typeStart; i--)
					{
						if (Text(i) == "]")
							depth++;
						else if (Text(i) == "[")
						{
							depth--;
							if (depth == 0)
							{
								open = i;
								break;
							}
						}
					}
					if (open < 0 || open == typeEnd - 2)
					{
						delete e;
						return null;
					}
					e.TypeText = NewText(typeStart, open - 1);
					e.IsArray = true;
					mPos = open + 1;
					if (!ParseArgs(e.Args, .IndexList, "]") || mPos != typeEnd)
					{
						delete e;
						return null;
					}
				}
				else
				{
					delete e;
					return null;
				}
			}
			if (Is("{") || Is("("))
			{
				// Initialiser blocks and the like: kept as text.
				delete e;
				return null;
			}
			for (int i = start; i <= allocLast; i++)
				e.Op.Append(Text(i));
			e.LastTok = (int32)(mPos - 1);
			return e;
		}

		Expr ParseNewExprRaw()
		{
			int start = mPos;
			mPos++; // new / scope / append
			if (Is("::"))
				mPos++;
			else if (Is(":") && Kind(mPos + 1) == .Identifier)
				mPos += 2;
			if (Is("."))
				mPos++;
			else if (!SkipType())
			{
				// `new [Friend] ...` and other exotic forms
				return null;
			}
			if (Is("("))
				SkipBalanced();
			if (Is("{"))
				SkipBalanced();
			Expr e = new .(.Raw);
			e.FirstTok = (int32)start;
			e.LastTok = (int32)(mPos - 1);
			return e;
		}
	}
}
