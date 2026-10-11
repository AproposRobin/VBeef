using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;
using VisualBeef.Graph;

namespace VisualBeef.Document
{
	/// Type- and member-level edits (docs/Classes-and-Members.md): every one is a token-range
	/// splice of the declaration, one undo step, and keeps the text around it (comments,
	/// indentation, the graphs of untouched bodies). They return false and set LastError when
	/// the edit cannot be made; true also when nothing had to change.
	extension SourceDocument
	{
		/// Steps on the undo / redo stacks (multi-file undo groups compare them).
		public int UndoDepth => mUndo.Count;
		public int RedoDepth => mRedo.Count;

		/// Refuses (LastError, nothing written) a type the slot does not accept. `scopeOf` is the
		/// member or type the text is written in. True when it is refused.
		bool RefuseType(StringView type, TypeSlot slot, Member scopeOf, StringView what)
		{
			String gen = scope .();
			TypeScope sc = default;
			if (scopeOf != null)
				sc = scopeOf.GetTypeScope(gen);
			else
				sc.InType = true;
			String why = scope .();
			if (TypeSlotRules.Check(type, slot, sc, why))
				return false;
			LastError.Clear();
			LastError.AppendF("{} {}", what, why);
			return true;
		}

		bool RefuseParams(StringView paramsText, Member scopeOf)
		{
			String gen = scope .();
			TypeScope sc = default;
			if (scopeOf != null)
				sc = scopeOf.GetTypeScope(gen);
			else
				sc.InType = true;
			String why = scope .();
			if (TypeSlotRules.CheckParamList(paramsText, sc, why))
				return false;
			LastError.Clear();
			LastError.AppendF("Parameters: {}", why);
			return true;
		}

		bool Refuse(StringView why)
		{
			LastError.Set(why);
			return false;
		}

		/// Index of a method in Methods (for re-keying its graph), -1 when it is not one.
		int MethodIndexOf(Member m)
		{
			for (let mg in Methods)
				if (mg.Method == m)
					return @mg.Index;
			return -1;
		}

		/// The first token of a declaration after its attributes (modifiers, or the type / kind).
		int DeclStartTok(Member m)
		{
			if (m.AttrLastTok >= 0)
				return m.AttrLastTok + 1;
			return m.FirstTok;
		}

		/// Splices `text` over [start, end) and re-parses, keeping graphs (see ReplaceRange).
		void Splice(int start, int end, StringView text, Member keyed = null)
		{
			int rekey = (keyed != null) ? MethodIndexOf(keyed) : -1;
			String oldKey = scope .();
			if (rekey >= 0)
				oldKey.Set(Methods[rekey].Key);
			ReplaceRange(start, end, text, rekey);
			if (rekey >= 0 && rekey < Methods.Count && Methods[rekey].Key != oldKey)
				RemapMethodKey(oldKey, Methods[rekey].Key);
		}

		// ------------------------------------------------------------------ modifiers

		/// Replaces the modifier words of a type or member (`public abstract`). "" removes them.
		public bool SetModifiers(Member m, StringView newModsIn)
		{
			if (m == null || !m.HasSpan)
				return Refuse("No declaration to change.");
			var newMods = newModsIn;
			newMods.Trim();
			if (StringView(m.Modifiers) == newMods)
				return true;
			if (m.Kind == .Method && m.IsAccessor && newMods.Contains("static"))
				return Refuse("An accessor takes its storage from the property.");
			if (m.Kind != .Type && Mods.Has(m.Modifiers, "static") && !Mods.Has(newMods, "static"))
			{
				List<Member> owners = scope .();
				Unit.CollectTypes(owners);
				for (let t in owners)
					if (t.IsNodeLibrary && t.Members != null && t.Members.Contains(m))
						return Refuse(scope $"{t.Name} is a Node Library: everything in it is static.");
			}
			if (m.ModFirstTok >= 0)
			{
				int start = Unit.Tokens[m.ModFirstTok].Start;
				int end = Unit.Tokens[m.ModLastTok].End;
				if (newMods.IsEmpty)
				{
					// Remove the words and the spaces that follow them (not line breaks).
					let next = Unit.Tokens[m.ModLastTok + 1];
					let gap = StringView(Unit.Text, end, next.Start - end);
					if (!gap.Contains('\n') && !gap.Contains('/'))
						end = next.Start;
				}
				PushUndo();
				Splice(start, end, newMods, m);
				return true;
			}
			int at = Unit.Tokens[DeclStartTok(m)].Start;
			PushUndo();
			Splice(at, at, scope String()..AppendF("{} ", newMods), m);
			return true;
		}

		/// Turns one modifier word on or off (`static`, `abstract`, `readonly`, ...).
		public bool SetModifierWord(Member m, StringView word, bool on)
		{
			String mods = scope .();
			Mods.SetWord(m.Modifiers, word, on, mods);
			return SetModifiers(m, mods);
		}

		/// Sets the visibility (`public`, `protected`, `internal`, `private`, "" = default).
		public bool SetVisibility(Member m, StringView vis)
		{
			String mods = scope .();
			Mods.SetVisibility(m.Modifiers, vis, mods);
			return SetModifiers(m, mods);
		}

		/// Sets one of `virtual` / `override` / `abstract` / `new` (or none) on a member.
		public bool SetInheritance(Member m, StringView word)
		{
			String mods = scope .();
			Mods.SetExclusive(m.Modifiers, "virtual,override,abstract,new", word, mods);
			if (word == "abstract" && m.Body != null)
				return Refuse("An abstract function has no body: delete its graph's nodes first, or use virtual.");
			return SetModifiers(m, mods);
		}

		// ------------------------------------------------------------------ attributes

