using System;
using System.Collections;

namespace VisualBeef.Syntax
{
	/// Lossless Beef tokenizer. Comments, whitespace and preprocessor lines are kept as trivia
	/// attached to tokens (see Token), so the original text can always be reconstructed.
	class Lexer
	{
		// Multi-character symbols, longest first. '>>' and '>>=' are deliberately absent so that
		// nested generic closers ("List<List<int>>") lex as separate '>' tokens; the parser
		// re-joins adjacent '>' tokens when it needs a shift operator.
		static String[?] sSymbols = .(
			"...", "..<", "<=>", "<<=", "??=", "===", "!==", "&+=", "&-=", "&*=", "&+", "&-", "&*",
			"->", "=>", "==", "!=", "<=", ">=", "&&", "||", "++", "--",
			"+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<", "::", "?.", "??", ".."
		);

		StringView mText;
		int mPos;
		List<Token> mTokens;

		public static void Tokenize(StringView text, List<Token> outTokens)
		{
			Lexer lexer = scope .();
			lexer.mText = text;
			lexer.mTokens = outTokens;
			lexer.Run();
		}

		char8 Peek(int offset = 0)
		{
			int p = mPos + offset;
			if (p < 0 || p >= mText.Length)
				return '\0';
			return mText[p];
		}

		bool AtLineStart(int pos)
		{
			int p = pos - 1;
			while (p >= 0)
			{
				char8 c = mText[p];
				if (c == '\n')
					return true;
				if (c != ' ' && c != '\t')
					return false;
				p--;
			}
			return true;
		}

		void SkipToLineEnd()
		{
			while (mPos < mText.Length && mText[mPos] != '\n')
				mPos++;
		}

		void SkipLeadingTrivia()
		{
			while (mPos < mText.Length)
			{
				char8 c = mText[mPos];
				if (CharUtil.IsSpace(c))
				{
					mPos++;
					continue;
				}
				if (c == '/' && Peek(1) == '/')
				{
					SkipToLineEnd();
					continue;
				}
				if (c == '/' && Peek(1) == '*')
				{
					// Beef block comments nest: /* a /* b */ c */
					mPos += 2;
					int depth = 1;
					while (mPos < mText.Length && depth > 0)
					{
						if (mText[mPos] == '*' && Peek(1) == '/')
						{
							depth--;
							mPos += 2;
						}
						else if (mText[mPos] == '/' && Peek(1) == '*')
						{
							depth++;
							mPos += 2;
						}
						else
							mPos++;
					}
					mPos = Math.Min(mPos, mText.Length);
					continue;
				}
				if (c == '#' && AtLineStart(mPos))
				{
					SkipToLineEnd();
					continue;
				}
				break;
			}
		}

		void SkipTrailingTrivia()
		{
			while (mPos < mText.Length)
			{
				char8 c = mText[mPos];
				if (c == ' ' || c == '\t' || c == '\r')
				{
					mPos++;
					continue;
				}
				if (c == '/' && Peek(1) == '/')
				{
					SkipToLineEnd();
					continue;
				}
				if (c == '\n')
				{
					mPos++;
					return;
				}
				return;
			}
		}

		void Run()
		{
			TokenKind prevKind = .EOF;
			char8 prevChar = '\0';
			while (true)
			{
				int leadStart = mPos;
				SkipLeadingTrivia();
				if (mPos >= mText.Length)
				{
					Token eof = .();
					eof.Kind = .EOF;
					eof.LeadStart = (int32)leadStart;
					eof.Start = (int32)mPos;
					eof.End = (int32)mPos;
					eof.TrailEnd = (int32)mPos;
					mTokens.Add(eof);
					return;
				}

				int start = mPos;
				TokenKind kind = LexToken(prevKind, prevChar);
				if (mPos > mText.Length)
					mPos = mText.Length;
				int end = mPos;
				if (end == start)
				{
					// Should never happen, but never loop forever.
					mPos++;
					end = mPos;
				}
				SkipTrailingTrivia();

				Token tok = .();
				tok.Kind = kind;
				tok.LeadStart = (int32)leadStart;
				tok.Start = (int32)start;
				tok.End = (int32)end;
				tok.TrailEnd = (int32)mPos;
				mTokens.Add(tok);
				prevKind = kind;
				prevChar = mText[end - 1];
			}
		}

