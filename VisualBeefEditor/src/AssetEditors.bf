using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Editor
{
	/// An editable row of an asset editor (enum case or variable): persistent input buffers.
	class AssetRow
	{
		public TextBuffer A = new .(256) ~ delete _;
		public TextBuffer B = new .(256) ~ delete _;
		public TextBuffer C = new .(1024) ~ delete _;
		/// Name the row had in the source (variables: what to rename).
		public String Orig = new .() ~ delete _;
		public String OrigType = new .() ~ delete _;
	}

	/// A non-graph tab in the "Graph" dock window: the Enum editor, or a type's overview (used
	/// when a class/struct/interface has no function to open yet). Kept separate from GraphTab
	/// (GraphPanel.bf) on purpose.
	class AssetTab
	{
		public enum TabKind { Enum, Type }
		public TabKind Kind;
		public AssetKind Asset;
		public String FilePath = new .() ~ delete _;
		public String TypeName = new .() ~ delete _;
		public int32 SyncedVersion = -1;
		public bool Editable = true;
		public List<AssetRow> Rows = new .() ~ DeleteContainerAndItems!(_);
		public List<AssetRow> VarRows = new .() ~ DeleteContainerAndItems!(_);
		public String Error = new .() ~ delete _;
	}

	extension EditorApp
	{
		List<AssetTab> mAssetTabs = new .() ~ DeleteContainerAndItems!(_);
		AssetTab mSelectAssetTab;
		/// The asset tab shown in the Graph window this frame (null when a graph tab is).
		AssetTab mActiveAssetTab;
		AssetTab mLastActiveAsset;
		bool mSelectSourceFileTab;

		// Variable selected in Outline (its details show in the Properties panel).
		String mSelVarType = new .() ~ delete _;
		String mSelVarName = new .() ~ delete _;
		bool mSelVarActive;
		bool mSelVarSigPending;
		int mSelVarSig;
		String mSelVarSyncKey = new .() ~ delete _;
		int32 mSelVarSyncVersion = -1;
		TextBuffer mVarNameBuf = new .(256) ~ delete _;
		TextBuffer mVarTypeBuf = new .(256) ~ delete _;
		String mBPFocusKey = new .() ~ delete _;

		static StringView[?] sCommonTypes = .("bool", "int", "int32", "int64", "uint8", "uint32", "float", "double", "char8", "String", "StringView");

		// ------------------------------------------------------------------ tabs

		AssetTab FindAssetTab(AssetTab.TabKind kind, StringView path, StringView typeName)
		{
			for (let t in mAssetTabs)
				if (t.Kind == kind && t.TypeName == typeName && ProjectIndex.SamePath(t.FilePath, path))
					return t;
			return null;
		}

		AssetTab OpenAssetTab(AssetTab.TabKind kind, AssetKind asset, StringView path, StringView typeName)
		{
			var tab = FindAssetTab(kind, path, typeName);
			if (tab == null)
			{
				tab = new .();
				tab.Kind = kind;
				tab.Asset = asset;
				tab.FilePath.Set(path);
				tab.TypeName.Set(typeName);
				mAssetTabs.Add(tab);
			}
			mSelectAssetTab = tab;
			return tab;
		}

		void RemoveAssetTab(int index)
		{
			let tab = mAssetTabs[index];
			if (mSelectAssetTab == tab)
				mSelectAssetTab = null;
			if (mActiveAssetTab == tab)
				mActiveAssetTab = null;
			if (mLastActiveAsset == tab)
				mLastActiveAsset = null;
			mAssetTabs.RemoveAt(index);
			delete tab;
		}

		/// Closes asset tabs of a file (all of them when typeName is empty).
		void CloseAssetTabs(StringView path, StringView typeName)
		{
			for (int i = mAssetTabs.Count - 1; i >= 0; i--)
			{
				let t = mAssetTabs[i];
				if (ProjectIndex.SamePath(t.FilePath, path) && (typeName.IsEmpty || t.TypeName == typeName))
					RemoveAssetTab(i);
			}
		}

		void OpenEnumEditor(StringView pathIn, StringView typeNameIn)
		{
			String path = scope .(pathIn);
			String typeName = scope .(typeNameIn);
			let doc = OpenFile(path, false);
			if (doc == null)
				return;
			OpenAssetTab(.Enum, .Enum, path, typeName);
			Panels.Focus(Panels.GraphId);
		}

		/// Class / struct / interface / globals: the Blueprint editor. Opens the type's first
		/// function graph (or one already open), else the type's overview with "+ Add Function".
		void OpenTypeEditor(StringView pathIn, StringView typeNameIn)
		{
			String path = scope .(pathIn);
			String typeName = scope .(typeNameIn);
			let doc = OpenFile(path, false);
			if (doc == null)
				return;
			String prefix = scope .();
			prefix.AppendF("{}.", typeName);
			for (let tab in Tabs)
			{
				if (tab.Doc == doc && tab.MethodKey.StartsWith(prefix))
				{
					let mg = doc.FindMethod(tab.MethodKey);
					if (mg != null && mg.Graphable)
					{
						OpenTab(mg);
						Panels.Focus(Panels.GraphId);
						return;
					}
				}
			}
			for (let mg in doc.Methods)
			{
				if (mg.Graphable && mg.Owner != null && mg.Owner.Name == typeName)
				{
					OpenTab(mg);
					Panels.Focus(Panels.GraphId);
					return;
				}
			}
			AssetKind asset = .Class;
			let type = FindTypeMember(doc, typeName);
			if (type != null && type.TypeKind != null)
				AssetStyle.FromType(type.TypeKind, type.IsNodeLibrary, out asset);
			OpenAssetTab(.Type, asset, path, typeName);
			Panels.Focus(Panels.GraphId);
		}

		/// The type Outline focuses on: the open asset tab's, or the active graph's owner.
		void GetFocusType(String outName)
		{
			if (mActiveAssetTab != null)
			{
				if (ProjectIndex.SamePath(mActiveAssetTab.FilePath, Doc.FilePath))
					outName.Set(mActiveAssetTab.TypeName);
				return;
			}
			let tab = CurrentTab;
			if (tab == null || tab.Doc != Doc)
				return;
			let mg = CurrentMethod;
			if (mg != null && mg.Owner != null)
				outName.Set(mg.Owner.Name);
		}

		// ------------------------------------------------------------------ drawing

		void DrawAssetHeader(AssetTab tab, SourceDocument doc, StringView kindText)
		{
			let p = Gui.igGetCursorScreenPos();
			float s = Gui.igGetFrameHeight() * 2.2f;
			let dl = Gui.igGetWindowDrawList();
			let kc = AssetStyle.KindColor(tab.Asset);
			Gui.ImDrawList_AddRectFilled(dl, p, .(p.x + s, p.y + s), Theme.Mix(Gui.Color(26, 26, 26), kc, 0.3f), 5, 0);
			AssetStyle.DrawIcon(dl, tab.Asset, .(p.x + s / 2, p.y + s / 2), s * 0.8f, kc);
			Gui.igDummy(.(s, s));
			Gui.SameLine(0, 12);
			Gui.igBeginGroup();
			AssetStyle.Text(dl, tab.TypeName, Gui.igGetCursorScreenPos(), Gui.igGetFontSize() * 1.35f, Gui.Color(240, 240, 240));
			Gui.igDummy(.(Gui.CalcTextSize(tab.TypeName).x * 1.35f, Gui.igGetFontSize() * 1.4f));
			String rel = scope .();
			RelativeToRoot(tab.FilePath, rel);
			Gui.TextColored(kc, kindText);
			Gui.SameLine();
			Gui.TextDisabled(scope $"  {rel}{(doc != null && doc.Modified) ? "  (unsaved)" : ""}");
			Gui.igEndGroup();
			Gui.SameLine(Math.Max(Gui.igGetCursorPos().x + 20, Gui.igGetWindowSize().x - 200));
			Gui.igBeginDisabled(doc == null || !doc.Modified);
			if (Gui.Button("Save", .(70 * Look.Scale, 0)) && doc != null)
			{
				if (SaveDoc(doc))
					SetStatus(scope $"Saved {doc.FilePath}");
				UpdateTitle();
			}
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Source", .(70 * Look.Scale, 0)) && doc != null)
			{
				Doc = doc;
				mSelectSourceFileTab = true;
				Panels.Focus(Panels.BeefSourceId);
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Show the file in the Beef Source panel");
			Gui.igSpacing();
		}

		void DrawAssetTab(AssetTab tab)
		{
			let doc = FindDoc(tab.FilePath);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(14, 12));
			Gui.igPushStyleColor_U32(Col.ChildBg, Gui.Color(30, 30, 30));
			if (Gui.igBeginChild_Str("##assettab", .(0, 0), 1 << 1 /* AlwaysUseWindowPadding */, 0))
			{
				if (doc == null)
					Gui.TextDisabled("The file is no longer open.");
				else if (tab.Kind == .Enum)
					DrawEnumEditor(tab, doc);
				else
					DrawTypeOverview(tab, doc);
			}
			Gui.igEndChild();
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(1);
		}

		// ------------------------------------------------------------------ enum editor

		void SyncEnumRows(AssetTab tab, SourceDocument doc, Member type)
		{
			ClearAndDeleteItems!(tab.Rows);
			List<EnumCase> cases = scope .();
			defer { ClearAndDeleteItems!(cases); }
			tab.Editable = EnumCases.Parse(doc.Unit, type, cases);
			for (let ec in cases)
			{
				AssetRow row = new .();
				row.A.Set(ec.Name);
				row.B.Set(ec.Value);
				row.C.Set(ec.Comment);
				tab.Rows.Add(row);
			}
			tab.SyncedVersion = doc.Version;
		}

		/// Writes the rows back into the enum (one undo step). Returns false on invalid input.
		bool ApplyEnumRows(AssetTab tab, SourceDocument doc, Member type)
		{
			List<EnumCase> cases = scope .();
			defer { ClearAndDeleteItems!(cases); }
			tab.Error.Clear();
			for (let row in tab.Rows)
			{
				String name = scope .(row.A.View);
				name.Trim();
				String value = scope .(row.B.View);
				value.Trim();
				String err = scope .();
				if (!ValidateIdentifier(name, err))
				{
					tab.Error.Set(scope $"Row {@row.Index}: {err}");
					return false;
				}
				for (let other in cases)
				{
					if (other.Name == name)
					{
						tab.Error.Set(scope $"'{name}' is used twice.");
						return false;
					}
				}
				if (value.Contains(',') || value.Contains(';') || value.Contains('/'))
				{
					tab.Error.Set(scope $"Row {@row.Index}: the value can't contain ',', ';' or '/'.");
					return false;
				}
				String comment = scope .(row.C.View);
				comment.Trim();
				cases.Add(new EnumCase(name, value, comment));
			}
			if (!doc.SetEnumCases(type, cases))
			{
				tab.Error.Set("This enum's body can't be rewritten.");
				return false;
			}
			tab.SyncedVersion = -1;
			UpdateTitle();
			return true;
		}

		void DrawEnumEditor(AssetTab tab, SourceDocument doc)
		{
			let type = FindTypeMember(doc, tab.TypeName);
			if (type == null || type.TypeKind != "enum")
			{
				Gui.TextDisabled(scope $"Enum '{tab.TypeName}' is no longer in {tab.FilePath}.");
				return;
			}
			if (tab.SyncedVersion != doc.Version && !Gui.igIsAnyItemActive())
				SyncEnumRows(tab, doc, type);

			DrawAssetHeader(tab, doc, "Enum");
			if (!tab.Editable)
			{
				Gui.TextColored(Theme.Warning, "This enum uses syntax the editor doesn't rewrite (payload cases, attributes or strings).");
				Gui.TextDisabled("Edit it in the Beef Source panel (Source button).");
				return;
			}

			Gui.SeparatorText("Enumerators");
			bool apply = false;
			if (GreenButton("+ Add Enumerator"))
			{
				// Next free NewEnumeratorN
				for (int n = tab.Rows.Count; n < tab.Rows.Count + 1000; n++)
				{
					String candidate = scope .();
					candidate.AppendF("NewEnumerator{}", n);
					bool used = false;
					for (let r in tab.Rows)
						if (r.A.View == candidate)
							used = true;
					if (!used)
					{
						AssetRow row = new .();
						row.A.Set(candidate);
						tab.Rows.Add(row);
						break;
					}
				}
				apply = true;
			}
			Gui.SameLine();
			Gui.TextDisabled(scope $"{tab.Rows.Count} enumerator{(tab.Rows.Count == 1) ? "" : "s"}");
			Gui.igSpacing();

			// Column headers
			float x0 = Gui.igGetCursorPos().x;
			float avail = Gui.igGetContentRegionAvail().x;
			float nameW = Math.Clamp(avail * 0.3f, 140, 280);
			float valueW = 90;
			float buttonsW = 3 * (Gui.igGetFrameHeight() + 4) + 8;
			float commentW = Math.Max(120, avail - 34 - nameW - valueW - buttonsW - 30);
			Gui.TextDisabled("#");
			Gui.SameLine(x0 + 34);
			Gui.TextDisabled("Name");
			Gui.SameLine(x0 + 34 + nameW + 8);
			Gui.TextDisabled("Value");
			Gui.SameLine(x0 + 34 + nameW + valueW + 16);
			Gui.TextDisabled("Description");

			int moveFrom = -1;
			int moveTo = -1;
			int remove = -1;
			for (let row in tab.Rows)
			{
				int i = @row.Index;
				Gui.PushID((int32)i);
				Gui.igSetCursorPos(.(x0, Gui.igGetCursorPos().y));
				Gui.igAlignTextToFramePadding();
				Gui.TextDisabled(scope $"{i}");
				Gui.SameLine(x0 + 34);
				String rowErr = scope .();
				var rowName = row.A.View;
				rowName.Trim();
				bool nameOk = ValidateIdentifier(rowName, rowErr);
				if (!nameOk)
					Gui.igPushStyleColor_U32(Col.FrameBg, Gui.Color(110, 30, 30));
				Gui.igSetNextItemWidth(nameW);
				Gui.igInputText("##name", row.A.Ptr, (.)row.A.Capacity, 0, null, null);
				if (Gui.igIsItemDeactivatedAfterEdit())
					apply = true;
				if (!nameOk)
				{
					Gui.igPopStyleColor(1);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip(rowErr);
				}
				Gui.SameLine(x0 + 34 + nameW + 8);
				Gui.igSetNextItemWidth(valueW);
				Gui.igInputTextWithHint("##value", "auto", row.B.Ptr, (.)row.B.Capacity, 0, null, null);
				if (Gui.igIsItemDeactivatedAfterEdit())
					apply = true;
				Gui.SameLine(x0 + 34 + nameW + valueW + 16);
				Gui.igSetNextItemWidth(commentW);
				Gui.igInputTextWithHint("##comment", "(optional comment)", row.C.Ptr, (.)row.C.Capacity, 0, null, null);
				if (Gui.igIsItemDeactivatedAfterEdit())
					apply = true;
				Gui.SameLine();
				Gui.igBeginDisabled(i == 0);
				if (Gui.igArrowButton("##up", Dir.Up))
				{
					moveFrom = i;
					moveTo = i - 1;
				}
				Gui.igEndDisabled();
				Gui.SameLine(0, 4);
				Gui.igBeginDisabled(i == tab.Rows.Count - 1);
				if (Gui.igArrowButton("##down", Dir.Down))
				{
					moveFrom = i;
					moveTo = i + 1;
				}
				Gui.igEndDisabled();
				Gui.SameLine(0, 4);
				Gui.igPushStyleColor_U32(Col.Button, Gui.Color(90, 36, 36));
				Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(160, 50, 50));
				if (Gui.Button("X", .(Gui.igGetFrameHeight(), 0)))
					remove = i;
				Gui.igPopStyleColor(2);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove this enumerator");
				Gui.PopID();
			}
			if (tab.Rows.IsEmpty)
				Gui.TextDisabled("No enumerators. Click + Add Enumerator.");

			if (moveFrom >= 0)
			{
				let r = tab.Rows[moveFrom];
				tab.Rows[moveFrom] = tab.Rows[moveTo];
				tab.Rows[moveTo] = r;
				apply = true;
			}
			if (remove >= 0)
			{
				delete tab.Rows[remove];
				tab.Rows.RemoveAt(remove);
				apply = true;
			}
			Gui.igSpacing();
			if (!tab.Error.IsEmpty)
				Gui.TextColored(Gui.Color(255, 110, 100), tab.Error);
			Gui.igSpacing();
			Gui.TextWrappedDim("Edits are written into the enum's source right away (Ctrl+Z undoes them). Save with Ctrl+S or the Save button. A value left empty counts up from the previous one.");
			if (apply)
				ApplyEnumRows(tab, doc, type);
		}

		// ------------------------------------------------------------------ type overview

		void SyncVarRows(AssetTab tab, SourceDocument doc, Member type)
		{
			ClearAndDeleteItems!(tab.VarRows);
			if (type.Members != null)
			{
				for (let m in type.Members)
				{
					if (m.Kind != .Field && m.Kind != .Property)
						continue;
					AssetRow row = new .();
					row.A.Set(m.Name);
					row.B.Set((m.TypeText != null) ? m.TypeText : "");
					row.Orig.Set(m.Name);
					row.OrigType.Set((m.TypeText != null) ? m.TypeText : "");
					row.C.Set((m.Kind == .Property) ? "property" : "");
					tab.VarRows.Add(row);
				}
			}
			tab.SyncedVersion = doc.Version;
		}

		static Member FindField(Member type, StringView name)
		{
			if (type?.Members == null)
				return null;
			for (let m in type.Members)
				if ((m.Kind == .Field || m.Kind == .Property) && m.Name == name)
					return m;
			return null;
		}

		void DrawTypeOverview(AssetTab tab, SourceDocument doc)
		{
			let type = FindTypeMember(doc, tab.TypeName);
			if (type == null)
			{
				Gui.TextDisabled(scope $"'{tab.TypeName}' is no longer in {tab.FilePath}.");
				return;
			}
			if (tab.SyncedVersion != doc.Version && !Gui.igIsAnyItemActive())
				SyncVarRows(tab, doc, type);
			DrawAssetHeader(tab, doc, AssetStyle.KindLabel(tab.Asset));

			// Functions
			Gui.SeparatorText("Functions");
			int fnCount = 0;
			MethodGraph openMg = null;
			for (let mg in doc.Methods)
			{
				if (mg.Owner != type)
					continue;
				fnCount++;
				String label = scope .();
				label.AppendF("f  {}##{}", mg.Method.Name, mg.Key);
				if (!mg.Graphable)
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
				if (Gui.Selectable(label) && mg.Graphable)
					openMg = mg;
				if (!mg.Graphable)
				{
					Gui.igPopStyleColor(1);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Declaration without a body (nothing to graph)");
				}
			}
			if (fnCount == 0)
			{
				Gui.igSpacing();
				Gui.TextDisabled(scope $"{tab.TypeName} has no functions yet.");
			}
			if (GreenButton("+ Add Function"))
			{
				Doc = doc;
				mAddTargetType.Set(tab.TypeName);
				mNameBuf.Set("NewFunction");
				mTypeBuf.Set("void");
				mParamsBuf.Set("");
				mAddCtorMode = false;
				mOpenAddFunction = true;
			}

			// Variables (the main content of a struct)
			Gui.igSpacing();
			Gui.SeparatorText("Variables");
			bool changed = false;
			int remove = -1;
			float x0 = Gui.igGetCursorPos().x;
			if (!tab.VarRows.IsEmpty)
			{
				Gui.TextDisabled("Name");
				Gui.SameLine(x0 + 230);
				Gui.TextDisabled("Type");
			}
			for (let row in tab.VarRows)
			{
				Gui.PushID((int32)@row.Index);
				Gui.igSetNextItemWidth(220 * Look.Scale);
				Gui.igInputText("##vname", row.A.Ptr, (.)row.A.Capacity, 0, null, null);
				if (Gui.igIsItemDeactivatedAfterEdit())
				{
					String newName = scope .(row.A.View);
					newName.Trim();
					String err = scope .();
					if (newName != row.Orig && ValidateIdentifier(newName, err))
					{
						let field = FindField(type, row.Orig);
						if (field != null)
						{
							doc.RenameMember(field, newName);
							changed = true;
						}
					}
					else if (!err.IsEmpty)
						SetStatus(err);
				}
				if (!changed)
				{
					Gui.SameLine(x0 + 230);
					Gui.igSetNextItemWidth(180 * Look.Scale);
					Gui.igInputText("##vtype", row.B.Ptr, (.)row.B.Capacity, 0, null, null);
					bool typeDone = Gui.igIsItemDeactivatedAfterEdit();
					Gui.SameLine(0, 2);
					if (Gui.igBeginCombo("##vtypes", null, 1 << 6 /* NoPreview */))
					{
						for (let t in sCommonTypes)
						{
							if (Gui.Selectable(t))
							{
								row.B.Set(t);
								typeDone = true;
							}
						}
						Gui.igEndCombo();
					}
					if (typeDone)
					{
						String newType = scope .(row.B.View);
						newType.Trim();
						if (!newType.IsEmpty && newType != row.OrigType)
						{
							let field = FindField(type, row.Orig);
							if (field != null && doc.SetMemberType(field, newType))
								changed = true;
						}
					}
				}
				if (!changed)
				{
					Gui.SameLine();
					if (!row.C.View.IsEmpty)
					{
						Gui.TextDisabled(row.C.View);
						Gui.SameLine();
					}
					Gui.igPushStyleColor_U32(Col.Button, Gui.Color(90, 36, 36));
					Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(160, 50, 50));
					if (Gui.Button("X", .(Gui.igGetFrameHeight(), 0)))
						remove = @row.Index;
					Gui.igPopStyleColor(2);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Delete this variable");
				}
				Gui.PopID();
				if (changed)
					break; // the parse changed: rows re-sync next frame
			}
			if (!changed && remove >= 0)
			{
				let field = FindField(type, tab.VarRows[remove].Orig);
				if (field != null)
				{
					doc.DeleteMember(field);
					changed = true;
				}
			}
			if (tab.VarRows.IsEmpty)
				Gui.TextDisabled("No variables.");
			if (!changed && GreenButton("+ Add Variable"))
			{
				Doc = doc;
				OpenAddVariable(tab.TypeName, (tab.Asset == .Struct) ? "NewField" : "mNewVar");
			}
			if (changed)
			{
				tab.SyncedVersion = -1;
				UpdateTitle();
			}
			if (openMg != null && !changed)
				OpenTab(openMg);
		}

		// Variable details: see PropertiesPanel.bf (DrawVariableDetails).
	}
}