		/// Replaces the attributes of a type or member with `attrs` ("AlwaysInclude",
		/// "Reflect(.All)"), written as one `[A, B]` on the line above. Empty removes them.
		public bool SetAttributes(Member m, List<String> attrs)
		{
			if (m == null || !m.HasSpan)
				return Refuse("No declaration to change.");
			List<String> current = scope .();
			defer { ClearAndDeleteItems!(current); }
			if (m.Attributes != null)
				AttrList.Parse(m.Attributes, current);
			bool same = current.Count == attrs.Count;
			for (int i < Math.Min(current.Count, attrs.Count))
				if (current[i] != attrs[i])
					same = false;
			if (same)
				return true;
			String text = scope .();
			AttrList.Format(attrs, text);
			if (m.AttrFirstTok >= 0)
			{
				int start = Unit.Tokens[m.AttrFirstTok].Start;
				int end = Unit.Tokens[m.AttrLastTok].End;
				if (text.IsEmpty)
					end = Unit.Tokens[m.AttrLastTok + 1].Start; // the line break and indentation before the declaration
				PushUndo();
				Splice(start, end, text, m);
				return true;
			}
			if (text.IsEmpty)
				return true;
			int at = Unit.Tokens[m.FirstTok].Start;
			String indent = scope .();
			Unit.GetLineIndent(m.FirstTok, indent);
			text.AppendF("\n{}", indent);
			PushUndo();
			Splice(at, at, text, m);
			return true;
		}

		// ------------------------------------------------------------------ type header

		/// `class` / `struct` / `interface` / `enum` / `extension`.
		public bool SetTypeKind(Member type, StringView kind)
		{
			if (type == null || type.Kind != .Type || type.KindTok < 0)
				return Refuse("No type declaration to change.");
			if (kind == "library")
				return MakeNodeLibrary(type);
			if (type.IsNodeLibrary)
			{
				if (kind == "class")
					return SetModifierWord(type, "static", false);
				return Refuse("A Node Library can only become a Class: change it to a Class first.");
			}
			if (kind != "class" && kind != "struct" && kind != "interface" && kind != "enum" && kind != "extension")
				return Refuse(scope $"'{kind}' is not a kind of type.");
			if (type.TypeKind == kind)
				return true;
			if ((kind == "enum") != (type.TypeKind == "enum"))
				return Refuse("An enum's body is a list of cases: make a new enum instead of turning a type into one (or back).");
			let tok = Unit.Tokens[type.KindTok];
			PushUndo();
			Splice(tok.Start, tok.End, kind);
			return true;
		}

		/// Turns a class into a Node Library (`static class`). Refused when the class has a parent,
		/// interfaces, or members that belong to an object (the message names the first one).
		bool MakeNodeLibrary(Member type)
		{
			if (type.IsNodeLibrary)
				return true;
			if (type.TypeKind != "class")
				return Refuse(scope $"Only a class can become a Node Library; {type.Name} is a {type.TypeKind}.");
			if (type.BaseColonTok >= 0)
				return Refuse(scope $"{type.Name} has a parent or interfaces: a Node Library has none. Remove them first.");
			if (type.Members != null)
			{
				for (let m in type.Members)
				{
					if (m.Kind == .Type || m.Kind == .Broken || m.Kind == .Using || m.Kind == .Raw)
						continue;
					if (Mods.Has(m.Modifiers, "static") || Mods.Has(m.Modifiers, "const"))
						continue;
					String what = scope .();
					if (m.Kind == .Method && m.IsCtor)
						what.Set("a constructor");
					else if (m.Kind == .Method && m.IsDtor)
						what.Set("a destructor");
					else
						what.Set(m.Name);
					return Refuse(scope $"{type.Name} has {what}, which belongs to an object: every member of a Node Library is static. Make it static (or remove it) first.");
				}
			}
			return SetModifierWord(type, "static", true);
		}

		/// Replaces the base list (`: Base, IFoo`). An empty list removes the `:`. For an enum
		/// it is the underlying type.
		public bool SetBaseList(Member type, List<String> bases)
		{
			if (type == null || type.Kind != .Type || type.NameTok < 0)
				return Refuse("No type declaration to change.");
			String list = scope .();
			for (let b in bases)
			{
				var t = StringView(b);
				t.Trim();
				if (t.IsEmpty)
					continue;
				{
					String gen = scope .();
					TypeScope bsc = type.GetTypeScope(gen);
					bsc.IsEnum = type.TypeKind == "enum";
					bsc.IsStruct = type.TypeKind == "struct";
					String why = scope .();
					if (!TypeSlotRules.Check(t, .Base, bsc, why))
						return Refuse(scope $"Base Type {why}");
				}
				// `class Player : Player` (the picker's typed text or Enter on the first row).
				{
					var bare = t;
					int lt = bare.IndexOf('<');
					if (lt >= 0)
						bare = bare.Substring(0, lt);
					bare.Trim();
					if (bare == type.Name)
						return Refuse(scope $"Base Type: {type.Name} cannot be its own parent.");
				}
				for (let prev in list.Split(", "))
					if (prev == t)
						return Refuse(scope $"Base Type: {t} is listed twice.");
				// A typed primitive (`struct Handle : int`): one basic type, and it comes first.
				if (type.TypeKind == "struct" && TypeSlotRules.IsPrimitiveName(t) && !list.IsEmpty)
					return Refuse(scope $"Base Type: the basic type {t} must be the first base of a struct, before any interface.");
				if (!list.IsEmpty)
					list.Append(", ");
				list.Append(t);
			}
			if (type.BaseColonTok >= 0)
			{
				let cur = Unit.SpanText(type.BaseColonTok + 1, type.BaseLastTok);
				var c = cur;
				c.Trim();
				if (c == list)
					return true;
				int start = Unit.Tokens[type.BaseColonTok].Start;
				int end = Unit.Tokens[type.BaseLastTok].End;
				PushUndo();
				if (list.IsEmpty)
					Splice(Unit.Tokens[type.BaseColonTok - 1].End, end, "");
				else
					Splice(start, end, scope String()..AppendF(": {}", list));
				return true;
			}
			if (list.IsEmpty)
				return true;
			int after = (type.GenericCloseTok >= 0) ? type.GenericCloseTok : type.NameTok;
			int at = Unit.Tokens[after].End;
			PushUndo();
			Splice(at, at, scope String()..AppendF(" : {}", list));
			return true;
		}

