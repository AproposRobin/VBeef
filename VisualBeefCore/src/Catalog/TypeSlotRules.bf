using System;
using System.Collections;

namespace VisualBeef.Catalog
{
	/// Where a type is being written. Each place accepts a different set of types
	/// (docs/Catalog-and-Types.md > What a type field accepts).
	enum TypeSlot : uint8
	{
		/// A function's Return Type: `void` and `ref T` are fine; `var` only on a [Comptime] function.
		Return,
		/// A function parameter's type (the modifier is a separate field).
		Param,
		/// A member variable or property of a type.
		Member,
		/// A local variable node: `var` / `let` take the type from the value.
		Local,
		/// The element of a For Each: `var` / `let` too.
		ForEach,
		/// Cast To.
		Cast,
		/// The type a Construct (new / scope) node makes.
		Construct,
		/// A base class, struct or interface in a type's base list.
		Base,
		/// What a Switch node switches on: whole numbers, characters, text or an enum.
		SwitchValue
	}

	/// What is in scope where the type is written.
	struct TypeScope
	{
		/// Comma separated generic parameters in scope (the function's and every enclosing type's).
		public StringView Generics;
		/// False when `Generics` is unknown: an undeclared `T` is then not reported.
		public bool GenericsKnown;
		/// False outside every type declaration: `Self` has no meaning there.
		public bool InType = true;
		/// The function carries [Comptime]: its Return Type may be `var`.
		public bool Comptime;
		/// The member is a mixin: its parameters may be untyped (`var`).
		public bool Mixin;
		/// Base slot: the type being declared is an enum (its base is an integer type).
		public bool IsEnum;
		/// Base slot: the type being declared is a struct. A struct may have one basic type as its first base (a typed primitive, `struct Handle : int`, like corlib's Int64 : int64).
		public bool IsStruct;
		/// Does the project or a library declare a type with this name? (Null: unknown.)
		public delegate bool(StringView) Known;
		/// SwitchValue slot: is this type name an enum? (Null: only the built-in types are accepted.)
		public delegate bool(StringView) IsEnumType;
	}

	/// What Beef 0.43.6 accepts as a type in each place a type is chosen or typed, and the
	/// message when it does not. One place, so the pickers, the document edits and the
	/// declaration errors of a file edited by hand all say the same thing.
	static class TypeSlotRules
	{
		static StringView[?] sKeywords = .("abstract", "as", "base", "break", "case", "catch", "class", "const", "continue", "default",
			"defer", "delete", "do", "else", "enum", "extern", "false", "finally", "for", "foreach", "if", "implicit", "explicit", "in",
			"interface", "internal", "is", "namespace", "new", "null", "operator", "out", "override", "params", "private", "protected",
			"public", "readonly", "ref", "repeat", "return", "scope", "sealed", "static", "struct", "switch", "this", "throw", "true",
			"try", "typeof", "using", "virtual", "while", "where", "mixin", "extension");

