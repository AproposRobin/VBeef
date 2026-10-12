using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// The Outline panel, styled like UE's: a search box, the class header, and category
	/// bars (FUNCTIONS / VARIABLES) with a count and a "+" on the right; rows carry an icon or a
	/// type-coloured pill. Behaviour (open, drag into the graph, rename / delete menus) is
	/// unchanged.
	extension EditorApp
	{
		TextBuffer mBPSearch = new .(128) ~ delete _;
		HashSet<String> mBPClosed = new .() ~ DeleteContainerAndItems!(_);

		/// UE category bar. Returns whether the section is open; `addClicked` reports the "+".
		bool BPSection(StringView id, StringView title, int count, out bool addClicked, StringView addTip)
		{
			addClicked = false;
			float h = Gui.igGetFrameHeight();
			let p = Gui.igGetCursorScreenPos();
			float w = Gui.igGetContentRegionAvail().x;
			String key = scope .(id);
			if (!mOlRecording) {}
			else if (title == "FUNCTIONS")
				mOlFunctionsY = p.y;
			else if (title == "VARIABLES")
				mOlVarsY = p.y;
			else if (title == "LOCAL VARIABLES")
			{
				mOlLocalsY = p.y;
				mOlLocalsCount = count;
			}
			bool open = !mBPClosed.Contains(key);
			Gui.PushID(id);
			bool clicked = Gui.igInvisibleButton("##sec", .(w - h - 2, h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			let dl = Gui.igGetWindowDrawList();
			Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + w, p.y + h), hovered ? Gui.Color(56, 56, 56) : Look.Header, 2 * Look.Scale, 0);
			float fs = Gui.igGetFontSize();
			float ty = p.y + (h - fs) * 0.5f;
			Gui.DrawText(dl, .(p.x + 4 * Look.Scale, ty), Look.ForegroundDim, open ? Icon.ChevronDown : Icon.ChevronRight);
			Gui.DrawText(dl, .(p.x + fs * 1.3f, ty), Gui.Color(215, 215, 215), title);
			float tw = Gui.CalcTextSize(title).x;
			Gui.DrawText(dl, .(p.x + fs * 1.3f + tw + 8 * Look.Scale, ty), Look.ForegroundDim, scope $"{count}");
			if (clicked)
			{
				if (open)
					mBPClosed.Add(new String(key));
				else if (mBPClosed.GetAndRemove(key) case .Ok(let s))
					delete s;
				open = !open;
			}
			Gui.SameLine(0, 2);
			// The "+" is drawn by hand, centred on the glyph's measured size: a framed button put the icon font's
			// glyph off-centre inside its highlight.
			let bp = Gui.igGetCursorScreenPos();
			bool addHit = Gui.igInvisibleButton("##add", .(h, h), ButtonFlags.MouseButtonLeft);
			bool addHovered = Gui.igIsItemHovered(0);
			Gui.ImDrawList_AddRectFilled(dl, bp, .(bp.x + h, bp.y + h), addHovered ? Look.Primary : Look.Header, 2 * Look.Scale, 0);
			let gs = Gui.CalcTextSize(Icon.Plus);
			Gui.DrawText(dl, .(bp.x + (h - gs.x) * 0.5f, bp.y + (h - gs.y) * 0.5f), Gui.Color(215, 215, 215), Icon.Plus);
			if (addHit)
				addClicked = true;
			if (addHovered)
				Gui.Tooltip(addTip);
			Gui.PopID();
			return open;
		}

		void DrawOutlinePanel()
		{
			ClearAndDeleteItems!(mMembers);
			OlResetRecord();
			if (Gui.Begin(Panels.Outline))
			{
				if (Doc.Unit == null || Doc.FilePath.IsEmpty)
					Gui.TextDisabled("Open a .bf file to see its types.");
				else
				{
					// Search box like UE's.
					Gui.igSetNextItemWidth(-1);
					Gui.igInputTextWithHint("##bpsearch", scope $"{Icon.Search}  Search", mBPSearch.Ptr, (.)mBPSearch.Capacity, 0, null, null);
					Gui.igSpacing();
					List<Member> types = scope .();
					Doc.Unit.CollectTypes(types);
					if (types.IsEmpty)
						Gui.TextDisabled("No types in this file.");
					// The asset being edited (Project Browser / active graph) comes first and open,
					// the file's other types below it, collapsed.
					String focusName = scope .();
					GetFocusType(focusName);
					int focusIndex = -1;
					for (let type in types)
					{
						if (type.Name == focusName)
						{
							focusIndex = @type.Index;
							break;
						}
					}
					if (focusIndex > 0)
					{
						let f = types[focusIndex];
						types.RemoveAt(focusIndex);
						types.Insert(0, f);
						focusIndex = 0;
					}
					String focusKey = scope .();
					focusKey.AppendF("{}|{}", Doc.FilePath, focusName);
					bool focusChanged = focusKey != mBPFocusKey;
					if (focusChanged)
						mBPFocusKey.Set(focusKey);
					for (let type in types)
					{
						bool isFocus = @type.Index == focusIndex;
						if (@type.Index == 1 && focusIndex == 0)
						{
							Gui.igSpacing();
							Gui.TextDisabled("Other types in this file");
						}
						Gui.PushID((int32)@type.Index);
						AssetKind kind = .Class;
						bool known = type.TypeKind != null && AssetStyle.FromType(type.TypeKind, type.IsNodeLibrary, out kind);
						StringView icon = Icon.Class;
						if (known)
						{
							switch (kind)
							{
							case .Struct: icon = Icon.Struct;
							case .Enum: icon = Icon.Enum;
							case .Interface: icon = Icon.Interface;
							case .Library: icon = Icon.Boxes;
							default:
							}
						}
						String header = scope .();
						header.AppendF("{}  {}  ", icon, type.Name);
						// Enums and empty types start collapsed so classes stay easy to find.
						bool hasCode = false;
						if (type.Members != null)
							for (let m in type.Members)
								if (m.Kind == .Method || m.Kind == .Field || m.Kind == .Property)
									hasCode = true;
						bool isEnum = type.TypeKind == "enum";
						if (focusChanged && focusIndex >= 0)
							Gui.igSetNextItemOpen(isFocus, Cond.Always);
						uint32 kindCol = known ? AssetStyle.KindColor(kind) : Look.AccentBlue;
						Gui.igPushStyleColor_U32(Col.Header, isFocus ? Theme.Mix(Look.Header, kindCol, 0.35f) : Look.Recessed);
						Gui.igPushStyleColor_U32(Col.HeaderHovered, Theme.Mix(Look.Dropdown, kindCol, 0.35f));
						Gui.igPushStyleColor_U32(Col.Text, (isEnum && !isFocus) ? Theme.TextDim : Look.ForegroundHover);
						bool open = Gui.CollapsingHeader(header, (hasCode && !isEnum) ? TreeNodeFlags.DefaultOpen : 0);
						Gui.igPopStyleColor(3);
						// The kind ("class", "struct" ...) dimmed at the right of the header.
						{
							let min = Gui.igGetItemRectMin();
							let max = Gui.igGetItemRectMax();
							StringView k = (type.TypeKind != null) ? type.TypeKind : "type";
							if (type.IsNodeLibrary)
								k = "node library";
							float kw = Gui.CalcTextSize(k).x;
							Gui.DrawText(Gui.igGetWindowDrawList(), .(max.x - kw - 8 * Look.Scale, min.y + (max.y - min.y - Gui.igGetFontSize()) * 0.5f), Look.ForegroundDim, k);
						}
						if (open)
						{
							// UE's Type Settings: Details shows the type's declaration.
							{
								bool csSel = mSelClassActive && mSelClassName == type.Name;
								if (Gui.Selectable(scope $"    {Icon.SlidersHorizontal}  Type Settings##cs", csSel))
									SelectTypeSettings(type.Name);
								if (Gui.igIsItemHovered(0))
									Gui.Tooltip("Parent class, interfaces, modifiers, attributes, generics");
								if (!isEnum && type.TypeKind != "static")
								{
									let info = ClassInfoFor(Doc, type);
									if (!info.Problems.IsEmpty)
									{
										Gui.igPushStyleColor_U32(Col.Text, Theme.NodeError);
										if (Gui.Selectable(scope $"    {Icon.Error}  {info.Problems.Count} problem{(info.Problems.Count == 1) ? "" : "s"}##csp"))
											SelectTypeSettings(type.Name);
										Gui.igPopStyleColor(1);
										if (Gui.igIsItemHovered(0))
										{
											String tip = scope .();
											for (let p in info.Problems)
												tip.AppendF("{}\n", p);
											Gui.Tooltip(tip);
										}
									}
								}
							}
							if (isEnum)
							{
								if (Gui.Button(scope $"{Icon.Enum}  Open Enum Editor"))
								{
									OpenEnumEditor(scope String(Doc.FilePath), scope String(type.Name));
									Gui.PopID();
									break; // the editor may switch documents
								}
								List<EnumCase> cases = scope .();
								defer { ClearAndDeleteItems!(cases); }
								EnumCases.Parse(Doc.Unit, type, cases);
								for (let ec in cases)
									Gui.TextDisabled(scope $"    {ec.Name}{ec.Value.IsEmpty ? "" : " = "}{ec.Value}");
							}
							else if (DrawTypeMembers(type, @type.Index == 0))
							{
								Gui.PopID();
								break; // the parse changed: members are gone
							}
						}
						Gui.PopID();
					}
				}
			}
			Gui.End();
		}

		bool BPMatches(StringView name)
		{
			var s = mBPSearch.View;
			s.Trim();
			return s.IsEmpty || name.IndexOf(s, true) >= 0;
		}

		/// Returns true when it changed the document (the caller must stop using its Members).
		bool DrawTypeMembers(Member type, bool isFirstType = false)
		{
			if (type.Members == null)
				return false;
			int fnCount = 0;
			int varCount = 0;
			for (let m in type.Members)
			{
				if (m.Kind == .Method || m.Kind == .Broken)
					fnCount++;
				else if (m.Kind == .Field || m.Kind == .Property)
					varCount++;
			}
			float fs = Gui.igGetFontSize();
			// The type that shows the LOCAL VARIABLES section (the one holding the open function, or the
			// first one when no Sheet is open): the self test reads where its bars were drawn.
			let openMg = OpenLocalsGraph();
			bool showsLocals = (openMg != null) ? TypeOwnsGraph(type, openMg) : isFirstType;
			if (showsLocals)
				OlResetRecord();
			mOlRecording = showsLocals;
			String secId = scope $"fn|{type.Name}";
			bool fnOpen = BPSection(secId, "FUNCTIONS", fnCount, let addFn, "Add a function, override, constructor, property...");
			let versionBefore = Doc.Version;
			if (addFn)
				Gui.OpenPopup("##addmember");
			if (Gui.BeginPopup("##addmember"))
			{
				DrawAddMemberMenu(type);
				Gui.EndPopup();
			}
			if (Doc.Version != versionBefore)
				return true;
			if (fnOpen && type.TypeKind != "interface" && type.TypeKind != "enum" && type.TypeKind != "static" && !type.IsNodeLibrary)
			{
				let info = ClassInfoFor(Doc, type);
				if (!info.Overridable.IsEmpty)
				{
					Gui.igIndent(14 * Look.Scale);
					bool selfTestOpen = mSelfTestOverrideMenu == type.Name;
					if (Gui.SmallButton(scope $"{Icon.ChevronDown}  Override ({info.Overridable.Count})##ovbtn") || selfTestOpen)
					{
						mSelfTestOverrideMenu.Clear();
						Gui.OpenPopup("##bpoverride");
					}
					if (selfTestOpen) // opened without a click: put it under the button, not at the mouse
						Gui.igSetNextWindowPos(.(Gui.igGetItemRectMin().x, Gui.igGetItemRectMax().y), Cond.Always, .(0, 0));
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Override a parent function (Tick, Initialize...) or implement an interface member");
					Gui.igUnindent(14 * Look.Scale);
					if (Gui.BeginPopup("##bpoverride"))
					{
						DrawOverrideItems(Doc, type);
						Gui.EndPopup();
					}
					if (Doc.Version != versionBefore)
						return true;
				}
			}
			let currentKey = (CurrentTab != null) ? CurrentTab.MethodKey : "";
			// Classes and structs always list a default Constructor and Destructor: dimmed until the
			// file has them; opening one writes it.
			if (fnOpen && SourceDocument.HasDefaultMembers(type))
			{
				for (int what < 2)
				{
					bool isDtor = what == 1;
					if ((isDtor ? SourceDocument.FindDtor(type) : SourceDocument.FindDefaultCtor(type)) != null)
						continue;
					StringView shown = isDtor ? "Destructor" : "Constructor";
					if (!BPMatches(shown))
						continue;
					Gui.PushID((int32)(30000 + what));
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
					bool clicked = Gui.Selectable(scope $"    {Icon.Function}  {shown}##default{what}", false, SelectableFlags.AllowDoubleClick);
					Gui.igPopStyleColor(1);
					if (!isDtor)
					{
						let min = Gui.igGetItemRectMin();
						let max = Gui.igGetItemRectMax();
						float nameW = Gui.CalcTextSize(scope $"    {Icon.Function}  {shown}").x + 8 * Look.Scale;
						Gui.DrawText(Gui.igGetWindowDrawList(), .(min.x + nameW, min.y + (max.y - min.y - fs) * 0.5f), Gui.Color(120, 120, 120), "()");
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Not written yet; open it to add it");
					Gui.PopID();
					if (clicked && Gui.igIsMouseDoubleClicked_Nil(0))
					{
						MaterializeDefaultMember(Doc, type, isDtor);
						return true;
					}
				}
			}
			for (let m in type.Members)
			{
				if (m.Kind != .Method && m.Kind != .Broken)
					continue;
				let mg = FindMethodGraph(m);
				if (mg == null)
					continue;
				if (m.Kind == .Broken)
				{
					// Code the parser could not read (docs/Parsing-and-Layout.md): a red row that
					// opens the read-only error node, with the parse error as its tooltip.
					if (!fnOpen || !BPMatches(m.Name))
						continue;
					Gui.PushID((int32)mMembers.Count);
					Gui.igPushStyleColor_U32(Col.Text, Theme.NodeError);
					String brokenLabel = scope .();
					if (m.Name.IsEmpty || m.Name == "?")
						brokenLabel.AppendF("    {}  unparsed member at line {}", Icon.Error, Doc.Unit.LineOf(Doc.Unit.Tokens[m.FirstTok].Start));
					else
						brokenLabel.AppendF("    {}  {} (unreadable)", Icon.Error, m.Name);
					if (Gui.Selectable(scope $"{brokenLabel}##{mg.Key}", mg.Key == currentKey))
					{
						mSelVarActive = false;
						OpenTab(mg);
					}
					Gui.igPopStyleColor(1);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope $"{(m.Error != null && !m.Error.IsEmpty) ? (StringView)m.Error : "The parser could not read this member."}\nIts text is kept in the file as it is. Click to see it; fix it in the File tab of Beef Source.");
					Gui.PopID();
					continue;
				}
				String paramsText = scope .();
				for (let p in m.Params)
				{
					if (@p.Index > 0)
						paramsText.Append(", ");
					if (!p.Modifier.IsEmpty)
						paramsText.AppendF("{} ", p.Modifier);
					paramsText.AppendF("{} {}", p.Type, p.Name);
					if (p.Default != null)
						paramsText.AppendF(" = {}", p.Default);
				}
				// Every member stays registered for drag-drop even when its section is closed.
				if (!fnOpen || !BPMatches(m.Name))
				{
					AddMemberRef(.Function, m.Name, m.TypeText, paramsText, type.Name, m.IsStatic);
					continue;
				}
				String label = scope .();
				bool isOverride = Mods.Has(m.Modifiers, "override");
				StringView shown = m.IsCtor ? (m.IsStatic ? "Static Constructor" : "Constructor") : (m.IsDtor ? "Destructor" : StringView(m.Name));
				// A declaration error (`var Main()`): the row is red with the message as tooltip.
				String declError = scope .();
				bool hasDeclError = m.GetDeclError(declError);
				label.AppendF("    {}  {}", hasDeclError ? Icon.Error : (isOverride ? Icon.Play : Icon.Function), shown);
				// Methods in `#if` arms: the inactive arm is dimmed, the condition is in the tooltip.
				bool inactiveArm = m.CondPath != null && !Preprocessor.IsActive(m.CondPath);
				if (m.KeySuffix != null)
					label.AppendF("  [{}{}]", m.CondPath ?? "", inactiveArm ? ", inactive" : "");
				Gui.PushID((int32)mMembers.Count);
				bool selected = mg.Key == currentKey;
				if (hasDeclError)
					Gui.igPushStyleColor_U32(Col.Text, Theme.NodeError);
				else if (!mg.Graphable || inactiveArm)
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
				else if (isOverride)
					Gui.igPushStyleColor_U32(Col.Text, Gui.Color(240, 140, 120));
				if (Gui.Selectable(label, selected) && mg.Graphable)
				{
					mSelVarActive = false;
					mSelLocalActive = false;
					OpenTab(mg);
				}
				if (hasDeclError || !mg.Graphable || inactiveArm || isOverride)
					Gui.igPopStyleColor(1);
				// Parameters, dimmed, after the name.
				{
					let min = Gui.igGetItemRectMin();
					let max = Gui.igGetItemRectMax();
					float nameW = Gui.CalcTextSize(label).x + 8 * Look.Scale;
					String sig = scope .();
					if (m.IsCtor && !m.IsStatic)
						{
						String tt = scope .();
						SourceDocument.CtorTypesText(m, tt);
						sig.AppendF("({})", tt);
					}
					else
						sig.AppendF("({})", paramsText);
					float avail = max.x - min.x - nameW - 4;
					if (avail > fs * 2)
					{
						String fit = scope .();
						FitText(sig, avail, fit);
						Gui.DrawText(Gui.igGetWindowDrawList(), .(min.x + nameW, min.y + (max.y - min.y - fs) * 0.5f), Gui.Color(120, 120, 120), fit);
					}
				}
				if (Gui.igIsItemHovered(0))
				{
					String tip = scope $"{(m.TypeText != null) ? m.TypeText : "void"} {m.Name}({paramsText}){(mg.Graphable ? "" : "\n(no graph: no body)")}";
					if (m.CondPath != null)
						tip.AppendF("\n#{} ({})", m.CondPath, inactiveArm ? "inactive in this build" : "active");
					if (hasDeclError)
						tip.AppendF("\n{}", declError);
					Gui.Tooltip(tip);
				}
				AddMemberRef(.Function, m.Name, m.TypeText, paramsText, type.Name, m.IsStatic);
				if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
				{
					// The ghost (DragGhost.bf) follows the cursor.
					int32 idx = (int32)mMembers.Count - 1;
					Gui.igSetDragDropPayload("VB_MEMBER", &idx, sizeof(int32), 0);
					Gui.igEndDragDropSource();
				}
				if (Gui.igBeginPopupContextItem())
				{
					if (!m.IsCtor && !m.IsDtor && !m.IsAccessor && IconItem(Icon.Pencil, "Rename...", "F2"))
					{
						mRenameTarget = m;
						mRenameVersion = Doc.Version;
						mRenameKey.Set(mg.Key);
						mNameBuf.Set(m.Name);
						mOpenRename = true;
					}
					if (IconItem(Icon.Trash2, "Delete Function"))
					{
						Doc.DeleteMember(m);
						Gui.EndPopup();
						Gui.PopID();
						return true; // members list was rebuilt
					}
					Gui.EndPopup();
				}
				Gui.PopID();
			}

			Gui.igSpacing();
			secId.Set(scope $"var|{type.Name}");
			bool varOpen = BPSection(secId, "VARIABLES", varCount, let addVar, "Add a variable");
			if (addVar)
			{
				OpenAddVariable(type.Name, "mNewVar");
			}
			for (let m in type.Members)
			{
				if (m.Kind != .Field && m.Kind != .Property)
					continue;
				if (!varOpen || !BPMatches(m.Name))
				{
					if (!m.IsIndexer)
						AddMemberRef(.Variable, m.Name, m.TypeText, "", type.Name, m.IsStatic);
					continue;
				}
				if (m.IsIndexer)
				{
					// `T this[...]`: its accessors are graphs.
					Gui.PushID((int32)(20000 + @m.Index));
					String sig = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
							sig.Append(", ");
						sig.AppendF("{} {}", p.Type, p.Name);
					}
					Gui.Text(scope $"    {Icon.ListOrdered}  this[{sig}]");
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(scope $"Indexer: {m.TypeText} this[{sig}]");
					if (DrawAccessorRows(m, currentKey))
					{
						Gui.PopID();
						return true;
					}
					Gui.PopID();
					continue;
				}
				Gui.PushID((int32)(10000 + mMembers.Count));
				let cur = Gui.igGetCursorScreenPos();
				float h = Gui.igGetTextLineHeight();
				String label = scope .();
				label.AppendF("##var{}", m.Name);
				bool varSelected = mSelVarActive && mSelVarName == m.Name && mSelVarType == type.Name;
				if (Gui.Selectable(label, varSelected))
				{
					// Details shows the variable (name / type), like Blueprint's variable details.
					mSelVarType.Set(type.Name);
					mSelVarName.Set(m.Name);
					mSelVarActive = true;
					mSelLocalActive = false;
					mSelVarSigPending = true;
				}
				if (m.Name == SelfTestRowName)
					SelfTestRowAt = cur + ImVec2(60 * Look.Scale, h * 0.5f);
				// UE's variable pill in the type colour, and the type dimmed on the right.
				let dl = Gui.igGetWindowDrawList();
				// A type that does not fit a variable (`void x;`, `var x;`): red with the reason.
				String varError = scope .();
				bool varBad = m.GetDeclError(varError);
				let col = varBad ? Theme.NodeError : Theme.TypeColor(m.TypeText);
				Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), col, h * 0.3f, 0);
				Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), varBad ? Theme.NodeError : (varSelected ? Look.ForegroundHover : Look.Foreground), m.Name);
				{
					let max = Gui.igGetItemRectMax();
					StringView t = (m.TypeText != null) ? m.TypeText : "";
					String fit = scope .();
					float nameW = 42 * Look.Scale + Gui.CalcTextSize(m.Name).x + 12 * Look.Scale;
					FitText(t, Math.Max(0, max.x - cur.x - nameW), fit);
					float tw = Gui.CalcTextSize(fit).x;
					Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(varBad ? varError : scope $"{m.Name} : {m.TypeText}{m.IsStatic ? "  (static)" : ""}\nDrag onto a pin to wire it, or onto the Sheet: Ctrl = Get, Alt = Set");
				AddMemberRef(.Variable, m.Name, m.TypeText, "", type.Name, m.IsStatic);
				if (Gui.igBeginDragDropSource(DragNative.SourceNoPreviewTooltip))
				{
					// The ghost (DragGhost.bf) follows the cursor; on a pin it says what the drop does.
					int32 idx = (int32)mMembers.Count - 1;
					Gui.igSetDragDropPayload("VB_MEMBER", &idx, sizeof(int32), 0);
					Gui.igEndDragDropSource();
				}
				if (Gui.igBeginPopupContextItem())
				{
					if (IconItem(Icon.Pencil, "Rename...", "F2"))
					{
						mRenameTarget = m;
						mRenameVersion = Doc.Version;
						mRenameKey.Clear();
						mNameBuf.Set(m.Name);
						mOpenRename = true;
					}
					if (IconItem(Icon.Type, "Change Type..."))
					{
						mSelVarType.Set(type.Name);
						mSelVarName.Set(m.Name);
						mSelVarActive = true;
						mSelLocalActive = false;
						mSelVarSigPending = true;
						Panels.Focus(Panels.PropertiesId);
					}
					if (IconItem(Icon.Trash2, "Delete Variable"))
					{
						Doc.DeleteMember(m);
						Gui.EndPopup();
						Gui.PopID();
						return true;
					}
					Gui.EndPopup();
				}
				if (m.Kind == .Property && DrawAccessorRows(m, currentKey))
				{
					Gui.PopID();
					return true;
				}
				Gui.PopID();
			}
			// LOCAL VARIABLES: one fixed section directly below VARIABLES. Its rows are the locals of
			// the function whose Sheet is in front (they follow the Sheet; the section does not move).
			if (showsLocals)
			{
				mOlVarsEndY = Gui.igGetCursorScreenPos().y;
				Gui.igSpacing();
				if (DrawOutlineLocals(openMg, type.Name))
					return true;
			}
			return false;
		}

		/// The function whose Sheet is in front when it can have locals (a graph with a body that is
		/// not read-only), else null.
		MethodGraph OpenLocalsGraph()
		{
			let mg = CurrentMethod;
			if (mOlForceNoSheet || mg == null || mg.Doc != Doc || !mg.Graphable || mg.IsBroken || mg.Graph == null || mg.Graph.ReadOnly)
				return null;
			return mg;
		}

		/// Whether `mg` is a function (or property accessor) written in `type`.
		bool TypeOwnsGraph(Member type, MethodGraph mg)
		{
			if (type.Members == null)
				return false;
			for (let m in type.Members)
			{
				if (m.Kind == .Method && m == mg.Method)
					return true;
				if (m.Members != null && (m.Kind == .Property))
					for (let a in m.Members)
						if (a == mg.Method)
							return true;
			}
			return false;
		}

		/// `get` / `set` rows under a property or indexer: each opens its graph.
		bool DrawAccessorRows(Member prop, StringView currentKey)
		{
			if (prop.Members == null)
				return false;
			for (let a in prop.Members)
			{
				let amg = FindMethodGraph(a);
				bool graph = amg != null && amg.Graphable;
				StringView which = a.Name.EndsWith(".set") ? "set" : "get";
				if (!graph)
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
				bool clicked = Gui.Selectable(scope $"            {Icon.Function}  {which}{(graph ? "" : "  (no body)")}##acc{@a.Index}", amg != null && amg.Key == currentKey);
				if (!graph)
					Gui.igPopStyleColor(1);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(graph ? scope $"Open the {which} graph of {prop.Name}" : "An accessor without a body (get; / set; / =>): give it a body in the text to edit it as a graph");
				if (clicked && graph)
				{
					mSelVarActive = false;
					mSelClassActive = false;
					OpenTab(amg);
					return true;
				}
			}
			return false;
		}
	}
}
