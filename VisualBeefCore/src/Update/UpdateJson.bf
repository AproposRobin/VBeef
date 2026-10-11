// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).

using System;
using System.Collections;

namespace VisualBeef.Update
{
	/// A small strict JSON reader for the updater: the release descriptor (release.json) and the list of releases the
	/// preview channel reads. Objects keep their key order; numbers keep their text (integers are read exactly).
	/// Depth is limited (32) so a hostile document cannot exhaust the stack.
	public class UpdateJson
	{
		public enum Kind { Null, Bool, Number, String, Array, Object }

		public Kind Type;
		public bool BoolValue;
		/// The number's text, or the string's value.
		public String Text ~ delete _;
		public List<UpdateJson> Items ~ DeleteContainerAndItems!(_);
		public List<String> Keys ~ DeleteContainerAndItems!(_);

		public const int MaxDepth = 32;

		public bool IsObject => Type == .Object;
		public bool IsArray => Type == .Array;

		public UpdateJson Get(StringView key)
		{
			if (Type != .Object)
				return null;
			for (int i < Keys.Count)
				if (Keys[i] == key)
					return Items[i];
			return null;
		}

		/// The string value of `key`; false when it is missing or not a string.
		public bool GetString(StringView key, String outValue)
		{
			let v = Get(key);
			if (v == null || v.Type != .String)
				return false;
			outValue.Set(v.Text);
			return true;
		}

		/// A whole number (no fraction, no exponent) that fits in int64; false otherwise.
		public bool GetInt(StringView key, out int64 value)
		{
			value = 0;
			let v = Get(key);
			if (v == null || v.Type != .Number)
				return false;
			for (let c in v.Text.RawChars)
				if (!c.IsDigit && c != '-')
					return false;
			if (int64.Parse(v.Text) case .Ok(let n))
			{
				value = n;
				return true;
			}
			return false;
		}

		public bool GetBool(StringView key, bool def)
		{
			let v = Get(key);
			return (v != null && v.Type == .Bool) ? v.BoolValue : def;
		}

		public static Result<UpdateJson> Parse(StringView text)
		{
			int i = 0;
			let v = ParseValue(text, ref i, 0);
			if (v == null)
				return .Err;
			SkipWs(text, ref i);
			if (i != text.Length)
			{
				delete v;
				return .Err;
			}
			return v;
		}

		static void SkipWs(StringView s, ref int i)
		{
			while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r'))
				i++;
		}

		static bool Literal(StringView s, ref int i, StringView word)
		{
			if (i + word.Length > s.Length || s.Substring(i, word.Length) != word)
				return false;
			i += word.Length;
			return true;
		}

		static UpdateJson ParseValue(StringView s, ref int i, int depth)
		{
			if (depth > MaxDepth)
				return null;
			SkipWs(s, ref i);
			if (i >= s.Length)
				return null;
			let c = s[i];
			if (c == '{')
			{
				i++;
				let obj = new UpdateJson() { Type = .Object, Items = new .(), Keys = new .() };
				SkipWs(s, ref i);
				if (i < s.Length && s[i] == '}')
				{
					i++;
					return obj;
				}
				while (true)
				{
					SkipWs(s, ref i);
					String key = new .();
					if (i >= s.Length || s[i] != '"' || !ParseString(s, ref i, key))
					{
						delete key;
						delete obj;
						return null;
					}
					SkipWs(s, ref i);
					if (i >= s.Length || s[i] != ':')
					{
						delete key;
						delete obj;
						return null;
					}
					i++;
					let v = ParseValue(s, ref i, depth + 1);
					if (v == null)
					{
						delete key;
						delete obj;
						return null;
					}
					obj.Keys.Add(key);
					obj.Items.Add(v);
					SkipWs(s, ref i);
					if (i < s.Length && s[i] == ',')
					{
						i++;
						continue;
					}
					if (i < s.Length && s[i] == '}')
					{
						i++;
						return obj;
					}
					delete obj;
					return null;
				}
			}
			if (c == '[')
			{
				i++;
				let arr = new UpdateJson() { Type = .Array, Items = new .() };
				SkipWs(s, ref i);
				if (i < s.Length && s[i] == ']')
				{
					i++;
					return arr;
				}
				while (true)
				{
					let v = ParseValue(s, ref i, depth + 1);
					if (v == null)
					{
						delete arr;
						return null;
					}
					arr.Items.Add(v);
					SkipWs(s, ref i);
					if (i < s.Length && s[i] == ',')
					{
						i++;
						continue;
					}
					if (i < s.Length && s[i] == ']')
					{
						i++;
						return arr;
					}
					delete arr;
					return null;
				}
			}
			if (c == '"')
			{
				let str = new UpdateJson() { Type = .String, Text = new .() };
				if (!ParseString(s, ref i, str.Text))
				{
					delete str;
					return null;
				}
				return str;
			}
			if (Literal(s, ref i, "true"))
				return new UpdateJson() { Type = .Bool, BoolValue = true };
			if (Literal(s, ref i, "false"))
				return new UpdateJson() { Type = .Bool, BoolValue = false };
			if (Literal(s, ref i, "null"))
				return new UpdateJson() { Type = .Null };
			if (c == '-' || c.IsDigit)
			{
				int start = i;
				if (s[i] == '-')
					i++;
				int digits = 0;
				while (i < s.Length && s[i].IsDigit)
				{
					i++;
					digits++;
				}
				if (digits == 0)
					return null;
				if (i < s.Length && s[i] == '.')
				{
					i++;
					int frac = 0;
					while (i < s.Length && s[i].IsDigit)
					{
						i++;
						frac++;
					}
					if (frac == 0)
						return null;
				}
				if (i < s.Length && (s[i] == 'e' || s[i] == 'E'))
				{
					i++;
					if (i < s.Length && (s[i] == '+' || s[i] == '-'))
						i++;
					int exp = 0;
					while (i < s.Length && s[i].IsDigit)
					{
						i++;
						exp++;
					}
					if (exp == 0)
						return null;
				}
				return new UpdateJson() { Type = .Number, Text = new .(s.Substring(start, i - start)) };
			}
			return null;
		}