		/// The generic parameters, "T, U" without brackets ("" removes them).
		public bool SetGenericParams(Member type, StringView paramsIn)
		{
			if (type == null || type.NameTok < 0)
				return Refuse("No declaration to change.");
			var p = paramsIn;
			p.Trim();
			{
				String why = scope .();
				if (!TypeSlotRules.CheckGenericList(p, why))
					return Refuse(scope $"Generic parameters: {why}");
			}
			if (type.GenericOpenTok >= 0)
			{
				let cur = (type.GenericCloseTok > type.GenericOpenTok + 1) ? Unit.SpanText(type.GenericOpenTok + 1, type.GenericCloseTok - 1) : "";
				if (cur == p)
					return true;
				int start = Unit.Tokens[type.GenericOpenTok].Start;
				int end = Unit.Tokens[type.GenericCloseTok].End;
				if (Unit.TokenText(type.GenericCloseTok) == ">>")
					return Refuse("The generic list ends in '>>': edit it in the text.");
				PushUndo();
				Splice(start, end, p.IsEmpty ? "" : scope String()..AppendF("<{}>", p), type);
				return true;
			}
			if (p.IsEmpty)
				return true;
			int at = Unit.Tokens[type.NameTok].End;
			PushUndo();
			Splice(at, at, scope String()..AppendF("<{}>", p), type);
			return true;
		}

		/// The constraints, "where T : class" (the text after the base list; "" removes them).
		public bool SetConstraints(Member type, StringView textIn)
		{
			if (type == null || type.Kind != .Type || type.NameTok < 0)
				return Refuse("No type declaration to change.");
			var text = textIn;
			text.Trim();
			if (!text.IsEmpty && !text.StartsWith("where"))
				return Refuse("Constraints start with 'where' (where T : class).");
			if (type.WhereFirstTok >= 0)
			{
				if (Unit.SpanText(type.WhereFirstTok, type.WhereLastTok) == text)
					return true;
				int start = Unit.Tokens[type.WhereFirstTok].Start;
				int end = Unit.Tokens[type.WhereLastTok].End;
				PushUndo();
				if (text.IsEmpty)
					Splice(Unit.Tokens[type.WhereFirstTok - 1].End, end, "");
				else
					Splice(start, end, text);
				return true;
			}
			if (text.IsEmpty)
				return true;
			int after = (type.BaseLastTok >= 0) ? type.BaseLastTok : (type.GenericCloseTok >= 0) ? type.GenericCloseTok : type.NameTok;
			int at = Unit.Tokens[after].End;
			PushUndo();
			Splice(at, at, scope String()..AppendF(" {}", text));
			return true;
		}

		/// Moves a type to another namespace by renaming the namespace declaration around it.
		/// Refused when that namespace holds other types too (move the type to its own file
		/// first) or when there is none.
		public bool SetNamespace(Member type, StringView nsIn)
		{
			var ns = nsIn;
			ns.Trim();
			let nsMember = TypeDeclInfo.NamespaceMemberOf(Unit.Members, type);
			if (nsMember == null)
				return Refuse("The type is not inside a namespace declaration; add one in the text.");
			int types = 0;
			for (let m in nsMember.Members)
				if (m.Kind == .Type || m.Kind == .Namespace)
					types++;
			if (types > 1)
				return Refuse(scope $"The namespace {nsMember.Name} holds {types} types: changing it would move all of them. Move the type to its own file first.");
			if (ns.IsEmpty)
				return Refuse("A namespace name is needed.");
			// The name tokens between `namespace` and `{` / `;` (a file-scoped `namespace A.B;`
			// has no brace: run to its `;`).
			int first = nsMember.FirstTok + 1;
			int last = first;
			if (nsMember.OpenBrace >= 0)
				last = nsMember.OpenBrace - 1;
			else
			{
				while (last + 1 < Unit.Tokens.Count && Unit.TokenText(last + 1) != ";" && Unit.TokenText(last + 1) != "{")
					last++;
			}
			while (last > first && (Unit.TokenText(last) == ";" || Unit.TokenText(last) == "{"))
				last--;
			// Properties shows the full path (`Outer.Inner`); a nested declaration owns only its
			// own part, so the outer declarations' path must stay in front.
			String full = scope .();
			TypeDeclInfo.NamespaceOf(Unit.Members, type, full);
			let own = Unit.SpanText(first, last);
			if (full.Length > own.Length && full.EndsWith(own) && full[full.Length - own.Length - 1] == '.')
			{
				let outer = StringView(full, 0, full.Length - own.Length - 1);
				if (!ns.StartsWith(outer) || ns.Length <= outer.Length + 1 || ns[outer.Length] != '.')
					return Refuse(scope $"This namespace is declared inside {outer}, so its name must start with {outer} and a dot. To move the type out of {outer}, edit the text.");
				ns = ns.Substring(outer.Length + 1);
			}
			if (own == ns)
				return true;
			PushUndo();
			Splice(Unit.Tokens[first].Start, Unit.Tokens[last].End, ns);
			return true;
		}

		// ------------------------------------------------------------------ fields

