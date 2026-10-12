using System;
using System.Collections;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// Properties > Outputs (the return value plus one row per `out` parameter), and the
	/// function's Locals (Graph.Locals, declared at the top of the body): listed in the Outline,
	/// the selected one shown in Properties. See
	/// docs/Classes-and-Members.md#outputs and #locals.
	extension EditorApp
	{
		/// A Local picked in the Outline (LOCAL VARIABLES under the open function): Properties shows it.
		public bool mSelLocalActive;
		public String mSelLocalName = new .() ~ delete _;
		public String mSelLocalKey = new .() ~ delete _;
		/// The Outline row of the selected Local is a name box (a Local just added, or F2).
		bool mLocalEditing;
		bool mLocalEditFocus;
		TextBuffer mLocalEditBuf = new .(256) ~ delete _;
		/// Properties' name box of the selected Local.
		String mLocalNameEdit = new .() ~ delete _;
		String mLocalNameFor = new .() ~ delete _;
		/// Argument / text box of a Local made here (`scope .(...)`).
		String mLocalArgsBuf = new .() ~ delete _;
		String mLocalArgsKey = new .() ~ delete _;

		/// The rows of Properties > Outputs after the return value: one per `out` parameter.
		/// Sets `sigDone` when the signature changed (the caller writes it).
		void DrawOutputRows(MethodGraph mg, ref bool sigDone)
		{
			let m = mg.Method;
			int removeAt = -1;
			int moveUp = -1;
			int moveDown = -1;
			List<int> outRows = scope .();
			for (let r in mParamRows)
				if (r.Modifier == "out")
					outRows.Add(@r.Index);
			for (int k < outRows.Count)
			{
				let i = outRows[k];
				let r = mParamRows[i];
				Gui.PushID((int32)(5000 + i));
				PropertyGrid.BeginRow();
				Gui.igIndent(14 * Look.Scale);
				Gui.igSetNextItemWidth(-1);
				if (i == mFocusParamRow)
				{
					Gui.igSetKeyboardFocusHere(0);
					mFocusParamRow = -1;
				}
				if (PropertyGrid.Text("##on", r.Name, ?, false, null, "name"))
					sigDone = true;
				// Right-click the name: move the output (also the arrows, when the row is wide enough).
				if (Gui.igBeginPopupContextItem())
				{
					if (k > 0 && IconItem(Icon.ChevronUp, "Move Up"))
						moveUp = k;
					if (k < outRows.Count - 1 && IconItem(Icon.ChevronDown, "Move Down"))
						moveDown = k;
					if (IconItem(Icon.X, "Remove"))
						removeAt = i;
					Gui.EndPopup();
				}
				Gui.igUnindent(14 * Look.Scale);
				Gui.igTableSetColumnIndex(1);
				float x = Gui.igGetFrameHeight();
				// The arrows only when the type picker keeps room for a type name.
				bool arrows = Gui.igGetContentRegionAvail().x - 3 * (x + 4 * Look.Scale) >= 96 * Look.Scale;
				if (TypeButton("##ot", r.Type, Gui.igGetContentRegionAvail().x - (arrows ? 3 : 1) * (x + 4 * Look.Scale) - 6 * Look.Scale, .Param, m))
					sigDone = true;
				TypeErrorText(r.Type, .Param, m);
				Gui.SameLine(0, 4 * Look.Scale);
				if (arrows)
				{
					Gui.igBeginDisabled(k == 0);
					if (Gui.Button(Icon.ChevronUp, .(x, x)))
						moveUp = k;
					Gui.igEndDisabled();
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Move this output up");
					Gui.SameLine(0, 4 * Look.Scale);
					Gui.igBeginDisabled(k == outRows.Count - 1);
					if (Gui.Button(Icon.ChevronDown, .(x, x)))
						moveDown = k;
					Gui.igEndDisabled();
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Move this output down");
					Gui.SameLine(0, 4 * Look.Scale);
				}
				if (Gui.Button(Icon.X, .(x, x)))
					removeAt = i;
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Remove this output");
				Gui.PopID();
			}
			PropertyGrid.WideRow();
			if (Gui.Button(scope $"{Icon.Plus}  Add Output"))
			{
				ParamRow r = new .();
				r.Modifier.Set("out");
				r.Type.Set("int");
				String name = scope .("output");
				for (int n = 2; ParamNameTaken(name); n++)
				{
					name.Clear();
					name.AppendF("output{}", n);
				}
				r.Name.Set(name);
				mParamRows.Add(r);
				mFocusParamRow = mParamRows.Count - 1;
				sigDone = true;
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Another value the function gives back: every call gets an output pin for it, and each Return an input for it");
			if (moveUp > 0 || (moveDown >= 0 && moveDown < outRows.Count - 1))
			{
				let a = (moveUp > 0) ? outRows[moveUp - 1] : outRows[moveDown];
				let b = (moveUp > 0) ? outRows[moveUp] : outRows[moveDown + 1];
				Swap!(mParamRows[a], mParamRows[b]);
				sigDone = true;
			}
			if (removeAt >= 0)
			{
				delete mParamRows[removeAt];
				mParamRows.RemoveAt(removeAt);
				sigDone = true;
			}
			// The Beef the rows stand for, read-only (like the ownership rows' declaration line).
			String pars = scope .();
			ParamsText(pars);
			InitPreviewLine(scope $"{mRetType} {m.Name}({pars})");
		}

		bool ParamNameTaken(StringView name)
		{
			for (let o in mParamRows)
				if (o.Name == name)
					return true;
			return false;
		}

		/// A name no parameter, Local or variable of the Sheet uses yet.
		public static void UniqueLocalName(MethodGraph mg, StringView baseName, String outName)
		{
			outName.Set(baseName);
			for (int i = 2; LocalNameTaken(mg, outName); i++)
			{
				outName.Set(baseName);
				outName.AppendF("{}", i);
			}
		}

		public static bool LocalNameTaken(MethodGraph mg, StringView name)
		{
			for (let p in mg.Method.Params)
				if (p.Name == name)
					return true;
			if (mg.Graph.FindLocal(name) != null)
				return true;
			for (let n in mg.Graph.Nodes)
				if ((n.Kind == .LocalVar || n.Kind == .ForEach || n.Kind == .Using || n.IsCountingLoop) && n.Text == name)
					return true;
			return false;
		}

		/// Outline > LOCAL VARIABLES > + (and hotkey L): `int newLocal = 0;` at the end of the
		/// function's Locals, selected in the Outline with its name box focused.
		public bool AddLocalTo(MethodGraph mg, StringView type = "int", StringView baseName = "newLocal")
		{
			if (mg == null || mg.Graph == null || mg.Graph.ReadOnly || !CheckWritable())
				return false;
			String name = scope .();
			UniqueLocalName(mg, baseName, name);
			String value = scope .();
			NodeFactory.ReturnDefault(type, value);
			BeginEdit();
			NodeFactory.AddLocal(mg.Graph, name, type, value);
			CommitCurrent();
			SelectLocal(mg, name, true);
			return true;
		}

		/// Selects a Local of `mg` (its Outline row highlighted, Properties shows it); `edit` turns
		/// its Outline row into a focused name box.
		public void SelectLocal(MethodGraph mg, StringView name, bool edit = false)
		{
			mSelLocalActive = true;
			mSelLocalName.Set(name);
			mSelLocalKey.Set(mg.Key);
			mSelVarActive = false;
			mSelClassActive = false;
			mSelVarSigPending = true;
			mLocalEditing = edit;
			mLocalEditFocus = edit;
			if (edit)
				mLocalEditBuf.Set(name);
		}

		/// The selected Local, or null (its function must be the Sheet in front).
		Node SelectedLocal(out MethodGraph outMg)
		{
			outMg = null;
			if (!mSelLocalActive)
				return null;
			let mg = CurrentMethod;
			if (mg == null || mg.Key != mSelLocalKey || !mg.Graphable || mg.Graph == null)
				return null;
			outMg = mg;
			return mg.Graph.FindLocal(mSelLocalName);
		}

		/// Hotkey L on a Sheet: a new Local of the function, selected in the Outline, name focused.
		public void AddLocalFromKey(GraphTab tab, MethodGraph mg)
		{
			if (tab == null || mg == null || !mg.Graphable || mg.Graph.ReadOnly)
				return;
			tab.ClearSelection();
			if (AddLocalTo(mg))
			{
				Panels.Focus(Panels.OutlineId);
				SetStatus(scope $"Added a local variable to {mg.Method.Name}: type its name in the Outline.");
			}
		}

		/// Renames Local `index`: directly when nothing else in the body says its name, else with
		/// the rename preview (every use in the function).
		void RenameLocal(MethodGraph mg, int index, StringView newName)
		{
			let local = mg.Graph.Locals[index];
			String err = scope .();
			if (!ValidateIdentifier(newName, err))
			{
				Notify.Warn(err);
				return;
			}
			if (LocalNameTaken(mg, newName))
			{
				Notify.Warn(scope $"{newName} is already a name in {mg.Method.Name}.");
				return;
			}
			int uses = 0;
			let unit = mg.Doc.Unit;
			let body = mg.Method.Body;
			if (body != null)
				for (int t = body.FirstTok; t <= body.LastTok && t < unit.Tokens.Count; t++)
					if (unit.TokenText(t) == local.Text)
						uses++;
			if (uses > 1 && mg.Owner != null)
			{
				StartProjectRename(.Local, local.Text, newName, mg.Owner.Name, mg.Key, mg.Doc.FilePath);
				return;
			}
			BeginEdit();
			local.Text.Set(newName);
			local.FindOutput("variable")?.Label.Set(newName);
			local.Edited = true;
			CommitCurrent();
			if (mSelLocalActive && mSelLocalKey == mg.Key)
				mSelLocalName.Set(newName);
		}

		/// Properties for the Local selected in the Outline: name, type, Ownership, Initial Value,
		/// delete. False when there is none (the panel then shows the usual selection).
		bool DrawLocalDetails()
		{
			let local = SelectedLocal(let mg);
			if (local == null)
			{
				mSelLocalActive = false;
				return false;
			}
			let index = mg.Graph.Locals.IndexOf(local);
			String key = scope $"{mg.Key}|{local.Text}";
			if (key != mLocalNameFor && !Gui.igIsAnyItemActive())
			{
				mLocalNameFor.Set(key);
				mLocalNameEdit.Set(local.Text);
			}
			DetailsHeader(Icon.Variable, Theme.TypeColor(local.Text2), local.Text, scope $"Local variable in {mg.Method.Name}");
			bool commit = false;
			if (PropertyGrid.Begin("##localgrid"))
			{
				if (PropertyGrid.Category("Local Variable", true))
				{
					PropertyGrid.Row("Variable Name", "Renames the local variable and its uses in this function");
					if (PropertyGrid.Text("##lname", mLocalNameEdit, ?))
					{
						String newName = scope .(mLocalNameEdit);
						newName.Trim();
						if (newName != local.Text && !newName.IsEmpty)
						{
							RenameLocal(mg, index, newName);
							PropertyGrid.End();
							return true;
						}
					}
					PropertyGrid.Row("Variable Type", "Pick a type (with container) or type one", Theme.TypeColor(local.Text2));
					String type = scope .(local.Text2);
					if (TypeButton("##ltype", type, -1, .Local, mg.Method) && type != local.Text2)
					{
						if (type == "var" || type == "let" || type.IsEmpty)
							Notify.Warn("A local variable here has a type: pick one.");
						else
						{
							BeginEdit();
							local.Text2.Set(type);
							local.FindInput("value")?.TypeName.Set(type);
							local.FindOutput("variable")?.TypeName.Set(type);
							// A value made for the old type does not fit the new one: start from its default.
							let value = local.FindInput("value");
							if (value != null && !value.Default.IsEmpty)
							{
								value.Default.Clear();
								NodeFactory.ReturnDefault(type, value.Default);
							}
							local.Edited = true;
							commit = true;
						}
					}
					TypeErrorText(local.Text2, .Local, mg.Method);
					if (!commit)
						DrawLocalValueRows(mg, local, index, ref commit);
					PropertyGrid.Row("Function");
					PropertyGrid.Value(mg.Method.Name);
				}
				if (!commit && PropertyGrid.Category("Nodes", true))
				{
					PropertyGrid.WideRow();
					Gui.igPushStyleColor_U32(Col.Button, Gui.Color(120, 30, 30));
					Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(160, 40, 40));
					if (Gui.Button(scope $"{Icon.Trash2}  Delete Local Variable"))
					{
						String why = scope .();
						if (!mg.Graph.IsLocalUsed(local))
						{
							BeginEdit();
							mg.Graph.RemoveLocal(local, why);
							mSelLocalActive = false;
							commit = true;
						}
						else
						{
							mg.Graph.RemoveLocal(local, why);
							SetStatus(why, .Warning);
						}
					}
					Gui.igPopStyleColor(2);
				}
				PropertyGrid.End();
			}
			if (commit)
			{
				mg.Graph.Version++;
				CommitCurrent();
			}
			return true;
		}

		/// Moves a Local up or down in the declaration order (Outline context menu).
		void MoveLocal(MethodGraph mg, Node local, int delta)
		{
			let i = mg.Graph.Locals.IndexOf(local);
			let j = i + delta;
			if (i < 0 || j < 0 || j >= mg.Graph.Locals.Count)
				return;
			BeginEdit();
			let other = mg.Graph.Locals[j];
			mg.Graph.Locals[j] = local;
			mg.Graph.Locals[i] = other;
			local.Moved = true;
			other.Moved = true;
			local.Edited = true;
			other.Edited = true;
			mg.Graph.Version++;
			CommitCurrent();
		}

		/// Outline: the one LOCAL VARIABLES section, directly below VARIABLES. Its rows are the locals
		/// of the function whose Sheet is in front (`mg`; null = no Sheet: one dim row), with the + and
		/// one row per Local (selectable, draggable onto the Sheet like a member variable). The section
		/// keeps its place; only the rows follow the open function.
		/// Returns true when the document changed (the member list must not be used further).
		bool DrawOutlineLocals(MethodGraph mg, StringView ownerName)
		{
			if (mg == null)
			{
				mOlNone = true;
				bool openNone = BPSection(scope $"loc|{ownerName}", "LOCAL VARIABLES", 0, let addNone, "Open a function to add a local variable");
				if (addNone)
					SetStatus("Open a function first: a local variable belongs to the function whose Sheet is in front.", .Warning);
				if (openNone)
				{
					Gui.igPushStyleColor_U32(Col.Text, Theme.TextDim);
					Gui.Text("    Open a function to see its locals");
					Gui.igPopStyleColor(1);
				}
				return false;
			}
			let g = mg.Graph;
			for (let local in g.Locals)
			{
				if (!mOlLocalNames.IsEmpty)
					mOlLocalNames.Append(',');
				mOlLocalNames.Append(local.Text);
			}
			bool open = BPSection(scope $"loc|{ownerName}", "LOCAL VARIABLES", g.Locals.Count, let add, scope $"Add a local variable to {mg.Method.Name} (L)");
			if (add)
			{
				AddLocalTo(mg);
				return true;
			}
			if (!open)
			{
				for (let local in g.Locals)
					AddMemberRef(.Variable, local.Text, local.Text2, "", ownerName, false);
				return false;
			}
			for (let local in g.Locals)
			{
				Gui.PushID((int32)(30000 + mMembers.Count));
				bool selected = mSelLocalActive && mSelLocalKey == mg.Key && mSelLocalName == local.Text;
				if (selected && mLocalEditing)
				{
					// The name box of a Local just added (or F2): leaving it renames.
					Gui.igIndent(14 * Look.Scale);
					Gui.igSetNextItemWidth(-1);
					if (mLocalEditFocus)
					{
						Gui.igSetKeyboardFocusHere(0);
						mLocalEditFocus = false;
					}
					Gui.igInputText("##lnameedit", mLocalEditBuf.Ptr, (.)mLocalEditBuf.Capacity, 0, null, null);
					bool done = Gui.igIsItemDeactivated();
					Gui.igUnindent(14 * Look.Scale);
					AddMemberRef(.Variable, local.Text, local.Text2, "", ownerName, false);
					Gui.PopID();
					if (done)
					{
						mLocalEditing = false;
						String newName = scope .(mLocalEditBuf.View);
						newName.Trim();
						if (!newName.IsEmpty && newName != local.Text)
						{
							RenameLocal(mg, g.Locals.IndexOf(local), newName);
							return true;
						}
					}
					continue;
				}
				let cur = Gui.igGetCursorScreenPos();
				float h = Gui.igGetTextLineHeight();
				if (Gui.Selectable(scope $"##local{local.Text}", selected, SelectableFlags.AllowDoubleClick))
				{
					SelectLocal(mg, local.Text);
					for (let t in Tabs)
						if (t.Doc == mg.Doc && t.MethodKey == mg.Key)
							t.ClearSelection();
					if (Gui.igIsMouseDoubleClicked_Nil(0))
					{
						mLocalEditing = true;
						mLocalEditFocus = true;
						mLocalEditBuf.Set(local.Text);
					}
				}
				let dl = Gui.igGetWindowDrawList();
				{
					// A breakpoint on the declaration: a red dot at the row's left edge; the arrow
					// where the program is stopped.
					HashSet<int32> bpIds = scope .();
					BreakpointNodes(mg, bpIds);
					// Where the program is stopped: a yellow arrow (as in the graph) takes the marker column
					// instead of the dot, so the two never overlap in the 17 px before the Local's swatch.
					float cy = cur.y + h * 0.5f;
					if (IsDebugStopped && DebugStopGraph == g && DebugStopNode == local.Id)
					{
						float s = 4.5f * Look.Scale;
						Gui.ImDrawList_AddTriangleFilled(dl, .(cur.x + 2 * Look.Scale, cy - s), .(cur.x + 2 * Look.Scale, cy + s), .(cur.x + 2 * Look.Scale + s * 1.4f, cy), 0xFF28C8FF);
					}
					else if (bpIds.Contains(local.Id))
						Gui.ImDrawList_AddCircleFilled(dl, .(cur.x + 9.5f * Look.Scale, cy), h * 0.16f, 0xFF3838E0, 0);
				}
				let col = Theme.TypeColor(local.Text2);
				Gui.ImDrawList_AddRectFilled(dl, .(cur.x + 14 * Look.Scale, cur.y + h * 0.22f), .(cur.x + 34 * Look.Scale, cur.y + h * 0.78f), col, h * 0.3f, 0);
				Gui.DrawText(dl, .(cur.x + 42 * Look.Scale, cur.y), selected ? Look.ForegroundHover : Look.Foreground, local.Text);
				{
					let max = Gui.igGetItemRectMax();
					String fit = scope .();
					float nameW = 42 * Look.Scale + Gui.CalcTextSize(local.Text).x + 12 * Look.Scale;
					FitText(local.Text2, Math.Max(0, max.x - cur.x - nameW), fit);
					float tw = Gui.CalcTextSize(fit).x;
					Gui.DrawText(dl, .(max.x - tw - 4 * Look.Scale, cur.y), Gui.Color(120, 120, 120), fit);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(scope $"{local.Text} : {local.Text2}  (local variable of {mg.Method.Name})\nDrag into the graph: Ctrl = Get, Alt = Set");
				AddMemberRef(.Variable, local.Text, local.Text2, "", ownerName, false);
				if (Gui.igBeginDragDropSource(0))
				{
					int32 idx = (int32)mMembers.Count - 1;
					Gui.igSetDragDropPayload("VB_MEMBER", &idx, sizeof(int32), 0);
					Gui.Text(scope $"{Icon.Variable}  {local.Text}  (Ctrl: Get, Alt: Set, or choose on drop)");
					Gui.igEndDragDropSource();
				}
				LuMenuOpenHook(local.Text);
				bool changed = false;
				if (Gui.igBeginPopupContextItem())
				{
					LuMenuCloseHook();
					if (IconItem(Icon.Pencil, "Rename...", "F2"))
						SelectLocal(mg, local.Text, true);
					let i = g.Locals.IndexOf(local);
					if (i > 0 && IconItem(Icon.ChevronUp, "Move Up"))
					{
						MoveLocal(mg, local, -1);
						changed = true;
					}
					if (!changed && !mg.Doc.FilePath.IsEmpty && IconItem(Icon.CircleDot, "Toggle Breakpoint", "F9"))
						ToggleBreakpoint(mg, local);
					if (!changed && i < g.Locals.Count - 1 && IconItem(Icon.ChevronDown, "Move Down"))
					{
						MoveLocal(mg, local, 1);
						changed = true;
					}
					if (!changed && IconItem(Icon.Trash2, "Delete Local Variable"))
					{
						String why = scope .();
						if (g.IsLocalUsed(local))
						{
							g.RemoveLocal(local, why);
							SetStatus(why, .Warning);
						}
						else
						{
							BeginEdit();
							g.RemoveLocal(local, why);
							if (selected)
								mSelLocalActive = false;
							CommitCurrent();
							changed = true;
						}
					}
					Gui.EndPopup();
				}
				Gui.PopID();
				if (changed)
					return true;
			}
			return false;
		}

		/// `scope .(args)` as the arguments, or false when the value is not that form.
		static bool ScopeArgs(StringView value, String outArgs)
		{
			var v = value;
			v.Trim();
			if (!v.StartsWith("scope .(") || !v.EndsWith(")"))
				return false;
			outArgs.Append(v.Substring(8, v.Length - 9));
			return true;
		}

		/// A Local's Ownership (class types: a reference, or made here for this call with `scope`)
		/// and its Initial Value (the same controls as a member variable's).
		void DrawLocalValueRows(MethodGraph mg, Node local, int row, ref bool commit)
		{
			let valuePin = local.FindInput("value");
			if (valuePin == null)
				return;
			let types = TypeService.Current;
			let t = MemberInit.TypeOf(local.Text2, types);
			bool canMake = !t.IsPointer && !local.Text2.EndsWith("]") && (t.Kind == .Class || t.Kind == .String || t.Kind == .Unknown);
			String args = scope .();
			bool made = ScopeArgs(valuePin.Default, args);
			if (canMake || made)
			{
				PropertyGrid.Row("Ownership", "Who makes the object this Local holds");
				Gui.igSetNextItemWidth(-1);
				if (Gui.igBeginCombo(scope $"##lown{row}", made ? "Made for this call" : "Reference", 0))
				{
					if (Gui.Selectable("Reference", !made) && made)
					{
						BeginEdit();
						valuePin.Default.Set("null");
						local.Edited = true;
						commit = true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Holds an object made somewhere else (or nothing yet): never deleted here");
					if (Gui.Selectable("Made for this call", made) && !made)
					{
						BeginEdit();
						valuePin.Default.Set("scope .()");
						local.Edited = true;
						commit = true;
					}
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Made when the function starts and gone when it returns (Beef: scope)");
					Gui.igEndCombo();
				}
				if (commit)
					return;
				if (made)
				{
					String key = scope $"{local.Text}|{valuePin.Default}";
					if (key != mLocalArgsKey && !Gui.igIsAnyItemActive())
					{
						mLocalArgsKey.Set(key);
						mLocalArgsBuf.Clear();
						if (t.Kind == .String && MemberInit.IsSingleStringLiteral(args))
							MemberInit.UnquoteLiteral(args, mLocalArgsBuf);
						else
							mLocalArgsBuf.Set(args);
					}
					bool isText = t.Kind == .String && (args.IsEmpty || MemberInit.IsSingleStringLiteral(args));
					PropertyGrid.Row(isText ? "Initial Text" : "Arguments", isText ? "The text it starts with" : "What the constructor is given, separated by commas");
					if (PropertyGrid.Text(scope $"##largs{row}", mLocalArgsBuf, ?))
					{
						String newArgs = scope .();
						if (isText && !mLocalArgsBuf.IsEmpty)
							MemberInit.QuoteString(mLocalArgsBuf, newArgs);
						else
							newArgs.Set(mLocalArgsBuf);
						if (newArgs != args)
						{
							BeginEdit();
							valuePin.Default.Set(scope $"scope .({newArgs})");
							local.Edited = true;
							commit = true;
							return;
						}
					}
					InitPreviewLine(scope $"{local.Text2} {local.Text} = {valuePin.Default};");
					return;
				}
			}
			DrawLocalInitRows(mg, local, ref commit, scope $"lv{row}");
			if (commit)
				local.Edited = true;
		}
	}
}