		static int HexValue(char8 c)
		{
			if (c >= '0' && c <= '9')
				return c - '0';
			if (c >= 'a' && c <= 'f')
				return c - 'a' + 10;
			if (c >= 'A' && c <= 'F')
				return c - 'A' + 10;
			return -1;
		}

		static bool ReadHex4(StringView s, ref int i, out uint32 value)
		{
			value = 0;
			if (i + 4 > s.Length)
				return false;
			for (int k < 4)
			{
				let h = HexValue(s[i + k]);
				if (h < 0)
					return false;
				value = (value << 4) | (uint32)h;
			}
			i += 4;
			return true;
		}

		/// Reads a string starting at its opening quote. Control characters must be escaped.
		static bool ParseString(StringView s, ref int i, String outStr)
		{
			i++; // opening quote
			while (i < s.Length)
			{
				let c = s[i];
				if (c == '"')
				{
					i++;
					return true;
				}
				if ((uint8)c < 0x20)
					return false;
				if (c != '\\')
				{
					outStr.Append(c);
					i++;
					continue;
				}
				i++;
				if (i >= s.Length)
					return false;
				let e = s[i++];
				switch (e)
				{
				case '"': outStr.Append('"');
				case '\\': outStr.Append('\\');
				case '/': outStr.Append('/');
				case 'b': outStr.Append('\b');
				case 'f': outStr.Append('\f');
				case 'n': outStr.Append('\n');
				case 'r': outStr.Append('\r');
				case 't': outStr.Append('\t');
				case 'u':
					if (!ReadHex4(s, ref i, var cp))
						return false;
					if (cp >= 0xD800 && cp <= 0xDBFF)
					{
						if (i + 2 > s.Length || s[i] != '\\' || s[i + 1] != 'u')
							return false;
						i += 2;
						if (!ReadHex4(s, ref i, let low) || low < 0xDC00 || low > 0xDFFF)
							return false;
						cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
					}
					else if (cp >= 0xDC00 && cp <= 0xDFFF)
						return false;
					outStr.Append((char32)cp);
				default:
					return false;
				}
			}
			return false;
		}

		/// Writes `s` as a JSON string literal (quotes included).
		public static void WriteString(StringView s, String outText)
		{
			outText.Append('"');
			for (let c in s.RawChars)
			{
				switch (c)
				{
				case '"': outText.Append("\\\"");
				case '\\': outText.Append("\\\\");
				case '\n': outText.Append("\\n");
				case '\r': outText.Append("\\r");
				case '\t': outText.Append("\\t");
				default:
					if ((uint8)c < 0x20)
						outText.AppendF("\\u{0:X4}", (int)c);
					else
						outText.Append(c);
				}
			}
			outText.Append('"');
		}
	}
}
