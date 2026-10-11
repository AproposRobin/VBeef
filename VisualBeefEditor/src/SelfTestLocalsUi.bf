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

		bool SelfTestLocalsUi()
		{
			if (mLuWait > 0)
			{
				mLuWait--;
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
				let mg = LuMethod("Add");
				let local = (mg != null) ? mg.Graph.FindLocal("sum") : null;
				if (local != null)
					ToggleBreakpoint(mg, local);
				return true;
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
