using System;
using System.Collections;

namespace VisualBeef.Catalog
{
	/// The pin colour families (UE's palette, adapted to Beef types).
	enum TypeFamily : uint8
	{
		Unknown,   // no type known: grey, connects to anything
		Wildcard,  // a generic parameter (T): grey, takes the type of what it connects to
		Exec,
		Bool,
		Int,
		Float,
		Char,
		String,
		Object,    // classes
		Struct,
		Vector,    // vector/colour-like structs: UE's gold
		Enum,
		Interface,
		Delegate,
		Pointer,
		Void
	}

	/// What the catalog knows about named types (implemented by TypeService).
	interface ITypeHierarchy
	{
		/// "class", "struct", "enum", "interface", "extension"... or "" when the type is unknown.
		void KindOf(StringView typeName, String outKind);
		/// True when `derived` names `baseType` among its base classes or interfaces (transitively).
		bool IsSubtype(StringView derived, StringView baseType);
	}

	enum Conversion : uint8
	{
		/// The types are known to be incompatible.
		Refused,
		/// One side is unknown or generic: allowed, nothing can be checked.
		Unchecked,
		/// Implicit conversion (widening, String -> StringView, subclass -> base).
		Implicit,
		Exact
	}

	/// Type rules that work without the compiler: normalising type text, literal types, Beef's
	/// implicit conversions, generic wildcards and the pin colour of a type. One place, so the
	/// canvas, the action menu and the wire checks agree.
	static class TypeRules
	{
		/// Set by the TypeService so wire checks can see class hierarchies; null = names only.
		public static ITypeHierarchy Hierarchy;

		// ------------------------------------------------------------------ text

		/// Trims, drops parameter modifiers (ref/out/in/params/mut/scope/readonly) and the
		/// `System.` prefix, and removes spaces inside generic argument lists.
		public static void Normalize(StringView type, String outType)
		{
			var t = type;
			t.Trim();
			bool again = true;
			while (again)
			{
				again = false;
				for (let mod in StringView[?]("ref ", "out ", "in ", "params ", "mut ", "scope ", "readonly ", "const "))
				{
					if (t.StartsWith(mod))
					{
						t = t.Substring(mod.Length);
						t.Trim();
						again = true;
					}
				}
			}
			int start = outType.Length;
			for (int i < t.Length)
			{
				let c = t[i];
				if (c.IsWhiteSpace)
				{
					// Keep one space only between two identifier characters ("delegate void").
					int j = i + 1;
					while (j < t.Length && t[j].IsWhiteSpace)
						j++;
					bool prevIdent = outType.Length > start && (outType[outType.Length - 1].IsLetterOrDigit || outType[outType.Length - 1] == '_');
					bool nextIdent = j < t.Length && (t[j].IsLetterOrDigit || t[j] == '_');
					if (prevIdent && nextIdent)
						outType.Append(' ');
					i = j - 1;
					continue;
				}
				outType.Append(c);
			}
			if (outType.Substring(start).StartsWith("System.") && outType.Length - start > 7)
				outType.Remove(start, 7);
		}

		public static bool IsUnknown(StringView t)
		{
			var t;
			t.Trim();
			return t.IsEmpty || t == "var" || t == "let" || t == "?" || t == "decltype" || t.StartsWith("decltype(") ||
				t.StartsWith("comptype(") || t == "Self" || t == "SelfBase";
		}

		/// `T`, `TKey`, `TValue`: a single capital letter, or T followed by a capitalised word.
		/// `declared` is a comma-separated list of the generic parameters in scope.
		public static bool IsGenericParam(StringView t, StringView declared = "")
		{
			var t;
			t.Trim();
			if (t.IsEmpty)
				return false;
			if (!declared.IsEmpty)
			{
				for (var d in declared.Split(','))
				{
					d.Trim();
					if (d == t)
						return true;
				}
			}
			if (t.Length == 1)
				return t[0].IsUpper;
			if (t.Length >= 2 && t[0] == 'T' && t[1].IsUpper)
			{
				for (let c in t.RawChars)
					if (!c.IsLetterOrDigit)
						return false;
				// "TArray", "TMap" are UE container names, not parameters.
				if (t.StartsWith("TArray") || t.StartsWith("TMap") || t.StartsWith("TSet") || t.StartsWith("TSubclass") ||
					t.StartsWith("TWeak") || t.StartsWith("TSoft") || t.StartsWith("TObject") || t.StartsWith("TEnum") ||
					t.StartsWith("TScript") || t.StartsWith("TLazy") || t.StartsWith("TOptional") || t.StartsWith("TFixed"))
					return false;
				return true;
			}
			return false;
		}

