using System;
using System.Collections;
using VisualBeef.Catalog;
using VisualBeef.Document;

namespace VisualBeef.Graph
{
	/// Which control an unwired input pin shows for its value, by the pin's type
	/// (docs/Editor-UI.md > Pin values).
	enum PinValueKind : uint8
	{
		/// Classes, structs, pointers, functions: wire or Construct only; `null` / `default` shown dim.
		None,
		/// A type that is not known (generic, `var`, not indexed) or a receiver: plain Beef expression text.
		Expr,
		Bool,
		/// A dropdown of the enum's members.
		Enum,
		/// A plain text field; the quotes are added on write and taken off on read.
		Text,
		/// A numeric field that refuses what the type cannot hold.
		Number,
		/// A one-character field, written `'x'`.
		Char,
		/// The pin's current value is not a plain literal of its type (an expression): shown read-only
		/// with a Custom badge, edited as text in Properties.
		Custom
	}

	/// The typed value rules of an unwired input pin, one place for the node canvas and the
	/// Properties panel. The Beef written is exactly what `MemberInit` writes for the same types
	/// (docs/Classes-and-Members.md > Ownership and initial values).
	static class PinValue
	{
		/// The control for a pin of `typeName` holding `def` (the Default text as it is in the source).
		public static PinValueKind KindOf(StringView typeName, StringView defIn, StringView pinName, TypeService types)
		{
			var def = defIn;
			def.Trim();
			if (pinName == "target")
				return .Expr;
			var tn = typeName;
			tn.Trim();
			if (tn.IsEmpty || tn == "var" || tn == "let")
				return .Expr;
			let t = MemberInit.TypeOf(tn, types);
			if (t.IsPointer)
				return IsNothing(def) ? .None : .Custom;
			switch (t.Kind)
			{
			case .Bool:
				return (def.IsEmpty || def == "true" || def == "false") ? .Bool : .Custom;
			case .Enum:
				return (def.IsEmpty || EnumMemberOf(def, t.BaseText, ?)) ? .Enum : .Custom;
			case .String, .StringView:
				return (def.IsEmpty || IsPlainStringLiteral(def)) ? .Text : .Custom;
			case .Integer, .Float:
				return (def.IsEmpty || FormatsAs(def, t.BaseText)) ? .Number : .Custom;
			case .Char:
				return (def.IsEmpty || IsPlainCharLiteral(def)) ? .Char : .Custom;
			case .Class, .Interface, .Struct:
				return IsNothing(def) ? .None : .Custom;
			default:
				return .Expr;
			}
		}

		static bool IsNothing(StringView def) => def.IsEmpty || def == "null" || def == "default";

		static bool FormatsAs(StringView def, StringView typeName)
		{
			String o = scope .();
			return MemberInit.FormatNumber(def, typeName, o);
		}

		static bool IsPlainStringLiteral(StringView def)
		{
			if (!(def.StartsWith('"') || def.StartsWith("@\"")))
				return false;
			String o = scope .();
			return MemberInit.UnquoteLiteral(def, o);
		}

		static bool IsPlainCharLiteral(StringView def)
		{
			if (!def.StartsWith('\''))
				return false;
			String o = scope .();
			if (!MemberInit.UnquoteLiteral(def, o) || o.IsEmpty)
				return false;
			let (cp, len) = StringView(o).GetChar32(0);
			return len > 0 && len == o.Length;
		}

		/// `.Member` or `EnumName.Member` (also `Namespace.EnumName.Member`): the member's name.
		public static bool EnumMemberOf(StringView defIn, StringView enumName, out StringView member)
		{
			member = default;
			var def = defIn;
			def.Trim();
			if (def.StartsWith('.'))
				def.RemoveFromStart(1);
			else
			{
				let dot = def.LastIndexOf('.');
				if (dot <= 0)
					return false;
				let head = def.Substring(0, dot);
				let en = enumName;
				if (!(head == en || head.EndsWith(scope $".{en}") || en.EndsWith(scope $".{head}")))
					return false;
				def.RemoveFromStart(dot + 1);
			}
			if (def.IsEmpty || !(def[0].IsLetter || def[0] == '_'))
				return false;
			for (let c in def)
				if (!(c.IsLetterOrDigit || c == '_'))
					return false;
			member = def;
			return true;
		}

