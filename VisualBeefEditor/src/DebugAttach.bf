using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using ImGui;
using VisualBeef.Debug;

namespace VisualBeef.Editor
{
	/// The one ImGui call the dialog needs that the shared binding does not declare (the host
	/// exports every cimgui function).
	static class AttachGui
	{
		[CLink] public static extern void igTableHeadersRow();
	}

	/// Debug > Attach to Process... (docs/Debugging.md "Attach to a process"): the running processes
	/// that have the attach module loaded (`attach.module` of the project's .vbproject, else the
	/// project's own DLL), what the picked one has of this workspace's build (loaded or not, the same
	/// build, its symbol file), and the attach itself. While attached the status bar is red,
	/// Shift+F5 / the toolbar's Detach let the process go on, and closing the editor detaches.
	extension EditorApp
	{
		bool mOpenAttach;
		/// Closes the dialog on its next frame (self tests).
		bool mAttachClose;
		List<GameProcess> mAttachList = new .() ~ DeleteContainerAndItems!(_);
		int32 mAttachPick;
		double mAttachListMs;
		/// The module that marks a process this project can be debugged in: `VB_ATTACH_MODULE` (tests),
		/// else `attach.module` of the project's .vbproject, else the project's own output file.
		String mAttachModule = new .() ~ delete _;
		/// Self tests: replaces everything above while not empty.
		String mAttachModuleOverride = new .() ~ delete _;
		/// The project's own output file name ("HelloTool.dll"; "" before it is compiled).
		String mAttachOwn = new .() ~ delete _;
		/// `attach.hint` of the .vbproject: what to do when no process has the module.
		String mAttachHint = new .() ~ delete _;
		/// "Game.exe" while attached (and after, for the detach message).
		String mAttachedName = new .() ~ delete _;
		/// Call Stack: frames without source (the process's own code) are drawn one by one, not collapsed.
		bool mExpandGameFrames;

		public bool IsAttached => IsDebugging && mDebug.Attached;

		StringView AttachModule
		{
			get
			{
				if (mAttachModule.IsEmpty)
					ResolveAttachModule();
				return mAttachModule;
			}
		}

		/// The project's output (Release first) as a file name, or "" when it is not compiled.
		void ProjectOutputName(String outName, String outConfig = null)
		{
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
				return;
			for (let config in StringView[2]("Release", "Debug"))
			{
				DebugTarget target = scope .();
				String err = scope .();
				if (target.ResolveOutput(ws, config, err))
				{
					Path.GetFileName(target.TargetPath, outName);
					outConfig?.Set(config);
					return;
				}
			}
		}

		void ResolveAttachModule()
		{
			mAttachModule.Clear();
			mAttachOwn.Clear();
			mAttachHint.Clear();
			ProjectOutputName(mAttachOwn);
			VisualBeef.Document.ProjectManifest manifest = scope .();
			if (!mProjectRoot.IsEmpty && manifest.Read(mProjectRoot))
			{
				mAttachModule.Set(manifest.AttachModule);
				mAttachHint.Set(manifest.AttachHint);
			}
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_ATTACH_MODULE", env) case .Ok && !env.IsEmpty)
				mAttachModule.Set(env);
			if (mAttachModule.IsEmpty)
				mAttachModule.Set(mAttachOwn);
			if (!mAttachModuleOverride.IsEmpty)
				mAttachModule.Set(mAttachModuleOverride);
		}

		public void OpenAttachDialog()
		{
			if (IsDebugging || mDebugAfterBuild)
				return;
			if (!DebugEngine.Load(mBeefBuildPath))
			{
				Notify.Error(scope $"{DebugEngine.NeedBeef} ({DebugEngine.LoadError})");
				return;
			}
			RefreshAttachList();
			mOpenAttach = true;
		}

		void RefreshAttachList()
		{
			let keep = mAttachPick;
			ClearAndDeleteItems!(mAttachList);
			ResolveAttachModule();
			let sw = scope Stopwatch(true);
			if (!mAttachModule.IsEmpty)
			{
				StringView[1] own = .(mAttachOwn);
				GameProcesses.Find(mAttachList, mAttachModule, own);
			}
			mAttachListMs = sw.Elapsed.TotalMilliseconds;
			mAttachPick = 0;
			for (let gp in mAttachList)
				if (gp.ProcessId == keep)
					mAttachPick = keep;
			if (mAttachPick == 0 && !mAttachList.IsEmpty)
				mAttachPick = mAttachList[0].ProcessId;
			Notify.Log(.Verbose, "Debug", scope $"Attach: {mAttachList.Count} process(es) with {AttachModule} ({mAttachListMs:F0} ms)");
		}

