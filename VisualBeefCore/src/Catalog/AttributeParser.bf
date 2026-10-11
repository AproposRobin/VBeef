using System;
using System.Collections;

namespace VisualBeef.Catalog
{
	/// One argument of an attribute: `Category="Math"` (Name = "Category") or `"Math"` (positional).
	class AttrArg
	{
		public String Name = new .() ~ delete _;
		/// The value with string quotes and escapes removed; other values as written.
		public String Value = new .() ~ delete _;
		public bool IsString;
	}

	/// One attribute from source text: `Node(Category="Math", Pure=true)`.
	class AttrInfo
	{
		/// Simple name without namespace or the "Attribute" suffix ("Node").
		public String Name = new .() ~ delete _;
		public List<AttrArg> Args = new .() ~ DeleteContainerAndItems!(_);

		/// A named argument, or the positional one at `position` (for `[Node("Math")]`).
		public StringView Get(StringView name, int position = -1)
		{
			for (let a in Args)
				if (a.Name == name)
					return a.Value;
			if (position >= 0)
			{
				int i = 0;
				for (let a in Args)
				{
					if (!a.Name.IsEmpty)
						continue;
					if (i == position)
						return a.Value;
					i++;
				}
			}
			return default;
		}

		public bool Has(StringView name, int position = -1) => Get(name, position).Ptr != null;

		public bool GetBool(StringView name, bool defaultValue = false)
		{
			for (let a in Args)
				if (a.Name == name)
					return a.Value == "true";
			return defaultValue;
		}

		public double GetNumber(StringView name, double defaultValue = 0)
		{
			let v = Get(name);
			if (v.Ptr == null)
				return defaultValue;
			var t = v;
			while (t.EndsWith('f') || t.EndsWith('F') || t.EndsWith('d') || t.EndsWith('D'))
				t.RemoveFromEnd(1);
			if (double.Parse(t) case .Ok(let d))
				return d;
			return defaultValue;
		}
	}

	/// Reads Beef attribute text (`[Pure, Node(Category="Math|Vector")] [Expose]`) without a
	/// compiler: names, positional and named arguments, string literals unescaped.
	static class AttributeParser
	{
		/// The VisualBeefMeta attribute names (see docs/Node-Attributes.md).
		public static bool IsNodeAttribute(StringView name)
		{
			switch (name)
			{
			case "Node", "Pure", "Expose", "Pin", "NodeLibrary", "NodeHidden", "Conversion", "ExpandEnumAsFlow", "ExpandEnumAsExecs", "ExposeType", "BlueprintType":
				return true;
			default:
				return false;
			}
		}

		public static void Parse(StringView text, List<AttrInfo> outAttrs)
		{
			int i = 0;
			int len = text.Length;
			while (i < len)
			{
				// Find the next '[' list.
				while (i < len && text[i] != '[')
					i++;
				if (i >= len)
					break;
				i++;
				// Attributes separated by commas until the matching ']'.
				while (i < len)
				{
					SkipSpace(text, ref i);
					if (i < len && text[i] == ']')
					{
						i++;
						break;
					}
					if (i < len && text[i] == ',')
					{
						i++;
						continue;
					}
					// Name (dotted); a target prefix `return:` is skipped.
					int nameStart = i;
					while (i < len && (text[i].IsLetterOrDigit || text[i] == '_' || text[i] == '.' || text[i] == '@'))
						i++;
					var name = text.Substring(nameStart, i - nameStart);
					SkipSpace(text, ref i);
					if (i < len && text[i] == ':' && (i + 1 >= len || text[i + 1] != ':'))
					{
						i++;
						continue;
					}
					if (name.IsEmpty)
					{
						// Unknown character: skip it to make progress.
						i++;
						continue;
					}
					AttrInfo info = new .();
					int dot = name.LastIndexOf('.');
					if (dot >= 0)
						name = name.Substring(dot + 1);
					if (name.EndsWith("Attribute") && name.Length > 9)
						name.RemoveFromEnd(9);
					info.Name.Set(name);
					outAttrs.Add(info);
					if (i < len && text[i] == '(')
					{
						i++;
						ParseArgs(text, ref i, info);
					}
				}
			}
		}

		static void SkipSpace(StringView text, ref int i)
		{
			while (i < text.Length && text[i].IsWhiteSpace)
				i++;
		}

		/// After '(' up to and including the matching ')'.
		static void ParseArgs(StringView text, ref int i, AttrInfo info)
		{
			int len = text.Length;
			while (i < len)
			{
				SkipSpace(text, ref i);
				if (i >= len)
					return;
				if (text[i] == ')')
				{
					i++;
					return;
				}
				if (text[i] == ',')
				{
					i++;
					continue;
				}
				AttrArg arg = new .();
				info.Args.Add(arg);
				// `Name =` (but not `==`)
				int save = i;
				int ns = i;
				while (i < len && (text[i].IsLetterOrDigit || text[i] == '_'))
					i++;
				int ne = i;
				SkipSpace(text, ref i);
				if (ne > ns && i < len && text[i] == '=' && (i + 1 >= len || text[i + 1] != '='))
				{
					arg.Name.Set(text.Substring(ns, ne - ns));
					i++;
					SkipSpace(text, ref i);
				}
				else
					i = save;
				ReadValue(text, ref i, arg);
			}
		}

