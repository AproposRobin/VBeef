using System;
using System.Collections;
using ImGui;
using VisualBeef.Debug;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=attach` (with `VB_ATTACH_MODULE=Debuggee.exe`): Debug > Attach to Process on the
	/// `Debuggee` fixture's workspace while the fixture runs as its own process (`Debuggee.exe loop`,
	/// started by the caller). The dialog empty (a module no process has), then listing the
	/// fixture with its symbol line; Attach; the stop on the Sleep node in Main's loop (red status,
	/// external code rows collapsed, Locals); the frames expanded; the breakpoint removed and Continue
	/// (running); Detach (the process keeps running). Captures `attach-*` with VB_SHOTS.
	extension EditorApp
	{
		int mAttachTestStep;
		int mAttachTestFrames;
		int32 mAttachTestPid;
		Node mAttachTestNode;
		MethodGraph mAttachTestMg;
		String mAttachTestShot = new .() ~ delete _;

		/// Waits for a capture named in mAttachTestShot (set by the step before).
		bool AttachTestShot()
		{
			if (mAttachTestShot.IsEmpty)
				return true;
			if (!SelfTestShot(mAttachTestShot))
				return false;
			mAttachTestShot.Clear();
			return true;
		}

		bool AttachTestWait(bool done)
		{
			if (done)
			{
				mAttachTestFrames = 0;
				return true;
			}
			if (++mAttachTestFrames > 3000)
			{
				SelfTestCheck(false, scope $"attach step {mAttachTestStep}: nothing happened within 3000 frames");
				mAttachTestFrames = 0;
				return true;
			}
			mAttachTestStep--;
			return false;
		}

		bool SelfTestAttach()
		{
			if (!AttachTestShot())
				return false;
			let step = mAttachTestStep++;
			switch (step)
			{
			case 0:
				// The fixture's Main with a breakpoint on the Sleep node of its loop.
				let doc = OpenFile(scope $"{mProjectRoot}\\src\\Program.bf", false);
				mAttachTestMg = doc?.FindMethod("Debuggee.Program.Main(String[])");
				if (mAttachTestMg == null && doc != null)
					for (let mg in doc.Methods)
						if (mg.Graphable && mg.Method.Name == "Main")
							mAttachTestMg = mg;
				mAttachTestNode = (mAttachTestMg != null) ? FindNodeOf(mAttachTestMg.Graph, .Call, "Sleep") : null;
				SelfTestCheck(mAttachTestNode != null, "attach 1: the fixture's Main has the Sleep node");
				if (mAttachTestNode == null)
					return true;
				OpenTab(mAttachTestMg);
				ToggleBreakpoint(mAttachTestMg, mAttachTestNode);
				// The empty list first: a module no process has.
				mAttachModuleOverride.Set("VbNoSuchModule.dll");
				OpenAttachDialog();
				SelfTestCheck(mAttachList.IsEmpty, "attach 1: no process has the made-up module: the dialog says so");
				mAttachTestShot.Set("attach-empty");
			case 1:
				mAttachClose = true;
				mAttachModuleOverride.Clear(); // back to VB_ATTACH_MODULE
				mAttachTestFrames = 0;
			case 2:
				if (!AttachTestWait(!Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup)))
					return false;
				OpenAttachDialog();
				let gp = AttachPicked();
				SelfTestCheck(gp != null && gp.ExeName.Equals(AttachModule, .OrdinalIgnoreCase), scope $"attach 2: the dialog lists the fixture ({mAttachList.Count} process(es) with {AttachModule}, {mAttachListMs:F0} ms)");
				if (gp == null)
					return true;
				mAttachTestPid = gp.ProcessId;
				String sym = scope .();
				AttachSymbols(gp, sym, let col);
				SelfTestCheck(col == Look.Success, scope $"attach 2: the symbol line is green: {sym}");
				mAttachTestShot.Set("attach-dialog");
			case 3:
				mAttachClose = true;
				SelfTestCheck(AttachDebug(mAttachTestPid, AttachModule), "attach 3: Attach");
				mAttachTestFrames = 0;
			case 4:
				if (!AttachTestWait(IsDebugStopped || !IsDebugging))
					return false;
				// The popup closes with the attach; the stop marks the node.
				SelfTestCheck(IsAttached && IsDebugStopped && DebugStopNode == mAttachTestNode.Id, scope $"attach 4: stopped on the Sleep node while attached ({mDebugStopWhere})");
				int sourceless = 0;
				for (let f in mDebug.Frames)
					if (!f.HasSource)
						sourceless++;
				SelfTestCheck(sourceless > 0 && !mExpandGameFrames, scope $"attach 4: {sourceless} frame(s) without source, drawn collapsed as external code");
				EvalValue v = scope .();
				SelfTestCheck(mDebug.Evaluate("g.mCount", DebugFrame, v) && v.Value == "3", scope $"attach 4: g.mCount = {v.Value}");
				Panels.Focus(Panels.CallStackId);
				mAttachTestShot.Set("attach-stopped");
			case 5:
				Panels.Focus(Panels.LocalsId);
				mAttachTestShot.Set("attach-locals");
			case 6:
				Panels.Focus(Panels.CallStackId);
				mExpandGameFrames = true;
				mAttachTestShot.Set("attach-frames");
			case 7:
				mExpandGameFrames = false;
				// Remove the breakpoint (the loop would stop again at once) and continue: running.
				ToggleBreakpoint(mAttachTestMg, mAttachTestNode);
				mDebug.Continue();
				mAttachTestFrames = 0;
			case 8:
				if (mAttachTestFrames++ < 30)
				{
					mAttachTestStep--;
					return false;
				}
				mAttachTestFrames = 0;
				Panels.Focus(Panels.DebugOutputId);
				SelfTestCheck(IsAttached && !IsDebugStopped, "attach 7: Continue without the breakpoint: the process runs, still attached");
				mAttachTestShot.Set("attach-running");
			case 9:
				StopDebugging();
				mAttachTestFrames = 0;
			case 10:
				if (!AttachTestWait(!IsDebugging))
					return false;
				SelfTestCheck(mDebug != null && mDebug.Detached && GameProcesses.IsRunning(mAttachTestPid), "attach 9: Detach ends the session and the process keeps running");
				mAttachTestShot.Set("attach-detached");
			default:
				return true;
			}
			return false;
		}
	}
}

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=attachlive` with `VB_ATTACH_FILE=<the project's main .bf>`: the live proof in a
	/// program started by its host tool with the project's DLL loaded. A breakpoint on the first Branch of
	/// the project's Tick, Attach to Process on the first listed process, the stop (the process
	/// paused), the call stack and locals logged, Step Over, the breakpoint removed and Continue,
	/// Detach (the process keeps running). Captures `live-*` with VB_SHOTS. `[ATTACHLIVE]` lines log what was seen.
	extension EditorApp
	{
		int mLiveStep;
		int mLiveFrames;
		int32 mLivePid;
		Node mLiveNode;
		MethodGraph mLiveMg;

		void LiveNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[ATTACHLIVE] {text}");

		bool LiveWait(bool done, int maxFrames = 6000)
		{
			if (done || ++mLiveFrames > maxFrames)
			{
				if (!done)
					SelfTestCheck(false, scope $"attachlive step {mLiveStep}: nothing happened within {maxFrames} frames");
				mLiveFrames = 0;
				return true;
			}
			mLiveStep--;
			return false;
		}

		bool SelfTestAttachLive()
		{
			if (!AttachTestShot())
				return false;
			let step = mLiveStep++;
			switch (step)
			{
			case 0:
				String file = scope .();
				Environment.GetEnvironmentVariable("VB_ATTACH_FILE", file).IgnoreError();
				let doc = file.IsEmpty ? null : OpenFile(file, false);
				if (doc != null)
					for (let mg in doc.Methods)
						if (mg.Graphable && mg.Method.Name == "Tick")
							mLiveMg = mg;
				// The node of the statement `VB_ATTACH_TEXT` names (default: the first Branch of Tick).
				String want = scope .();
				Environment.GetEnvironmentVariable("VB_ATTACH_TEXT", want).IgnoreError();
				if (!want.IsEmpty && doc != null && mLiveMg != null)
				{
					let at = doc.Unit.Text.IndexOf(want);
					if (at >= 0)
					{
						let line = doc.Unit.LineOf(at);
						mLiveNode = DebugMap.NodeAt(doc, line, let nodeMg);
						if (nodeMg != mLiveMg)
							mLiveNode = null;
					}
				}
				if (mLiveNode == null && mLiveMg != null)
					mLiveNode = FindNodeOf(mLiveMg.Graph, .Branch);
				SelfTestCheck(mLiveNode != null, scope $"attachlive 1: the mod's Tick has the node to stop on ('{want}', {file})");
				if (mLiveNode == null)
					return true;
				OpenTab(mLiveMg);
				ToggleBreakpoint(mLiveMg, mLiveNode);
				OpenAttachDialog();
				let gp = AttachPicked();
				SelfTestCheck(gp != null, scope $"attachlive 1: the dialog lists {mAttachList.Count} process(es) with {AttachModule} ({mAttachListMs:F0} ms)");
				if (gp == null)
					return true;
				mLivePid = gp.ProcessId;
				String mods = scope .();
				for (let m in gp.Mods)
					mods.AppendF("{} ", m);
				String sym = scope .();
				AttachSymbols(gp, sym, let col);
				LiveNote(scope $"picked {gp.ExeName} pid {gp.ProcessId}; mods: {mods}");
				LiveNote(scope $"symbols: {sym}");
				SelfTestCheck(col == Look.Success, scope $"attachlive 1: the symbol line is green: {sym}");
				mAttachTestShot.Set("live-dialog");
			case 1:
				mAttachClose = true;
				SelfTestCheck(AttachDebug(mLivePid, AttachPicked()?.ExeName ?? "process"), "attachlive 2: Attach");
				mLiveFrames = 0;
			case 2:
				if (mLiveFrames % 300 == 299 && mDebug != null)
					for (let bp in mDebug.Breakpoints)
						LiveNote(scope $"waiting: breakpoint {bp.File}:{bp.Line} bound={bp.Bound} at line {bp.BoundLine}");
				if (!LiveWait(IsDebugStopped || !IsDebugging, 2400))
					return false;
				SelfTestCheck(IsAttached && IsDebugStopped && DebugStopNode == mLiveNode.Id, scope $"attachlive 3: the process stopped on the node in the project's Tick ({mDebugStopWhere})");
				if (!IsDebugStopped)
					return true;
				int gameRows = 0;
				for (let f in mDebug.Frames)
				{
					if (!f.HasSource)
						gameRows++;
					if (@f.Index < 12)
						LiveNote(scope $"frame {@f.Index}: {f.Name} {f.File}:{f.Line}");
				}
				LiveNote(scope $"{mDebug.Frames.Count} frames, {gameRows} without source (external code)");
				List<String> locals = scope .();
				defer { ClearAndDeleteItems!(locals); }
				mDebug.GetLocals(DebugFrame, locals);
				for (let l in locals)
				{
					EvalValue v = scope .();
					mDebug.Evaluate(l, DebugFrame, v, 500);
					LiveNote(scope $"local {l} = {v.Value} ({v.Type})");
				}
				EvalValue lv = scope .();
				SelfTestCheck(mDebug.Evaluate("mLevelLogged", DebugFrame, lv, 500) && (lv.Value == "true" || lv.Value == "false"), scope $"attachlive 3: a field of the mod reads while stopped: mLevelLogged = {lv.Value}");
				EvalValue tv = scope .();
				mDebug.Evaluate("mTicks", DebugFrame, tv, 500);
				LiveNote(scope $"mTicks = {tv.Value} ({tv.Type})");
				Panels.Focus(Panels.CallStackId);
				mAttachTestShot.Set("live-stopped");
			case 3:
				Panels.Focus(Panels.LocalsId);
				mAttachTestShot.Set("live-locals");
			case 4:
				mDebug.StepOver();
				mLiveFrames = 0;
			case 5:
				if (!LiveWait(IsDebugStopped || !IsDebugging, 3000))
					return false;
				LiveNote(scope $"after Step Over: {(IsDebugStopped ? mDebugStopWhere : "not stopped")} ({(mDebug.Frames.IsEmpty ? "" : mDebug.Frames[0].File)}:{(mDebug.Frames.IsEmpty ? 0 : mDebug.Frames[0].Line)})");
				SelfTestCheck(IsDebugStopped, "attachlive 4: Step Over stops again in the mod");
				// Remove the breakpoint (Tick runs every frame) and let the process run.
				ToggleBreakpoint(mLiveMg, mLiveNode);
				if (IsDebugStopped)
					mDebug.Continue();
				mLiveFrames = 0;
			case 6:
				if (mLiveFrames++ < 120)
				{
					mLiveStep--;
					return false;
				}
				mLiveFrames = 0;
				SelfTestCheck(IsAttached && !IsDebugStopped, "attachlive 5: without the breakpoint the process runs on, still attached");
				Panels.Focus(Panels.DebugOutputId);
				mAttachTestShot.Set("live-running");
			case 7:
				StopDebugging();
				mLiveFrames = 0;
			case 8:
				if (!LiveWait(!IsDebugging, 3000))
					return false;
				SelfTestCheck(mDebug != null && mDebug.Detached && GameProcesses.IsRunning(mLivePid), "attachlive 6: Detach; the process keeps running");
				if (mDebug != null)
					LiveNote(scope $"first-chance exceptions of the process skipped while attached: {mDebug.SkippedExceptions}");
				mAttachTestShot.Set("live-detached");
			default:
				return true;
			}
			return false;
		}
	}
}