		GameProcess AttachPicked()
		{
			for (let gp in mAttachList)
				if (gp.ProcessId == mAttachPick)
					return gp;
			return null;
		}

		/// What the picked process has of this workspace's build: one line and its colour. The DLL the
		/// process loaded is matched by file name with the workspace's build output (Release first),
		/// and both name the same symbol file build (GUID and age of their debug record), so
		/// breakpoints by source line land in the code the process runs.
		void AttachSymbols(GameProcess gp, String outText, out uint32 color)
		{
			color = Look.Warning;
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
			{
				outText.Append("No project is open: open the project's folder to stop on its nodes.");
				return;
			}
			DebugTarget target = scope .();
			String err = scope .();
			StringView config = "Release";
			if (!target.ResolveOutput(ws, config, err))
			{
				config = "Debug";
				err.Clear();
				if (!target.ResolveOutput(ws, config, err))
				{
					outText.Append("This project is not compiled yet: Compile it, and put the output where the program loads it, first.");
					return;
				}
			}
			String dllName = scope .();
			Path.GetFileName(target.TargetPath, dllName);
			String loaded = scope .();
			if (!GameProcesses.FindModule(gp.ProcessId, dllName, loaded))
			{
				outText.AppendF("{} is not loaded in this process: put it where the program loads it and start the program again.", dllName);
				return;
			}
			SymbolInfo inGame = scope .();
			SymbolInfo built = scope .();
			if (!inGame.Read(loaded))
			{
				color = Look.Error;
				outText.AppendF("{} in the process has no debug information: nodes cannot stop. Compile with debug information.", dllName);
				return;
			}
			if (!File.Exists(inGame.PdbPath))
			{
				color = Look.Error;
				outText.AppendF("The symbol file of {} is missing ({}): Compile again and put the new output in place.", dllName, inGame.PdbPath);
				return;
			}
			if (!DebugSession.IsUnder(inGame.PdbPath, ws))
			{
				// Breakpoints are placed by source path: a build made from another copy of the project
				// names that copy's files.
				outText.AppendF("{} in the process was compiled from another folder ({}): stops only work for the files of that copy. Compile this project and put its output in place.", dllName, inGame.PdbPath);
				return;
			}
			if (built.Read(target.TargetPath) && !inGame.SameBuild(built))
			{
				outText.AppendF("The process runs another build of {} than this project's {} output: put the new output in place and restart the program, or stops land on the wrong nodes.", dllName, config);
				return;
			}
			color = Look.Success;
			outText.AppendF("{} is loaded and matches this project's {} build: breakpoints on its nodes will stop the process.", dllName, config);
		}

