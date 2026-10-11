using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Dockable panel names. The part after "###" is the stable ImGui id (layouts, focus calls);
	/// the visible part carries the panel's icon. Use `Panels.Focus(Panels.PropertiesId)`.
	static class Panels
	{
		public const String Outline = "\u{E065}  Outline###Outline";
		public const String Graph = "\u{E42A}  Graph###Graph";
		public const String Properties = "\u{E29A}  Properties###Properties";
		public const String ProjectBrowser = "\u{E0DC}  Project Browser###Project Browser";
		public const String BeefSource = "\u{E0C7}  Beef Source###Beef Source";
		public const String OutputLog = "\u{E20A}  Output Log###Output Log";
		/// The Problems panel (errors and warnings of the last compile). The id stays
		/// "Compiler Results" so saved layouts keep its place.
		public const String CompilerResults = "\u{E088}  Problems###Compiler Results";
		public const String FindResults = "\u{E626}  Find Results###Find Results";
		public const String Locals = "\u{E478}  Locals###Locals";
		public const String CallStack = "\u{E104}  Call Stack###Call Stack";
		public const String DebugOutput = "\u{E185}  Debug Output###Debug Output";

		public const String OutlineId = "###Outline";
		public const String GraphId = "###Graph";
		public const String PropertiesId = "###Properties";
		public const String ProjectBrowserId = "###Project Browser";
		public const String BeefSourceId = "###Beef Source";
		public const String OutputLogId = "###Output Log";
		public const String CompilerResultsId = "###Compiler Results";
		public const String FindResultsId = "###Find Results";
		public const String LocalsId = "###Locals";
		public const String CallStackId = "###Call Stack";
		public const String DebugOutputId = "###Debug Output";

		public static void Focus(StringView id) => Gui.igSetWindowFocus_Str(scope String(id));

		/// The titles of the narrow right dock, for `FitTabWidth`.
		public static String[?] Narrow = .(Properties, Locals, CallStack);

		/// Dock tabs shrink to `TabMinWidthShrink` before they scroll; ImGui's 80 px default cut
		/// "Properties" and "Call Stack" in the narrow right dock (most at 125 %). The floor is the
		/// widest title of that dock at the current font and scale, so they stay whole; a longer
		/// title in the wide bottom dock can still shrink to it (its tooltip shows the full name),
		/// and a dock too narrow for its tabs scrolls them.
		public static void FitTabWidth()
		{
			let style = Gui.igGetStyle();
			float widest = 0;
			for (let title in Narrow)
			{
				int end = title.IndexOf("###");
				let w = Gui.igCalcTextSize(title.Ptr, title.Ptr + ((end < 0) ? title.Length : end), false, -1).x;
				widest = Math.Max(widest, w);
			}
			style.TabMinWidthShrink = widest + style.FramePadding.x * 2 + 1;
		}
	}

	/// The compile button states.
	enum CompileState
	{
		NotCompiled,
		/// Needs compile: sources changed or unsaved edits.
		Unknown,
		Compiling,
		Good,
		Warnings,
		Error
	}

	/// The editor shell: theme + DPI, the toolbar under the menu bar, the status bar, the window
	/// title, toasts and the frame-pacing hints for the main loop.
	extension EditorApp
	{
		double mDpiCheckTime;
		String mWindowTitle = new .() ~ delete _;
		int mBuildLogged;
		bool mBuildToastPending;
		public ImFont* UiFont;
		float mToolbarH;
		/// The width every button would take with its label this frame, and whether the last frame
		/// found that too wide for the window: then labels are dropped (the tooltip carries them).
		float mToolbarFullW;
		bool mToolbarCompact;
		float mStatusH;
		/// Panels the Window menu can show / hide.
		public bool ShowOutputLog = true;
		public bool ShowFindResults;
		public bool ShowCompilerResults = true;
		bool mFocusCompilerResults;
		bool mFocusOutputLog;

		// ---------------------------------------------------------------- frame hooks

		/// First thing every frame (before any window is drawn).
		void ShellBeginFrame()
		{
			if (UiFont == null)
				UiFont = Gui.igGetFont();
			let now = Desktop.Now;
			// Per-monitor DPI: follow the monitor the window is on.
			if (now - mDpiCheckTime > 0.5)
			{
				mDpiCheckTime = now;
				float s = Desktop.WindowDpiScale();
				if (Math.Abs(s - Look.Scale) > 0.01f)
				{
					Look.Apply(s);
					Notify.Log(.Info, "Editor", scope $"Display scale {(int)(s * 100 + 0.5f)}%");
				}
			}
			Panels.FitTabWidth();
			StreamBuildOutput();
		}

		/// Streams BeefBuild's output into the Output Log as it arrives (category "Build").
		void StreamBuildOutput()
		{
			if (mBuild == null)
			{
				mBuildLogged = 0;
				return;
			}
			while (mBuildLogged < mBuild.Output.Count)
			{
				let line = mBuild.Output[mBuildLogged++];
				if (line.IsEmpty)
					continue;
				LogLevel level = .Verbose;
				if (line.Contains("ERROR"))
					level = .Error;
				else if (line.Contains("WARNING"))
					level = .Warning;
				// Compiler messages with a location become links in the log.
				Diagnostic found = null;
				for (let m in mBuild.Messages)
				{
					if (m.Line > 0 && line.Contains(m.Path) && line.Contains(m.Text))
					{
						found = m;
						break;
					}
				}
				if (found != null)
					Notify.LogAt(level, "Build", line, found.Path, found.Line);
				else
					Notify.Log(level, "Build", line);
			}
		}

		/// Called when a build finishes (from Frame).
		void OnBuildFinished(int errors, int warnings)
		{
			StreamBuildOutput();
			if (mBuild.Succeeded)
			{
				if (warnings > 0)
					Notify.Warn(scope $"Compile complete with {warnings} warning{(warnings == 1) ? "" : "s"}");
				else
					Notify.Success("Compile complete");
			}
			else
			{
				Notify.Error(scope $"Compile failed: {errors} error{(errors == 1) ? "" : "s"}, {warnings} warning{(warnings == 1) ? "" : "s"}");
				mFocusCompilerResults = true;
			}
		}

		/// Last thing every frame.
		void ShellEndFrame()
		{
			Notify.DrawToasts(mStatusH);
			UpdateWindowTitle();
		}

		/// The main loop keeps drawing at full rate while this is true; otherwise it sleeps until
		/// input arrives (see Desktop.PaceFrame).
		public bool WantsContinuousFrames
		{
			get
			{
				if (mBuild != null && mBuild.Running)
					return true;
				if (Notify.Animating || mCommitPending || GraphTab.Animating)
					return true;
				// A dialog is queued but not open yet (conflict / error modals open next frame).
				if (!mErrors.IsEmpty || !mConflicts.IsEmpty)
					return true;
				for (int b < 3)
					if (Gui.igIsMouseDown_Nil((int32)b))
						return true;
				// A popup (action menu, context menu, modal) animates, filters and tracks hover
				// every frame, so it must never be left on a stale frame by the idle sleep.
				if (Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup))
					return true;
				// A text field being edited (caret blink, typed characters, IME).
				if (Gui.igIsAnyItemActive())
					return true;
				return false;
			}
		}

		/// How long the idle loop may sleep: short while a text field is active (caret blink),
		/// shorter while the background indexer runs (progress in the status bar, and the result
		/// is taken within a tenth of a second).
		public int32 IdleTimeoutMs => (IsDebugging && !IsDebugStopped) ? 30 : (mNodeMenu != null && mNodeMenu.SearchPending) ? 20 : ((mIndexJob != null) ? 100 : (Gui.igIsAnyItemActive() ? 500 : 1000));

		// ---------------------------------------------------------------- compile state

		/// The last compile of the current workspace (from settings.json after a start, or from
		/// the compile that just finished) and a throttled hash of its sources.
		CompileRecord mCompRec ~ delete _;
		String mCompWs = new .() ~ delete _;
		uint64 mCompHash;
		double mCompHashAt = -100;
		bool mCompHashDirty = true;
		/// The hash taken when the running compile started (after Save All).
		uint64 mBuildHash;

		/// Forget the cached source hash (after a save, a compile or a rescan).
		void InvalidateCompileHash() { mCompHashDirty = true; }

		void LoadCompileRecord(StringView ws)
		{
			if (mCompWs == ws)
				return;
			mCompWs.Set(ws);
			delete mCompRec;
			mCompRec = null;
			mCompHashDirty = true;
			let text = Settings.ProjectValue(ws, "compile");
			if (!text.IsEmpty)
				mCompRec = CompileRecord.Decode(text);
		}

		/// Stores the result of the compile that just ended (hash = the sources it was built from).
		void StoreCompileRecord(StringView ws, bool ok, StringView config, int errors, int warnings)
		{
			let rec = new CompileRecord();
			rec.Ok = ok;
			rec.Config.Set(config);
			rec.Time = DateTime.UtcNow.Ticks;
			rec.Hash = mBuildHash;
			rec.Errors = (int32)errors;
			rec.Warnings = (int32)warnings;
			delete mCompRec;
			mCompRec = rec;
			mCompWs.Set(ws);
			String enc = scope .();
			rec.Encode(enc);
			Settings.Load();
			Settings.Project(ws).Set("compile", Json.NewString(enc));
			Settings.Save();
		}

		public CompileState GetCompileState()
		{
			if (mBuild != null && mBuild.Running)
				return .Compiling;
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
				return .NotCompiled;
			LoadCompileRecord(ws);
			if (mCompRec == null)
				return .NotCompiled;
			bool unsaved = false;
			for (let d in mDocs)
				if (d.Modified)
					unsaved = true;
			if (!unsaved)
			{
				double now = Gui.igGetTime();
				if (mCompHashDirty || now - mCompHashAt > 3)
				{
					mCompHash = CompileRecord.HashWorkspace(ws);
					mCompHashAt = now;
					mCompHashDirty = false;
				}
			}
			String cfg = scope .();
			ResolveCompileConfig(ws, cfg);
			switch (CompileRecord.Decide(mCompRec, mCompHash, unsaved, cfg))
			{
			case .NotCompiled: return .NotCompiled;
			case .NeedsCompile: return .Unknown;
			case .Failed: return .Error;
			case .UpToDate: return (mCompRec.Warnings > 0) ? .Warnings : .Good;
			}
		}

		static uint32 CompileColor(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return Look.ForegroundDim;
			case .Unknown: return Look.AccentYellow;
			case .Compiling: return Look.AccentBlue;
			case .Good: return Look.Success;
			case .Warnings: return Look.Warning;
			case .Error: return Look.Error;
			}
		}

		static StringView CompileBadge(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return Icon.CircleHelp;
			case .Unknown: return Icon.CircleHelp;
			case .Compiling: return Icon.LoaderCircle;
			case .Good: return Icon.CircleCheck;
			case .Warnings: return Icon.TriangleAlert;
			case .Error: return Icon.CircleX;
			}
		}

		StringView CompileTip(CompileState s)
		{
			switch (s)
			{
			case .NotCompiled: return "Not compiled yet (F7)";
			case .Unknown: return "Needs compile: the sources changed since the last compile (F7)";
			case .Compiling: return "Compiling...";
			case .Good: return "Up to date: the sources match the last successful compile";
			case .Warnings: return "Up to date, with warnings from the last compile";
			case .Error: return "The last compile failed and the sources have not changed since";
			}
		}

		/// The status bar text for a compile state.
		void CompileText(CompileState s, String outText)
		{
			switch (s)
			{
			case .NotCompiled: outText.Append("Not compiled");
			case .Unknown: outText.Append("Needs compile");
			case .Compiling: outText.Append("Compiling...");
			case .Good: outText.Append("Up to date");
			case .Warnings: outText.Append("Up to date, with warnings");
			case .Error:
				int n = (mCompRec != null) ? mCompRec.Errors : 0;
				outText.AppendF("Compile failed ({} error{})", n, (n == 1) ? "" : "s");
			}
		}

		// ---------------------------------------------------------------- toolbar

		/// A UE toolbar button: icon + label, flat until hovered. Returns true when clicked.
		bool ToolbarButton(StringView id, StringView icon, StringView labelIn, StringView tipIn, bool enabled = true, uint32 iconColor = 0, bool active = false, StringView badge = default, uint32 badgeColor = 0)
		{
			float fs = Gui.igGetFontSize();
			var label = labelIn;
			var tip = tipIn;
			float iconSize = fs * 1.25f;
			float padX = fs * 0.55f;
			float labelW = label.IsEmpty ? 0 : Gui.CalcTextSize(label).x;
			mToolbarFullW += padX * 2 + iconSize + (label.IsEmpty ? 0 : (fs * 0.4f + labelW)) + 2 * Look.Scale;
			String compactTip = scope .();
			if (mToolbarCompact && !label.IsEmpty && id != "config")
			{
				compactTip.AppendF("{}\n{}", label, tip);
				tip = compactTip;
				label = "";
				labelW = 0;
			}
			float w = padX * 2 + iconSize + (label.IsEmpty ? 0 : (fs * 0.4f + labelW));
			float h = mToolbarH - fs * 0.5f;
			let pos = Gui.igGetCursorScreenPos();
			Gui.PushID(id);
			Gui.igBeginDisabled(!enabled);
			bool clicked = Gui.igInvisibleButton("##tb", .(w, h), ButtonFlags.MouseButtonLeft);
			bool hovered = Gui.igIsItemHovered(0);
			bool held = Gui.igIsItemActive();
			Gui.igEndDisabled();
			let dl = Gui.igGetWindowDrawList();
			if (active || hovered || held)
				Gui.ImDrawList_AddRectFilled(dl, pos, pos + ImVec2(w, h), held ? Look.PrimaryPress : (active ? Look.Header : Look.Dropdown), 4 * Look.Scale, 0);
			uint32 fg = enabled ? (hovered ? Look.ForegroundHover : Look.Foreground) : Gui.Color(90, 90, 90);
			uint32 ic = (iconColor != 0 && enabled) ? iconColor : fg;
			float cy = pos.y + h * 0.5f;
			let iconPos = ImVec2(pos.x + padX, cy - iconSize * 0.5f);
			Gui.DrawText(dl, iconPos, ic, icon, iconSize);
			if (!badge.IsEmpty)
			{
				float bs = fs * 0.8f;
				let bp = ImVec2(iconPos.x + iconSize - bs * 0.55f, iconPos.y + iconSize - bs * 0.8f);
				Gui.ImDrawList_AddCircleFilled(dl, bp + ImVec2(bs * 0.5f, bs * 0.5f), bs * 0.55f, Look.Title, 0);
				Gui.DrawText(dl, bp, badgeColor, badge, bs);
			}
			if (!label.IsEmpty)
				Gui.DrawText(dl, .(iconPos.x + iconSize + fs * 0.4f, cy - fs * 0.5f), fg, label);
			if (hovered && !tip.IsEmpty)
				Gui.Tooltip(tip);
			Gui.PopID();
			Gui.SameLine(0, 2 * Look.Scale);
			return clicked && enabled;
		}

		void ToolbarSeparator()
		{
			let pos = Gui.igGetCursorScreenPos();
			float h = mToolbarH - Gui.igGetFontSize() * 0.5f;
			mToolbarFullW += 12 * Look.Scale;
			let dl = Gui.igGetWindowDrawList();
			float x = pos.x + 5 * Look.Scale;
			Gui.ImDrawList_AddLine(dl, .(x, pos.y + h * 0.18f), .(x, pos.y + h * 0.82f), Look.Dropdown, 1);
			Gui.igDummy(.(10 * Look.Scale, h));
			Gui.SameLine(0, 2 * Look.Scale);
		}

		void DrawToolbar()
		{
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			mToolbarH = Math.Round(fs * 2.5f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(6 * Look.Scale, fs * 0.25f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Panel);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBToolbar", vp, Dir.Up, mToolbarH, flags))
			{
				Gui.igPopStyleVar(1);
				mToolbarFullW = 0;
				let state = GetCompileState();
				String cfgWs = scope .();
				CurrentWorkspace(cfgWs);
				String cfg = scope .();
				String cfgReason = scope .();
				if (!cfgWs.IsEmpty)
					ResolveCompileConfig(cfgWs, cfg, cfgReason);
				if (ToolbarButton("compile", Icon.Compile, "Compile", scope $"Compile (F7): {(cfg.IsEmpty ? "no workspace" : cfg)}\n{CompileTip(state)}", true, 0, false, CompileBadge(state), CompileColor(state)))
					Compile();
				// Configuration dropdown next to Compile (UMP mods must be built Release).
				if (ToolbarButton("config", Icon.ChevronDown, cfg.IsEmpty ? "Config" : cfg, scope $"Compile configuration: {(cfg.IsEmpty ? "no workspace" : cfg)}{(cfgReason.IsEmpty ? "" : " (")}{cfgReason}{(cfgReason.IsEmpty ? "" : ")")}\nClick to choose Debug or Release for this project", !cfgWs.IsEmpty))
					Gui.OpenPopup("##configmenu");
				if (Gui.igBeginPopup("##configmenu", 0))
				{
					DrawConfigItems();
					Gui.EndPopup();
				}
				DrawDebugToolbar();
				bool canSave = !Doc.FilePath.IsEmpty;
				if (ToolbarButton("save", Icon.Save, "Save", "Save the current file (Ctrl+S)", canSave, 0, false,
					(canSave && Doc.Modified) ? Icon.Circle : default, Look.Warning))
					Save();
				if (ToolbarButton("saveall", Icon.SaveAll, "", "Save All (Ctrl+Shift+S)", ModifiedCount > 0))
					SaveAll();
				if (ToolbarButton("browse", Icon.Browse, "Browse", "Show the current asset in the Project Browser (Ctrl+B)", !Doc.FilePath.IsEmpty))
					BrowseToCurrent();
				{
					String focusType = scope .();
					GetFocusType(focusType);
					if (ToolbarButton("classsettings", Icon.SlidersHorizontal, "Type Settings", "Parent class, interfaces, modifiers, attributes of the class being edited (Properties)", !focusType.IsEmpty, 0, mSelClassActive))
						SelectTypeSettings(focusType);
				}
				ToolbarSeparator();
				if (ToolbarButton("find", Icon.Find, "Find", "Find in Sheets: search the whole project (Ctrl+Shift+F)", !mProjectRoot.IsEmpty, 0, ShowFindResults))
					OpenFindResults();
				ToolbarSeparator();
				let tab = CurrentTab;
				bool haveGraph = tab != null && CurrentMethod != null;
				if (ToolbarButton("arrange", Icon.Arrange, "Arrange", "Auto-arrange the graph by execution flow (layered)", haveGraph))
					ArrangeCurrentGraph();
				if (ToolbarButton("align", Icon.AlignStartVertical, "Align", "Align and distribute the selected nodes", haveGraph && tab.SelectedNodes.Count > 1))
					Gui.OpenPopup("##alignmenu");
				DrawAlignMenu(tab);
				if (ToolbarButton("minimap", Icon.Minimap, "", "Toggle the graph minimap (M)", haveGraph, 0, Prefs.ShowMinimap))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				if (ToolbarButton("snap", Icon.Magnet, "", scope $"Snap nodes to the grid: {Prefs.GridSnap ? "on" : "off"}", true, 0, Prefs.GridSnap))
				{
					Prefs.GridSnap = !Prefs.GridSnap;
					Prefs.Save();
				}
				ToolbarSeparator();
				if (ToolbarButton("prefs", Icon.Settings, "", "Editor Preferences", true))
					OpenPreferences();

				// Too wide for the window (more buttons while debugging, a big UI scale): drop the
				// labels from the next frame on; room for the asset name is not counted.
				mToolbarCompact = mToolbarFullW > Gui.igGetWindowWidth() - 14 * Look.Scale;

				// Asset name on the right, like UE's tab of the open Blueprint.
				String asset = scope .();
				GetCurrentAssetName(asset);
				if (!asset.IsEmpty)
				{
					String text = scope .();
					text.AppendF("{}{}", asset, (Doc.Modified ? " *" : ""));
					float tw = Gui.CalcTextSize(text).x + fs * 1.6f;
					float avail = Gui.igGetContentRegionAvail().x;
					if (avail > tw + 10)
					{
						Gui.SameLine(Gui.igGetCursorPos().x + avail - tw - 6 * Look.Scale);
						let pos = Gui.igGetCursorScreenPos();
						let dl = Gui.igGetWindowDrawList();
						float cy = pos.y + (mToolbarH - fs * 0.5f) * 0.5f;
						Gui.DrawText(dl, .(pos.x, cy - fs * 0.5f), Look.AccentBlue, Icon.Class);
						Gui.DrawText(dl, .(pos.x + fs * 1.6f, cy - fs * 0.5f), Look.ForegroundDim, text);
					}
				}
				// 1 px separator under the toolbar
				let wp = Gui.igGetWindowPos();
				let ws = Gui.igGetWindowSize();
				Gui.ImDrawList_AddLine(Gui.igGetWindowDrawList(), .(wp.x, wp.y + ws.y - 1), .(wp.x + ws.x, wp.y + ws.y - 1), Look.WindowBorder, 1);
			}
			else
				Gui.igPopStyleVar(1);
			Gui.End();
			Gui.igPopStyleColor(1);
		}

		/// "Player" for the open class, the enum editor's type or the file name.
		void GetCurrentAssetName(String outName)
		{
			let mg = CurrentMethod;
			if (mg != null && mg.Owner != null)
			{
				outName.Append(mg.Owner.Name);
				return;
			}
			if (mActiveAssetTab != null)
			{
				outName.Append(mActiveAssetTab.TypeName);
				return;
			}
			if (!Doc.FilePath.IsEmpty)
				Path.GetFileNameWithoutExtension(Doc.FilePath, outName);
		}

		/// Toolbar "Browse": shows the current file's folder in the Project Browser with its tile selected.
		void BrowseToCurrent()
		{
			if (Doc.FilePath.IsEmpty)
				return;
			String dir = scope .();
			Path.GetDirectoryPath(Doc.FilePath, dir).IgnoreError(); // no parent: dir stays empty
			NavigateCB(dir);
			String typeName = scope .();
			GetCurrentAssetName(typeName);
			String key = scope .();
			CBItem.MakeKey(.Class, Doc.FilePath, typeName, key);
			CBSelectOnly(key);
			mCBScrollTo.Set(key);
			Panels.Focus(Panels.ProjectBrowserId);
		}

		// ---------------------------------------------------------------- status bar

		void DrawStatusBar()
		{
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			mStatusH = Math.Round(fs * 1.75f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(4 * Look.Scale, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(8 * Look.Scale, fs * 0.2f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Title);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBStatusBar", vp, Dir.Down, mStatusH, flags))
			{
				Gui.igSetCursorPosY((mStatusH - Gui.igGetFrameHeight()) * 0.5f);
				Gui.igPushStyleColor_U32(Col.Button, Gui.Color(0, 0, 0, 0));
				Gui.igPushStyleColor_U32(Col.Border, Gui.Color(0, 0, 0, 0));
				// UE: Project Drawer + Output Log buttons bottom-left.
				if (Gui.Button(scope $"{Icon.FolderOpen}  Project Drawer"))
					ToggleProjectDrawer();
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Open the Project Drawer (Ctrl+Space)");
				Gui.SameLine(0, 2);
				if (Gui.Button(scope $"{Icon.Log}  Output Log"))
				{
					ShowOutputLog = true;
					mFocusOutputLog = true;
				}
				Gui.igPopStyleColor(2);

				// Background indexing progress (with cancel), then the latest status text.
				DrawIndexingStatus();
				DrawDebugStatus();

				// Right side: compile state and save state, like UE's bottom-right corner.
				let state = GetCompileState();
				int modified = ModifiedCount;
				String compileText = scope .();
				CompileText(state, compileText);
				String saveText = scope .();
				if (Doc.FilePath.IsEmpty && mDocs.IsEmpty)
					saveText.Append("No file open");
				else if (modified > 0)
					saveText.AppendF("{} Unsaved", modified);
				else
					saveText.Append("All Saved");
				// Read-only (viewer) mode: a lock badge before the compile / save state.
				bool locked = FileSafety.ReadOnlyProject;
				StringView lockText = "Read-only";
				float w0 = locked ? (Gui.CalcTextSize(lockText).x + fs * 1.6f + 24 * Look.Scale) : 0;
				float w1 = Gui.CalcTextSize(compileText).x + fs * 1.6f;
				float w2 = Gui.CalcTextSize(saveText).x + fs * 1.6f;
				float total = w0 + w1 + w2 + 24 * Look.Scale;
				// The latest status text, cut with "..." where the right side starts (a long path
				// must not run under the compile state); the whole text is the tooltip.
				if (!mStatus.IsEmpty && Gui.igGetTime() - mStatusTime < 8)
				{
					Gui.SameLine(0, 16 * Look.Scale);
					float room = Gui.igGetWindowWidth() - total - 8 * Look.Scale - Gui.igGetCursorPos().x - 16 * Look.Scale;
					if (room > fs * 2)
					{
						String shown = scope .();
						FitText(mStatus, room, shown);
						Gui.igAlignTextToFramePadding();
						Gui.TextColored(Look.ForegroundDim, shown);
						if (shown.Length != mStatus.Length && Gui.igIsItemHovered(0))
							Gui.Tooltip(mStatus);
					}
				}
				Gui.SameLine(Math.Max(Gui.igGetCursorPos().x + 10, Gui.igGetWindowWidth() - total - 8 * Look.Scale));
				let dl = Gui.igGetWindowDrawList();
				var p = Gui.igGetCursorScreenPos();
				float ty = Gui.igGetWindowPos().y + (mStatusH - fs) * 0.5f;
				if (locked)
				{
					Gui.DrawText(dl, .(p.x, ty), Look.Warning, Icon.Lock);
					Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), Look.Warning, lockText);
					p.x += w0;
				}
				Gui.DrawText(dl, .(p.x, ty), CompileColor(state), CompileBadge(state));
				Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), Look.Foreground, compileText);
				p.x += w1 + 24 * Look.Scale;
				uint32 saveCol = (modified > 0) ? Look.Warning : Look.Foreground;
				Gui.DrawText(dl, .(p.x, ty), saveCol, (modified > 0) ? Icon.Circle : Icon.Save);
				Gui.DrawText(dl, .(p.x + fs * 1.4f, ty), saveCol, saveText);
				Gui.igDummy(.(total, fs));
			}
			Gui.End();
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(2);
		}

		// ---------------------------------------------------------------- window title

		/// "VisualBeef alpha - <Project> - <Class> *", following the active tab.
		void UpdateWindowTitle()
		{
			String title = scope .(scope $"{VisualBeefInfo.Name} {VisualBeefInfo.Channel}");
			if (!mProjectRoot.IsEmpty)
			{
				String name = scope .();
				Path.GetFileName(mProjectRoot, name);
				title.AppendF(" - {}", name);
			}
			String asset = scope .();
			GetCurrentAssetName(asset);
			if (!asset.IsEmpty)
			{
				title.AppendF(" - {}", asset);
				if (!Doc.FilePath.IsEmpty && Doc.Modified)
					title.Append(" *");
			}
			if (title != mWindowTitle)
			{
				mWindowTitle.Set(title);
				Desktop.SetTitle(title);
			}
		}
	}
}
