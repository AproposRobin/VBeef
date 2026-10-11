using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Debug;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// A breakpoint as the editor keeps it: on a node (function key + content-keyed layout key,
	/// like compiler messages), saved per workspace in settings.json, never in the source.
	class EditorBreakpoint
	{
		public String Workspace = new .() ~ delete _;
		public String File = new .() ~ delete _;
		public String Method = new .() ~ delete _;
		public String NodeKey = new .() ~ delete _;
	}

	/// The debugger in the editor (docs/Debugging.md): breakpoints on nodes, Start Debugging
	/// (compile in Debug, then run under Beef's debugger engine), the stopped node, stepping,
	/// values of pins, Locals, Call Stack and Debug Output (DebugPanels.bf), the node overlay
	/// (DebugCanvas.bf). The engine itself is VisualBeefCore's DebugSession.
	extension EditorApp
	{
		DebugSession mDebug ~ delete _;
		List<EditorBreakpoint> mBreakpoints = new .() ~ DeleteContainerAndItems!(_);
		List<String> mBreakpointsLoaded = new .() ~ DeleteContainerAndItems!(_);
		bool mDebugAfterBuild;
		String mDebugWs = new .() ~ delete _;
		/// The program's stdout / stderr of the session (Debug Output panel).
		public String DebugOutput = new .() ~ delete _;
		/// Selected call stack frame (0 = where it stopped).
		public int32 DebugFrame;
		/// The node shown as "stopped here" (in the graph object it belongs to).
		public Graph DebugStopGraph;
		public int32 DebugStopNode;
		/// The document the stop marker was resolved against, and its version then: the marker comes
		/// from line numbers of the program as built, so a text change under it (Reload From Disk, an
		/// edit, undo) makes it wrong; it is hidden and the user told.
		SourceDocument mDebugStopDoc;
		int32 mDebugStopVersion;
		String mDebugStopWhere = new .() ~ delete _;
		/// Values of pins while stopped: pin id -> text ("!" first = not available, the reason).
		Dictionary<int32, String> mPinValues = new .() ~ DeleteDictionaryAndValues!(_);
		Graph mPinValuesGraph;
		int32 mPinValuesStop = -1;
		/// The document version the cached pin values were read for (an edit while stopped makes
		/// new graphs; a new one can reuse a freed graph's address).
		int32 mPinValuesVersion = -1;
		int32 mPinValuesFrame = -1;
		/// The Project Browser took F5 this frame (refresh): Start Debugging leaves it alone.
		bool mCBTookF5;
		public bool ShowLocals = true;
		public bool ShowCallStack = true;
		public bool ShowDebugOutput = true;
		bool mFocusDebugOutput;
		bool mDebugEverStarted;

		public bool IsDebugging => mDebug != null && mDebug.IsActive;
		public bool IsDebugStopped => mDebug != null && mDebug.IsStopped;
		public DebugSession Debugger => mDebug;

		// ---------------------------------------------------------------- breakpoints

		void WorkspaceOf(StringView file, String outWs)
		{
			BuildRunner.FindWorkspace(file, outWs);
		}

		void LoadBreakpoints(StringView ws)
		{
			if (ws.IsEmpty)
				return;
			for (let w in mBreakpointsLoaded)
				if (BuildRunner.SamePath(w, ws))
					return;
			mBreakpointsLoaded.Add(new String(ws));
			let arr = Settings.Project(ws).Get("breakpoints");
			if (arr == null || arr.Type != .Array)
				return;
			for (let item in arr.Items)
			{
				if (item.Type != .String)
					continue;
				let parts = item.Str.Split('\t');
				StringView[3] p = default;
				int i = 0;
				for (let s in parts)
				{
					if (i < 3)
						p[i] = s;
					i++;
				}
				if (i != 3)
					continue;
				let bp = new EditorBreakpoint();
				bp.Workspace.Set(ws);
				bp.File.Set(p[0]);
				bp.Method.Set(p[1]);
				bp.NodeKey.Set(p[2]);
				mBreakpoints.Add(bp);
			}
		}

		void SaveBreakpoints(StringView ws)
		{
			Settings.Load();
			let arr = Json.NewArray();
			for (let bp in mBreakpoints)
				if (BuildRunner.SamePath(bp.Workspace, ws))
					arr.Items.Add(Json.NewString(scope $"{bp.File}\t{bp.Method}\t{bp.NodeKey}"));
			Settings.Project(ws).Set("breakpoints", arr);
			Settings.Save();
		}

		/// The node a stored breakpoint is on, in the graph of an open document (null when gone).
		Node BreakpointNode(EditorBreakpoint bp, SourceDocument doc, out MethodGraph mg)
		{
			mg = doc?.FindMethod(bp.Method);
			if (mg == null || !mg.Graphable)
				return null;
			return DiagnosticMap.FindByKey(mg.Graph, bp.NodeKey);
		}

		/// Ids of the nodes of this graph that carry a breakpoint (drawn as red dots).
		public void BreakpointNodes(MethodGraph mg, HashSet<int32> outIds)
		{
			if (mg.Doc == null || mg.Doc.FilePath.IsEmpty)
				return;
			String ws = scope .();
			WorkspaceOf(mg.Doc.FilePath, ws);
			LoadBreakpoints(ws);
			for (let bp in mBreakpoints)
			{
				if (bp.Method != mg.Key || !BuildRunner.SamePath(bp.File, mg.Doc.FilePath))
					continue;
				let n = DiagnosticMap.FindByKey(mg.Graph, bp.NodeKey);
				if (n != null)
					outIds.Add(n.Id);
			}
		}

		/// F9 / a click on the node's breakpoint circle. Nodes without a line say why.
		public void ToggleBreakpoint(MethodGraph mg, Node node)
		{
			if (mg == null || node == null || mg.Doc == null || mg.Doc.FilePath.IsEmpty)
				return;
			String ws = scope .();
			WorkspaceOf(mg.Doc.FilePath, ws);
			if (ws.IsEmpty)
			{
				SetStatus("No BeefSpace.toml for this file: breakpoints belong to a workspace", .Warning);
				return;
			}
			LoadBreakpoints(ws);
			for (let bp in mBreakpoints)
			{
				if (bp.Method != mg.Key || !BuildRunner.SamePath(bp.File, mg.Doc.FilePath))
					continue;
				if (DiagnosticMap.FindByKey(mg.Graph, bp.NodeKey) != node)
					continue;
				RemoveSessionBreakpoint(bp);
				mBreakpoints.Remove(bp);
				delete bp;
				SaveBreakpoints(ws);
				return;
			}
			String why = scope .();
			if (DebugMap.LineOf(mg.Graph, node, why) <= 0)
			{
				SetStatus(scope $"No breakpoint here: {why}", .Warning);
				return;
			}
			let bp = new EditorBreakpoint();
			bp.Workspace.Set(ws);
			bp.File.Set(mg.Doc.FilePath);
			bp.Method.Set(mg.Key);
			LayoutKeys.Compose(node, bp.NodeKey);
			mBreakpoints.Add(bp);
			SaveBreakpoints(ws);
			if (IsDebugging && mDebug.State != .Stopping)
				AddSessionBreakpoint(bp, mg.Doc);
		}

		/// Removes every breakpoint of the current workspace.
		void ClearBreakpoints()
		{
			String ws = scope .();
			CurrentWorkspace(ws);
			for (int i = mBreakpoints.Count - 1; i >= 0; i--)
			{
				let bp = mBreakpoints[i];
				if (!BuildRunner.SamePath(bp.Workspace, ws))
					continue;
				RemoveSessionBreakpoint(bp);
				mBreakpoints.RemoveAt(i);
				delete bp;
			}
			SaveBreakpoints(ws);
		}

		bool AddSessionBreakpoint(EditorBreakpoint bp, SourceDocument doc)
		{
			let node = BreakpointNode(bp, doc, let mg);
			if (node == null)
				return false;
			let line = DebugMap.LineOf(mg.Graph, node);
			if (line <= 0)
				return false;
			mDebug.AddBreakpoint(bp.File, line, bp);
			return true;
		}

		void RemoveSessionBreakpoint(EditorBreakpoint bp)
		{
			if (mDebug == null)
				return;
			for (let dbp in mDebug.Breakpoints)
			{
				if (dbp.Tag == bp)
				{
					mDebug.RemoveBreakpoint(dbp);
					return;
				}
			}
		}

		// ---------------------------------------------------------------- start / stop

		/// F5: compile the workspace in Debug, then run it under the debugger. While stopped, F5
		/// continues.
		public void StartDebugging()
		{
			if (IsDebugStopped)
			{
				mDebug.Continue();
				return;
			}
			if (IsDebugging || mDebugAfterBuild)
				return;
			if (mBuild != null && mBuild.Running)
			{
				SetStatus("A compile is running: start debugging when it is done", .Warning);
				return;
			}
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
			{
				SetStatus("No BeefSpace.toml found - nothing to debug", .Warning);
				return;
			}
			if (!DebugEngine.Load(mBeefBuildPath))
			{
				Notify.Error(scope $"{DebugEngine.NeedBeef} ({DebugEngine.LoadError})");
				return;
			}
			mDebugWs.Set(ws);
			mDebugAfterBuild = true;
			Compile("Debug");
			if (mBuild == null || !mBuild.Running)
			{
				mDebugAfterBuild = false;
				return;
			}
			LowPriority.Apply(mBuild.ProcessId);
			Notify.Log(.Info, "Debug", "Start Debugging: compiling in Debug first");
		}

		/// Called when a compile ends (Frame).
		void OnBuildFinishedForDebug()
		{
			if (!mDebugAfterBuild)
				return;
			mDebugAfterBuild = false;
			if (!mBuild.Succeeded)
			{
				Notify.Error("Compile failed: not debugging (see Problems)");
				return;
			}
			LaunchDebug(mDebugWs);
		}

		void LaunchDebug(StringView ws)
		{
			DebugTarget target = scope .();
			String err = scope .();
			if (!target.Resolve(ws, "Debug", err))
			{
				Notify.Error(err);
				return;
			}
			let set = NewSession(ws);
			DebugOutput.Clear();
			ClearStop();
			if (!mDebug.Launch(target.Exe, target.Args, target.WorkDir, err))
			{
				Notify.Error(err);
				return;
			}
			mDebugEverStarted = true;
			ShowDebugOutput = true;
			Notify.Log(.Info, "Debug", scope $"Debugging {target.Exe} (in {target.WorkDir}) with {set} breakpoint(s); engine {DebugEngine.DllPath}");
			SetStatus(scope $"Debugging {target.Project}", .Info, false);
		}

		/// A new session for workspace `ws` with its breakpoints set by line (the nodes' lines in
		/// the saved text). Returns how many were set.
		int NewSession(StringView ws)
		{
			delete mDebug;
			mDebug = new DebugSession();
			// A new session counts stops from 0 again: values cached at stop 1 of the last run
			// must not show at stop 1 of this one.
			mPinValuesStop = -1;
			mLocalsStop = -1;
			mExpandGameFrames = false;
			mDebug.SourceRoot.Set(ws);
			LoadBreakpoints(ws);
			// Breakpoints go to the engine by line: the nodes' lines in the saved text just built.
			Dictionary<String, SourceDocument> temp = scope .();
			defer { for (let kv in temp) { delete kv.key; delete kv.value; } }
			int set = 0;
			for (let bp in mBreakpoints)
			{
				if (!BuildRunner.SamePath(bp.Workspace, ws))
					continue;
				var doc = FindDoc(bp.File);
				if (doc == null)
				{
					String key = scope .(bp.File);
					key.ToLower();
					if (!temp.TryGetValue(key, out doc))
					{
						doc = new SourceDocument();
						if (doc.Load(bp.File) case .Err)
							DeleteAndNullify!(doc);
						temp[new String(key)] = doc;
					}
				}
				if (doc != null && AddSessionBreakpoint(bp, doc))
					set++;
				else
					Notify.Log(.Warning, "Debug", scope $"A breakpoint's node is gone ({bp.File}, {bp.Method}): skipped");
			}
			return set;
		}

		/// Shift+F5: ends a launched program, detaches from an attached game (it keeps running).
		public void StopDebugging()
		{
			mDebugAfterBuild = false;
			if (IsDebugging)
			{
				if (mDebug.Attached)
					Notify.Log(.Info, "Debug", scope $"Detaching from {mAttachedName} (pid {mDebug.ProcessId})");
				mDebug.Stop();
			}
		}

		void ClearStop()
		{
			DebugStopGraph = null;
			DebugStopNode = 0;
			DebugFrame = 0;
			mDebugStopDoc = null;
			mDebugStopWhere.Clear();
		}

		// ---------------------------------------------------------------- every frame

		void DebugTick()
		{
			mCBTookF5 = false;
			if (mDebug == null)
				return;
			mDebug.Update();
			List<DebugEvent> events = scope .();
			mDebug.TakeEvents(events);
			defer { ClearAndDeleteItems!(events); }
			for (let e in events)
			{
				switch (e.Kind)
				{
				case .Output:
					DebugOutput.Append(e.Text);
					if (DebugOutput.Length > 4 << 20)
						DebugOutput.Remove(0, DebugOutput.Length - (2 << 20));
				case .Message:
					Notify.Log(.Info, "Debug", e.Text);
					// An attached game has no console of ours: the debugger's lines go to Debug Output.
					if (mDebug.Attached)
						DebugOutput.AppendF("{}\n", e.Text);
				case .Error:
					Notify.Error(e.Text);
				case .Started:
					Notify.Log(.Info, "Debug", "Running");
				case .Resumed:
					ClearStop();
				case .Stopped:
					OnDebugStopped();
				case .Exited:
					ClearStop();
					if (mDebug.Attached)
					{
						let msg = scope $"Detached from {mAttachedName}: the game keeps running";
						Notify.Info(msg);
						DebugOutput.AppendF("{}\n", msg);
						if (mDebug.SkippedExceptions > 0)
							Notify.Log(.Info, "Debug", scope $"The game raised and handled {mDebug.SkippedExceptions} exception(s) of its own while attached");
					}
					else if (e.Text.IsEmpty)
						Notify.Info("The program ended");
					else
						Notify.Info(scope $"The program exited with code {e.Text}");
				}
			}
			if (mDebugStopDoc != null && DebugStopGraph != null && IsDebugStopped)
			{
				bool gone = !mDocs.Contains(mDebugStopDoc);
				if (gone || mDebugStopDoc.Version != mDebugStopVersion)
				{
					ClearStop();
					SetStatus("The source changed while the program is stopped: the stop marker is hidden, as its line no longer matches. Stop and start debugging again to see the new code run.", .Warning);
				}
			}
		}

		void OnDebugStopped()
		{
			// Show the first frame in this workspace (a fault inside a library shows where your
			// code called it).
			DebugFrame = -1;
			for (let f in mDebug.Frames)
			{
				if (f.HasSource && DebugSession.IsUnder(f.File, mDebug.SourceRoot))
				{
					DebugFrame = (int32)@f.Index;
					break;
				}
			}
			if (DebugFrame >= 0)
				ShowDebugFrame(DebugFrame, true);
			else
			{
				// Stopped outside the workspace (a pause in system code): nothing to open; the
				// Call Stack lists the frames.
				DebugFrame = 0;
				ClearStop();
				if (!mDebug.Frames.IsEmpty)
					mDebugStopWhere.Set(mDebug.Frames[0].Name);
				ShowCallStack = true;
			}
			switch (mDebug.Reason)
			{
			case .Exception:
				ReportFault();
			case .Pause:
				Notify.Log(.Info, "Debug", scope $"Paused at {mDebugStopWhere}");
			default:
				Notify.Log(.Verbose, "Debug", scope $"Stopped at {mDebugStopWhere}");
			}
			Desktop.BringToFront();
		}

		/// Opens the Sheet of a frame and marks its node; `useHit` marks the node a hit breakpoint
		/// was set on (a breakpoint the engine moved to the next line still shows on its node).
		public void ShowDebugFrame(int32 index, bool useHit = false)
		{
			if (mDebug == null || index < 0 || index >= mDebug.Frames.Count)
				return;
			DebugFrame = index;
			let f = mDebug.Frames[index];
			mDebugStopWhere.Set(f.Name);
			if (!f.HasSource)
			{
				DebugStopGraph = null;
				return;
			}
			let doc = OpenFile(f.File, false);
			if (doc == null)
				return;
			mDebugStopDoc = doc;
			mDebugStopVersion = doc.Version;
			MethodGraph mg = null;
			Node node = null;
			if (useHit && index == 0)
			{
				if (let ebp = mDebug.HitBreakpoint()?.Tag as EditorBreakpoint)
					node = BreakpointNode(ebp, doc, out mg);
			}
			if (node == null)
				node = DebugMap.NodeAt(doc, f.Line, out mg);
			if (mg == null || node == null)
			{
				DebugStopGraph = null;
				JumpToLine(f.File, f.Line);
				return;
			}
			mDebugStopWhere.Clear();
			if (mg.Owner != null)
				mDebugStopWhere.AppendF("{}.", mg.Owner.Name);
			mDebugStopWhere.Append(mg.Method.Name);
			OpenTab(mg);
			DebugStopGraph = mg.Graph;
			DebugStopNode = node.Id;
			let tab = CurrentTab;
			if (tab != null)
			{
				// A fault puts its message in a bubble under the node: centre lower so both show.
				bool fault = useHit && mDebug.Reason == .Exception;
				tab.CenterOn(node.X + 100, node.Y + (fault ? 110 : 40));
			}
		}

		/// A fault: the message on the node in Problems (and a toast).
		void ReportFault()
		{
			String text = scope $"The program stopped on a fault: {mDebug.ExceptionText}";
			Notify.Error(text);
			if (DebugFrame >= mDebug.Frames.Count)
				return;
			let f = mDebug.Frames[DebugFrame];
			if (!f.HasSource)
				return;
			if (mBuild == null)
				mBuild = new BuildRunner();
			let d = new Diagnostic();
			d.Severity = .Error;
			d.Text.Set(text);
			d.Path.Set(f.File);
			d.Line = f.Line;
			let doc = FindDoc(f.File);
			if (doc != null)
				DiagnosticMap.Locate(doc, d);
			mBuild.Messages.Add(d);
			ShowCompilerResults = true;
		}

		// ---------------------------------------------------------------- values

		/// The frame whose function is this graph (the selected frame first), or -1.
		public int32 FrameForGraph(MethodGraph mg)
		{
			if (!IsDebugStopped || mg.Doc == null)
				return -1;
			bool Matches(int32 i)
			{
				let f = mDebug.Frames[i];
				return f.HasSource && BuildRunner.SamePath(f.File, mg.Doc.FilePath) && DiagnosticMap.MethodAt(mg.Doc, f.Line) == mg;
			}
			if (DebugFrame < mDebug.Frames.Count && Matches(DebugFrame))
				return DebugFrame;
			for (int32 i < (int32)mDebug.Frames.Count)
				if (Matches(i))
					return i;
			return -1;
		}

		/// The value of a pin while stopped, read once per stop. False with the reason in outText.
		public bool DebugPinValue(MethodGraph mg, Pin pin, String outText)
		{
			if (!IsDebugStopped)
				return false;
			let frame = FrameForGraph(mg);
			if (frame < 0)
			{
				outText.Set("This function is not on the call stack.");
				return false;
			}
			if (mPinValuesGraph != mg.Graph || mPinValuesStop != mDebug.StopCount || mPinValuesFrame != frame || mPinValuesVersion != mg.Doc.Version)
			{
				for (let v in mPinValues.Values)
					delete v;
				mPinValues.Clear();
				mPinValuesGraph = mg.Graph;
				mPinValuesStop = mDebug.StopCount;
				mPinValuesFrame = frame;
				mPinValuesVersion = mg.Doc.Version;
			}
			if (mPinValues.TryGetValue(pin.Id, let cached))
			{
				bool ok = !cached.StartsWith('!');
				outText.Set(ok ? cached : cached.Substring(1));
				return ok;
			}
			String expr = scope .();
			String why = scope .();
			String result = new .();
			if (!DebugMap.PinExpr(mg.Graph, pin, expr, why))
				result.AppendF("!{}", why.IsEmpty ? "No value." : why);
			else
			{
				EvalValue v = scope .();
				if (mDebug.Evaluate(expr, frame, v, 200))
					ShortValue(v.Value, result);
				else
					result.AppendF("!{}", v.Value);
			}
			mPinValues[pin.Id] = result;
			bool ok = !result.StartsWith('!');
			outText.Set(ok ? result : result.Substring(1));
			return ok;
		}

		/// "0x7FF6'73E1F4A8 \"Beef\"" -> "\"Beef\"": the address in front of strings and objects
		/// is noise on a pin.
		public static void ShortValue(StringView value, String outText)
		{
			var v = value;
			if (v.StartsWith("0x"))
			{
				int sp = v.IndexOf(' ');
				if (sp > 0 && sp + 1 < v.Length)
					v = v.Substring(sp + 1);
			}
			outText.Append(v);
		}

		// ---------------------------------------------------------------- menu, toolbar, keys

		void DrawDebugMenu()
		{
			if (!Gui.BeginMenu("Debug"))
				return;
			bool active = IsDebugging;
			bool stopped = IsDebugStopped;
			if (IconItem(Icon.Bug, stopped ? "Continue" : "Start Debugging", "F5", false, !active || stopped))
				StartDebugging();
			if (IconItem(Icon.Plug, "Attach to Game...", "", false, !active && !mDebugAfterBuild))
				OpenAttachDialog();
			if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
				Gui.Tooltip(active ? "A debugging session is running: stop or detach it first" : "Debug your mod inside a running game started by the UMP launcher");
			Gui.Separator();
			if (IconItem(Icon.Pause, "Pause", "", false, active && !stopped))
				mDebug.Pause();
			if (IsAttached)
			{
				if (IconItem(Icon.Plug, "Detach", "Shift+F5", false, true))
					StopDebugging();
			}
			else if (IconItem(Icon.Square, "Stop Debugging", "Shift+F5", false, active))
				StopDebugging();
			Gui.Separator();
			if (IconItem(Icon.RedoDot, "Step Over", "F10", false, stopped))
				mDebug.StepOver();
			if (IconItem(Icon.ArrowDownToLine, "Step Into", "F11", false, stopped))
				mDebug.StepInto();
			if (IconItem(Icon.ArrowUpFromLine, "Step Out", "Shift+F11", false, stopped))
				mDebug.StepOut();
			Gui.Separator();
			let tab = CurrentTab;
			let mg = CurrentMethod;
			bool haveNode = tab != null && mg != null && tab.SelectedNodes.Count > 0;
			if (IconItem(Icon.CircleDot, "Toggle Breakpoint", "F9", false, haveNode))
				ToggleSelectedBreakpoints();
			if (IconItem(Icon.Trash2, "Remove All Breakpoints", "", false, !mBreakpoints.IsEmpty))
				ClearBreakpoints();
			Gui.Separator();
			if (IconItem(Icon.Variable, "Locals", "", ShowLocals))
				ShowLocals = !ShowLocals;
			if (IconItem(Icon.Layers, "Call Stack", "", ShowCallStack))
				ShowCallStack = !ShowCallStack;
			if (IconItem(Icon.Terminal, "Debug Output", "", ShowDebugOutput))
				ShowDebugOutput = !ShowDebugOutput;
			Gui.EndMenu();
		}

		void ToggleSelectedBreakpoints()
		{
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			List<int32> ids = scope .(tab.SelectedNodes.GetEnumerator());
			for (let id in ids)
				ToggleBreakpoint(mg, mg.Graph.FindNode(id));
		}

		void DrawDebugToolbar()
		{
			bool active = IsDebugging;
			bool stopped = IsDebugStopped;
			ToolbarSeparator();
			StringView label = stopped ? "Continue" : (active ? (mDebug.Attached ? "Attached" : "Running") : (mDebugAfterBuild ? "Compiling" : "Debug"));
			if (ToolbarButton("debugstart", stopped ? Icon.Play : Icon.Bug, label, stopped ? "Continue (F5)" : "Start Debugging (F5): compile in Debug, then run with your breakpoints", !active || stopped, Look.Success))
				StartDebugging();
			if (active)
			{
				if (ToolbarButton("debugpause", Icon.Pause, "", "Pause", !stopped))
					mDebug.Pause();
				if (mDebug.Attached)
				{
					if (ToolbarButton("debugdetach", Icon.Plug, "Detach", "Detach (Shift+F5): the debugger lets go, the game keeps running", true, Look.Error))
						StopDebugging();
				}
				else if (ToolbarButton("debugstop", Icon.Square, "", "Stop Debugging (Shift+F5)", true, Look.Error))
					StopDebugging();
				if (ToolbarButton("stepover", Icon.RedoDot, "", "Step Over (F10): run this node, stop at the next", stopped))
					mDebug.StepOver();
				if (ToolbarButton("stepinto", Icon.ArrowDownToLine, "", "Step Into (F11): into the function this node calls", stopped))
					mDebug.StepInto();
				if (ToolbarButton("stepout", Icon.ArrowUpFromLine, "", "Step Out (Shift+F11): run to the end of this function", stopped))
					mDebug.StepOut();
			}
		}

		/// After every panel is drawn (the Project Browser keeps F5 for refreshing).
		void DebugShortcuts()
		{
			if (Gui.igIsAnyItemActive() || Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup))
				return;
			bool shift = Gui.IsShiftDown;
			bool ctrl = Gui.IsCtrlDown;
			if (ctrl)
				return;
			if (Gui.IsKeyPressed(576 /* F5 */, false))
			{
				if (shift)
					StopDebugging();
				else if (!mCBTookF5)
					StartDebugging();
			}
			if (!shift && Gui.IsKeyPressed(580 /* F9 */, false))
				ToggleSelectedBreakpoints();
			if (IsDebugStopped)
			{
				if (!shift && Gui.IsKeyPressed(581 /* F10 */, false))
					mDebug.StepOver();
				if (Gui.IsKeyPressed(582 /* F11 */, false))
				{
					if (shift)
						mDebug.StepOut();
					else
						mDebug.StepInto();
				}
			}
		}

		/// Status bar: "Running", "Stopped at Greeter.Hello", "Not debugging" (after a session).
		void DrawDebugStatus()
		{
			if (!mDebugEverStarted && !mDebugAfterBuild)
				return;
			String text = scope .();
			uint32 col = Look.ForegroundDim;
			StringView icon = Icon.Bug;
			if (mDebugAfterBuild)
				text.Append("Compiling for debugging...");
			else if (IsAttached)
			{
				// Red while attached: a game paused at a breakpoint stays paused until Continue or Detach.
				col = Look.Error;
				icon = Icon.Plug;
				text.AppendF("Attached to {} ({})", mAttachedName, mDebug.ProcessId);
				if (mDebug.State == .Stopping)
					text.Append(" - detaching...");
				else if (IsDebugStopped)
					text.AppendF(" - game paused at {}: F5 Continue, Shift+F5 Detach", mDebugStopWhere.IsEmpty ? "game code" : mDebugStopWhere);
				else
					text.Append(" - running");
			}
			else if (!IsDebugging)
				text.Append("Not debugging");
			else if (mDebug.State == .Stopping)
				text.Append("Stopping...");
			else if (IsDebugStopped)
			{
				text.AppendF("Stopped at {}", mDebugStopWhere);
				if (mDebug.Reason == .Exception)
				{
					text.Append(" (fault)");
					col = Look.Error;
				}
				else
					col = Look.Warning;
				icon = Icon.Pause;
			}
			else
			{
				text.Append("Running");
				col = Look.Success;
				icon = Icon.Play;
			}
			Gui.SameLine(0, 16 * Look.Scale);
			Gui.igAlignTextToFramePadding();
			Gui.TextColored(col, scope $"{icon}  {text}");
		}
	}
}