		public static bool IsWildcard(StringView t, StringView declared = "") => IsUnknown(t) || IsGenericParam(t, declared);

		/// "List<int>?" -> "List"; "System.Collections.List<T>" -> "List".
		public static StringView BaseName(StringView t)
		{
			var s = t;
			s.Trim();
			int lt = s.IndexOf('<');
			if (lt > 0)
				s = s.Substring(0, lt);
			while (s.EndsWith('?') || s.EndsWith('*'))
				s.RemoveFromEnd(1);
			int br = s.IndexOf('[');
			if (br > 0)
				s = s.Substring(0, br);
			int dot = s.LastIndexOf('.');
			if (dot >= 0)
				s = s.Substring(dot + 1);
			s.Trim();
			return s;
		}

		/// Top-level generic arguments: "Dictionary<String, List<int>>" -> ["String", "List<int>"].
		/// The array part of a type (`[]`, `[,]`, `[4]`; empty for none), outside generic arguments.
		public static StringView ArrayPart(StringView t)
		{
			var s = t;
			s.Trim();
			while (s.EndsWith('?') || s.EndsWith('*'))
				s.RemoveFromEnd(1);
			int gt = s.LastIndexOf('>');
			int br = s.IndexOf('[', Math.Max(gt, 0));
			return (br >= 0) ? s.Substring(br) : "";
		}

		/// Both names are qualified (`UI.Button`, `Physics.Button`) and the qualifiers differ.
		static bool OtherNamespace(StringView a, StringView b)
		{
			StringView Qual(StringView t)
			{
				var s = t;
				int lt = s.IndexOf('<');
				if (lt > 0)
					s = s.Substring(0, lt);
				int dot = s.LastIndexOf('.');
				return (dot > 0) ? s.Substring(0, dot) : "";
			}
			let qa = Qual(a);
			let qb = Qual(b);
			return !qa.IsEmpty && !qb.IsEmpty && qa != qb;
		}

		public static void GenericArgs(StringView t, List<StringView> outArgs)
		{
			int lt = t.IndexOf('<');
			if (lt < 0)
				return;
			int depth = 0;
			int segStart = lt + 1;
			for (int i = lt; i < t.Length; i++)
			{
				let c = t[i];
				if (c == '<' || c == '(' || c == '[')
				{
					depth++;
					continue;
				}
				if (c == '>' || c == ')' || c == ']')
				{
					depth--;
					if (depth == 0)
					{
						var a = t.Substring(segStart, i - segStart);
						a.Trim();
						if (!a.IsEmpty)
							outArgs.Add(a);
						return;
					}
					continue;
				}
				if (c == ',' && depth == 1)
				{
					var a = t.Substring(segStart, i - segStart);
					a.Trim();
					outArgs.Add(a);
					segStart = i + 1;
				}
			}
		}

		/// Replaces whole-word generic parameter names: ("List<T>", {T: int}) -> "List<int>".
		public static void Substitute(StringView t, Dictionary<String, String> map, String outType)
		{
			if (map == null || map.IsEmpty)
			{
				outType.Append(t);
				return;
			}
			int i = 0;
			while (i < t.Length)
			{
				let c = t[i];
				if (c.IsLetter || c == '_')
				{
					int s = i;
					while (i < t.Length && (t[i].IsLetterOrDigit || t[i] == '_'))
						i++;
					let word = t.Substring(s, i - s);
					if (map.TryGetAlt(word, var key, var value))
						outType.Append(value);
					else
						outType.Append(word);
					continue;
				}
				outType.Append(c);
				i++;
			}
		}

		// ------------------------------------------------------------------ primitives

		/// Integer types: size in bytes and signedness. Returns false for non-integers.
		public static bool IntInfo(StringView t, out int size, out bool signed)
		{
			signed = true;
			size = 0;
			switch (t)
			{
			case "int8": size = 1;
			case "int16": size = 2;
			case "int32": size = 4;
			case "int64": size = 8;
			case "int": size = 8;
			case "uint8": size = 1; signed = false;
			case "uint16": size = 2; signed = false;
			case "uint32": size = 4; signed = false;
			case "uint64": size = 8; signed = false;
			case "uint": size = 8; signed = false;
			default: return false;
			}
			return true;
		}