		TokenKind LexToken(TokenKind prevKind, char8 prevChar)
		{
			char8 c = mText[mPos];

			// String forms: "..." @"..." $"..." $@"..." @$"..." """..."""
			{
				int p = mPos;
				bool verbatim = false;
				bool interp = false;
				while (p < mText.Length && (mText[p] == '@' || mText[p] == '$'))
				{
					if (mText[p] == '@') verbatim = true;
					else interp = true;
					p++;
				}
				if (p < mText.Length && mText[p] == '"' && (p - mPos) <= 2)
				{
					mPos = p;
					LexString(verbatim, interp);
					return .String;
				}
			}

			if (c == '@' && CharUtil.IsIdentStart(Peek(1)))
			{
				mPos++;
				while (mPos < mText.Length && CharUtil.IsIdentChar(mText[mPos]))
					mPos++;
				return .Identifier;
			}

			if (CharUtil.IsIdentStart(c))
			{
				while (mPos < mText.Length && CharUtil.IsIdentChar(mText[mPos]))
					mPos++;
				return .Identifier;
			}

			if (CharUtil.IsDigit(c))
			{
				LexNumber();
				return .Number;
			}

			// ".5" style number, but not tuple member access like "t.0"
			if (c == '.' && CharUtil.IsDigit(Peek(1)) &&
				!(prevKind == .Identifier || prevChar == ')' || prevChar == ']'))
			{
				LexNumber();
				return .Number;
			}

			if (c == '\'')
			{
				LexChar();
				return .Char;
			}

			for (let sym in sSymbols)
			{
				if (mPos + sym.Length <= mText.Length && mText.Substring(mPos, sym.Length) == sym)
				{
					mPos += sym.Length;
					return .Symbol;
				}
			}
			mPos++;
			return .Symbol;
		}

		void LexNumber()
		{
			if (mText[mPos] == '0' && (Peek(1) == 'x' || Peek(1) == 'X' || Peek(1) == 'b' || Peek(1) == 'B'))
			{
				mPos += 2;
				while (mPos < mText.Length && (CharUtil.IsIdentChar(mText[mPos]) || (mText[mPos] == '\'' && CharUtil.IsIdentChar(Peek(1)))))
					mPos++;
				return;
			}
			while (mPos < mText.Length)
			{
				char8 c = mText[mPos];
				if (CharUtil.IsDigit(c) || c == '_')
				{
					mPos++;
					continue;
				}
				if (c == '\'' && CharUtil.IsDigit(Peek(1)))
				{
					mPos++;
					continue;
				}
				if (c == '.' && CharUtil.IsDigit(Peek(1)))
				{
					mPos++;
					continue;
				}
				if ((c == 'e' || c == 'E') && (CharUtil.IsDigit(Peek(1)) || ((Peek(1) == '+' || Peek(1) == '-') && CharUtil.IsDigit(Peek(2)))))
				{
					mPos += 2;
					continue;
				}
				break;
			}
			// Suffix (u, l, ul, f, d, ...)
			while (mPos < mText.Length && CharUtil.IsIdentChar(mText[mPos]))
				mPos++;
		}

		void LexChar()
		{
			mPos++; // opening '
			while (mPos < mText.Length)
			{
				char8 c = mText[mPos];
				if (c == '\\')
				{
					mPos += 2;
					continue;
				}
				if (c == '\'')
				{
					mPos++;
					return;
				}
				if (c == '\n')
					return;
				mPos++;
			}
		}

		/// mPos is at the opening quote.
		void LexString(bool verbatim, bool interp)
		{
			if (Peek(0) == '"' && Peek(1) == '"' && Peek(2) == '"')
			{
				mPos += 3;
				while (mPos < mText.Length)
				{
					if (mText[mPos] == '"' && Peek(1) == '"' && Peek(2) == '"')
					{
						mPos += 3;
						// A raw string may end with more than three quotes.
						while (Peek(0) == '"')
							mPos++;
						return;
					}
					mPos++;
				}
				return;
			}

			mPos++; // opening "
			int braceDepth = 0;
			while (mPos < mText.Length)
			{
				char8 c = mText[mPos];
				if (braceDepth > 0)
				{
					if (c == '"')
					{
						LexString(false, false);
						continue;
					}
					if (c == '\'')
					{
						LexChar();
						continue;
					}
					if (c == '{')
						braceDepth++;
					else if (c == '}')
						braceDepth--;
					mPos++;
					continue;
				}

				if (interp && c == '{')
				{
					if (Peek(1) == '{')
					{
						mPos += 2;
						continue;
					}
					braceDepth++;
					mPos++;
					continue;
				}
				if (verbatim)
				{
					if (c == '"')
					{
						if (Peek(1) == '"')
						{
							mPos += 2;
							continue;
						}
						mPos++;
						return;
					}
					mPos++;
					continue;
				}
				if (c == '\\')
				{
					mPos += 2;
					continue;
				}
				if (c == '"')
				{
					mPos++;
					return;
				}
				if (c == '\n')
					return; // unterminated; recover at line end
				mPos++;
			}
		}
	}
}
