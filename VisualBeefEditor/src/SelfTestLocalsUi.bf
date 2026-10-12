using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=localsui` on the Debuggee fixture (a copy): the Local `sum` of Greeter.Add (used by
	/// later nodes) with a breakpoint on it (the red dot in the Outline), its context menu open, a delete
	/// refused while it is used (the status line), Properties of the middle declaration `int extra` in
	/// Hello with Move to Local Variables, and a Start Debugging stop on the Local (the arrow).
	/// Captures `ls-bp`, `ls-menu`, `ls-refused`, `ls-move`, `ls-stopped` (VB_SHOTS).
	extension EditorApp
	{
		int mLuStep;
		int mLuWait;
		String mLuMenuLocal = new .() ~ delete _;
		bool mLuMenuClose;
		int mLuMenuFrames;
		double mLuT0;
		// What the Outline drew last frame (set while drawing, read by the self test): the screen Y of the
		// FUNCTIONS / VARIABLES / LOCAL VARIABLES bars, where the VARIABLES rows end, the local rows listed and
		// the badge count, and whether the "Open a function" row was drawn.
		float mOlFunctionsY;
		float mOlVarsY;
		float mOlVarsEndY;
		float mOlLocalsY;
		int mOlLocalsCount;
		bool mOlNone;
		bool mOlRecording;
		String mOlLocalNames = new .() ~ delete _;
		/// Test hook: the Outline behaves as if no function's Sheet was in front.
		bool mOlForceNoSheet;

		void OlResetRecord()
		{
			mOlFunctionsY = -1;
			mOlVarsY = -1;
			mOlVarsEndY = -1;
			mOlLocalsY = -1;
			mOlLocalsCount = -1;
			mOlNone = false;
			mOlLocalNames.Clear();
		}

		[CLink] static extern void ImGuiIO_AddMousePosEvent(void* io, float x, float y);

		/// Test hook: the Local's context menu opens as if right-clicked on its row: the mouse is moved onto
		/// the row first (its popup is placed at the mouse), then the popup of the row is opened.
		void LuMenuOpenHook(StringView name)
		{
			if (mLuMenuLocal.IsEmpty || mLuMenuLocal != name)
				return;
			mLuMenuFrames++;
			let min = Gui.igGetItemRectMin();
			let max = Gui.igGetItemRectMax();
			if (mLuMenuFrames == 1)
				ImGuiIO_AddMousePosEvent(Gui.igGetIO_Nil(), min.x + 60 * Look.Scale, (min.y + max.y) * 0.5f);
			else if (mLuMenuFrames >= 3)
			{
				// The popup's place: under the row, as the right-click would put it (cond Always, pivot top-left).
				Gui.igSetNextWindowPos(.(min.x + 60 * Look.Scale, max.y), 1, .(0, 0));
				Gui.igOpenPopup_ID(Gui.igGetItemID(), 0);
			}
		}

		/// Test hook: closes the open context menu when the harness asks.
		void LuMenuCloseHook()
		{
			if (mLuMenuClose)
			{
				mLuMenuClose = false;
				mLuMenuLocal.Clear();
				mLuMenuFrames = 0;
				ImGuiIO_AddMousePosEvent(Gui.igGetIO_Nil(), -3.4e38f, -3.4e38f); // no mouse: no hover tooltip in the captures
				Gui.igCloseCurrentPopup();
			}
		}

		bool mLuPreDone;
		bool mLuPost;
		int mLuPs;
		float mLuNoneY;
		float mLuAddY;

		/// The Outline's LOCAL VARIABLES bar sits directly under the VARIABLES rows, after FUNCTIONS.
		void LuCheckOrder(StringView what)
		{
			SelfTestCheck(mOlFunctionsY >= 0 && mOlFunctionsY < mOlVarsY && mOlVarsY < mOlLocalsY, scope $"localsui {what}: bars in order FUNCTIONS {mOlFunctionsY} < VARIABLES {mOlVarsY} < LOCAL VARIABLES {mOlLocalsY}");
			SelfTestCheck(mOlLocalsY >= mOlVarsEndY && mOlLocalsY - mOlVarsEndY < 14 * Look.Scale, scope $"localsui {what}: LOCAL VARIABLES starts right below the VARIABLES rows ({mOlVarsEndY} -> {mOlLocalsY})");
		}

		/// Before the Sheet opens: no function in front, the bar shows 0 and the dim row (capture `ls-none`).
		bool LuPre()
		{
			switch (mLuPs++)
			{
			case 0:
				let mg = LuMethod("Add");
				SelfTestCheck(mg != null, "localsui pre: Greeter.Add in Program.bf");
				// A Sheet may be open already (a project start opens one): then the Outline is told there is none.
				mOlForceNoSheet = CurrentTab != null;
				mLuWait = 4;
			case 1:
				SelfTestCheck(mOlNone && mOlLocalNames.IsEmpty && mOlLocalsCount == 0, scope $"localsui pre: no Sheet open: the bar counts {mOlLocalsCount}, the row 'Open a function to see its locals' drawn ({mOlNone})");
				LuCheckOrder("pre");
				mLuNoneY = mOlLocalsY;
			case 2:
				if (!SelfTestShot("ls-none"))
				{
					mLuPs--;
					return false;
				}
				mOlForceNoSheet = false;
				mLuPs = 0;
				return true;
			}
			return false;
		}

		/// After the Debug stop: the section stays put while the function in front changes, and its rows follow
		/// the Sheet, a local added, renamed, deleted and undone.
		bool LuPost()
		{
			let hello = LuMethod("Hello");
			switch (mLuPs++)
			{
			case 0:
				let mg = LuMethod("Add");
				SelfTestCheck(mg != null && hello != null, "localsui post: Add and Hello");
				if (mg == null || hello == null)
					return true;
				OpenTab(mg);
				mLuWait = 4;
			case 1:
				SelfTestCheck(!mOlNone && mOlLocalNames == "sum" && mOlLocalsCount == 1, scope $"localsui post 1: Add's Sheet in front: rows '{mOlLocalNames}', badge {mOlLocalsCount}");
				LuCheckOrder("post 1");
				SelfTestCheck(Math.Abs(mOlLocalsY - mLuNoneY) < 0.5f, scope $"localsui post 1: the bar did not move between no Sheet ({mLuNoneY}) and Add ({mOlLocalsY})");
				mLuAddY = mOlLocalsY;
				OpenTab(hello);
				mLuWait = 4;
			case 2:
				SelfTestCheck(mOlLocalNames == "first" && mOlLocalsCount == 1, scope $"localsui post 2: Hello's Sheet in front: rows '{mOlLocalNames}' (first), badge {mOlLocalsCount}; Add's sum is gone");
				SelfTestCheck(Math.Abs(mOlLocalsY - mLuAddY) < 0.5f, scope $"localsui post 2: the bar stays where it was ({mLuAddY} -> {mOlLocalsY})");
				LuCheckOrder("post 2");
				mLuWait = 2;
			case 3:
				if (!SelfTestShot("ls-switch"))
				{
					mLuPs--;
					return false;
				}
				AddLocalTo(hello);
				mLocalEditing = false;
				mLuWait = 4;
			case 4:
				SelfTestCheck(mOlLocalNames == "first,newLocal" && mOlLocalsCount == 2, scope $"localsui post 4: a local added: rows '{mOlLocalNames}', badge {mOlLocalsCount}");
				let local = hello.Graph.FindLocal("newLocal");
				if (local != null)
					RenameLocal(hello, hello.Graph.Locals.IndexOf(local), "renamed");
				mLuWait = 4;
			case 5:
				SelfTestCheck(mOlLocalNames == "first,renamed", scope $"localsui post 5: the local renamed: rows '{mOlLocalNames}'");
				hello.Doc.Undo();
				mLuWait = 4;
			case 6:
				SelfTestCheck(mOlLocalNames == "first,newLocal", scope $"localsui post 6: undo of the rename: rows '{mOlLocalNames}'");
				hello.Doc.Undo();
				mLuWait = 4;
			case 7:
				SelfTestCheck(mOlLocalNames == "first" && mOlLocalsCount == 1, scope $"localsui post 7: undo of the add: rows '{mOlLocalNames}', badge {mOlLocalsCount}");
				AddLocalTo(hello);
				mLocalEditing = false;
				mLuWait = 4;
			case 8:
				SelfTestCheck(mOlLocalNames == "first,newLocal", scope $"localsui post 8: added again: rows '{mOlLocalNames}'");
				let local = hello.Graph.FindLocal("newLocal");
				if (local != null)
				{
					String why = scope .();
					BeginEdit();
					hello.Graph.RemoveLocal(local, why);
					mSelLocalActive = false;
					CommitCurrent();
				}
				mLuWait = 4;
			case 9:
				SelfTestCheck(mOlLocalNames == "first" && mOlLocalsCount == 1, scope $"localsui post 9: the local deleted: rows '{mOlLocalNames}', badge {mOlLocalsCount}");
				LuCheckOrder("post 9");
				return true;
			}
			return false;
		}

		bool SelfTestLocalsUi()
		{
			if (mLuWait > 0)
			{
				mLuWait--;
				return false;
			}
			if (!mLuPreDone)
			{
				if (LuPre())
					mLuPreDone = true;
				return false;
			}
			if (mLuPost)
			{
				if (LuPost())
				{
					let mg = LuMethod("Add");
					let local = (mg != null) ? mg.Graph.FindLocal("sum") : null;
					if (local != null)
						ToggleBreakpoint(mg, local);
					return true;
				}
				return false;
			}
			let step = mLuStep++;
			switch (step)
			{
			case 0:
				// The window size is the driver's (captures at several sizes).
			case 1:
				let mg = LuMethod("Add");
				SelfTestCheck(mg != null, "localsui 1: Greeter.Add in Program.bf");
				if (mg == null)
					return true;
				OpenTab(mg);
				mLuWait = 2;
			case 2:
				let mg = CurrentMethod;
				let local = (mg != null) ? mg.Graph.FindLocal("sum") : null;
				SelfTestCheck(local != null && mg.Graph.IsLocalUsed(local), scope $"localsui 2: Add's Local sum, used by later nodes ({(mg != null) ? mg.Graph.Locals.Count : -1} Locals)");
				if (local == null)
					return true;
				ToggleBreakpoint(mg, local);
				HashSet<int32> ids = scope .();
				BreakpointNodes(mg, ids);
				SelfTestCheck(ids.Contains(local.Id), "localsui 2: a breakpoint on the Local's declaration (red dot)");
				SelectLocal(mg, "sum");
				Panels.Focus(Panels.OutlineId);
				mStatus.Clear();
				mLuWait = 3;
			case 3:
				if (!SelfTestShot("ls-bp"))
				{
					mLuStep--;
					return false;
				}
			case 4:
				mLuMenuLocal.Set("sum");
				mLuMenuFrames = 0;
				mLuWait = 6;
			case 5:
				if (!SelfTestShot("ls-menu"))
				{
					mLuStep--;
					return false;
				}
				mLuMenuClose = true;
				mLuWait = 3;
			case 6:
				// Delete (the Properties button or the menu item) of a Local that later nodes use: refused.
				let mg = CurrentMethod;
				let local = mg.Graph.FindLocal("sum");
				String why = scope .();
				SelfTestCheck(local != null && mg.Graph.IsLocalUsed(local), "localsui 6: later nodes use sum");
				bool gone = mg.Graph.RemoveLocal(local, why);
				SetStatus(why, .Warning);
				SelfTestCheck(!gone && mg.Graph.FindLocal("sum") != null, scope $"localsui 6: the delete is refused ({why})");
				SelectLocal(mg, "sum");
				mLuWait = 3;
			case 7:
				if (!SelfTestShot("ls-refused"))
				{
					mLuStep--;
					return false;
				}
			case 8:
				// Properties of the middle declaration `int extra` in Hello: Move to Local Variables.
				let hello = LuMethod("Hello");
				Node total = null;
				if (hello != null)
					for (let n in hello.Graph.Nodes)
						if (n.Kind == .LocalVar && n.Text == "extra")
							total = n;
				SelfTestCheck(total != null, "localsui 8: the declaration `int extra` in Hello");
				if (total == null)
					return true;
				OpenTab(hello);
				mSelLocalActive = false;
				CurrentTab.ClearSelection();
				CurrentTab.SelectOnly(total.Id);
				mStatus.Clear();
				mLuT0 = Desktop.Now;
				mLuWait = 3;
			case 9:
				if (Desktop.Now - mLuT0 < 9)
				{
					// The refused-delete toast leaves the screen first (it would sit over Properties).
					mLuStep--;
					return false;
				}
				if (!SelfTestShot("ls-move"))
				{
					mLuStep--;
					return false;
				}
				// Start Debugging: the breakpoint on sum stops the program in Add.
				mDebugTestFrames = 0;
				StartDebugging();
				mLuWait = 2;
			case 10:
				if (!DebugTestWait(let stopped))
				{
					mLuStep--;
					return false;
				}
				let mg = LuMethod("Add");
				let local = (mg != null) ? mg.Graph.FindLocal("sum") : null;
				SelfTestCheck(stopped && local != null && DebugStopNode == local.Id,
					scope $"localsui 10: stopped on the Local sum of Add ({mDebugStopWhere})");
				CurrentTab?.ClearSelection();
				mStatus.Clear();
				mLuWait = 2;
			case 11:
				if (!SelfTestShot("ls-stopped"))
				{
					mLuStep--;
					return false;
				}
				StopDebugging();
				mLuWait = 5;
			case 12:
				mLuPs = 0;
				mLuPost = true;
				return false;
			}
			return false;
		}

		MethodGraph LuMethod(StringView name)
		{
			let doc = OpenFile(scope $"{mProjectRoot}{Path.DirectorySeparatorChar}src{Path.DirectorySeparatorChar}Program.bf", false);
			if (doc == null)
				return null;
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == name)
					return mg;
			return null;
		}
	}
}