		public static bool IsInt(StringView t) => IntInfo(t, ?, ?);
		public static bool IsFloat(StringView t) => t == "float" || t == "double";
		public static bool IsChar(StringView t) => t == "char8" || t == "char16" || t == "char32";
		public static bool IsNumeric(StringView t) => IsInt(t) || IsFloat(t);
		public static bool IsStringLike(StringView t) => t == "String" || t == "StringView" || t == "char8*";

		public static bool IsPrimitive(StringView t) => IsNumeric(t) || IsChar(t) || t == "bool" || t == "void";

		/// The corlib struct behind a primitive keyword ("int" -> "Int"), for `int.Parse`.
		public static StringView PrimitiveStruct(StringView t)
		{
			switch (t)
			{
			case "int": return "Int";
			case "uint": return "UInt";
			case "int8": return "Int8";
			case "int16": return "Int16";
			case "int32": return "Int32";
			case "int64": return "Int64";
			case "uint8": return "UInt8";
			case "uint16": return "UInt16";
			case "uint32": return "UInt32";
			case "uint64": return "UInt64";
			case "float": return "Float";
			case "double": return "Double";
			case "bool": return "Boolean";
			case "char8": return "Char8";
			case "char16": return "Char16";
			case "char32": return "Char32";
			case "void": return "Void";
			default: return t;
			}
		}

		// ------------------------------------------------------------------ literals

		/// The Beef type of a literal from its text: `1` int, `1.0` double, `1.0f` float,
		/// `1u` uint, `1L` int64, `0xFF` int, `'c'` char8, `"s"`/`$"s"`/`@"s"` String, `true` bool,
		/// `null` "null". Empty when the text isn't a literal.
		public static void LiteralType(StringView text, String outType)
		{
			var t = text;
			t.Trim();
			if (t.IsEmpty)
				return;
			if (t == "true" || t == "false")
			{
				outType.Append("bool");
				return;
			}
			if (t == "null")
			{
				outType.Append("null");
				return;
			}
			let c0 = t[0];
			if (c0 == '"' || ((c0 == '$' || c0 == '@') && t.Length > 1 && (t[1] == '"' || t[1] == '$' || t[1] == '@')))
			{
				outType.Append("String");
				return;
			}
			if (c0 == '\'')
			{
				// '\u{1F600}' does not fit a char8
				if (t.Contains("\\u") || t.Contains("\\U"))
					outType.Append("char32");
				else
					outType.Append("char8");
				return;
			}
			if (!c0.IsDigit && !(c0 == '.' && t.Length > 1 && t[1].IsDigit))
				return;
			String num = scope .();
			for (let c in t.RawChars)
				if (c != '\'' && c != '_')
					num.Append(c);
			num.ToLower();
			bool hex = num.StartsWith("0x");
			bool bin = num.StartsWith("0b");
			bool oct = num.StartsWith("0o");
			if (hex || bin || oct)
			{
				if (num.EndsWith("ul") || num.EndsWith("lu"))
					outType.Append("uint64");
				else if (num.EndsWith('u'))
					outType.Append("uint");
				else if (num.EndsWith('l') && !hex)
					outType.Append("int64");
				else if (num.EndsWith('l') && hex)
					outType.Append("int64");
				else
					outType.Append("int");
				return;
			}
			if (num.EndsWith('f'))
			{
				outType.Append("float");
				return;
			}
			if (num.EndsWith('d'))
			{
				outType.Append("double");
				return;
			}
			if (num.EndsWith("ul") || num.EndsWith("lu"))
			{
				outType.Append("uint64");
				return;
			}
			if (num.EndsWith('u'))
			{
				outType.Append("uint");
				return;
			}
			if (num.EndsWith('l'))
			{
				outType.Append("int64");
				return;
			}
			if (num.Contains('.') || num.Contains('e'))
			{
				outType.Append("double");
				return;
			}
			outType.Append("int");
		}

		// ------------------------------------------------------------------ families and colours

