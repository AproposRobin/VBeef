using System;
using System.Collections;
using System.IO;
using VisualBeef.Debug;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// Capture set-up steps for the pixel passes (docs/Testing.md > Captures): the debugger screens
	/// (`debugshots`, `faultshot`), the Add dialogs, the type picker per context, a bad generic
	/// list, a variable's details and the Node menu's search and open tree. Every step only sets
	/// the editor into the state the UI has when the user does the same.
	extension EditorApp
	{
		bool mSelfTestCloseDialog;
		bool mSelfTestLocalsOpen;
		String mSelfTestPickerId = new .() ~ delete _;
		String mSelfTestPickerSearch = new .() ~ delete _;
		int mPixStep;
		int mPixSub;
		int32 mPixStops;

		/// Steps with arguments. `adddialog:fn:<Type>|<ret>|<params with ; for commas>`,
		/// `adddialog:var:<Type>|<type>`, `picker:<button id>[|search]`, `generics:<text>`,
		/// `selectvar:<Type>:<name>`, `deselect`, `menu-search:<text>`, `menu-open:<path>`.
		bool SelfTestPixelStep(StringView test)
		{
			if (test.StartsWith("adddialog:"))
			{
				var spec = test.Substring(10);
				bool isFn = spec.StartsWith("fn:");
				spec = spec.Substring(isFn ? 3 : 4);
				List<StringView> parts = scope .();
				for (let p in spec.Split('|'))
					parts.Add(p);
				mAddTargetType.Set(parts[0]);
				if (isFn)
				{
					mNameBuf.Set("NewFunction");
					mTypeBuf.Set((parts.Count > 1) ? parts[1] : "void");
					String pars = scope .((parts.Count > 2) ? parts[2] : "");
					pars.Replace(";", ", ");
					mParamsBuf.Set(pars);
					mOpenAddFunction = true;
				}
				else
				{
					mNameBuf.Set("mNewVar");
					mTypeBuf.Set((parts.Count > 1) ? parts[1] : "int");
					mParamsBuf.Set("");
					mOpenAddVariable = true;
				}
				SelfTestCheck(true, scope $"dialog {spec}");
				return true;
			}
			if (test.StartsWith("openfn:"))
			{
				// `openfn:Type.Name`: the first function of that name, whatever its parameters.
				let want = test.Substring(7);
				for (let f in Index.Files)
				{
					let doc = OpenFile(f.Path, false);
					if (doc == null)
						continue;
					for (let mg in doc.Methods)
						if (mg.Owner != null && want == scope $"{mg.Owner.Name}.{mg.Method.Name}")
						{
							OpenTab(mg);
							SelfTestCheck(true, scope $"opened {mg.Key}");
							return true;
						}
				}
				SelfTestCheck(false, scope $"openfn: {want} not found");
				return true;
			}
			if (test.StartsWith("picker:"))
			{
				let spec = test.Substring(7);
				int bar = spec.IndexOf('|');
				mSelfTestPickerId.Set((bar >= 0) ? spec.Substring(0, bar) : spec);
				mSelfTestPickerSearch.Set((bar >= 0) ? spec.Substring(bar + 1) : "");
				return true;
			}
			if (test.StartsWith("category:"))
			{
				PropertyGrid.ForceOpen.Set(test.Substring(9));
				return true;
			}
			if (test.StartsWith("generics:"))
			{
				String g = scope .(test.Substring(9));
				g.Replace(";", ", ");
				mGenericBuf.Set(g);
				return true;
			}
			if (test.StartsWith("selectvar:"))
			{
				let spec = test.Substring(10);
				int colon = spec.IndexOf(':');
				mSelVarType.Set(spec.Substring(0, colon));
				mSelVarName.Set(spec.Substring(colon + 1));
				mSelVarActive = true;
				mSelVarSigPending = true;
				return true;
			}
			if (test == "deselect")
			{
				if (CurrentTab != null)
					CurrentTab.SelectedNodes.Clear();
				mSelVarActive = false;
				mSelClassActive = false;
				return true;
			}
			if (test.StartsWith("menu-search:"))
			{
				mNodeMenu.SelfTestSetSearch(test.Substring(12));
				return true;
			}
			if (test == "menu-tree")
			{
				mNodeMenu.SelfTestDumpTree(2);
				return true;
			}
			if (test.StartsWith("menu-open:"))
			{
				mNodeMenu.OpenPath.Set(test.Substring(10));
				return true;
			}
			return false;
		}

		/// Waits until the next stop (a stop count above `mPixStops`) or the end of the program.
		bool PixWaitStop(out bool stopped)
		{
			stopped = IsDebugStopped && mDebug.StopCount > mPixStops;
			if (stopped || (!IsDebugging && !mDebugAfterBuild && mDebugTestFrames > 2))
				return true;
			if (++mDebugTestFrames > 6000)
			{
				SelfTestCheck(false, "debugshots: no stop within 6000 frames");
				return true;
			}
			return false;
		}

		/// `debugshots` on a project whose `Main` calls `Greeter.Hello()` (Hello prints, branches on
		/// IsReady and calls Ping, which changes mCount): captures the breakpoint marker, the stop,
		/// Locals (collapsed and with `this` open), the Call Stack two and three frames deep and the
		/// Debug Output after the run.
		bool SelfTestDebugShots()
		{
			if (mSessionWait > 0)
			{
				mSessionWait--;
				return false;
			}
			let step = mPixStep++;
			switch (step)
			{
			case 0:
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(print != null, "debugshots: Hello has the print node");
				if (print == null)
					return true;
				OpenTab(mg);
				ToggleBreakpoint(mg, print);
				mStatus.Clear();
				mSessionWait = 4;
			case 1:
				if (!SelfTestShot((mPixSub == 0) ? "debug-breakpoint-set" : "debug-bp-hover"))
				{
					mPixStep--;
					return false;
				}
				if (mPixSub == 0)
				{
					mPixSub = 1; // a second capture in this step: the mouse over a node without a breakpoint
					mPixStep--;
					return false;
				}
			case 2:
				mDebugTestFrames = 0;
				mPixStops = 0;
				StartDebugging();
			case 3:
				if (!PixWaitStop(let stopped))
				{
					mPixStep--;
					return false;
				}
				SelfTestCheck(stopped, "debugshots: stopped at the breakpoint");
				if (!stopped)
					return true;
				ShowLocals = true;
				Panels.Focus(Panels.LocalsId);
				mStatus.Clear();
				mSessionWait = 6;
			case 4:
				if (!SelfTestShot("debug-stopped"))
				{
					mPixStep--;
					return false;
				}
				mSelfTestLocalsOpen = true;
				mSessionWait = 6;
			case 5:
				if (!SelfTestShot("debug-locals-expanded"))
				{
					mPixStep--;
					return false;
				}
				mSelfTestLocalsOpen = false;
				Panels.Focus(Panels.CallStackId);
				mSessionWait = 6;
			case 6:
				if (!SelfTestShot("debug-menu-stopped"))
				{
					mPixStep--;
					return false;
				}
			case 7:
				if (!SelfTestShot("debug-callstack-2"))
				{
					mPixStep--;
					return false;
				}
				mPixStops = mDebug.StopCount;
				mDebugTestFrames = 0;
				mDebug.StepOver();
			case 8, 10, 12:
				if (!PixWaitStop(let stopped))
				{
					mPixStep--;
					return false;
				}
				SelfTestCheck(stopped, scope $"debugshots: step {step} stopped ({mDebugStopWhere})");
				if (!stopped)
					return true;
				mSessionWait = 3;
			case 9:
				mPixStops = mDebug.StopCount;
				mDebugTestFrames = 0;
				mDebug.StepOver();
			case 11:
				mPixStops = mDebug.StopCount;
				mDebugTestFrames = 0;
				mDebug.StepInto();
			case 13:
				SelfTestCheck(mDebug.Frames.Count >= 3, scope $"debugshots: Call Stack has {mDebug.Frames.Count} frames");
				Panels.Focus(Panels.CallStackId);
				mSessionWait = 6;
			case 14:
				if (!SelfTestShot("debug-callstack-3"))
				{
					mPixStep--;
					return false;
				}
				Panels.Focus(Panels.LocalsId);
				mSessionWait = 6;
			case 15:
				if (!SelfTestShot("debug-stopped-inner"))
				{
					mPixStep--;
					return false;
				}
				mPixStops = mDebug.StopCount;
				mDebugTestFrames = 0;
				mDebug.Continue();
			case 16:
				if (!PixWaitStop(let stopped))
				{
					mPixStep--;
					return false;
				}
				if (stopped)
				{
					mPixStops = mDebug.StopCount;
					mDebugTestFrames = 0;
					mDebug.Continue();
					mPixStep--;
					return false;
				}
				mFocusDebugOutput = true;
				mSessionWait = 6;
			case 17:
				if (!SelfTestShot("debug-output"))
				{
					mPixStep--;
					return false;
				}
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				if (print != null)
					ToggleBreakpoint(mg, print);
			case 18:
				if (!SelfTestShot("debug-menu-idle"))
				{
					mPixStep--;
					return false;
				}
				return true;
			}
			return false;
		}

		/// `faultshot` on a project whose `Main` reads a field of a null object: no breakpoint, the
		/// run stops on the fault.
		bool SelfTestFaultShot()
		{
			if (mSessionWait > 0)
			{
				mSessionWait--;
				return false;
			}
			let step = mPixStep++;
			switch (step)
			{
			case 0:
				mDebugTestFrames = 0;
				mPixStops = 0;
				StartDebugging();
			case 1:
				if (!PixWaitStop(let stopped))
				{
					mPixStep--;
					return false;
				}
				SelfTestCheck(stopped && mDebug.Reason == .Exception, scope $"faultshot: stopped on a fault ({mDebugStopWhere})");
				if (!stopped)
					return true;
				ShowLocals = true;
				Panels.Focus(Panels.LocalsId);
				mStatus.Clear();
				mSessionWait = 8;
			case 2:
				if (!SelfTestShot("debug-fault"))
				{
					mPixStep--;
					return false;
				}
				Panels.Focus(Panels.CallStackId);
				mSessionWait = 6;
			case 3:
				if (!SelfTestShot("debug-fault-callstack"))
				{
					mPixStep--;
					return false;
				}
				Panels.Focus(Panels.CompilerResultsId);
				mSessionWait = 6;
			case 4:
				if (!SelfTestShot("debug-fault-problems"))
				{
					mPixStep--;
					return false;
				}
				StopDebugging();
				return true;
			}
			return false;
		}
	}
}