		static void ReadValue(StringView text, ref int i, AttrArg arg)
		{
			int len = text.Length;
			bool verbatim = false;
			if (i + 1 < len && text[i] == '@' && text[i + 1] == '"')
			{
				verbatim = true;
				i++;
			}
			if (i < len && text[i] == '"')
			{
				arg.IsString = true;
				i++;
				while (i < len && text[i] != '"')
				{
					let c = text[i];
					if (c == '\\' && !verbatim && i + 1 < len)
					{
						i++;
						switch (text[i])
						{
						case 'n': arg.Value.Append('\n');
						case 't': arg.Value.Append('\t');
						case 'r': arg.Value.Append('\r');
						case '0': arg.Value.Append('\0');
						default: arg.Value.Append(text[i]);
						}
						i++;
						continue;
					}
					if (c == '"' && verbatim && i + 1 < len && text[i + 1] == '"')
					{
						arg.Value.Append('"');
						i += 2;
						continue;
					}
					arg.Value.Append(c);
					i++;
				}
				if (i < len)
					i++;
				return;
			}
			// Anything else: up to the next top-level ',' or ')'.
			int start = i;
			int depth = 0;
			while (i < len)
			{
				let c = text[i];
				if (c == '(' || c == '[' || c == '{')
					depth++;
				else if (c == ')' || c == ']' || c == '}')
				{
					if (depth == 0)
						break;
					depth--;
				}
				else if (c == ',' && depth == 0)
					break;
				else if (c == '\'')
				{
					// char literal
					i++;
					while (i < len && text[i] != '\'')
					{
						if (text[i] == '\\')
							i++;
						i++;
					}
				}
				i++;
			}
			var v = text.Substring(start, Math.Min(i, len) - start);
			v.Trim();
			arg.Value.Set(v);
		}

		/// Finds an attribute by simple name in parsed attributes.
		public static AttrInfo Find(List<AttrInfo> attrs, StringView name)
		{
			for (let a in attrs)
				if (a.Name == name)
					return a;
			return null;
		}
	}

	/// `///` doc comments: plain text, or the XML-ish C# form with <summary> and <param>.
	static class DocComment
	{
		/// The summary: text outside <param>/<returns> tags, tags stripped, lines joined.
		public static void Summary(StringView doc, String outText)
		{
			if (doc.IsEmpty)
				return;
			int i = 0;
			bool skipping = false;
			String raw = scope .();
			while (i < doc.Length)
			{
				let c = doc[i];
				if (c == '<')
				{
					int close = doc.Substring(i).IndexOf('>');
					if (close < 0)
					{
						raw.Append(doc.Substring(i));
						break;
					}
					let tag = doc.Substring(i + 1, close - 1);
					if (tag.StartsWith("param") || tag.StartsWith("returns") || tag.StartsWith("exception") || tag.StartsWith("typeparam"))
						skipping = !tag.EndsWith('/');
					else if (tag.StartsWith("/param") || tag.StartsWith("/returns") || tag.StartsWith("/exception") || tag.StartsWith("/typeparam"))
						skipping = false;
					else if (tag.StartsWith("see") || tag.StartsWith("paramref"))
					{
						// <see cref="X"/> -> X
						int q = tag.IndexOf('"');
						if (q >= 0)
						{
							int q2 = tag.Substring(q + 1).IndexOf('"');
							if (q2 >= 0 && !skipping)
								raw.Append(tag.Substring(q + 1, q2));
						}
					}
					i += close + 1;
					continue;
				}
				if (!skipping)
					raw.Append(c);
				i++;
			}
			// Collapse whitespace runs inside lines, keep paragraph breaks.
			for (var line in raw.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty)
					continue;
				if (!outText.IsEmpty)
					outText.Append(' ');
				outText.Append(line);
			}
		}

		/// The text of `<param name="name">...</param>`.
		public static void Param(StringView doc, StringView name, String outText)
		{
			String open = scope $"<param name=\"{name}\">";
			int at = doc.IndexOf(open);
			if (at < 0)
				return;
			var rest = doc.Substring(at + open.Length);
			int end = rest.IndexOf("</param>");
			if (end >= 0)
				rest = rest.Substring(0, end);
			for (var line in rest.Split('\n'))
			{
				line.Trim();
				if (line.IsEmpty)
					continue;
				if (!outText.IsEmpty)
					outText.Append(' ');
				outText.Append(line);
			}
		}
	}
}
