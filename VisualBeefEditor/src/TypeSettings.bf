using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// A rename (or another multi-file edit) applied to several documents: undoing it in any of
	/// them undoes it in all (each document keeps its own undo stack; the group remembers the
	/// depth its step left each one at).
	class UndoGroup
	{
		public List<SourceDocument> Docs = new .() ~ delete _;
		public List<int> Depths = new .() ~ delete _;
		public String Label = new .() ~ delete _;
	}

	/// Type Settings (Details when the type itself is selected, like Unreal's), the class-level
	/// options of functions and variables, the Override dropdown, attribute lists, the parent /
	/// interface pickers, project-wide renames with a preview, and the multi-file undo groups.
	/// See docs/Classes-and-Members.md.
	extension EditorApp
	{
		bool mSelClassActive;
		String mSelClassName = new .() ~ delete _;
		/// ClassModel results per "path|type", with the version key they were computed for.
		Dictionary<String, (String key, ClassInfo info)> mClassInfos = new .() ~ { for (let kv in _) { delete kv.key; delete kv.value.key; delete kv.value.info; } delete _; };
		bool mOpenRenameLocal;
		String mRenameLocalOld = new .() ~ delete _;
		String mRenameLocalKey = new .() ~ delete _;
		/// Problems already written to the Output Log (per type), so they are logged once.
		String mClassLogged = new .() ~ delete _;

		List<UndoGroup> mUndoGroups = new .() ~ DeleteContainerAndItems!(_);
		List<UndoGroup> mRedoGroups = new .() ~ DeleteContainerAndItems!(_);

		RenamePlan mRenamePlan ~ delete _;
		/// Project Browser rename of a type whose file is named after it: moved once applied.
		String mPendingTypeFile = new .() ~ delete _;
		bool mOpenRenamePreview;

		TextBuffer mPickSearch = new .(128) ~ delete _;
		bool mPickFocus;
		String mClassEditBuf = new .() ~ delete _;
		String mClassEditFor = new .() ~ delete _;
		String mGenericBuf = new .() ~ delete _;
		String mConstraintBuf = new .() ~ delete _;
		String mNamespaceBuf = new .() ~ delete _;
		String mDefaultBuf = new .() ~ delete _;
		List<String> mAttrRows = new .() ~ DeleteContainerAndItems!(_);
		String mAttrRowsFor = new .() ~ delete _;

		// Add Property / Indexer
		bool mOpenAddProperty;
		bool mOpenAddIndexer;
		bool mNewPropSetter = true;
		bool mNewPropAuto;

		// Create Asset extras (Project Browser)
		String mCBNewParent = new .() ~ delete _;
		List<String> mCBNewInterfaces = new .() ~ DeleteContainerAndItems!(_);
		int32 mCBNewTemplate;
		bool mCBNewImplement = true;

		// ------------------------------------------------------------------ model access

		/// What ClassModel knows about `type` (cached per document version and index generation).
		ClassInfo ClassInfoFor(SourceDocument doc, Member type)
		{
			let svc = TypeService.Current;
			svc?.Sync();
			String slot = scope .();
			slot.AppendF("{}|{}", doc.FilePath, type.Name);
			String key = scope .();
			key.AppendF("{}|{}|{}", doc.Version, (svc != null) ? svc.Generation : -1, (svc != null && svc.Project != null) ? svc.Project.Version : -1);
			if (mClassInfos.TryGetValueAlt(slot, let cached) && cached.key == key)
				return cached.info;
			ClassInfo mClassInfo = new .();
			ClassModel.Analyze(doc.Unit, type, svc, mClassInfo);
			if (mClassInfos.TryGetAlt(slot, var oldKey, var old))
			{
				delete old.key;
				delete old.info;
				mClassInfos[oldKey] = (new String(key), mClassInfo);
			}
			else
				mClassInfos[new String(slot)] = (new String(key), mClassInfo);
			// Document-level errors go to the Output Log once per change.
			String logged = scope .();
			for (let p in mClassInfo.Problems)
				logged.AppendF("{}\n", p);
			String logKey = scope .();
			logKey.AppendF("{}|{}", type.Name, logged);
			if (logKey != mClassLogged)
			{
				mClassLogged.Set(logKey);
				for (let p in mClassInfo.Problems)
					Notify.LogAt(.Error, "Class", p, doc.FilePath, doc.Unit.LineOf(doc.Unit.Tokens[type.FirstTok].Start));
			}
			return mClassInfo;
		}

		Member FindTypeIn(SourceDocument doc, StringView name)
		{
			if (doc?.Unit == null)
				return null;
			List<Member> types = scope .();
			doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name && t.TypeKind != "extension")
					return t;
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		/// Shows Type Settings for a type of the current document.
		public void SelectTypeSettings(StringView typeName)
		{
			mSelClassName.Set(typeName);
			mSelClassActive = true;
			mSelLocalActive = false;
			mSelVarActive = false;
			mSelVarSigPending = true;
			Panels.Focus(Panels.PropertiesId);
		}

		/// After a class-level edit: reports a refusal (LastError) or marks the title dirty.
		void ClassEditResult(SourceDocument doc, bool ok, StringView what)
		{
			if (!ok)
			{
				SetStatus(scope $"{what}: {doc.LastError}", .Warning);
				return;
			}
			UpdateTitle();
		}

		// ------------------------------------------------------------------ group undo

		public int UndoDepthOf(SourceDocument doc) => doc.UndoDepth;

		/// Records that the last undo step of every document in `docs` belongs to one edit.
		void PushUndoGroup(List<SourceDocument> docs, StringView label)
		{
			if (docs.Count < 2)
				return;
			UndoGroup g = new .();
			g.Label.Set(label);
			for (let d in docs)
			{
				g.Docs.Add(d);
				g.Depths.Add(d.UndoDepth);
			}
			mUndoGroups.Add(g);
			ClearAndDeleteItems!(mRedoGroups);
		}

		/// Undo / redo in `doc`: when its top step belongs to a multi-file group, every file of
		/// the group steps back (or forward) together. Returns false when it is an ordinary step.
		public bool GroupUndo(SourceDocument doc, bool redo)
		{
			let stack = redo ? mRedoGroups : mUndoGroups;
			if (stack.IsEmpty)
				return false;
			let g = stack.Back;
			int at = g.Docs.IndexOf(doc);
			if (at < 0 || !mDocs.Contains(doc))
				return false;
			// The step must still be on top of the document's stack.
			int depth = redo ? doc.RedoDepth : doc.UndoDepth;
			int want = redo ? g.Depths[at] : g.Depths[at];
			if (depth != want)
				return false;
			for (int i < g.Docs.Count)
			{
				let d = g.Docs[i];
				if (!mDocs.Contains(d))
					continue;
				if (redo)
				{
					if (d.RedoDepth == g.Depths[i])
						d.Redo();
				}
				else if (d.UndoDepth == g.Depths[i])
					d.Undo();
			}
			stack.PopBack();
			// The opposite stack now holds the group at the depths left behind.
			for (int i < g.Docs.Count)
				g.Depths[i] = redo ? g.Docs[i].UndoDepth : g.Docs[i].RedoDepth;
			(redo ? mUndoGroups : mRedoGroups).Add(g);
			SetStatus(scope $"{(redo ? "Redid" : "Undid")} {g.Label} in {g.Docs.Count} files");
			return true;
		}

		// ------------------------------------------------------------------ renames

		/// Every project file as a rename / find-references source (open files with their live
		/// text); `texts` owns the strings the sources point at.
		void CollectProjectSources(List<RenameService.Source> sources, List<String> texts)
		{
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }
			void AddSource(StringView path)
			{
				String norm = scope .(path);
				norm.Replace('\\', '/');
				norm.ToLower();
				if (seen.Contains(norm))
					return;
				seen.Add(new String(norm));
				String text = new .();
				let d = FindDoc(path);
				if (d != null && d.Unit != null)
					text.Set(d.Text);
				else if (File.ReadAllText(path, text, true) case .Err)
				{
					delete text;
					return;
				}
				texts.Add(text);
				RenameService.Source s;
				s.Path = path;
				s.Text = text;
				sources.Add(s);
			}
			// Only the project: library sources are never rewritten.
			for (let f in Index.Files)
				if (f.Path.EndsWith(".bf", .OrdinalIgnoreCase) && (mProjectRoot.IsEmpty || f.Path.StartsWith(mProjectRoot, .OrdinalIgnoreCase) || FindDoc(f.Path) != null))
					AddSource(f.Path);
			for (let d in mDocs)
				if (!d.FilePath.IsEmpty)
					AddSource(d.FilePath);
		}

		/// Plans a rename over every project file (open files with their live text) and shows the
		/// preview; nothing changes until the user confirms.
		public void StartProjectRename(RenameKind kind, StringView oldName, StringView newName, StringView typeName, StringView methodKey, StringView filePath)
		{
			if (!CheckWritable())
				return;
			List<RenameService.Source> sources = scope .();
			List<String> texts = scope .();
			defer { ClearAndDeleteItems!(texts); }
			CollectProjectSources(sources, texts);
			RenameTarget t = scope .();
			t.Kind = kind;
			t.OldName.Set(oldName);
			t.NewName.Set(newName);
			t.TypeName.Set(typeName);
			t.MethodKey.Set(methodKey);
			t.FilePath.Set(filePath);
			delete mRenamePlan;
			mRenamePlan = new .();
			RenameService.Plan(t, sources, TypeService.Current, mRenamePlan);
			String summary = scope .();
			mRenamePlan.Summary(summary);
			if (!mRenamePlan.Refusal.IsEmpty)
				Notify.Log(.Warning, "Rename", scope $"Rename {oldName} -> {newName} refused: {mRenamePlan.Refusal}");
			else if (!mRenamePlan.Problems.IsEmpty)
			{
				Notify.Log(.Warning, "Rename", scope $"Rename {oldName} -> {newName} refused: {mRenamePlan.Problems.Count} reference(s) cannot be rewritten safely:");
				for (let p in mRenamePlan.Problems)
					Notify.Log(.Warning, "Rename", scope $"  {p}");
			}
			else
				Notify.Log(.Info, "Rename", scope $"Rename {oldName} -> {newName}: {summary}");
			mOpenRenamePreview = true;
		}

		/// The preview modal: counts, every reference, and why a rename is refused.
		void DrawRenamePreview()
		{
			if (mOpenRenamePreview)
			{
				Gui.OpenPopup("Rename References");
				mOpenRenamePreview = false;
			}
			Gui.igSetNextWindowSize(.(620 * Look.Scale, 0), Cond.Appearing);
			if (!Gui.igBeginPopupModal("Rename References", null, WindowFlags.AlwaysAutoResize))
				return;
			if (mRenamePlan == null || Gui.IsKeyPressed(Key.Escape, false))
			{
				Gui.igCloseCurrentPopup();
				Gui.EndPopup();
				return;
			}
			let t = mRenamePlan.Target;
			StringView what = "";
			switch (t.Kind)
			{
			case .Type: what = "type";
			case .Member: what = "member";
			case .Parameter: what = "parameter";
			case .Local: what = "local variable";
			}
			Gui.Text(scope $"Rename {what} {(t.Kind == .Member ? scope String()..AppendF("{}.", t.TypeName) : "")}{t.OldName}  {Icon.ArrowRight}  {t.NewName}");
			String summary = scope .();
			mRenamePlan.Summary(summary);
			bool ok = mRenamePlan.CanApply;
			Gui.TextColored(ok ? Look.Foreground : Theme.NodeError, summary);
			Gui.igSpacing();
			if (Gui.igBeginChild_Str("##renlist", .(600 * Look.Scale, 260 * Look.Scale), ChildFlags.Borders, 0))
			{
				for (let p in mRenamePlan.Problems)
					Gui.TextColored(Theme.NodeError, scope $"{Icon.Error}  {p}");
				for (let f in mRenamePlan.Files)
				{
					String file = scope .();
					Path.GetFileName(f.Path, file);
					if (Gui.TreeNode(scope $"{Icon.File}  {file}  ({f.Edits.Count})##{f.Path}", TreeNodeFlags.DefaultOpen))
					{
						for (let e in f.Edits)
						{
							int ls = e.Start;
							while (ls > 0 && f.Text[ls - 1] != '\n')
								ls--;
							int le = e.Start;
							while (le < f.Text.Length && f.Text[le] != '\n' && f.Text[le] != '\r')
								le++;
							var line = StringView(f.Text, ls, le - ls);
							line.Trim();
							Gui.TextDisabled(scope $"{e.Line,5}  {line}");
						}
						Gui.TreePop();
					}
				}
			}
			Gui.igEndChild();
			if (!ok)
				Gui.TextWrappedDim("Nothing was changed. The Output Log lists the same lines (category Rename).");
			Gui.igBeginDisabled(!ok);
			if (Gui.Button(scope $"Rename {mRenamePlan.Count}", .(160 * Look.Scale, 0)))
			{
				ApplyRenamePlan();
				Gui.igCloseCurrentPopup();
			}
			Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			Gui.EndPopup();
		}

		/// Writes the planned edits into the documents (opening files that are not open yet;
		/// nothing is saved) as one multi-file undo step.
		void ApplyRenamePlan()
		{
			let plan = mRenamePlan;
			if (plan == null || !plan.CanApply || !CheckWritable())
				return;
			let keepDoc = Doc;
			List<SourceDocument> touched = scope .();
			int failures = 0;
			for (let f in plan.Files)
			{
				var d = FindDoc(f.Path);
				if (d == null)
					d = OpenFile(f.Path, false);
				if (d == null)
				{
					failures++;
					continue;
				}
				if (!d.ApplyRenameEdits(f.Text, f.Edits, plan.Target.NewName))
				{
					Notify.Log(.Error, "Rename", scope $"{f.Path}: {d.LastError}");
					failures++;
					continue;
				}
				touched.Add(d);
			}
			if (mDocs.Contains(keepDoc))
				Doc = keepDoc;
			PushUndoGroup(touched, scope $"rename {plan.Target.OldName} -> {plan.Target.NewName}");
			// Open tabs follow their functions' new keys.
			for (let tab in Tabs)
			{
				if (!touched.Contains(tab.Doc) || tab.Doc.FindMethod(tab.MethodKey) != null)
					continue;
				String key = scope .();
				ReplaceWord(tab.MethodKey, plan.Target.OldName, plan.Target.NewName, key);
				let mg = tab.Doc.FindMethod(key);
				if (mg != null)
				{
					tab.MethodKey.Set(key);
					tab.Title.Clear();
					if (mg.Owner != null)
						tab.Title.AppendF("{}.", mg.Owner.Name);
					tab.Title.Append(mg.Method.Name);
				}
			}
			if (plan.Target.Kind == .Type && mSelClassName == plan.Target.OldName)
				mSelClassName.Set(plan.Target.NewName);
			if (plan.Target.Kind == .Type && !mPendingTypeFile.IsEmpty && ProjectIndex.SamePath(mPendingTypeFile, plan.Target.FilePath))
				MoveTypeFileAfterRename(mPendingTypeFile, plan.Target.OldName, plan.Target.NewName);
			mPendingTypeFile.Clear();
			if (plan.Target.Kind == .Member && mSelVarName == plan.Target.OldName)
				mSelVarName.Set(plan.Target.NewName);
			UpdateTitle();
			if (failures > 0)
				ReportError(scope $"Rename {plan.Target.OldName} -> {plan.Target.NewName}: {failures} file(s) could not be changed (see the Output Log). Undo reverts the others.");
			else
				SetStatus(scope $"Renamed {plan.Target.OldName} to {plan.Target.NewName}: {plan.Count} references in {plan.Files.Count} files (unsaved)");
		}

		static void ReplaceWord(StringView text, StringView oldWord, StringView newWord, String o)
		{
			int i = 0;
			while (i < text.Length)
			{
				if (text.Substring(i).StartsWith(oldWord) && (i == 0 || !CharUtil.IsIdentChar(text[i - 1])) &&
					(i + oldWord.Length >= text.Length || !CharUtil.IsIdentChar(text[i + oldWord.Length])))
				{
					o.Append(newWord);
					i += oldWord.Length;
					continue;
				}
				o.Append(text[i]);
				i++;
			}
		}

		// ------------------------------------------------------------------ pickers

		/// A button showing `value` that opens a searchable list of project and library types of
		/// `kinds` ("class", "struct", "interface", comma separated). Returns true on a pick
		/// (`value` is "" for None when `allowNone`).
		bool ClassPickerButton(StringView id, String value, StringView kinds, bool forDerive, bool allowNone, float width = -1, StringView exclude = default)
		{
			bool changed = false;
			Gui.PushID(id);
			float h = Gui.igGetFrameHeight();
			float w = (width < 0) ? Gui.igGetContentRegionAvail().x : width;
			Gui.igPushStyleColor_U32(Col.Button, Look.Input);
			Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(30, 30, 30));
			Gui.igPushStyleVar_Vec2(StyleVarX.ButtonTextAlign, .(0, 0.5f));
			bool open = Gui.Button(scope $"  {(kinds.Contains("interface") && !kinds.Contains("class") ? Icon.Interface : Icon.Class)}  {(value.IsEmpty ? "None" : value)}", .(w, h));
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(2);
			if (open)
			{
				Gui.OpenPopup("##classpick");
				mPickSearch.Set("");
				mPickFocus = true;
			}
			Gui.igSetNextWindowSize(.(Math.Max(w, 340 * Look.Scale), 420 * Look.Scale), Cond.Always);
			if (Look.BeginPopupSpaced("##classpick"))
			{
				if (mPickFocus)
				{
					Gui.igSetKeyboardFocusHere(0);
					mPickFocus = false;
				}
				Gui.igSetNextItemWidth(-1);
				bool enter = Gui.igInputTextWithHint("##psearch", scope $"{Icon.Search}  Search project and library types", mPickSearch.Ptr, (.)mPickSearch.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				var search = mPickSearch.View;
				search.Trim();
				List<TypeChoice> list = scope .();
				ClassModel.ListTypes(TypeService.Current, kinds, search, forDerive, 400, list);
				list.Sort(scope (a, b) =>
				{
					int c = (a.Library.IsEmpty ? 0 : 1) <=> (b.Library.IsEmpty ? 0 : 1);
					return (c != 0) ? c : StringView.Compare(a.Name, b.Name, true);
				});
				String picked = scope .();
				bool pickedNone = false;
				if (Gui.igBeginChild_Str("##plist", .(0, 0), 0, 0))
				{
					if (allowNone && Gui.Selectable("None"))
						pickedNone = true;
					if (!search.IsEmpty && Gui.Selectable(scope $"{Icon.Pencil}  Use \"{search}\""))
						picked.Set(search);
					StringView lastGroup = "?";
					for (let c in list)
					{
						if (!exclude.IsEmpty && c.Name == exclude && c.Library.IsEmpty)
							continue; // a type cannot derive from itself
						StringView group = c.Library.IsEmpty ? "Project" : c.Library;
						if (group != lastGroup)
						{
							Gui.TextDisabled(group);
							lastGroup = group;
						}
						String label = scope .();
						label.AppendF("    {}{}{}##{}.{}", c.Name, c.Namespace.IsEmpty ? "" : "  ", c.Namespace.IsEmpty ? "" : scope String()..AppendF("({})", c.Namespace), c.Namespace, c.Name);
						if (Gui.Selectable(label, value == c.Name))
							picked.Set(c.Name);
					}
					if (list.Count >= 400)
						Gui.TextDisabled("... refine the search");
					if (enter && picked.IsEmpty && !list.IsEmpty)
						picked.Set(list[0].Name);
				}
				Gui.igEndChild();
				if (pickedNone)
				{
					value.Clear();
					changed = true;
					Gui.igCloseCurrentPopup();
				}
				else if (!picked.IsEmpty)
				{
					value.Set(picked);
					changed = true;
					Gui.igCloseCurrentPopup();
				}
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				Look.EndPopupSpaced();
			}
			Gui.PopID();
			return changed;
		}

		// ------------------------------------------------------------------ attributes

		static String[?] sAttrPresets = .("AlwaysInclude", "Reflect", "CRepr", "Packed", "Ordered", "Union", "Inline",
			"NoDiscard", "Obsolete(\"...\")", "Node(Category=\"...\")", "Pure", "Expose", "NodeHidden", "ExposeType");

		/// The attribute list of a declaration: one editable row per attribute, remove, add (with
		/// presets). Returns true when the document changed.
		bool DrawAttributeList(SourceDocument doc, Member m, StringView ownerKey)
		{
			String key = scope .();
			// File and position too: A.Update and B.Update share a name.
			key.AppendF("{}|{}|{}|{}|{}", ownerKey, doc.FilePath, m.FirstTok, m.Name, doc.Version);
			if (key != mAttrRowsFor && !Gui.igIsAnyItemActive())
			{
				mAttrRowsFor.Set(key);
				ClearAndDeleteItems!(mAttrRows);
				if (m.Attributes != null)
					AttrList.Parse(m.Attributes, mAttrRows);
			}
			bool commit = false;
			int removeAt = -1;
			for (let a in mAttrRows)
			{
				Gui.PushID((int32)@a.Index);
				PropertyGrid.BeginRow();
				Gui.igIndent(14 * Look.Scale);
				Gui.TextDisabled(scope $"[{@a.Index}]");
				Gui.igUnindent(14 * Look.Scale);
				Gui.igTableSetColumnIndex(1);
				float x = Gui.igGetFrameHeight();
				Gui.igSetNextItemWidth(Gui.igGetContentRegionAvail().x - x - 4 * Look.Scale);
				if (PropertyGrid.Text("##attr", a, ?))
					commit = true;
				Gui.SameLine(0, 4 * Look.Scale);
				if (Gui.Button(Icon.X, .(x, x)))
					removeAt = @a.Index;
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove this attribute");
				Gui.PopID();
			}
			if (removeAt >= 0)
			{
				delete mAttrRows[removeAt];
				mAttrRows.RemoveAt(removeAt);
				commit = true;
			}
			PropertyGrid.WideRow();
			if (Gui.Button(scope $"{Icon.Plus}  Add Attribute"))
				Gui.OpenPopup("##attrpresets");
			if (Look.BeginPopupSpaced("##attrpresets"))
			{
				for (let p in sAttrPresets)
				{
					if (Gui.Selectable(p))
					{
						mAttrRows.Add(new String(p));
						commit = true;
					}
				}
				Look.EndPopupSpaced();
			}
			if (!commit)
				return false;
			List<String> clean = scope .();
			for (let a in mAttrRows)
			{
				var s = StringView(a);
				s.Trim();
				if (s.StartsWith('[') && s.EndsWith(']'))
					s = s.Substring(1, s.Length - 2);
				if (!s.IsEmpty)
					clean.Add(scope:: String(s));
			}
			mAttrRowsFor.Clear();
			ClassEditResult(doc, doc.SetAttributes(m, clean), "Attributes");
			return true;
		}

		// ------------------------------------------------------------------ Override dropdown

		/// Menu items for every member `type` can override or implement (inside an open popup /
		/// menu). Choosing one adds it with the right signature and opens its graph.
		void DrawOverrideItems(SourceDocument doc, Member type)
		{
			let info = ClassInfoFor(doc, type);
			if (info.Overridable.IsEmpty)
			{
				Gui.TextDisabled(info.Complete ? "Nothing to override" : "Nothing known to override (the parent is not indexed)");
				return;
			}
			String typeName = scope .(type.Name);
			StringView lastOwner = "";
			String disp = scope .();
			InheritedMember chosen = null;
			for (let m in info.Overridable)
			{
				if (m.OwnerType != lastOwner)
				{
					Gui.TextDisabled(scope $"{(m.FromInterface ? "Interface" : "Parent")} {m.OwnerType}");
					lastOwner = m.OwnerType;
				}
				disp.Clear();
				m.Display(disp);
				StringView icon = (m.Kind == .Method) ? Icon.Function : Icon.Variable;
				uint32 col = m.IsAbstract ? Theme.NodeError : (m.FromInterface ? Gui.Color(120, 200, 140) : Gui.Color(230, 110, 90));
				Gui.igPushStyleColor_U32(Col.Text, col);
				String sig = scope .();
				if (m.Kind == .Method)
				{
					sig.Append('(');
					m.ParamsText(sig);
					sig.Append(')');
				}
				bool clicked = Gui.Selectable(scope $"    {icon}  {m.Name}{sig}##ov{@m.Index}");
				Gui.igPopStyleColor(1);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{disp}\n{(m.IsAbstract ? "Must be implemented" : (m.FromInterface ? "Interface member with a default body" : "virtual: adds a call to the parent function"))}");
				if (clicked)
					chosen = m;
			}
			if (chosen != null)
			{
				InheritedMember copy = scope .();
				copy.Kind = chosen.Kind;
				copy.Name.Set(chosen.Name);
				copy.OwnerType.Set(chosen.OwnerType);
				copy.ReturnType.Set(chosen.ReturnType);
				for (let s in chosen.ParamTypes) copy.ParamTypes.Add(new String(s));
				for (let s in chosen.ParamNames) copy.ParamNames.Add(new String(s));
				for (let s in chosen.ParamModifiers) copy.ParamModifiers.Add(new String(s));
				copy.IsAbstract = chosen.IsAbstract;
				copy.IsVirtual = chosen.IsVirtual;
				copy.FromInterface = chosen.FromInterface;
				copy.HasSetter = chosen.HasSetter;
				copy.Visibility = chosen.Visibility;
				AddOverrideNow(doc, typeName, copy);
			}
		}

		void AddOverrideNow(SourceDocument doc, StringView typeName, InheritedMember m)
		{
			if (!CheckWritable())
				return;
			let type = FindTypeIn(doc, typeName);
			if (type == null)
				return;
			String key = scope .();
			if (!doc.AddOverride(type, m, true, key))
			{
				ClassEditResult(doc, false, "Override");
				return;
			}
			let mg = doc.FindMethod(key);
			if (mg != null && mg.Graphable)
				OpenTab(mg);
			UpdateTitle();
			SetStatus(scope $"Added {(m.FromInterface ? "" : "override ")}{m.Name} to {typeName}");
		}

		// ------------------------------------------------------------------ Type Settings

		static StringView[5] sKinds = .("class", "struct", "interface", "extension", "enum");
		static StringView[5] sAccess = .("(default)", "public", "internal", "protected", "private");

		static int32 AccessIndex(StringView mods)
		{
			String vis = scope .();
			Mods.GetVisibility(mods, vis);
			for (int32 i = 1; i < 5; i++)
				if (vis == sAccess[i])
					return i;
			return 0;
		}

		/// Details for the selected type. Returns false when the type is gone.
		bool DrawTypeSettings()
		{
			let doc = Doc;
			let type = FindTypeIn(doc, mSelClassName);
			if (type == null)
			{
				mSelClassActive = false;
				return false;
			}
			TypeDeclInfo decl = scope .();
			decl.Read(doc.Unit, type);
			String syncKey = scope .();
			syncKey.AppendF("{}|{}|{}", doc.FilePath, type.Name, doc.Version);
			if (syncKey != mClassEditFor && !Gui.igIsAnyItemActive())
			{
				mClassEditFor.Set(syncKey);
				mClassEditBuf.Set(type.Name);
				mGenericBuf.Set(decl.GenericParams);
				mConstraintBuf.Set(decl.Constraints);
				mNamespaceBuf.Set(decl.Namespace);
			}
			let kind = StringView(decl.Kind);
			bool isEnum = kind == "enum";
			AssetKind ak = .Class;
			bool isLib = type.IsNodeLibrary;
			AssetStyle.FromType(kind, isLib, out ak);
			StringView icon = Icon.Class;
			switch (ak)
			{
			case .Struct: icon = Icon.Struct;
			case .Enum: icon = Icon.Enum;
			case .Interface: icon = Icon.Interface;
			case .Library: icon = Icon.Boxes;
			default:
			}
			DetailsHeader(icon, AssetStyle.KindColor(ak), type.Name, scope $"Type Settings  -  {(isLib ? (StringView)"Node Library" : kind)}{(decl.Namespace.IsEmpty ? "" : " in ")}{decl.Namespace}");
			let info = ClassInfoFor(doc, type);
			String typeName = scope .(type.Name);
			bool changed = false;
			if (!PropertyGrid.Begin("##classgrid"))
				return true;
			defer PropertyGrid.End();

			if (!info.Problems.IsEmpty && PropertyGrid.Category("Problems", true, Icon.Error))
			{
				for (let p in info.Problems)
				{
					PropertyGrid.WideRow();
					Gui.igPushStyleColor_U32(Col.Text, Theme.NodeError);
					Gui.igPushTextWrapPos(0);
					Gui.Text(scope $"{Icon.Error}  {p}");
					Gui.igPopTextWrapPos();
					Gui.igPopStyleColor(1);
				}
				if (!info.Missing.IsEmpty)
				{
					PropertyGrid.WideRow();
					if (Gui.Button(scope $"{Icon.Plus}  Implement Missing Members ({info.Missing.Count})"))
					{
						if (CheckWritable())
						{
							int n = doc.AddStubs(type, info.Missing);
							SetStatus(scope $"Added {n} stub{(n == 1) ? "" : "s"} to {typeName}");
							UpdateTitle();
						}
						return true;
					}
				}
			}

			if (PropertyGrid.Category("Class Options", true))
			{
				PropertyGrid.Row("Name", "Renames the type and every reference to it in the project (with a preview)");
				if (PropertyGrid.Text("##cname", mClassEditBuf, ?))
				{
					String n = scope .(mClassEditBuf);
					n.Trim();
					if (n != type.Name && !n.IsEmpty)
					{
						mPendingTypeFile.Clear(); // Type Settings renames the type, not its file
						StartProjectRename(.Type, type.Name, n, type.Name, "", doc.FilePath);
					}
					mClassEditBuf.Set(type.Name);
				}
				PropertyGrid.Row("Kind", "class, Node Library (a static class of global functions and variables), struct, interface, extension (an enum stays an enum)");
				int32 ki = 0;
				for (int32 i < 5)
					if (sKinds[i] == kind)
						ki = (i == 0) ? 0 : ((i == 4) ? 0 : i + 1);
				if (isLib)
					ki = 1;
				Gui.igBeginDisabled(isEnum);
				Gui.igSetNextItemWidth(-1);
				StringView[5] kindItems = .("class", "Node Library", "struct", "interface", "extension");
				StringView[5] kindWords = .("class", "library", "struct", "interface", "extension");
				if (!isEnum && PropertyGrid.Combo("##ckind", ref ki, kindItems))
				{
					ClassEditResult(doc, doc.SetTypeKind(type, kindWords[ki]), "Kind");
					changed = true;
				}
				Gui.igEndDisabled();
				if (changed)
					return true;
				if (isLib)
				{
					PropertyGrid.WideRow();
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
					Gui.igPushTextWrapPos(0);
					Gui.Text(scope $"Every function and variable here is static and global: call them as {typeName}.Name from any sheet. A Node Library is never constructed.");
					Gui.igPopTextWrapPos();
					Gui.igPopStyleColor(1);
				}

				// Parent class (class / struct), underlying type (enum).
				if ((kind == "class" && !isLib) || kind == "struct")
				{
					PropertyGrid.Row(kind == "class" ? "Parent Class" : "Parent Struct", "The base type; choosing one offers to implement what it requires");
					String parent = scope .(info.BaseClass);
					if (info.BaseClass.IsEmpty && !decl.Bases.IsEmpty && !info.Complete)
					{
						// Unknown first base: show it as written.
						bool isIface = false;
						for (let i in info.Interfaces)
							if (i == decl.Bases[0])
								isIface = true;
						if (!isIface)
							parent.Set(decl.Bases[0]);
					}
					if (ClassPickerButton("##parent", parent, kind, true, true, -1, type.Name))
					{
						List<String> bases = scope .();
						if (!parent.IsEmpty)
							bases.Add(parent);
						for (let b in decl.Bases)
							if (b != info.BaseClass && (parent.IsEmpty || b != parent) && !(info.BaseClass.IsEmpty && !decl.Bases.IsEmpty && b == decl.Bases[0] && !info.Interfaces.Contains(b)))
								bases.Add(b);
						ClassEditResult(doc, doc.SetBaseList(type, bases), "Parent class");
						return true;
					}
				}
				else if (isEnum)
				{
					PropertyGrid.Row("Underlying Type", "The integer type of the cases (int when none)");
					StringView[9] ints = .("(int)", "int8", "uint8", "int16", "uint16", "int32", "uint32", "int64", "uint64");
					int32 ii = 0;
					for (int32 i = 1; i < 9; i++)
						if (!decl.Bases.IsEmpty && decl.Bases[0] == ints[i])
							ii = i;
					Gui.igSetNextItemWidth(-1);
					if (PropertyGrid.Combo("##eunder", ref ii, ints))
					{
						List<String> bases = scope .();
						if (ii > 0)
							bases.Add(scope:: String(ints[ii]));
						ClassEditResult(doc, doc.SetBaseList(type, bases), "Underlying type");
						return true;
					}
				}
				PropertyGrid.Row("Namespace", "Renames the namespace declaration around the type (refused when it holds other types)");
				if (PropertyGrid.Text("##cns", mNamespaceBuf, ?))
				{
					if (mNamespaceBuf != decl.Namespace)
					{
						ClassEditResult(doc, doc.SetNamespace(type, mNamespaceBuf), "Namespace");
						return true;
					}
				}
			}

			if (!isLib && (kind == "class" || kind == "struct" || kind == "interface" || kind == "extension") && PropertyGrid.Category(kind == "interface" ? "Base Interfaces" : "Interfaces", true))
			{
				int removeAt = -1;
				for (let i in info.Interfaces)
				{
					Gui.PushID((int32)@i.Index);
					PropertyGrid.BeginRow();
					Gui.igIndent(14 * Look.Scale);
					Gui.Text(scope $"{Icon.Interface}  {i}");
					Gui.igUnindent(14 * Look.Scale);
					Gui.igTableSetColumnIndex(1);
					if (Gui.Button(scope $"{Icon.X}  Remove"))
						removeAt = @i.Index;
					Gui.PopID();
				}
				for (let u in info.Unresolved)
				{
					PropertyGrid.Row(u, "Not found in the project or its libraries: kept as written");
					PropertyGrid.Value("(not indexed)");
				}
				if (removeAt >= 0)
				{
					List<String> bases = scope .();
					for (let b in decl.Bases)
						if (b != info.Interfaces[removeAt])
							bases.Add(b);
					ClassEditResult(doc, doc.SetBaseList(type, bases), "Interfaces");
					return true;
				}
				PropertyGrid.Row("Add Interface", "Implements another interface; its members can then be stubbed");
				String add = scope .();
				if (ClassPickerButton("##addif", add, "interface", false, false, -1, type.Name) && !add.IsEmpty)
				{
					List<String> bases = scope .();
					for (let b in decl.Bases)
						bases.Add(b);
					if (!bases.Contains(add))
						bases.Add(add);
					ClassEditResult(doc, doc.SetBaseList(type, bases), "Interfaces");
					return true;
				}
				if (!info.Missing.IsEmpty)
				{
					PropertyGrid.WideRow();
					if (Gui.Button(scope $"{Icon.Plus}  Implement Missing Members ({info.Missing.Count})"))
					{
						if (CheckWritable())
						{
							int n = doc.AddStubs(type, info.Missing);
							SetStatus(scope $"Added {n} stub{(n == 1) ? "" : "s"} to {typeName}");
							UpdateTitle();
						}
						return true;
					}
					if (Gui.igIsItemHovered(0))
					{
						String tip = scope .("Adds a stub (a graph) for each:");
						for (let m in info.Missing)
						{
							tip.Append("\n  ");
							m.Display(tip);
						}
						Gui.Tooltip(tip);
					}
				}
				if (kind != "interface")
				{
					PropertyGrid.Row("Override", "Virtual and abstract functions of the parents and interface members");
					if (Gui.Button(scope $"{Icon.ChevronDown}  Override ({info.Overridable.Count})", .(-1, 0)))
						Gui.OpenPopup("##csoverride");
					if (Look.BeginPopupSpaced("##csoverride"))
					{
						DrawOverrideItems(doc, type);
						Look.EndPopupSpaced();
					}
				}
			}

			if (PropertyGrid.Category("Modifiers", true))
			{
				PropertyGrid.Row("Access", "public / internal / private (top-level types are public by default)");
				int32 ai = AccessIndex(type.Modifiers);
				Gui.igSetNextItemWidth(-1);
				if (PropertyGrid.Combo("##cacc", ref ai, sAccess))
				{
					ClassEditResult(doc, doc.SetVisibility(type, (ai == 0) ? "" : sAccess[ai]), "Access");
					return true;
				}
				StringView[4] words = .("static", "abstract", "sealed", "partial");
				StringView[4] labels = .("Static", "Abstract", "Sealed", "Partial");
				StringView[4] tips = .("A static class: only static members, no instances", "Cannot be created; may leave members abstract",
					"Cannot be derived from", "Declared in several parts");
				for (int i < 4)
				{
					if (isEnum && i < 3)
						continue;
					if (kind == "class" && i == 0)
						continue; // Static is the Node Library kind
					if (isLib && i < 3)
						continue;
					PropertyGrid.Row(labels[i], tips[i]);
					bool on = Mods.Has(type.Modifiers, words[i]);
					if (Gui.Checkbox(scope $"##cm{i}", &on))
					{
						ClassEditResult(doc, doc.SetModifierWord(type, words[i], on), words[i]);
						return true;
					}
				}
			}

			if (PropertyGrid.Category("Attributes", true))
			{
				if (DrawAttributeList(doc, type, "type"))
					return true;
			}

			if (!isEnum && PropertyGrid.Category("Generics", false))
			{
				PropertyGrid.Row("Parameters", "T, U  (empty: not generic)");
				if (PropertyGrid.Text("##cgen", mGenericBuf, ?, true, mMono, "T, U"))
				{
					if (mGenericBuf != decl.GenericParams)
					{
						ClassEditResult(doc, doc.SetGenericParams(type, mGenericBuf), "Generic parameters");
						return true;
					}
				}
				{
					String genWhy = scope .();
					if (!TypeSlotRules.CheckGenericList(mGenericBuf, genWhy))
						ErrorText(genWhy);
				}
				PropertyGrid.Row("Constraints", "where T : class, IFoo");
				if (PropertyGrid.Text("##ccon", mConstraintBuf, ?, true, mMono, "where T : class"))
				{
					if (mConstraintBuf != decl.Constraints)
					{
						ClassEditResult(doc, doc.SetConstraints(type, mConstraintBuf), "Constraints");
						return true;
					}
				}
			}

			if (isEnum && PropertyGrid.Category("Values", true))
			{
				List<EnumCase> cases = scope .();
				defer { ClearAndDeleteItems!(cases); }
				EnumCases.Parse(doc.Unit, type, cases);
				for (let ec in cases)
				{
					PropertyGrid.Row(ec.Name);
					PropertyGrid.Value(ec.Value.IsEmpty ? "(auto)" : ec.Value);
				}
				PropertyGrid.WideRow();
				if (Gui.Button(scope $"{Icon.Enum}  Edit Values in the Enum Editor"))
					OpenEnumEditor(scope String(doc.FilePath), typeName);
			}

			if (!isEnum && PropertyGrid.Category("Add", false))
			{
				PropertyGrid.WideRow();
				if (!isLib)
				{
					if (Gui.Button(scope $"{Icon.Plus}  Constructor"))
						OpenAddConstructor(typeName);
					Gui.SameLine();
				}
				if (Gui.Button(scope $"{Icon.Plus}  Static Constructor"))
				{
					AddSpecialMember(doc, typeName, 1);
					return true;
				}
				if (!isLib)
				{
					Gui.SameLine();
					if (Gui.Button(scope $"{Icon.Plus}  Destructor"))
					{
						AddSpecialMember(doc, typeName, 2);
						return true;
					}
				}
			}
			return true;
		}

		/// Opens the Add Function dialog in constructor mode.
		void OpenAddConstructor(StringView typeName)
		{
			mAddTargetType.Set(typeName);
			mParamsBuf.Set("");
			mCtorAccess = 0;
			mCtorChain = 0;
			mAddCtorMode = true;
			mOpenAddFunction = true;
		}

		/// Writes the empty default constructor / destructor of a class or struct (one undo step)
		/// and opens its Sheet. Used by the Outline's dimmed default rows.
		public bool MaterializeDefaultMember(SourceDocument doc, Member type, bool dtor)
		{
			if (!CheckWritable())
				return false;
			String key = scope .();
			bool ok = dtor ? doc.EnsureDefaultDestructor(type, key) : doc.EnsureDefaultConstructor(type, key);
			ClassEditResult(doc, ok, dtor ? "Destructor" : "Constructor");
			if (ok)
			{
				let mg = doc.FindMethod(key);
				if (mg != null)
					OpenTab(mg);
			}
			return ok;
		}

		/// 0 constructor, 1 static constructor, 2 destructor.
		void AddSpecialMember(SourceDocument doc, StringView typeName, int what)
		{
			if (!CheckWritable())
				return;
			let type = FindTypeIn(doc, typeName);
			if (type == null)
				return;
			String key = scope .();
			bool ok = (what == 2) ? doc.AddDestructor(type, key) : doc.AddConstructor(type, what == 1, key);
			ClassEditResult(doc, ok, (what == 2) ? "Destructor" : "Constructor");
			if (ok)
			{
				let mg = doc.FindMethod(key);
				if (mg != null)
					OpenTab(mg);
			}
		}

		// ------------------------------------------------------------------ function options

		static StringView[5] sInherit = .("(none)", "virtual", "override", "abstract", "new");

		/// The class-level rows of a function's Details (inside the Graph category). Returns
		/// true when the document changed (the caller stops drawing).
		bool DrawFunctionClassOptions(MethodGraph mg)
		{
			let doc = mg.Doc;
			let m = mg.Method;
			let owner = mg.Owner;
			bool accessor = m.IsAccessor;
			bool special = m.IsCtor || m.IsDtor;
			PropertyGrid.Row("Access", "Who can call it: public (any class), protected (subclasses), internal (this project), private (this type)");
			int32 ai = AccessIndex(m.Modifiers);
			Gui.igSetNextItemWidth(-1);
			if (PropertyGrid.Combo("##facc", ref ai, sAccess))
			{
				ClassEditResult(doc, doc.SetVisibility(m, (ai == 0) ? "" : sAccess[ai]), "Access");
				return true;
			}
			if (!accessor)
			{
				PropertyGrid.Row("Static", "No this: called on the type (no Receiver pin)");
				bool inLib = owner != null && owner.IsNodeLibrary;
				bool st = Mods.Has(m.Modifiers, "static") || inLib;
				Gui.igBeginDisabled(m.IsDtor || inLib);
				// A locked box is drawn grey (not the blue of one you can change).
				if (inLib)
				{
					Gui.igPushStyleColor_U32(ColX.CheckboxSelectedBg, Look.Dropdown);
					Gui.igPushStyleColor_U32(ColX.CheckMark, Look.ForegroundDim);
				}
				bool stClicked = Gui.Checkbox("##fstatic", &st);
				if (inLib)
					Gui.igPopStyleColor(2);
				if (stClicked)
				{
					ClassEditResult(doc, doc.SetModifierWord(m, "static", st), "Static");
					Gui.igEndDisabled();
					return true;
				}
				Gui.igEndDisabled();
				if (inLib && Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
					Gui.Tooltip(scope $"A Node Library is always static\n{owner.Name} is a Node Library: every function in it is static. Call it as {owner.Name}.{m.Name}(...).");
			}
			if (!accessor && !special && !m.IsMixin && !(owner != null && owner.IsNodeLibrary))
			{
				PropertyGrid.Row("Inheritance", "virtual: subclasses may override it; override: replaces a parent's; abstract: no body here; new: hides a parent's");
				int32 ii = 0;
				for (int32 i = 1; i < 5; i++)
					if (Mods.Has(m.Modifiers, sInherit[i]))
						ii = i;
				Gui.igSetNextItemWidth(-1);
				if (PropertyGrid.Combo("##finh", ref ii, sInherit))
				{
					ClassEditResult(doc, doc.SetInheritance(m, (ii == 0) ? "" : sInherit[ii]), "Inheritance");
					return true;
				}
				if (owner != null && owner.TypeKind == "struct")
				{
					PropertyGrid.Row("Mutating (mut)", "A struct function that changes the struct's fields");
					bool mu = Mods.Has(m.Modifiers, "mut");
					if (Gui.Checkbox("##fmut", &mu))
					{
						ClassEditResult(doc, doc.SetModifierWord(m, "mut", mu), "mut");
						return true;
					}
				}
				if (Mods.Has(m.Modifiers, "extern"))
				{
					PropertyGrid.Row("Extern");
					PropertyGrid.Value("Yes (implemented outside Beef)");
				}
			}
			if (m.IsMixin)
			{
				PropertyGrid.Row("Mixin");
				PropertyGrid.Value("Yes (inlined at the call)");
			}
			if (owner != null && Mods.Has(m.Modifiers, "override") && !accessor)
			{
				let info = ClassInfoFor(doc, owner);
				String sig = scope .();
				ClassModel.OwnSignature(m, sig);
				PropertyGrid.Row("Overrides", "The parent function this one replaces");
				if (info.OverridesWithoutBase.Contains(sig))
					PropertyGrid.Value(scope $"{Icon.Error} nothing to override", Theme.NodeError);
				else if (!info.Complete)
					PropertyGrid.Value("(parent not indexed)");
				else
				{
					String b = scope .(info.BaseClass.IsEmpty ? "Object" : info.BaseClass);
					PropertyGrid.Value(scope $"{b}.{m.Name}");
				}
			}
			if (owner != null && owner.TypeKind != "interface" && owner.TypeKind != "enum" && !owner.IsNodeLibrary)
			{
				PropertyGrid.Row("Add Override", "Override a parent function or implement an interface member (adds a new graph)");
				if (Gui.Button(scope $"{Icon.ChevronDown}  Override", .(-1, 0)))
					Gui.OpenPopup("##fnoverride");
				if (Look.BeginPopupSpaced("##fnoverride"))
				{
					DrawOverrideItems(doc, owner);
					Look.EndPopupSpaced();
				}
			}
			return false;
		}

		// ------------------------------------------------------------------ variable options

		static StringView[5] sStorage = .("Instance", "Static", "Const", "Readonly", "Static Readonly");

		/// The class-level rows of a variable's Details. Returns true when the document changed.
		bool DrawVariableClassOptions(SourceDocument doc, Member type, Member field)
		{
			PropertyGrid.Row("Access", "public / protected / internal / private");
			int32 ai = AccessIndex(field.Modifiers);
			Gui.igSetNextItemWidth(-1);
			if (PropertyGrid.Combo("##vacc", ref ai, sAccess))
			{
				ClassEditResult(doc, doc.SetVisibility(field, (ai == 0) ? "" : sAccess[ai]), "Access");
				return true;
			}
			bool isProp = field.Kind == .Property;
			PropertyGrid.Row("Storage", isProp ? "Instance or static" : "const: a compile-time value; readonly: set only in a constructor");
			int32 si = 0;
			bool st = Mods.Has(field.Modifiers, "static");
			if (Mods.Has(field.Modifiers, "const"))
				si = 2;
			else if (Mods.Has(field.Modifiers, "readonly"))
				si = st ? 4 : 3;
			else if (st)
				si = 1;
			bool inLib = type != null && type.IsNodeLibrary;
			Gui.igSetNextItemWidth(-1);
			StringView[2] propStorage = .("Instance", "Static");
			bool storageChanged;
			if (inLib)
			{
				// Static is locked on: a Node Library has no instances.
				StringView[3] libStorage = .("Static", "Const", "Static Readonly");
				int32 li = (si == 2) ? 1 : ((si == 4) ? 2 : 0);
				storageChanged = PropertyGrid.Combo("##vst", ref li, Span<StringView>(&libStorage[0], isProp ? 1 : 3));
				if (storageChanged)
					si = (li == 0) ? 1 : ((li == 1) ? 2 : 4);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{type.Name} is a Node Library: every variable in it is static (global), read as {type.Name}.{field.Name}.");
			}
			else
				storageChanged = isProp ? PropertyGrid.Combo("##vst", ref si, propStorage) : PropertyGrid.Combo("##vst", ref si, sStorage);
			if (storageChanged)
			{
				String mods = scope .(field.Modifiers);
				String tmp = scope .();
				void Set(StringView word, bool on)
				{
					tmp.Clear();
					Mods.SetWord(mods, word, on, tmp);
					mods.Set(tmp);
				}
				Set("static", si == 1 || si == 4);
				Set("const", si == 2);
				Set("readonly", si == 3 || si == 4);
				ClassEditResult(doc, doc.SetModifiers(field, mods), "Storage");
				return true;
			}
			if (isProp)
			{
				PropertyGrid.Row("Inheritance", "virtual / override / abstract");
				int32 ii = 0;
				for (int32 i = 1; i < 5; i++)
					if (Mods.Has(field.Modifiers, sInherit[i]))
						ii = i;
				Gui.igSetNextItemWidth(-1);
				if (PropertyGrid.Combo("##vinh", ref ii, sInherit))
				{
					String mods = scope .();
					Mods.SetExclusive(field.Modifiers, "virtual,override,abstract,new", (ii == 0) ? "" : sInherit[ii], mods);
					ClassEditResult(doc, doc.SetModifiers(field, mods), "Inheritance");
					return true;
				}
			}
			if (DrawMemberInitRows(doc, type, field, let initChanged))
			{
				if (initChanged)
					return true;
			}
			else if (!isProp)
			{
				PropertyGrid.Row("Default Value", "The initial value (= ...); empty for none");
				String cur = scope .();
				if (field.InitTok >= 0 && field.LastTok > field.InitTok + 1)
					cur.Set(doc.Unit.SpanText(field.InitTok + 1, field.LastTok - 1));
				String key = scope .();
				key.AppendF("{}|{}|{}|{}|{}", doc.FilePath, field.FirstTok, field.Name, doc.Version, cur);
				if (key != mClassEditFor && !Gui.igIsAnyItemActive())
				{
					mClassEditFor.Set(key);
					mDefaultBuf.Set(cur);
				}
				if (PropertyGrid.Text("##vdef", mDefaultBuf, ?, true, mMono, "none"))
				{
					if (mDefaultBuf != cur)
					{
						ClassEditResult(doc, doc.SetFieldInitializer(field, mDefaultBuf), "Default value");
						return true;
					}
				}
			}
			if (field.Kind == .Field && !inLib && !Mods.Has(field.Modifiers, "static") && DrawSetOnCreateRow(doc, type, field))
				return true;
			if (field.Members != null)
			{
				for (let a in field.Members)
				{
					let amg = FindMethodGraph(a);
					PropertyGrid.Row(a.Name.EndsWith(".set") ? "Setter" : "Getter", "Open the accessor's graph");
					Gui.igBeginDisabled(amg == null || !amg.Graphable);
					if (Gui.Button(scope $"{Icon.Function}  {(amg != null && amg.Graphable) ? "Open graph" : "no body"}##acc{@a.Index}", .(-1, 0)) && amg != null)
					{
						Gui.igEndDisabled();
						OpenTab(amg);
						return true;
					}
					Gui.igEndDisabled();
				}
			}
			return false;
		}

		/// The "Set on create" row of a variable: ticked when the create constructor takes it.
		/// Disabled (with the reason in the tooltip) while that constructor was edited by hand or the
		/// variable cannot be one. Returns true when the document changed.
		bool DrawSetOnCreateRow(SourceDocument doc, Member type, Member field)
		{
			if (type == null || (type.TypeKind != "class" && type.TypeKind != "struct"))
				return false;
			PropertyGrid.Row("Set on create", "Creating the object asks for this value: it becomes a parameter of the create constructor");
			List<Member> marked = scope .();
			Member ctor = null;
			let state = doc.GetCreateState(type, marked, out ctor);
			String why = scope .();
			bool eligible = doc.CanSetOnCreate(field, why);
			bool on = marked.Contains(field);
			bool disabled = (state == .Custom) || (!eligible && !on);
			if (state == .Custom)
				why.Set("custom constructor: it was edited by hand, so the checkboxes are off. Edit it in the text, or delete its \"// VisualBeef: set on create\" line to let the editor write a new one.");
			Gui.igBeginDisabled(disabled);
			bool v = on;
			bool clicked = Gui.Checkbox(scope $"{(state == .Custom ? "custom constructor" : "")}##soc", &v);
			Gui.igEndDisabled();
			if (disabled && Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip(why);
			if (clicked && v != on)
			{
				ClassEditResult(doc, doc.SetFieldSetOnCreate(type, field, v), "Set on create");
				return true;
			}
			return false;
		}

		/// Category "Attributes" for a variable or function (inside a PropertyGrid).
		bool DrawMemberAttributes(SourceDocument doc, Member m)
		{
			if (!PropertyGrid.Category("Attributes", false))
				return false;
			return DrawAttributeList(doc, m, "member");
		}

		// ------------------------------------------------------------------ Add Property / Indexer

		/// Every popup of this file (called once per frame with the other modals).
		void DrawClassPopups()
		{
			DrawRenamePreview();
			DrawAddPropertyPopups();
			if (mOpenRenameLocal)
			{
				Gui.OpenPopup("Rename Local");
				mOpenRenameLocal = false;
			}
			if (Gui.igBeginPopupModal("Rename Local", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text(scope $"New name for the local {mRenameLocalOld} (every use in the function):");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				bool enter = Gui.igInputText("##rlocal", mNameBuf.Ptr, (.)mNameBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.Button("Preview...", .(120 * Look.Scale, 0)) || enter)
				{
					let mg = EditDoc.FindMethod(mRenameLocalKey);
					if (mg != null && mg.Owner != null)
						StartProjectRename(.Local, mRenameLocalOld, mNameBuf.View, mg.Owner.Name, mRenameLocalKey, mg.Doc.FilePath);
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		void DrawAddPropertyPopups()
		{
			if (mOpenAddProperty)
			{
				Gui.OpenPopup("Add Property");
				mOpenAddProperty = false;
			}
			if (Gui.igBeginPopupModal("Add Property", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text(scope $"New property in {mAddTargetType}");
				Gui.Text("Name");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##pname", mNameBuf.Ptr, (.)mNameBuf.Capacity, 0, null, null);
				Gui.Text("Type");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##ptype", mTypeBuf.Ptr, (.)mTypeBuf.Capacity, 0, null, null);
				var propTyped = mTypeBuf.View;
				propTyped.Trim();
				bool propOk = TypeErrorText(propTyped, .Member, FindTypeIn(Doc, mAddTargetType));
				Gui.Checkbox("Setter (set)", &mNewPropSetter);
				Gui.Checkbox("Auto-property ({ get; set; }, no graphs)", &mNewPropAuto);
				Gui.igBeginDisabled(!propOk);
				bool propCreate = Gui.Button("Create", .(120 * Look.Scale, 0));
				Gui.igEndDisabled();
				if (propCreate)
				{
					let type = FindTypeIn(Doc, mAddTargetType);
					String err = scope .();
					if (type != null && RenameService.ValidName(mNameBuf.View, err) && CheckWritable())
					{
						String key = scope .();
						let ok = Doc.AddProperty(type, mTypeBuf.View, mNameBuf.View, mNewPropSetter, mNewPropAuto, key);
						ClassEditResult(Doc, ok, "Add property");
						let mg = Doc.FindMethod(key);
						if (ok && mg != null)
							OpenTab(mg);
					}
					else if (!err.IsEmpty)
						Notify.Warn(err);
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
			if (mOpenAddIndexer)
			{
				Gui.OpenPopup("Add Indexer");
				mOpenAddIndexer = false;
			}
			if (Gui.igBeginPopupModal("Add Indexer", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				Gui.Text(scope $"New indexer in {mAddTargetType}:  T this[parameters]");
				Gui.Text("Element Type");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##itype", mTypeBuf.Ptr, (.)mTypeBuf.Capacity, 0, null, null);
				Gui.Text("Parameters (e.g. int index)");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##iparams", mParamsBuf.Ptr, (.)mParamsBuf.Capacity, 0, null, null);
				var idxTyped = mTypeBuf.View;
				idxTyped.Trim();
				let idxType = FindTypeIn(Doc, mAddTargetType);
				bool idxOk = TypeErrorText(idxTyped, .Member, idxType);
				idxOk = ParamsErrorText(mParamsBuf.View, idxType) && idxOk;
				Gui.Checkbox("Setter (set)", &mNewPropSetter);
				Gui.igBeginDisabled(!idxOk);
				bool idxCreate = Gui.Button("Create", .(120 * Look.Scale, 0));
				Gui.igEndDisabled();
				if (idxCreate)
				{
					let type = FindTypeIn(Doc, mAddTargetType);
					if (type != null && CheckWritable())
					{
						String key = scope .();
						let ok = Doc.AddIndexer(type, mTypeBuf.View, mParamsBuf.View, mNewPropSetter, key);
						ClassEditResult(Doc, ok, "Add indexer");
						let mg = Doc.FindMethod(key);
						if (ok && mg != null)
							OpenTab(mg);
					}
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		/// The FUNCTIONS "+" menu: function, override, constructors, destructor, property, indexer.
		void DrawAddMemberMenu(Member type)
		{
			String typeName = scope .(type.Name);
			if (IconItem(Icon.Function, "Function..."))
			{
				mAddTargetType.Set(typeName);
				mNameBuf.Set("NewFunction");
				mTypeBuf.Set("void");
				mParamsBuf.Set("");
				mAddCtorMode = false;
				mOpenAddFunction = true;
			}
			if (type.TypeKind != "interface" && !type.IsNodeLibrary && Gui.BeginMenu(scope $"{Icon.ChevronRight}  Override"))
			{
				DrawOverrideItems(Doc, type);
				Gui.EndMenu();
			}
			Gui.Separator();
			bool lib = type.IsNodeLibrary;
			if (!lib && IconItem(Icon.Plus, "Constructor..."))
				OpenAddConstructor(typeName);
			if (IconItem(Icon.Plus, "Static Constructor  static this()"))
				AddSpecialMember(Doc, typeName, 1);
			if (!lib && IconItem(Icon.Plus, "Destructor  ~this()"))
				AddSpecialMember(Doc, typeName, 2);
			if (lib)
				return;
			Gui.Separator();
			if (IconItem(Icon.Variable, "Property (get / set graphs)..."))
			{
				mAddTargetType.Set(typeName);
				mNameBuf.Set("NewProperty");
				mTypeBuf.Set("int");
				mNewPropSetter = true;
				mNewPropAuto = false;
				mOpenAddProperty = true;
			}
			if (IconItem(Icon.ListOrdered, "Indexer  this[...]..."))
			{
				mAddTargetType.Set(typeName);
				mTypeBuf.Set("int");
				mParamsBuf.Set("int index");
				mNewPropSetter = true;
				mOpenAddIndexer = true;
			}
		}

		// ------------------------------------------------------------------ new types

		/// The text of a new type file from the Create Asset dialog: template, parent, interfaces,
		/// and (optionally) stubs for what they require.
		void MakeNewTypeText(AssetKind kind, StringView ns, StringView name, String outText)
		{
			StringView kindWord = "class";
			StringView typeMods = "";
			switch (kind)
			{
			case .Struct: kindWord = "struct";
			case .Enum: kindWord = "enum";
			case .Interface: kindWord = "interface";
			case .Library: typeMods = "static";
			default:
			}
			String baseList = scope .();
			if (!mCBNewParent.IsEmpty)
				baseList.Append(mCBNewParent);
			if (kind != .Enum)
			{
				for (let i in mCBNewInterfaces)
				{
					if (!baseList.IsEmpty)
						baseList.Append(", ");
					baseList.Append(i);
				}
			}
			TypeTemplates.Make(kindWord, ns, name, typeMods, baseList, "", outText);
			if (!mCBNewImplement || baseList.IsEmpty || kind == .Enum || kind == .Interface)
				return;
			// Stubs for what the parent / interfaces require, inside the new type.
			let unit = Parser.Parse(outText);
			defer delete unit;
			List<Member> types = scope .();
			unit.CollectTypes(types);
			if (types.IsEmpty)
				return;
			ClassInfo info = scope .();
			ClassModel.Analyze(unit, types[0], TypeService.Current, info);
			if (info.Missing.IsEmpty)
				return;
			String members = scope .();
			for (let m in info.Missing)
			{
				if (@m.Index > 0)
					members.Append("\n");
				ClassModel.StubText(m, false, "\t\t", "\t", true, members);
			}
			outText.Clear();
			TypeTemplates.Make(kindWord, ns, name, typeMods, baseList, members, outText);
		}

		/// The extra rows of the Create Asset dialog for types.
		void DrawCreateTypeOptions(AssetKind kind)
		{
			if (kind != .Class && kind != .Library && kind != .Struct && kind != .Interface && kind != .Enum)
				return;
			Gui.igSpacing();
			if (kind == .Class || kind == .Library)
			{
				Gui.Text("Template");
				Gui.igSetNextItemWidth(380 * Look.Scale);
				StringView[2] templates = .("Empty class", "Node Library (static class: global functions and variables)");
				if (PropertyGrid.Combo("##tmpl", ref mCBNewTemplate, templates))
				{
					if (mCBNewTemplate == 1)
					{
						mCBNewParent.Clear();
						ClearAndDeleteItems!(mCBNewInterfaces);
					}
					// The chosen template decides the kind: its icon, title and the file written.
					let nameNow = StringView(mCBNameBuf.View);
					if (mCBNewTemplate == 1 && nameNow.StartsWith("NewClass"))
						mCBNameBuf.Set("NewLibrary");
					else if (mCBNewTemplate != 1 && nameNow.StartsWith("NewLibrary"))
						mCBNameBuf.Set("NewClass");
					mCBNewKind = (mCBNewTemplate == 1) ? .Library : .Class;
				}
			}
			if (kind == .Library)
			{
				Gui.TextDisabled("A static class: its functions and variables are global, called as Name.Function(...).");
				Gui.TextDisabled("It has no parent, interfaces or constructors and is never constructed.");
				return;
			}
			if (kind == .Enum)
			{
				Gui.Text("Underlying Type");
				Gui.igSetNextItemWidth(380 * Look.Scale);
				StringView[5] ints = .("(int)", "uint8", "int16", "uint16", "int32");
				int32 ii = 0;
				for (int32 i = 1; i < 5; i++)
					if (mCBNewParent == ints[i])
						ii = i;
				if (PropertyGrid.Combo("##eu", ref ii, ints))
					mCBNewParent.Set((ii == 0) ? "" : ints[ii]);
				return;
			}
			Gui.Text((kind == .Interface) ? "Extends" : "Derived from");
			if (kind == .Interface)
			{
				String add = scope .();
				if (ClassPickerButton("##cbif0", add, "interface", false, false, 380) && !add.IsEmpty && !mCBNewInterfaces.Contains(add))
					mCBNewInterfaces.Add(new String(add));
			}
			else
				ClassPickerButton("##cbparent", mCBNewParent, (kind == .Struct) ? "struct" : "class", true, true, 380);
			if (kind != .Interface)
			{
				Gui.Text("Interfaces");
				String add = scope .();
				if (ClassPickerButton("##cbif", add, "interface", false, false, 380) && !add.IsEmpty && !mCBNewInterfaces.Contains(add))
					mCBNewInterfaces.Add(new String(add));
			}
			int removeAt = -1;
			for (let i in mCBNewInterfaces)
			{
				Gui.TextDisabled(scope $"    {Icon.Interface}  {i}");
				Gui.SameLine();
				if (Gui.SmallButton(scope $"{Icon.X}##rm{@i.Index}"))
					removeAt = @i.Index;
			}
			if (removeAt >= 0)
			{
				delete mCBNewInterfaces[removeAt];
				mCBNewInterfaces.RemoveAt(removeAt);
			}
			if (kind != .Interface)
				Gui.Checkbox("Implement missing members (stubs for abstract and interface members)", &mCBNewImplement);
		}

		void ResetCreateTypeOptions()
		{
			mCBNewParent.Clear();
			ClearAndDeleteItems!(mCBNewInterfaces);
			mCBNewTemplate = 0;
			mCBNewImplement = true;
		}
	}

	extension NodeMenu
	{
		/// Functions the type inherits that the catalog does not offer: protected ones of the
		/// parents (callable with self from a subclass). Private ones are never offered.
		void AddInheritedItems(MethodGraph mg)
		{
			let svc = TypeService.Current;
			if (svc == null || mg == null || mg.Owner == null)
				return;
			String baseName = scope .();
			ClassModel.BaseClassOf(mg.Doc.Unit, mg.Owner, baseName);
			if (baseName.IsEmpty)
				return;
			let h = svc.FindType(baseName, null);
			if (!h.IsValid)
				return;
			HashSet<String> seen = scope .();
			defer { for (let s in seen) delete s; }
			bool isStatic = mg.Graph.StaticContext;
			String ownerName = scope .(mg.Owner.Name);
			svc.VisitHierarchy(h, baseName, scope [&] (t, map) =>
			{
				let rec = ref t.Rec;
				for (int mi = rec.FirstMember; mi < rec.FirstMember + rec.MemberCount; mi++)
				{
					let m = ref t.Store.Members[mi];
					if (m.Visibility == .Protected && !m.IsMethod && !(isStatic && !m.IsStatic))
					{
						// A protected field or property of a parent (ToolBase.DataPath): read (and set) on self.
						let fname = t.Store.Str(m.Name);
						if (fname.IsEmpty || fname.Contains('.') || seen.ContainsAlt(fname))
							continue;
						seen.Add(new String(fname));
						let ftype = t.Store.Str(m.Type);
						let fowner = t.Store.Str(rec.Name);
						Add(.GetVar, scope $"Variables | {fowner} (inherited)", scope $"Get {fname}", fname, ftype).Tooltip.AppendF("protected {} {}\nInherited from {}", ftype, fname, fowner);
						if (m.Writable)
							Add(.SetVar, scope $"Variables | {fowner} (inherited)", scope $"Set {fname}", fname, ftype).Tooltip.AppendF("{} = value  ({})\nInherited from {}", fname, ftype, fowner);
						continue;
					}
					if (m.Visibility != .Protected || !m.IsMethod || m.Kind == .Ctor || (isStatic && !m.IsStatic))
						continue;
					let name = t.Store.Str(m.Name);
					if (name.IsEmpty || name.Contains('.') || name.StartsWith('~') || seen.ContainsAlt(name))
						continue;
					seen.Add(new String(name));
					String paramsText = scope .();
					for (int pi < m.ParamCount)
					{
						let p = ref t.Store.Params[m.FirstParam + pi];
						if (pi > 0)
							paramsText.Append(", ");
						let mod = t.Store.Str(p.Modifier);
						if (!mod.IsEmpty)
							paramsText.AppendF("{} ", mod);
						paramsText.AppendF("{} {}", t.Store.Str(p.Type), t.Store.Str(p.Name));
					}
					let owner = t.Store.Str(rec.Name);
					let item = Add(.CallMethod, scope $"Functions | {owner} (inherited)", scope $"{name}({paramsText})", name, paramsText, t.Store.Str(m.Type));
					item.OnType.Set(owner);
					item.Static = m.IsStatic;
					item.Tooltip.AppendF("protected {} {}({})\nInherited from {}; Receiver is {} ({})", t.Store.Str(m.Type), name, paramsText, owner, ownerName, m.IsStatic ? "static" : "this");
				}
				return true;
			});
		}
	}
}
