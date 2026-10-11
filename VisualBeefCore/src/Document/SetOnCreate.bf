using System;
using System.Collections;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Document
{
	/// What a type's "create constructor" looks like in the file.
	enum CreateState
	{
		/// No constructor carries the marker: nothing is set on create.
		None,
		/// The marked constructor is exactly what the editor writes; the checkboxes read from it.
		Marked,
		/// A marked constructor that was edited by hand and no longer matches.
		Custom
	}

	/// "Set on create" (docs/Classes-and-Members.md): the variables that creating the object asks
	/// for are the parameters of one constructor the editor owns, found by its marker comment.
	extension SourceDocument
	{
		/// The line before the constructor the editor owns.
		public const String CreateMarker = "// VisualBeef: set on create";

		/// `mSpeed` -> `speed`, `Speed` -> `speed`, `_speed` -> `speed`, `speed` -> `speed`.
		public static void CreateParamName(StringView field, String o)
		{
			var f = field;
			while (f.StartsWith('_'))
				f.RemoveFromStart(1);
			if (f.Length >= 2 && f[0] == 'm' && f[1].IsUpper)
				f.RemoveFromStart(1);
			if (f.IsEmpty)
				return;
			o.Append(f[0].ToLower);
			o.Append(f.Substring(1));
		}

		static void StripSpaces(StringView s, String o)
		{
			for (let c in s.RawChars)
				if (!c.IsWhiteSpace)
					o.Append(c);
		}

		/// True when the leading comments of the constructor hold the marker line.
		bool HasCreateMarker(Member ctor)
		{
			if (ctor.FirstTok < 0)
				return false;
			let tok = Unit.Tokens[ctor.FirstTok];
			if (tok.Start <= tok.LeadStart)
				return false;
			let lead = StringView(Unit.Text, tok.LeadStart, tok.Start - tok.LeadStart);
			for (var line in lead.Split('\n'))
			{
				line.Trim();
				if (line == CreateMarker)
					return true;
			}
			return false;
		}

		/// A variable the create constructor can take: an instance field, one declarator.
		public bool CanSetOnCreate(Member field, String why = null)
		{
			if (field == null || field.Kind != .Field || !field.HasSpan || field.TypeText == null || field.TypeText.IsEmpty)
			{
				why?.Set("Only variables can be set on create.");
				return false;
			}
			if (field.IsStatic || ProjectIndex.HasWord(field.Modifiers, "static") || ProjectIndex.HasWord(field.Modifiers, "const"))
			{
				why?.Set("Only instance variables can be set on create (static and const ones belong to the type, not the object).");
				return false;
			}
			int depth = 0;
			for (int i = field.NameTok; i < field.LastTok; i++)
			{
				let tx = Unit.TokenText(i);
				if (tx == "(" || tx == "[" || tx == "{" || tx == "<") depth++;
				else if (tx == ")" || tx == "]" || tx == "}" || tx == ">") depth--;
				else if (tx == "," && depth == 0)
				{
					why?.Set("This line declares several variables: split them into one line each first.");
					return false;
				}
			}
			return true;
		}

		/// The marked constructor of `type` (null when none) and the variables it sets, in order.
		/// `Marked` only when the constructor is exactly what ApplyCreate writes (any parameter
		/// names are accepted; they are re-derived on the next change).
		public CreateState GetCreateState(Member type, List<Member> outFields, out Member ctor)
		{
			ctor = null;
			if (type == null || type.Members == null)
				return .None;
			for (let m in type.Members)
				if (m.Kind == .Method && m.IsCtor && !m.IsStatic && m.Params != null && m.HasSpan && HasCreateMarker(m))
				{
					ctor = m;
					break;
				}
			if (ctor == null)
				return .None;
			let c = ctor;
			if (c.Modifiers != "public" || c.ParamsCloseTok < 0 || c.ParamsCloseTok + 1 >= c.LastTok)
				return .Custom;
			if (Unit.TokenText(c.ParamsCloseTok + 1) != "{" || Unit.TokenText(c.LastTok) != "}")
				return .Custom;
			// The assignments: `field = param;` or `this.field = param;`, one per parameter.
			let count = c.Params.Count;
			int tok = c.ParamsCloseTok + 2;
			List<Member> found = scope .();
			for (int i < count)
			{
				let p = c.Params[i];
				if (!p.Modifier.IsEmpty || p.Default != null)
					return .Custom;
				if (Unit.TokenText(tok) == "this" && Unit.TokenText(tok + 1) == ".")
					tok += 2;
				let fname = Unit.TokenText(tok);
				if (Unit.TokenText(tok + 1) != "=" || Unit.TokenText(tok + 2) != p.Name || Unit.TokenText(tok + 3) != ";")
					return .Custom;
				tok += 4;
				Member field = null;
				for (let m in type.Members)
					if (m.Kind == .Field && m.Name == fname)
						field = m;
				if (field == null || !CanSetOnCreate(field))
					return .Custom;
				String a = scope .();
				String b = scope .();
				StripSpaces(field.TypeText, a);
				StripSpaces(p.Type, b);
				if (a != b)
					return .Custom;
				found.Add(field);
			}
			if (tok != c.LastTok)
				return .Custom;
			// Declaration order.
			int last = -1;
			for (let f in found)
			{
				int idx = type.Members.IndexOf(f);
				if (idx <= last)
					return .Custom;
				last = idx;
			}
			if (outFields != null)
				outFields.AddRange(found);
			return .Marked;
		}

		/// True when `field` is one of the variables the create constructor takes.
		public bool IsSetOnCreate(Member type, Member field)
		{
			List<Member> l = scope .();
			if (GetCreateState(type, l, ?) != .Marked)
				return false;
			return l.Contains(field);
		}

		/// What a Construct node's input for each "set on create" variable starts with: the
		/// variable's own initial value (`= 1.5f` in the file) or `default`. One entry per parameter,
		/// appended to `outDefaults` (nothing when the type has no marked constructor).
		public void GetCreateDefaults(Member type, List<String> outDefaults)
		{
			List<Member> fields = scope .();
			Member ctor = null;
			if (GetCreateState(type, fields, out ctor) != .Marked)
				return;
			for (let f in fields)
			{
				let s = new String();
				// The variable's Initial value (its MemberInit), not the destructor clause.
				MemberInit init = scope .();
				if (ReadMemberInit(f, MemberInit.TypeOf(f.TypeText ?? "", TypeService.Current), init) &&
					(init.Owner != .Custom || !init.Raw.Contains('~')) && init.Owner != .OwnedCreatedLater)
					init.ValueText(s);
				if (s.IsEmpty)
					s.Set("default");
				outDefaults.Add(s);
			}
		}

		/// The variables that are set on create, as the parameter list text: "float speed, String name".
		/// Empty when the type has no marked constructor.
		public void GetCreateParamsText(Member type, String o)
		{
			List<Member> l = scope .();
			Member ctor = null;
			if (GetCreateState(type, l, out ctor) == .None)
				return;
			if (ctor == null)
				return;
			for (let p in ctor.Params)
			{
				if (@p.Index > 0)
					o.Append(", ");
				o.AppendF("{} {}", p.Type, p.Name);
			}
		}

		/// The create constructor of `type`, null when the type has none marked.
		public Member FindCreateConstructor(Member type)
		{
			Member ctor = null;
			GetCreateState(type, null, out ctor);
			return ctor;
		}

		/// Builds the constructor text for `fields` (variable order): marker line, header, body.
		void BuildCreateCtor(Member type, List<Member> fields, StringView indent, String o, bool withMarker)
		{
			String unit = scope .(IndentUnit.IsEmpty ? "\t" : (StringView)IndentUnit);
			if (withMarker)
				o.AppendF("{}{}\n", indent, CreateMarker);
			o.AppendF("{}public this(", indent);
			for (let f in fields)
			{
				if (@f.Index > 0)
					o.Append(", ");
				String pn = scope .();
				CreateParamName(f.Name, pn);
				o.AppendF("{} {}", f.TypeText, pn);
			}
			o.Append(')');
			if (Allman)
				o.AppendF("\n{}{{\n", indent);
			else
				o.Append(" {\n");
			for (let f in fields)
			{
				String pn = scope .();
				CreateParamName(f.Name, pn);
				if (pn == f.Name)
					o.AppendF("{}{}this.{} = {};\n", indent, unit, f.Name, pn);
				else
					o.AppendF("{}{}{} = {};\n", indent, unit, f.Name, pn);
			}
			o.AppendF("{}}}", indent);
		}

		/// Marks or unmarks `field` as set on create: rewrites the create constructor (creating
		/// or removing it). One undo step; false with LastError when it cannot be done.
		public bool SetFieldSetOnCreate(Member type, Member field, bool on)
		{
			return SetFieldSetOnCreate(type, field, on, true);
		}

		bool SetFieldSetOnCreate(Member type, Member field, bool on, bool pushUndo)
		{
			if (type == null || type.Kind != .Type || type.CloseBrace < 0 || type.Members == null)
				return Refuse("No type body to change.");
			List<Member> marked = scope .();
			Member ctor = null;
			let state = GetCreateState(type, marked, out ctor);
			if (state == .Custom)
				return Refuse(scope $"{type.Name} has a constructor marked \"set on create\" that was edited by hand. Edit it in the text, or delete the marker line to let the editor write a new one.");
			bool isOn = marked.Contains(field);
			if (isOn == on)
				return true;
			if (on)
			{
				String why = scope .();
				if (!CanSetOnCreate(field, why))
					return Refuse(why);
			}
			// The new list, in variable order.
			List<Member> want = scope .();
			for (let m in type.Members)
			{
				if (m.Kind != .Field)
					continue;
				if (m == field ? on : marked.Contains(m))
					want.Add(m);
			}
			// Parameter names: distinct, and not words of the language.
			for (int i < want.Count)
			{
				String pi = scope .();
				CreateParamName(want[i].Name, pi);
				if (pi.IsEmpty || Parser.IsReservedWord(pi))
					return Refuse(scope $"'{want[i].Name}' would become the parameter '{pi}', which is a reserved word. Rename the variable first.");
				for (int j = i + 1; j < want.Count; j++)
				{
					String pj = scope .();
					CreateParamName(want[j].Name, pj);
					if (pi == pj)
						return Refuse(scope $"'{want[i].Name}' and '{want[j].Name}' would both become the parameter '{pi}'. Rename one of them first.");
				}
			}
			if (want.IsEmpty)
			{
				if (ctor != null)
				{
					if (pushUndo)
						DeleteMember(ctor);
					else
						DeleteMemberNoUndo(ctor);
				}
				return true;
			}
			// The parameter list, and a clash with a constructor written by hand.
			String paramsText = scope .();
			String sig = scope .();
			for (let f in want)
			{
				String pn = scope .();
				CreateParamName(f.Name, pn);
				if (@f.Index > 0)
				{
					paramsText.Append(", ");
					sig.Append(',');
				}
				paramsText.AppendF("{} {}", f.TypeText, pn);
				StripSpaces(f.TypeText, sig);
			}
			if (RefuseParams(paramsText, type))
				return false;
			let other = FindConstructor(type, sig, ctor);
			if (other != null)
			{
				String types = scope .();
				CtorTypesText(other, types);
				return Refuse(scope $"{type.Name} already has a constructor with these parameters: Constructor ({types}). Edit that one, or change the variables.");
			}
			if (pushUndo)
				PushUndo();
			if (ctor != null)
			{
				// Replace the declaration only; the marker line above it stays.
				String indent = scope .();
				Unit.GetLineIndent(ctor.FirstTok, indent);
				String text = scope .();
				BuildCreateCtor(type, want, indent, text, false);
				text.Remove(0, indent.Length); // the splice starts at the first token, after the indent
				Splice(Unit.Tokens[ctor.FirstTok].Start, Unit.Tokens[ctor.LastTok].End, text, ctor);
			}
			else
			{
				String indent = scope .();
				MemberIndent(type, indent);
				String text = scope .();
				BuildCreateCtor(type, want, indent, text, true);
				text.Append('\n');
				InsertBeforeFunctions(type, text, scope (m) => (m.Kind != .Field && !(m.Kind == .Method && m.IsCtor)));
			}
			return true;
		}

		/// The type declaration whose members include `m` (nested types searched too).
		static Member EnclosingType(List<Member> members, Member m)
		{
			if (members == null)
				return null;
			for (let t in members)
			{
				if (t.Members == null)
					continue;
				if (t.Kind == .Type && t.Members.Contains(m))
					return t;
				let inner = EnclosingType(t.Members, m);
				if (inner != null)
					return inner;
			}
			return null;
		}

		/// The type named `typeName` that has a constructor marked "set on create", and that constructor.
		Member TypeWithCreate(List<Member> members, StringView typeName, out Member ctor)
		{
			ctor = null;
			if (members == null)
				return null;
			for (let t in members)
			{
				if (t.Kind == .Type && t.Name == typeName && t.Members != null)
					for (let m in t.Members)
						if (m.Kind == .Method && m.IsCtor && !m.IsStatic && m.HasSpan && HasCreateMarker(m))
						{
							ctor = m;
							return t;
						}
				let inner = TypeWithCreate(t.Members, typeName, out ctor);
				if (inner != null)
					return inner;
			}
			return null;
		}

		/// Before `field` is retyped or deleted: when the create constructor sets it, the names
		/// of the variables it sets (to write it again after the edit, `RewriteCreate`).
		bool CreateNamesBefore(Member field, String outTypeName, List<String> outNames)
		{
			if (field == null || field.Kind != .Field)
				return false;
			let type = EnclosingType(Unit.Members, field);
			if (type == null)
				return false;
			List<Member> marked = scope .();
			if (GetCreateState(type, marked, ?) != .Marked || !marked.Contains(field))
				return false;
			outTypeName.Set(type.Name);
			for (let f in marked)
				outNames.Add(new String(f.Name));
			return true;
		}

		/// After the edit: the create constructor written again for the variables of `names`
		/// still in the type (types as they are now), in the same undo step as the edit.
		void RewriteCreate(StringView typeName, List<String> names)
		{
			let type = TypeWithCreate(Unit.Members, typeName, let ctor);
			if (type == null)
				return;
			List<Member> want = scope .();
			for (let m in type.Members)
				if (m.Kind == .Field && names.Contains(scope String(m.Name)))
					want.Add(m);
			if (want.IsEmpty)
			{
				DeleteMemberNoUndo(ctor);
				return;
			}
			String indent = scope .();
			Unit.GetLineIndent(ctor.FirstTok, indent);
			String text = scope .();
			BuildCreateCtor(type, want, indent, text, false);
			text.Remove(0, indent.Length);
			Splice(Unit.Tokens[ctor.FirstTok].Start, Unit.Tokens[ctor.LastTok].End, text, ctor);
		}

		void DeleteMemberNoUndo(Member member)
		{
			if (!member.HasSpan)
				return;
			let first = Unit.Tokens[member.FirstTok];
			let last = Unit.Tokens[member.LastTok];
			ReplaceRange(first.LeadStart, last.TrailEnd, "");
		}

		/// Adds a variable and, when `setOnCreate`, marks it; one undo step. A refusal of the
		/// second part leaves the variable added and says why in LastError (returns true).
		public bool AddFieldSetOnCreate(Member type, StringView fieldType, StringView name, StringView initializer, bool setOnCreate, bool isStatic = false)
		{
			String typeName = scope .(type.Name);
			if (!AddField(type, fieldType, name, initializer, isStatic))
				return false;
			return MarkNewField(typeName, name, setOnCreate);
		}

		/// The same with the Ownership / Initial Value choices.
		public bool AddFieldSetOnCreate(Member type, StringView fieldType, StringView name, MemberInit init, bool setOnCreate, bool isStatic = false)
		{
			String typeName = scope .(type.Name);
			if (!AddField(type, fieldType, name, init, isStatic))
				return false;
			return MarkNewField(typeName, name, setOnCreate);
		}

		bool MarkNewField(StringView typeName, StringView name, bool setOnCreate)
		{
			if (!setOnCreate)
				return true;
			Member nt = null;
			Member field = null;
			// The member objects are new after the re-parse: find them again.
			for (let t in Unit.Members)
				CollectByName(t, typeName, name, ref nt, ref field);
			if (nt == null || field == null)
				return true;
			if (!SetFieldSetOnCreate(nt, field, true, false))
				return true; // LastError says why; the variable is there
			LastError.Clear();
			return true;
		}

		void CollectByName(Member scopeM, StringView typeName, StringView fieldName, ref Member outType, ref Member outField)
		{
			if (scopeM.Members == null)
				return;
			if (scopeM.Kind == .Type && scopeM.Name == typeName)
			{
				outType = scopeM;
				for (let m in scopeM.Members)
					if (m.Kind == .Field && m.Name == fieldName)
						outField = m;
			}
			for (let m in scopeM.Members)
				if (m.Kind == .Type || m.Kind == .Namespace)
					CollectByName(m, typeName, fieldName, ref outType, ref outField);
		}
	}
}