		/// A field's initial value ("" removes `= ...`). Refused for `int a, b;` declarations.
		public bool SetFieldInitializer(Member field, StringView valueIn)
		{
			if (field == null || field.Kind != .Field || !field.HasSpan)
				return Refuse("No field to change.");
			var value = valueIn;
			value.Trim();
			int semi = field.LastTok;
			if (Unit.TokenText(semi) != ";")
				return Refuse("The field declaration does not end in ';'.");
			// One declarator only.
			int depth = 0;
			for (int i = field.NameTok; i < semi; i++)
			{
				let tx = Unit.TokenText(i);
				if (tx == "(" || tx == "[" || tx == "{" || tx == "<") depth++;
				else if (tx == ")" || tx == "]" || tx == "}" || tx == ">") depth--;
				else if (tx == "," && depth == 0)
					return Refuse("This line declares several fields: edit their values in the text.");
			}
			if (field.InitTok >= 0)
			{
				// The value ends at the destructor clause (`= new .() ~ delete _`), which stays.
				int valueLast = (field.DtorTok > field.InitTok) ? field.DtorTok - 1 : semi - 1;
				let cur = Unit.SpanText(field.InitTok + 1, valueLast);
				if (cur == value)
					return true;
				PushUndo();
				int end = (field.DtorTok > field.InitTok) ? Unit.Tokens[valueLast].End : Unit.Tokens[semi].Start;
				if (value.IsEmpty)
					Splice(Unit.Tokens[field.InitTok - 1].End, end, "");
				else
					Splice(Unit.Tokens[field.InitTok].Start, end, scope String()..AppendF("= {}", value));
				return true;
			}
			if (value.IsEmpty)
				return true;
			// `T x ~ delete _;`: the value goes before the destructor clause.
			int at = (field.DtorTok > field.NameTok) ? Unit.Tokens[field.DtorTok - 1].End : Unit.Tokens[semi - 1].End;
			PushUndo();
			Splice(at, at, scope String()..AppendF(" = {}", value));
			return true;
		}

		// ------------------------------------------------------------------ ownership and initial values

		/// Where a member variable's initializer and destructor clause go: from the end of its
		/// name to its `;` (` = new .() ~ delete _`; empty when it has neither). For an
		/// auto-property, from the accessors' `}` to the end of its `;` (`isProperty`: the
		/// replacement then carries the `;`). False with LastError for `int a, b;`, a property
		/// with accessor bodies or an expression body, and anything without a declaration.
		public bool InitRange(Member m, out int start, out int end, out bool isProperty)
		{
			start = end = -1;
			isProperty = false;
			if (m == null || !m.HasSpan || m.NameTok < 0 || Unit == null)
				return Refuse("No member variable to change.");
			if (m.Kind == .Property)
			{
				if (m.IsIndexer || m.Members == null || m.Members.IsEmpty)
					return Refuse("Only a property with `{ get; set; }` has an initial value.");
				for (let a in m.Members)
					if (a.Body != null)
						return Refuse("A property whose get / set have bodies has no initial value: set the value in its setter or a constructor.");
				isProperty = true;
				if (m.InitTok >= 0)
				{
					if (Unit.TokenText(m.LastTok) != ";")
						return Refuse("The property's initial value does not end in ';'.");
					start = Unit.Tokens[m.InitTok - 1].End;
					end = Unit.Tokens[m.LastTok].End;
				}
				else
				{
					if (Unit.TokenText(m.LastTok) != "}")
						return Refuse("The property does not end in '}'.");
					start = end = Unit.Tokens[m.LastTok].End;
				}
				return true;
			}
			if (m.Kind != .Field)
				return Refuse("No member variable to change.");
			int semi = m.LastTok;
			if (Unit.TokenText(semi) != ";")
				return Refuse("The member variable's declaration does not end in ';'.");
			int nameEnd = m.NameTok;
			while (nameEnd + 2 < semi && Unit.TokenText(nameEnd + 1) == "." && Unit.Tokens[nameEnd + 2].Kind == .Identifier)
				nameEnd += 2;
			int depth = 0;
			for (int i = nameEnd + 1; i < semi; i++)
			{
				let tx = Unit.TokenText(i);
				if (tx == "(" || tx == "[" || tx == "{") depth++;
				else if (tx == ")" || tx == "]" || tx == "}") depth--;
				else if (tx == "," && depth == 0)
					return Refuse("This line declares several member variables: edit their values in the text.");
			}
			start = Unit.Tokens[nameEnd].End;
			end = Unit.Tokens[semi].Start;
			return true;
		}

		/// Reads a member's initializer and destructor clause into the Ownership / Initial value
		/// choices (Custom when it is none of them). False when the member has no such clause
		/// to read (see InitRange).
		public bool ReadMemberInit(Member m, InitType type, MemberInit outInit)
		{
			if (!InitRange(m, let start, let end, let isProperty))
				return false;
			var tail = StringView(Unit.Text, start, end - start);
			if (isProperty && tail.EndsWith(';'))
				tail.RemoveFromEnd(1);
			outInit.Classify(tail, type, m.IsStatic || Mods.Has(m.Modifiers, "static"));
			return true;
		}

