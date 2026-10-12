using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// Hidden self tests that drive the running editor through the same calls its UI makes (no
	/// window messages needed), for checks the test runner cannot make because they live in the
	/// editor: VB_SELFTEST=rename-undo,move-undo,find-refs,openall (any subset, in that order).
	/// Results go to the Output Log / session log as `[SELFTEST] ok ...` / `[SELFTEST] FAIL ...`
	/// and end with `[SELFTEST] done failures=N`. See docs/Testing.md (Verifying the UI).
	///
	/// rename-undo and move-undo and find-refs expect the sample project the docs describe: a
	/// `Player` class with a field `mHealth` used in `Player.Hit(int)` and in another file.
	extension EditorApp
	{
		int mSelfTestStep = -1;
		List<String> mSelfTests = new .() ~ DeleteContainerAndItems!(_);
		int mSelfTestFailures;
		int mSelfTestWait;
		/// openall: the methods still to open, as (file, method key).
		List<(String path, String key)> mSelfTestQueue = new .() ~ { for (let q in _) { delete q.path; delete q.key; } delete _; };
		int mSelfTestOpened;
		int mSelfTestDrawsAtOpen;
		int mSelfTestUndrawn;
		String mSelfTestA = new .() ~ delete _;
		String mSelfTestB = new .() ~ delete _;
		/// `override-menu:<Type>`: Outline opens that type's Override dropdown on its next draw.
		String mSelfTestOverrideMenu = new .() ~ delete _;
		/// `close-popups`: the next frame closes the Add Variable dialog (after its capture).
		bool mSelfTestClosePopups;

		void SelfTestCheck(bool ok, StringView what)
		{
			if (!ok)
				mSelfTestFailures++;
			Notify.Log(ok ? .Info : .Error, "SelfTest", scope $"[SELFTEST] {(ok ? "ok  " : "FAIL")} {what}");
		}

		SourceDocument SelfTestDocWithType(StringView typeName)
		{
			for (let f in Index.Files)
				for (let t in f.Types)
					if (t.Name == typeName)
						return OpenFile(f.Path, false);
			return null;
		}

		SourceDocument SelfTestOtherDoc(SourceDocument not, StringView word)
		{
			for (let f in Index.Files)
			{
				if (ProjectIndex.SamePath(f.Path, not.FilePath))
					continue;
				String text = scope .();
				if (File.ReadAllText(f.Path, text, true) case .Ok && text.Contains(word))
					return OpenFile(f.Path, false);
			}
			return null;
		}

		void SelfTestCloseTab(GraphTab tab)
		{
			int i = Tabs.IndexOf(tab);
			if (i < 0)
				return;
			if (mLastActiveTab == tab)
				mLastActiveTab = null;
			if (mSelectTab == tab)
				mSelectTab = null;
			Tabs.RemoveAt(i);
			delete tab;
			if (ActiveTab >= Tabs.Count)
				ActiveTab = Tabs.Count - 1;
		}

		/// Called once per frame.
		void SelfTestTick()
		{
			if (mSelfTestStep == -2)
				return;
			if (mSelfTestStep == -1)
			{
				String v = scope .();
				if (Environment.GetEnvironmentVariable("VB_SELFTEST", v) case .Err || v.IsEmpty)
				{
					mSelfTestStep = -2;
					return;
				}
				for (var part in v.Split(','))
				{
					part.Trim();
					if (!part.IsEmpty)
						mSelfTests.Add(new String(part));
				}
				mSelfTestStep = 0;
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] start: {v}");
			}
			// Also wait for the first-start focus of the Project Browser (a fresh default layout), which
			// would otherwise take the front tab from a panel a step just showed.
			if ((!mIndexReady || mIndexJob != null || mCommitPending || mFocusCBFrames > 0) && !(mSelfTests.IsEmpty || mSelfTests[0] == "nodoc"))
				return;
			if (mSelfTestWait > 0)
			{
				mSelfTestWait--;
				return;
			}
			if (mSelfTests.IsEmpty)
			{
				// A host assert is ImGui or SDL misuse: users get no dialog, the self tests get a failure.
				SelfTestCheck(HostAsserts.Count == 0, scope $"no host asserts ([ASSERT] lines in the session log: {HostAsserts.Count})");
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] done failures={mSelfTestFailures}");
				mSelfTestStep = -2;
				return;
			}
			let test = mSelfTests[0];
			if (test != "adddialog-close")
				mSelfTestCloseDialog = false;
			bool finished = true;
			switch (test)
			{
			case "rename-undo": finished = SelfTestRenameUndo();
			case "move-undo": finished = SelfTestMoveUndo();
			case "find-refs": finished = SelfTestFindRefs();
			case "openall": finished = SelfTestOpenAll();
			case "session": finished = SelfTestSession();
			case "debug": finished = SelfTestDebug();
			case "attach": finished = SelfTestAttach();
			case "attachlive": finished = SelfTestAttachLive();
			case "reload-check": finished = SelfTestReloadCheck();
			case "unreadable": finished = SelfTestUnreadable();
			case "nodoc": finished = SelfTestNoDoc();
			case "disk": finished = SelfTestDisk();
			case "ids": finished = SelfTestIds();
			case "debugshots": finished = SelfTestDebugShots();
			case "faultshot": finished = SelfTestFaultShot();
			case "newcomer": finished = SelfTestNewcomer();
			case "modauthor": finished = SelfTestModAuthor();
			case "fnlocals": finished = SelfTestFnLocals();
			case "localsui": finished = SelfTestLocalsUi();
			case "mathexpr": finished = SelfTestMath();
			case "adddialog-close": mSelfTestCloseDialog = true;
			case "locals-open": mSelfTestLocalsOpen = true;
			case "menu": SelfTestMenu(true);
			case "menu-close": SelfTestMenu(false);
			case "menu-pin": SelfTestMenuPin();
			default:
				if (test.StartsWith("shot:"))
					finished = SelfTestShot(test.Substring(5));
				else if (test.StartsWith("size:"))
					finished = SelfTestShot(scope $"size-{test.Substring(5)}");
				else if (test.StartsWith("theme:"))
					SelfTestTheme(test.Substring(6));
				else if (test.StartsWith("panel:"))
					SelfTestPanel(test.Substring(6));
				else if (test.StartsWith("status:")) // the status bar text (captures: hide scratch paths)
					mStatus.Set(test.Substring(7));
				else if (test.StartsWith("override:"))
					SelfTestOverride(test.Substring(9));
				else if (test.StartsWith("override-menu:"))
					mSelfTestOverrideMenu.Set(test.Substring(14));
				else if (test.StartsWith("newclass:"))
					SelfTestNewClass(test.Substring(9));
				else if (test.StartsWith("addctor:"))
					SelfTestAddCtor(test.Substring(8), false);
				else if (test.StartsWith("addctor-dialog:"))
					SelfTestAddCtor(test.Substring(15), true);
				else if (test.StartsWith("setoncreate:"))
					SelfTestSetOnCreate(test.Substring(12));
				else if (test.StartsWith("construct:"))
					SelfTestConstruct(test.Substring(10));
				else if (test.StartsWith("typesettings:"))
					SelectTypeSettings(test.Substring(13));
				else if (test.StartsWith("open:"))
					SelfTestOpen(test.Substring(5));
				else if (test.StartsWith("select:"))
					SelfTestSelect(test.Substring(7));
				else if (test.StartsWith("var:"))
					SelfTestVar(test.Substring(4));
				else if (test.StartsWith("addvar:"))
					SelfTestAddVar(test.Substring(7));
				else if (test.StartsWith("initbuf:")) // what the Value box shows, as if typed (error state captures)
					mInitValueBuf.Set(test.Substring(8));
				else if (test.StartsWith("newproject-mod:")) // File > New Project with UMP Mod chosen and the Game SDK filled in
				{
					StartNewProject();
					mNPType = 3;
					mNPName.Set("Hello Mod");
					mNPSdk.Set(test.Substring(15));
				}
				else if (test == "close-popups")
					mSelfTestClosePopups = true;
				else if (SelfTestPixelStep(test)) {}
				else if (test == "fit")
					SelfTestFit();
				else if (test.StartsWith("minimap:")) // the minimap on / off (captures)
					Prefs.ShowMinimap = test.Substring(8) == "on";
				else if (test.StartsWith("navsave:")) // Ctrl+<n> on the current Sheet, the toast held for a capture
				{
					mGraphPanel.NavToastHold = 6;
					mGraphPanel.SaveView(CurrentTab, (int)int32.Parse(test.Substring(8)).GetValueOrDefault());
				}
				else if (test.StartsWith("navjump:")) // <n> on the current Sheet
				{
					mGraphPanel.NavToastHold = 6;
					mGraphPanel.JumpToView(CurrentTab, (int)int32.Parse(test.Substring(8)).GetValueOrDefault());
				}
				else if (test.StartsWith("navhover:")) // the pointer on a spot of the window (clientXxclientY), or off
				{
					if (test.EndsWith("off"))
						mGraphPanel.SelfTestMouse = .(-3e38f, -3e38f);
					else if (test.EndsWith("mm"))
						mGraphPanel.SelfTestMouse = mGraphPanel.MinimapCenter(CurrentTab);
					else
					{
						var parts = test.Substring(9).Split('x');
						float x = float.Parse(parts.GetNext().Get()).GetValueOrDefault();
						float y = float.Parse(parts.GetNext().Get()).GetValueOrDefault();
						mGraphPanel.SelfTestMouse = .(x, y);
					}
				}
				else if (test.StartsWith("navpan:")) // pan the current Sheet by dxXdy grid units (captures)
				{
					var parts = test.Substring(7).Split('x');
					float dx = float.Parse(parts.GetNext().Get()).GetValueOrDefault();
					float dy = float.Parse(parts.GetNext().Get()).GetValueOrDefault();
					CurrentTab.Pan = .(CurrentTab.Pan.x + dx, CurrentTab.Pan.y + dy);
				}
				else if (test == "hotkey-menu")
					SelfTestHotkeyMenu();
				else if (test.StartsWith("hotkey-capture:")) // the Node menu's key-capture control on a favorite
					SelfTestHotkeyCapture(test.Substring(15));
				else if (test.StartsWith("prefs:")) // Editor Preferences open on a category (4 = Node Hotkeys)
				{
					OpenPreferences();
					mPrefsCategory = int32.Parse(test.Substring(6)).GetValueOrDefault();
				}
				else if (test == "prefs-close")
					mShowPrefs = false;
				else if (test.StartsWith("update:")) // the update notice line in a state (captures; no network)
					SelfTestUpdateState(test.Substring(7));
				else if (test.StartsWith("update-stage:")) // end to end: install an extracted package through the helper
					SelfTestUpdateStage(test.Substring(13));
				else if (test == "update-check") // a real check, as Help > Check for Updates
					CheckForUpdatesNow();
				else
					SelfTestCheck(false, scope $"unknown check {test}");
			}
			if (finished)
			{
				delete mSelfTests.PopFront();
				mSelfTestStep = 0;
				mSelfTestWait = 3;
			}
		}

		/// Members the editor cannot use as written stay visible (docs/Files-and-Safety.md >
		/// Unparsed members are kept). Expects the 2026-10-11 report: `Program.bf` with
		/// `public static var Main()` on line 11 and `Run()` after it, and `Bad.bf` with an unreadable
		/// member on line 3 (`public default Bad(int a)`).
		bool SelfTestUnreadable()
		{
			UnreadableMember mainProblem = null;
			UnreadableMember badProblem = null;
			String programPath = scope .();
			String badPath = scope .();
			for (let f in Index.Files)
				for (let u in f.Unreadable)
				{
					if (u.Name == "Program.Main")
					{
						mainProblem = u;
						programPath.Set(f.Path);
					}
					else if (u.Name == "C.Bad")
					{
						badProblem = u;
						badPath.Set(f.Path);
					}
				}
			SelfTestCheck(mainProblem != null && mainProblem.Line == 11 && mainProblem.Message.Contains("Return Type 'var'"), "unreadable: Problems lists Program.Main (line 11, Return Type 'var')");
			SelfTestCheck(badProblem != null && badProblem.Broken && badProblem.Line == 3, "unreadable: Problems lists the unreadable C.Bad (line 3)");
			if (mainProblem == null || badProblem == null)
				return true;
			let doc = OpenFile(programPath, false);
			String diskBefore = scope .();
			File.ReadAllText(programPath, diskBefore, true).IgnoreError();
			let main = doc?.FindMethod("Program.Main()");
			SelfTestCheck(main != null && main.Graphable && main.Graph.Entry.Error != null, "unreadable: var Main() has a graph whose entry node shows the error");
			SelfTestCheck(doc?.FindMethod("Program.Run()") != null, "unreadable: Run() is listed");
			// A Problems click on a line of a function opens its graph.
			JumpToLine(programPath, 11);
			SelfTestCheck(CurrentMethod != null && CurrentMethod.Key == "Program.Main()", "unreadable: line 11 opens Program.Main");
			// A line outside every graph (a member variable) opens Beef Source > File at that line.
			mSelectSourceFileTab = false;
			JumpToLine(programPath, 7);
			SelfTestCheck(mSelectSourceFileTab && mSourceScrollLine == 7, "unreadable: line 7 (a member variable) opens the File tab at line 7");
			// The unreadable member opens as its read-only error graph.
			JumpToLine(badPath, 3);
			SelfTestCheck(CurrentMethod != null && CurrentMethod.IsBroken && CurrentMethod.Graph.ReadOnly, "unreadable: line 3 of Bad.bf opens the red read-only node");
			// Saving without an edit leaves the file as it was; the Return Type fix clears the error.
			let progDoc = OpenFile(programPath, false);
			SelfTestCheck(progDoc.TrySave() == .Saved, "unreadable: saving Program.bf without an edit is allowed");
			String diskAfter = scope .();
			File.ReadAllText(programPath, diskAfter, true).IgnoreError();
			SelfTestCheck(diskAfter == diskBefore, "unreadable: the file is unchanged byte for byte");
			let m = progDoc.FindMethod("Program.Main()");
			if (m != null)
			{
				progDoc.SetSignature(m.Method, "void", "");
				let fixedMain = progDoc.FindMethod("Program.Main()");
				SelfTestCheck(fixedMain != null && fixedMain.Graph.Entry.Error == null && progDoc.Text.Contains("static void Main()"), "unreadable: Return Type void clears the error");
				progDoc.Undo();
				SelfTestCheck(progDoc.Text == diskBefore && !progDoc.Modified, "unreadable: undo restores the text, nothing to save");
			}
			return true;
		}

		/// A project rename touches two files; undo / redo from either file moves both.
		bool SelfTestRenameUndo()
		{
			let player = SelfTestDocWithType("Player");
			if (player == null)
			{
				SelfTestCheck(false, "rename-undo: the project has no Player type");
				return true;
			}
			let other = SelfTestOtherDoc(player, "mHealth");
			if (other == null)
			{
				SelfTestCheck(false, "rename-undo: no other file uses mHealth");
				return true;
			}
			mSelfTestA.Set(player.Text);
			mSelfTestB.Set(other.Text);
			for (let mg in player.Methods)
				if (mg.Graphable)
				{
					OpenTab(mg);
					break;
				}
			StartProjectRename(.Member, "mHealth", "mHitPoints", "Player", "", player.FilePath);
			mOpenRenamePreview = false; // what the preview's Rename button does next
			SelfTestCheck(mRenamePlan != null && mRenamePlan.CanApply && mRenamePlan.Files.Count >= 2,
				scope $"rename-undo: plan {mRenamePlan?.Count} references in {mRenamePlan?.Files.Count} files");
			ApplyRenamePlan();
			SelfTestCheck(player.Text.Contains("mHitPoints") && !player.Text.Contains("mHealth") && other.Text.Contains("mHitPoints") && !other.Text.Contains("mHealth"),
				"rename-undo: both files renamed");
			let undone = GroupUndo(player, false);
			SelfTestCheck(undone && player.Text == mSelfTestA && other.Text == mSelfTestB, "rename-undo: one undo in the first file restores both files");
			let redone = GroupUndo(player, true);
			SelfTestCheck(redone && player.Text.Contains("mHitPoints") && other.Text.Contains("mHitPoints") && !other.Text.Contains("mHealth"),
				"rename-undo: redo renames both again");
			let undone2 = GroupUndo(other, false);
			SelfTestCheck(undone2 && player.Text == mSelfTestA && other.Text == mSelfTestB, "rename-undo: undo from the other file restores both too");
			SelfTestCheck(!player.Modified && !other.Modified, "rename-undo: back at the saved text, neither file is dirty");
			return true;
		}

		/// A node drag is one undo step, never dirties the text, and undo puts it back.
		bool SelfTestMoveUndo()
		{
			let player = SelfTestDocWithType("Player");
			MethodGraph mg = null;
			if (player != null)
				for (let m in player.Methods)
					if (m.Graphable && m.Method.Name == "Hit")
						mg = m;
			if (mg == null)
			{
				SelfTestCheck(false, "move-undo: Player.Hit not found");
				return true;
			}
			OpenTab(mg);
			Node node = null;
			for (let n in mg.Graph.Nodes)
				if (n.Kind != .Entry && !n.IsPure)
					node = n;
			if (node == null)
			{
				SelfTestCheck(false, "move-undo: Player.Hit has no statement node");
				return true;
			}
			String key = scope .(node.Key);
			String mgKey = scope .(mg.Key); // undo rebuilds the MethodGraph wrappers
			float x = node.X;
			float y = node.Y;
			int depth = player.UndoDepth;
			bool dirty = player.Modified;
			// What GraphPanel does on a drag: one BeginEdit, then the positions change.
			BeginEdit();
			node.X = x + 160;
			node.Y = y + 48;
			node.HasPos = true;
			LayoutChanged();
			SelfTestCheck(player.UndoDepth == depth + 1 && player.Modified == dirty, "move-undo: a drag adds one undo step and leaves the text clean");
			player.Undo();
			Node back = null;
			for (let n in player.FindMethod(mgKey).Graph.Nodes)
				if (n.Key == key)
					back = n;
			SelfTestCheck(back != null && back.X == x && back.Y == y, scope $"move-undo: undo puts the node back at ({x}, {y})");
			player.Redo();
			Node again = null;
			for (let n in player.FindMethod(mgKey).Graph.Nodes)
				if (n.Key == key)
					again = n;
			SelfTestCheck(again != null && again.X == x + 160 && again.Y == y + 48, "move-undo: redo moves it again");
			player.Undo();
			return true;
		}

		/// Find References on a node reading mHealth lists every use in the project.
		bool SelfTestFindRefs()
		{
			let player = SelfTestDocWithType("Player");
			MethodGraph mg = null;
			if (player != null)
				for (let m in player.Methods)
					if (m.Graphable && m.Method.Name == "Hit")
						mg = m;
			if (mg == null)
			{
				SelfTestCheck(false, "find-refs: Player.Hit not found");
				return true;
			}
			OpenTab(mg);
			let tab = CurrentTab;
			Node get = null;
			for (let n in mg.Graph.Nodes)
				if ((n.Kind == .Get && n.Text == "mHealth") || (n.Kind == .Set && n.FindInput("target")?.Default == "mHealth"))
					get = n;
			if (tab == null || get == null)
			{
				SelfTestCheck(false, "find-refs: no node reads mHealth in Player.Hit");
				return true;
			}
			tab.SelectedNodes.Clear();
			tab.SelectedNodes.Add(get.Id);
			FindReferencesOfSelection();
			int refs = 0;
			HashSet<String> files = scope .();
			defer { for (let f in files) delete f; }
			for (let h in mFindHits)
			{
				if (h.Kind != .Reference)
					continue;
				refs++;
				if (!files.ContainsAlt(StringView(h.Path)))
					files.Add(new String(h.Path));
			}
			SelfTestCheck(refs >= 3 && files.Count >= 2 && ShowFindResults, scope $"find-refs: {mRefsTitle}");
			return true;
		}

		/// `open:Type.Method(int)`: opens that function's graph in a tab (for captures).
		void SelfTestOpen(StringView key)
		{
			for (let f in Index.Files)
			{
				let doc = OpenFile(f.Path, false);
				let mg = doc?.FindMethod(key);
				if (mg != null)
				{
					OpenTab(mg);
					SelfTestCheck(true, scope $"opened {key}");
					return;
				}
			}
			SelfTestCheck(false, scope $"open: {key} not found");
		}

		/// `var:Type.member`: shows a member variable in Properties, as a click on it in Outline does
		/// (opens the file that declares the type first).
		void SelfTestVar(StringView spec)
		{
			int dot = spec.IndexOf('.');
			if (dot < 0)
			{
				SelfTestCheck(false, scope $"var: {spec}: expected Type.member");
				return;
			}
			let typeName = spec.Substring(0, dot);
			let name = spec.Substring(dot + 1);
			for (let f in Index.Files)
			{
				let doc = OpenFile(f.Path, false);
				if (doc == null || FindField(FindTypeIn(doc, typeName), name) == null)
					continue;
				// Make the file the current one: open one of its graphs.
				for (let mg in doc.Methods)
					if (mg.Graphable && mg.Owner != null && mg.Owner.Name == typeName)
					{
						OpenTab(mg);
						break;
					}
				mSelClassActive = false;
				mSelVarType.Set(typeName);
				mSelVarName.Set(name);
				mSelVarActive = true;
				mSelVarSigPending = true;
				Panels.Focus(Panels.PropertiesId);
				SelfTestCheck(true, scope $"variable {spec} in Properties");
				return;
			}
			SelfTestCheck(false, scope $"var: {spec} not found");
		}

		/// `nodoc` (run with no project open): the Add Variable / Add Function dialogs and Type Settings are
		/// asked for with no document; nothing may crash and no dialog may open (they need a selected type).
		bool SelfTestNoDoc()
		{
			switch (mSelfTestStep)
			{
			case 0:
				SelfTestCheck(Doc == mEmptyDoc && CurrentTab == null, "nodoc: no document is loaded");
				mAddTargetType.Set("Greeter");
				mNameBuf.Set("mNewVar");
				mTypeBuf.Set("int");
				mOpenAddVariable = true;
				mOpenAddFunction = true;
				SelectTypeSettings("Greeter");
				mSelfTestStep = 1;
				mSelfTestWait = 5;
				return false;
			default:
				SelfTestCheck(!mOpenAddVariable && !mOpenAddFunction && mDialogRefusals == 2, scope $"nodoc: Add Variable and Add Function refused with no document ({mDialogRefusals} refusals) and the frames after them ran");
				return true;
			}
		}

		/// `addvar:Type:VarType:name`: opens the Add Variable dialog for Type with a type and a name typed.
		void SelfTestAddVar(StringView spec)
		{
			var parts = spec.Split(':');
			StringView typeName = parts.GetNext() case .Ok(let a) ? a : "";
			StringView varType = parts.GetNext() case .Ok(let b) ? b : "int";
			StringView name = parts.GetNext() case .Ok(let c) ? c : "mNewVar";
			mAddTargetType.Set(typeName);
			mNameBuf.Set(name);
			mTypeBuf.Set(varType);
			mParamsBuf.Set("");
			mOpenAddVariable = true;
			SelfTestCheck(true, scope $"Add Variable {spec}");
		}

		/// `fit`: zooms the current graph so every node shows (for captures).
		void SelfTestFit()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null || mg.Graph.Nodes.IsEmpty)
				return;
			float minX = float.MaxValue, minY = float.MaxValue, maxX = float.MinValue, maxY = float.MinValue;
			for (let n in mg.Graph.Nodes)
			{
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
				maxX = Math.Max(maxX, n.X + AutoLayout.EstimateWidth(n));
				maxY = Math.Max(maxY, n.Y + AutoLayout.EstimateHeight(n));
			}
			float w = maxX - minX + 80;
			float h = maxY - minY + 80;
			int32 level = Canvas.DefaultZoomLevel;
			while (level > 0 && (w * Canvas.ZoomLevels[level] > tab.CanvasSize.x || h * Canvas.ZoomLevels[level] > tab.CanvasSize.y))
				level--;
			tab.ZoomLevel = level;
			let z = tab.Zoom;
			tab.Pan = .(40 / z - minX, 40 / z - minY);
			tab.NeedsFocus = false;
			SelfTestCheck(true, scope $"fit: zoom {z}");
		}

		/// `select:Kind:Text`: selects the first node of that kind and text in the current tab, so
		/// Properties shows it (for captures).
		void SelfTestSelect(StringView spec)
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			int colon = spec.IndexOf(':');
			if (tab == null || mg == null || colon < 0)
			{
				SelfTestCheck(false, scope $"select: {spec}: no graph open");
				return;
			}
			let kindName = spec.Substring(0, colon);
			let text = spec.Substring(colon + 1);
			for (let n in mg.Graph.Nodes)
			{
				String k = scope .();
				n.Kind.ToString(k);
				if (k == kindName && (text.IsEmpty || n.Text == text))
				{
					tab.SelectedNodes.Clear();
					tab.SelectedNodes.Add(n.Id);
					// What a click on a node does to Properties: the node replaces Type Settings.
					mSelClassActive = false;
					mSelVarActive = false;
					tab.CenterOn(n.X + 100, n.Y + 40);
					tab.NeedsFocus = false;
					SelfTestCheck(true, scope $"selected {spec}");
					return;
				}
			}
			SelfTestCheck(false, scope $"select: {spec} not found");
		}

		/// Opens every function of every project file in a tab, one per frame (the graph is drawn
		/// on the next frame), then closes it: anything that crashes or asserts on real code shows.
		bool SelfTestOpenAll()
		{
			if (mSelfTestStep == 0)
			{
				for (let q in mSelfTestQueue)
				{
					delete q.path;
					delete q.key;
				}
				mSelfTestQueue.Clear();
				for (let f in Index.Files)
				{
					if (!f.Path.EndsWith(".bf", .OrdinalIgnoreCase))
						continue;
					let doc = OpenFile(f.Path, false);
					if (doc == null)
					{
						SelfTestCheck(false, scope $"openall: {f.Path} did not open");
						continue;
					}
					for (let mg in doc.Methods)
						if (mg.Graphable || mg.IsBroken)
							mSelfTestQueue.Add((new String(f.Path), new String(mg.Key)));
				}
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] openall: {Index.Files.Count} files, {mSelfTestQueue.Count} functions to open");
				mSelfTestOpened = 0;
				mSelfTestStep = 1;
				return false;
			}
			// A tab opened two frames ago has been drawn: close it, open the next.
			if (mSelfTestStep == 2)
			{
				mSelfTestStep = 3;
				return false;
			}
			if (CurrentTab != null && mSelfTestStep == 3)
			{
				if (GraphPanel.DrawCount == mSelfTestDrawsAtOpen)
				{
					mSelfTestUndrawn++;
					if (mSelfTestUndrawn <= 10)
						Notify.Log(.Warning, "SelfTest", scope $"[SELFTEST] openall: {CurrentTab.MethodKey} was not drawn");
				}
				SelfTestCloseTab(CurrentTab);
			}
			if (mSelfTestQueue.IsEmpty)
			{
				SelfTestCheck(mSelfTestUndrawn == 0, scope $"openall: {mSelfTestOpened} functions opened and drawn without a crash ({mSelfTestUndrawn} not drawn)");
				return true;
			}
			let next = mSelfTestQueue.PopFront();
			defer { delete next.path; delete next.key; }
			let doc = FindDoc(next.path);
			let mg = (doc != null) ? doc.FindMethod(next.key) : null;
			if (mg == null)
			{
				SelfTestCheck(false, scope $"openall: {next.key} is gone");
				return false;
			}
			OpenTab(mg);
			mSelfTestDrawsAtOpen = GraphPanel.DrawCount;
			mSelfTestOpened++;
			mSelfTestStep = 2;
			if (mSelfTestOpened % 100 == 0)
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] openall: {mSelfTestOpened} opened");
			return false;
		}
	}
}
