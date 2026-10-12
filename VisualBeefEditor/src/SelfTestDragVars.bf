using System;
using System.Collections;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;
using VisualBeef.Catalog;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=dragvars` on a project with a `Shop` class (`int mCount`, `float mPrice`,
	/// `String mName`, `int Add(int a, int b)` and `Run()` with the local variable `int total = 0;`
	/// and the statement `Add(1, 2);`). The 2026-10-12 owner requests through the calls the UI makes:
	/// the ghost over an input that takes the variable (green ring, "Get mCount into a"), over one
	/// that refuses it (the refusal colour and the reason), over the Sheet, for a function and a
	/// Project Browser tile; mCount dropped on Add's `a` (`Add(mCount, 2);`, one undo step), the local
	/// variable total dropped on Add's Return Value (a Set after the call), mName on an int input
	/// refused in the status bar with nothing written, a variable dragged out of the Node menu onto a
	/// pin and onto the Sheet (a Set row places a Set); Add Variable starting with `int`, its type
	/// picker open, `bool` picked (preview `public bool bRunning;`), Create, the next Add Variable
	/// starting with `bool`, a typed `Dictionary<String, int>` taken. Captures `dv-first`,
	/// `dv-accepted`, `dv-refused`, `dv-ghost`, `dv-ghost-fn`, `dv-ghost-asset`, `dv-dropped`, `dv-set`,
	/// `dv-addvar-picker`, `dv-addvar-bool` (docs/Testing.md > Verifying the UI). `dragvars-live`
	/// (below) drags with ImGui's own mouse input.
	extension EditorApp
	{
		int mDvStep;
		int mDvWait;
		String mDvPath = new .() ~ delete _;
		String mDvSaved = new .() ~ delete _;
		const String cDvRun = "Shop.Run()";

		SourceDocument DvDoc => FindDoc(mDvPath);

		MethodGraph DvOpen()
		{
			let doc = DvDoc;
			let mg = (doc != null) ? doc.FindMethod(cDvRun) : null;
			if (mg != null)
				OpenTab(mg);
			return CurrentMethod;
		}

		Node DvAdd()
		{
			let mg = DvOpen();
			return (mg != null) ? FindNodeOf(mg.Graph, .Call, "Add") : null;
		}

		/// The text of the file, line breaks as `\n`.
		void DvText(String outText)
		{
			let doc = DvDoc;
			if (doc != null)
				outText.Set(doc.Text);
			outText.Replace("\r\n", "\n");
		}

		bool DvHas(StringView part)
		{
			String t = scope .();
			DvText(t);
			return t.Contains(part);
		}

		/// Ctrl+Z on the file (what the shortcut does).
		bool DvUndo()
		{
			let doc = DvDoc;
			if (doc == null || !doc.CanUndo)
				return false;
			if (!GroupUndo(doc, false))
				doc.Undo();
			UpdateTitle();
			return true;
		}

		/// The Outline row (an index into the drag payload list) of a variable or function.
		int32 DvRow(StringView name, MemberRef.Kind kind)
		{
			for (let m in mMembers)
				if (m.Name == name && m.MemberKind == kind)
					return (int32)@m.Index;
			return -1;
		}

		/// The Add call in the middle of the canvas, at 1:1.
		void DvCenter()
		{
			let tab = CurrentTab;
			let add = DvAdd();
			if (tab == null || add == null)
				return;
			tab.ClearSelection();
			tab.ZoomLevel = Canvas.DefaultZoomLevel;
			tab.CenterOn(add.X + 60, add.Y + 40);
			tab.NeedsFocus = false;
			mStatus.Clear();
		}

		ImVec2 DvCanvasPoint(float fx, float fy)
		{
			let tab = CurrentTab;
			if (tab == null)
				return .(400, 300);
			return tab.CanvasOrigin + ImVec2(tab.CanvasSize.x * fx, tab.CanvasSize.y * fy);
		}

		bool DvShot(StringView name)
		{
			if (!SelfTestShot(name))
			{
				mDvStep--;
				return false;
			}
			return true;
		}

		bool SelfTestDragVars()
		{
			if (mDvWait > 0)
			{
				mDvWait--;
				return false;
			}
			let step = mDvStep++;
			switch (step)
			{
			case 0:
				for (let f in Index.Files)
				{
					let doc = OpenFile(f.Path, false);
					if (doc != null && doc.FindMethod(cDvRun) != null)
					{
						mDvPath.Set(f.Path);
						break;
					}
				}
				let mg = DvOpen();
				SelfTestCheck(mg != null && DvAdd() != null, "dragvars 1: Shop.Run opened, it calls Add");
				if (mg == null || DvAdd() == null)
					return true;
				mDvSaved.Set(DvDoc.Text);
				Panels.Focus(Panels.OutlineId);
				DvCenter();
			case 1:
				// The first frame after opening the function.
				if (!DvShot("dv-first"))
					return false;
				mDvWait = 3;
			case 2:
				// The ghost of mCount over Add's input a: taken.
				let add = DvAdd();
				GhostFrames = 0;
				SelfTestShowDrag("mCount", "int", add.FindInput("arg0").Id, DvCanvasPoint(0.5f, 0.5f));
				mDvWait = 3;
			case 3:
				SelfTestCheck(GhostFrames > 0 && GhostLastHint.StartsWith("Get mCount into") && !GhostLastRefused,
					scope $"dragvars 2: the ghost follows the drag; over Add's a it says \"{GhostLastHint}\" (taken)");
			case 4:
				if (!DvShot("dv-accepted"))
					return false;
			case 5:
				// mName (String) over the int input b: refused, with the reason.
				let add = DvAdd();
				SelfTestShowDrag("mName", "String", add.FindInput("arg1").Id, DvCanvasPoint(0.5f, 0.5f));
				mDvWait = 3;
			case 6:
				SelfTestCheck(GhostLastRefused && GhostLastHint.StartsWith("Can't connect:"),
					scope $"dragvars 3: over the int input b a String is refused: \"{GhostLastHint}\"");
			case 7:
				if (!DvShot("dv-refused"))
					return false;
			case 8:
				// The ghost over the empty Sheet: name and type, no second line.
				SelfTestShowDrag("total", "int", 0, DvCanvasPoint(0.3f, 0.75f));
				mDvWait = 3;
			case 9:
				SelfTestCheck(GhostFrames > 0 && GhostLastHint.IsEmpty, "dragvars 4: over the empty Sheet the ghost shows the name and the type only");
			case 10:
				if (!DvShot("dv-ghost"))
					return false;
				SelfTestShowDrag("Add", "int", 0, DvCanvasPoint(0.3f, 0.75f), .Function);
				mDvWait = 3;
			case 11:
				if (!DvShot("dv-ghost-fn"))
					return false;
				SelfTestEndDrag();
				CBItem item = scope .();
				item.Kind = .Class;
				item.Name.Set("Shop");
				item.Key.Set("T|selftest|Shop");
				SelfTestShowAssetDrag(item, DvCanvasPoint(0.3f, 0.75f));
				mDvWait = 3;
			case 12:
				if (!DvShot("dv-ghost-asset"))
					return false;
				SelfTestEndDrag();
				mDvWait = 2;
			case 13:
				// mCount dropped on Add's a (the Outline row's payload, the pin under the cursor).
				let add = DvAdd();
				int32 row = DvRow("mCount", .Variable);
				SelfTestCheck(row >= 0, "dragvars 5: the Outline lists mCount");
				if (row < 0)
					return true;
				DropMember(CurrentTab, row, .(add.X - 200, add.Y), add.FindInput("arg0").Id);
				mDvWait = 2;
			case 14:
				let mg = DvOpen();
				let add = FindNodeOf(mg.Graph, .Call, "Add");
				let link = mg.Graph.FindLinkTo(add.FindInput("arg0"));
				let get = link?.From.Owner;
				SelfTestCheck(DvHas("\t\t\tAdd(mCount, 2);\n") && get != null && get.Kind == .Get && get.Text == "mCount" && CurrentTab.IsSelected(get.Id),
					"dragvars 6: mCount dropped on a: a Get of mCount wired into it, selected, written `Add(mCount, 2);`");
				DvCenter();
				mDvWait = 2;
			case 15:
				if (!DvShot("dv-dropped"))
					return false;
			case 16:
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved && FindNodeOf(DvOpen().Graph, .Get, "mCount") == null,
					"dragvars 7: one undo removes the Get and its wire, the file is as it was");
				mDvWait = 2;
			case 17:
				// The local variable total dropped on Add's Return Value: a Set after the call.
				let add = DvAdd();
				int32 row = DvRow("total", .Variable);
				SelfTestCheck(row >= 0, "dragvars 8: LOCAL VARIABLES lists total");
				if (row < 0)
					return true;
				DropMember(CurrentTab, row, .(add.X + 300, add.Y), add.Result.Id);
				mDvWait = 2;
			case 18:
				String t = scope .();
				DvText(t);
				int iAdd = t.IndexOf("Add(1, 2)");
				int iSet = t.IndexOf("\t\t\ttotal = ");
				int iDone = t.IndexOf("\"done\"");
				let mg = DvOpen();
				let add = FindNodeOf(mg.Graph, .Call, "Add");
				let next = mg.Graph.ExecTarget(add.Then);
				SelfTestCheck(next != null && next.Kind == .Set && iAdd >= 0 && iSet > iAdd && iDone > iSet,
					"dragvars 9: total dropped on Add's Return Value: a Set of total fed by it, run right after Add");
				DvCenter();
				mDvWait = 2;
			case 19:
				if (!DvShot("dv-set"))
					return false;
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved, "dragvars 10: one undo removes the Set and its wires");
				mDvWait = 2;
			case 20:
				// A String on an int input: refused in the status bar, nothing written, no undo step.
				let add = DvAdd();
				let doc = DvDoc;
				let couldUndo = doc.CanUndo;
				int32 row = DvRow("mName", .Variable);
				mStatus.Clear();
				DropMember(CurrentTab, row, .(add.X - 200, add.Y), add.FindInput("arg1").Id);
				SelfTestCheck(mStatus.StartsWith("Can't connect:") && doc.Text == mDvSaved && !doc.Modified && doc.CanUndo == couldUndo,
					scope $"dragvars 11: mName on the int input b is refused: \"{mStatus}\", nothing written");
				mDvWait = 2;
			case 21:
				// Dragged out of the Node menu: the Get total row onto b, then the Set total row onto the Sheet.
				let add = DvAdd();
				BeginMenuDrag("total", "int", false);
				DropMember(CurrentTab, cMenuDragIndex, .(add.X - 200, add.Y + 60), add.FindInput("arg1").Id);
				mDvWait = 2;
			case 22:
				SelfTestCheck(DvHas("\t\t\tAdd(1, total);\n"), "dragvars 12: a Node menu variable row dropped on b: `Add(1, total);`");
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved, "dragvars 12: one undo");
				mDvWait = 2;
			case 23:
				let add = DvAdd();
				let before = DvOpen().Graph.Nodes.Count;
				BeginMenuDrag("total", "int", true);
				DropMember(CurrentTab, cMenuDragIndex, .(add.X, add.Y + 200), 0);
				mDvCount = before;
				mDvWait = 2;
			case 24:
				let g = DvOpen().Graph;
				Node set = null;
				for (let n in g.Nodes)
					if (n.Kind == .Set && n.FindInput("target")?.Default == "total")
						set = n;
				SelfTestCheck(g.Nodes.Count == mDvCount + 1 && set != null && CurrentTab.IsSelected(set.Id),
					"dragvars 13: the Set total row dropped on the Sheet places a Set of total (no Get / Set question)");
				SelfTestCheck(DvUndo() && DvOpen().Graph.Nodes.Count == mDvCount, "dragvars 13: one undo removes it");
				mDvWait = 2;
			case 25:
				// Add Variable: the type picker, starting with int.
				mStatus.Clear();
				OpenAddVariable("Shop", "bRunning");
				SelfTestCheck(mTypeBuf.View == "int", scope $"dragvars 14: Add Variable starts with int ({mTypeBuf.View})");
				mDvWait = 3;
			case 26:
				mSelfTestPickerId.Set("##vtype");
				mSelfTestPickerSearch.Clear();
				mDvWait = 3;
			case 27:
				if (!DvShot("dv-addvar-picker"))
					return false;
			case 28:
				mSelfTestPickerPick.Set("bool");
				mDvWait = 3;
			case 29:
				SelfTestCheck(mTypeBuf.View == "bool" && SelfTestAddVarPreview == "public bool bRunning;",
					scope $"dragvars 15: bool picked: the type is {mTypeBuf.View}, the preview `{SelfTestAddVarPreview}`");
			case 30:
				if (!DvShot("dv-addvar-bool"))
					return false;
				SelfTestAddVarCreate = true;
				mDvWait = 3;
			case 31:
				SelfTestCheck(DvHas("\t\tpublic bool bRunning;\n") && mLastVarType == "bool", "dragvars 16: Create writes the preview line `public bool bRunning;`");
				OpenAddVariable("Shop", "mTable");
				SelfTestCheck(mTypeBuf.View == "bool", scope $"dragvars 17: the next Add Variable starts with the last type used ({mTypeBuf.View})");
				mDvWait = 3;
			case 32:
				// A type the picker does not list, typed into its search box.
				mSelfTestPickerId.Set("##vtype");
				mSelfTestPickerSearch.Set("Dictionary<String, int>");
				mDvWait = 3;
			case 33:
				mSelfTestPickerPick.Set("Dictionary<String, int>");
				mDvWait = 3;
			case 34:
				SelfTestCheck(mTypeBuf.View == "Dictionary<String, int>" && SelfTestAddVarPreview.StartsWith("public Dictionary<String, int> mTable"),
					scope $"dragvars 18: a typed Dictionary<String, int> is taken: `{SelfTestAddVarPreview}`");
				mSelfTestCloseDialog = true;
				mDvWait = 3;
			case 35:
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved, "dragvars 19: undo removes bRunning; the file is as it was");
			default:
				mDvStep = 0; // the other dragvars test may follow
				return true;
			}
			return false;
		}
		int mDvCount;

		/// Self test: the Outline row of this variable records where it was drawn (screen).
		public String SelfTestRowName = new .() ~ delete _;
		public ImVec2 SelfTestRowAt;

		/// `VB_SELFTEST=dragvars-live`: a real drag through ImGui's own input (the mouse events the
		/// platform layer would queue): press on the mCount row of the Outline, move over Add's input a
		/// one frame at a time (capture `dvlive-over-pin`: the ghost and the ring), release. The drop
		/// must have written `Add(mCount, 2);`. Run it on a window that never had the keyboard focus
		/// (the runner starts it minimized and shows it without activating it): a focused window reads
		/// the real cursor every frame instead.
		bool SelfTestDragVarsLive()
		{
			if (mDvWait > 0)
			{
				mDvWait--;
				return false;
			}
			let io = DragNative.igGetIO_Nil();
			let step = mDvStep++;
			switch (step)
			{
			case 0:
				for (let f in Index.Files)
				{
					let doc = OpenFile(f.Path, false);
					if (doc != null && doc.FindMethod(cDvRun) != null)
					{
						mDvPath.Set(f.Path);
						break;
					}
				}
				SelfTestCheck(DvOpen() != null && DvAdd() != null, "dragvars-live 1: Shop.Run opened");
				if (DvAdd() == null)
					return true;
				mDvSaved.Set(DvDoc.Text);
				Panels.Focus(Panels.OutlineId);
				SelfTestRowName.Set("mCount");
				DvCenter();
				mDvWait = 5;
			case 1:
				let add = DvAdd();
				bool pinOk = mGraphPanel.PinScreenPos(CurrentTab, add.FindInput("arg0").Id, out mDvPinAt);
				SelfTestCheck(pinOk && SelfTestRowAt.x > 0, scope $"dragvars-live 2: the mCount row ({(int)SelfTestRowAt.x}, {(int)SelfTestRowAt.y}) and the pin ({(int)mDvPinAt.x}, {(int)mDvPinAt.y}) are on screen");
				if (!pinOk)
					return true;
				DragNative.ImGuiIO_AddMousePosEvent(io, SelfTestRowAt.x, SelfTestRowAt.y);
				mDvWait = 2;
			case 2:
				DragNative.ImGuiIO_AddMouseButtonEvent(io, 0, true);
				mDvWait = 2;
			case 3, 4, 5, 6, 7, 8, 9, 10, 11, 12:
				float t = (step - 2) / 10.0f;
				DragNative.ImGuiIO_AddMousePosEvent(io, SelfTestRowAt.x + (mDvPinAt.x - SelfTestRowAt.x) * t, SelfTestRowAt.y + (mDvPinAt.y - SelfTestRowAt.y) * t);
				if (step == 12)
					mDvWait = 3;
			case 13:
				SelfTestCheck(ActiveDrag() != null && GhostLastHint.StartsWith("Get mCount into") && !GhostLastRefused,
					scope $"dragvars-live 3: mid-drag over a the ghost says \"{GhostLastHint}\"");
			case 14:
				if (!DvShot("dvlive-over-pin"))
					return false;
				DragNative.ImGuiIO_AddMouseButtonEvent(io, 0, false);
				mDvDrops = mGraphPanel.DropsSeen;
				mDvWait = 5;
			case 15:
				SelfTestCheck(DvHas("\t\t\tAdd(mCount, 2);\n") && FindNodeOf(DvOpen().Graph, .Get, "mCount") != null && ActiveDrag() == null,
					scope $"dragvars-live 4: released on a: `Add(mCount, 2);` (drops the Sheet took: {mGraphPanel.DropsSeen - mDvDrops})");
				DvCenter();
				mDvWait = 2;
			case 16:
				if (!DvShot("dvlive-after"))
					return false;
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved, "dragvars-live 5: one undo");
				mDvWait = 2;
			case 17:
				// Out of the Node menu: the Get total row pressed, dragged onto b, released.
				let add = DvAdd();
				OpenNodeMenu(CurrentTab, .(add.X - 300, add.Y + 200), 0);
				mNodeMenu.SelfTestSetSearch("total");
				mNodeMenu.SelfTestRowFor.Set("total");
				mNodeMenu.SelfTestRowAt = .(-1, -1);
				mDvWait = 6;
			case 18:
				let add = DvAdd();
				bool pinOk = mGraphPanel.PinScreenPos(CurrentTab, add.FindInput("arg1").Id, out mDvPinAt);
				let row = mNodeMenu.SelfTestRowAt;
				SelfTestCheck(mNodeMenu.IsShown && row.x > 0 && pinOk, scope $"dragvars-live 6: the Node menu shows Get total ({(int)row.x}, {(int)row.y}); pin b at ({(int)mDvPinAt.x}, {(int)mDvPinAt.y})");
				if (row.x <= 0 || !pinOk)
					return true;
				mDvRowAt = row;
				DragNative.ImGuiIO_AddMousePosEvent(io, row.x, row.y);
				mDvWait = 2;
			case 19:
				DragNative.ImGuiIO_AddMouseButtonEvent(io, 0, true);
				mDvWait = 2;
			case 20, 21, 22, 23, 24, 25, 26, 27, 28, 29:
				float t = (step - 19) / 10.0f;
				DragNative.ImGuiIO_AddMousePosEvent(io, mDvRowAt.x + (mDvPinAt.x - mDvRowAt.x) * t, mDvRowAt.y + (mDvPinAt.y - mDvRowAt.y) * t);
				if (step == 29)
					mDvWait = 3;
			case 30:
				SelfTestCheck(!mNodeMenu.IsShown && ActiveDrag() != null && GhostLastHint.StartsWith("Get total into b"),
					scope $"dragvars-live 7: the menu closed as the drag began; over b the ghost says \"{GhostLastHint}\"");
			case 31:
				if (!DvShot("dvlive-menu-over-pin"))
					return false;
				DragNative.ImGuiIO_AddMouseButtonEvent(io, 0, false);
				mDvDrops = mGraphPanel.DropsSeen;
				mDvCount = DvOpen().Graph.Nodes.Count;
				mDvWait = 5;
			case 32:
				SelfTestCheck(DvHas("\t\t\tAdd(1, total);\n"), scope $"dragvars-live 8: released on b: `Add(1, total);` (drops the Sheet took: {mGraphPanel.DropsSeen - mDvDrops}, nodes added: {DvOpen().Graph.Nodes.Count - mDvCount}, status: {mStatus})");
				SelfTestCheck(DvUndo() && DvDoc.Text == mDvSaved, "dragvars-live 9: one undo");
			default:
				mDvStep = 0; // the other dragvars test may follow
				return true;
			}
			return false;
		}
		ImVec2 mDvPinAt;
		ImVec2 mDvRowAt;
		int mDvDrops;
	}
}