		void DrawAttachPopup()
		{
			if (mOpenAttach)
			{
				Gui.OpenPopup("Attach to Process");
				mOpenAttach = false;
			}
			Gui.igSetNextWindowSizeConstraints(.(560 * Look.Scale, 0), .(900 * Look.Scale, 700 * Look.Scale), null, null);
			if (!Gui.igBeginPopupModal("Attach to Process", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mAttachClose || IsDebugging)
			{
				mAttachClose = false;
				Gui.igCloseCurrentPopup();
			}
			float wrap = 540 * Look.Scale;
			Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
			if (AttachModule.IsEmpty)
				Gui.TextDisabled("Compile the project first: the dialog lists the running processes that have its output loaded (or the module its .vbproject names under attach).");
			else
				Gui.TextDisabled(scope $"Running processes with {AttachModule} loaded. Attaching lets breakpoints on this project's nodes stop the process; it is paused while it is stopped.");
			Gui.igPopTextWrapPos();
			Gui.igSpacing();
			GameProcess attachNow = null;
			if (mAttachList.IsEmpty)
			{
				Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
				String hint = scope .(mAttachHint);
				if (hint.IsEmpty)
					hint.Set("Start the program that loads this project, then Refresh.");
				String whatModule = scope .(AttachModule);
				if (whatModule.IsEmpty)
					whatModule.Set("the project's output");
				Gui.TextColored(Look.Warning, scope $"{Icon.Warning}  No running process has {whatModule} loaded. {hint}");
				Gui.igPopTextWrapPos();
			}
			else if (Gui.igBeginTable("##attachlist", 3, TableFlags.RowBg | TableFlags.BordersInnerV | TableFlags.SizingStretchProp, .(wrap, 0), 0))
			{
				Gui.igTableSetupColumn("Program", TableColumnFlags.WidthStretch, 1.2f, 0);
				Gui.igTableSetupColumn("Process", TableColumnFlags.WidthFixed, 70 * Look.Scale, 0);
				Gui.igTableSetupColumn("This project", TableColumnFlags.WidthStretch, 2, 0);
				AttachGui.igTableHeadersRow();
				for (let gp in mAttachList)
				{
					Gui.PushID(gp.ProcessId);
					Gui.igTableNextRow(0, 0);
					Gui.igTableSetColumnIndex(0);
					String label = scope $"{Icon.Monitor}  {gp.ExeName}###row";
					if (Gui.Selectable(label, gp.ProcessId == mAttachPick, SelectableFlags.AllowDoubleClick | (1 << 1) /* SpanAllColumns */))
					{
						mAttachPick = gp.ProcessId;
						if (Gui.igIsMouseDoubleClicked_Nil(0))
							attachNow = gp;
					}
					Gui.igTableSetColumnIndex(1);
					CellText(scope $"{gp.ProcessId}", 0, true);
					Gui.igTableSetColumnIndex(2);
					String mods = scope .();
					for (let m in gp.Mods)
					{
						if (!mods.IsEmpty)
							mods.Append(", ");
						Path.GetFileName(m, mods);
					}
					if (mods.IsEmpty)
						mods.Append("(not loaded)");
					String fit = scope .();
					FitText(mods, Math.Max(8 * Look.Scale, Gui.igGetContentRegionAvail().x), fit);
					CellText(fit, 0, gp.Mods.IsEmpty);
					if (Gui.igIsItemHovered(0) && !gp.Mods.IsEmpty)
					{
						String all = scope .();
						for (let m in gp.Mods)
							all.AppendF("{}{}", all.IsEmpty ? "" : "\n", m);
						Gui.Tooltip(all);
					}
					Gui.PopID();
				}
				Gui.igEndTable();
			}
			let picked = AttachPicked();
			if (picked != null)
			{
				Gui.igSpacing();
				String sym = scope .();
				AttachSymbols(picked, sym, let col);
				Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
				Gui.TextColored(col, scope $"{(col == Look.Success) ? Icon.Ok : (col == Look.Error) ? Icon.Error : Icon.Warning}  {sym}");
				Gui.igPopTextWrapPos();
			}
			Gui.igSpacing();
			Gui.Separator();
			Gui.igSpacing();
			Gui.igBeginDisabled(picked == null);
			if (Gui.Button(scope $"{Icon.Plug}  Attach", .(120 * Look.Scale, 0)) && picked != null)
				attachNow = picked;
			Gui.igEndDisabled();
			if (picked == null && Gui.igIsItemHovered(1 << 10))
				Gui.Tooltip("Pick a process first");
			Gui.SameLine();
			if (Gui.Button(scope $"{Icon.RefreshCw}  Refresh", .(120 * Look.Scale, 0)))
				RefreshAttachList();
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
			if (attachNow != null)
			{
				Gui.igCloseCurrentPopup();
				AttachDebug(attachNow.ProcessId, attachNow.ExeName);
			}
			Gui.EndPopup();
		}

		/// Attaches the debugger to a running process with this workspace's breakpoints.
		public bool AttachDebug(int32 pid, StringView exeName)
		{
			if (IsDebugging || mDebugAfterBuild)
				return false;
			String ws = scope .();
			CurrentWorkspace(ws);
			let set = NewSession(ws);
			DebugOutput.Clear();
			ClearStop();
			mAttachedName.Set(exeName);
			String err = scope .();
			if (!mDebug.Attach(pid, err))
			{
				Notify.Error(scope $"Could not attach to {exeName} ({pid}): {err}");
				return false;
			}
			mDebugEverStarted = true;
			ShowDebugOutput = true;
			ShowCallStack = true;
			let line = scope $"Attached to {exeName} (pid {pid}) with {set} breakpoint(s); engine {DebugEngine.DllPath}";
			Notify.Log(.Info, "Debug", line);
			if (!mDebug.SkippedImage.IsEmpty)
				Notify.Log(.Info, "Debug", scope $"{mDebug.SkippedImage} has no symbol file here: the debugger reads only its headers (its frames show as code without source)");
			DebugOutput.AppendF("Attached to {} (pid {}) with {} breakpoint(s)\n", exeName, pid, set);
			SetStatus(scope $"Attached to {exeName}", .Info, false);
			return true;
		}
	}
}
