using System;

namespace VisualBeef.Syntax
{
	enum TokenKind : uint8
	{
		EOF,
		Identifier, // identifiers and keywords
		Number,
		String,     // any string literal form (regular, verbatim, interpolated, multi-line)
		Char,
		Symbol      // operators and punctuation
	}

	/// A token plus the trivia that surrounds it. Every character of the source belongs to
	/// exactly one token's LeadStart..TrailEnd range, so concatenating all tokens reproduces
	/// the file byte-for-byte.
	///
	///   [LeadStart .. Start)  leading trivia (whitespace, comments, preprocessor lines)
	///   [Start .. End)        the token text
	///   [End .. TrailEnd)     trailing trivia on the same line (spaces, a comment, the newline)
	struct Token
	{
		public TokenKind Kind;
		public int32 LeadStart;
		public int32 Start;
		public int32 End;
		public int32 TrailEnd;

		public int Length => End - Start;
	}

	/// Classifies literal tokens into the type Beef gives them.
	static class Literals
	{
		static bool IsHexDigit(char8 c)
		{
			return CharUtil.IsDigit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
		}

		/// kind is the lexer's token kind (Number, String or Char); text is the token text.
		public static LiteralKind Classify(TokenKind kind, StringView text)
		{
			switch (kind)
			{
			case .Number:
				return ClassifyNumber(text);
			case .Char:
				return ClassifyChar(text);
			case .String:
				return ClassifyString(text);
			case .Identifier:
				if (text == "true" || text == "false") return .Bool;
				if (text == "null") return .Null;
				if (text == "this") return .This;
				if (text == "base") return .Base;
				if (text == "default") return .Default;
				return .None;
			default:
				return .None;
			}
		}

		public static LiteralKind ClassifyString(StringView text)
		{
			bool verbatim = false;
			bool interp = false;
			int i = 0;
			while (i < text.Length && (text[i] == '@' || text[i] == '$'))
			{
				if (text[i] == '@') verbatim = true;
				else interp = true;
				i++;
			}
			if (i + 2 < text.Length && text[i] == '"' && text[i + 1] == '"' && text[i + 2] == '"')
				return .RawString;
			if (interp)
				return .InterpolatedString;
			if (verbatim)
				return .VerbatimString;
			return .String;
		}

		public static LiteralKind ClassifyChar(StringView text)
		{
			if (text.Length >= 3 && text[0] == '\'')
			{
				if (text[1] == '\\' && (text[2] == 'u' || text[2] == 'U'))
					return .Char32;
				if ((uint8)text[1] >= 0x80)
					return .Char32;
			}
			return .Char8;
		}

		public static LiteralKind ClassifyNumber(StringView text)
		{
			if (text.IsEmpty)
				return .None;
			int i = 0;
			bool hexOrBin = false;
			int radix = 10;
			if (text.Length > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X'))
			{
				radix = 16;
				hexOrBin = true;
				i = 2;
			}
			else if (text.Length > 2 && text[0] == '0' && (text[1] == 'b' || text[1] == 'B'))
			{
				radix = 2;
				hexOrBin = true;
				i = 2;
			}

			uint64 value = 0;
			bool overflow = false;
			bool isReal = false;
			// Digits (underscores and ' separators are ignored)
			if (hexOrBin)
			{
				for (; i < text.Length; i++)
				{
					let c = text[i];
					if (c == '_' || c == '\'')
						continue;
					if (radix == 16 ? !IsHexDigit(c) : !(c == '0' || c == '1'))
						break;
					uint64 d = CharUtil.IsDigit(c) ? (uint64)(c - '0') : (uint64)(((int32)c | 0x20) - (int32)'a' + 10);
					if (value >> (radix == 16 ? 60 : 63) != 0)
						overflow = true;
					value = value * (uint64)radix + d;
				}
			}
			else
			{
				for (; i < text.Length; i++)
				{
					let c = text[i];
					if (c == '_' || c == '\'')
						continue;
					if (CharUtil.IsDigit(c))
					{
						uint64 d = (uint64)(c - '0');
						if (value > (uint64.MaxValue - d) / 10)
							overflow = true;
						else
							value = value * 10 + d;
						continue;
					}
					if (c == '.' && i + 1 < text.Length && CharUtil.IsDigit(text[i + 1]))
					{
						isReal = true;
						continue;
					}
					if ((c == 'e' || c == 'E') && i + 1 < text.Length &&
						(CharUtil.IsDigit(text[i + 1]) || ((text[i + 1] == '+' || text[i + 1] == '-') && i + 2 < text.Length && CharUtil.IsDigit(text[i + 2]))))
					{
						isReal = true;
						i += 2;
						while (i < text.Length && (CharUtil.IsDigit(text[i]) || text[i] == '_'))
							i++;
					}
					break;
				}
				// After a fraction, digits kept accumulating into value; that is fine for reals.
			}

			// Suffix
			bool u = false;
			bool l = false;
			bool f = false;
			bool d = false;
			for (; i < text.Length; i++)
			{
				switch (text[i])
				{
				case 'u', 'U': u = true;
				case 'l', 'L': l = true;
				case 'f', 'F': f = true;
				case 'd', 'D': d = true;
				}
			}

			if (!hexOrBin)
			{
				if (f)
					return .Float;
				if (d || isReal)
					return .Double;
			}
			if (u)
			{
				if (l || overflow || value > 0xFFFFFFFF)
					return .ULong;
				return .UInt;
			}
			if (l)
				return (overflow || value > (uint64)int64.MaxValue) ? .ULong : .Long;
			if (overflow)
				return .ULong;
			if (value <= 0x7FFFFFFF)
				return .Int;
			if (hexOrBin && value <= 0xFFFFFFFF)
				return .UInt;
			return (value <= (uint64)int64.MaxValue) ? .Long : .ULong;
		}
	}

	static class CharUtil
	{
		public static bool IsIdentStart(char8 c)
		{
			return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || (uint8)c >= 0x80;
		}

		public static bool IsIdentChar(char8 c)
		{
			return IsIdentStart(c) || (c >= '0' && c <= '9');
		}

		public static bool IsDigit(char8 c)
		{
			return c >= '0' && c <= '9';
		}

		public static bool IsSpace(char8 c)
		{
			return c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\f' || c == '\v';
		}
	}
}