		/// Writes a member's Ownership / Initial value: only the text after its name changes (and
		/// its type when `newType` is given: a Pointer adds the `*`, leaving Pointer removes it).
		/// One undo step; true without a step when nothing changes.
		public bool SetMemberInit(Member m, MemberInit init, StringView newTypeIn = "", Member enclosing = null)
		{
			if (!InitRange(m, let start, let end, let isProperty))
				return false;
			let o = init.Owner;
			if (isProperty && o == .DisposedWith)
				return Refuse("A property cannot run Dispose for what it holds: use a member variable for it, and a property that returns it.");
			if (isProperty && (o == .OwnedCreatedHere || o == .OwnedCreatedLater || o == .Appended))
				return Refuse("A property cannot own what it holds: use a member variable for it, and a property that returns it.");
			bool isConst = Mods.Has(m.Modifiers, "const");
			if (isConst && (o == .OwnedCreatedHere || o == .OwnedCreatedLater || o == .Appended || o == .OwnedForRun || o == .DisposedWith))
				return Refuse("A const member variable holds a value known when compiling: it cannot own an instance.");
			if (o == .OwnedForRun && !(m.IsStatic || Mods.Has(m.Modifiers, "static")))
				return Refuse("Owned for the run is only for static member variables: an instance one would never be deleted.");
			if (o == .Appended)
			{
				if (m.IsStatic || Mods.Has(m.Modifiers, "static"))
					return Refuse("Appended is only for instance member variables: a static one cannot be stored inside an object.");
				if (enclosing != null && enclosing.TypeKind != null && enclosing.TypeKind != "class")
					return Refuse(scope $"Appended is only for member variables of a class; {enclosing.Name} is a {enclosing.TypeKind}.");
			}
			String tail = scope .();
			init.Emit(tail);
			if (isProperty && !tail.IsEmpty)
				tail.Append(';');
			var newType = newTypeIn;
			newType.Trim();
			int spliceStart = start;
			String text = scope .();
			if (!newType.IsEmpty && m.TypeText != null && newType != m.TypeText)
			{
				let nameTok = Unit.Tokens[m.NameTok];
				int typeEnd = nameTok.Start;
				while (typeEnd > 0 && CharUtil.IsSpace(Unit.Text[typeEnd - 1]))
					typeEnd--;
				int typeStart = typeEnd - m.TypeText.Length;
				if (typeStart < 0 || StringView(Unit.Text, typeStart, m.TypeText.Length) != m.TypeText)
					return Refuse("The member's type could not be found in the text.");
				spliceStart = typeStart;
				text.Append(newType);
				// `FFIType *mRType` without its `*` needs a space before the name.
				if (typeEnd == nameTok.Start && !newType.EndsWith('*'))
					text.Append(' ');
				text.Append(StringView(Unit.Text, typeEnd, start - typeEnd));
			}
			text.Append(tail);
			if (StringView(Unit.Text, spliceStart, end - spliceStart) == text)
				return true;
			// A type change (Pointer adds `*`) of a variable the create constructor sets.
			String createType = scope .();
			List<String> createNames = scope .();
			defer { ClearAndDeleteItems!(createNames); }
			bool marked = spliceStart != start && CreateNamesBefore(m, createType, createNames);
			PushUndo();
			Splice(spliceStart, end, text);
			if (marked)
				RewriteCreate(createType, createNames);
			return true;
		}

		// ------------------------------------------------------------------ renames

		/// Applies this document's part of a rename plan (RenameService), planned on
		/// `plannedText`; refused when the text changed since. One undo step. Functions whose key
		/// changes (a renamed type, a parameter type) keep their layout and pending orphans.
		public bool ApplyRenameEdits(StringView plannedText, List<RenameEdit> edits, StringView newName)
		{
			if (Unit == null || Unit.Text != plannedText)
				return Refuse("The file changed after the rename was planned: run the rename again.");
			if (edits.IsEmpty)
				return true;
			// A function whose graph holds a commit that was refused (its edits are not in the text)
			// would be rebuilt from the renamed text and lose them: refuse, naming it, instead.
			for (let mg in Methods)
			{
				if (!mg.IsBuilt || !mg.Method.HasSpan || mg.Graph.Errors.IsEmpty)
					continue;
				int start = Unit.Tokens[mg.Method.FirstTok].Start;
				int end = Unit.Tokens[mg.Method.LastTok].End;
				bool touched = false;
				for (let e in edits)
					if (e.Start >= start && e.End <= end)
						touched = true;
				if (!touched)
					continue;
				// Edits the text does not have: nodes added in the graph (no line), or a shape that differs from the code.
				bool pending = !SameShapeAsCode(mg, mg.Graph);
				for (let n in mg.Graph.Nodes)
					if (n.Line <= 0 && n.Kind != .Entry)
						pending = true;
				if (pending)
					return Refuse(scope $"Not renamed: the graph of {mg.Method.Name} has edits that were not written (its commit was refused). Fix or undo them first, then rename again.");
			}
			String newText = scope .();
			RenameService.Apply(plannedText, edits, newName, newText);
			List<String> oldKeys = scope .();
			defer { ClearAndDeleteItems!(oldKeys); }
			for (let mg in Methods)
				oldKeys.Add(new String(mg.Key));
			PushUndo();
			CaptureAllLayouts();
			ReparseKeeping(newText);
			RefreshModified();
			if (Methods.Count == oldKeys.Count)
				for (int i < oldKeys.Count)
					if (Methods[i].Key != oldKeys[i])
						RemapMethodKey(oldKeys[i], Methods[i].Key);
			return true;
		}

		// ------------------------------------------------------------------ adding members

		/// Inserts member text (already indented with the member indent, ending in a newline)
		/// before the type's closing brace, after a blank line. No undo step of its own.
		void InsertMembersRaw(Member type, StringView memberText)
		{
			String text = scope .();
			let closeTok = Unit.Tokens[type.CloseBrace];
			bool needsBlank = false;
			if (type.Members != null)
				for (let m in type.Members)
					if (m.HasSpan)
						needsBlank = true;
			if (needsBlank)
				text.Append("\n");
			text.Append(memberText);
			int insertAt = closeTok.LeadStart;
			if (insertAt > 0 && Unit.Text[insertAt - 1] != '\n')
				text.Insert(0, "\n");
			ReplaceRange(insertAt, insertAt, text);
		}

		/// The indentation members of `type` use.
		public void GetMemberIndent(Member type, String outIndent)
		{
			MemberIndent(type, outIndent);
		}

		/// Finds the key of the last method of `typeName` named `name` (after an insert).
		void LastMethodKey(StringView typeName, StringView name, String outKey)
		{
			outKey.Clear();
			for (let mg in Methods)
				if (mg.Owner != null && mg.Owner.Name == typeName && mg.Method.Name == name)
					outKey.Set(mg.Key);
		}

