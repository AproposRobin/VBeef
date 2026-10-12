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
	/// One editable function parameter row in Properties (UE's Inputs list).
	class ParamRow
	{
		public String Modifier = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public String Name = new .() ~ delete _;
		public String Default ~ delete _;
	}

	/// The Properties panel as a UE property grid: categories with collapsible bars, names on the
	/// left, UE-like widgets on the right (checkboxes, numeric drags, enum combos, type pickers).
	/// The data binding is the same as before: edits go through BeginEdit / CommitCurrent and
	/// the SourceDocument signature APIs.
	extension EditorApp
	{
		List<ParamRow> mParamRows = new .() ~ DeleteContainerAndItems!(_);
		String mParamRowsFor = new .() ~ delete _;
		int32 mParamRowsVersion = -1;
		String mRetType = new .() ~ delete _;
		String mFnNameEdit = new .() ~ delete _;
		/// The Inputs row whose name gets the keyboard focus on the next draw (a row just added).
		int mFocusParamRow = -1;
		Dictionary<String, List<String>> mEnumCaseCache = new .() ~ { for (let kv in _) { delete kv.key; DeleteContainerAndItems!(kv.value); } delete _; };
		double mEnumCacheTime;

		// ------------------------------------------------------------------ helpers

		/// A text property bound to `value`: the first keystroke records an undo step, the edit is
		/// committed when the field is left. Returns true on commit.
		bool GridText(StringView name, StringView id, String value, StringView tip = default, bool mono = false, StringView hint = default, uint32 swatch = 0)
		{
			PropertyGrid.Row(name, tip, swatch);
			String before = scope .(value);
			bool done = PropertyGrid.Text(id, value, let changed, mono, mMono, hint);
			if (changed && !mDetailsEditPushed)
				BeginEditBefore(value, before);
			return done;
		}

		/// The grid widgets write into the node's own string as you type or pick, so the undo
		/// step (a copy of the graph) must see the value from before the change: put it back for
		/// the snapshot, then the new one again.
		void BeginEditBefore(String value, StringView before)
		{
			String now = scope .(value);
			value.Set(before);
			BeginEdit();
			value.Set(now);
			mDetailsEditPushed = true;
		}

		/// The type picker on a node's type field, with the undo step taken before the change.
		bool NodeTypeButton(StringView id, String type, VisualBeef.Catalog.TypeSlot slot, Member scopeOf)
		{
			String before = scope .(type);
			if (!TypeButton(id, type, -1, slot, scopeOf))
				return false;
			String now = scope .(type);
			type.Set(before);
			BeginEdit();
			type.Set(now);
			return true;
		}

		/// Cases of a project enum (".Case" values for enum pins), cached for a moment.
		List<String> GetEnumCases(StringView typeName)
		{
			let now = Desktop.Now;
			if (now - mEnumCacheTime > 3)
			{
				for (let kv in mEnumCaseCache)
				{
					delete kv.key;
					DeleteContainerAndItems!(kv.value);
				}
				mEnumCaseCache.Clear();
				mEnumCacheTime = now;
			}
			String baseName = scope .();
			ProjectIndex.BaseTypeName(typeName, baseName);
			if (baseName.IsEmpty)
				return null;
			if (mEnumCaseCache.TryGetValue(baseName, let cached))
				return cached;
			List<String> cases = new .();
			mEnumCaseCache[new String(baseName)] = cases;
			let st = Index.FindType(baseName);
			if (st == null || st.Kind != "enum")
				return cases;
			// Use the open document, else parse the file privately (nothing is opened or written).
			var doc = FindDoc(st.FilePath);
			SourceDocument temp = null;
			if (doc == null)
			{
				temp = new SourceDocument();
				if (temp.Load(st.FilePath) case .Err)
				{
					delete temp;
					return cases;
				}
				doc = temp;
			}
			defer { delete temp; }
			let type = FindTypeMember(doc, baseName);
			if (type != null)
			{
				List<EnumCase> ecs = scope .();
				defer { ClearAndDeleteItems!(ecs); }
				EnumCases.Parse(doc.Unit, type, ecs);
				for (let ec in ecs)
					cases.Add(new String(ec.Name));
			}
			return cases;
		}

		static bool IsIntType(StringView t) => t == "int" || t == "int8" || t == "int16" || t == "int32" || t == "int64" ||
			t == "uint" || t == "uint8" || t == "uint16" || t == "uint32" || t == "uint64";
		static bool IsFloatType(StringView t) => t == "float" || t == "double";

		PinValueEditor mPropPinEditor = new .() ~ delete _;

		/// Self test: the Overload dropdown of the selected call is opened / closed on the next draw.
		public bool SelfTestOpenOverloads;
		public bool SelfTestCloseOverloads;
		/// Self test: how many overloads the dropdown listed when it was last drawn open.
		public int SelfTestOverloadRows;

		/// Properties > Call > Overload: every overload of the call's function, the one the node shows
		/// marked. Picking one is ChooseOverload. True when the node changed (the caller commits).
		bool DrawOverloadChoice(MethodGraph mg, Node node)
		{
			List<SymbolMethod> overloads = scope .();
			CallOverloads.ListOf(mg.Graph, node, TypeService.Current, overloads);
			if (overloads.Count < 2)
				return false;
			PropertyGrid.Row("Overload", "Which of the function's overloads the node calls. Beef chooses by the arguments: a wired or typed value picks the most specific one. Picking another one here writes a Cast where the arguments would choose differently.");
			let cur = CallOverloads.IndexOfCurrent(node, overloads);
			String curSig = scope .();
			if (cur >= 0)
				CallOverloads.Signature(overloads[cur], curSig);
			else
				CallOverloads.PinSignature(node, curSig);
			SymbolMethod pick = null;
			if (SelfTestOpenOverloads)
			{
				SelfTestOpenOverloads = false;
				Gui.OpenPopup("##ovlpop");
			}
			let start = Gui.igGetCursorScreenPos();
			let h = Gui.igGetFrameHeight();
			let width = Gui.igGetContentRegionAvail().x;
			// Left-aligned like the other dropdowns; a signature wider than the row ends in "..." (the
			// whole one is in the tooltip and the list).
			String shown = scope .();
			GraphPanel.Ellipsize(curSig, width - 18 * Look.Scale, 1.0f, shown);
			Gui.igPushStyleColor_U32(Col.Button, Look.Input);
			Gui.igPushStyleVar_Vec2(StyleVarX.ButtonTextAlign, .(0, 0.5f));
			if (Gui.Button(scope $"{shown}##ovlbtn", .(width, h)))
				Gui.OpenPopup("##ovlpop");
			Gui.igPopStyleVar(1);
			Gui.igPopStyleColor(1);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip(curSig);
			// The list opens under the button (above it when there is no room below), inside the window.
			let display = Gui.igGetIO_Nil().DisplaySize;
			float listW = width;
			for (let m in overloads)
			{
				String s = scope .();
				CallOverloads.Signature(m, s);
				listW = Math.Max(listW, Gui.CalcTextSize(s).x + 60 * Look.Scale);
			}
			float listH = overloads.Count * (Gui.igGetFontSize() + 8 * Look.Scale) + 16 * Look.Scale;
			float listX = Math.Max(0, Math.Min(start.x, display.x - listW - 4 * Look.Scale));
			bool above = start.y + h + listH > display.y && start.y - listH > 0;
			Gui.igSetNextWindowPos(.(listX, above ? start.y : start.y + h), Cond.Always, .(0, above ? 1 : 0));
			Gui.igSetNextWindowSize(.(listW, 0), Cond.Always);
			if (Look.BeginPopupSpaced("##ovlpop"))
			{
				if (SelfTestCloseOverloads)
				{
					SelfTestCloseOverloads = false;
					Gui.igCloseCurrentPopup();
				}
				SelfTestOverloadRows = overloads.Count;
				String why = scope .();
				for (let m in overloads)
				{
					String sig = scope .();
					CallOverloads.Signature(m, sig);
					why.Clear();
					bool ok = CallOverloads.Applicable(node, m, why);
					if (!ok)
						Gui.igBeginDisabled(true);
					if (Gui.Selectable(scope $"{Icon.Function}  {sig}##ovl{@m.Index}", @m.Index == cur) && ok && @m.Index != cur)
						pick = m;
					if (!ok)
					{
						Gui.igEndDisabled();
						if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
							Gui.Tooltip(why);
					}
				}
				Look.EndPopupSpaced();
			}
			if (pick == null)
				return false;
			String sig = scope .();
			CallOverloads.Signature(pick, sig);
			return ChooseOverload(mg, node, sig);
		}

		/// Makes the call show the overload with signature `sig` (`WriteLine(StringView line)`), as
		/// picking it in Properties > Call > Overload does: one undo step, wires kept where they fit.
		public bool ChooseOverload(MethodGraph mg, Node node, StringView sig)
		{
			List<SymbolMethod> overloads = scope .();
			CallOverloads.ListOf(mg.Graph, node, TypeService.Current, overloads);
			for (let m in overloads)
			{
				String s = scope .();
				CallOverloads.Signature(m, s);
				if (s != sig)
					continue;
				BeginEdit();
				String why = scope .();
				if (!CallOverloads.Choose(mg.Graph, node, m, TypeService.Current, why))
				{
					SetStatus(why, .Warning);
					return false;
				}
				if (!why.IsEmpty)
					SetStatus(why, .Warning);
				return true;
			}
			return false;
		}

		/// Value widget for an unlinked data input, by pin type (the same rules as the node canvas:
		/// PinValue). Returns true when committed.
		bool PinValueWidget(Node node, Pin p)
		{
			let kind = PinValue.KindOf(p.TypeName, p.Default, p.Name, TypeService.Current);
			if (PinValueEditor.Handles(kind))
				return mPropPinEditor.Draw(this, node, p, kind, Gui.igGetContentRegionAvail().x);
			if (kind == .None)
			{
				Gui.TextColored(Look.ForegroundDim, p.Default.IsEmpty ? "wire it, or use a Construct node" : StringView(p.Default));
				return false;
			}
			// Beef expression text: an unknown type, a receiver, or a value that is not a plain literal (Custom).
			String before = scope .(p.Default);
			bool done = PropertyGrid.Text("##v", p.Default, let changed, false, null, (p.Name == "target") ? "this" : (kind == .Custom ? "an expression" : ""));
			if (changed && !mDetailsEditPushed)
				BeginEditBefore(p.Default, before);
			if (kind == .Custom && Gui.igIsItemHovered(0))
				Gui.Tooltip(scope $"{GraphPanel.cExpressionBadge}: {GraphPanel.cExpressionTip}");
			return done;
		}

		// ------------------------------------------------------------------ panel

		void DrawPropertiesPanel()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 4 * Look.Scale));
			bool visible = Gui.Begin(Panels.Properties);
			Gui.igPopStyleVar(1);
			if (visible)
			{
				let tab = CurrentTab;
				let mg = CurrentMethod;
				// A variable picked in Outline shows until the graph selection changes.
				int sig = (tab == null) ? -1 : (tab.SelectedNodes.Count * 7919 + (tab.SelectedNodes.IsEmpty ? 0 : tab.SelectedNodes[0]));
				if (mSelVarSigPending)
				{
					mSelVarSig = sig;
					mSelVarSigPending = false;
				}
				else if (sig != mSelVarSig)
				{
					mSelVarSig = sig;
					mSelVarActive = false;
					mSelClassActive = false;
					mSelLocalActive = false;
					mSelProjectActive = false;
				}
				if (mSelClassActive && DrawTypeSettings())
				{
				}
				else if (mSelVarActive && DrawVariableDetails())
				{
				}
				else if (mSelLocalActive && DrawLocalDetails())
				{
				}
				else if (mSelProjectActive && DrawProjectSettings())
				{
				}
				else if (tab == null || mg == null)
				{
					Gui.igIndent(10 * Look.Scale);
					Gui.igPushTextWrapPos(0);
					Gui.TextDisabled("Select a node, a variable or a function to see its properties.");
					Gui.igPopTextWrapPos();
					Gui.igUnindent(10 * Look.Scale);
				}
				else if (tab.SelectedNodes.Count == 1 && mg.Graph.FindNode(tab.SelectedNodes[0]) != null &&
					mg.Graph.FindNode(tab.SelectedNodes[0]) != mg.Graph.Entry)
					DrawNodeDetails(mg, mg.Graph.FindNode(tab.SelectedNodes[0]));
				else if (mGraphPanel.DrawCommentDetails(tab)) {} // comment box selected (text, colour)
				else if (tab.SelectedNodes.Count > 1)
					DrawMultiSelectDetails(tab, mg);
				else
					DrawFunctionDetails(mg);
			}
			Gui.End();
		}

		/// The header strip at the top of Details: icon + title (+ subtitle), like UE.
		void DetailsHeader(StringView icon, uint32 iconColor, StringView title, StringView subtitle = default)
		{
			Gui.igIndent(10 * Look.Scale);
			let p = Gui.igGetCursorScreenPos();
			float fs = Gui.igGetFontSize();
			let dl = Gui.igGetWindowDrawList();
			Gui.DrawText(dl, .(p.x, p.y + 2 * Look.Scale), iconColor, icon, fs * 1.3f);
			Gui.igSetCursorScreenPos(.(p.x + fs * 1.8f, p.y));
			Gui.TextColored(Look.ForegroundHover, title);
			if (!subtitle.IsEmpty)
			{
				Gui.igSetCursorScreenPos(.(p.x + fs * 1.8f, Gui.igGetCursorScreenPos().y));
				Gui.TextColored(Look.ForegroundDim, subtitle);
			}
			Gui.igUnindent(10 * Look.Scale);
			Gui.igSpacing();
		}

		/// Cases of a Switch as a property list: match text per case, reorder, remove, add.
		void DrawSwitchDetails(MethodGraph mg, Node node, ref bool commit)
		{
			Pin remove = null;
			Pin move = null;
			int moveDelta = 0;
			int idx = 0;
			let types = TypeService.Current;
			String swType = scope .(NodeFactory.SwitchType(node));
			let swKind = PinValue.KindOf(swType, "", "", types);
			PropertyGrid.Row("Switch On", "What the switch looks at: a whole number, a character, text or any enum. Changing it keeps the cases that still fit");
			if (TypeButton("##swtype", swType, -1, .SwitchValue, null))
			{
				String why = scope .();
				BeginEdit();
				if (NodeFactory.SetSwitchType(mg.Graph, node, swType, types, why))
					commit = true;
				else
					Notify.Warn(why);
			}
			for (let p in node.Outputs)
			{
				if (p.Kind != .Exec || p.Name == "then")
					continue;
				Gui.PushID((int32)idx++);
				if (p.Name == "default")
				{
					PropertyGrid.Row("Default", "Taken when nothing else matches. Checked: 'default:' is written even with no body");
					bool explicitDefault = p.Optional;
					if (Gui.Checkbox("write when empty", &explicitDefault))
					{
						BeginEdit();
						p.Optional = explicitDefault;
						commit = true;
					}
				}
				else
				{
					String name = scope $"Case {idx}";
					if (NodeFactory.CaseFits(swKind, swType, p.Label, null) && !p.Label.Contains(',') && PinValueEditor.Handles(swKind))
					{
						PropertyGrid.Row(name, "What this case matches");
						if (mPropPinEditor.Draw(this, node, p.Id, swType, p.Label, false, swKind, Gui.igGetContentRegionAvail().x))
							commit = true;
					}
					else if (GridText(name, "##label", p.Label, "What this case matches: several values 2, 3  or  \"name\"  or  .EnumCase", true))
						commit = true;
					PropertyGrid.BeginRow();
					Gui.igTableSetColumnIndex(1);
					if (Gui.igArrowButton("##up", Dir.Up))
					{
						move = p;
						moveDelta = -1;
					}
					Gui.SameLine(0, 4);
					if (Gui.igArrowButton("##down", Dir.Down))
					{
						move = p;
						moveDelta = 1;
					}
					Gui.SameLine(0, 4);
					if (Gui.Button("X", .(Gui.igGetFrameHeight(), 0)))
						remove = p;
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Remove this case; nodes wired into it stay unconnected");
				}
				Gui.PopID();
			}
			PropertyGrid.WideRow();
			if (swKind == .Enum)
			{
				if (Gui.Button("Update members"))
				{
					String why = scope .();
					BeginEdit();
					if (NodeFactory.SetSwitchType(mg.Graph, node, swType, types, why))
						commit = true;
					else
						Notify.Warn(why);
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Adds a case for every member the enum has now and removes cases of members it no longer has");
				Gui.SameLine();
			}
			if (Gui.Button("+ Add Case"))
			{
				BeginEdit();
				String starter = scope .();
				if (swKind == .Enum)
				{
					List<String> ms = scope .();
					defer { ClearAndDeleteItems!(ms); }
					PinValue.Members(swType, types, ms);
					if (!ms.IsEmpty)
						starter.AppendF(".{}", ms[0]);
				}
				if (starter.IsEmpty)
					NodeFactory.DefaultCaseLabel(PinValueEditor.Handles(swKind) ? swKind : .Number, starter);
				NodeFactory.AddCase(mg.Graph, node, starter);
				commit = true;
			}
			if (move != null && NodeFactory.MoveCase(mg.Graph, node, move, moveDelta))
			{
				BeginEdit();
				commit = true;
			}
			if (remove != null)
			{
				BeginEdit();
				NodeFactory.RemoveCase(mg.Graph, node, remove);
				commit = true;
			}
		}

		/// Options of the flow macros: state field, polarity, number of outputs, action target.
		void DrawFlowDetails(MethodGraph mg, Node node, ref bool commit)
		{
			String summary = scope .();
			FlowMacros.GetSummary(node, summary);
			if (!summary.IsEmpty)
			{
				PropertyGrid.WideRow();
				Gui.igPushTextWrapPos(0);
				Gui.TextColored(Look.ForegroundDim, summary);
				Gui.igPopTextWrapPos();
			}
			let macro = node.Text;
			if (FlowMacros.IsStateful(macro))
			{
				PropertyGrid.Row("State Field", "Added to the class when the graph is written");
				PropertyGrid.Value(node.Text2.IsEmpty ? "(named when written)" : StringView(node.Text2));
			}
			if (macro == FlowMacros.Gate)
			{
				PropertyGrid.Row("Start Closed", "Whether the gate begins closed");
				bool closed = FlowMacros.GateStartsClosed(node);
				if (Gui.Checkbox("##gate", &closed))
				{
					BeginEdit();
					FlowMacros.SetGateStartClosed(node, closed);
					commit = true;
				}
			}
			if (macro == FlowMacros.MultiGate)
			{
				PropertyGrid.Row("Loop", "Start over after the last output");
				bool loop = node.Postfix;
				if (Gui.Checkbox("##loop", &loop))
				{
					BeginEdit();
					node.Postfix = loop;
					commit = true;
				}
			}
			if (macro == FlowMacros.Sequence || macro == FlowMacros.MultiGate)
			{
				PropertyGrid.WideRow();
				if (Gui.Button("+ Add Output"))
				{
					BeginEdit();
					FlowMacros.AddArm(mg.Graph, node);
					commit = true;
				}
				Gui.SameLine();
				if (Gui.Button("- Remove Last") && FlowMacros.ArmCount(node) > 1)
				{
					BeginEdit();
					FlowMacros.RemoveArm(mg.Graph, node);
					commit = true;
				}
			}
			if (FlowMacros.IsAction(macro))
			{
				let target = FlowMacros.TargetMacro(macro);
				List<String> names = scope .();
				defer { ClearAndDeleteItems!(names); }
				for (let o in mg.Graph.Nodes)
				{
					if (o.Kind != .Flow || o.Text != target || o.Text2.IsEmpty)
						continue;
					bool have = false;
					for (let s in names)
						if (s == o.Text2)
							have = true;
					if (!have)
						names.Add(new String(o.Text2));
				}
				HashSet<String> fields = scope .();
				defer { for (let s in fields) delete s; }
				mg.Doc.GetOwnerFieldNames(mg, fields);
				for (let f in fields)
				{
					if (FlowMacros.MacroOfField(f) != target)
						continue;
					bool have = false;
					for (let s in names)
						if (s == f)
							have = true;
					if (!have)
						names.Add(new String(f));
				}
				PropertyGrid.Row("Acts On", "The stateful node this node controls");
				if (Gui.igBeginCombo("##flowtarget", scope String(node.Text2.IsEmpty ? "(choose)" : StringView(node.Text2)), 0))
				{
					for (let s in names)
					{
						Gui.PushID((int32)@s.Index);
						if (Gui.Selectable(s, s == node.Text2))
						{
							BeginEdit();
							node.Text2.Set(s);
							commit = true;
						}
						Gui.PopID();
					}
					Gui.igEndCombo();
				}
			}
		}

		/// A combo of fixed keyword choices plus "custom" (a text field), for Node.Alloc.
		bool AllocCombo(Node node, StringView id, Span<StringView> choices, Span<StringView> labels, StringView customPrefix)
		{
			if (node.Alloc == null)
				node.Alloc = new String(choices[0]);
			bool changed = false;
			int current = -1;
			for (int i < choices.Length)
				if (node.Alloc == choices[i])
					current = i;
			String shown = scope .((current >= 0) ? labels[current] : StringView(node.Alloc));
			// The closed box shows the full label when it fits and the bare keyword when it does not
			// (the open list is as wide as its longest entry); the full label is the tooltip then.
			bool shortened = false;
			if (current >= 0 && Gui.CalcTextSize(shown).x + Gui.igGetFrameHeight() + 20 * Look.Scale > Gui.igGetContentRegionAvail().x)
			{
				shown.Set(choices[current]);
				shortened = true;
			}
			bool open = Gui.igBeginCombo(scope String(id), shown, 0);
			if (shortened && !open && Gui.igIsItemHovered(0))
				Gui.Tooltip(labels[current]);
			if (open)
			{
				for (int i < choices.Length)
				{
					if (Gui.Selectable(labels[i], i == current) && i != current)
					{
						BeginEdit();
						node.Alloc.Set(choices[i]);
						changed = true;
					}
				}
				if (Gui.Selectable(scope $"{customPrefix}<name>  (custom)", current < 0) && current >= 0)
				{
					BeginEdit();
					node.Alloc.Set(customPrefix);
					node.Alloc.Append("alloc");
					changed = true;
				}
				Gui.igEndCombo();
			}
			if (current < 0 && GridText("Custom", scope String(id)..Append("c"), node.Alloc, "The keyword exactly as written, e.g. new:gAlloc or defer:mixin", true))
				changed = true;
			return changed;
		}

		/// The constructors of a Construct's project class ("(int start)"); picking one gives the
		/// node one input per parameter. The current choice is the one whose types the inputs have.
		void DrawConstructorChoice(Graph g, Node node, ref bool commit)
		{
			let st = (Index != null && !node.Text.IsEmpty && node.Text != "." && node.Text != "(.)") ? Index.FindType(node.Text) : null;
			if (st == null)
				return;
			List<SymbolMethod> ctors = scope .();
			for (let m in st.Methods)
				if (m.IsCtor && !m.IsStatic)
					ctors.Add(m);
			if (ctors.IsEmpty)
				return;
			String current = scope .("(choose)");
			SymbolMethod currentCtor = null;
			for (let m in ctors)
			{
				if (m.ParamNames.Count != node.ArgCount)
					continue;
				bool same = true;
				for (int i < m.ParamTypes.Count)
				{
					let p = node.FindInput(scope $"arg{i}");
					if (p == null || (!p.TypeName.IsEmpty && p.TypeName != m.ParamTypes[i]))
						same = false;
				}
				if (same)
				{
					currentCtor = m;
					current.Set(scope $"({m.ParamsText})");
					break;
				}
			}
			PropertyGrid.Row("Constructor", scope $"Which constructor of {st.Name} makes the object; its inputs become the node's inputs");
			Gui.igSetNextItemWidth(-1);
			if (Gui.igBeginCombo("##cctor", current, 0))
			{
				for (let m in ctors)
				{
					if (Gui.Selectable(scope $"({m.ParamsText})##{@m.Index}", m == currentCtor) && m != currentCtor)
					{
						BeginEdit();
						ChooseConstructor(g, node, m);
						commit = true;
					}
				}
				Gui.igEndCombo();
			}
		}

		/// Replaces a Construct's inputs with one per parameter of `ctor` (defaults as written).
		public void ChooseConstructor(Graph g, Node node, SymbolMethod ctor)
		{
			while (node.ArgCount > 0)
				NodeFactory.RemoveLastArgument(g, node);
			for (int i < ctor.ParamNames.Count)
			{
				let p = NodeFactory.AddArgument(g, node);
				p.Label.Set(ctor.ParamNames[i]);
				if (i < ctor.ParamTypes.Count)
					p.TypeName.Set(ctor.ParamTypes[i]);
				if (i < ctor.ParamDefaults.Count && !ctor.ParamDefaults[i].IsEmpty)
					p.Default.Set(ctor.ParamDefaults[i]);
			}
		}

		/// Construct / Delete / Defer / Using / Result (docs/Lifetime-Nodes.md).
		void DrawLifetimeDetails(MethodGraph mg, Node node, ref bool commit)
		{
			let g = mg.Graph;
			switch (node.Kind)
			{
			case .Construct:
				PropertyGrid.Row("Allocation", "new: you delete it. scope: freed when the block ends. scope::: freed when the method returns. new:<allocator>: a custom allocator.");
				StringView[4] choices = .("new", "scope", "scope::", "append");
				StringView[4] labels = .("new  (you delete it)", "scope  (freed when the block ends)", "scope::  (freed when the method returns)", "append  (in a constructor)");
				if (AllocCombo(node, "##alloc", choices, labels, "new:"))
					commit = true;
				if (node.Text != "$")
				{
					PropertyGrid.Row("Type", "The type to make; `.` takes it from where the value goes", Theme.TypeColor(node.Text));
					if (NodeTypeButton("##ctype", node.Text, .Construct, mg.Method))
					{
						if (node.Result != null)
						{
							node.Result.TypeName.Clear();
							NodeFactory.ConstructResultType(node.Text, node.IsArray, node.Result.TypeName);
						}
						commit = true;
					}
					PropertyGrid.Row("Array  (T[n])", "Make an array of Count elements instead of calling a constructor");
					bool arr = node.IsArray;
					if (Gui.Checkbox("##carr", &arr))
					{
						BeginEdit();
						while (node.ArgCount > 0)
							NodeFactory.RemoveLastArgument(g, node);
						node.IsArray = arr;
						if (arr)
						{
							let p = g.AddDataIn(node, "arg0", "Count");
							p.TypeName.Set("int");
							p.Default.Set("1");
						}
						if (node.Result != null)
						{
							node.Result.TypeName.Clear();
							NodeFactory.ConstructResultType(node.Text, node.IsArray, node.Result.TypeName);
						}
						commit = true;
					}
					if (!node.IsArray)
						DrawConstructorChoice(g, node, ref commit);
					if (!node.IsArray)
					{
						PropertyGrid.WideRow();
						if (Gui.Button("+ Add Argument"))
						{
							BeginEdit();
							NodeFactory.AddArgument(g, node);
							commit = true;
						}
						Gui.SameLine();
						if (Gui.Button("- Remove Last") && node.ArgCount > 0)
						{
							BeginEdit();
							NodeFactory.RemoveLastArgument(g, node);
							commit = true;
						}
					}
				}
			case .Delete:
				StringView[1] choices = .("delete");
				StringView[1] labels = .("delete");
				PropertyGrid.Row("Keyword", "delete, or delete:<allocator> for an object made with new:<allocator>");
				if (AllocCombo(node, "##dalloc", choices, labels, "delete:"))
					commit = true;
			case .Defer:
				StringView[2] choices = .("defer", "defer::");
				StringView[2] labels = .("defer  (end of this block)", "defer::  (when the method returns)");
				PropertyGrid.Row("Runs", "When Deferred runs. Several Defers in one block run last-first.");
				if (AllocCombo(node, "##defer", choices, labels, "defer:"))
					commit = true;
			case .Using:
				PropertyGrid.Row("Declare a variable", "using (let name = Value): the value can be read in Body through the variable pin");
				bool decl = node.FindOutput("variable") != null;
				if (Gui.Checkbox("##udecl", &decl))
				{
					BeginEdit();
					if (decl)
					{
						String name = scope .();
						GraphPanel.UniqueLocalName(mg, "scope", name);
						node.Text.Set(name);
						node.Text2.Set("let");
						g.AddDataOut(node, "variable", name);
					}
					else
					{
						let v = node.FindOutput("variable");
						if (v != null)
							g.RemovePin(v);
						node.Text.Clear();
						node.Text2.Clear();
					}
					commit = true;
				}
				if (node.FindOutput("variable") != null)
				{
					if (GridText("Variable Name", "##uname", node.Text))
					{
						node.FindOutput("variable").Label.Set(node.Text);
						commit = true;
					}
					PropertyGrid.Row("Variable Type", "let / var or a type", Theme.TypeColor(node.Text2));
					if (NodeTypeButton("##utype", node.Text2, .Local, mg.Method)) commit = true;
				}
			case .ResultMatch:
				PropertyGrid.Row("Test for", "Ok: `if (r case .Ok(let value))`, the if-arm is Ok. Err: `if (r case .Err)`, the if-arm is Err.");
				bool ok = node.Text != "Err";
				if (Gui.igBeginCombo("##rcase", ok ? "Ok" : "Err", 0))
				{
					if (Gui.Selectable("Ok", ok) && !ok)
					{
						BeginEdit();
						NodeFactory.SetResultCase(g, node, true);
						commit = true;
					}
					if (Gui.Selectable("Err", !ok) && ok)
					{
						BeginEdit();
						NodeFactory.SetResultCase(g, node, false);
						commit = true;
					}
					Gui.igEndCombo();
				}
				let p = node.FindOutput("payload");
				if (p != null)
				{
					PropertyGrid.Row(ok ? "Value" : "Error", "The bound value: written `let name` when something reads the pin", Theme.TypeColor(p.TypeName));
					String v = scope .();
					if (p.Form == .Inline && p.OutName != null)
						v.AppendF("case .{}({} {})", node.Text, (p.OutDecl == "var") ? "var" : "let", p.OutName);
					else
						v.AppendF("case .{}  (nothing reads it)", node.Text);
					PropertyGrid.Value(v);
				}
			case .Lambda:
				PropertyGrid.Row("Allocation", "scope: freed when the block ends (a callback used right away). new: you delete it (an event handler, a thread). none: a function pointer, or a delegate the callee keeps.");
				StringView[3] choices = .("scope", "new", "");
				StringView[3] labels = .("scope  (freed when the block ends)", "new  (you delete it)", "none");
				if (AllocCombo(node, "##lalloc", choices, labels, "new:"))
					commit = true;
				if (node.Text.IsEmpty)
				{
					if (GridText("Function", "##lfn", node.Text2, "The function the delegate calls (`=> Name`)"))
						commit = true;
				}
				else
				{
					if (GridText("Parameters", "##lparams", node.Text, "As written: (a, b), (int x), x", true))
					{
						NodeFactory.SyncParams(g, node);
						commit = true;
					}
					String caps = scope .(node.Attributes ?? "");
					if (GridText("Capture", "##lcap", caps, "[&] captures the locals it reads by reference, [=] by value; empty: the Beef default", true))
					{
						caps.Trim();
						if (caps.IsEmpty)
							DeleteAndNullify!(node.Attributes);
						else
							Graph.CopyStr(ref node.Attributes, caps);
						commit = true;
					}
					PropertyGrid.Row("Captures", "The locals and parameters of this function the lambda reads");
					List<String> names = scope .();
					defer { ClearAndDeleteItems!(names); }
					g.GetCaptures(node, names);
					String list = scope .();
					for (let s in names)
						list.AppendF("{}{}", (@s.Index > 0) ? ", " : "", s);
					PropertyGrid.Value(list.IsEmpty ? "(nothing)" : list);
				}
			case .LocalFunc:
				if (GridText("Declaration", "##lfhdr", node.Text2, "Return type, name and parameters: int Twice(int x)", true))
				{
					NodeFactory.SyncParams(g, node);
					commit = true;
				}
			case .Format:
				if (GridText("Text", "##fmt", node.Text, "The interpolated string with empty holes: $\"x = {}, hex {:X2}\". Each {} is an input.", true))
				{
					NodeFactory.SyncHoles(g, node);
					commit = true;
				}
			case .Scope:
				String attrs = scope .(node.Attributes ?? "");
				attrs.Trim();
				if (GridText("Attributes", "##sattr", attrs, "Written before the block, e.g. [ConstSkip] or [IgnoreErrors]", true))
				{
					if (attrs.IsEmpty)
						DeleteAndNullify!(node.Attributes);
					else
						Graph.CopyStr(ref node.Attributes, scope String(attrs)..Append(' '));
					commit = true;
				}
			default:
			}
			let err = g.FindError(node.Id);
			let warn = (err == null) ? g.FindWarning(node.Id) : null;
			if (err != null || warn != null)
			{
				PropertyGrid.WideRow();
				Gui.igPushTextWrapPos(0);
				if (err != null)
					Gui.TextColored(Gui.Color(255, 110, 110), scope $"Error: {err}");
				else
					Gui.TextColored(Theme.Warning, scope $"Warning: {warn}");
				Gui.igPopTextWrapPos();
			}
		}

		void DrawNodeDetails(MethodGraph mg, Node node)
		{
			String title = scope .();
			node.GetTitle(title);
			String kind = scope .();
			// Readable subtitle, not the raw kind name: "Local declaration", "Result Match", "Loop Break", ...
			if (node.Kind == .Call)
				kind.Set(node.IsPure ? "Value call" : "Function Call");
			else if (node.Kind == .LocalVar)
				kind.Set("Local declaration");
			else if (node.Kind == .MathExpr)
				kind.Set("Math Expression");
			else
			{
				String raw = scope .();
				raw.AppendF("{}", node.Kind);
				for (let c in raw.RawChars)
				{
					if (c.IsUpper && !kind.IsEmpty)
						kind.Append(' ');
					kind.Append(c);
				}
			}
			DetailsHeader(node.IsPure ? Icon.Function : Icon.Box, Theme.HeaderColor(node) | 0xFF000000, title, kind);
			bool commit = false;
			bool edited = false;

			if (PropertyGrid.Begin("##nodegrid"))
			{
				if (node.Kind != .Switch && node.Kind != .Flow && PropertyGrid.Category("Node", true))
				{
					switch (node.Kind)
					{
					case .Call:
						if (GridText("Function", "##fn", node.Text, "The function this node calls")) commit = true;
						PropertyGrid.Row("Null-conditional (?.)", "Call with ?. so a null receiver skips the call");
						if (Gui.Checkbox("##nc", &node.NullCond)) edited = true;
					case .Get:
						if (GridText("Name", "##name", node.Text, "Variable or member read by this node")) commit = true;
					case .Set:
						if (GridText("Operator", "##op", node.Text, "=, +=, -=, *=, /=, ++, --")) commit = true;
					case .LocalVar:
						if (GridText("Variable Name", "##vn", node.Text)) commit = true;
						PropertyGrid.Row("Rename", "Renames the local and every use of it in this function (with a preview)");
						if (Gui.Button(scope $"{Icon.Pencil}  Rename with Uses...", .(-1, 0)))
						{
							mRenameLocalOld.Set(node.Text);
							mRenameLocalKey.Set(mg.Key);
							mNameBuf.Set(node.Text);
							mOpenRenameLocal = true;
						}
						PropertyGrid.Row("Variable Type", "let / var or a type", Theme.TypeColor(node.Text2));
						if (NodeTypeButton("##vt", node.Text2, .Local, mg.Method)) commit = true;
						PropertyGrid.Row("Modifier", "const: a fixed value known when compiling. ref: another name for an existing variable (the value is `ref x`).");
						StringView mod = (node.Alloc != null) ? (StringView)node.Alloc : "";
						if (Gui.igBeginCombo("##vmod", scope String(mod.IsEmpty ? "(none)" : mod), 0))
						{
							for (let choice in StringView[?]("", "const", "ref"))
							{
								if (Gui.Selectable(choice.IsEmpty ? "(none)" : choice, choice == mod) && choice != mod)
								{
									BeginEdit();
									if (choice.IsEmpty)
										DeleteAndNullify!(node.Alloc);
									else
										Graph.CopyStr(ref node.Alloc, scope String(choice));
									commit = true;
								}
							}
							Gui.igEndCombo();
						}
						DrawLocalInitRows(mg, node, ref commit);
						if (!commit && mg.Graph.CanBeLocal(node, let construct))
						{
							PropertyGrid.WideRow();
							Gui.igPushTextWrapPos(0);
							Gui.TextColored(Theme.TextDim, "Declared in the middle of the function. Move to Local Variables declares it at the top instead (Outline > Local Variables): it then exists from the start, and its value is set there, before the statements above this node run. That can change what the program does, so it is only done when you ask.");
							Gui.igPopTextWrapPos();
							PropertyGrid.WideRow();
							if (Gui.Button(scope $"{Icon.ArrowUp}  Move to Local Variables", .(-1, 0)))
							{
								BeginEdit();
								if (mg.Graph.MoveToLocals(node))
								{
									CurrentTab?.ClearSelection();
									CommitCurrent();
									PropertyGrid.End();
									return;
								}
							}
						}
					case .ForEach:
						if (GridText("Element Name", "##en", node.Text)) commit = true;
						PropertyGrid.Row("Element Type", "let / var or a type", Theme.TypeColor(node.Text2));
						if (NodeTypeButton("##et", node.Text2, .ForEach, mg.Method)) commit = true;
					case .For:
						if (node.IsCountingLoop)
						{
							// A counting loop: the counter's name and type; Start and Count are pins.
							mFocusCodeField = false;
							if (GridText("Counter Name", "##cn", node.Text, "The name of the counter inside the loop (its output pin)")) commit = true;
							PropertyGrid.Row("Counter Type", "A whole-number type: the counter goes from Start up to (not including) Count", Theme.TypeColor(node.Text2));
							if (Gui.igBeginCombo("##ctype", scope String(node.Text2.IsEmpty ? "int" : node.Text2), 0))
							{
								for (let choice in StringView[?]("int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "intptr", "uintptr"))
								{
									if (Gui.Selectable(scope String(choice), choice == node.Text2) && choice != node.Text2)
									{
										BeginEdit();
										node.Text2.Set(choice);
										for (let p in node.Inputs)
											if (p.Kind == .Data)
												p.TypeName.Set(choice);
										node.FindOutput("counter").TypeName.Set(choice);
										commit = true;
									}
								}
								Gui.igEndCombo();
							}
						}
						else
						{
							if (mFocusCodeField) { Gui.igSetKeyboardFocusHere(1); mFocusCodeField = false; }
							if (GridText("Loop Header", "##hdr", node.Text, "init; condition; step   or   int i < count", true)) commit = true;
						}
					case .Operator:
						if (GridText("Operator", "##op", node.Text)) commit = true;
					case .Cast:
						PropertyGrid.Row("Cast To", "Type to cast to", Theme.TypeColor(node.Text));
						if (NodeTypeButton("##ct", node.Text, .Cast, mg.Method)) commit = true;
					case .MathExpr:
						DrawMathDetails(mg, node, ref commit);
					case .Code, .Expr, .Switch, .Flow:
					default:
						PropertyGrid.Row("Kind");
						PropertyGrid.Value(kind);
					}
				}
				if (node.Kind == .Switch && PropertyGrid.Category("Cases", true))
					DrawSwitchDetails(mg, node, ref commit);
				if (node.Kind == .Flow && PropertyGrid.Category("Flow", true))
					DrawFlowDetails(mg, node, ref commit);
				if ((node.Kind == .Construct || node.Kind == .Delete || node.Kind == .Defer || node.Kind == .Using || node.Kind == .ResultMatch) &&
					PropertyGrid.Category("Lifetime", true))
					DrawLifetimeDetails(mg, node, ref commit);
				// An ambiguous call: the overloads that fit equally well; picking one writes a cast.
				if (node.Kind == .Call && node.Overloads != null && node.Overloads.Count > 1 && PropertyGrid.Category("Overloads", true))
				{
					PropertyGrid.WideRow();
					Gui.igPushTextWrapPos(0);
					Gui.TextColored(node.Ambiguous ? Theme.Warning : Look.ForegroundDim, node.Ambiguous ?
						"Several overloads fit these arguments equally well. Pick the one to call: a Cast is put on the argument that tells them apart." :
						"Overloads that fit equally well when the call was read; the first is the one it calls now.");
					Gui.igPopTextWrapPos();
					String pick = null;
					for (let s in node.Overloads)
					{
						PropertyGrid.WideRow();
						if (Gui.Selectable(scope $"{Icon.Function}  {s}##ovl{@s.Index}", !node.Ambiguous && @s.Index == 0))
							pick = s;
					}
					if (pick != null && (node.Ambiguous || pick != node.Overloads[0]))
					{
						BeginEdit();
						String why = scope .();
						String sig = scope .(pick);
						if (NodeFactory.PickOverload(mg.Graph, node, sig, why))
							commit = true;
						else
							SetStatus(why, .Warning);
					}
				}
				if ((node.Kind == .Lambda || node.Kind == .LocalFunc || node.Kind == .Format || node.Kind == .Scope) &&
					PropertyGrid.Category((node.Kind == .Format) ? "Text" : ((node.Kind == .Scope) ? "Block" : "Function"), true))
					DrawLifetimeDetails(mg, node, ref commit);


				// A Math Expression: its expression in a full-width field.
				if (node.Kind == .MathExpr && PropertyGrid.Category("Expression", true, Icon.Sigma))
					DrawMathExpression(mg, node, ref commit);

				// Beef code nodes: a full-width code editor.
				if (node.Kind == .Code || node.Kind == .Expr)
				{
					if (PropertyGrid.Category("Beef Code", true, Icon.Code))
					{
						if (node.Kind == .Code && node.Reason != null)
						{
							PropertyGrid.WideRow();
							Gui.igPushTextWrapPos(0);
							Gui.TextColored(Look.ForegroundDim, scope $"Why this is code: {node.Reason}");
							Gui.igPopTextWrapPos();
						}
						PropertyGrid.WideRow();
						if (mFocusCodeField) { Gui.igSetKeyboardFocusHere(0); mFocusCodeField = false; }
						Gui.igPushItemWidth(-6 * Look.Scale);
						String codeBefore = scope .(node.Text);
						bool done = PropertyGrid.Multiline("##code", node.Text, 200 * Look.Scale, let changed, mMono);
						Gui.igPopItemWidth();
						if (changed && !mDetailsEditPushed) BeginEditBefore(node.Text, codeBefore);
						if (done) commit = true;
					}
				}

				// How the call binds (docs/Calls-and-Receivers.md), its out variables, and what the
				// validator says about it.
				if (node.Kind == .Call && PropertyGrid.Category("Call", true))
				{
					let g = mg.Graph;
					PropertyGrid.Row("Binding", "Static: no Receiver pin. Member: a Receiver pin of the owning type, unconnected = this. Unresolved: written as read, the compiler checks it.");
					switch (node.Binding)
					{
					case .Static: PropertyGrid.Value("Static function");
					case .Instance: PropertyGrid.Value("Member function");
					case .Unresolved: PropertyGrid.Value("Unresolved (written as typed)", Look.ForegroundDim);
					}
					if (node.Binding == .Static)
					{
						PropertyGrid.Row("Receiver is", "The type the static function belongs to; the qualifier is written as shown.");
						String q = scope .();
						if (node.Qualifier != null && !node.Qualifier.IsEmpty)
							q.AppendF("{}  (written {}.{})", node.OwnerType ?? node.Qualifier, node.Qualifier, node.Text);
						else
							q.AppendF("{}  (written {}(), no qualifier)", node.OwnerType ?? "?", node.Text);
						PropertyGrid.Value(q);
					}
					else if (node.Binding == .Instance)
					{
						let target = node.FindInput("target");
						PropertyGrid.Row("Receiver is", "Wire an object into the Receiver; unconnected means this.");
						String t = scope .();
						t.Append((node.OwnerType != null) ? (StringView)node.OwnerType : "(owner unknown)");
						if (target != null && g.FindLinkTo(target) == null && target.Default.IsEmpty)
							t.AppendF("  -  this ({}{})", g.SelfType.IsEmpty ? "no type" : (StringView)g.SelfType, g.StaticContext ? ", static: no this" : "");
						PropertyGrid.Value(t);
					}
					// The overload the node calls (an ambiguous call has its own Overloads section above).
					if (!node.Ambiguous && DrawOverloadChoice(mg, node))
						commit = true;
					for (let p in node.Outputs)
					{
						if (!p.IsOutArg)
							continue;
						Gui.PushID(p.Id);
						PropertyGrid.Row(scope $"out {p.Label}", "An out parameter: an output pin, and a variable in the code.", Theme.TypeColor(p.TypeName));
						String v = scope .();
						switch (p.Form)
						{
						case .Discard: v.Append("? (nothing reads it)");
						case .Inline: v.AppendF("{}{} {}", p.OutKeyword ? "out " : "", (p.OutDecl != null) ? (StringView)p.OutDecl : "var", p.OutName ?? "");
						case .Declared: v.AppendF("{} {}; then out {}", (p.OutDecl != null) ? (StringView)p.OutDecl : (StringView)p.TypeName, p.OutName ?? "", p.OutName ?? "");
						case .DeclaredRef: v.AppendF("{} {} = default; then ref {}", p.TypeName, p.OutName ?? "", p.OutName ?? "");
						case .Existing: v.AppendF("out {} (writes it)", p.OutName ?? "");
						}
						PropertyGrid.Value(v);
						Gui.PopID();
					}
					let err = g.FindError(node.Id);
					if (err != null)
					{
						PropertyGrid.WideRow();
						Gui.igPushTextWrapPos(0);
						Gui.TextColored(Gui.Color(255, 110, 110), scope $"Error: {err}");
						Gui.igPopTextWrapPos();
					}
					else
					{
						let warn = g.FindWarning(node.Id);
						if (warn != null)
						{
							PropertyGrid.WideRow();
							Gui.igPushTextWrapPos(0);
							Gui.TextColored(Theme.Warning, scope $"Warning: {warn}");
							Gui.igPopTextWrapPos();
						}
					}
				}

				// Pin defaults (UE's "Default Value" rows), one per unlinked data input.
				bool any = false;
				for (let p in node.Inputs)
					if (p.Kind == .Data && !mg.Graph.IsLinked(p))
						any = true;
				if (any && PropertyGrid.Category("Inputs", true))
				{
					for (let p in node.Inputs)
					{
						if (p.Kind != .Data || mg.Graph.IsLinked(p))
							continue;
						Gui.PushID(p.Id);
						String label = scope .(p.Label.IsEmpty ? p.Name : p.Label);
						if (label == "target")
							label.Set((node.Kind == .Set) ? "Variable" : "Receiver");
						if (p.IsRefArg)
							label.Insert(0, "ref ");
						String tip = scope .();
						tip.AppendF("{}  ({})", label, p.TypeName.IsEmpty ? "type unknown" : p.TypeName);
						PropertyGrid.Row(label, tip, Theme.TypeColor(p.TypeName));
						if (PinValueWidget(node, p))
						{
							// A typed value can choose another overload (a text typed into an Object pin).
							RefitCall(mg.Graph, node);
							commit = true;
						}
						Gui.PopID();
					}
				}

				// Linked inputs are shown read-only, so every pin is accounted for.
				bool anyLinked = false;
				for (let p in node.Inputs)
					if (p.Kind == .Data && mg.Graph.IsLinked(p))
						anyLinked = true;
				if (anyLinked && PropertyGrid.Category("Connected Inputs", false))
				{
					for (let p in node.Inputs)
					{
						if (p.Kind != .Data || !mg.Graph.IsLinked(p))
							continue;
						let src = mg.Graph.DataSource(p);
						String from = scope .();
						if (src != null)
							src.GetTitle(from);
						PropertyGrid.Row(p.Label.IsEmpty ? p.Name : p.Label, p.TypeName, Theme.TypeColor(p.TypeName));
						PropertyGrid.Value(scope $"{Icon.Link}  {from}");
					}
				}

				if (node.IsExecNode && PropertyGrid.Category("Comment", true, Icon.Comment))
				{
					if (node.LeadingComments == null)
						node.LeadingComments = new String();
					String commentText = scope .();
					// Show the comment without the // markers.
					for (let line in node.LeadingComments.Split('\n'))
					{
						var l = line;
						l.Trim();
						if (l.StartsWith("//"))
							l = l.Substring(2);
						l.TrimStart();
						if (!commentText.IsEmpty || !l.IsEmpty)
						{
							commentText.Append(l);
							commentText.Append('\n');
						}
					}
					while (commentText.EndsWith('\n'))
						commentText.RemoveFromEnd(1);
					PropertyGrid.WideRow();
					Gui.igPushItemWidth(-1);
					String commentBefore = scope .(commentText);
					bool done = PropertyGrid.Multiline("##comment", commentText, 60 * Look.Scale, let changed);
					Gui.igPopItemWidth();
					if (changed && !mDetailsEditPushed) BeginEditBefore(commentText, commentBefore);
					if (done)
					{
						node.LeadingComments.Clear();
						for (let line in commentText.Split('\n'))
						{
							var l = line;
							l.Trim();
							if (!l.IsEmpty)
								node.LeadingComments.AppendF("// {}\n", l);
						}
						if (node.LeadingComments.IsEmpty)
						{
							delete node.LeadingComments;
							node.LeadingComments = null;
						}
						node.Moved = true; // regenerate the comment lines
						commit = true;
					}
					else if (node.LeadingComments != null && node.LeadingComments.IsEmpty)
					{
						delete node.LeadingComments;
						node.LeadingComments = null;
					}
				}

				if (node.Original != null && !node.Edited && PropertyGrid.Category("Source", false, Icon.FileCode))
				{
					PropertyGrid.WideRow();
					if (mMono != null)
						Gui.igPushFont(mMono, 0);
					Gui.igPushTextWrapPos(0);
					Gui.TextColored(Theme.TextCode, node.Original);
					Gui.igPopTextWrapPos();
					if (mMono != null)
						Gui.igPopFont();
				}
				PropertyGrid.End();
			}

			if (commit || edited)
			{
				node.Edited = true;
				if (node.Kind == .LocalVar || node.Kind == .ForEach || node.IsCountingLoop)
				{
					let varPin = node.FindOutput((node.Kind == .LocalVar) ? "variable" : (node.Kind == .For) ? "counter" : "element");
					if (varPin != null)
						varPin.Label.Set(node.Text);
				}
				CommitCurrent();
			}
		}

		void DrawMultiSelectDetails(GraphTab tab, MethodGraph mg)
		{
			DetailsHeader(Icon.Layers, Look.AccentBlue, scope $"{tab.SelectedNodes.Count} nodes selected");
			if (PropertyGrid.Begin("##multigrid"))
			{
				if (PropertyGrid.Category("Selection", true))
				{
					for (let id in tab.SelectedNodes)
					{
						let n = mg.Graph.FindNode(id);
						if (n == null)
							continue;
						String t = scope .();
						n.GetTitle(t);
						PropertyGrid.Row(t);
						PropertyGrid.Value(scope $"{n.Kind}");
						if (@id.Index >= 30)
							break;
					}
				}
				if (PropertyGrid.Category("Alignment", true, Icon.AlignStartVertical))
				{
					PropertyGrid.WideRow();
					StringView[6] icons = .(Icon.AlignStartHorizontal, Icon.AlignEndHorizontal, Icon.AlignStartVertical, Icon.AlignEndVertical, Icon.AlignHorizontalDistributeCenter, Icon.AlignVerticalDistributeCenter);
					StringView[6] tips = .("Align Top (Shift+W)", "Align Bottom (Shift+S)", "Align Left (Shift+A)", "Align Right (Shift+D)", "Distribute Horizontally", "Distribute Vertically");
					AlignMode[6] modes = .(.Top, .Bottom, .Left, .Right, .DistributeH, .DistributeV);
					for (int i < 6)
					{
						if (i > 0)
							Gui.SameLine(0, 2);
						Gui.PushID((int32)i);
						if (Gui.Button(icons[i], .(Gui.igGetFrameHeight() * 1.4f, 0)))
							AlignSelection(tab, modes[i]);
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip(tips[i]);
						Gui.PopID();
					}
				}
				PropertyGrid.End();
			}
		}

		/// The Passing chooser of a parameter row (Properties > Inputs, the Add Function dialog):
		/// value, out, ref or in, only what Beef takes for that row (TypeSlotRules.PassingChoices).
		bool PassingCombo(StringView id, ParamRow r, float width)
		{
			bool changed = false;
			List<StringView> choices = scope .();
			VisualBeef.Catalog.TypeSlotRules.PassingChoices(r.Type, r.Default != null, r.Modifier, choices);
			Gui.igSetNextItemWidth(width);
			if (Gui.igBeginCombo(scope String(id), scope String(VisualBeef.Catalog.TypeSlotRules.PassingLabel(r.Modifier)), 0))
			{
				for (let choice in choices)
				{
					if (Gui.Selectable(scope String(VisualBeef.Catalog.TypeSlotRules.PassingLabel(choice)), choice == r.Modifier) && choice != r.Modifier)
					{
						r.Modifier.Set(choice);
						changed = true;
					}
					if (Gui.igIsItemHovered(0))
					{
						switch (choice)
						{
						case "": Gui.Tooltip("The function gets its own copy of the value.");
						case "out": Gui.Tooltip("The function sets it and the caller gets it back (an output pin on calls).");
						case "ref": Gui.Tooltip("The function works on the caller's own variable and can change it.");
						case "in": Gui.Tooltip("Read-only, passed without a copy. Callers pass a variable, not a typed value.");
						default:
						}
					}
				}
				Gui.igEndCombo();
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip((r.Default != null) ? "Passing: a parameter with a default value is passed by value" : "Passing: how the value goes into the function");
			return changed;
		}

		void SyncParamRows(MethodGraph mg)
		{
			let m = mg.Method;
			ClearAndDeleteItems!(mParamRows);
			for (let p in m.Params)
			{
				ParamRow r = new .();
				r.Modifier.Set(p.Modifier);
				r.Type.Set(p.Type);
				r.Name.Set(p.Name);
				if (p.Default != null)
					r.Default = new String(p.Default);
				mParamRows.Add(r);
			}
			mRetType.Set((m.TypeText != null) ? m.TypeText : "void");
			mFnNameEdit.Set(m.Name);
			// The file too: two files can hold the same Type.Method key.
			mParamRowsFor.Set(scope $"{mg.Doc.FilePath}|{mg.Key}");
			mParamRowsVersion = mg.Doc.Version;
		}

		void ParamsText(String outText)
		{
			for (let r in mParamRows)
			{
				if (r.Name.IsEmpty || r.Type.IsEmpty)
					continue;
				if (!outText.IsEmpty)
					outText.Append(", ");
				if (!r.Modifier.IsEmpty)
					outText.AppendF("{} ", r.Modifier);
				outText.AppendF("{} {}", r.Type, r.Name);
				if (r.Default != null)
					outText.AppendF(" = {}", r.Default);
			}
		}

		void DrawFunctionDetails(MethodGraph mg)
		{
			let m = mg.Method;
			if ((mParamRowsFor != scope $"{mg.Doc.FilePath}|{mg.Key}" || mParamRowsVersion != mg.Doc.Version) && !Gui.igIsAnyItemActive())
				SyncParamRows(mg);
			bool isOverride = Mods.Has(m.Modifiers, "override");
			StringView kindText = m.IsAccessor ? "Accessor" : (m.IsCtor ? (m.IsStatic ? "Static constructor" : "Constructor") : (m.IsDtor ? "Destructor" : (isOverride ? "Override" : "Function")));
			DetailsHeader(Icon.Function, isOverride ? Gui.Color(230, 90, 70) : Gui.Color(90, 150, 230), m.Name, (mg.Owner != null) ? scope $"{kindText} in {mg.Owner.Name}" : kindText);
			bool special = m.IsCtor || m.IsDtor || m.IsMixin || m.IsAccessor;
			bool sigDone = false;
			if (PropertyGrid.Begin("##fngrid"))
			{
				if (PropertyGrid.Category("Graph", true))
				{
					PropertyGrid.Row("Name", special ? "Constructors, destructors, accessors and mixins keep their name" : "Renames the function and every call to it in the project (with a preview)");
					Gui.igBeginDisabled(special);
					bool nameDone = PropertyGrid.Text("##fnname", mFnNameEdit, ?);
					Gui.igEndDisabled();
					if (nameDone && mFnNameEdit != m.Name && !mFnNameEdit.IsEmpty)
					{
						String newName = scope .(mFnNameEdit);
						mFnNameEdit.Set(m.Name);
						if (mg.Owner != null)
							StartProjectRename(.Member, m.Name, newName, mg.Owner.Name, mg.Key, mg.Doc.FilePath);
						else
						{
							String key = scope .(mg.Key);
							mg.Doc.RenameMember(m, newName);
							RetargetTab(key, newName);
							PropertyGrid.End();
							return; // m / mg belong to the old parse and are gone now
						}
					}
					if (DrawFunctionClassOptions(mg))
					{
						PropertyGrid.End();
						return; // the document changed: m / mg are gone
					}
				}
				if (DrawMemberAttributes(mg.Doc, m))
				{
					PropertyGrid.End();
					return;
				}
				if (!m.IsAccessor && PropertyGrid.Category("Inputs", true))
				{
					int removeAt = -1;
					for (let r in mParamRows)
					{
						if (r.Modifier == "out" && !m.IsCtor)
							continue; // an output: Properties > Outputs
						Gui.PushID((int32)@r.Index);
						PropertyGrid.BeginRow();
						Gui.igIndent(14 * Look.Scale);
						Gui.igSetNextItemWidth(-1);
						if (@r.Index == mFocusParamRow)
						{
							Gui.igSetKeyboardFocusHere(0);
							mFocusParamRow = -1;
						}
						bool nameDone = PropertyGrid.Text("##pn", r.Name, ?, false, null, "name");
						Gui.igUnindent(14 * Look.Scale);
						if (nameDone)
							sigDone = true;
						Gui.igTableSetColumnIndex(1);
						float x = Gui.igGetFrameHeight();
						// One line when the type picker keeps room for a type name next to Passing and the remove
						// button; otherwise Passing and remove stay on the first line and the picker takes a whole
						// line of its own below (a long type name is never squeezed to its pill).
						bool stacked = Gui.igGetContentRegionAvail().x - 62 * Look.Scale - 2 * (x + 14 * Look.Scale) < 110 * Look.Scale;
						if (PassingCombo("##pm", r, 62 * Look.Scale))
							sigDone = true;
						Gui.SameLine(0, 4 * Look.Scale);
						if (!stacked)
						{
							if (TypeButton("##pt", r.Type, Gui.igGetContentRegionAvail().x - x - 10 * Look.Scale, .Param, m))
								sigDone = true;
							TypeErrorText(r.Type, .Param, m);
							Gui.SameLine(0, 4 * Look.Scale);
						}
						else
							Gui.igSetCursorPosX(Gui.igGetCursorPosX() + Math.Max(0, Gui.igGetContentRegionAvail().x - x - 10 * Look.Scale));
						if (Gui.Button(Icon.X, .(x, x)))
							removeAt = @r.Index;
						if (Gui.igIsItemHovered(0))
							Gui.Tooltip("Remove this parameter");
						if (stacked)
						{
							if (TypeButton("##pt", r.Type, -1, .Param, m))
								sigDone = true;
							TypeErrorText(r.Type, .Param, m);
						}
						Gui.PopID();
					}
					PropertyGrid.WideRow();
					Gui.igBeginDisabled(special && m.IsDtor);
					if (Gui.Button(scope $"{Icon.Plus}  Add Input"))
					{
						ParamRow r = new .();
						r.Type.Set("int");
						String name = scope .("newParam");
						int n = 1;
						bool clash = true;
						while (clash)
						{
							clash = false;
							for (let o in mParamRows)
								if (o.Name == name)
									clash = true;
							if (clash)
							{
								name.Clear();
								name.AppendF("newParam{}", ++n);
							}
						}
						r.Name.Set(name);
						mParamRows.Add(r);
						mFocusParamRow = mParamRows.Count - 1;
						sigDone = true;
					}
					Gui.igEndDisabled();
					if (removeAt >= 0)
					{
						delete mParamRows[removeAt];
						mParamRows.RemoveAt(removeAt);
						sigDone = true;
					}
				}
				if (!m.IsCtor && !m.IsDtor && !m.IsAccessor && PropertyGrid.Category("Outputs", true))
				{
					PropertyGrid.Row("Return Value", "The value the function returns (void = none)", Theme.TypeColor(mRetType));
					if (TypeButton("##ret", mRetType, -1, .Return, m))
						sigDone = true;
					TypeErrorText(mRetType, .Return, m);
					DrawOutputRows(mg, ref sigDone);
				}
				PropertyGrid.End();
			}
			if (sigDone && ApplyParamRows(mg))
				return; // m / mg belong to the old parse and are gone now
			Gui.igSpacing();
			Gui.igIndent(10 * Look.Scale);
			Gui.TextWrappedDim("Select a node to edit it. Right-click the graph to add nodes; drag pins to connect them.");
			Gui.igUnindent(10 * Look.Scale);
		}

		/// Writes the Inputs / Outputs rows (mParamRows, mRetType) as the function's signature: one
		/// parameter renamed goes through the rename preview (its uses too). The Sheet stays on the
		/// function (its tab follows the new key). True when the document changed (or a rename started).
		public bool ApplyParamRows(MethodGraph mg)
		{
			let m = mg.Method;
			if (mg.Owner != null && mParamRows.Count == m.Params.Count)
			{
				// Only one parameter's name changed: rename it with its uses in the body.
				int renamed = -1;
				bool other = false;
				for (int i < m.Params.Count)
				{
					let r = mParamRows[i];
					let p = m.Params[i];
					if (r.Type != p.Type || r.Modifier != p.Modifier)
						other = true;
					else if (r.Name != p.Name)
					{
						if (renamed >= 0)
							other = true;
						renamed = i;
					}
				}
				if (renamed >= 0 && !other && !mParamRows[renamed].Name.IsEmpty)
				{
					String newName = scope .(mParamRows[renamed].Name);
					mParamRows[renamed].Name.Set(m.Params[renamed].Name);
					StartProjectRename(.Parameter, m.Params[renamed].Name, newName, mg.Owner.Name, mg.Key, mg.Doc.FilePath);
					return true;
				}
			}
			{
				String pars = scope .();
				ParamsText(pars);
				String ret = scope .(mRetType);
				if (m.IsCtor || m.IsDtor)
					ret.Set((m.TypeText != null) ? m.TypeText : "");
				String name = scope .(m.Name);
				String key = scope .(mg.Key);
				let doc = mg.Doc;
				if (!ApplySignature(doc, m, ret, pars))
				{
					mFocusParamRow = -1;
					return false; // not a valid signature: nothing written, the rows keep what was typed
				}
				mParamRowsVersion = -1;
				if (!doc.LastSignatureKey.IsEmpty)
					RetargetTabToKey(doc, key, doc.LastSignatureKey);
				else
					RetargetTab(key, name);
				return true; // m / mg belong to the old parse and are gone now
			}
		}

		/// Details for a variable picked in Outline. Returns false when the variable no
		/// longer exists (the panel then shows the graph selection as usual).
		bool DrawVariableDetails()
		{
			if (Doc.Unit == null)
				return false;
			let type = FindTypeMember(Doc, mSelVarType);
			let field = FindField(type, mSelVarName);
			if (field == null)
			{
				mSelVarActive = false;
				return false;
			}
			String key = scope .();
			key.AppendF("{}|{}|{}", Doc.FilePath, mSelVarType, mSelVarName);
			if ((key != mSelVarSyncKey || mSelVarSyncVersion != Doc.Version) && !Gui.igIsAnyItemActive())
			{
				mSelVarSyncKey.Set(key);
				mSelVarSyncVersion = Doc.Version;
				mVarNameBuf.Set(field.Name);
				mVarTypeBuf.Set((field.TypeText != null) ? field.TypeText : "");
			}
			String typeText = scope .((field.TypeText != null) ? field.TypeText : "");
			DetailsHeader(Icon.Variable, Theme.TypeColor(typeText), field.Name, (field.Kind == .Property) ? scope $"Property in {mSelVarType}" : scope $"Variable in {mSelVarType}");
			bool result = true;
			if (PropertyGrid.Begin("##vargrid"))
			{
				if (PropertyGrid.Category("Variable", true))
				{
					PropertyGrid.Row("Variable Name", "Renames the variable and every use of it in the project (with a preview)");
					String name = scope .(mVarNameBuf.View);
					if (PropertyGrid.Text("##varname", name, let changed))
					{
						name.Trim();
						String err = scope .();
						if (name != field.Name && ValidateIdentifier(name, err))
						{
							StartProjectRename(.Member, field.Name, name, mSelVarType, "", Doc.FilePath);
							mVarNameBuf.Set(field.Name);
							PropertyGrid.End();
							return true;
						}
						if (!err.IsEmpty)
							Notify.Warn(err);
					}
					if (changed)
						mVarNameBuf.Set(name);
					PropertyGrid.Row("Variable Type", "Pick a type (with container) or type one", Theme.TypeColor(typeText));
					if (TypeButton("##vartype", typeText, -1, .Member, field) && !typeText.IsEmpty && typeText != field.TypeText)
					{
						ApplyVariableType(Doc, field, typeText);
						UpdateTitle();
						PropertyGrid.End();
						return true;
					}
					TypeErrorText(typeText, .Member, field);
					if (DrawVariableClassOptions(Doc, type, field))
					{
						UpdateTitle();
						PropertyGrid.End();
						return true;
					}
					PropertyGrid.Row("Owner");
					PropertyGrid.Value(mSelVarType);
				}
				if (DrawMemberAttributes(Doc, field))
				{
					PropertyGrid.End();
					return true;
				}
				if (PropertyGrid.Category("Nodes", true))
				{
					PropertyGrid.WideRow();
					Gui.igPushStyleColor_U32(Col.Button, Gui.Color(120, 30, 30));
					Gui.igPushStyleColor_U32(Col.ButtonHovered, Gui.Color(160, 40, 40));
					if (Gui.Button(scope $"{Icon.Trash2}  Delete Variable"))
					{
						Doc.DeleteMember(field);
						mSelVarActive = false;
						UpdateTitle();
						result = true;
					}
					Gui.igPopStyleColor(2);
				}
				PropertyGrid.End();
			}
			return result;
		}
	}
}
