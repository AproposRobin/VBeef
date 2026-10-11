using System;
using System.Collections;

namespace VisualBeef.Syntax
{
	/// Which `#if` arm is in force, for showing the active one of two same-named methods
	/// (docs/Parsing-and-Layout.md). The defines are the Beef compiler's for a Windows x64
	/// Debug build unless the editor sets others; an arm path (Member.CondPath) is active when
	/// every arm on it is: `if A` needs A, `else A` needs !A, `elif B` needs B.
	static class Preprocessor
	{
		public static HashSet<String> Defines = MakeDefaults() ~ DeleteContainerAndItems!(_);

		static HashSet<String> MakeDefaults()
		{
			HashSet<String> d = new .();
			for (let s in StringView[?]("BF_PLATFORM_WINDOWS", "BF_64_BIT", "BF_LITTLE_ENDIAN", "BF_MACHINE_X64", "DEBUG", "BF_DEBUG_ALLOC",
				"BF_ENABLE_REALTIME_LEAK_CHECK", "BF_ENABLE_OBJECT_DEBUG_FLAGS", "BF_HAS_VDATA_EXTENDER"))
				d.Add(new String(s));
			return d;
		}

		/// True when every arm on the path is taken with the current defines.
		public static bool IsActive(StringView condPath)
		{
			if (condPath.IsEmpty)
				return true;
			for (var part in condPath.Split("; "))
			{
				part.Trim();
				int sp = part.IndexOf(' ');
				StringView kind = (sp < 0) ? part : part.Substring(0, sp);
				StringView cond = (sp < 0) ? "" : part.Substring(sp + 1);
				bool v = Eval(cond);
				if (kind == "else" ? v : !v)
					return false;
			}
			return true;
		}

		/// Evaluates `A && !(B || C)`, `true`, `false`; unknown words are false (undefined).
		public static bool Eval(StringView expr)
		{
			int pos = 0;
			return Or(expr, ref pos);
		}

		static void Skip(StringView s, ref int pos)
		{
			while (pos < s.Length && s[pos].IsWhiteSpace)
				pos++;
		}

		static bool Or(StringView s, ref int pos)
		{
			bool v = And(s, ref pos);
			while (true)
			{
				Skip(s, ref pos);
				if (pos + 1 < s.Length && s[pos] == '|' && s[pos + 1] == '|')
				{
					pos += 2;
					bool r = And(s, ref pos);
					v = v || r;
				}
				else
					return v;
			}
		}

		static bool And(StringView s, ref int pos)
		{
			bool v = Unary(s, ref pos);
			while (true)
			{
				Skip(s, ref pos);
				if (pos + 1 < s.Length && s[pos] == '&' && s[pos + 1] == '&')
				{
					pos += 2;
					bool r = Unary(s, ref pos);
					v = v && r;
				}
				else
					return v;
			}
		}

		static bool Unary(StringView s, ref int pos)
		{
			Skip(s, ref pos);
			if (pos < s.Length && s[pos] == '!')
			{
				pos++;
				return !Unary(s, ref pos);
			}
			if (pos < s.Length && s[pos] == '(')
			{
				pos++;
				bool v = Or(s, ref pos);
				Skip(s, ref pos);
				if (pos < s.Length && s[pos] == ')')
					pos++;
				return v;
			}
			int start = pos;
			while (pos < s.Length && (s[pos].IsLetterOrDigit || s[pos] == '_'))
				pos++;
			let word = s.Substring(start, pos - start);
			if (word == "true")
				return true;
			if (word == "false" || word.IsEmpty)
				return false;
			return Defines.ContainsAlt(word);
		}
	}
}
