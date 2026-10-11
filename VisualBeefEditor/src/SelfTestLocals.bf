using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=fnlocals` (an empty scratch folder as the project): the owner's 2026-10-12
	/// requests through the calls the UI makes. Properties > Inputs > Add Input / remove keep the
	/// Sheet and Properties on the function (the new row focused); Properties > Outputs with two
	/// outputs and the Return writing them; Locals added with L, renamed, a String made here;
	/// Get / Set of a Local from the Node menu (no Local Variable node offered); the pin menu's
	/// Make variable / Make local variable / Make variable (Get), each one undo step; Save All and
	/// a Release compile; close / reopen byte for byte. Captures `fn-outputs`, `fn-locals`,
	/// `outline-locals` (VB_SHOTS).
	extension EditorApp
	{
		int mLcStep;
		int mLcWait;
		String mLcSrc = new .() ~ delete _;
		String mLcBefore = new .() ~ delete _;
		String mLcVar = new .() ~ delete _;
		int mLcTabIndex = -1;
		int32 mLcCallId;

		[CLink] static extern void igClearActiveID();

		SourceDocument LcDoc() => OpenFile(scope $"{mLcSrc}{Path.DirectorySeparatorChar}Shop.bf", false);

		MethodGraph LcMethod(StringView name)
		{
			let doc = LcDoc();
			if (doc == null)
				return null;
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == name)
					return mg;
			return null;
		}

		MethodGraph LcOpen(StringView name)
		{
			let mg = LcMethod(name);
			if (mg != null)
				OpenTab(mg);
			return mg;
		}

		void LcNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[FNLOCALS] {text}");

		/// The Sheet in front is `name`'s, and Properties shows that function (no node selected).
		bool LcOnFunction(StringView name)
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			return tab != null && mg != null && mg.Method.Name == name && tab.SelectedNodes.IsEmpty && !mSelVarActive && !mSelClassActive &&
				ActiveTab >= 0 && ActiveTab < Tabs.Count && Tabs[ActiveTab] == tab;
		}

		/// The Sheet in front is `name`'s.
		bool LcOnFunctionSheet(StringView name)
		{
			let mg = CurrentMethod;
			return mg != null && mg.Method.Name == name && ActiveTab >= 0 && ActiveTab < Tabs.Count && Tabs[ActiveTab] == CurrentTab;
		}

		bool SelfTestFnLocals()
		{
			if (mLcWait > 0)
			{
				mLcWait--;
				return false;
			}
			let step = mLcStep++;
			switch (step)
			{
			case 0:
				// The window size is the driver's (captures at several sizes).
			case 1:
				CreateProject("Shop", 0, mProjectRoot);
				mLcSrc.Clear();
				mLcSrc.AppendF("{}{}Shop{}src", mProjectRoot, Path.DirectorySeparatorChar, Path.DirectorySeparatorChar);
				ResetCreateTypeOptions();
				CreateAsset(.Class, mLcSrc, "Shop");
				SelfTestCheck(LcDoc() != null, "fnlocals 1: a project with a class Shop");
			case 2:
				let doc = LcDoc();
				String k = scope .();
				// Each edit reads the file again: the type is looked up after each.
				bool ok = doc.AddMethod(FindTypeIn(doc, "Shop"), "void", "Run", "", k);
				ok = ok && doc.AddMethod(FindTypeIn(doc, "Shop"), "bool", "TryGet", "int key", k);
				SelfTestCheck(ok, scope $"fnlocals 2: functions Run and TryGet(int key) {doc.LastError}");
				LcOpen("Run");
			case 3:
				LcOpen("TryGet");
				mLcWait = 2;
			case 4:
				// Request 1: Add Input stays on the function being edited.
				let mg = CurrentMethod;
				SelfTestCheck(LcOnFunction("TryGet"), "fnlocals 3: TryGet's Sheet is in front, Properties on TryGet");
				mLcTabIndex = ActiveTab;
				SyncParamRows(mg);
				ParamRow r = new .();
				r.Type.Set("int");
				r.Name.Set("newParam");
				mParamRows.Add(r);
				mFocusParamRow = mParamRows.Count - 1;
				ApplyParamRows(mg);
				mLcWait = 3;
			case 5:
				let mg = CurrentMethod;
				SelfTestCheck(LcOnFunction("TryGet") && mg.Method.Params.Count == 2 && ActiveTab == mLcTabIndex,
					scope $"fnlocals 4: after Add Input the Sheet in front is still TryGet (tab {ActiveTab} of {Tabs.Count}, was {mLcTabIndex}), Properties on it");
				SelfTestCheck(mFocusParamRow == -1 && Gui.igIsAnyItemActive(), "fnlocals 5: the new Inputs row's name box has the keyboard focus");
				SelfTestCheck(LcDoc().Text.Contains("public bool TryGet(int key, int newParam)"), "fnlocals 6: written `TryGet(int key, int newParam)`");
				igClearActiveID();
			case 6:
				// Remove it again, and change the type of key: still on TryGet.
				let mg = CurrentMethod;
				SyncParamRows(mg);
				delete mParamRows.PopBack();
				mParamRows[0].Type.Set("int64");
				ApplyParamRows(mg);
				mLcWait = 3;
			case 7:
				SelfTestCheck(LcOnFunction("TryGet") && ActiveTab == mLcTabIndex && LcDoc().Text.Contains("public bool TryGet(int64 key)"),
					"fnlocals 7: input removed and key's type changed: still on TryGet");
				// Request 2: two outputs.
				let mg = CurrentMethod;
				SyncParamRows(mg);
				for (let spec in StringView[2]("int value", "String name"))
				{
					ParamRow o = new .();
					o.Modifier.Set("out");
					int sp = spec.IndexOf(' ');
					o.Type.Set(spec.Substring(0, sp));
					o.Name.Set(spec.Substring(sp + 1));
					mParamRows.Add(o);
				}
				ApplyParamRows(mg);
				mLcWait = 3;
			case 8:
				let doc = LcDoc();
				SelfTestCheck(LcOnFunction("TryGet") && doc.Text.Contains("public bool TryGet(int64 key, out int value, out String name)"),
					"fnlocals 8: Outputs: `bool TryGet(int64 key, out int value, out String name)`, still on TryGet");
				let mg = CurrentMethod;
				NcPick(mg.Graph.Entry.Then, "Return", 400, 0);
				mLcWait = 2;
			case 9:
				let doc = LcDoc();
				let mg = CurrentMethod;
				Node ret = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Return)
						ret = n;
				SelfTestCheck(ret != null && ret.FindInput("out:value") != null && ret.FindInput("out:name") != null, "fnlocals 9: the Return has an input per output (value, name)");
				SelfTestCheck(doc.Text.Contains("\t\t\tvalue = 0;\n\t\t\tname = null;\n\t\t\treturn false;"), "fnlocals 10: the Return writes `value = 0; name = null; return false;`");
				LcNote(scope $"Shop.bf after the Return:\n{doc.Text}");
				CurrentTab.ClearSelection();
				mLcWait = 3;
			case 10:
				if (!SelfTestShot("fn-outputs"))
				{
					mLcStep--;
					return false;
				}
			case 11:
				// Request 3: Locals. L adds one to the function in front, its name focused.
				AddLocalFromKey(CurrentTab, CurrentMethod);
				mLcWait = 3;
			case 12:
				let mg = CurrentMethod;
				SelfTestCheck(mg.Method.Name == "TryGet" && mg.Graph.Locals.Count == 1 && LcDoc().Text.Contains("\t\t\tint newLocal = 0;\n\t\t\tvalue = 0;"),
					"fnlocals 11: L: `int newLocal = 0;` at the top of TryGet");
				SelfTestCheck(mSelLocalActive && mSelLocalName == "newLocal" && mLocalEditing && Gui.igIsAnyItemActive(),
					"fnlocals 12: the new local variable is selected in the Outline, its name box focused");
				// Typing a name and leaving the box renames it (the Outline's own path).
				mLocalEditBuf.Set("count");
				igClearActiveID();
				mLcWait = 3;
			case 13:
				SelfTestCheck(LcDoc().Text.Contains("\t\t\tint count = 0;\n") && mSelLocalName == "count" && !mLocalEditing,
					"fnlocals 13: renamed in the Outline: `int count = 0;`, still selected");
				AddLocalTo(CurrentMethod, "String", "label");
				mLcWait = 2;
			case 14:
				let mg = CurrentMethod;
				SelfTestCheck(mg.Graph.Locals.Count == 2 && mg.Graph.Locals[1].Text == "label" && mSelLocalName == "label", "fnlocals 14: a second local variable `label` (String), selected");
				igClearActiveID();
				// Properties > Ownership > Made for this call.
				BeginEdit();
				let v = mg.Graph.Locals[1].FindInput("value");
				v.Default.Set("scope .()");
				mg.Graph.Locals[1].Edited = true;
				CommitCurrent();
				mLcWait = 2;
			case 15:
				let doc = LcDoc();
				SelfTestCheck(doc.Text.Contains("\t\t\tint count = 0;\n\t\t\tString label = scope .();\n\t\t\tvalue = 0;"), "fnlocals 15: `String label = scope .();` after count, before the flow");
				String labels = scope .();
				NcLabels(null, "count", labels);
				SelfTestCheck(labels.Contains("Get count") && labels.Contains("Set count"), scope $"fnlocals 16: the Node menu offers Get count and Set count ({labels})");
				labels.Clear();
				NcLabels(null, "Local Variable", labels);
				SelfTestCheck(!labels.Contains("Local Variable") || labels.Contains("Locals"), scope $"fnlocals 17: no Local Variable node in the Node menu ({labels})");
				let mg = CurrentMethod;
				NcPick(mg.Graph.Entry.Then, "Set count", 300, 120);
				mLcWait = 2;
			case 16:
				let mg = CurrentMethod;
				Node set = null;
				for (let n in mg.Graph.Nodes)
					if (n.Kind == .Set && n.FindInput("target")?.Default == "count")
						set = n;
				if (set != null)
				{
					BeginEdit();
					set.FindInput("value").Default.Set("5");
					set.Edited = true;
					CommitCurrent();
				}
				mLcWait = 2;
			case 17:
				SelfTestCheck(LcDoc().Text.Contains("\t\t\tString label = scope .();\n\t\t\tcount = 5;\n\t\t\tvalue = 0;"), "fnlocals 18: Set count from the Node menu: `count = 5;` after the Locals");
				CurrentTab.ClearSelection();
				SelectLocal(CurrentMethod, "label");
				mLcWait = 3;
			case 18:
				if (!SelfTestShot("local-props"))
				{
					mLcStep--;
					return false;
				}
			case 19:
				if (mShotStart < 0)
					SelfTestCheck(mSelLocalActive && mSelLocalName == "label" && LcOnFunctionSheet("TryGet"), "fnlocals 19: Properties shows the local variable label selected in the Outline");
				if (!SelfTestShot("outline-locals"))
				{
					mLcStep--;
					return false;
				}
			case 20:
				// The pin menu: a call with a result in Run, then Make variable from its pin.
				let doc = LcDoc();
				String k = scope .();
				doc.AddMethod(FindTypeIn(doc, "Shop"), "int", "Price", "", k);
				let price = LcOpen("Price");
				if (price != null)
				{
					BeginEdit();
					let ret = NodeFactory.Return(price.Graph, "int");
					ret.FindInput("value").Default.Set("3");
					price.Graph.Connect(price.Graph.Entry.Then, ret.ExecIn);
					CommitCurrent();
				}
				mLcWait = 2;
			case 21:
				let run = LcOpen("Run");
				mLcWait = 2;
				if (run == null)
					break;
				BeginEdit();
				let call = CreateCallNode(run, "Price", "", "int", true, false, "Shop", false);
				run.Graph.Connect(run.Graph.Entry.Then, call.ExecIn);
				call.X = 300;
				call.HasPos = true;
				mLcCallId = call.Id;
				CommitCurrent();
			case 22:
				let run = CurrentMethod;
				let call = run?.Graph.FindNode(mLcCallId);
				if (call == null || call.Result == null)
				{
					SelfTestCheck(false, "fnlocals 19b: Price() placed in Run");
					break;
				}
				mLcBefore.Set(LcDoc().Text);
				mLcVar.Set("m");
				String b = scope .();
				GraphPanel.PinVariableBase(call.Result, b);
				mLcVar.Append(b);
				mLcVar[1] = mLcVar[1].ToUpper;
				mGraphPanel.MakeVariableFromPin(CurrentTab, run, call.Result, true);
				mLcWait = 2;
			case 23:
				let doc = LcDoc();
				SelfTestCheck(doc.Text.Contains(scope $"int {mLcVar};") && doc.Text.Contains(scope $"{mLcVar} = "), scope $"fnlocals 20: Make variable: member `int {mLcVar};` and a Set from the pin");
				LcNote(scope $"Shop.bf after Make variable:\n{doc.Text}");
				LcDoc().Undo();
				SelfTestCheck(LcDoc().Text == mLcBefore, "fnlocals 21: one undo removes the member and the Set");
				let run = LcOpen("Run");
				let call = run?.Graph.FindNode(mLcCallId);
				if (call != null)
					mGraphPanel.MakeVariableFromPin(CurrentTab, run, call.Result, false);
				mLcWait = 2;
			case 24:
				let doc = LcDoc();
				let run = LcMethod("Run");
				SelfTestCheck(run != null && run.Graph.Locals.Count == 1 && doc.Text.Contains(scope $"\t\t\tint {run.Graph.Locals[0].Text} = 0;\n\t\t\tlet "), "fnlocals 22: Make local variable: a Local of Run set from the pin");
				LcNote(scope $"Shop.bf after Make local variable:\n{doc.Text}");
				// Make variable (Get) on TryGet's Return value (its Sheet in front first).
				LcOpen("TryGet");
				mLcWait = 2;
			case 25:
				let doc = LcDoc();
				let tg = CurrentMethod;
				Node ret = null;
				for (let n in tg.Graph.Nodes)
					if (n.Kind == .Return)
						ret = n;
				if (ret != null)
				{
					mLcBefore.Set(doc.Text);
					mGraphPanel.MakeVariableFromPin(CurrentTab, tg, ret.FindInput("value"), true);
				}
				mLcWait = 2;
			case 26:
				let doc = LcDoc();
				SelfTestCheck(doc.Text != mLcBefore && doc.Text.Contains("bool m") && doc.Text.Contains("\t\t\treturn m"), "fnlocals 23: Make variable (Get): a bool member read into the Return");
				LcNote(scope $"Shop.bf after Make variable (Get):\n{doc.Text}");
				let main = OpenFile(scope $"{mLcSrc}{Path.DirectorySeparatorChar}Program.bf", false);
				if (main != null)
					LcNote(scope $"Program.bf:\n{main.Text}");
				SaveAll();
				Compile("Release");
			case 27:
				if (SessionBuildRunning)
				{
					mLcStep--;
					return false;
				}
				mLcWait = 5;
			case 28:
				let st = SessionState;
				SelfTestCheck(st == .Good || st == .Unknown, scope $"fnlocals 24: Release compile of Locals, Outputs and the made variables ({st})");
				let doc = LcDoc();
				mLcBefore.Set(doc.Text);
				CloseDoc(doc);
			case 29:
				let doc = LcDoc();
				let tg = LcMethod("TryGet");
				SelfTestCheck(doc != null && doc.Text == mLcBefore && !doc.Modified, "fnlocals 25: Shop.bf closed and reopened byte for byte");
				SelfTestCheck(tg != null && tg.Graph.Locals.Count == 2 && tg.Graph.Locals[0].Text == "count", "fnlocals 26: TryGet's Locals read back (count, label)");
				// No ImGui misuse on the way (the host logs a failed IM_ASSERT as an [ASSERT] line).
				String log = scope .();
				int asserts = 0;
				if (File.ReadAllText(SessionLog.LogPath, log, true) case .Ok)
					for (let line in log.Split('\n'))
						if (line.Contains("[ASSERT]"))
							asserts++;
				SelfTestCheck(asserts == 0, scope $"fnlocals 27: the session log has no [ASSERT] line ({asserts})");
				return true;
			}
			return false;
		}
	}
}
