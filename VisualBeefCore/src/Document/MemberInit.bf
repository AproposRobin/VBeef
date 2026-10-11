using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// How a member variable holds what its type refers to (docs/Classes-and-Members.md >
	/// Ownership and initial values). Each choice is one Beef idiom; MemberInit.Emit writes it.
	enum InitOwnership : uint8
	{
		/// A value type (number, bool, character, enum, StringView): nothing to own.
		None,
		/// `= new .(args) ~ delete _`: made with the object, deleted with it.
		OwnedCreatedHere,
		/// `~ delete _`: starts null, set later, deleted with the object.
		OwnedCreatedLater,
		/// Nothing (or `= null`, or a value someone else owns): holds an instance, never deletes it.
		Reference,
		/// `T*`, nothing or `= null`.
		Pointer,
		/// `= append .(args)`: stored inside the object's own memory (instance members of a class).
		Appended,
		/// A struct value: nothing, `= .()`, `= .(args)` or `= default`.
		ValueDefault,
		/// A static member's `= new .(args)` with no destructor: made once, lives for the whole run.
		OwnedForRun,
		/// `~ _.Dispose()` (optionally after `= .(args)`): the object's own Dispose runs when it goes.
		DisposedWith,
		/// Anything else: the text is kept as written.
		Custom
	}

	/// What the initial value is (the part after `=` for values, references and structs).
	enum InitValueKind : uint8
	{
		/// No initializer: the type's zero value (0, false, null, a zeroed struct).
		None,
		/// A number, bool, character or string literal (`5`, `1.5f`, `true`, `'a'`, `"text"`).
		Literal,
		/// An enum member (`.Red`, `Color.Red`).
		EnumCase,
		/// `default`.
		Default,
		/// `null`.
		Null,
		/// A struct value made in place: `.()`, `.(1, 2)`, `Point(1, 2)`.
		Construct,
		/// Any other expression, kept as written.
		Custom
	}

	/// What the member's type is, as far as the choices go.
	enum InitTypeKind : uint8
	{
		Unknown,
		Integer,
		Float,
		Bool,
		Char,
		Enum,
		/// StringView (a struct that takes a string literal).
		StringView,
		/// The String class (owned with its text as the argument, or a reference to a literal).
		String,
		Class,
		Interface,
		Struct
	}

	/// A member's type as the Ownership and Initial value rows see it.
	struct InitType
	{
		public InitTypeKind Kind;
		/// The type text ends in `*`; Kind is then the kind of the type pointed to.
		public bool IsPointer;
		/// The type's text without the `*` of a pointer.
		public StringView BaseText;

		public bool IsValue => Kind == .Integer || Kind == .Float || Kind == .Bool || Kind == .Char || Kind == .Enum || Kind == .StringView;
		public bool IsReferenceType => Kind == .Class || Kind == .String || Kind == .Interface;
	}

	/// The initializer and destructor clause of a member variable (or auto-property) as a
	/// choice plus its parts. Read from text with Classify, written back with Emit: a member
	/// that is classified writes back byte for byte; anything else is Custom with its raw text.
	class MemberInit
	{
		public InitOwnership Owner;
		/// Owned / appended / constructed values: the type after `new` / `append` (`.` when
		/// inferred) and the arguments between the brackets as written.
		public String AllocType = new .(".") ~ delete _;
		public String Args = new .() ~ delete _;
		/// `new int[10]` instead of `new int(10)`.
		public bool ArrayAlloc;
		/// Owned members: what deletes the instance (`delete _`, `DeleteContainerAndItems!(_)`, ...).
		public String Deleter = new .("delete _") ~ delete _;
		public InitValueKind ValueKind;
		/// Literal / enum member / custom expression text, as written.
		public String Value = new .() ~ delete _;
		/// Custom: the text after the name up to the `;`, exactly as in the file.
		public String Raw = new .() ~ delete _;
		/// Custom: what the text means when its spacing is ignored (Convert turns it into that),
		/// or Custom when it cannot be read as one of the choices.
		public InitOwnership ConvertOwner = .Custom;
		/// The spacing before the `=` (or the `~` of an owned-later member), and before the `~`
		/// after a value, as written: aligned declarations keep their columns.
		public String Lead = new .(" ") ~ delete _;
		public String DtorLead = new .(" ") ~ delete _;
		/// The spacing after the `=`, and before the `;`, as written.
		public String AfterEq = new .(" ") ~ delete _;
		public String Trail = new .() ~ delete _;

		/// The destructor texts the Ownership choices offer (other `~ ...` clauses are Custom).
		/// The destructor text of the Disposed with it choice.
		public const String DisposeText = "_.Dispose()";

		public static bool IsDisposeText(StringView text)
		{
			String n = scope .();
			for (let c in text.RawChars)
				if (!c.IsWhiteSpace)
					n.Append(c);
			return n == "_.Dispose()";
		}

		public static String[?] Deleters = .("delete _", "DeleteContainerAndItems!(_)", "DeleteDictionaryAndKeys!(_)",
			"DeleteDictionaryAndValues!(_)", "DeleteDictionaryAndKeysAndValues!(_)");

		/// Which of Deleters a destructor text is, ignoring spaces and `delete(_)` brackets; -1
		/// for any other text.
		public static int DeleterIndex(StringView text)
		{
			String n = scope .();
			for (let c in text.RawChars)
				if (!c.IsWhiteSpace)
					n.Append(c);
			if (n == "delete(_)" || n == "delete_")
				return 0;
			for (int i < Deleters.Count)
			{
				String d = scope .(Deleters[i]);
				d.Replace(" ", "");
				if (n == d)
					return i;
			}
			return -1;
		}

		public bool CanConvert => Owner == .Custom && ConvertOwner != .Custom;

		public void Set(MemberInit other)
		{
			Owner = other.Owner;
			AllocType.Set(other.AllocType);
			Args.Set(other.Args);
			ArrayAlloc = other.ArrayAlloc;
			Deleter.Set(other.Deleter);
			ValueKind = other.ValueKind;
			Value.Set(other.Value);
			Raw.Set(other.Raw);
			ConvertOwner = other.ConvertOwner;
			Lead.Set(other.Lead);
			DtorLead.Set(other.DtorLead);
			AfterEq.Set(other.AfterEq);
			Trail.Set(other.Trail);
		}

		void Reset()
		{
			Owner = .None;
			AllocType.Set(".");
			Args.Clear();
			ArrayAlloc = false;
			Deleter.Set("delete _");
			ValueKind = .None;
			Value.Clear();
			Raw.Clear();
			ConvertOwner = .Custom;
			ResetSpacing();
		}

		/// The usual spacing: ` = value ~ delete _`.
		public void ResetSpacing()
		{
			Lead.Set(" ");
			DtorLead.Set(" ");
			AfterEq.Set(" ");
			Trail.Clear();
		}

		/// Turns a Custom member whose text only differs in spacing into its choice.
		public bool Convert()
		{
			if (!CanConvert)
				return false;
			Owner = ConvertOwner;
			ConvertOwner = .Custom;
			Raw.Clear();
			ResetSpacing();
			let di = DeleterIndex(Deleter);
			if (Owner == .DisposedWith)
				Deleter.Set(DisposeText);
			else
				Deleter.Set((di >= 0) ? Deleters[di] : "delete _");
			return true;
		}

		// ------------------------------------------------------------------ type kinds

		/// The kind of a member's type. With a TypeService, project and library types resolve;
		/// without one, only built-in types and a few corlib names are known.
		public static InitType TypeOf(StringView typeTextIn, TypeService types = null)
		{
			InitType t = .();
			var text = typeTextIn;
			text.Trim();
			if (text.EndsWith('*'))
			{
				t.IsPointer = true;
				text.RemoveFromEnd(1);
				text.Trim();
			}
			t.BaseText = text;
			if (text.IsEmpty)
				return t;
			if (text.EndsWith('?') || text.StartsWith('('))
				t.Kind = .Struct;
			else if (text.EndsWith(']'))
			{
				// `int[]` / `int[,]` are arrays (classes); `int[4]` is a fixed-size value.
				int open = text.LastIndexOf('[');
				let inside = text.Substring(open + 1, text.Length - open - 2);
				bool sized = false;
				for (let c in inside)
					if (c != ',' && c != ' ')
						sized = true;
				t.Kind = sized ? .Struct : .Class;
			}
			else if (TypeRules.IsInt(text))
				t.Kind = .Integer;
			else if (TypeRules.IsFloat(text))
				t.Kind = .Float;
			else if (text == "bool")
				t.Kind = .Bool;
			else if (TypeRules.IsChar(text))
				t.Kind = .Char;
			else if (text == "String" || text == "System.String")
				t.Kind = .String;
			else if (text == "StringView" || text == "System.StringView")
				t.Kind = .StringView;
			else if (text.StartsWith("delegate ") || text.StartsWith("Event<"))
				t.Kind = text.StartsWith("Event<") ? .Struct : .Class;
			else if (text.StartsWith("function "))
				t.Kind = .Struct;
			else
			{
				String kind = scope .();
				if (types != null)
					types.KindOf(text, kind);
				if (kind.IsEmpty)
				{
					// Without an index: the corlib containers everyone uses.
					let baseName = TypeRules.BaseName(text);
					if (baseName == "List" || baseName == "Dictionary" || baseName == "HashSet" || baseName == "Queue" ||
						baseName == "Object" || baseName == "Thread" || baseName == "Monitor" || baseName == "Random")
						kind.Set("class");
				}
				switch (kind)
				{
				case "class": t.Kind = .Class;
				case "interface": t.Kind = .Interface;
				case "struct": t.Kind = .Struct;
				case "enum": t.Kind = .Enum;
				case "delegate", "function": t.Kind = .Class;
				default: t.Kind = .Unknown;
				}
			}
			return t;
		}

		/// The Ownership choices legal for a type, in menu order. `inClass` is false for a member of
		/// a struct (no `append` there), `isStatic` for a static member (no `append` either).
		public static void Choices(InitType type, bool inClass, bool isStatic, List<InitOwnership> outChoices)
		{
			bool canAppend = inClass && !isStatic;
			switch (type.Kind)
			{
			case .Class, .String:
				outChoices.Add(.OwnedCreatedHere);
				outChoices.Add(.OwnedCreatedLater);
				if (isStatic)
					outChoices.Add(.OwnedForRun);
				outChoices.Add(.Reference);
				if (canAppend)
					outChoices.Add(.Appended);
				if (type.Kind == .Class)
					outChoices.Add(.DisposedWith);
				outChoices.Add(.Pointer);
			case .Interface:
				outChoices.Add(.Reference);
				outChoices.Add(.Pointer);
			case .Struct:
				outChoices.Add(.ValueDefault);
				outChoices.Add(.DisposedWith);
				outChoices.Add(.Pointer);
			case .Unknown:
				outChoices.Add(.OwnedCreatedHere);
				outChoices.Add(.OwnedCreatedLater);
				if (isStatic)
					outChoices.Add(.OwnedForRun);
				outChoices.Add(.Reference);
				if (canAppend)
					outChoices.Add(.Appended);
				outChoices.Add(.ValueDefault);
				outChoices.Add(.DisposedWith);
				outChoices.Add(.Pointer);
			default:
				// Value types: a value, or a pointer to one.
				outChoices.Add(.None);
				outChoices.Add(.Pointer);
			}
		}

		/// The label of a choice in the Ownership select.
		public static StringView Label(InitOwnership o, InitType type = .())
		{
			switch (o)
			{
			case .None: return "Value";
			case .OwnedCreatedHere: return "Owned, made here";
			case .OwnedCreatedLater: return "Owned, set later";
			case .Reference: return "Reference";
			case .Pointer: return "Pointer";
			case .Appended: return "Appended";
			case .OwnedForRun: return "Owned for the run";
			case .DisposedWith: return "Disposed with it";
			case .ValueDefault: return "Value";
			case .Custom: return "Custom";
			}
		}

		/// One line explaining a choice (the tooltip of the select).
		public static StringView Explain(InitOwnership o)
		{
			switch (o)
			{
			case .None: return "A value: copied, nothing to delete.";
			case .OwnedCreatedHere: return "Made together with the object and deleted with it.";
			case .OwnedCreatedLater: return "Starts as null; when you set it, the object deletes it at the end.";
			case .Reference: return "Holds an instance that something else owns; never deleted here.";
			case .Pointer: return "An address (T*): nothing is made or deleted here.";
			case .Appended: return "Stored inside this object's memory, made and destroyed with it.";
			case .OwnedForRun: return "Made once for the whole run of the program and never deleted.";
			case .DisposedWith: return "When the object goes, this value's Dispose() runs (~ _.Dispose()).";
			case .ValueDefault: return "A struct value stored in place.";
			case .Custom: return "Written by hand: kept exactly as it is.";
			}
		}

		/// The member's type text for a choice: Pointer adds the `*`, every other choice removes it
		/// (Custom keeps the type as it is).
		public static void TypeFor(InitOwnership o, StringView typeTextIn, String outType)
		{
			var t = typeTextIn;
			t.Trim();
			if (o == .Custom)
			{
				outType.Append(t);
				return;
			}
			bool ptr = t.EndsWith('*');
			if (o == .Pointer && !ptr)
				outType.AppendF("{}*", t);
			else if (o != .Pointer && ptr)
			{
				t.RemoveFromEnd(1);
				t.Trim();
				outType.Append(t);
			}
			else
				outType.Append(t);
		}

		/// Changes the choice, keeping what still applies (arguments, a literal that becomes
		/// a String's text, the deleter).
		public void Retarget(InitOwnership o, InitType type)
		{
			if (o == Owner)
				return;
			let oldOwner = Owner;
			let oldKind = ValueKind;
			String oldValue = scope .(Value);
			Owner = o;
			Raw.Clear();
			ConvertOwner = .Custom;
			switch (o)
			{
			case .OwnedCreatedHere, .Appended, .OwnedForRun:
				if (oldOwner != .OwnedCreatedHere && oldOwner != .Appended && oldOwner != .OwnedForRun)
				{
					AllocType.Set(".");
					ArrayAlloc = false;
					Args.Clear();
					// A String reference to a literal becomes an owned String with that text.
					if (type.Kind == .String && oldKind == .Literal && oldValue.StartsWith('"'))
						Args.Set(oldValue);
				}
				ValueKind = .None;
				Value.Clear();
			case .OwnedCreatedLater:
				ValueKind = .None;
				Value.Clear();
			case .Reference, .Pointer:
				// An owned String's text stays as a literal the reference points at.
				if (o == .Reference && type.Kind == .String && oldOwner == .OwnedCreatedHere && Args.StartsWith('"') && IsSingleStringLiteral(Args))
				{
					ValueKind = .Literal;
					Value.Set(Args);
				}
				else if (oldKind == .Null)
					ValueKind = .Null;
				else
				{
					ValueKind = .None;
					Value.Clear();
				}
			case .DisposedWith:
				if (oldOwner != .ValueDefault)
				{
					ValueKind = .None;
					Value.Clear();
				}
			case .ValueDefault, .None:
				if (oldOwner != .DisposedWith)
				{
					ValueKind = .None;
					Value.Clear();
				}
			case .Custom:
			}
			if (o == .DisposedWith)
				Deleter.Set(DisposeText);
			else if ((o != .OwnedCreatedHere && o != .OwnedCreatedLater) || oldOwner == .DisposedWith)
				Deleter.Set("delete _");
		}

		public static bool IsSingleStringLiteral(StringView text)
		{
			List<Token> toks = scope .();
			Lexer.Tokenize(text, toks);
			int n = 0;
			for (let t in toks)
				if (t.Kind != .EOF)
					n++;
			return n == 1 && toks[0].Kind == .String && text.StartsWith('"');
		}

		// ------------------------------------------------------------------ emission

		/// The text after the member's name up to its `;`: ` = new .() ~ delete _`, ` = 5`, ``.
		public void Emit(String outTail)
		{
			int startLen = outTail.Length;
			switch (Owner)
			{
			case .Custom:
				outTail.Append(Raw);
			case .OwnedCreatedHere:
				outTail.AppendF("{}={}new ", Lead, AfterEq);
				AppendAlloc(outTail);
				outTail.AppendF("{}~ {}", DtorLead, Deleter);
			case .OwnedCreatedLater:
				if (ValueKind == .Null)
					outTail.AppendF("{}={}null{}~ {}", Lead, AfterEq, DtorLead, Deleter);
				else
					outTail.AppendF("{}~ {}", Lead, Deleter);
			case .Appended:
				outTail.AppendF("{}={}append ", Lead, AfterEq);
				AppendAlloc(outTail);
			case .OwnedForRun:
				outTail.AppendF("{}={}new ", Lead, AfterEq);
				AppendAlloc(outTail);
			case .DisposedWith:
				if (ValueKind == .None)
					outTail.AppendF("{}~ {}", Lead, Deleter);
				else
				{
					EmitValue(outTail);
					outTail.AppendF("{}~ {}", DtorLead, Deleter);
				}
			default:
				EmitValue(outTail);
			}
			if (Owner != .Custom && outTail.Length > startLen)
				outTail.Append(Trail);
		}

		void AppendAlloc(String o)
		{
			o.Append(AllocType);
			o.Append(ArrayAlloc ? "[" : "(");
			o.Append(Args);
			o.Append(ArrayAlloc ? "]" : ")");
		}

		void EmitValue(String o)
		{
			switch (ValueKind)
			{
			case .None:
			case .Default: o.AppendF("{}={}default", Lead, AfterEq);
			case .Null: o.AppendF("{}={}null", Lead, AfterEq);
			case .Construct:
				o.AppendF("{}={}", Lead, AfterEq);
				AppendAlloc(o);
			case .Literal, .EnumCase, .Custom:
				o.AppendF("{}={}", Lead, AfterEq);
				o.Append(Value);
			}
		}

		/// The whole declaration as the user learns it: `Application mApp = new .() ~ delete _;`.
		public void Preview(StringView typeText, StringView name, String outText)
		{
			outText.AppendF("{} {}", typeText, name);
			Emit(outText);
			outText.Append(';');
		}

		// ------------------------------------------------------------------ reading

		/// Reads the text after a member's name (up to, not including, its `;`). Always succeeds:
		/// what is not exactly one of the choices (spacing included) is Custom, with ConvertOwner
		/// set when it is one of them apart from spacing.
		public void Classify(StringView tail, InitType type, bool isStatic = false)
		{
			Reset();
			if (Read(tail, type, isStatic))
			{
				String emitted = scope .();
				Emit(emitted);
				if (emitted == tail)
					return;
				ConvertOwner = Owner;
			}
			else
				ConvertOwner = .Custom;
			Owner = .Custom;
			Raw.Set(tail);
		}

		/// Reads a value on its own (a local's initial value, the text after `=`): "" is None.
		public void ClassifyValue(StringView exprIn, InitType type)
		{
			var expr = exprIn;
			expr.Trim();
			if (expr.IsEmpty)
				Classify("", type);
			else
				Classify(scope String()..AppendF(" = {}", expr), type);
		}

		/// The text after the `=` that Emit writes, without a destructor clause ("" when none).
		public void ValueText(String outText)
		{
			String t = scope .();
			Emit(t);
			int eq = t.IndexOf('=');
			if (eq < 0)
				return;
			int tilde = (Owner == .OwnedCreatedHere || Owner == .OwnedCreatedLater || Owner == .DisposedWith) ? t.LastIndexOf('~') : -1;
			var v = (tilde > eq) ? StringView(t, eq + 1, tilde - eq - 1) : StringView(t, eq + 1);
			v.Trim();
			outText.Append(v);
		}

		/// Reads the structure ignoring spacing; false when the text is none of the choices.
		bool Read(StringView tail, InitType type, bool isStatic)
		{
			List<Token> all = scope .();
			Lexer.Tokenize(tail, all);
			List<Token> toks = scope .();
			for (let t in all)
				if (t.Kind != .EOF)
					toks.Add(t);
			// Comments or preprocessor lines inside the clause are kept as written.
			for (let t in toks)
				if (HasNonSpace(tail, t.LeadStart, t.Start) || HasNonSpace(tail, t.End, t.TrailEnd))
					return false;
			if (toks.IsEmpty)
				return SetPlain(type, .None, "");
			StringView T(int i) => StringView(tail, toks[i].Start, toks[i].End - toks[i].Start);
			Lead.Set(StringView(tail, 0, toks[0].Start));
			Trail.Set(StringView(tail, toks[toks.Count - 1].End));
			if (toks.Count > 1 && StringView(tail, toks[0].Start, 1) == "=")
				AfterEq.Set(StringView(tail, toks[0].End, toks[1].Start - toks[0].End));

			int i = 0;
			int valueFirst = -1, valueLast = -1;
			if (T(0) == "=")
			{
				i = 1;
				valueFirst = 1;
			}
			else if (T(0) != "~")
				return false;
			// The destructor `~`: at depth 0, after a complete value.
			int depth = 0;
			int tilde = -1;
			for (int k = i; k < toks.Count; k++)
			{
				let tx = T(k);
				if (tx == "(" || tx == "[" || tx == "{")
					depth++;
				else if (tx == ")" || tx == "]" || tx == "}")
				{
					depth--;
					if (depth < 0)
						return false;
				}
				else if (depth == 0 && tx == ",")
					return false; // `int a = 1, b;`
				else if (depth == 0 && tx == "~" && (k == 0 || EndsValue(toks[k - 1].Kind, T(k - 1))))
				{
					tilde = k;
					break;
				}
			}
			if (depth != 0 && tilde < 0)
				return false;
			if (valueFirst >= 0)
			{
				valueLast = (tilde >= 0) ? tilde - 1 : toks.Count - 1;
				if (valueLast < valueFirst)
					return false;
			}
			if (tilde >= 0)
			{
				if (tilde + 1 >= toks.Count)
					return false;
				let del = StringView(tail, toks[tilde + 1].Start, toks[toks.Count - 1].End - toks[tilde + 1].Start);
				bool dispose = IsDisposeText(del);
				if (DeleterIndex(del) < 0 && !dispose)
					return false;
				Deleter.Set(del);
				if (tilde > 0)
					DtorLead.Set(StringView(tail, toks[tilde - 1].End, toks[tilde].Start - toks[tilde - 1].End));
				if (dispose)
				{
					// `~ _.Dispose()` alone, or after a value made in place.
					if (valueFirst >= 0 && (T(valueFirst) == "new" || T(valueFirst) == "append"))
						return false;
					if (valueFirst >= 0 && !ReadValueExpr(tail, toks, valueFirst, valueLast, type))
						return false;
					Owner = .DisposedWith;
					return true;
				}
				if (valueFirst < 0)
				{
					Owner = .OwnedCreatedLater;
					return true;
				}
				if (valueFirst == valueLast && T(valueFirst) == "null")
				{
					// `= null ~ delete _`: the same as created later, with the null written out.
					Owner = .OwnedCreatedLater;
					ValueKind = .Null;
					return true;
				}
				if (T(valueFirst) != "new" || !ReadAlloc(tail, toks, valueFirst + 1, valueLast))
					return false;
				Owner = .OwnedCreatedHere;
				return true;
			}
			if (valueFirst < 0)
				return false;
			let first = T(valueFirst);
			if (first == "new")
			{
				// A static member made once and never deleted; for an instance member it is a leak: Custom.
				if (isStatic && !type.IsPointer && ReadAlloc(tail, toks, valueFirst + 1, valueLast))
				{
					Owner = .OwnedForRun;
					return true;
				}
				return false;
			}
			if (first == "append")
			{
				if (!ReadAlloc(tail, toks, valueFirst + 1, valueLast))
					return false;
				Owner = .Appended;
				return true;
			}
			return ReadValueExpr(tail, toks, valueFirst, valueLast, type);
		}

		/// The value after `=`: a struct made in place, or a plain value (sets Owner from the type).
		bool ReadValueExpr(StringView tail, List<Token> toks, int valueFirst, int valueLast, InitType type)
		{
			StringView T(int i) => StringView(tail, toks[i].Start, toks[i].End - toks[i].Start);
			let first = T(valueFirst);
			let valueText = StringView(tail, toks[valueFirst].Start, toks[valueLast].End - toks[valueFirst].Start);
			// `.(args)` / `Point(args)`: a struct value made in place.
			bool dotCtor = first == "." && valueFirst + 1 <= valueLast && T(valueFirst + 1) == "(";
			bool namedCtor = type.Kind == .Struct && !type.BaseText.IsEmpty && valueText.StartsWith(type.BaseText) &&
				valueText.Length > type.BaseText.Length && valueText[type.BaseText.Length] == '(';
			if (dotCtor || namedCtor)
			{
				if (ReadAlloc(tail, toks, valueFirst, valueLast) && !ArrayAlloc && !type.IsPointer &&
					(type.Kind == .Struct || type.Kind == .Unknown))
				{
					Owner = .ValueDefault;
					ValueKind = .Construct;
					return true;
				}
				AllocType.Set(".");
				Args.Clear();
				ArrayAlloc = false;
			}
			return SetPlain(type, ValueKindOf(tail, toks, valueFirst, valueLast, type), valueText);
		}

		static bool HasNonSpace(StringView text, int start, int end)
		{
			for (int i = start; i < end; i++)
				if (!text[i].IsWhiteSpace)
					return true;
			return false;
		}

		static bool EndsValue(TokenKind kind, StringView text)
		{
			if (kind == .Identifier || kind == .Number || kind == .String || kind == .Char)
				return true;
			return text == ")" || text == "]" || text == "}" || text == ">";
		}

		/// `Type(args)` / `.(args)` / `int[10]` spanning toks[first..last] exactly.
		bool ReadAlloc(StringView tail, List<Token> toks, int first, int last)
		{
			if (first > last)
				return false;
			StringView T(int i) => StringView(tail, toks[i].Start, toks[i].End - toks[i].Start);
			// The type: up to the first '(' / '[' outside generic arguments.
			int angle = 0;
			int open = -1;
			for (int k = first; k <= last; k++)
			{
				let tx = T(k);
				if (tx == "<") angle++;
				else if (tx == ">") angle--;
				else if (angle == 0 && (tx == "(" || tx == "["))
				{
					open = k;
					break;
				}
			}
			if (open <= first || T(last) != ((T(open) == "(") ? ")" : "]"))
				return false;
			// The bracket must close at `last`.
			int depth = 0;
			for (int k = open; k <= last; k++)
			{
				let tx = T(k);
				if (tx == "(" || tx == "[" || tx == "{") depth++;
				else if (tx == ")" || tx == "]" || tx == "}")
				{
					depth--;
					if (depth == 0 && k != last)
						return false;
				}
			}
			AllocType.Set(StringView(tail, toks[first].Start, toks[open - 1].End - toks[first].Start));
			ArrayAlloc = T(open) == "[";
			int argStart = toks[open].End;
			int argEnd = toks[last].Start;
			Args.Set(StringView(tail, argStart, argEnd - argStart));
			// `new .[10]` style inferred arrays and `new :alloc` forms stay as written.
			if (AllocType.Contains(':'))
				return false;
			return true;
		}

		InitValueKind ValueKindOf(StringView tail, List<Token> toks, int first, int last, InitType type)
		{
			StringView T(int i) => StringView(tail, toks[i].Start, toks[i].End - toks[i].Start);
			int n = last - first + 1;
			let f = T(first);
			if (n == 1)
			{
				if (f == "null") return .Null;
				if (f == "default") return .Default;
				if (f == "true" || f == "false") return .Literal;
				let k = toks[first].Kind;
				if (k == .Number || k == .Char)
					return .Literal;
				if (k == .String)
				{
					// Plain and verbatim strings; interpolated ones are expressions.
					return (f.StartsWith('"') || f.StartsWith("@\"")) ? .Literal : .Custom;
				}
				return .Custom;
			}
			if (n == 2 && (f == "-" || f == "+") && toks[last].Kind == .Number)
				return .Literal;
			if (n == 2 && f == "." && toks[last].Kind == .Identifier)
				return .EnumCase;
			if (n == 3 && toks[first].Kind == .Identifier && T(first + 1) == "." && toks[last].Kind == .Identifier && f == type.BaseText && type.Kind == .Enum)
				return .EnumCase;
			return .Custom;
		}

		/// No allocation: the owner follows from the type, the value from the text.
		bool SetPlain(InitType type, InitValueKind kind, StringView valueText)
		{
			ValueKind = kind;
			if (kind == .Literal || kind == .EnumCase || kind == .Custom)
				Value.Set(valueText);
			if (type.IsPointer)
				Owner = .Pointer;
			else if (type.IsReferenceType)
				Owner = .Reference;
			else if (type.Kind == .Struct)
				Owner = .ValueDefault;
			else if (type.Kind == .Unknown)
				Owner = (kind == .Null) ? .Reference : .None;
			else
				Owner = .None;
			return true;
		}

		// ------------------------------------------------------------------ literals

		/// A number typed in the Initial value box, written for the member's type: integers as
		/// they are, `1.5f` / `2.0f` for float, `1.5` / `2.0` for double. False when it is not a number.
		public static bool FormatNumber(StringView typedIn, StringView typeText, String outLiteral)
		{
			var typed = typedIn;
			typed.Trim();
			if (typed.IsEmpty)
				return false;
			if (TypeRules.IntInfo(typeText, let size, let signed))
			{
				// The magnitude and sign, checked against the type's range (300 is not a uint8).
				if (!ParseIntParts(typed, let neg, let mag))
					return false;
				int bits = size * 8;
				if (!signed)
				{
					if (neg && mag != 0)
						return false;
					if (bits < 64 && mag > (1UL << bits) - 1)
						return false;
					mag.ToString(outLiteral);
					return true;
				}
				uint64 limit = 1UL << (bits - 1); // -limit .. limit - 1
				if (neg ? (mag > limit) : (mag >= limit))
					return false;
				if (neg && mag != 0)
					outLiteral.Append('-');
				mag.ToString(outLiteral);
				return true;
			}
			if (!ParseFloat(typed, let d))
				return false;
			FormatFloat(d, typeText == "float", outLiteral);
			return true;
		}

		public static void FormatFloat(double d, bool isFloat, String outLiteral)
		{
			String s = scope .();
			if (isFloat)
				((float)d).ToString(s);
			else
				d.ToString(s);
			if (s.Contains("E"))
				s.Replace("E", "e");
			if (!s.Contains('.') && !s.Contains('e') && !s.Contains("Inf") && !s.Contains("NaN"))
				s.Append(".0");
			outLiteral.Append(s);
			if (isFloat)
				outLiteral.Append('f');
		}

		/// An integer literal's value: decimal, `0x` hex, `0b` binary, `'_'` separators, a sign,
		/// and the `u` / `L` / `UL` suffixes.
		public static bool ParseInt(StringView textIn, out int64 value)
		{
			value = 0;
			if (!ParseIntParts(textIn, let neg, let acc))
				return false;
			value = neg ? -(int64)acc : (int64)acc;
			return true;
		}

		/// An integer literal's sign and magnitude; false for anything else or above 2^64 - 1.
		static bool ParseIntParts(StringView textIn, out bool neg, out uint64 acc)
		{
			neg = false;
			acc = 0;
			var text = textIn;
			text.Trim();
			if (text.StartsWith('-') || text.StartsWith('+'))
			{
				neg = text[0] == '-';
				text.RemoveFromStart(1);
				text.Trim();
			}
			while (!text.IsEmpty && (text.EndsWith('u') || text.EndsWith('U') || text.EndsWith('l') || text.EndsWith('L')))
				text.RemoveFromEnd(1);
			if (text.IsEmpty)
				return false;
			int radix = 10;
			if (text.StartsWith("0x") || text.StartsWith("0X"))
			{
				radix = 16;
				text.RemoveFromStart(2);
			}
			else if (text.StartsWith("0b") || text.StartsWith("0B"))
			{
				radix = 2;
				text.RemoveFromStart(2);
			}
			if (text.IsEmpty)
				return false;
			for (let c in text)
			{
				if (c == '_' || c == '\'')
					continue;
				int digit;
				if (c >= '0' && c <= '9') digit = c - '0';
				else if (c >= 'a' && c <= 'f') digit = c - 'a' + 10;
				else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
				else return false;
				if (digit >= radix)
					return false;
				if (acc > (uint64.MaxValue - (uint64)digit) / (uint64)radix)
					return false; // above 2^64 - 1
				acc = acc * (uint64)radix + (uint64)digit;
			}
			return true;
		}

		/// A float literal's value (`1.5f`, `2`, `1e3`, `-0.5d`).
		public static bool ParseFloat(StringView textIn, out double value)
		{
			value = 0;
			var text = scope String(textIn);
			text.Trim();
			if (text.EndsWith('f') || text.EndsWith('F') || text.EndsWith('d') || text.EndsWith('D'))
				text.RemoveFromEnd(1);
			if (text.IsEmpty)
				return false;
			for (let c in text.RawChars)
				if (!(c.IsDigit || c == '.' || c == '-' || c == '+' || c == 'e' || c == 'E'))
					return false;
			if (double.Parse(text) case .Ok(let d))
			{
				value = d;
				return true;
			}
			return false;
		}

		/// `"text"` with Beef escapes for `\`, `"`, line breaks, tabs and other control characters.
		public static void QuoteString(StringView text, String outLiteral)
		{
			outLiteral.Append('"');
			for (let c in text)
				AppendEscaped(c, '"', outLiteral);
			outLiteral.Append('"');
		}

		/// `'a'`, `'\n'`, `'\''`.
		public static void QuoteChar(char8 c, String outLiteral)
		{
			outLiteral.Append('\'');
			AppendEscaped(c, '\'', outLiteral);
			outLiteral.Append('\'');
		}

		/// The literal for what a user typed into a character box: exactly one code point (not one
		/// byte), and one the type holds as Beef checks it: char8 up to U+00FF, char16 up to U+FFFF
		/// (no surrogate pair), char32 any scalar value. False with the reason in `why`.
		public static bool QuoteCharFor(StringView text, StringView typeName, String outLiteral, String why)
		{
			if (text.IsEmpty)
			{
				why.Set("Type one character.");
				return false;
			}
			let (cp, len) = text.GetChar32(0);
			if (len <= 0)
			{
				why.Set("That is not valid UTF-8 text.");
				return false;
			}
			if (len < text.Length)
			{
				why.Set("A character value is one character.");
				return false;
			}
			int32 max = (typeName == "char32") ? 0x10FFFF : (typeName == "char16") ? 0xFFFF : 0xFF;
			if ((int32)cp > max || ((int32)cp >= 0xD800 && (int32)cp <= 0xDFFF))
			{
				why.Set(scope $"'{text}' does not fit {typeName} (U+{(int32)cp:X4}); {typeName} holds up to U+{max:X4}.{(typeName != "char32") ? " Use char32 for it." : ""}");
				return false;
			}
			if ((int32)cp < 0x80)
				QuoteChar((char8)cp, outLiteral);
			else
			{
				outLiteral.Append('\'');
				outLiteral.Append(cp);
				outLiteral.Append('\'');
			}
			return true;
		}

		static void AppendEscaped(char8 c, char8 quote, String o)
		{
			switch (c)
			{
			case '\\': o.Append("\\\\");
			case '\n': o.Append("\\n");
			case '\r': o.Append("\\r");
			case '\t': o.Append("\\t");
			case '\0': o.Append("\\0");
			default:
				if (c == quote)
				{
					o.Append('\\');
					o.Append(c);
				}
				else if ((uint8)c < 0x20)
					o.AppendF("\\x{0:X2}", (uint8)c);
				else
					o.Append(c);
			}
		}

		/// The text of a `"..."` / `@"..."` / `'x'` literal with its escapes resolved (what the
		/// text box shows). False for anything else (interpolated strings included).
		public static bool UnquoteLiteral(StringView lit, String outText)
		{
			if (lit.StartsWith("@\"") && lit.EndsWith('"') && lit.Length >= 3)
			{
				let inner = lit.Substring(2, lit.Length - 3);
				for (int i = 0; i < inner.Length; i++)
				{
					outText.Append(inner[i]);
					if (inner[i] == '"' && i + 1 < inner.Length && inner[i + 1] == '"')
						i++;
				}
				return true;
			}
			char8 q;
			if (lit.Length >= 2 && lit[0] == '"' && lit[lit.Length - 1] == '"')
				q = '"';
			else if (lit.Length >= 3 && lit[0] == '\'' && lit[lit.Length - 1] == '\'')
				q = '\'';
			else
				return false;
			let inner = lit.Substring(1, lit.Length - 2);
			for (int i = 0; i < inner.Length; i++)
			{
				let c = inner[i];
				if (c != '\\' || i + 1 >= inner.Length)
				{
					outText.Append(c);
					continue;
				}
				i++;
				switch (inner[i])
				{
				case 'n': outText.Append('\n');
				case 'r': outText.Append('\r');
				case 't': outText.Append('\t');
				case '0': outText.Append('\0');
				case 'a': outText.Append('\a');
				case 'b': outText.Append('\b');
				case 'f': outText.Append('\f');
				case 'v': outText.Append('\v');
				case 'x':
					int len = 0;
					while (len < 2 && i + 1 + len < inner.Length && IsHex(inner[i + 1 + len]))
						len++;
					if (len == 0)
						return false;
					int64 v = 0;
					if (!ParseInt(scope $"0x{inner.Substring(i + 1, len)}", out v))
						return false;
					outText.Append((char8)(uint8)v);
					i += len;
				case 'u':
					// `\u{E9}`: a code point, written to the text as UTF-8.
					if (i + 2 >= inner.Length || inner[i + 1] != '{')
						return false;
					let close = inner.IndexOf('}', i + 2);
					if (close < 0 || close == i + 2 || close - (i + 2) > 6)
						return false;
					for (int h = i + 2; h < close; h++)
						if (!IsHex(inner[h]))
							return false;
					int64 cp = 0;
					if (!ParseInt(scope $"0x{inner.Substring(i + 2, close - (i + 2))}", out cp) || cp > 0x10FFFF)
						return false;
					outText.Append((char32)cp);
					i = close;
				case '"', '\'', '\\': outText.Append(inner[i]);
				default: return false; // not an escape Beef knows: leave the literal as code
				}
			}
			return true;
		}

		static bool IsHex(char8 c) => (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');

		/// The enum members a type offers (from the index), as `.Name`.
		public static void EnumMembers(StringView typeText, TypeService types, List<String> outCases)
		{
			if (types == null)
				return;
			let t = types.FindType(typeText, null);
			if (!t.IsValid)
				return;
			let cases = t.Store.Str(t.Rec.EnumCases);
			for (var c in cases.Split(';'))
			{
				c.Trim();
				if (!c.IsEmpty)
					outCases.Add(new String()..AppendF(".{}", c));
			}
		}
	}
}