		/// Adds an override (or interface implementation) of `m` to `type`, with a call to the
		/// parent function when `callBase` and the base has one. `outKey` gets the new function's
		/// key (for a property, its getter's).
		public bool AddOverride(Member type, InheritedMember m, bool callBase, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			ClassModel.StubText(m, callBase, indent, IndentUnit.IsEmpty ? "\t" : IndentUnit, Allman, text);
			PushUndo();
			InsertMembersRaw(type, text);
			StringView keyName = m.Name;
			String accName = scope .();
			if (m.Kind == .Property)
			{
				accName.AppendF("{}.get", m.Name);
				keyName = accName;
			}
			else if (m.Kind == .Indexer)
				keyName = "this[].get";
			LastMethodKey(typeName, keyName, outKey);
			return true;
		}

		/// Adds stubs for every member in `list` (one undo step). Returns how many were added.
		public int AddStubs(Member type, List<InheritedMember> list, bool callBase = false)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0 || list.IsEmpty)
				return 0;
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			for (let m in list)
			{
				if (@m.Index > 0)
					text.Append("\n");
				ClassModel.StubText(m, callBase, indent, IndentUnit.IsEmpty ? "\t" : IndentUnit, Allman, text);
			}
			PushUndo();
			InsertMembersRaw(type, text);
			return list.Count;
		}

		/// A constructor's parameter list as the text compared for "same signature": modifiers and
		/// types without spaces, names and defaults dropped ("int,refString").
		public static void ParamTypesKey(StringView paramsText, String o)
		{
			int depth = 0;
			int start = 0;
			void Flush(StringView piece, String o)
			{
				var t = piece;
				int d = 0;
				int eq = -1;
				for (int i < t.Length)
				{
					let c = t[i];
					if (c == '(' || c == '<' || c == '[') d++;
					else if (c == ')' || c == '>' || c == ']') d--;
					else if (c == '=' && d == 0 && eq < 0)
						eq = i;
				}
				if (eq >= 0)
					t = StringView(t, 0, eq);
				t.Trim();
				if (t.IsEmpty)
					return;
				int last = t.Length;
				while (last > 0 && !t[last - 1].IsWhiteSpace)
					last--;
				var typePart = StringView(t, 0, last);
				typePart.Trim();
				if (!o.IsEmpty)
					o.Append(',');
				for (let c in typePart.RawChars)
					if (!c.IsWhiteSpace)
						o.Append(c);
			}
			for (int i < paramsText.Length)
			{
				let c = paramsText[i];
				if (c == '(' || c == '<' || c == '[') depth++;
				else if (c == ')' || c == '>' || c == ']') depth--;
				else if (c == ',' && depth == 0)
				{
					Flush(StringView(paramsText, start, i - start), o);
					start = i + 1;
				}
			}
			Flush(StringView(paramsText, start, paramsText.Length - start), o);
		}

		/// The signature key of a parsed constructor.
		public static void CtorKey(Member ctor, String o)
		{
			for (let p in ctor.Params)
			{
				if (@p.Index > 0)
					o.Append(',');
				for (let c in p.Modifier.RawChars)
					if (!c.IsWhiteSpace)
						o.Append(c);
				for (let c in p.Type.RawChars)
					if (!c.IsWhiteSpace)
						o.Append(c);
			}
		}

		/// A constructor of `type` (instance, not `except`) with this signature key.
		public Member FindConstructor(Member type, StringView sigKey, Member except = null)
		{
			if (type.Members == null)
				return null;
			String k = scope .();
			for (let m in type.Members)
			{
				if (m.Kind != .Method || !m.IsCtor || m.IsStatic || m == except || m.Params == null)
					continue;
				k.Clear();
				CtorKey(m, k);
				if (k == sigKey)
					return m;
			}
			return null;
		}

		/// "int, String" text of a constructor's parameter types (Outline row, messages).
		public static void CtorTypesText(Member ctor, String o)
		{
			for (let p in ctor.Params)
			{
				if (@p.Index > 0)
					o.Append(", ");
				if (!p.Modifier.IsEmpty)
					o.AppendF("{} ", p.Modifier);
				o.Append(p.Type);
			}
		}

		/// True when the type gets the Outline's default Constructor / Destructor rows (classes
		/// and structs; not interfaces, enums, extensions or static classes).
		public static bool HasDefaultMembers(Member type)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return false;
			let k = type.TypeKind ?? "";
			if (k != "class" && k != "struct")
				return false;
			return !(type.IsStatic || ProjectIndex.HasWord(type.Modifiers, "static"));
		}

		/// The parameterless instance constructor / the destructor of `type`; null when not written.
		public static Member FindDefaultCtor(Member type)
		{
			if (type.Members != null)
				for (let m in type.Members)
					if (m.Kind == .Method && m.IsCtor && !m.IsStatic && m.Params != null && m.Params.Count == 0)
						return m;
			return null;
		}

		public static Member FindDtor(Member type)
		{
			if (type.Members != null)
				for (let m in type.Members)
					if (m.Kind == .Method && m.IsDtor)
						return m;
			return null;
		}

		/// Inserts member text after the fields, before the first member `isAnchor` says yes to
		/// (at the end when none). No undo step of its own.
		void InsertBeforeFunctions(Member type, StringView memberText, delegate bool(Member) isAnchor)
		{
			Member anchor = null;
			bool before = false;
			for (let m in type.Members)
			{
				if (!m.HasSpan)
					continue;
				if (isAnchor(m))
				{
					anchor = m;
					break;
				}
				before = true;
			}
			if (anchor == null)
			{
				InsertMembersRaw(type, memberText);
				return;
			}
			let tok = Unit.Tokens[anchor.FirstTok];
			int pos = tok.LeadStart;
			bool blank = false;
			// A blank line right before the member stays before the new text.
			int i = pos;
			while (i < tok.Start && (Unit.Text[i] == ' ' || Unit.Text[i] == '\t' || Unit.Text[i] == '\r'))
				i++;
			if (i < tok.Start && Unit.Text[i] == '\n')
			{
				pos = i + 1;
				blank = true;
			}
			String text = scope .();
			if (before && !blank)
				text.Append("\n");
			text.Append(memberText);
			text.Append("\n");
			ReplaceRange(pos, pos, text);
		}

		/// Adds `static this()` (or the parameterless instance constructor), with an empty body.
		/// `outKey` gets its key. A second static constructor is refused.
		public bool AddConstructor(Member type, bool isStatic, String outKey)
		{
			if (!isStatic)
				return AddConstructor(type, "public", "", "", outKey);
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			for (let m in type.Members)
				if (m.Kind == .Method && m.IsCtor && m.IsStatic)
					return Refuse(scope $"{type.Name} already has a static constructor (static this()). A type has only one.");
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			AppendFunction(text, indent, "static this()", "");
			PushUndo();
			InsertMembersRaw(type, text);
			outKey.Clear();
			for (let mg in Methods)
				if (mg.Owner != null && mg.Owner.Name == typeName && mg.Method.IsCtor && mg.Method.IsStatic)
					outKey.Set(mg.Key);
			return true;
		}

		/// A constructor chain is `base(args)` or `this(args)`, and every argument is a parameter of
		/// the new constructor (optionally behind ref / out / in) or a literal. Else refused (LastError).
		bool ChainFits(StringView chain, StringView paramsText)
		{
			var c = chain;
			c.Trim();
			int open = c.IndexOf('(');
			if (open < 0 || !c.EndsWith(")") || !(c.StartsWith("base") || c.StartsWith("this")) || !IsChainWord(c.Substring(0, open)))
				return Refuse(scope $"Chain '{chain}': write it as base(arguments) or this(arguments).");
			List<(StringView name, StringView type)> pars = scope .();
			GraphBuilder.SplitParams(paramsText, pars);
			let inner = c.Substring(open + 1, c.Length - open - 2);
			List<StringView> args = scope .();
			int depth = 0;
			int start = 0;
			char8 quote = 0;
			for (int i <= inner.Length)
			{
				char8 ch = (i < inner.Length) ? inner[i] : ',';
				if (quote != 0)
				{
					if (ch == '\\')
						i++;
					else if (ch == quote)
						quote = 0;
					continue;
				}
				if (ch == '"' || ch == '\'')
					quote = ch;
				else if (ch == '(' || ch == '<' || ch == '[' || ch == '{')
					depth++;
				else if (ch == ')' || ch == '>' || ch == ']' || ch == '}')
					depth--;
				else if (ch == ',' && depth <= 0)
				{
					var a = inner.Substring(start, i - start);
					a.Trim();
					start = i + 1;
					if (!a.IsEmpty)
						args.Add(a);
				}
			}
			if (quote != 0 || depth != 0)
				return Refuse(scope $"Chain '{chain}': the brackets or quotes do not match.");
			for (var a in args)
			{
				for (let mod in StringView[?]("ref ", "out ", "in "))
					if (a.StartsWith(mod))
					{
						a.RemoveFromStart(mod.Length);
						a.Trim();
					}
				bool isParam = false;
				for (let p in pars)
					if (p.name == a)
						isParam = true;
				if (!isParam && !IsLiteralArg(a))
					return Refuse(scope $"Chain '{chain}': {a} is not a parameter of this constructor. Add a parameter named {a}, or choose another chain.");
			}
			return true;
		}

		static bool IsChainWord(StringView w)
		{
			var t = w;
			t.Trim();
			return t == "base" || t == "this";
		}

		static bool IsLiteralArg(StringView a)
		{
			if (a.IsEmpty)
				return false;
			if (a == "true" || a == "false" || a == "null" || a == "default")
				return true;
			if ((a[0] == '"' && a.Length >= 2 && a.EndsWith("\"")) || (a[0] == '\'' && a.Length >= 3 && a.EndsWith("'")))
				return true;
			int i = 0;
			if (a[0] == '-' || a[0] == '+')
				i = 1;
			if (i >= a.Length || !(a[i].IsDigit || (a[i] == '.' && i + 1 < a.Length && a[i + 1].IsDigit)))
				return false;
			for (; i < a.Length; i++)
				if (!(a[i].IsLetterOrDigit || a[i] == '.' || a[i] == '_' || a[i] == '\''))
					return false;
			return true;
		}

		/// Adds `access this(params) : chain` with an empty body. `chain` is "" or "base(a, b)" /
		/// "this(x)". The same parameter types as another constructor are refused.
		public bool AddConstructor(Member type, StringView access, StringView paramsText, StringView chain, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			if (RefuseParams(paramsText, type))
				return false;
			if (!chain.IsEmpty && !ChainFits(chain, paramsText))
				return false;
			String sig = scope .();
			ParamTypesKey(paramsText, sig);
			let existing = FindConstructor(type, sig);
			if (existing != null)
			{
				String types = scope .();
				CtorTypesText(existing, types);
				return Refuse(scope $"{type.Name} already has a constructor with these parameters: Constructor ({types}). Change the parameters, or edit that one.");
			}
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String header = scope .();
			if (!access.IsEmpty)
				header.AppendF("{} ", access);
			header.AppendF("this({})", paramsText);
			if (!chain.IsEmpty)
				header.AppendF(" : {}", chain);
			String text = scope .();
			AppendFunction(text, indent, header, "");
			PushUndo();
			InsertBeforeFunctions(type, text, scope (m) => (m.Kind != .Field && !(m.Kind == .Method && m.IsCtor)));
			outKey.Clear();
			for (let mg in Methods)
				if (mg.Owner != null && mg.Owner.Name == typeName && mg.Method.IsCtor && !mg.Method.IsStatic)
				{
					String k = scope .();
					CtorKey(mg.Method, k);
					if (k == sig)
						outKey.Set(mg.Key);
				}
			return true;
		}

		/// Adds `~this()` with an empty body. A second destructor is refused.
		public bool AddDestructor(Member type, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			for (let m in type.Members)
				if (m.Kind == .Method && m.IsDtor)
					return Refuse(scope $"{type.Name} already has a destructor (~this()). A type has only one.");
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			AppendFunction(text, indent, "public ~this()", "");
			PushUndo();
			InsertBeforeFunctions(type, text, scope (m) => (m.Kind != .Field && !(m.Kind == .Method && (m.IsCtor || m.IsDtor))));
			LastMethodKey(typeName, "~this", outKey);
			return true;
		}

		/// Writes the default (parameterless) constructor if the type has none; `outKey` gets its key.
		public bool EnsureDefaultConstructor(Member type, String outKey)
		{
			let have = FindDefaultCtor(type);
			if (have == null)
				return AddConstructor(type, "public", "", "", outKey);
			outKey.Clear();
			for (let mg in Methods)
				if (mg.Method == have)
					outKey.Set(mg.Key);
			return true;
		}

		/// Writes the default destructor if the type has none; `outKey` gets its key.
		public bool EnsureDefaultDestructor(Member type, String outKey)
		{
			let have = FindDtor(type);
			if (have == null)
				return AddDestructor(type, outKey);
			outKey.Clear();
			for (let mg in Methods)
				if (mg.Method == have)
					outKey.Set(mg.Key);
			return true;
		}

		void AppendFunction(String o, StringView indent, StringView header, StringView bodyLine)
		{
			if (Allman)
				o.AppendF("{0}{1}\n{0}{{\n", indent, header);
			else
				o.AppendF("{0}{1} {{\n", indent, header);
			if (!bodyLine.IsEmpty)
				o.AppendF("{}{}{}\n", indent, IndentUnit.IsEmpty ? "\t" : IndentUnit, bodyLine);
			o.AppendF("{}}}\n", indent);
		}

		/// Adds a property with `get` (and `set`) bodies, each a graph; or an auto-property
		/// (`{ get; set; }`) when `auto`. `outKey` gets the getter's key.
		public bool AddProperty(Member type, StringView propType, StringView name, bool hasSetter, bool auto, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			if (RefuseType(propType, .Member, type, "Property Type"))
				return false;
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String text = scope .();
			if (auto)
				text.AppendF("{}public {} {} {{ get;{} }}\n", indent, propType, name, hasSetter ? " set;" : "");
			else
			{
				InheritedMember m = scope .();
				m.Kind = .Property;
				m.Name.Set(name);
				m.ReturnType.Set(propType);
				m.HasSetter = hasSetter;
				m.FromInterface = true; // plain `public`, no override
				ClassModel.StubText(m, false, indent, IndentUnit.IsEmpty ? "\t" : IndentUnit, Allman, text);
			}
			PushUndo();
			InsertMembersRaw(type, text);
			LastMethodKey(typeName, scope String()..AppendF("{}.get", name), outKey);
			return true;
		}

		/// Adds an indexer `T this[params]` with get / set bodies.
		public bool AddIndexer(Member type, StringView elemType, StringView paramsText, bool hasSetter, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			if (RefuseType(elemType, .Member, type, "Indexer Type") || RefuseParams(paramsText, type))
				return false;
			for (let m in type.Members)
				if (m.IsIndexer)
					return Refuse(scope $"{type.Name} already has an indexer.");
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String u = scope .(IndentUnit.IsEmpty ? "\t" : IndentUnit);
			String text = scope .();
			String i1 = scope .(indent);
			i1.Append(u);
			String i2 = scope .(i1);
			i2.Append(u);
			String header = scope $"public {elemType} this[{paramsText}]";
			if (Allman)
			{
				text.AppendF("{0}{1}\n{0}{{\n{2}get\n{2}{{\n{3}return default;\n{2}}}\n", indent, header, i1, i2);
				if (hasSetter)
					text.AppendF("{0}set\n{0}{{\n{0}}}\n", i1);
			}
			else
			{
				text.AppendF("{0}{1} {{\n{2}get {{\n{3}return default;\n{2}}}\n", indent, header, i1, i2);
				if (hasSetter)
					text.AppendF("{0}set {{\n{0}}}\n", i1);
			}
			text.AppendF("{}}}\n", indent);
			PushUndo();
			InsertMembersRaw(type, text);
			LastMethodKey(typeName, "this[].get", outKey);
			return true;
		}

		/// Adds a function with modifiers and a return type (`public virtual void Foo(int a)`).
		/// Non-void functions get `return default;` so the new code compiles.
		public bool AddFunction(Member type, StringView modifiers, StringView returnType, StringView name, StringView paramsText, String outKey)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0)
				return Refuse("No type body to add to.");
			String typeName = scope .(type.Name);
			String indent = scope .();
			MemberIndent(type, indent);
			String header = scope .();
			String modsOut = scope .(modifiers);
			if (type.IsNodeLibrary && !Mods.Has(modifiers, "static"))
			{
				modsOut.Clear();
				Mods.SetWord(modifiers, "static", true, modsOut);
			}
			if (!modsOut.IsEmpty)
				header.AppendF("{} ", modsOut);
			header.AppendF("{} {}({})", returnType.IsEmpty ? "void" : returnType, name, paramsText);
			String text = scope .();
			if (Mods.Has(modifiers, "abstract") || Mods.Has(modifiers, "extern") || type.TypeKind == "interface")
				text.AppendF("{}{};\n", indent, header);
			else
				AppendFunction(text, indent, header, (returnType.IsEmpty || returnType == "void") ? "" : "return default;");
			PushUndo();
			InsertMembersRaw(type, text);
			LastMethodKey(typeName, name, outKey);
			return true;
		}
	}
}
