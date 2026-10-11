using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// The Ownership and Initial value rows (docs/Classes-and-Members.md > Ownership and initial
	/// values): member variables in Properties, the Add Variable dialog and Local Variable nodes.
	/// The choices come from VisualBeef.Document.MemberInit; the Beef they write is shown under
	/// them so the idiom is learned by using it.
	extension EditorApp
	{
		/// Text being typed in the rows, refreshed when the member or the document changes.
		String mInitSyncKey = new .() ~ delete _;
		String mInitValueBuf = new .() ~ delete _;
		String mInitArgsBuf = new .() ~ delete _;
		String mInitRawBuf = new .() ~ delete _;

		// Add Variable dialog
		InitOwnership mAddVarOwner = .None;
		InitValueKind mAddVarValueKind = .None;
		String mAddVarValue = new .() ~ delete _;
		String mAddVarTypeSeen = new .() ~ delete _;

		static StringView ValueKindLabel(InitValueKind k, InitType t)
		{
			switch (k)
			{
			case .None:
				switch (t.Kind)
				{
				case .Integer, .Float: return "None (0)";
				case .Bool: return "None (false)";
				case .Char: return "None ('\\0')";
				case .Enum: return "None (zero value)";
				case .StringView: return "None (empty)";
				case .Struct: return "None (all zero)";
				default: return t.IsPointer || t.IsReferenceType ? "None (null)" : "None";
				}
			case .Literal:
				switch (t.Kind)
				{
				case .String, .StringView: return "Text";
				case .Bool: return "True / false";
				case .Char: return "Character";
				default: return "Number";
				}
			case .EnumCase: return "Member";
			case .Default: return "default";
			case .Null: return "null";
			case .Construct: return "Made here .()";
			case .Custom: return "Expression";
			}
		}

		/// The Initial value modes that fit a choice and a type.
		static void ValueModes(InitOwnership owner, InitType t, List<InitValueKind> outModes)
		{
			outModes.Add(.None);
			if (owner == .Pointer)
			{
				outModes.Add(.Null);
				outModes.Add(.Custom);
				return;
			}
			if (owner == .Reference)
			{
				outModes.Add(.Null);
				if (t.Kind == .String)
					outModes.Add(.Literal);
				outModes.Add(.Custom);
				return;
			}
			if (owner == .ValueDefault || owner == .DisposedWith)
			{
				outModes.Add(.Construct);
				outModes.Add(.Default);
				outModes.Add(.Custom);
				return;
			}
			switch (t.Kind)
			{
			case .Enum:
				outModes.Add(.EnumCase);
			case .Unknown:
				outModes.Add(.Literal);
				outModes.Add(.Null);
			default:
				outModes.Add(.Literal);
			}
			outModes.Add(.Default);
			outModes.Add(.Custom);
		}

		/// What a new mode starts with (a value the type accepts).
		static void StartValue(InitValueKind k, InitType t, MemberInit init, TypeService types)
		{
			init.ValueKind = k;
			init.Value.Clear();
			switch (k)
			{
			case .Literal:
				switch (t.Kind)
				{
				case .Bool: init.Value.Set("false");
				case .Char: init.Value.Set("' '");
				case .String, .StringView: init.Value.Set("\"\"");
				case .Float: MemberInit.FormatFloat(0, t.BaseText == "float", init.Value);
				default: init.Value.Set("0");
				}
			case .EnumCase:
				List<String> cases = scope .();
				MemberInit.EnumMembers(t.BaseText, types, cases);
				init.Value.Set(cases.IsEmpty ? "." : cases[0]);
				ClearAndDeleteItems!(cases);
			case .Construct:
				init.AllocType.Set(".");
				init.Args.Clear();
				init.ArrayAlloc = false;
			case .Custom:
				init.Value.Set("default");
			default:
			}
		}

		/// The value control for a Literal / Member / Expression mode. `buf` holds what is shown;
		/// returns true when `init.Value` was changed by a commit.
		bool DrawValueControl(StringView id, InitType t, MemberInit init, String buf, TypeService types)
		{
			switch (init.ValueKind)
			{
			case .Literal:
				switch (t.Kind)
				{
				case .Bool:
					bool on = init.Value == "true";
					if (Gui.Checkbox(scope $"{(on ? "true" : "false")}##{id}b", &on))
					{
						init.Value.Set(on ? "true" : "false");
						return true;
					}
					return false;
				case .Char:
					if (PropertyGrid.Text(scope $"##{id}c", buf, ?, false, null, "a character"))
					{
						String lit = scope .();
						String why = scope .();
						if (!MemberInit.QuoteCharFor(buf, t.BaseText, lit, why))
						{
							Notify.Warn(why);
							return false;
						}
						init.Value.Set(lit);
						return true;
					}
					return false;
				case .String, .StringView:
					if (PropertyGrid.Text(scope $"##{id}s", buf, ?, false, null, "text"))
					{
						init.Value.Clear();
						MemberInit.QuoteString(buf, init.Value);
						return true;
					}
					return false;
				default:
					if (PropertyGrid.Text(scope $"##{id}n", buf, ?, false, null, "0"))
					{
						String lit = scope .();
						let typeName = (t.Kind == .Integer || t.Kind == .Float) ? t.BaseText : (buf.Contains('.') ? "double" : "int");
						if (!MemberInit.FormatNumber(buf, typeName, lit))
						{
							Notify.Warn(scope $"'{buf}' is not a number for {typeName}.");
							return false;
						}
						init.Value.Set(lit);
						return true;
					}
					return false;
				}
			case .EnumCase:
				List<String> cases = scope .();
				defer { ClearAndDeleteItems!(cases); }
				MemberInit.EnumMembers(t.BaseText, types, cases);
				if (cases.IsEmpty)
				{
					if (PropertyGrid.Text(scope $"##{id}e", buf, ?, false, null, ".Member"))
					{
						init.Value.Set(buf);
						return true;
					}
					return false;
				}
				bool changed = false;
				if (Gui.igBeginCombo(scope $"##{id}ec", scope String(init.Value), 0))
				{
					for (let c in cases)
					{
						if (Gui.Selectable(c, c == init.Value) && c != init.Value)
						{
							init.Value.Set(c);
							changed = true;
						}
					}
					Gui.igEndCombo();
				}
				return changed;
			case .Custom:
				if (PropertyGrid.Text(scope $"##{id}x", buf, ?, false, null, "an expression"))
				{
					var v = StringView(buf);
					v.Trim();
					if (v.IsEmpty)
						init.ValueKind = .None;
					init.Value.Set(v);
					return true;
				}
				return false;
			default:
				return false;
			}
		}

		/// What the value box shows for the current value (the text inside quotes, the number).
		static void ValueBufFor(MemberInit init, String outBuf)
		{
			outBuf.Clear();
			if (init.ValueKind == .Literal && MemberInit.UnquoteLiteral(init.Value, outBuf))
				return;
			outBuf.Clear();
			outBuf.Append(init.Value);
		}

		/// The text an owned String is made with (`new .("text")`), when its arguments are one
		/// plain string literal or nothing.
		static bool OwnedStringText(MemberInit init, String outText)
		{
			var a = StringView(init.Args);
			a.Trim();
			if (a.IsEmpty)
				return true;
			return a.StartsWith('"') && MemberInit.IsSingleStringLiteral(a) && MemberInit.UnquoteLiteral(a, outText);
		}

		/// The Ownership choice combo; returns true when a new choice was picked (in `outPicked`).
		bool OwnershipCombo(StringView id, InitType t, InitOwnership current, bool inClass, bool isStatic, bool isProperty, bool isConst, out InitOwnership outPicked)
		{
			outPicked = current;
			List<InitOwnership> choices = scope .();
			MemberInit.Choices(t, inClass, isStatic, choices);
			if (isProperty || isConst)
				choices.RemoveAll(scope (c) => c == .OwnedCreatedHere || c == .OwnedCreatedLater || c == .Appended || c == .DisposedWith || (isConst && c == .OwnedForRun));
			bool changed = false;
			if (Gui.igBeginCombo(scope String(id), scope String(MemberInit.Label(current)), 0))
			{
				for (let c in choices)
				{
					Gui.PushID((int32)c);
					if (Gui.Selectable(MemberInit.Label(c), c == current) && c != current)
					{
						outPicked = c;
						changed = true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(MemberInit.Explain(c));
					Gui.PopID();
				}
				if (current == .Custom)
					Gui.Selectable(MemberInit.Label(.Custom), true);
				Gui.igEndCombo();
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(MemberInit.Explain(current));
			return changed;
		}

		/// The type is not in the index: every choice is offered, so say why.
		void NotIndexedHint(bool inGrid)
		{
			if (inGrid)
			{
				PropertyGrid.WideRow();
				Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 8 * Look.Scale);
			}
			Gui.TextColored(Theme.TextDim, "(type not indexed)");
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("VisualBeef does not know this type, so every choice is offered. Pick the one that matches what it is.");
		}

		/// The read-only Beef line under the rows.
		void InitPreviewLine(StringView code)
		{
			PropertyGrid.WideRow();
			float pad = 8 * Look.Scale;
			Gui.igSetCursorPosX(Gui.igGetCursorPosX() + pad);
			InitCodeText(code, Gui.igGetContentRegionAvail().x - pad);
			Gui.igDummy(.(0, 2 * Look.Scale));
		}

		/// Beef code in the monospace font at the size of the text around it, wrapped at `width`.
		void InitCodeText(StringView code, float width)
		{
			float wrapAt = Gui.igGetCursorPosX() + width;
			if (mMono != null)
				Gui.igPushFont(mMono, Gui.igGetFontSize() / Math.Max(Look.Scale, 0.5f) * 0.85f);
			Gui.igPushTextWrapPos(wrapAt);
			Gui.TextColored(Theme.TextCode, code);
			Gui.igPopTextWrapPos();
			if (mMono != null)
				Gui.igPopFont();
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The Beef this writes (read only)");
		}

		/// The declaration of a member as the file has it, on one line, without attributes.
		static void DeclarationLine(CompilationUnit unit, Member m, String outText)
		{
			int first = (m.AttrLastTok >= 0) ? m.AttrLastTok + 1 : m.FirstTok;
			let text = unit.SpanText(first, m.LastTok);
			bool space = false;
			for (let c in text.RawChars)
			{
				if (c == '\n' || c == '\r' || c == '\t' || c == ' ')
				{
					space = true;
					continue;
				}
				if (space && !outText.IsEmpty)
					outText.Append(' ');
				space = false;
				outText.Append(c);
			}
		}

		bool ApplyMemberInit(SourceDocument doc, Member type, Member field, MemberInit init, bool typeMayChange = true)
		{
			String newType = scope .();
			if (typeMayChange && field.TypeText != null)
				MemberInit.TypeFor(init.Owner, field.TypeText, newType);
			doc.LastError.Clear();
			ClassEditResult(doc, doc.SetMemberInit(field, init, newType, type), "Ownership");
			return true;
		}

		/// The Ownership / Initial value rows of a member variable (or an auto-property) in
		/// Properties. False with nothing drawn when the member has no clause to edit (`int a, b;`,
		/// a property with get / set bodies): the caller then shows the plain Default Value row.
		/// `changed` is true when the document changed.
		public bool DrawMemberInitRows(SourceDocument doc, Member type, Member field, out bool changed)
		{
			changed = false;
			let types = TypeService.Current;
			let t = MemberInit.TypeOf(field.TypeText ?? "", types);
			MemberInit init = scope .();
			if (!doc.ReadMemberInit(field, t, init))
				return false;
			bool isProp = field.Kind == .Property;
			bool isStatic = field.IsStatic || Mods.Has(field.Modifiers, "static");
			bool isConst = Mods.Has(field.Modifiers, "const");
			bool inClass = type == null || type.TypeKind == null || type.TypeKind == "class";

			String key = scope .();
			key.AppendF("{}|{}|{}|{}|{}", doc.FilePath, type?.Name, field.Name, doc.Version, field.TypeText);
			if (key != mInitSyncKey && !Gui.igIsAnyItemActive())
			{
				mInitSyncKey.Set(key);
				ValueBufFor(init, mInitValueBuf);
				mInitArgsBuf.Clear();
				if (!(t.Kind == .String && OwnedStringText(init, mInitArgsBuf)))
					mInitArgsBuf.Set(init.Args);
				mInitRawBuf.Set(init.Raw);
				mInitRawBuf.Trim();
			}

			// Ownership: for what can be owned, referenced or pointed at.
			bool showOwner = !t.IsValue || t.IsPointer || init.Owner == .Custom;
			if (showOwner)
			{
				PropertyGrid.Row("Ownership", "Who makes and deletes what this variable holds");
				if (OwnershipCombo("##vown", t, init.Owner, inClass, isStatic, isProp, isConst, let picked))
				{
					init.Retarget(picked, t);
					changed = ApplyMemberInit(doc, type, field, init);
					return true;
				}
				if (t.Kind == .Unknown && !t.IsPointer && !t.BaseText.IsEmpty)
					NotIndexedHint(true);
			}

			switch (init.Owner)
			{
			case .Custom:
				PropertyGrid.Row("Written As", "Kept exactly as written. Edit the text, or convert it to a choice.");
				String raw = scope .(mInitRawBuf);
				bool canConvert = init.CanConvert;
				if (PropertyGrid.Text("##vraw", raw, let rawEdit, false, null, "nothing"))
				{
					// What is typed is the text after the name: `= value`, `~ delete _`, or both.
					String tail = scope .();
					var r = StringView(raw);
					r.Trim();
					if (!r.IsEmpty)
						tail.AppendF(" {}", r);
					MemberInit typed = scope .();
					typed.Classify(tail, t, isStatic);
					changed = ApplyMemberInit(doc, type, field, typed, false);
					return true;
				}
				if (rawEdit)
					mInitRawBuf.Set(raw);
				if (Gui.igIsItemHovered(0) && !Gui.igIsItemActive() && !raw.IsEmpty)
					Gui.Tooltip(raw);
				if (canConvert)
				{
					PropertyGrid.Row("Convert To", "The text means this choice written with other spacing: write it the usual way");
					if (Gui.Button(scope $"{MemberInit.Label(init.ConvertOwner)}##vconv", .(-1, 0)))
					{
						init.Convert();
						changed = ApplyMemberInit(doc, type, field, init, false);
						return true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope $"Write it as: {MemberInit.Label(init.ConvertOwner)}");
				}
			case .OwnedCreatedHere, .Appended, .OwnedForRun:
				let label = (t.Kind == .String && OwnedStringText(init, scope .())) ? "Initial Text" : "Arguments";
				PropertyGrid.Row(label, (label == "Initial Text") ? "The text the String starts with" : "What the constructor gets: new .(arguments)");
				String args = scope .(mInitArgsBuf);
				if (PropertyGrid.Text("##vargs", args, let argsEdit, false, null, (label == "Initial Text") ? "empty" : "none"))
				{
					if (label == "Initial Text")
					{
						init.Args.Clear();
						if (!args.IsEmpty)
							MemberInit.QuoteString(args, init.Args);
					}
					else
					{
						var a = StringView(args);
						a.Trim();
						init.Args.Set(a);
					}
					changed = ApplyMemberInit(doc, type, field, init, false);
					return true;
				}
				if (argsEdit)
					mInitArgsBuf.Set(args);
				if (init.Owner == .OwnedCreatedHere && (init.Deleter != "delete _" || TypeRules.BaseName(t.BaseText) == "List" || TypeRules.BaseName(t.BaseText) == "Dictionary"))
				{
					if (DrawDeleterRow(init))
					{
						changed = ApplyMemberInit(doc, type, field, init, false);
						return true;
					}
				}
			case .OwnedCreatedLater:
				if (init.Deleter != "delete _" || TypeRules.BaseName(t.BaseText) == "List" || TypeRules.BaseName(t.BaseText) == "Dictionary")
				{
					if (DrawDeleterRow(init))
					{
						changed = ApplyMemberInit(doc, type, field, init, false);
						return true;
					}
				}
			default:
				if (DrawValueRows("v", t, init, mInitValueBuf, mInitArgsBuf, types))
				{
					changed = ApplyMemberInit(doc, type, field, init, false);
					return true;
				}
			}
			String line = scope .();
			DeclarationLine(doc.Unit, field, line);
			InitPreviewLine(line);
			return true;
		}

		static StringView DeleterLabel(int i)
		{
			switch (i)
			{
			case 0: return "Delete it";
			case 1: return "With its items";
			case 2: return "With its keys";
			case 3: return "With its values";
			case 4: return "With keys, values";
			default: return "Custom";
			}
		}

		/// "Delete With": what deletes an owned instance (a container and its items, ...).
		bool DrawDeleterRow(MemberInit init)
		{
			PropertyGrid.Row("Delete With", "What runs when the object is deleted: the instance alone, or a container with the items inside it");
			int idx = MemberInit.DeleterIndex(init.Deleter);
			bool changed = false;
			if (Gui.igBeginCombo("##vdel", scope String(DeleterLabel(idx)), 0))
			{
				for (int i < MemberInit.Deleters.Count)
				{
					Gui.PushID((int32)i);
					if (Gui.Selectable(DeleterLabel(i), i == idx) && i != idx)
					{
						init.Deleter.Set(MemberInit.Deleters[i]);
						changed = true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(MemberInit.Deleters[i]);
					Gui.PopID();
				}
				Gui.igEndCombo();
			}
			else if (Gui.igIsItemHovered(0))
				Gui.Tooltip(init.Deleter);
			return changed;
		}

		/// Initial value mode + value (+ arguments for a struct made here). True when `init` changed.
		bool DrawValueRows(StringView id, InitType t, MemberInit init, String valueBuf, String argsBuf, TypeService types)
		{
			List<InitValueKind> modes = scope .();
			ValueModes(init.Owner, t, modes);
			if (!modes.Contains(init.ValueKind))
				modes.Add(init.ValueKind);
			PropertyGrid.Row("Initial Value", "What the variable holds when the object is made");
			bool changed = false;
			if (Gui.igBeginCombo(scope $"##{id}mode", scope String(ValueKindLabel(init.ValueKind, t)), 0))
			{
				for (let k in modes)
				{
					Gui.PushID((int32)k);
					if (Gui.Selectable(ValueKindLabel(k, t), k == init.ValueKind) && k != init.ValueKind)
					{
						StartValue(k, t, init, types);
						ValueBufFor(init, valueBuf);
						changed = true;
					}
					Gui.PopID();
				}
				Gui.igEndCombo();
			}
			if (changed)
				return true;
			switch (init.ValueKind)
			{
			case .Literal, .EnumCase, .Custom:
				PropertyGrid.Row("Value", (init.ValueKind == .Custom) ? "Any Beef expression" : "The starting value");
				String buf = scope .(valueBuf);
				let committed = DrawValueControl(id, t, init, buf, types);
				if (buf != valueBuf && !committed)
					valueBuf.Set(buf);
				if (committed)
					return true;
				if (init.ValueKind == .Literal && !valueBuf.IsEmpty)
				{
					String why = scope .();
					if ((t.Kind == .Integer || t.Kind == .Float) && !MemberInit.FormatNumber(valueBuf, t.BaseText, scope String()))
						why.AppendF("'{}' is not a number for {}: not written.", valueBuf, t.BaseText);
					else if (t.Kind == .Char && valueBuf.Length != 1)
						why.Append("A character value is one character: it is not written.");
					if (!why.IsEmpty)
					{
						PropertyGrid.WideRow();
						Gui.igSetCursorPosX(Gui.igGetCursorPosX() + 8 * Look.Scale);
						ErrorText(why);
					}
				}
			case .Construct:
				PropertyGrid.Row("Arguments", "What the value is made with: .(arguments)");
				String args = scope .(argsBuf);
				if (PropertyGrid.Text(scope $"##{id}cargs", args, let edited, false, null, "none"))
				{
					var a = StringView(args);
					a.Trim();
					init.Args.Set(a);
					return true;
				}
				if (edited)
					argsBuf.Set(args);
			default:
			}
			return false;
		}

		// ------------------------------------------------------------------ Add Variable

		/// Called when the Add Variable dialog's type text changes: the usual choice for it.
		void AddVarDefaults(InitType t)
		{
			switch (t.Kind)
			{
			case .Class, .String: mAddVarOwner = t.IsPointer ? .Pointer : .OwnedCreatedHere;
			case .Interface: mAddVarOwner = t.IsPointer ? .Pointer : .Reference;
			case .Struct: mAddVarOwner = t.IsPointer ? .Pointer : .ValueDefault;
			default: mAddVarOwner = t.IsPointer ? .Pointer : .None;
			}
			mAddVarValueKind = .None;
			mAddVarValue.Clear();
		}

		/// The Ownership / Initial value part of the Add Variable dialog. Fills `outInit` and the
		/// type to write (with or without `*`).
		void DrawAddVarInit(StringView typed, Member target, MemberInit outInit, String outType, bool isStatic = false)
		{
			let types = TypeService.Current;
			let t = MemberInit.TypeOf(typed, types);
			if (typed != mAddVarTypeSeen)
			{
				mAddVarTypeSeen.Set(typed);
				AddVarDefaults(t);
			}
			bool inClass = target == null || target.TypeKind == null || target.TypeKind == "class";
			outInit.Retarget(mAddVarOwner, t);
			outInit.Owner = mAddVarOwner;
			if (!t.IsValue || t.IsPointer)
			{
				Gui.Text("Ownership");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				if (OwnershipCombo("##avown", t, mAddVarOwner, inClass, isStatic, false, false, let picked))
				{
					mAddVarOwner = picked;
					mAddVarValueKind = .None;
					mAddVarValue.Clear();
				}
				if (t.Kind == .Unknown && !t.IsPointer && !t.BaseText.IsEmpty)
					NotIndexedHint(false);
			}
			outInit.Owner = mAddVarOwner;
			outInit.ValueKind = mAddVarValueKind;
			outInit.Value.Set(mAddVarValue);
			if (mAddVarOwner != .OwnedCreatedHere && mAddVarOwner != .OwnedCreatedLater && mAddVarOwner != .Appended && mAddVarOwner != .OwnedForRun)
			{
				List<InitValueKind> modes = scope .();
				ValueModes(mAddVarOwner, t, modes);
				Gui.Text("Initial Value");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				if (Gui.igBeginCombo("##avmode", scope String(ValueKindLabel(mAddVarValueKind, t)), 0))
				{
					for (let k in modes)
					{
						Gui.PushID((int32)k);
						if (Gui.Selectable(ValueKindLabel(k, t), k == mAddVarValueKind) && k != mAddVarValueKind)
						{
							StartValue(k, t, outInit, types);
							mAddVarValueKind = k;
							mAddVarValue.Set(outInit.Value);
							String shown = scope .();
							ValueBufFor(outInit, shown);
							mAddVarBuf.Set(shown);
							mAddVarEnumBuf.Set(shown);
						}
						Gui.PopID();
					}
					Gui.igEndCombo();
				}
				if (mAddVarValueKind == .Literal && t.Kind == .Bool)
				{
					bool on = mAddVarValue == "true";
					if (Gui.Checkbox(scope $"{(on ? "true" : "false")}##avb", &on))
						mAddVarValue.Set(on ? "true" : "false");
				}
				else if (mAddVarValueKind == .EnumCase)
				{
					Gui.igSetNextItemWidth(360 * Look.Scale);
					if (DrawValueControl("av", t, outInit, mAddVarEnumBuf, types)) // a kept buffer: a fresh one each frame lost what was typed
						mAddVarValue.Set(outInit.Value);
				}
				else if (mAddVarValueKind == .Literal || mAddVarValueKind == .Custom)
				{
					Gui.igSetNextItemWidth(360 * Look.Scale);
					if (Gui.igInputText("##avval", mAddVarBuf.Ptr, (.)mAddVarBuf.Capacity, 0, null, null))
					{
						String typedVal = scope .(mAddVarBuf.View);
						String lit = scope .();
						if (mAddVarValueKind == .Custom)
							lit.Set(typedVal);
						else if (t.Kind == .String || t.Kind == .StringView)
							MemberInit.QuoteString(typedVal, lit);
						else if (t.Kind == .Char)
						{
							String why = scope .();
							MemberInit.QuoteCharFor(typedVal, t.BaseText, lit, why);
						}
						else
							MemberInit.FormatNumber(typedVal, (t.Kind == .Integer || t.Kind == .Float) ? t.BaseText : "int", lit);
						mAddVarValue.Set(lit);
					}
					if (mAddVarValue.IsEmpty && mAddVarValueKind == .Literal)
						ErrorText(scope $"Type a value of {typed}.");
				}
				outInit.ValueKind = mAddVarValueKind;
				outInit.Value.Set(mAddVarValue);
				if (mAddVarValueKind == .Literal && mAddVarValue.IsEmpty)
					outInit.ValueKind = .None;
			}
			MemberInit.TypeFor(mAddVarOwner, typed, outType);
		}

		TextBuffer mAddVarBuf = new .(256) ~ delete _;
		/// What the Member box of an enum without known members shows while typed.
		String mAddVarEnumBuf = new .() ~ delete _;

		// ------------------------------------------------------------------ Local Variable nodes

		/// The Initial value rows of a Local Variable node whose value is not wired: the same
		/// modes as a member variable's, written into the value pin. True when the pin changed.
		bool DrawLocalInitRows(MethodGraph mg, Node node, ref bool commit, StringView id = "lv")
		{
			let valuePin = node.FindInput("value");
			if (valuePin == null || mg?.Graph == null || mg.Graph.IsLinked(valuePin))
				return false;
			let typeText = node.Text2;
			if (typeText == "var" || typeText == "let" || typeText.IsEmpty)
				return false;
			let types = TypeService.Current;
			let t = MemberInit.TypeOf(typeText, types);
			MemberInit init = scope .();
			init.ClassifyValue(valuePin.Default, t);
			if (init.Owner == .Custom || init.Owner == .OwnedCreatedHere || init.Owner == .Appended || init.Owner == .OwnedCreatedLater)
			{
				// A local holds what is made here as `new` / `scope`: that stays an expression.
				init.Owner = t.IsPointer ? .Pointer : (t.IsReferenceType ? .Reference : (t.Kind == .Struct ? .ValueDefault : .None));
				init.ValueKind = valuePin.Default.IsEmpty ? .None : .Custom;
				init.Value.Set(valuePin.Default);
			}
			String key = scope .();
			key.AppendF("local|{}|{}|{}", node.Id, valuePin.Default, typeText);
			if (key != mInitSyncKey && !Gui.igIsAnyItemActive())
			{
				mInitSyncKey.Set(key);
				ValueBufFor(init, mInitValueBuf);
				mInitArgsBuf.Set(init.Args);
			}
			if (!DrawValueRows(id, t, init, mInitValueBuf, mInitArgsBuf, types))
			{
				String line = scope .();
				line.AppendF("{} {}", typeText, node.Text);
				String v = scope .();
				init.ValueText(v);
				if (!v.IsEmpty)
					line.AppendF(" = {}", v);
				line.Append(';');
				InitPreviewLine(line);
				return false;
			}
			String v = scope .();
			init.ValueText(v);
			BeginEdit();
			valuePin.Default.Set(v);
			commit = true;
			return true;
		}
	}
}
