using System;
using System.Collections;
using System.IO;
using VisualBeef.Debug;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=session,debug`: the debugger on the class `session` made (Greeter.Hello, called
	/// from the scratch project's Main): a breakpoint on the print node (the call F9 makes), Start
	/// Debugging (compile in Debug, launch), the stop on that node, a pin value and the locals,
	/// two Step Overs (each on a different node), Continue to the program's exit, the breakpoint
	/// removed again. See docs/Testing.md and docs/Debugging.md.
	extension EditorApp
	{
		int mDebugTestStep;
		int mDebugTestFrames;
		int32 mDebugTestLastNode;
		int32 mDebugTestStops;
		bool mDebugTestShot;

		MethodGraph DebugTestHello()
		{
			if (mSessionPath.IsEmpty)
				mSessionPath.AppendF("{}\\src\\Greeter.bf", mProjectRoot);
			let doc = OpenFile(mSessionPath, false);
			if (doc == null)
				return null;
			for (let mg in doc.Methods)
				if (mg.Graphable && mg.Method.Name == "Hello")
					return mg;
			return null;
		}

		/// Waits (frames) until the session stops or ends; false while still waiting.
		bool DebugTestWait(out bool stopped)
		{
			stopped = IsDebugStopped;
			if (stopped || (!IsDebugging && !mDebugAfterBuild && mDebugTestFrames > 2))
				return true;
			if (++mDebugTestFrames > 6000)
			{
				SelfTestCheck(false, "debug: no stop within 6000 frames");
				return true;
			}
			return false;
		}

		bool SelfTestDebug()
		{
			// A capture of the stop (only with VB_SHOTS set, see SelfTestShot).
			if (mDebugTestShot)
			{
				if (!SelfTestShot("debug-stopped"))
					return false;
				mDebugTestShot = false;
			}
			if (mSessionWait > 0)
			{
				mSessionWait--;
				return false;
			}
			let step = mDebugTestStep++;
			switch (step)
			{
			case 0:
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(print != null, "debug 1: Greeter.Hello has the print node");
				if (print == null)
					return true;
				OpenTab(mg);
				ToggleBreakpoint(mg, print);
				HashSet<int32> ids = scope .();
				BreakpointNodes(mg, ids);
				SelfTestCheck(ids.Contains(print.Id), "debug 1: F9 on the print node sets a breakpoint (red dot)");
				String ws = scope .();
				CurrentWorkspace(ws);
				SelfTestCheck(Settings.Project(ws).Get("breakpoints") != null, "debug 1: the breakpoint is saved in settings.json, not in the source");
				mDebugTestFrames = 0;
				StartDebugging();
				SelfTestCheck(mDebugAfterBuild, "debug 2: Start Debugging compiles in Debug first");
			case 1:
				if (!DebugTestWait(let stopped))
				{
					mDebugTestStep--;
					return false;
				}
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(stopped && print != null && DebugStopGraph == mg.Graph && DebugStopNode == print.Id,
					scope $"debug 3: stopped at the print node of Greeter.Hello ({mDebugStopWhere}, state {(mDebug != null) ? mDebug.State.ToString(.. scope .()) : "none"})");
				if (!stopped)
					return true;
				SelfTestCheck(CurrentMethod == mg, "debug 3: the Sheet of Hello is open on the stopped node");
				String value = scope .();
				let pin = FirstValueInput(print);
				bool ok = DebugPinValue(mg, pin, value);
				SelfTestCheck(ok && value.Contains("Hello"), scope $"debug 4: the print's pin value reads \"{value}\"");
				List<String> locals = scope .();
				defer { ClearAndDeleteItems!(locals); }
				mDebug.GetLocals(DebugFrame, locals);
				SelfTestCheck(locals.Contains("this"), scope $"debug 4: Locals has this ({locals.Count} locals)");
				EvalValue v = scope .();
				SelfTestCheck(mDebug.Evaluate("mCount", DebugFrame, v) && v.Value == "1", scope $"debug 4: this.mCount = {v.Value}");
				mDebugTestLastNode = DebugStopNode;
				mDebugTestStops = mDebug.StopCount;
				ShowLocals = true;
				Panels.Focus(Panels.LocalsId);
				mDebugTestShot = true;
				mStatus.Clear(); // the capture must not show a scratch path
			case 2:
				mSessionWait = 2;
				mDebugTestFrames = 0;
				mDebug.StepOver();
			case 3, 5:
				if (!DebugTestWait(let stopped))
				{
					mDebugTestStep--;
					return false;
				}
				String title = scope .();
				if (DebugStopGraph != null)
					DebugStopGraph.FindNode(DebugStopNode)?.GetTitle(title);
				SelfTestCheck(stopped && mDebug.StopCount > mDebugTestStops && DebugStopNode != mDebugTestLastNode,
					scope $"debug {(step == 3) ? 5 : 6}: Step Over stops on the next node ({mDebugStopWhere}: {title})");
				if (!stopped)
					return true;
				mDebugTestLastNode = DebugStopNode;
				mDebugTestStops = mDebug.StopCount;
				mSessionWait = 2;
			case 4:
				mDebugTestFrames = 0;
				mDebug.StepOver();
			case 6:
			{
				// Reload From Disk while stopped: the file changes under the stop. Nothing may crash, the
				// session must stay stopped and usable, and the marker must never point at the wrong node.
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(mg != null && print != null && DebugStopNode == mDebugTestLastNode && DebugStopGraph == mg.Graph, "debug 7a: stopped on a node of Hello (the Ping call) before the reload");
				if (mg == null)
					return true;
				let doc = mg.Doc;
				String path = scope .(doc.FilePath);
				String original = scope .();
				File.ReadAllText(path, original, true).IgnoreError();
				// (a) the same bytes on disk: a reload changes nothing.
				ReloadFromDisk(doc);
				SelfTestCheck(IsDebugStopped && DebugStopGraph == mg.Graph && DebugStopNode == mDebugTestLastNode, "debug 7a: reloading identical text keeps the stop marker");
				// (b) the file changed on disk (two lines inserted at the top, so every line moves).
				String changed = scope $"// edited outside\n// while stopped\n{original}";
				File.WriteAllText(path, changed).IgnoreError();
				ReloadFromDisk(doc);
				SelfTestCheck(doc.Text == changed, "debug 7b: Reload From Disk takes the new text while stopped");
				mDebugTestFrames = 0;
				mSessionWait = 3;
			}
			case 7:
			{
				bool hidden = IsDebugStopped && DebugStopGraph == null && mStatus.Contains("stop marker");
				SelfTestCheck(hidden, scope $"debug 7b: the session stays stopped, the stale marker is hidden and the status says why ({mStatus})");
				let doc = DebugTestHello()?.Doc;
				EvalValue ev = scope .();
				SelfTestCheck(mDebug.Frames.Count >= 2 && mDebug.Evaluate("mCount", DebugFrame, ev) && ev.Value == "1", "debug 7b: the call stack and values still work");
				// (c) back to the original text: the frame can be shown again on the right node.
				String path = scope .(doc.FilePath);
				String original = scope .();
				File.ReadAllText(path, original, true).IgnoreError();
				original.Remove(0, original.IndexOf('\n', original.IndexOf('\n') + 1) + 1); // drop the two inserted lines
				File.WriteAllText(path, original).IgnoreError();
				ReloadFromDisk(doc);
				ShowDebugFrame(DebugFrame, true);
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				SelfTestCheck(print != null && DebugStopGraph == mg.Graph && DebugStopNode == mDebugTestLastNode, "debug 7c: original text back, the frame shows on the same node again");
				mSessionWait = 2;
			}
			case 8:
				mSessionWait = 2;
				mDebugTestFrames = 0;
				mDebug.Continue();
			case 9:
				if (!DebugTestWait(let stopped) || stopped)
				{
					if (stopped)
						mDebug.Continue(); // another stop on the way out (a breakpoint hit again)
					mDebugTestStep--;
					return false;
				}
				SelfTestCheck(!IsDebugging && mDebug != null && mDebug.ExitCode == 0, scope $"debug 7: Continue runs the program to its end (exit code {(mDebug != null) ? mDebug.ExitCode : -1})");
				SelfTestCheck(DebugOutput.Contains("Hello"), scope $"debug 7: Debug Output has the program's print ({DebugOutput.Length} chars)");
				let mg = DebugTestHello();
				let print = (mg != null) ? FindNodeOf(mg.Graph, .Call, "WriteLine") : null;
				if (print != null)
					ToggleBreakpoint(mg, print);
				HashSet<int32> ids = scope .();
				if (mg != null)
					BreakpointNodes(mg, ids);
				SelfTestCheck(ids.IsEmpty, "debug 8: F9 again removes the breakpoint");
				return true;
			}
			return false;
		}
	}
}
