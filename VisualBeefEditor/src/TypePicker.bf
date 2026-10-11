using System;
using System.Collections;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// UE's variable-type picker: a button showing the type with its pin colour; clicking opens a
	/// searchable list (basic types, then every class / struct / enum / interface in the project)
	/// plus a container selector (single, array, List, nullable).
	extension EditorApp
	{
		TextBuffer mTypeSearch = new .(256) ~ delete _;
		String mTypePickerFor = new .() ~ delete _;
		bool mTypeSearchFocus;
		int32 mTypeContainer;

		static StringView[?] sBasicTypes = .("bool", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
			"float", "double", "char8", "char32", "String", "StringView", "Object");

		/// What the picked type is for is a `TypeSlot` (TypeSlotRules in the core says what each
		/// accepts): `void` only as a Return Type, `var` / `let` only on locals and For Each
		/// elements, `Self` only inside a type, generic parameters only those declared here.
		/// The list offers only what fits; a typed type that does not fit gets the reason and
		/// is not applied (the typed text stays in the search box).
		String mTypeError = new .() ~ delete _;

		bool ProjectHasType(StringView name)
		{
			for (let f in Index.Files)
				for (let t in f.Types)
					if (t.Name == name)
						return true;
			return false;
		}

		/// The scope a type written in `scopeOf` sees (null: nothing known about generics).
		TypeScope TypeScopeOf(Member scopeOf, String gen, delegate bool(StringView) known)
		{
			TypeScope sc = default;
			if (scopeOf != null)
				sc = scopeOf.GetTypeScope(gen);
			else
				sc.InType = true;
			sc.Known = known;
			return sc;
		}

		/// Draws the reason in red under a field whose current text does not fit its place.
		/// True when it fits.
		public bool TypeErrorText(StringView type, TypeSlot slot, Member scopeOf)
		{
			String gen = scope .();
			delegate bool(StringView) known = scope (n) => ProjectHasType(n);
			String why = scope .();
			if (type.IsEmpty || TypeSlotRules.Check(type, slot, TypeScopeOf(scopeOf, gen, known), why))
				return true;
			ErrorText(why);
			return false;
		}

		/// The same for a parameter list typed as text ("int a, ref Foo b").
		public bool ParamsErrorText(StringView text, Member scopeOf)
		{
			String gen = scope .();
			delegate bool(StringView) known = scope (n) => ProjectHasType(n);
			String why = scope .();
			if (text.IsEmpty || TypeSlotRules.CheckParamList(text, TypeScopeOf(scopeOf, gen, known), why))
				return true;
			ErrorText(why);
			return false;
		}

		// The edits behind the type fields. Each one writes nothing and says why when the type
		// does not fit its place (the SourceDocument checks again, so a typed text from any
		// route is covered); the Properties panel, the Add dialogs and the session self test
		// all go through these.

		public bool ApplySignature(SourceDocument doc, Member method, StringView ret, StringView pars)
		{
			doc.LastError.Clear();
			if (doc.SetSignature(method, ret, pars))
				return true;
			Notify.Warn(doc.LastError.IsEmpty ? "That signature cannot be applied." : doc.LastError);
			return false;
		}

		public bool ApplyVariableType(SourceDocument doc, Member field, StringView type)
		{
			doc.LastError.Clear();
			if (doc.SetMemberType(field, type))
				return true;
			Notify.Warn(doc.LastError.IsEmpty ? "That type cannot be applied here." : doc.LastError);
			return false;
		}

		public bool AddVariableChecked(SourceDocument doc, Member type, StringView varType, StringView name, StringView init, bool setOnCreate = false, bool isStatic = false)
		{
			doc.LastError.Clear();
			if (doc.AddFieldSetOnCreate(type, varType, name, init, setOnCreate, isStatic))
			{
				if (!doc.LastError.IsEmpty)
					Notify.Warn(scope $"Variable added, but not set on create: {doc.LastError}");
				return true;
			}
			Notify.Warn(doc.LastError.IsEmpty ? "That variable cannot be added." : doc.LastError);
			return false;
		}

		public bool AddVariableChecked(SourceDocument doc, Member type, StringView varType, StringView name, MemberInit init, bool setOnCreate = false, bool isStatic = false)
		{
			doc.LastError.Clear();
			if (doc.AddFieldSetOnCreate(type, varType, name, init, setOnCreate, isStatic))
			{
				if (!doc.LastError.IsEmpty)
					Notify.Warn(scope $"Variable added, but not set on create: {doc.LastError}");
				return true;
			}
			Notify.Warn(doc.LastError.IsEmpty ? "That variable cannot be added." : doc.LastError);
			return false;
		}

		/// A red, wrapped message with the error icon.
		public static void ErrorText(StringView msg)
		{
			Gui.igPushTextWrapPos(0);
			Gui.TextColored(Theme.NodeError, scope $"{Icon.Error}  {msg}");
			Gui.igPopTextWrapPos();
		}

		/// Splits "List<Foo>" / "Foo[]" / "Foo?" into the element type and a container index
		/// (0 single, 1 array, 2 List, 3 nullable).
		static void SplitContainer(StringView type, String outElement, out int32 container)
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

		static void JoinContainer(StringView element, int32 container, String outType)
		{
			switch (container)
			{
			case 1: outType.AppendF("{}[]", element);
			case 2: outType.AppendF("List<{}>", element);
			case 3: outType.AppendF("{}?", element);
			default: outType.Append(element);
			}
		}

		/// Draws a type pill (pin colour) at the cursor and advances past it.
		static void TypePill(StringView type, float h)
		{
			let p = Gui.igGetCursorScreenPos();
			let col = Theme.TypeColor(type);
			Gui.ImDrawList_AddRectFilled(Gui.igGetWindowDrawList(), .(p.x, p.y + h * 0.3f), .(p.x + 14 * Look.Scale, p.y + h * 0.7f), col, 4 * Look.Scale, 0);
			Gui.igDummy(.(18 * Look.Scale, h));
			Gui.SameLine(0, 0);
		}

		/// The type button + picker popup. Returns true when `type` changed.
		public bool TypeButton(StringView id, String type, float width = -1, TypeSlot slot = .Member, Member scopeOf = null)
		{
			bool changed = false;
			Gui.PushID(id);
			float h = Gui.igGetFrameHeight();
			let start = Gui.igGetCursorScreenPos();
			float w = (width < 0) ? Gui.igGetContentRegionAvail().x : width;
			Gui.igPushStyleColor_U32(Col.Button, Look.Input);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(30, 30, 30));
			Gui.igPushStyleVar_Vec2(StyleVarX.ButtonTextAlign, .(0, 0.5f));
			String label = scope .();
			label.AppendF("      {}", type.IsEmpty ? "(none)" : type);
			bool open = Gui.Button(label, .(w, h));
			if (!mSelfTestPickerId.IsEmpty && mSelfTestPickerId == id)
			{
				open = true;
				mSelfTestPickerId.Clear();
			}
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(2);
			// Pill + chevron drawn over the button.
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, .(start.x + 8 * Look.Scale, start.y + h * 0.3f), .(start.x + 22 * Look.Scale, start.y + h * 0.7f), Theme.TypeColor(type), 4 * Look.Scale, 0);
			Gui.DrawText(dl, .(start.x + w - Gui.igGetFontSize() * 1.3f, start.y + (h - Gui.igGetFontSize()) * 0.5f), Look.ForegroundDim, Icon.ChevronDown);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(scope $"{type}\nClick to pick a type");
			if (open)
			{
				Gui.OpenPopup("##typepicker");
				mTypeSearch.Set(mSelfTestPickerSearch);
				mSelfTestPickerSearch.Clear();
				mTypeError.Clear();
				mTypeSearchFocus = true;
				String element = scope .();
				SplitContainer(type, element, out mTypeContainer);
			}
			Gui.igSetNextWindowSize(.(Math.Max(w, 300 * Look.Scale), 420 * Look.Scale), Cond.Always);
			if (Look.BeginPopupSpaced("##typepicker"))
			{
				if (mSelfTestCloseDialog)
				{
					mSelfTestCloseDialog = false;
					Gui.igCloseCurrentPopup();
				}
				String element = scope .();
				int32 curContainer;
				SplitContainer(type, element, out curContainer);
				String gen = scope .();
				delegate bool(StringView) known = scope (n) => ProjectHasType(n);
				TypeScope sc = TypeScopeOf(scopeOf, gen, known);
				// Container selector, like UE's single / array / set / map dropdown.
				StringView[4] containers = .("Single", "Array", "List", "Nullable");
				for (int i < 4)
				{
					if (i > 0)
						Gui.SameLine(0, 2);
					bool sel = mTypeContainer == i;
					Gui.igPushStyleColor_U32(Col.Button, sel ? Look.Primary : Look.Dropdown);
					if (Gui.Button(containers[i]))
					{
						String joined = scope .();
						JoinContainer(element, (int32)i, joined);
						String why = scope .();
						if (TypeSlotRules.Check(joined, slot, sc, why))
						{
							mTypeContainer = (int32)i;
							type.Set(joined);
							changed = true;
							mTypeError.Clear();
						}
						else
							mTypeError.Set(why);
					}
					Gui.igPopStyleColor(1);
				}
				if (mTypeSearchFocus)
				{
					Gui.igSetKeyboardFocusHere(0);
					mTypeSearchFocus = false;
				}
				Gui.igSetNextItemWidth(-1);
				bool enter = Gui.igInputTextWithHint("##tsearch", scope $"{Icon.Search}  Search types", mTypeSearch.Ptr, (.)mTypeSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				var search = mTypeSearch.View;
				search.Trim();
				String picked = scope .();
				if (Gui.igBeginChild_Str("##tlist", .(0, 0), 0, 0))
				{
					String first = scope .();
					// Free-form entry (generic instances, corlib types the index doesn't know): only
					// what fits this place; otherwise the reason, and the text stays as typed.
					if (!search.IsEmpty)
					{
						String why = scope .();
						if (TypeSlotRules.Check(search, slot, sc, why))
						{
							if (Gui.Selectable(scope $"{Icon.Pencil}  Use \"{search}\""))
								picked.Set(search);
							first.Set(search);
						}
						else
							ErrorText(why);
					}
					if (!mTypeError.IsEmpty)
						ErrorText(mTypeError);
					DrawTypeGroup("Basic", Icon.Hash, search, picked, first, true, scope (list) =>
					{
						if (slot == .Return)
							list.Add(new String("void"));
						for (let t in sBasicTypes)
							list.Add(new String(t));
						if (sc.InType && slot != .Base)
							list.Add(new String("Self"));
						if (slot == .Local || slot == .ForEach)
						{
							list.Add(new String("var"));
							list.Add(new String("let"));
						}
						else if (slot == .Return && sc.Comptime)
							list.Add(new String("var"));
					});
					if (sc.GenericsKnown && !sc.Generics.IsEmpty && slot != .Base)
					{
						DrawTypeGroup("Generic parameters", Icon.Hash, search, picked, first, true, scope [&] (list) =>
						{
							for (var g in sc.Generics.Split(','))
							{
								g.Trim();
								if (!g.IsEmpty)
									list.Add(new String(g));
							}
						});
					}
					StringView[4] kinds = .("class", "struct", "enum", "interface");
					StringView[4] titles = .("Classes", "Structs", "Enums", "Interfaces");
					StringView[4] icons = .(Icon.Class, Icon.Struct, Icon.Enum, Icon.Interface);
					for (int k < 4)
					{
						DrawTypeGroup(titles[k], icons[k], search, picked, first, !search.IsEmpty || k < 2, scope [&] (list) =>
						{
							for (let f in Index.Files)
								for (let t in f.Types)
								{
									if (t.Kind != kinds[k])
										continue;
									if (slot == .Construct && (kinds[k] == "enum" || kinds[k] == "interface"))
										continue; // cannot be made with new / scope
									bool dup = false;
									for (let s in list)
										if (s == t.Name)
											dup = true;
									if (!dup)
										list.Add(new String(t.Name));
								}
						});
					}
					if (enter && picked.IsEmpty && !first.IsEmpty)
						picked.Set(first);
				}
				Gui.igEndChild();
				if (!picked.IsEmpty)
				{
					// The row is checked alone; with the container around it (List<var>, void[])
					// it may not fit this place: then the reason, and nothing is written.
					String joined = scope .();
					JoinContainer(picked, mTypeContainer, joined);
					String why = scope .();
					if (TypeSlotRules.Check(joined, slot, sc, why))
					{
						type.Set(joined);
						changed = true;
						mTypeError.Clear();
						Gui.igCloseCurrentPopup();
					}
					else
						mTypeError.Set(why);
				}
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				Look.EndPopupSpaced();
			}
			Gui.PopID();
			return changed;
		}

		void DrawTypeGroup(StringView title, StringView icon, StringView search, String picked, String first, bool defaultOpen, delegate void(List<String>) fill)
		{
			List<String> all = scope .();
			defer { ClearAndDeleteItems!(all); }
			fill(all);
			all.Sort(scope (a, b) => String.Compare(a, b, true));
			List<String> shown = scope .();
			for (let t in all)
				if (search.IsEmpty || t.IndexOf(search, true) >= 0)
					shown.Add(t);
			if (shown.IsEmpty)
				return;
			if (!search.IsEmpty)
				Gui.igSetNextItemOpen(true, Cond.Always);
			if (Gui.TreeNode(scope $"{icon}  {title} ({shown.Count})", defaultOpen ? TreeNodeFlags.DefaultOpen : 0))
			{
				float h = Gui.igGetTextLineHeight();
				int count = 0;
				for (let t in shown)
				{
					if (first.IsEmpty)
						first.Set(t);
					TypePill(t, h);
					if (Gui.Selectable(t))
						picked.Set(t);
					if (++count >= 400)
					{
						Gui.TextDisabled("... refine the search");
						break;
					}
				}
				Gui.TreePop();
			}
		}
	}
}