		/// What the field shows for the pin's current value: no quotes for text and characters, the
		/// member name for an enum, no `f` / `d` suffix for a float.
		public static void Display(PinValueKind kind, StringView typeName, StringView defIn, String outText)
		{
			var def = defIn;
			def.Trim();
			switch (kind)
			{
			case .Text, .Char:
				if (!def.IsEmpty && !MemberInit.UnquoteLiteral(def, outText))
					outText.Append(def);
			case .Enum:
				if (EnumMemberOf(def, typeName, let m))
					outText.Append(m);
			case .Number:
				if (!def.IsEmpty && MemberInit.TypeOf(typeName).Kind == .Float && !def.StartsWith("0x") &&
					(def.EndsWith('f') || def.EndsWith('F') || def.EndsWith('d') || def.EndsWith('D')))
					outText.Append(def.Substring(0, def.Length - 1));
				else
					outText.Append(def);
			default:
				outText.Append(def);
			}
		}

		/// The Beef literal for what was typed into the field. False (with the reason in `why`) when the
		/// type cannot hold it; `outLiteral` is untouched then. An empty number or character is allowed
		/// only for an optional pin (it clears the value).
		public static bool Write(PinValueKind kind, StringView typeName, StringView typedIn, bool allowEmpty, String outLiteral, String why)
		{
			var typed = typedIn;
			switch (kind)
			{
			case .Text:
				MemberInit.QuoteString(typed, outLiteral);
				return true;
			case .Char:
				if (typed.IsEmpty && allowEmpty)
					return true;
				return MemberInit.QuoteCharFor(typed, typeName, outLiteral, why);
			case .Number:
				typed.Trim();
				if (typed.IsEmpty)
				{
					if (allowEmpty)
						return true;
					why.Set("Type a number.");
					return false;
				}
				if (MemberInit.FormatNumber(typed, typeName, outLiteral))
					return true;
				NumberWhy(typed, typeName, why);
				return false;
			case .Enum:
				typed.Trim();
				outLiteral.Append('.');
				outLiteral.Append(typed);
				return true;
			case .Bool:
				outLiteral.Append((typed == "true") ? "true" : "false");
				return true;
			default:
				outLiteral.Append(typed);
				return true;
			}
		}

		/// Why a number does not fit the type: not a number, decimals for an integer, out of range.
		public static void NumberWhy(StringView typed, StringView typeName, String why)
		{
			why.Clear();
			if (!TypeRules.IntInfo(typeName, let size, let signed))
			{
				why.AppendF("'{}' is not a number for {}.", typed, typeName);
				return;
			}
			bool allDigits = !typed.IsEmpty;
			for (let c in typed)
				if (!(c.IsDigit || c == '-' || c == '+' || c == '_'))
					allDigits = false;
			if (!allDigits && !MemberInit.ParseInt(typed, ?))
			{
				if (MemberInit.ParseFloat(typed, ?))
					why.AppendF("{} holds whole numbers: no decimals.", typeName);
				else
					why.AppendF("'{}' is not a whole number.", typed);
				return;
			}
			int bits = size * 8;
			if (signed)
			{
				if (bits == 64)
					why.AppendF("{} does not fit {} ({} to {}).", typed, typeName, int64.MinValue, int64.MaxValue);
				else
					why.AppendF("{} does not fit {} ({} to {}).", typed, typeName, -(1L << (bits - 1)), (1L << (bits - 1)) - 1);
			}
			else if (typed.StartsWith('-'))
				why.AppendF("{} cannot be negative ({} holds 0 to {}).", typed, typeName, (bits == 64) ? uint64.MaxValue : (1UL << bits) - 1);
			else
				why.AppendF("{} does not fit {} (0 to {}).", typed, typeName, (bits == 64) ? uint64.MaxValue : (1UL << bits) - 1);
		}

		/// The enum's members (names only, no dot), in declaration order.
		public static void Members(StringView typeName, TypeService types, List<String> outMembers)
		{
			List<String> dotted = scope .();
			defer { ClearAndDeleteItems!(dotted); }
			MemberInit.EnumMembers(typeName, types, dotted);
			for (let d in dotted)
				outMembers.Add(new String(d, 1));
		}
	}
}