		static StringView[?] sIntegers = .("int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "intptr", "uintptr", "char8", "char16", "char32");

		static StringView[?] sPrimitives = .("bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
			"intptr", "uintptr", "float", "double", "char8", "char16", "char32", "void");

		public static bool IsPrimitiveName(StringView w) => IsInArr(sPrimitives, w);

		public static bool IsKeyword(StringView w)
		{
			for (let k in sKeywords)
				if (k == w)
					return true;
			return false;
		}

		static bool IsInArr(Span<StringView> list, StringView w)
		{
			for (let k in list)
				if (k == w)
					return true;
			return false;
		}

		static bool IdentStart(char8 c) => c.IsLetter || c == '_' || c == '@';
		static bool IdentChar(char8 c) => c.IsLetterOrDigit || c == '_';

		struct Ctx
		{
			public StringView S;
			public TypeSlot Slot;
			public TypeScope Sc;
			public String Why;
		}

		static bool Fail(ref Ctx c, StringView word, StringView why)
		{
			c.Why.Clear();
			if (word.IsEmpty)
				c.Why.Set(why);
			else
				c.Why.AppendF("'{}' is not allowed here: {}", word, why);
			return false;
		}

		static void SkipWs(ref Ctx c, ref int i)
		{
			while (i < c.S.Length && c.S[i].IsWhiteSpace)
				i++;
		}

		/// True when `type` fits `slot`. Otherwise `why` holds "'<word>' is not allowed here:
		/// <reason>" (or a plainer sentence when no single word is at fault).
		public static bool Check(StringView typeIn, TypeSlot slot, TypeScope sc, String why)
		{
			var t = typeIn;
			t.Trim();
			why.Clear();
			if (t == "...")
				return true; // a C-style variadic
			if (t.IsEmpty)
			{
				why.Set("A type is needed here.");
				return false;
			}
			if (slot == .Return)
			{
				if (t.StartsWith("ref ") || t.StartsWith("readonly ref "))
				{
					t = t.Substring(t.IndexOf("ref ") + 4);
					t.Trim();
				}
			}
			else
			{
				for (let mod in StringView[?]("ref", "in", "out", "params", "mut", "readonly", "const"))
				{
					if (t.StartsWith(mod) && t.Length > mod.Length && t[mod.Length].IsWhiteSpace)
					{
						let how = (slot == .Param) ? "it is the parameter's modifier: set it in the Modifier field, not in the type." : "it is not part of a type.";
						Ctx c0 = .() { S = t, Slot = slot, Sc = sc, Why = why };
						return Fail(ref c0, mod, how);
					}
				}
			}
			Ctx c = .() { S = t, Slot = slot, Sc = sc, Why = why };
			int i = 0;
			if (!ParseType(ref c, ref i, 0))
				return false;
			SkipWs(ref c, ref i);
			if (i < t.Length)
			{
				c.Why.Clear();
				c.Why.AppendF("'{}' is not part of a type name.", t.Substring(i));
				return false;
			}
			if (slot == .SwitchValue)
				return CheckSwitchValue(t, sc, why);
			return true;
		}

		/// A switch is on a whole number, a character, text or an enum.
		static bool CheckSwitchValue(StringView t, TypeScope sc, String why)
		{
			if (t == "String" || t == "StringView" || t == "bool" || t == "float" || t == "double")
			{
				if (t == "String" || t == "StringView")
					return true;
				why.AppendF("'{}' is not allowed here: a switch works on whole numbers, characters, text and enums.", t);
				return false;
			}
			if (IsInArr(sIntegers, t))
				return true;
			if (sc.IsEnumType != null && sc.IsEnumType(t))
				return true;
			why.AppendF("'{}' is not allowed here: a switch works on whole numbers, characters, text and enums.", t);
			return false;
		}

		static bool ParseType(ref Ctx c, ref int i, int level)
		{
			SkipWs(ref c, ref i);
			let s = c.S;
			if (i >= s.Length)
			{
				c.Why.Set("The type is incomplete.");
				return false;
			}
			bool anySuffix = false;
			bool firstPtr = false;
			StringView word = default;
			bool dotted = false;
			if (level == 0 && s[i] == '.' && i + 1 < s.Length && IdentStart(s[i + 1]))
				i++; // an inferred type: .Enumerator
			if (s[i] == '(')
			{
				// Tuple: (int a, String b)
				i++;
				while (true)
				{
					if (!ParseType(ref c, ref i, level + 1))
						return false;
					SkipWs(ref c, ref i);
					if (i < s.Length && IdentStart(s[i]))
					{
						while (i < s.Length && IdentChar(s[i]))
							i++;
						SkipWs(ref c, ref i);
					}
					if (i < s.Length && s[i] == ',')
					{
						i++;
						continue;
					}
					if (i < s.Length && s[i] == ')')
					{
						i++;
						break;
					}
					c.Why.Set("The tuple type is not closed with ')'.");
					return false;
				}
			}
			else if (IdentStart(s[i]))
			{
				int start = i;
				while (i < s.Length && IdentChar(s[i]))
					i++;
				word = s.Substring(start, i - start);
				if (word == "delegate" || word == "function" || word == "decltype" || word == "comptype" || word == "alloctype" || word == "rettype")
				{
					// Written forms checked by the compiler: skip to the end of the parameter list.
					int open = -1;
					int bd = 0;
					for (int j = i; j < s.Length; j++)
					{
						let cj = s[j];
						if (cj == '[' || cj == '<') bd++;
						else if (cj == ']' || cj == '>') bd--;
						else if (cj == '(' && bd == 0) { open = j; break; }
					}
					if (open < 0)
					{
						i = s.Length;
						return true;
					}
					int pd = 0;
					for (int j = open; j < s.Length; j++)
					{
						if (s[j] == '(') pd++;
						else if (s[j] == ')' && --pd == 0)
						{
							i = j + 1;
							break;
						}
					}
					if (pd != 0)
						i = s.Length;
					return true;
				}
				while (true)
				{
					if (i < s.Length && s[i] == '<')
					{
						i++;
						while (true)
						{
							// A constant generic argument: `SizedArray<int, 4>`, `Grid<int, -1>`.
							SkipWs(ref c, ref i);
							if (i < s.Length && (s[i].IsDigit || (s[i] == '-' && i + 1 < s.Length && s[i + 1].IsDigit)))
							{
								i++;
								while (i < s.Length && (s[i].IsLetterOrDigit || s[i] == '_'))
									i++;
							}
							else if (!ParseType(ref c, ref i, level + 1))
								return false;
							SkipWs(ref c, ref i);
							if (i < s.Length && s[i] == ',')
							{
								i++;
								continue;
							}
							if (i < s.Length && s[i] == '>')
							{
								i++;
								break;
							}
							c.Why.AppendF("The generic arguments of '{}' are not closed with '>'.", word);
							return false;
						}
					}
					if (i + 1 < s.Length && (s[i] == '.' || (s[i] == ':' && s[i + 1] == ':')))
					{
						i += (s[i] == '.') ? 1 : 2;
						if (i >= s.Length || !IdentStart(s[i]))
						{
							c.Why.Set("A name is missing after the '.'.");
							return false;
						}
						while (i < s.Length && IdentChar(s[i]))
							i++;
						dotted = true;
						continue;
					}
					break;
				}
			}
			else
			{
				c.Why.AppendF("'{}' is not a type name.", s.Substring(i));
				return false;
			}
			// Suffixes: pointer, nullable, array.
			while (i < s.Length)
			{
				int at = i;
				while (at < s.Length && s[at].IsWhiteSpace)
					at++;
				if (at >= s.Length || !(s[at] == '*' || s[at] == '?' || s[at] == '['))
					break;
				i = at;
				let ch = s[i];
				if (ch == '*' || ch == '?')
				{
					if (!anySuffix)
						firstPtr = ch == '*';
					anySuffix = true;
					i++;
				}
				else if (ch == '[')
				{
					// T[], T[,], T[4], T[?], T[N]: a size or nothing.
					int j = i + 1;
					while (j < s.Length && s[j] != ']')
						j++;
					if (j >= s.Length)
					{
						c.Why.Set("An array type is written T[] (or T[,] for two dimensions, T[4] for a fixed size).");
						return false;
					}
					if (!anySuffix)
						firstPtr = false;
					anySuffix = true;
					i = j + 1;
				}
				else
					break;
			}
			if (!word.IsEmpty && !dotted)
				return CheckWord(ref c, word, level, anySuffix, firstPtr);
			return true;
		}

		static bool CheckWord(ref Ctx c, StringView word, int level, bool anySuffix, bool firstPtr)
		{
			let slot = c.Slot;
			let sc = c.Sc;
			if (word == "void")
			{
				if (firstPtr)
					return true;
				if (!anySuffix && (level > 0 || slot == .Return))
					return true; // Result<void, E>

				return Fail(ref c, word, "void is not a value. It only works as a function's Return Type (nothing returned) or in a pointer, void*.");
			}
			if (word == "var" || word == "let")
			{
				bool ok = level == 0 && !anySuffix && (slot == .Local || slot == .ForEach || (slot == .Return && sc.Comptime && word == "var") || (slot == .Param && sc.Mixin));
				if (ok)
					return true;
				switch (slot)
				{
				case .Return:
					return Fail(ref c, word, "a function returns a named type (void when it returns nothing). var is only valid on a [Comptime] function.");
				case .Param:
					return Fail(ref c, word, "a parameter needs a named type; var and let take their type from a value, which only a local variable has.");
				case .Member:
					return Fail(ref c, word, "a variable of a type needs a named type; var and let are only for local variables.");
				case .Cast:
					return Fail(ref c, word, "a Cast names the type to convert to.");
				case .Construct:
					return Fail(ref c, word, "a Construct node makes a named type.");
				case .Base:
					return Fail(ref c, word, "a base type is a named class, struct or interface.");
				default:
					return Fail(ref c, word, "var and let must stand alone (not in an array, pointer, nullable or generic argument); name the type.");
				}
			}
			if (word == "Self" || word == "SelfBase")
			{
				if (!sc.InType)
					return Fail(ref c, word, scope $"{word} is the type that contains this code; there is no type here.");
				if (slot == .Base)
					return Fail(ref c, word, scope $"{word} cannot be written in a type's own base list.");
				return true;
			}
			if (IsKeyword(word))
				return Fail(ref c, word, "it is a Beef keyword, not a type name.");
			if (slot == .Base)
			{
				if (level == 0 && anySuffix)
					return Fail(ref c, word, "a base type is a plain class, struct or interface name, not an array, pointer or nullable.");
				if (IsInArr(sPrimitives, word))
				{
					if (sc.IsEnum && IsInArr(sIntegers, word))
						return true;
					if (sc.IsStruct && level == 0 && word != "void")
						return true;
					return Fail(ref c, word, sc.IsEnum ? "an enum's base type is an integer type." : sc.IsStruct ? "a struct's basic base type cannot be void." : "only an enum or a struct can have a basic type as its base.");
				}
				if (sc.IsEnum && level == 0)
					return Fail(ref c, word, "an enum's base type is an integer type.");
			}
			if (sc.GenericsKnown && LooksGeneric(word) && !InList(sc.Generics, word) && !(sc.Known != null && sc.Known(word)))
			{
				return Fail(ref c, word, scope $"{word} is a generic parameter that is not declared here. Declare it on the function (Name<{word}>) or on its type (Type Settings > Generics), or use a real type.");
			}
			return true;
		}

		static bool LooksGeneric(StringView w)
		{
			if (w.Length == 1)
				return w[0].IsUpper;
			return w == "TKey" || w == "TValue" || w == "TResult" || w == "TElement" || w == "TItem" || w == "TSource";
		}

		public static bool InList(StringView list, StringView name)
		{
			for (var d in list.Split(','))
			{
				d.Trim();
				if (d == name)
					return true;
			}
			return false;
		}

		// ------------------------------------------------------------------ generic parameter lists

		/// "T, U" for a type or function: names only (or `const int N`), no duplicates, no keyword,
		/// basic type, var or void.
		public static bool CheckGenericList(StringView list, String why)
		{
			why.Clear();
			var l = list;
			l.Trim();
			if (l.IsEmpty)
				return true;
			List<StringView> seen = scope .();
			for (var part in l.Split(','))
			{
				part.Trim();
				if (part.IsEmpty)
				{
					why.Set("A generic parameter list is names separated by commas (T, U); one is empty.");
					return false;
				}
				var name = part;
				if (name.StartsWith("const "))
				{
					let sp = name.LastIndexOf(' ');
					name = name.Substring(sp + 1);
				}
				bool bad = name.IsEmpty || !IdentStart(name[0]);
				for (let ch in name.RawChars)
					if (!IdentChar(ch))
						bad = true;
				if (bad)
				{
					why.AppendF("'{}' is not a name: generic parameters are names such as T or TKey.", part);
					return false;
				}
				if (IsKeyword(name) || IsInArr(sPrimitives, name) || name == "var" || name == "let" || name == "Self" || name == "SelfBase")
				{
					why.AppendF("'{}' is not allowed here: a generic parameter is a new name, not a keyword or a type that exists.", name);
					return false;
				}
				for (let s in seen)
					if (s == name)
					{
						why.AppendF("'{}' is not allowed here: it is declared twice.", name);
						return false;
					}
				seen.Add(name);
			}
			return true;
		}

		// ------------------------------------------------------------------ parameter lists

		/// The ways a parameter can be passed, for the Passing chooser (Properties > Inputs and the
		/// Add Function dialog): "" (a copy of the value), `out`, `ref` and `in`. Beef 0.43.6 takes
		/// out / ref / in on a parameter of any type, but not with a default value (`= x`) and not
		/// on an untyped mixin parameter (`var`). A modifier this list does not offer (`params`,
		/// `mut`) is kept as the row's current choice so it is never lost by opening the chooser.
		public static void PassingChoices(StringView type, bool hasDefault, StringView current, List<StringView> outChoices)
		{
			outChoices.Add("");
			var t = type;
			t.Trim();
			if (!hasDefault && t != "var")
			{
				outChoices.Add("out");
				outChoices.Add("ref");
				outChoices.Add("in");
			}
			if (!current.IsEmpty && !outChoices.Contains(current))
				outChoices.Add(current);
		}

		/// What the Passing chooser shows for a modifier ("value" for none).
		public static StringView PassingLabel(StringView modifier) => modifier.IsEmpty ? "value" : modifier;

		/// A parameter list as typed ("int a, ref Foo b, params int[] rest"): modifiers, the type
		/// of each, `params` only on the last one.
		public static bool CheckParamList(StringView paramsText, TypeScope sc, String why)
		{
			why.Clear();
			var all = paramsText;
			all.Trim();
			if (all.IsEmpty)
				return true;
			List<StringView> parts = scope .();
			int depth = 0;
			int start = 0;
			for (int i < all.Length)
			{
				let ch = all[i];
				if (ch == '<' || ch == '(' || ch == '[')
					depth++;
				else if (ch == '>' || ch == ')' || ch == ']')
					depth--;
				else if (ch == ',' && depth == 0)
				{
					parts.Add(all.Substring(start, i - start));
					start = i + 1;
				}
			}
			parts.Add(all.Substring(start));
			for (int pi < parts.Count)
			{
				var p = parts[pi];
				p.Trim();
				// Attributes and a default value are not part of the type.
				while (p.StartsWith('['))
				{
					int close = p.IndexOf(']');
					if (close < 0)
						break;
					p = p.Substring(close + 1);
					p.Trim();
				}
				int eq = -1;
				int d2 = 0;
				for (int i < p.Length)
				{
					let ch = p[i];
					if (ch == '<' || ch == '(' || ch == '[')
						d2++;
					else if (ch == '>' || ch == ')' || ch == ']')
						d2--;
					else if (ch == '=' && d2 == 0)
					{
						eq = i;
						break;
					}
				}
				if (eq >= 0)
					p = p.Substring(0, eq);
				p.Trim();
				if (p.IsEmpty)
				{
					why.Set("A parameter is empty: each one is a type and a name (int a).");
					return false;
				}
				StringView modifier = "";
				bool again = true;
				while (again)
				{
					again = false;
					for (let mod in StringView[?]("this", "ref", "out", "in", "params", "mut"))
					{
						if (p.StartsWith(mod) && p.Length > mod.Length && p[mod.Length].IsWhiteSpace)
						{
							if (mod == "this" && pi != 0)
							{
								why.Set("'this' is not allowed here: only the first parameter of a static extension method can be 'this'.");
								return false;
							}
							if (mod == "params" && pi != parts.Count - 1)
							{
								why.Set("'params' is not allowed here: only the last parameter can be params.");
								return false;
							}
							if (mod != "this")
								modifier = mod;
							p = p.Substring(mod.Length);
							p.Trim();
							again = true;
						}
					}
				}
				// The name is the last word; the type is what is in front of it.
				int sp = -1;
				int d3 = 0;
				for (int i = p.Length - 1; i >= 0; i--)
				{
					let ch = p[i];
					if (ch == '>' || ch == ')' || ch == ']')
						d3++;
					else if (ch == '<' || ch == '(' || ch == '[')
						d3--;
					else if (ch.IsWhiteSpace && d3 == 0)
					{
						sp = i;
						break;
					}
				}
				if (sp < 0)
					continue; // a lone word: not readable as type + name, leave it to the compiler
				var type = p.Substring(0, sp);
				type.Trim();
				if (modifier == "params" && !(type.EndsWith("[]") || type.StartsWith("Span<") || type.StartsWith("System.Span<")))
				{
					why.AppendF("'params' is not allowed here: a params parameter is an array or a Span (params {}[]).", type);
					return false;
				}
				if (!Check(type, .Param, sc, why))
					return false;
			}
			return true;
		}

		/// A modifier written on a parameter (the Modifier field of the parameter row).
		public static bool CheckParamModifier(StringView mod, String why)
		{
			why.Clear();
			if (mod.IsEmpty || mod == "ref" || mod == "out" || mod == "in" || mod == "params" || mod == "mut")
				return true;
			why.AppendF("'{}' is not allowed here: a parameter modifier is ref, out, in or params.", mod);
			return false;
		}
	}
}