		static bool IsVectorName(StringView b)
		{
			return b.StartsWith("Vector") || b.StartsWith("Vec2") || b.StartsWith("Vec3") || b.StartsWith("Vec4") ||
				b == "Vec" || b.StartsWith("Color") || b.StartsWith("Quat") || b.StartsWith("Rotator") ||
				b == "FVector" || b == "FVector2D" || b == "FVector4" || b == "FRotator" || b == "FLinearColor" ||
				b == "FColor" || b == "FQuat" || b == "FTransform";
		}

		public static TypeFamily Family(StringView type, ITypeHierarchy hierarchy = null)
		{
			let h = (hierarchy != null) ? hierarchy : Hierarchy;
			String t = scope .();
			Normalize(type, t);
			if (t.IsEmpty || IsUnknown(t))
				return .Unknown;
			if (t.EndsWith('?'))
				t.RemoveFromEnd(1);
			if (t == "void")
				return .Void;
			if (t == "bool")
				return .Bool;
			if (IsInt(t))
				return .Int;
			if (IsFloat(t))
				return .Float;
			if (IsChar(t))
				return .Char;
			if (IsStringLike(t) || t == "FString" || t == "FName" || t == "FText")
				return .String;
			if (t.StartsWith("delegate ") || t.StartsWith("delegate") && t.Contains('(') || t.StartsWith("function") ||
				t.StartsWith("Event<") || t.StartsWith("Action<") || t.StartsWith("Func<"))
				return .Delegate;
			if (IsGenericParam(t))
				return .Wildcard;
			let b = BaseName(t);
			if (t.EndsWith('*') && !t.StartsWith("char8"))
			{
				// UE SDK objects are passed as pointers to structs: colour them as objects.
				let inner = StringView(t, 0, t.Length - 1);
				let fam = Family(inner, h);
				if (fam == .Struct || fam == .Object || fam == .Unknown)
				{
					bool ueObject = (b.StartsWith('U') || b.StartsWith('A')) && b.Length > 1 && b[1].IsUpper;
					return ueObject ? TypeFamily.Object : TypeFamily.Pointer;
				}
				return .Pointer;
			}
			if (IsVectorName(b))
				return .Vector;
			if (h != null)
			{
				String kind = scope .();
				h.KindOf(t, kind);
				switch (kind)
				{
				case "enum": return .Enum;
				case "struct": return .Struct;
				case "interface": return .Interface;
				case "class": return .Object;
				case "delegate", "function": return .Delegate;
				default:
				}
			}
			// Unknown name: the same guesses Theme used before there was an index.
			if (b.EndsWith("Kind") || b.EndsWith("Mode") || b.EndsWith("Flags") || (b.Length > 1 && b[0] == 'E' && b[1].IsUpper))
				return .Enum;
			if (b.Length > 1 && b[0] == 'F' && b[1].IsUpper)
				return .Struct;
			return .Object;
		}

		/// ImGui-packed colour (IM_COL32: 0xAABBGGRR) for a family.
		public static uint32 FamilyColor(TypeFamily family)
		{
			uint32 Rgb(uint32 r, uint32 g, uint32 b) => 0xFF000000 | (b << 16) | (g << 8) | r;
			switch (family)
			{
			case .Exec: return Rgb(240, 240, 240);
			case .Bool: return Rgb(146, 0, 0);
			case .Int: return Rgb(31, 227, 175);
			case .Float: return Rgb(160, 250, 68);
			case .Char: return Rgb(206, 120, 255);
			case .String: return Rgb(251, 0, 209);
			case .Object: return Rgb(0, 168, 242);
			case .Struct: return Rgb(0, 87, 200);
			case .Vector: return Rgb(253, 200, 35);
			case .Enum: return Rgb(0, 109, 99);
			case .Interface: return Rgb(238, 252, 168);
			case .Delegate: return Rgb(255, 56, 56);
			case .Pointer: return Rgb(110, 150, 210);
			case .Void: return Rgb(120, 120, 120);
			case .Unknown, .Wildcard: return Rgb(170, 170, 170);
			}
		}

		/// The pin colour for a type name (the single mapping the editor should use).
		public static uint32 PinColor(StringView type, ITypeHierarchy hierarchy = null) => FamilyColor(Family(type, hierarchy));

		// ------------------------------------------------------------------ conversions

