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

	/// Debug > Attach to Game... (docs/Debugging.md "Attach to game"): the running processes that
	/// have the UMP runtime loaded, what the picked one has of this workspace's mod (loaded or not,
	/// the same build, its symbol file), and the attach itself. While attached the status bar is
	/// red, Shift+F5 / the toolbar's Detach let the game go on, and closing the editor detaches.
	extension EditorApp
	{
		bool mOpenAttach;
		/// Closes the dialog on its next frame (self tests).
		bool mAttachClose;
		List<GameProcess> mAttachList = new .() ~ DeleteContainerAndItems!(_);
		int32 mAttachPick;
		double mAttachListMs;
		/// The module that marks a game a mod can be debugged in (`VB_ATTACH_MODULE` replaces it for tests).
		String mAttachModule = new .() ~ delete _;
		/// "HogwartsLegacy.exe" while attached (and after, for the detach message).
		String mAttachedName = new .() ~ delete _;
		/// Call Stack: frames without source (the game's own code) are drawn one by one, not collapsed.
		bool mExpandGameFrames;

		public bool IsAttached => IsDebugging && mDebug.Attached;

		StringView AttachModule
		{
			get
			{
				if (mAttachModule.IsEmpty)
				{
					if (Environment.GetEnvironmentVariable("VB_ATTACH_MODULE", mAttachModule) case .Err || mAttachModule.IsEmpty)
						mAttachModule.Set(GameProcesses.RuntimeModule);
				}
				return mAttachModule;
			}
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
			let sw = scope Stopwatch(true);
			GameProcesses.Find(mAttachList, AttachModule);
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

		/// What the picked game has of this workspace's mod: one line and its colour. The DLL the
		/// game loaded is matched by file name with the workspace's build output (Release first, the
		/// configuration mods are built in), and both name the same symbol file build (GUID and age
		/// of their debug record), so breakpoints by source line land in the code the game runs.
		void AttachSymbols(GameProcess gp, String outText, out uint32 color)
		{
			color = Look.Warning;
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
			{
				outText.Append("No project is open: open your mod's folder to stop on its nodes.");
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
					outText.Append("This project's mod is not compiled yet: Compile in Release and install it in the game first.");
					return;
				}
			}
			String dllName = scope .();
			Path.GetFileName(target.TargetPath, dllName);
			String loaded = scope .();
			if (!GameProcesses.FindModule(gp.ProcessId, dllName, loaded))
			{
				outText.AppendF("{} is not loaded in this game: install the mod (UMP launcher) and start the game again.", dllName);
				return;
			}
			SymbolInfo inGame = scope .();
			SymbolInfo built = scope .();
			if (!inGame.Read(loaded))
			{
				color = Look.Error;
				outText.AppendF("{} in the game has no debug information: nodes cannot stop. Compile with debug information.", dllName);
				return;
			}
			if (!File.Exists(inGame.PdbPath))
			{
				color = Look.Error;
				outText.AppendF("The symbol file of {} is missing ({}): Compile again and reinstall the mod.", dllName, inGame.PdbPath);
				return;
			}
			if (!DebugSession.IsUnder(inGame.PdbPath, ws))
			{
				// Breakpoints are placed by source path: a build made from another copy of the project
				// names that copy's files.
				outText.AppendF("{} in the game was compiled from another folder ({}): stops only work for the files of that copy. Compile this project and reinstall the mod.", dllName, inGame.PdbPath);
				return;
			}
			if (built.Read(target.TargetPath) && !inGame.SameBuild(built))
			{
				outText.AppendF("The game runs another build of {} than this project's {} output: reinstall the mod and restart the game, or stops land on the wrong nodes.", dllName, config);
				return;
			}
			color = Look.Success;
			outText.AppendF("{} is loaded and matches this project's {} build: breakpoints on its nodes will stop the game.", dllName, config);
		}

		void DrawAttachPopup()
		{
			if (mOpenAttach)
			{
				Gui.OpenPopup("Attach to Game");
				mOpenAttach = false;
			}
			Gui.igSetNextWindowSizeConstraints(.(560 * Look.Scale, 0), .(900 * Look.Scale, 700 * Look.Scale), null, null);
			if (!Gui.igBeginPopupModal("Attach to Game", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mAttachClose || IsDebugging)
			{
				mAttachClose = false;
				Gui.igCloseCurrentPopup();
			}
			float wrap = 540 * Look.Scale;
			Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
			Gui.TextDisabled(scope $"Running games with the UMP runtime ({AttachModule}). Attaching lets breakpoints on this project's nodes stop the game; the game is paused while it is stopped.");
			Gui.igPopTextWrapPos();
			Gui.igSpacing();
			GameProcess attachNow = null;
			if (mAttachList.IsEmpty)
			{
				Gui.igPushTextWrapPos(Gui.igGetCursorPosX() + wrap);
				Gui.TextColored(Look.Warning, scope $"{Icon.Warning}  No running game has the UMP runtime loaded. Start the game from the UMP launcher, wait for its main menu, then Refresh.");
				Gui.igPopTextWrapPos();
			}
			else if (Gui.igBeginTable("##attachlist", 3, TableFlags.RowBg | TableFlags.BordersInnerV | TableFlags.SizingStretchProp, .(wrap, 0), 0))
			{
				Gui.igTableSetupColumn("Game", TableColumnFlags.WidthStretch, 1.2f, 0);
				Gui.igTableSetupColumn("Process", TableColumnFlags.WidthFixed, 70 * Look.Scale, 0);
				Gui.igTableSetupColumn("Mods loaded", TableColumnFlags.WidthStretch, 2, 0);
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
						mods.Append("(none)");
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
				Gui.Tooltip("Pick a game first");
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

		/// Attaches the debugger to a running game with this workspace's breakpoints.
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
				Notify.Log(.Info, "Debug", scope $"{mDebug.SkippedImage} has no symbol file here: the debugger reads only its headers (its frames show as game code)");
			DebugOutput.AppendF("Attached to {} (pid {}) with {} breakpoint(s)\n", exeName, pid, set);
			SetStatus(scope $"Attached to {exeName}", .Info, false);
			return true;
		}
	}
}