		/// The type picker's container row: splits "List<Foo>" / "Foo[]" / "Foo?" into the element type
		/// and a container index (0 single, 1 array, 2 List, 3 nullable). Any other text is a single
		/// type (a `Dictionary<String, int>` typed into the picker stays as typed).
		public static void SplitContainer(StringView type, String outElement, out int32 container)
		{
			var t = type;
			t.Trim();
			container = 0;
			if (t.EndsWith("[]"))
			{
				container = 1;
				t.RemoveFromEnd(2);
			}
			else if (t.StartsWith("List<") && t.EndsWith(">"))
			{
				container = 2;
				t = t.Substring(5, t.Length - 6);
			}
			else if (t.EndsWith("?"))
			{
				container = 3;
				t.RemoveFromEnd(1);
			}
			outElement.Append(t);
		}

		/// The other way: the element type in the container `container` (see SplitContainer).
		public static void JoinContainer(StringView element, int32 container, String outType)
		{
			switch (container)
			{
			case 1: outType.AppendF("{}[]", element);
			case 2: outType.AppendF("List<{}>", element);
			case 3: outType.AppendF("{}?", element);
			default: outType.Append(element);
			}
		}

		/// Can a value of type `from` flow into a pin of type `to` without a cast? On Refused,
		/// `outReason` says why ("float to int needs a cast: it can lose data").
		public static Conversion CanConvert(StringView fromType, StringView toType, String outReason = null, ITypeHierarchy hierarchy = null)
		{
			let h = (hierarchy != null) ? hierarchy : Hierarchy;
			String from = scope .();
			String to = scope .();
			Normalize(fromType, from);
			Normalize(toType, to);
			if (IsWildcard(from) || IsWildcard(to))
				return .Unchecked;
			if (from == to)
				return .Exact;
			if (BaseName(from) == BaseName(to) && !from.Contains('<') && !to.Contains('<') && from.Contains('.') != to.Contains('.'))
				return .Exact; // "System.String" vs "String"

			Conversion Refuse(StringView why)
			{
				outReason?.Set(why);
				return .Refused;
			}

			bool toNullable = to.EndsWith('?');
			bool fromNullable = from.EndsWith('?');
			String toCore = scope .(to);
			String fromCore = scope .(from);
			if (toNullable)
				toCore.RemoveFromEnd(1);
			if (fromNullable)
				fromCore.RemoveFromEnd(1);

			if (from == "null")
			{
				let fam = Family(toCore, h);
				if (toNullable || fam == .Object || fam == .Interface || fam == .Pointer || fam == .Delegate || fam == .String && toCore != "StringView" || fam == .Unknown)
					return .Implicit;
				return Refuse(scope $"null can't be a {to}: it's a value type");
			}
			if (to == "Object" || to == "System.Object")
				return .Implicit; // anything boxes to Object
			if (fromNullable && !toNullable && fromCore == toCore)
				return Refuse(scope $"{from} may be null: use ?? or .Value to get a {to}");
			if (toNullable && fromCore == toCore)
				return .Implicit;

			let fromFam = Family(fromCore, h);
			let toFam = Family(toCore, h);

			if (fromFam == .Void)
				return Refuse("a void call has no value");
			if (fromFam == .Bool || toFam == .Bool)
			{
				if (fromFam == toFam)
					return .Exact;
				if (fromFam == .Unknown || toFam == .Unknown)
					return .Unchecked;
				return Refuse(scope $"{from} is not a bool (use a comparison)");
			}

			// Numbers
			if (IsNumeric(fromCore) || IsChar(fromCore))
			{
				if (IsInt(fromCore) && IsInt(toCore))
				{
					IntInfo(fromCore, var fs, var fsigned);
					IntInfo(toCore, var ts, var tsigned);
					if (fsigned == tsigned && ts >= fs)
						return .Implicit;
					if (!fsigned && tsigned && ts > fs)
						return .Implicit;
					return Refuse(scope $"{from} to {to} needs a cast: it can lose data or sign");
				}
				if (IsInt(fromCore) && IsFloat(toCore))
					return .Implicit;
				if (fromCore == "float" && toCore == "double")
					return .Implicit;
				if (IsFloat(fromCore) && (IsInt(toCore) || toCore == "float"))
					return Refuse(scope $"{from} to {to} needs a cast: it can lose data");
				if (IsChar(fromCore) && IsChar(toCore))
				{
					int CharSize(StringView ct) => (ct == "char8") ? 1 : ((ct == "char16") ? 2 : 4);
					let fs = CharSize(fromCore);
					let ts = CharSize(toCore);
					return (ts >= fs) ? .Implicit : Refuse(scope $"{from} to {to} needs a cast");
				}
				if (IsChar(fromCore) && IsInt(toCore))
					return Refuse(scope $"{from} to {to} needs a cast");
				if (IsInt(fromCore) && IsChar(toCore))
					return Refuse(scope $"{from} to {to} needs a cast");
				if (toFam == .Enum)
					return Refuse(scope $"{from} to the enum {to} needs a cast");
				if (toFam == .String)
					return Refuse(scope $"{from} is not text: format it (\"{{}}\") or call ToString");
				if (toFam == .Unknown)
					return .Unchecked;
				if (toFam == .Struct || toFam == .Object || toFam == .Vector || toFam == .Interface)
				{
					// User structs can declare implicit operators we can't see without the compiler.
					return .Unchecked;
				}
				return Refuse(scope $"{from} can't become a {to}");
			}
			if (IsNumeric(toCore) || IsChar(toCore))
			{
				if (fromFam == .Enum)
					return Refuse(scope $"the enum {from} to {to} needs a cast");
				if (fromFam == .String)
					return Refuse(scope $"text to {to} needs parsing ({PrimitiveStruct(toCore)}.Parse)");
				if (fromFam == .Unknown || fromFam == .Struct || fromFam == .Vector)
					return .Unchecked;
				return Refuse(scope $"{from} can't become a {to}");
			}

			// Text
			if (fromFam == .String && toFam == .String)
			{
				if (toCore == "StringView" || toCore == "char8*")
					return .Implicit;
				if (fromCore == "String" || BaseName(fromCore) == BaseName(toCore))
					return .Implicit;
				if (toCore == "String")
					return Refuse(scope $"{from} to String needs a copy: new String({from}) or .Append");
				return .Unchecked;
			}
			if (toFam == .String && toCore == "StringView" && fromCore == "char8*")
				return .Implicit;

			// Arrays and spans
			if (fromCore.EndsWith("[]") && BaseName(toCore) == "Span")
				return .Implicit;

			// Pointers
			if (fromCore.EndsWith('*') && toCore == "void*")
				return .Implicit;

			// Same generic type: compare arguments loosely (wildcards unify).
			let fb = BaseName(fromCore);
			let tb = BaseName(toCore);
			if (fb == tb && fromCore.EndsWith('*') == toCore.EndsWith('*') && !OtherNamespace(fromCore, toCore))
			{
				// `int[]` vs `int[,]` / `int[4]`: one simple name, different types.
				if (ArrayPart(fromCore) != ArrayPart(toCore))
					return Refuse(scope $"{from} is not a {to}");
				List<StringView> fa = scope .();
				List<StringView> ta = scope .();
				GenericArgs(fromCore, fa);
				GenericArgs(toCore, ta);
				if (fa.Count == ta.Count)
				{
					for (int i < fa.Count)
					{
						let c = CanConvert(fa[i], ta[i], null, h);
						// Generic arguments must match: List<Circle> is not a List<Shape>.
						if (c == .Refused || c == .Implicit && !IsWildcard(ta[i]))
							return Refuse(scope $"{from} is not a {to}");
					}
					return .Implicit;
				}
				return .Unchecked;
			}

			// Class hierarchy and interfaces (pointers to UE objects: compare what they point to)
			StringView fh = fromCore;
			StringView th = toCore;
			if (fh.EndsWith('*') && th.EndsWith('*'))
			{
				fh.RemoveFromEnd(1);
				th.RemoveFromEnd(1);
			}
			if (h != null && h.IsSubtype(fh, th))
				return .Implicit;
			if (fromFam == .Unknown || toFam == .Unknown)
				return .Unchecked;
			if (h != null)
			{
				String fk = scope .();
				String tk = scope .();
				h.KindOf(fh, fk);
				h.KindOf(th, tk);
				if (fk.IsEmpty || tk.IsEmpty)
					return .Unchecked; // one side isn't indexed: can't tell
				if (fromFam == .Struct && toFam == .Interface)
					return .Unchecked; // structs box into interfaces when they implement them
				if (toFam == .Enum || fromFam == .Enum)
					return Refuse(scope $"{from} is not a {to}");
				return Refuse(scope $"{from} is not a {to} (no common base)");
			}
			return .Unchecked;
		}
	}
}
