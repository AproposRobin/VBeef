using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Graph;
using VisualBeef.Document;
using VisualBeef.Syntax;

namespace VisualBeef.Editor
{
	/// An entry in the Outline panel that can be dragged into a graph.
	class MemberRef
	{
		public enum Kind { Variable, Function }
		public Kind MemberKind;
		public String Name = new .() ~ delete _;
		public String Type = new .() ~ delete _;
		public String Params = new .() ~ delete _;
		public String Owner = new .() ~ delete _;
		public bool IsStatic;
	}

	class EditorApp
	{
		/// The document the side panels show (follows the active graph tab).
		public SourceDocument Doc;
		/// Every file opened this session; all stay loaded so graphs in several files can be open.
		List<SourceDocument> mDocs = new .() ~ DeleteContainerAndItems!(_);
		SourceDocument mEmptyDoc = new .() ~ delete _;
		/// Symbols of every .bf file in the project folder.
		public ProjectIndex Index = new .() ~ delete _;
		GraphTab mLastActiveTab;
		public List<GraphTab> Tabs = new .() ~ DeleteContainerAndItems!(_);
		public int ActiveTab = -1;
		GraphPanel mGraphPanel ~ delete _;
		NodeMenu mNodeMenu ~ delete _;
		GraphTab mActionTab;
		OrphanSet mClipboard ~ delete _;
		List<MemberRef> mMembers = new .() ~ DeleteContainerAndItems!(_);

		public bool QuitNow;
		bool mShowQuitModal;
		bool mShowDemo;
		String mStatus = new .() ~ delete _;
		double mStatusTime;
		bool mLayoutDirty;
		/// Documents whose save was refused because the file changed on disk (shown one at a time).
		List<SourceDocument> mConflicts = new .() ~ delete _;
		/// Errors waiting for the user to acknowledge (modal); creation / delete / save failures.
		List<String> mErrors = new .() ~ DeleteContainerAndItems!(_);

		// Project / files
		String mProjectRoot = new .() ~ delete _;
		List<String> mProjectFiles = new .() ~ DeleteContainerAndItems!(_);
		bool mShowSwitchModal;
		int mFrame;

		// Popups
		TextBuffer mPathBuf = new .(1024) ~ delete _;
		TextBuffer mNameBuf = new .(256) ~ delete _;
		TextBuffer mTypeBuf = new .(256) ~ delete _;
		TextBuffer mParamsBuf = new .(512) ~ delete _;
		bool mOpenFilePopup;
		bool mOpenFolderPopup;
		bool mOpenAddFunction;
		bool mAddCtorMode;       // the Add Function dialog adds a constructor
		int32 mCtorAccess;
		bool mAddSetOnCreate;
		bool mAddStatic;
		int32 mCtorChain;
		bool mOpenAddVariable;
		/// Add Variable / Add Function asked for while no document is loaded (they need a selected type).
		int mDialogRefusals;
		bool mOpenRename;
		Member mRenameTarget;
		int32 mRenameVersion;
		String mRenameKey = new .() ~ delete _;
		String mAddTargetType = new .() ~ delete _;
		int32 mContextNode;
		bool mOpenNodeContext;
		String mBrowseDir = new .() ~ delete _;

		// Details / source panels
		TextBuffer mFieldBuf = new .(4096) ~ delete _;
		TextBuffer mSourceBuf = new .(1 << 20) ~ delete _;
		int32 mSourceVersion = -1;
		bool mSourceDirty;
		/// Beef Source > File scrolls to this line (1-based) on its next frame; 0 = none.
		int32 mSourceScrollLine;
		bool mDetailsEditPushed;
		bool mFocusCodeField;
		ImFont* mMono;

		// Function details buffers (re-synced when the function changes)
		String mDetailsFor = new .() ~ delete _;
		TextBuffer mFnName = new .(256) ~ delete _;
		TextBuffer mFnReturn = new .(256) ~ delete _;
		TextBuffer mFnParams = new .(1024) ~ delete _;

		/// The pre-JSON session file in the working directory (read once for migration, never written).
		const String cLegacySettingsFile = "VisualBeef_settings.txt";

		// Compile (BeefBuild)
		BuildRunner mBuild ~ delete _;
		String mBeefBuildPath = new .() ~ delete _;
		bool mSelectResultsTab;

		/// Bumped when the default dock layout changes, so saved layouts are rebuilt once.
		const int32 cLayoutVersion = 5;
		int32 mLayoutVersion;
		/// Frames until the Project Browser tab is brought to front after a layout rebuild.
		int32 mFocusCBFrames;

		public this()
		{
			Doc = mEmptyDoc;
			GraphBuilder.Index = Index;
			mGraphPanel = new GraphPanel(this);
			mNodeMenu = new NodeMenu(this);
			LoadSettings();
			if (mBeefBuildPath.IsEmpty)
			{
#if BF_PLATFORM_WINDOWS
				mBeefBuildPath.Set("C:\\Program Files\\BeefLang\\bin\\BeefBuild.exe");
#else
				mBeefBuildPath.Set("BeefBuild");
#endif
			}
		}

		// ------------------------------------------------------------------ status & settings

		public void SetStatus(StringView text)
		{
			// Every status message also lands in the Output Log; failures get a toast too.
			bool failure = text.StartsWith("Could not") || text.StartsWith("Save failed") || text.Contains(" failed") ||
				text.StartsWith("No BeefSpace") || text.StartsWith("Can't") || text.Contains("can't") ||
				text.StartsWith("Not saved") || text.Contains("cancelled");
			SetStatus(text, failure ? .Warning : .Info, failure);
		}

		/// Status bar text plus an Output Log entry at an explicit level (toast when `toast`).
		public void SetStatus(StringView text, LogLevel level, bool toast = true)
		{
			mStatus.Set(text);
			mStatusTime = Gui.igGetTime();
			Notify.Post(level, "Editor", text, toast);
		}

		/// Shows a failure where it can't be missed (modal), logs it as an error and mirrors it
		/// in the status bar.
		public void ReportError(StringView msg)
		{
			SetStatus(msg, .Error, false); // the modal is the notification; no toast on top
			mErrors.Add(new String(msg));
		}

		/// False (with a warning) in a read-only project.
		public bool CheckWritable()
		{
			if (!FileSafety.ReadOnlyProject)
				return true;
			SetStatus(FileSafety.ReadOnlyMessage, .Warning);
			return false;
		}

		/// Session state from settings.json ("session" and "beefBuild"); see Settings.
		void LoadSettings()
		{
			Settings.Load();
			let s = Settings.Root.Get("session");
			if (s == null)
			{
				LoadLegacySettings();
				return;
			}
			// The last project and its tabs are not reopened: with no project on the command line the start page shows.
			mBeefBuildPath.Set(Settings.Root.GetString("beefBuild"));
			mCBTileSize = (float)s.GetNumber("cbTile", mCBTileSize);
			mLayoutVersion = (int32)s.GetNumber("layoutVersion", mLayoutVersion);
		}

		void LoadLegacySettings()
		{
			String content = scope .();
			if (File.ReadAllText(cLegacySettingsFile, content) case .Err)
				return;
			for (var line in content.Split('\n'))
			{
				line.Trim();
				if (line.StartsWith("beefbuild="))
					mBeefBuildPath.Set(line.Substring(10));
				else if (line.StartsWith("cbtile="))
				{
					if (float.Parse(line.Substring(7)) case .Ok(let v))
						mCBTileSize = v;
				}
				else if (line.StartsWith("layoutver="))
				{
					if (int32.Parse(line.Substring(10)) case .Ok(let v))
						mLayoutVersion = v;
				}
			}
		}

		public void SaveSettings()
		{
			Settings.Load();
			let s = Settings.Session;
			// Older versions kept the open project and tabs here; nothing is reopened now, so they are dropped.
			s.Remove("root");
			s.Remove("file");
			s.Remove("tabs");
			s.Remove("cbFolder");
			s.Set("cbTile", Json.NewNumber((int)mCBTileSize));
			s.Set("layoutVersion", Json.NewNumber(mLayoutVersion));
			Settings.Root.Set("beefBuild", Json.NewString(mBeefBuildPath));
			Settings.Save();
		}

		/// The command line, already parsed and resolved by Program (EditorArgs / ProjectContract): `root` is the
		/// project folder to open, `file` the file to focus (either may be empty).
		public void HandleArgs(EditorArgs args, StringView root, StringView file)
		{
			// Nothing to open: the start page (Recent projects, Open project, New project, Documentation) shows.
			if (args.IsEmpty)
				return;
			// --view: open read-only (nothing is ever written to the project).
			if (args.View)
				FileSafety.ReadOnlyProject = true;
			if (root.IsEmpty)
				return;
			// The root first, so opening the file does not adopt the file's own folder as the project.
			mProjectRoot.Set(root);
			if (!file.IsEmpty && File.Exists(file))
				OpenFile(scope String(file));
			else if (!file.IsEmpty)
				Notify.Log(.Warning, "Editor", scope $"{file} does not exist; opening the project only");
			ScanProject();
			RememberProject(root);
			Notify.Log(.Info, "Editor", scope $"Opened {root} (focus: {file})");
		}

		// ------------------------------------------------------------------ files

		/// Re-indexes the project folder and rebuilds the Project Browser's folder tree. Frees
		/// every index string: never call it while something iterates the index.
		///
		/// A new root (or one whose first indexing did not finish) is indexed in the background
		/// (StartIndexing; the Project Browser fills in when it is done). A rescan of the same
		/// root is synchronous and incremental: only files whose size or time changed are parsed.
		void ScanProject()
		{
			ClearAndDeleteItems!(mProjectFiles);
			TrimSeparators(mProjectRoot);
			if (mProjectRoot.IsEmpty || !Directory.Exists(mProjectRoot))
			{
				CancelIndexing(false);
				mIndexReady = false;
				Index.Clear();
				BuildContentTree();
				mCBSignature = 0;
				return;
			}
			if (mIndexReady && mIndexJob == null && ProjectIndex.SamePath(Index.Root, mProjectRoot))
			{
				Index.Build(mProjectRoot);
				FinishScan();
				return;
			}
			if (!ProjectIndex.SamePath(Index.Root, mProjectRoot))
			{
				Index.Clear();
				Index.Root.Set(mProjectRoot);
				for (let d in mDocs)
					if (d.Unit != null && d.FilePath.StartsWith(mProjectRoot))
						Index.Update(d.FilePath, d.Unit);
			}
			BuildContentTree();
			StartIndexing();
		}

		public SourceDocument FindDoc(StringView path)
		{
			for (let d in mDocs)
				if (ProjectIndex.SamePath(d.FilePath, path))
					return d;
			return null;
		}

		public void RequestOpen(StringView path)
		{
			OpenFile(path);
		}

		/// Opens a file (or switches to it if it's already open) and shows a function graph.
		public SourceDocument OpenFile(StringView path, bool openFirstGraph = true)
		{
			var doc = FindDoc(path);
			if (doc == null)
			{
				doc = new SourceDocument();
				if (doc.Load(path) case .Err)
				{
					delete doc;
					SetStatus(scope $"Could not open {path}");
					return null;
				}
				if (File.GetLastWriteTime(path) case .Ok(let t))
					doc.DiskTime = t;
				mDocs.Add(doc);
				Index.Update(doc.FilePath, doc.Unit);
				doc.IndexedVersion = doc.Version;
				if (mProjectRoot.IsEmpty)
				{
					String dir = scope .();
					Path.GetDirectoryPath(path, dir).IgnoreError(); // a root has no parent: dir stays empty
					mProjectRoot.Set(dir);
					ScanProject();
					RememberProject(dir);
				}
			}
			Doc = doc;
			mSourceVersion = -1;
			mSourceDirty = false;
			if (openFirstGraph)
			{
				// Prefer a tab that's already open for this file.
				bool found = false;
				for (let tab in Tabs)
				{
					if (tab.Doc == doc)
					{
						ActiveTab = @tab.Index;
						mSelectTab = tab;
						mLastActiveTab = tab;
						found = true;
						break;
					}
				}
				if (!found)
				{
					for (let mg in doc.Methods)
					{
						if (mg.Graphable)
						{
							OpenTab(mg);
							break;
						}
					}
				}
			}
			SetStatus(scope $"Opened {path}");
			SaveSettings();
			UpdateTitle();
			return doc;
		}

		/// Opens the graph of a function by type and name, anywhere in the project.
		public bool OpenFunction(StringView filePathIn, StringView typeNameIn, StringView methodNameIn, int32 line = -1)
		{
			// Copy first: opening a file re-indexes it, which frees index strings we may have been given.
			String filePath = scope .(filePathIn);
			String typeName = scope .(typeNameIn);
			String methodName = scope .(methodNameIn);
			let doc = OpenFile(filePath, false);
			if (doc == null)
				return false;
			MethodGraph best = null;
			for (let mg in doc.Methods)
			{
				if (mg.Method.Name == methodName && mg.Graphable && (typeName.IsEmpty || (mg.Owner != null && mg.Owner.Name == typeName)))
				{
					// Overloads share a name: the declaration line picks the right one.
					if (line >= 0 && MethodLine(doc, mg) == line)
					{
						best = mg;
						break;
					}
					if (best == null)
						best = mg;
				}
			}
			if (best == null)
				return false;
			OpenTab(best);
			return true;
		}

		static int32 MethodLine(SourceDocument doc, MethodGraph mg)
		{
			if (!mg.Method.HasSpan)
				return -1;
			return (.)doc.Unit.LineOf(doc.Unit.Tokens[mg.Method.FirstTok].Start);
		}

		/// A failed write of a layout side file is told once (until a write works again).
		void ReportLayoutError(SourceDocument doc)
		{
			if (doc.LayoutError.IsEmpty)
			{
				doc.LayoutErrorReported = false;
				return;
			}
			if (doc.LayoutErrorReported)
				return;
			doc.LayoutErrorReported = true;
			Notify.Warn(scope $"Node positions of {doc.FilePath} were not saved: {doc.LayoutError}");
		}

		bool SaveDoc(SourceDocument doc, bool force = false)
		{
			if (doc.FilePath.IsEmpty)
				return false;
			switch (doc.TrySave(force))
			{
			case .Saved:
				ReportLayoutError(doc);
				InvalidateCompileHash();
				if (File.GetLastWriteTime(doc.FilePath) case .Ok(let t))
					doc.DiskTime = t;
				doc.ExternalChange = false;
				return true;
			case .Conflict:
				if (!mConflicts.Contains(doc))
					mConflicts.Add(doc);
				SetStatus(scope $"Not saved: {doc.FilePath} changed on disk");
				return false;
			case .ReadOnly:
				SetStatus(FileSafety.ReadOnlyMessage, .Warning);
				return false;
			case .Failed:
				ReportError(scope $"Save failed: {doc.LastError}. The original file is untouched.");
				return false;
			case .GraphErrors:
				// Safety rule: a graph with errors is never saved as if its edits were written.
				SetStatus(scope $"Not saved: {doc.FilePath}: {doc.LastError}", .Error);
				return false;
			case .NoPath:
				return false;
			}
		}

		public void Save()
		{
			if (Doc.FilePath.IsEmpty)
				return;
			if (SaveDoc(Doc))
				SetStatus(scope $"Saved {Doc.FilePath}");
			mLayoutDirty = false;
			UpdateTitle();
		}

		/// Saves every modified file. False when any save was refused (conflict, read-only,
		/// failure): callers that go on regardless (compile, quit) should stop.
		public bool SaveAll()
		{
			int count = 0;
			bool allOk = true;
			for (let d in mDocs)
			{
				// NeedsSave: graph edits not written (a refused commit) are refused here with their
				// reason, so quitting through Save All stays open instead of losing them.
				if (d.NeedsSave)
				{
					if (SaveDoc(d))
						count++;
					else
						allOk = false;
				}
				else if (!d.FilePath.IsEmpty)
				{
					d.SaveLayout();
					ReportLayoutError(d);
				}
			}
			mLayoutDirty = false;
			if (allOk)
				SetStatus(scope $"Saved {count} file(s)");
			UpdateTitle();
			return allOk;
		}

		int ModifiedCount
		{
			get
			{
				int count = 0;
				for (let d in mDocs)
					if (d.NeedsSave)
						count++;
				return count;
			}
		}

		void ReloadFromDisk(SourceDocument doc)
		{
			String path = scope .(doc.FilePath);
			doc.CaptureAllLayouts();
			String text = scope .();
			if (File.ReadAllText(path, text, true) case .Err)
			{
				// Gone, locked or unreadable: the text in the editor stays as it is, nothing is lost.
				SetStatus(scope $"Could not reload {path}: the file cannot be read. Your text in the editor is unchanged.", .Warning);
				return;
			}
			doc.ApplyText(text);
			doc.MarkSavedFromDisk(text);
			if (File.GetLastWriteTime(path) case .Ok(let t))
				doc.DiskTime = t;
			doc.ExternalChange = false;
			if (doc == Doc)
				mSourceVersion = -1;
			SetStatus(scope $"Reloaded {path} from disk");
		}

		void ReloadFromDisk()
		{
			if (!Doc.FilePath.IsEmpty)
				ReloadFromDisk(Doc);
		}

		void CheckExternalChange()
		{
			for (let doc in mDocs)
			{
				if (doc.FilePath.IsEmpty || doc.ExternalChange)
					continue;
				if (File.GetLastWriteTime(doc.FilePath) case .Ok(let t))
				{
					if (t != doc.DiskTime)
					{
						// Unsaved text or graph edits not written: never reloaded on its own (the
						// changed-on-disk banner asks).
						if (!doc.NeedsSave)
							ReloadFromDisk(doc);
						else
							doc.ExternalChange = true;
					}
				}
			}
		}

		/// The window title follows the active tab (see Shell.bf: UpdateWindowTitle).
		void UpdateTitle()
		{
			UpdateWindowTitle();
		}

		// ------------------------------------------------------------------ tabs & graphs

		public GraphTab CurrentTab => (ActiveTab >= 0 && ActiveTab < Tabs.Count) ? Tabs[ActiveTab] : null;

		public MethodGraph CurrentMethod
		{
			get
			{
				let tab = CurrentTab;
				if (tab == null)
					return null;
				return tab.Doc.FindMethod(tab.MethodKey);
			}
		}

		public void OpenTab(MethodGraph mg)
		{
			for (let tab in Tabs)
			{
				if (tab.Doc == mg.Doc && tab.MethodKey == mg.Key)
				{
					ActiveTab = @tab.Index;
					tab.Open = true;
					mSelectTab = tab;
					mLastActiveTab = tab;
					Doc = tab.Doc;
					return;
				}
			}
			String title = scope .();
			if (mg.Owner != null)
				title.AppendF("{}.", mg.Owner.Name);
			AppendSheetName(title, mg);
			GraphTab tab = new .(mg.Doc, mg.Key, title);
			Tabs.Add(tab);
			ActiveTab = Tabs.Count - 1;
			mSelectTab = tab;
			mLastActiveTab = tab;
			Doc = mg.Doc;
		}
		GraphTab mSelectTab;

		public void LayoutChanged()
		{
			EditDoc.LayoutTouched = true;
			mLayoutDirty = true;
		}

		/// Call before mutating a graph: records an undo step.
		public void BeginEdit()
		{
			EditDoc.PushUndo();
		}

		/// The document graph edits apply to: the active tab's file.
		public SourceDocument EditDoc => (CurrentTab != null) ? CurrentTab.Doc : Doc;

		bool mCommitPending;

		/// Writes the current graph back into the source. The commit happens at the end of the
		/// frame, because it re-parses the file (graph objects are kept, but MethodGraph wrappers are
		/// recreated) and panels may still be using them.
		public void CommitCurrent()
		{
			mCommitPending = true;
		}

		void DoCommit()
		{
			mCommitPending = false;
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			KeyAssigner.Assign(mg.Graph);
			ClearAndDeleteItems!(tab.ReselectKeys);
			for (let id in tab.SelectedNodes)
			{
				let n = mg.Graph.FindNode(id);
				if (n != null)
					tab.ReselectKeys.Add(new String(n.Key));
			}
			let doc = tab.Doc;
			String key = scope .(mg.Key);
			let graph = mg.Graph;
			doc.Commit(mg);
			if (!doc.Messages.IsEmpty)
				SetStatus(doc.Messages[0]);
			ReportGraphIssues(doc, key, graph);
			mDetailsEditPushed = false;
			UpdateTitle();
		}

		/// What the last commit reported, so the same problems are not logged again each edit.
		String mLastGraphIssues = new .() ~ delete _;
		/// Graphs (by Graph.Serial) already checked since they were built.
		HashSet<int32> mCheckedGraphs = new .() ~ delete _;

		/// Runs GraphValidator and the generator's checks on a graph the first time it is shown,
		/// without writing anything, so the errors and warnings of the code as read are on the
		/// nodes (and in the Output Log) before the first edit. Every edit checks again.
		public void EnsureChecked(MethodGraph mg)
		{
			let g = mg.Graph;
			if (g.ReadOnly || !mg.Graphable || !mCheckedGraphs.Add(g.Serial))
				return;
			String body = scope .();
			mg.Doc.GenerateMethodBody(mg, body);
			if (!g.Errors.IsEmpty || !g.Warnings.IsEmpty)
				ReportGraphIssues(mg.Doc, mg.Key, g);
		}

		/// Puts GraphValidator / generator errors and warnings of a graph in the Output Log (the
		/// nodes show them too: red outline and ERROR badge, yellow WARNING badge, tooltips).
		void ReportGraphIssues(SourceDocument doc, StringView methodKey, Graph graph)
		{
			String sig = scope .();
			sig.AppendF("{}|", methodKey);
			for (let e in graph.Errors)
				sig.AppendF("E{}:{}\n", e.NodeId, e.Message);
			for (let e in graph.Warnings)
				sig.AppendF("W{}:{}\n", e.NodeId, e.Message);
			if (sig == mLastGraphIssues)
				return;
			mLastGraphIssues.Set(sig);
			void Log(LogLevel level, GraphError e)
			{
				let node = graph.FindNode(e.NodeId);
				String title = scope .();
				node?.GetTitle(title);
				int32 line = (node != null && node.Line > 0) ? node.Line : ((graph.Entry != null) ? graph.Entry.Line : 0);
				Notify.LogAt(level, "Graph", scope $"{methodKey} - {title}: {e.Message}", doc.FilePath, line);
			}
			for (let e in graph.Errors)
				Log(.Error, e);
			for (let e in graph.Warnings)
				Log(.Warning, e);
		}

		public void AddArgument(Node node)
		{
			let mg = CurrentMethod;
			if (mg == null)
				return;
			BeginEdit();
			NodeFactory.AddArgument(mg.Graph, node);
			CommitCurrent();
		}

		public void RemoveArgument(Node node)
		{
			let mg = CurrentMethod;
			if (mg == null)
				return;
			BeginEdit();
			NodeFactory.RemoveLastArgument(mg.Graph, node);
			CommitCurrent();
		}

		public void DeleteSelection(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (mg == null || (tab.SelectedNodes.IsEmpty && tab.SelectedLinks.IsEmpty))
				return;
			BeginEdit();
			let g = mg.Graph;
			for (let id in tab.SelectedLinks)
			{
				let l = g.FindLink(id);
				if (l != null)
					g.Disconnect(l);
			}
			for (let id in tab.SelectedNodes)
			{
				let n = g.FindNode(id);
				if (n == null || n == g.Entry)
					continue;
				// Keep the flow intact: reconnect the node's predecessor to its successor.
				let execIn = n.ExecIn;
				let then = n.Then;
				if (execIn != null && then != null)
				{
					let inLink = g.FindLinkTo(execIn);
					let next = g.ExecTarget(then);
					if (inLink != null && next != null && n.Outputs.Count > 0)
					{
						bool simple = true;
						for (let p in n.Outputs)
							if (p.Kind == .Exec && p.Name != "then" && g.ExecTarget(p) != null)
								simple = false;
						if (simple)
						{
							let from = inLink.From;
							g.RemoveNode(n);
							g.Connect(from, next.ExecIn);
							continue;
						}
					}
				}
				g.RemoveNode(n);
			}
			tab.ClearSelection(); // canvas selection lives on the tab (was imnodes)
			CommitCurrent();
		}

		public void CopySelection(GraphTab tab)
		{
			let mg = CurrentMethod;
			if (mg == null || tab.SelectedNodes.IsEmpty)
				return;
			List<Node> nodes = scope .();
			for (let id in tab.SelectedNodes)
			{
				let n = mg.Graph.FindNode(id);
				if (n != null && n != mg.Graph.Entry)
					nodes.Add(n);
			}
			if (nodes.IsEmpty)
				return;
			KeyAssigner.Assign(mg.Graph);
			delete mClipboard;
			mClipboard = OrphanSet.CaptureNodes(mg.Graph, nodes);
			SetStatus(scope $"Copied {nodes.Count} node(s)");
		}

		/// Grid position at the centre of the visible canvas (where menu paste lands).
		public ImVec2 ViewCentre(GraphTab tab)
		{
			return tab.ScreenToGrid(.(tab.CanvasOrigin.x + tab.CanvasSize.x * 0.5f, tab.CanvasOrigin.y + tab.CanvasSize.y * 0.5f));
		}

		public void Paste(GraphTab tab, ImVec2 at)
		{
			let mg = CurrentMethod;
			if (mg == null || mClipboard == null || mClipboard.Nodes.IsEmpty)
				return;
			BeginEdit();
			float minX = float.MaxValue;
			float minY = float.MaxValue;
			for (let n in mClipboard.Nodes)
			{
				minX = Math.Min(minX, n.X);
				minY = Math.Min(minY, n.Y);
			}
			List<Node> added = scope .();
			mClipboard.InjectInto(mg.Graph, at.x - minX, at.y - minY, false, added);
			// The pasted nodes are the selection (all of them, the old selection cleared), so they drag as a group.
			if (tab != null && !added.IsEmpty)
			{
				tab.ClearSelection();
				for (let n in added)
					tab.AddToSelection(n.Id);
			}
			CommitCurrent();
		}

		public void DuplicateSelection(GraphTab tab)
		{
			CopySelection(tab);
			let mg = CurrentMethod;
			if (mg == null || mClipboard == null || mClipboard.Nodes.IsEmpty)
				return;
			Paste(tab, .(mClipboard.Nodes[0].X + 40, mClipboard.Nodes[0].Y + 40));
		}

		/// The wire to keep drawing while the Node menu is up for a dragged pin: the source pin id and
		/// the grid point the new node will go to (false when no pin menu is showing on `tab`).
		public bool PendingWire(GraphTab tab, Graph graph, out int32 pinId, out ImVec2 gridPos)
		{
			pinId = 0;
			gridPos = default;
			if (tab == null || tab != mActionTab || !mNodeMenu.PinMenuActive || mNodeMenu.ContextGraph != (Object)graph)
				return false;
			pinId = mNodeMenu.ContextPinId;
			gridPos = mNodeMenu.SpawnPos;
			return graph.FindPin(pinId) != null;
		}

		public void OpenNodeMenu(GraphTab tab, ImVec2 gridPos, int32 pinId)
		{
			mActionTab = tab;
			mNodeMenu.Open(CurrentMethod, gridPos, pinId);
		}

		/// Node hotkeys and favorites (settings.json `editor.nodeHotkeys` / `editor.favorites`).
		public NodeMenuPrefs NodePrefs
		{
			get
			{
				mNodeMenu.Prefs.Load();
				return mNodeMenu.Prefs;
			}
		}

		/// Node hotkeys (docs/Editor-UI.md, "Node hotkeys and favorites"): places the node bound to
		/// `letter` at `gridPos` exactly as choosing it in the Node menu would, wired to the pin
		/// `pinId` when a wire was being dragged from it (0 = none). False when the letter has no node
		/// or this Sheet does not offer it (the status bar says why).
		public bool PlaceHotkeyNode(GraphTab tab, char8 letter, ImVec2 gridPos, int32 pinId)
		{
			let mg = CurrentMethod;
			if (tab == null || mg == null || !mg.Graphable || mg.Graph.ReadOnly)
				return false;
			let nodeKey = NodePrefs.Hotkeys.NodeOf(letter);
			if (nodeKey.IsEmpty)
				return false;
			let item = mNodeMenu.ItemForKey(mg, gridPos, pinId, nodeKey);
			if (item == null)
			{
				SetStatus(scope $"Node hotkey {letter.ToUpper}: {VisualBeef.Catalog.NodeHotkeys.LabelOf(nodeKey)} is not offered in this Sheet.");
				return false;
			}
			defer delete item;
			mActionTab = tab;
			ExecuteAction(item);
			return true;
		}

		public void OpenNodeContext(int32 nodeId)
		{
			mContextNode = nodeId;
			mOpenNodeContext = true;
		}

		public void NodeDoubleClicked(Node node)
		{
			if (node == null)
				return;
			if (node.Kind == .Call)
			{
				// Jump to the function: this file first, then the rest of the project.
				let tabDoc = EditDoc;
				let target = node.FindInput("target");
				bool qualified = node.Binding == .Static && node.Qualifier != null && !node.Qualifier.IsEmpty;
				if (target == null && !qualified)
				{
					for (let mg in tabDoc.Methods)
					{
						if (mg.Method.Name == node.Text && mg.Graphable)
						{
							OpenTab(mg);
							return;
						}
					}
				}
				// The declaring type (static calls, member calls), else the typed target.
				SymbolType st = null;
				if (node.OwnerType != null && !node.OwnerType.IsEmpty)
					st = Index.FindType(node.OwnerType);
				if (st == null && target != null && !target.TypeName.IsEmpty)
					st = Index.FindType(target.TypeName);
				if (st == null && target != null && !target.Default.IsEmpty)
					st = Index.FindType(target.Default);
				SymbolMethod sm = st?.FindMethod(node.Text);
				if (sm == null)
					st = Index.FindMethodAnywhere(node.Text, out sm);
				if (st != null && sm != null && sm.HasBody && OpenFunction(st.FilePath, st.Name, node.Text, sm.Line))
					return;
				SetStatus(scope $"'{node.Text}' isn't defined in this project");
			}
			else if (node.Kind == .Code || node.Kind == .Expr || node.Kind == .For)
				mFocusCodeField = true;
		}

		/// A `VB_MEMBER` payload dropped on the Sheet at `pos` (grid), over pin `pinId` (0: none).
		/// A variable on a pin is wired to it (DropVariableOnPin); elsewhere Ctrl places a Get, Alt
		/// a Set, and a plain drop asks (a Node menu row places what it says).
		public void DropMember(GraphTab tab, int32 index, ImVec2 pos, int32 pinId = 0)
		{
			let m = DraggedRef(index);
			if (m == null)
				return;
			let mg = CurrentMethod;
			if (mg == null)
				return;
			if (m.MemberKind == .Variable && pinId != 0)
			{
				DropVariableOnPin(tab, mg, m.Name, m.Type, pinId);
				return;
			}
			bool asSet = Gui.IsAltDown;
			// UX: like UE, Ctrl+drop = Get, Alt+drop = Set, a plain drop asks (Get / Set menu).
			if (m.MemberKind == .Variable && !Gui.IsCtrlDown && !Gui.IsAltDown)
			{
				if (index != cMenuDragIndex)
				{
					mGraphPanel.ShowVariableDropMenu(m.Name, m.Type, pos);
					return;
				}
				asSet = mMenuDragIsSet;
			}
			BeginEdit();
			Node n;
			if (m.MemberKind == .Variable)
			{
				if (asSet)
					n = NodeFactory.Set(mg.Graph, m.Name, m.Type);
				else
					n = NodeFactory.Get(mg.Graph, m.Name, m.Type);
			}
			else
			{
				// The type's own function: static (no Target) or a member call on self.
				n = CreateCallNode(mg, m.Name, m.Params, m.Type, true, false, m.Owner, m.IsStatic);
			}
			n.X = Canvas.SnapIf(pos.x);
			n.Y = Canvas.SnapIf(pos.y);
			n.HasPos = true;
			tab.SelectOnly(n.Id); // UX: select the dropped node
			CommitCurrent();
		}

		/// A call node for a function known by name and parameter text ("int a, out int b = 2").
		///  - `memberCall`: a member function of `ownerType` with a Target pin (unconnected = self);
		///  - a dotted name ("Console.WriteLine"): a static call with that qualifier;
		///  - `ownerType` set: a function of the type being edited, static (`isStatic`, no Target)
		///    or a member call on self;
		///  - otherwise a call by name the generator writes as typed.
		/// `out` parameters become output pins, `ref` ones ref inputs, defaults go in the pins.
		Node CreateCallNode(MethodGraph mg, StringView name, StringView paramsText, StringView returnType, bool exec,
			bool memberCall = false, StringView ownerType = "", bool isStatic = false)
		{
			List<StringView> names = scope .();
			List<StringView> types = scope .();
			List<StringView> mods = scope .();
			List<StringView> defaults = scope .();
			// Split on top-level commas only ("Dictionary<int, String> map, int count").
			List<StringView> parts = scope .();
			{
				int depth = 0;
				int segStart = 0;
				for (int i < paramsText.Length)
				{
					let c = paramsText[i];
					if (c == '<' || c == '(' || c == '[')
						depth++;
					else if (c == '>' || c == ')' || c == ']')
						depth--;
					else if (c == ',' && depth == 0)
					{
						parts.Add(paramsText.Substring(segStart, i - segStart));
						segStart = i + 1;
					}
				}
				parts.Add(paramsText.Substring(segStart));
			}
			for (var part in parts)
			{
				StringView def = default;
				int eq = part.IndexOf('=');
				if (eq > 0)
				{
					def = part.Substring(eq + 1);
					def.Trim();
					part = part.Substring(0, eq);
				}
				part.Trim();
				if (part.IsEmpty)
					continue;
				int space = part.LastIndexOf(' ');
				if (space > 0)
				{
					var t = part.Substring(0, space);
					t.Trim();
					NodeFactory.SplitModifier(t, let modifier, let type);
					types.Add(type);
					mods.Add(modifier);
					names.Add(part.Substring(space + 1));
				}
				else
				{
					names.Add(part);
					types.Add("");
					mods.Add("");
				}
				defaults.Add(def);
			}
			String ret = scope .(returnType);
			if (ret.IsEmpty)
				ret.Set("void");
			Node n;
			int dot = name.LastIndexOf('.');
			if (memberCall)
				n = NodeFactory.MemberCall(mg.Graph, name, ownerType, exec, names, types, ret, mods);
			else if (dot > 0)
			{
				// "Console.WriteLine": a static call, exactly like the parsed code.
				let qualifier = name.Substring(0, dot);
				String owner = scope .();
				NodeFactory.OwnerOfQualifier(qualifier, owner);
				n = NodeFactory.StaticCall(mg.Graph, name.Substring(dot + 1), qualifier, owner, exec, names, types, ret, mods);
			}
			else if (!ownerType.IsEmpty && isStatic)
				n = NodeFactory.StaticCall(mg.Graph, name, "", ownerType, exec, names, types, ret, mods);
			else if (!ownerType.IsEmpty)
				n = NodeFactory.MemberCall(mg.Graph, name, ownerType, exec, names, types, ret, mods);
			else
			{
				StringView[0] none = .();
				n = NodeFactory.Call(mg.Graph, name, exec, false, "", none, none, ret);
				for (int i < names.Count)
				{
					let p = NodeFactory.AddArgument(mg.Graph, n);
					p.Label.Set(names[i]);
					p.TypeName.Set(types[i]);
				}
			}
			for (int i < defaults.Count)
			{
				if (defaults[i].IsEmpty)
					continue;
				let p = n.FindInput(scope $"arg{i}");
				if (p != null)
					p.Default.Set(defaults[i]);
			}
			return n;
		}

		/// After a wire or a typed value changed a call's inputs: the call shows the overload those
		/// values choose (CallOverloads.Refit; docs/Calls-and-Receivers.md#overloads). True when it changed.
		public bool RefitCall(VisualBeef.Graph.Graph g, Node n)
		{
			if (g == null || n == null || n.Kind != .Call)
				return false;
			return CallOverloads.Refit(g, n, VisualBeef.Catalog.TypeService.Current);
		}

		/// A parameter, local or field of the function being edited named `name`; its type.
		bool FindVariable(MethodGraph mg, StringView name, String outType)
		{
			for (let p in mg.Method.Params)
				if (p.Name == name)
				{
					outType.Set(p.Type);
					return true;
				}
			for (let n in mg.Graph.Nodes)
				if ((n.Kind == .LocalVar || n.Kind == .ForEach) && n.Text == name)
				{
					outType.Set(n.Text2);
					return true;
				}
			if (mg.Owner != null && mg.Owner.Members != null)
				for (let m in mg.Owner.Members)
					if ((m.Kind == .Field || m.Kind == .Property) && m.Name == name)
					{
						if (m.TypeText != null)
							outType.Set(m.TypeText);
						return true;
					}
			return false;
		}

		void ExecuteAction(NodeItem item)
		{
			let tab = mActionTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			let g = mg.Graph;
			BeginEdit();
			int32 maxIdBefore = 0;
			for (let o in g.Nodes)
				maxIdBefore = Math.Max(maxIdBefore, o.Id);
			Pin contextPin = (mNodeMenu.ContextPinId != 0) ? g.FindPin(mNodeMenu.ContextPinId) : null;
			// UX: calls made for a data input are pure. From a data output they're statements when
			// they return nothing or follow a statement (auto-chained after it), pure otherwise.
			bool wantExec = true;
			if (contextPin != null && contextPin.Kind == .Data)
			{
				if (contextPin.IsInput)
					wantExec = false;
				else
					wantExec = item.C.IsEmpty || item.C == "void" || contextPin.Owner.IsExecNode;
			}

			// Catalog entries (project + libraries): typed pins, default values, [Pure] (NodeMenu).
			Node n = mNodeMenu.CreateCatalogNode(g, item, wantExec);
			bool loopBreakChain = false;
			if (n == null)
			switch (item.Kind)
			{
			case .CallMethod:
				// The type's own functions carry their type (static or self); "Console.WriteLine"
				// style entries are static calls by their dotted name.
				n = CreateCallNode(mg, item.A, item.B, item.C, wantExec, false, item.OnType, item.Static);
			case .CallInstance:
				n = CreateCallNode(mg, item.A, item.B, item.C, wantExec, true, item.OnType);
				if (!item.OnType.IsEmpty && n.FindInput("target") != null) // UX: typed target ("Receiver is T")
					n.FindInput("target").TypeName.Set(item.OnType);
			case .This:
				n = NodeFactory.This(g, (mg.Owner != null) ? (StringView)mg.Owner.Name : "");
			case .Base:
				String parent = scope:: .();
				VisualBeef.Catalog.ClassModel.BaseClassOf(mg.Doc.Unit, mg.Owner, parent);
				n = NodeFactory.Base(g, parent);
			case .CallCustom:
				StringView[0] none = .();
				// "obj.Foo" on a variable of this function or type: a member call with obj wired
				// into Target (what the code reads back as); "Type.Foo": a static call.
				int dot = item.A.LastIndexOf('.');
				StringView qualifier = (dot > 0) ? item.A.Substring(0, dot) : "";
				String varType = scope .();
				if (!qualifier.IsEmpty && FindVariable(mg, qualifier, varType))
				{
					n = NodeFactory.Call(g, item.A.Substring(dot + 1), wantExec, true, "", none, none, "var");
					let v = NodeFactory.Get(g, qualifier, varType);
					g.Connect(v.Result, n.FindInput("target"));
				}
				else
					n = NodeFactory.Call(g, item.A, wantExec, false, "", none, none, "var");
			case .CallMember:
				StringView[0] none = .();
				n = NodeFactory.Call(g, item.A, wantExec, true, "", none, none, "var");
			case .GetVar:
				n = NodeFactory.Get(g, item.A, item.B);
			case .SetVar:
				n = NodeFactory.Set(g, item.A, item.B);
			case .LocalVar:
				String varName = scope:: .(); // UX: unique local name
				GraphPanel.UniqueLocalName(mg, "newVar", varName);
				n = NodeFactory.LocalVar(g, varName, "var");
			case .Branch:
				n = NodeFactory.Branch(g);
			case .While:
				n = NodeFactory.Loop(g, .While);
			case .DoWhile:
				n = NodeFactory.Loop(g, .DoWhile);
			case .For:
				n = NodeFactory.Loop(g, .For);
			case .ForEach:
				n = NodeFactory.Loop(g, .ForEach);
			case .Return:
				n = NodeFactory.Return(g, (mg.Method.TypeText != null) ? mg.Method.TypeText : "void");
				NodeFactory.AddReturnOutPins(g, n, mg.Method, true);
			case .Break:
				n = NodeFactory.Jump(g, .Break);
			case .Continue:
				n = NodeFactory.Jump(g, .Continue);
			case .Code:
				n = NodeFactory.Code(g, (item.A == "delete") ? "delete obj;" : "{ /* your Beef code here */ }");
			case .Switch:
				List<StringView> labels = scope .();
				for (let part in item.B.Split('\n'))
					if (!part.IsEmpty)
						labels.Add(part);
				n = NodeFactory.Switch(g, item.A.IsEmpty ? "var" : item.A, labels);
			case .Flow:
				HashSet<String> ownerFields = scope .();
				defer { for (let s in ownerFields) delete s; }
				mg.Doc.GetOwnerFieldNames(mg, ownerFields);
				int arms = 2;
				if (!item.B.IsEmpty && (int.Parse(item.B) case .Ok(let parsed)))
					arms = parsed;
				n = NodeFactory.Flow(g, item.A, ownerFields, arms);
			case .LoopBreak:
				// A loop with `if (false) break;` in its body, the Blueprint "with Break" loops.
				n = NodeFactory.Loop(g, (item.A == "foreach") ? .ForEach : .For);
				let brk = NodeFactory.Branch(g);
				brk.FindInput("condition").Default.Set("false");
				let jump = NodeFactory.Jump(g, .Break);
				g.Connect(n.FindOutput("body"), brk.ExecIn);
				g.Connect(brk.FindOutput("true"), jump.ExecIn);
				loopBreakChain = true; // positioned below, once the loop itself has its place
			case .Expr:
				n = NodeFactory.Expr(g, item.A.IsEmpty ? "0" : item.A);
				if (!item.B.IsEmpty && n.Result != null) // UX: typed literal (pin colour)
					n.Result.TypeName.Set(item.B);
			case .Operator:
				n = NodeFactory.Operator(g, item.A, item.B == "2");
			case .Select:
				n = NodeFactory.Select(g);
			case .Cast:
				n = NodeFactory.Cast(g, item.A.IsEmpty ? "int" : item.A); // UX: "Cast To T" from a T input
			case .Index:
				n = NodeFactory.Index(g);
			case .GetMember:
				n = NodeFactory.GetMember(g, "Member");
			case .GetField: // UX: `target.Field` on the dragged object
				n = NodeFactory.GetMember(g, item.A);
				if (n.Result != null)
					n.Result.TypeName.Set(item.B);
			case .Construct:
				StringView[0] none = .();
				// A class of this file with a create constructor ("Set on create" variables), or with
				// exactly one constructor that has parameters, spawns with one input per parameter.
				List<StringView> ctorNames = scope .();
				List<StringView> ctorTypes = scope .();
				Member createType = null;
				// The document that declares the type: this one, an open one, or the project file read
				// for the moment (a class of another file gets its constructor's inputs too).
				SourceDocument typeDoc = mg.Doc;
				SourceDocument tempDoc = null;
				defer { delete tempDoc; }
				if (item.C != "array" && item.A != "." && item.A != "$" && mg.Doc != null && mg.Doc.Unit != null && FindTypeIn(mg.Doc, item.A) == null)
				{
					typeDoc = null;
					for (let f in Index.Files)
					{
						bool declares = false;
						for (let t in f.Types)
							if (t.Name == item.A && t.Outer.IsEmpty)
								declares = true;
						if (!declares)
							continue;
						typeDoc = FindDoc(f.Path);
						if (typeDoc == null)
						{
							tempDoc = new SourceDocument();
							if (tempDoc.Load(f.Path) case .Err)
								DeleteAndNullify!(tempDoc);
							typeDoc = tempDoc;
						}
						break;
					}
				}
				if (item.C != "array" && item.A != "." && item.A != "$" && typeDoc != null && typeDoc.Unit != null)
				{
					List<Member> allTypes = scope .();
					typeDoc.Unit.CollectTypes(allTypes);
					for (let t in allTypes)
					{
						if (t.Name != item.A || t.Members == null)
							continue;
						Member pick = typeDoc.FindCreateConstructor(t);
						if (pick == null)
						{
							// No create constructor: the only constructor with parameters; or, when
							// there are several and none without parameters, the first one (Beef has
							// no `new T()` for that type, so the inputs of one are needed).
							int withParams = 0;
							bool plain = false;
							bool anyCtor = false;
							Member first = null;
							for (let m in t.Members)
							{
								if (m.Kind != .Method || !m.IsCtor || m.IsStatic || m.IsDtor)
									continue;
								anyCtor = true;
								if (m.Params != null && m.Params.Count > 0)
								{
									withParams++;
									pick = m;
									if (first == null)
										first = m;
								}
								else
									plain = true;
							}
							if (withParams != 1)
								pick = (anyCtor && !plain && t.TypeKind == "class") ? first : null;
						}
						if (pick != null && pick == typeDoc.FindCreateConstructor(t))
							createType = t;
						if (pick != null)
							for (let p in pick.Params)
							{
								ctorNames.Add(p.Name);
								ctorTypes.Add(p.Type);
							}
						break;
					}
				}
				if (ctorNames.Count > 0)
				{
					n = NodeFactory.Construct(g, item.A, item.B, Span<StringView>(ctorNames.Ptr, ctorNames.Count), Span<StringView>(ctorTypes.Ptr, ctorTypes.Count), false);
					// Set on create inputs start with the variable's initial value (or `default`).
					List<String> defaults = scope .();
					defer { for (let s in defaults) delete s; }
					if (createType != null)
						typeDoc.GetCreateDefaults(createType, defaults);
					for (int di < defaults.Count)
					{
						let pin = n.FindInput(scope $"arg{di}");
						if (pin != null && di < ctorNames.Count)
							pin.Default.Set(defaults[di]);
					}
				}
				else
					n = NodeFactory.Construct(g, item.A, item.B, none, none, item.C == "array");
			case .Delete:
				n = NodeFactory.Delete(g, item.A);
			case .Defer:
				n = NodeFactory.Defer(g);
			case .Using:
				n = NodeFactory.Using(g);
			case .ResultMatch:
				n = NodeFactory.ResultMatch(g, item.A != "Err");
			case .Scope:
				n = NodeFactory.Scope(g);
			case .Lambda:
				n = NodeFactory.Lambda(g, item.A, item.C == "block", item.B, (item.C == "block" && item.B == "scope") ? "[&]" : "");
			case .Delegate:
				n = NodeFactory.DelegateOf(g, item.A, item.B);
			case .LocalFunc:
				n = NodeFactory.LocalFunc(g, item.A, item.C != "expr");
			case .Format:
				n = NodeFactory.Format(g, item.A);
			case .MathExpr:
				n = NodeFactory.MathExpr(g, item.A.IsEmpty ? "a + b" : item.A);
			}
			if (n == null)
				return;
			// Placed nodes snap to the grid like dragged ones (UE).
			n.X = Canvas.SnapIf(mNodeMenu.SpawnPos.x);
			n.Y = Canvas.SnapIf(mNodeMenu.SpawnPos.y);
			n.HasPos = true;

			// UX: wire to the pin the user dragged from, choosing the best pin by kind and type
			// (Blueprint behavior). Dragged from an input, the node goes left of the mouse.
			if (contextPin != null)
			{
				if (contextPin.IsInput)
					n.X -= 240;
				NodeMenu.WireToContext(g, n, contextPin, item);
				if (n.Kind == .ResultMatch || n.Kind == .Construct)
					LifetimeWired(g, n);
			}
			// Companions a single entry spawns (the Branch and Break of a loop with Break) are
			// spaced like Arrange does; the whole group then steps clear of existing nodes so a
			// new Switch / Flow node never lands on top of another one.
			LayeredArrange.SizeFn sizeOf = scope (nd, w, h) => mGraphPanel.GetNodeSize(nd.Id, out w, out h);
			List<Node> fresh = scope .();
			for (let o in g.Nodes)
				if (o.Id > maxIdBefore)
					fresh.Add(o);
			if (loopBreakChain)
				LayeredArrange.ArrangeFrom(g, n, fresh, sizeOf);
			LayeredArrange.AvoidOverlap(g, fresh, sizeOf);
			// Select the spawned node like Blueprints (re-selected by key after the commit).
			if (mActionTab != null)
				mActionTab.SelectOnly(n.Id);
			CommitCurrent();
		}

		/// After auto-wiring a lifetime node: a Result node takes the type of the Result wired into
		/// it (and its payload the T); a `.()` Construct shows the type of the input it feeds.
		static void LifetimeWired(VisualBeef.Graph.Graph g, Node n)
		{
			if (n.Kind == .ResultMatch)
			{
				let v = n.FindInput("value");
				let link = (v != null) ? g.FindLinkTo(v) : null;
				if (link != null && !link.From.TypeName.IsEmpty)
				{
					v.TypeName.Set(link.From.TypeName);
					NodeFactory.SetResultPayloadType(n);
				}
				return;
			}
			if (n.Text == "." && n.Result != null && n.Result.TypeName.IsEmpty)
			{
				let link = g.FindLinkFrom(n.Result);
				if (link != null)
					n.Result.TypeName.Set(link.To.TypeName);
			}
		}

		// ------------------------------------------------------------------ compile

		/// `configOverride` ("Debug" for Start Debugging) replaces the project's configuration.
		/// When nothing BeefBuild reads changed since the last successful compile of that
		/// configuration and its output is unchanged, BeefBuild is not run (BuildInputs);
		/// `force` (Build > Force Compile) always runs it. `lowerPriority`: BeefBuild runs at
		/// BelowNormal (the build before debugging).
		public void Compile(StringView configOverride = default, bool force = false, bool lowerPriority = false)
		{
			let callWatch = scope System.Diagnostics.Stopwatch(true);
			defer { CompileCallMs = callWatch.Elapsed.TotalMilliseconds; }
			if (Doc.FilePath.IsEmpty && mProjectRoot.IsEmpty)
			{
				SetStatus("Open a project first");
				return;
			}
			if (mBuild != null && mBuild.Running)
				return;
			if (!SaveAll())
			{
				SetStatus("Compile cancelled: some files could not be saved.");
				return;
			}
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
			{
				SetStatus("No BeefSpace.toml found - can't compile");
				return;
			}
			String config = scope .();
			String reason = scope .();
			ResolveCompileConfig(ws, config, reason);
			if (!configOverride.IsEmpty)
			{
				config.Set(configOverride);
				reason.Set("for debugging");
			}
			// What the last successful compile was built from: with the same inputs BeefBuild
			// would only build the same output again. Its messages (warnings) are shown again; a
			// record from an earlier session is used only when it had no messages to show.
			CompileInputs skipIf = null;
			List<Diagnostic> carried = null;
			if (!force)
			{
				bool sameRun = mBuild != null && !mBuild.Running && mBuild.Succeeded && !mBuild.StartFailed && mBuild.Config == config && ProjectIndex.SamePath(mBuild.Workspace, ws);
				LoadCompileRecord(ws);
				bool cleanRecord = mCompRec != null && mCompRec.Ok && mCompRec.Errors == 0 && mCompRec.Warnings == 0 && mCompRec.Config == config;
				if (sameRun || (mBuild == null && cleanRecord))
				{
					skipIf = CompileInputs.Decode(Settings.ProjectValue(ws, "compileInputs"));
					if (sameRun)
						carried = mBuild.Messages;
				}
			}
			let build = new BuildRunner();
			build.LowerPriority = lowerPriority;
			for (let d in mDocs)
				d.BuildVersion = d.Version;
			if (build.Start(mBeefBuildPath, ws, config, skipIf, carried) case .Err)
			{
				SetStatus(scope $"Could not run BeefBuild at '{mBeefBuildPath}' (set it in Edit > Editor Preferences)");
				delete build;
				return;
			}
			delete mBuild;
			mBuild = build;
			mSelectResultsTab = true;
			mBuildLogged = 0;
			CompileMaxFrameMs = 0;
			CompileFrames = 0;
			mCompileTailFrames = 6;
			mBuildCommandLogged = false;
			Notify.Log(.Info, "Build", scope $"Compiling {ws} ({config}: {reason})");
			SetStatus(scope $"Compiling {ws} ({config})...");
		}

		void JumpToLine(StringView path, int32 line)
		{
			if (OpenFile(path, false) == null)
				return;
			// The innermost function that holds the line, or the unreadable member (its read-only
			// error graph: the red node with the parser's message).
			let mg = DiagnosticMap.MethodAt(Doc, line);
			if (mg != null)
			{
				OpenTab(mg);
				Node best = null;
				for (let n in mg.Graph.Nodes)
				{
					if (mg.IsBroken)
					{
						if (n.Kind == .Code)
							best = n;
						continue;
					}
					if (n.Line <= 0 || line < n.Line || line > n.LineEnd)
						continue;
					if (best == null || (n.LineEnd - n.Line) < (best.LineEnd - best.Line))
						best = n;
				}
				if (best != null)
				{
					let tab = CurrentTab;
					// Select the node and scroll it into the middle of the canvas.
					tab.SelectOnly(best.Id);
					tab.CenterOn(best.X + 100, best.Y + 40);
				}
				return;
			}
			// No graph holds the line (a field, a declaration, a member kept as text): show the
			// file as text at that line, so every message can be looked at.
			ShowSourceLine(line);
			SetStatus(scope $"Line {line} is not inside a function graph: shown in Beef Source > File");
		}

		/// Selects Beef Source > File for the current document and scrolls it to `line` (1-based).
		public void ShowSourceLine(int32 line)
		{
			mSelectSourceFileTab = true;
			mSourceScrollLine = line;
			Panels.Focus(Panels.BeefSourceId);
		}

		// ------------------------------------------------------------------ frame

		public void Frame()
		{
			mFrame++;
			TrackFrameTime();
			ShellBeginFrame();
			if (mMono == null)
				mMono = Host.vbh_get_mono_font();
			// Polling is time-based: the frame loop sleeps while idle (see Desktop.PaceFrame).
			let now = Desktop.Now;
			if (now - mExternalCheckTime > 1.0)
			{
				mExternalCheckTime = now;
				CheckExternalChange();
			}
			// Node positions live in a side file (<file>.bf.vblayout); save it quietly when only
			// the layout changed, so moving nodes never marks the Beef file as modified.
			if (mLayoutDirty && now - mLayoutSaveTime > 2.0 && !Gui.igIsMouseDown_Nil(0))
			{
				for (let d in mDocs)
					if (!d.FilePath.IsEmpty && !d.Modified)
					{
						d.SaveLayout();
						ReportLayoutError(d);
					}
				mLayoutDirty = false;
				mLayoutSaveTime = now;
			}
			if (!mLayoutDirty)
				mLayoutSaveTime = now;
			Autosave(now);
			Recovery.Tick(mDocs, now);
			PollIndexing();
			RetypeOpenDocuments();
#if !BF_PLATFORM_WINDOWS
			CrashHandler.SetProject(mProjectRoot);
#endif
			Desktop.MaybeRaiseForTest();
			CrashHandler.MaybeCrashForTest(mFrame, scope () =>
			{
				if (Doc.Unit != null && !Doc.FilePath.IsEmpty)
				{
					String text = scope .(Doc.Unit.Text);
					text.Append("// VB_DEBUG_CRASH_TEST: unsaved edit\r\n");
					Doc.ApplyText(text);
				}
			});
			SelfTestTick();
			UpdateTick();
			DebugTick();
			// Keep the project index in step with edits.
			for (let d in mDocs)
			{
				if (d.IndexedVersion != d.Version && d.Unit != null)
				{
					Index.Update(d.FilePath, d.Unit);
					d.IndexedVersion = d.Version;
				}
			}

			MapPendingDiagnostics();
			if (mBuild != null && mBuild.Update() && !OnBuildStartFailed())
			{
				let finishWatch = scope System.Diagnostics.Stopwatch(true);
				defer { CompileFinishMs = finishWatch.Elapsed.TotalMilliseconds; }
				int errors = 0;
				int warnings = 0;
				for (let m in mBuild.Messages)
				{
					if (m.IsError)
						errors++;
					else
						warnings++;
				}
				mStatus.Set(mBuild.Succeeded ? "Compile succeeded" : "Compile failed");
				mStatusTime = Gui.igGetTime();
				MapDiagnostics();
				StoreCompileRecord(mBuild.Workspace, mBuild.Succeeded, mBuild.Config, errors, warnings);
				InvalidateCompileHash();
				OnBuildFinished(errors, warnings);
				OnBuildFinishedForDebug();
			}
			UpdateProjectBrowser();
			HandleShortcuts();
			DrawMainMenu();
			DrawToolbar();
			DrawUpdateBar();
			DrawStatusBar();
			SetupDockspace();
			DrawProjectBrowserWindows();
			if (mFocusCBFrames > 0 && --mFocusCBFrames == 0)
				Panels.Focus(Panels.ProjectBrowserId);
			DrawOutlinePanel();
			DrawGraphArea();
			DrawPropertiesPanel();
			DrawSourcePanel();
			DrawOutputLog();
			DrawCompilerResultsPanel();
			DrawFindResults();
			DrawDebugPanels();
			DrawPopups();
			DrawStartPageAndDocs();
			DrawPreferences();
			if (mShowDemo)
				Gui.igShowDemoWindow(&mShowDemo);
			DebugShortcuts();
			DrawDragGhost();
			ShellEndFrame();
			if (mCommitPending)
				DoCommit();
			if (mReloadSheetPending)
				ReloadSheet();
		}

		/// Safety valves for a node or Sheet that shows something the function no longer says
		/// (the real cure is that kept graphs follow every edit; see SourceDocument.ReloadNode).
		bool mReloadSheetPending;

		public void ReloadNode(MethodGraph mg, Node node)
		{
			if (mg.Doc.ReloadNode(mg, node))
			{
				String title = scope .();
				node.GetTitle(title);
				SetStatus(scope $"Reloaded {title}");
				// An enum Switch follows its enum: new members get a case, removed ones lose theirs.
				if (node.Kind == .Switch && NodeFactory.SwitchMembersStale(node, VisualBeef.Catalog.TypeService.Current))
				{
					BeginEdit();
					String why = scope .();
					if (NodeFactory.SetSwitchType(mg.Graph, node, NodeFactory.SwitchType(node), VisualBeef.Catalog.TypeService.Current, why))
					{
						CommitCurrent();
						SetStatus(scope $"Reloaded {title}: its cases follow the enum's members now");
					}
				}
			}
			else
				SetStatus("This node has changes not written yet or is not connected: use Graph > Reload Sheet", .Warning);
		}

		public void ReloadSheet()
		{
			mReloadSheetPending = false;
			let tab = CurrentTab;
			let mg = CurrentMethod;
			if (tab == null || mg == null)
				return;
			tab.SelectedNodes.Clear();
			mg.Doc.ReloadGraph(mg);
			UpdateTitle();
			SetStatus(scope $"Reloaded the Sheet of {mg.Method.Name}");
		}

		double mExternalCheckTime;
		double mLayoutSaveTime;

		void HandleShortcuts()
		{
			bool ctrl = Gui.IsCtrlDown;
			if (ctrl && Gui.IsKeyPressed(Key.S, false))
			{
				if (Gui.IsShiftDown)
					SaveAll();
				else
					Save();
			}
			if (ctrl && Gui.IsKeyPressed(Key.O, false))
				OpenFileBrowser();
			if (Gui.IsKeyPressed(578 /* F7 */, false))
				Compile(default, ctrl);
			if (Gui.IsKeyPressed(572 /* F1 */, false))
				OpenDocumentation();
			// UE: Ctrl+B browses to the asset, Ctrl+Shift+F finds in all Blueprints.
			if (ctrl && !Gui.IsShiftDown && Gui.IsKeyPressed(Key.B, false) && !Gui.igIsAnyItemActive())
				BrowseToCurrent();
			if (ctrl && Gui.IsShiftDown && Gui.IsKeyPressed(Key.F, false))
				OpenFindResults();
			if (!ctrl && Gui.IsShiftDown && Gui.IsKeyPressed(Key.F12, false) && !Gui.igIsAnyItemActive())
				FindReferencesOfSelection();
			// UE's Project Drawer
			if (ctrl && Gui.IsKeyPressed(Key.Space, false))
				ToggleProjectDrawer();
			if (!Gui.igIsAnyItemActive())
			{
				if (ctrl && Gui.IsKeyPressed(Key.Z, true))
				{
					if (Gui.IsShiftDown)
					{
						if (!GroupUndo(EditDoc, true))
							EditDoc.Redo();
					}
					else if (!GroupUndo(EditDoc, false))
						EditDoc.Undo();
					UpdateTitle();
				}
				if (ctrl && Gui.IsKeyPressed(Key.Y, true))
				{
					if (!GroupUndo(EditDoc, true))
						EditDoc.Redo();
					UpdateTitle();
				}
			}
		}

		void OpenFolderPicker()
		{
			char8[4096] buf = default;
			let start = mProjectRoot.IsEmpty ? "" : mProjectRoot;
			int32 r = Host.vbh_native_dialog(1, scope String(start), &buf, 4096);
			if (r == 1)
			{
				RequestOpenProject(StringView(&buf));
				return;
			}
			if (r == 0)
				return;
			// No native dialog: fall back to the built-in one.
			mPathBuf.Set(mProjectRoot);
			mOpenFolderPopup = true;
		}

		void OpenFileBrowser()
		{
			{
				String start = scope .();
				if (!Doc.FilePath.IsEmpty)
					Path.GetDirectoryPath(Doc.FilePath, start).IgnoreError(); // a root has no parent: dir stays empty
				else
					start.Set(mProjectRoot);
				char8[4096] buf = default;
				int32 r = Host.vbh_native_dialog(0, start, &buf, 4096);
				if (r == 1)
				{
					OpenFile(StringView(&buf));
					return;
				}
				if (r == 0)
					return;
			}
			if (mBrowseDir.IsEmpty)
			{
				if (!Doc.FilePath.IsEmpty)
					Path.GetDirectoryPath(Doc.FilePath, mBrowseDir).IgnoreError(); // a root has no parent: browse dir stays empty and falls through
				else if (!mProjectRoot.IsEmpty)
					mBrowseDir.Set(mProjectRoot);
				else
					Directory.GetCurrentDirectory(mBrowseDir);
			}
			mPathBuf.Set(mBrowseDir);
			mOpenFilePopup = true;
		}

		/// Menu item with an icon in front (UE menus carry an icon on most entries).
		static bool IconItem(StringView icon, StringView label, StringView shortcut = "", bool selected = false, bool enabled = true)
		{
			String text = scope .();
			Icon.Label(text, icon, label);
			return Gui.MenuItem(text, shortcut, selected, enabled);
		}

		void DrawMainMenu()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(8 * Look.Scale, 6 * Look.Scale));
			bool open = Gui.igBeginMainMenuBar();
			Gui.igPopStyleVar(1);
			if (!open)
				return;
			// App mark, like UE's logo at the start of the menu row.
			{
				let pos = Gui.igGetCursorScreenPos();
				float fs = Gui.igGetFontSize();
				Gui.DrawText(Gui.igGetWindowDrawList(), .(pos.x + 2, pos.y + (Gui.igGetFrameHeight() - fs * 1.2f) * 0.5f), Look.AccentBlue, Icon.Workflow, fs * 1.2f);
				Gui.igDummy(.(fs * 1.5f, 1));
				Gui.SameLine();
			}
			if (mSpFileMenu) // captures: the File menu open
			{
				mSpFileMenu = false;
				Gui.OpenPopup("File");
			}
			if (Gui.BeginMenu("File"))
			{
				if (IconItem(Icon.Package, "New Project..."))
					StartNewProject();
				bool haveFolder = !mProjectRoot.IsEmpty && mCBTree != null;
				if (IconItem(Icon.Class, "New Class...", "", false, haveFolder))
					StartNewAsset(.Class, mCBFolder);
				if (IconItem(Icon.FilePlus, "New File...", "", false, haveFolder))
					StartNewAsset(.File, mCBFolder);
				if (IconItem(Icon.FolderPlus, "New Folder...", "", false, haveFolder))
					StartNewAsset(.Folder, mCBFolder);
				Gui.Separator();
				if (IconItem(Icon.File, "Open File...", "Ctrl+O"))
					OpenFileBrowser();
				if (IconItem(Icon.FolderOpen, "Open Project Folder..."))
				{
					FileSafety.ReadOnlyProject = false;
					OpenFolderPicker();
				}
				if (IconItem(Icon.FolderLock, "Open Project (Read-only)..."))
				{
					FileSafety.ReadOnlyProject = true;
					OpenFolderPicker();
				}
				DrawOpenRecentMenu();
				if (IconItem(Icon.X, "Close Project", "", false, !mProjectRoot.IsEmpty))
					RequestCloseProject();
				Gui.Separator();
				if (IconItem(Icon.Lock, "Read-only (viewer) mode", "", FileSafety.ReadOnlyProject))
					FileSafety.ReadOnlyProject = !FileSafety.ReadOnlyProject;
				if (IconItem(Icon.History, "Keep .bak backup when saving", "", FileSafety.KeepBackup))
					FileSafety.KeepBackup = !FileSafety.KeepBackup;
				Gui.Separator();
				if (IconItem(Icon.Save, "Save", "Ctrl+S", false, !Doc.FilePath.IsEmpty))
					Save();
				if (IconItem(Icon.SaveAll, "Save All", "Ctrl+Shift+S", false, ModifiedCount > 0))
					SaveAll();
				if (IconItem(Icon.RotateCcw, "Reload From Disk", "", false, !Doc.FilePath.IsEmpty))
					ReloadFromDisk();
				Gui.Separator();
				if (IconItem(Icon.LogOut, "Exit"))
					RequestQuit();
				Gui.EndMenu();
			}
			if (Gui.BeginMenu("Edit"))
			{
				if (IconItem(Icon.Undo2, "Undo", "Ctrl+Z", false, EditDoc.CanUndo) && !GroupUndo(EditDoc, false))
					EditDoc.Undo();
				if (IconItem(Icon.Redo2, "Redo", "Ctrl+Y", false, EditDoc.CanRedo) && !GroupUndo(EditDoc, true))
					EditDoc.Redo();
				Gui.Separator();
				if (IconItem(Icon.Find, "Find References", "Shift+F12", false, !mProjectRoot.IsEmpty))
					FindReferencesOfSelection();
				Gui.Separator();
				let tab = CurrentTab;
				if (IconItem(Icon.Copy, "Copy", "Ctrl+C", false, tab != null))
					CopySelection(tab);
				if (IconItem(Icon.Clipboard, "Paste", "Ctrl+V", false, tab != null && mClipboard != null))
					Paste(tab, ViewCentre(tab));
				if (IconItem(Icon.CopyPlus, "Duplicate", "Ctrl+D", false, tab != null))
					DuplicateSelection(tab);
				if (IconItem(Icon.Trash2, "Delete", "Del", false, tab != null))
					DeleteSelection(tab);
				Gui.Separator();
				if (IconItem(Icon.Find, "Find in Sheets", "Ctrl+Shift+F", false, !mProjectRoot.IsEmpty))
					OpenFindResults();
				Gui.Separator();
				if (IconItem(Icon.Settings, "Editor Preferences..."))
					OpenPreferences();
				Gui.EndMenu();
			}
			if (Gui.BeginMenu("Graph"))
			{
				let tab = CurrentTab;
				bool haveGraph = tab != null && CurrentMethod != null;
				if (IconItem(Icon.Arrange, "Auto-Arrange (layered)", "", false, haveGraph))
					ArrangeCurrentGraph();
				if (IconItem(Icon.RefreshCw, "Reload Sheet", "", false, haveGraph && CurrentMethod.Graphable && !CurrentMethod.Graph.ReadOnly))
					mReloadSheetPending = true;
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Builds this Sheet again from the function as it is now (positions and unconnected nodes are kept; Ctrl+Z undoes it)");
				if (Gui.BeginMenu(scope $"{Icon.AlignStartVertical}  Alignment", haveGraph))
				{
					DrawAlignItems(tab);
					Gui.EndMenu();
				}
				Gui.Separator();
				if (IconItem(Icon.Minimap, "Minimap", "M", Prefs.ShowMinimap, haveGraph))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				if (IconItem(Icon.Magnet, "Snap to Grid", "", Prefs.GridSnap))
				{
					Prefs.GridSnap = !Prefs.GridSnap;
					Prefs.Save();
				}
				Gui.EndMenu();
			}
			DrawBuildMenu();
			DrawDebugMenu();
			if (Gui.BeginMenu("Window"))
			{
				if (IconItem(Icon.FolderOpen, "Project Drawer", "Ctrl+Space", mCBDrawerOpen))
					ToggleProjectDrawer();
				if (IconItem(Icon.Log, "Output Log", "", ShowOutputLog))
				{
					ShowOutputLog = !ShowOutputLog;
					mFocusOutputLog = ShowOutputLog;
				}
				if (IconItem(Icon.CircleX, "Problems", "", ShowCompilerResults))
					ShowCompilerResults = !ShowCompilerResults;
				if (IconItem(Icon.Find, "Find Results", "", ShowFindResults))
					ShowFindResults = !ShowFindResults;
				if (IconItem(Icon.Minimap, "Graph Minimap", "M", Prefs.ShowMinimap, CurrentTab != null))
				{
					Prefs.ShowMinimap = !Prefs.ShowMinimap;
					Prefs.Save();
				}
				mGraphPanel.DrawViewsMenu(CurrentTab);
				Gui.Separator();
				if (IconItem(Icon.Variable, "Locals", "", ShowLocals))
					ShowLocals = !ShowLocals;
				if (IconItem(Icon.Layers, "Call Stack", "", ShowCallStack))
					ShowCallStack = !ShowCallStack;
				if (IconItem(Icon.Terminal, "Debug Output", "", ShowDebugOutput))
					ShowDebugOutput = !ShowDebugOutput;
				Gui.Separator();
				if (IconItem(Icon.LayoutGrid, "Reset Layout"))
				{
					mLayoutVersion = 0;
					mDockBuilt = false;
				}
				Gui.EndMenu();
			}
			if (mSelfTestHelpMenu) // captures: the Help menu open
			{
				mSelfTestHelpMenu = false;
				Gui.OpenPopup("Help");
			}
			if (Gui.BeginMenu("Help"))
			{
				if (IconItem(Icon.BookOpen, "Documentation", "F1"))
					OpenDocumentation();
				Gui.Separator();
				Gui.TextDisabled("Graph");
				Gui.Text("Right-click the graph: add nodes (type to search).");
				Gui.Text("Drag from a pin into empty space: add a connected node.");
				Gui.Text("Drag variables/functions from the Outline into the graph.");
				Gui.Text("  (Ctrl = Get, Alt = Set when dropping a variable)");
				Gui.Text("Alt+click a pin or wire to break it.  Double-click a call to open it.");
				Gui.Text("Shift+W/S/A/D: align top/bottom/left/right.  Q: straighten.  M: minimap.");
				Gui.Text("Del: delete   Ctrl+C/V/D: copy/paste/duplicate   F: frame   Home: entry   Ctrl+1..9 / 1..9: save / go to view");
				Gui.TextDisabled("Editor");
				Gui.Text("F7: compile   Ctrl+S: save   Ctrl+B: browse   Ctrl+Shift+F: find in Sheets");
				Gui.Text("F5: debug / continue   Shift+F5: stop   F9: breakpoint   F10 / F11 / Shift+F11: step over / into / out");
				Gui.Text("Project Browser: double-click to open, F2 rename, Del delete, drag onto a folder to move.");
				Gui.Text("Ctrl+Space: Project Drawer.   docs/Editor-UI.md lists every shortcut.");
				Gui.Separator();
				bool updatesBusy = mUpdates == null || mUpdates.Busy;
				// A known new version reads "Update to X..." and runs the update flow; otherwise a check.
				bool offered = UpdateIsOffered;
				String updateLabel = scope .();
				if (offered)
					updateLabel.AppendF("Update to {}...", mUpdateView.LatestVersion);
				else
					updateLabel.Set("Check for Updates...");
				if (IconItem(Icon.ArrowDownToLine, updateLabel, "", false, offered || !updatesBusy))
				{
					if (offered)
						UpdateFromMenu();
					else
						CheckForUpdatesNow();
				}
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip(offered ? "Download and install the new VisualBeef release (Editor Preferences > Updates shows the progress)" : "Look for a new VisualBeef release now (Editor Preferences > Updates has the settings)");
				Gui.Separator();
				Gui.MenuItem("Show ImGui Demo", "", mShowDemo);
				if (Gui.igIsItemClicked(0))
					mShowDemo = !mShowDemo;
				Gui.EndMenu();
			}
			// Project name and window controls share the title row (see TitleBar.bf).
			DrawTitleBarExtras();
			Gui.igEndMainMenuBar();
		}

		bool mDockBuilt;
		void SetupDockspace()
		{
			let viewport = Gui.igGetMainViewport();
			uint32 dockId = Gui.igGetID_Str("VBDock");
			if (!mDockBuilt)
			{
				mDockBuilt = true;
				if (Gui.igDockBuilderGetNode(dockId) == null || mLayoutVersion < cLayoutVersion)
				{
					// Default layout (UE's Blueprint editor): Outline left, Details right, the
					// graph in the middle, Project Browser / Output Log / Compiler Results / Beef
					// Source tabbed along the bottom.
					mLayoutVersion = cLayoutVersion;
					mFocusCBFrames = 12;
					SaveSettings();
					Gui.igDockBuilderRemoveNode(dockId);
					Gui.igDockBuilderAddNode(dockId, 1 << 10);
					Gui.igDockBuilderSetNodeSize(dockId, viewport.WorkSize);
					uint32 left = 0;
					uint32 rest = 0;
					Gui.igDockBuilderSplitNode(dockId, Dir.Left, 0.18f, &left, &rest);
					uint32 right = 0;
					uint32 center = 0;
					Gui.igDockBuilderSplitNode(rest, Dir.Right, 0.24f, &right, &center);
					uint32 bottom = 0;
					uint32 graph = 0;
					Gui.igDockBuilderSplitNode(center, Dir.Down, 0.34f, &bottom, &graph);
					Gui.igDockBuilderDockWindow(Panels.OutlineId, left);
					Gui.igDockBuilderDockWindow(Panels.PropertiesId, right);
					Gui.igDockBuilderDockWindow(Panels.ProjectBrowserId, bottom);
					Gui.igDockBuilderDockWindow(Panels.OutputLogId, bottom);
					Gui.igDockBuilderDockWindow(Panels.CompilerResultsId, bottom);
					Gui.igDockBuilderDockWindow(Panels.FindResultsId, bottom);
					Gui.igDockBuilderDockWindow(Panels.BeefSourceId, bottom);
					Gui.igDockBuilderDockWindow(Panels.DebugOutputId, bottom);
					Gui.igDockBuilderDockWindow(Panels.LocalsId, right);
					Gui.igDockBuilderDockWindow(Panels.CallStackId, right);
					Gui.igDockBuilderDockWindow(Panels.GraphId, graph);
					Gui.igDockBuilderFinish(dockId);
				}
			}
			// UE look: no ImGui dock-node menu triangle or node close button on any panel.
			Gui.igDockSpaceOverViewport(dockId, viewport, DockNodeFlagsX.NoWindowMenuButton | DockNodeFlagsX.NoCloseButton, null);
		}

		// ------------------------------------------------------------------ panels

		// Outline panel: see Outline.bf.

		void AddMemberRef(MemberRef.Kind kind, StringView name, StringView type, StringView paramsText, StringView owner, bool isStatic)
		{
			MemberRef r = new .();
			r.MemberKind = kind;
			r.Name.Set(name);
			r.Type.Set(type);
			r.Params.Set(paramsText);
			r.Owner.Set(owner);
			r.IsStatic = isStatic;
			mMembers.Add(r);
		}

		MethodGraph FindMethodGraph(Member m)
		{
			for (let mg in Doc.Methods)
				if (mg.Method == m)
					return mg;
			return null;
		}

		void DrawGraphArea()
		{
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(0, 0));
			// UE: the graph tabs are the document tabs; the dock node's own "Graph" tab only shows
			// when another panel is docked with it.
			ImGuiWindowClass graphClass = .();
			graphClass.DockNodeFlagsOverrideSet = DockNodeFlagsX.AutoHideTabBar;
			Gui.igSetNextWindowClass(&graphClass);
			if (Gui.Begin(Panels.Graph, null, WindowFlags.NoScrollbar | WindowFlags.NoScrollWithMouse))
			{
				Gui.igPopStyleVar(1);
				bool graphSelected = false;
				AssetTab assetSelected = null;
				if (Tabs.IsEmpty && mAssetTabs.IsEmpty)
				{
					mActiveAssetTab = null;
					Gui.igSetCursorPos(.(20, Gui.igGetCursorPos().y + 20));
					Gui.igPushTextWrapPos(Gui.igGetWindowWidth() - 20);
					if (Doc.FilePath.IsEmpty && mProjectRoot.IsEmpty)
						Gui.TextDisabled("Open a project folder or a Beef file (File menu, the Project Browser, or drop it on the window).");
					else if (Doc.FilePath.IsEmpty)
						Gui.TextDisabled("Double-click a class in the Project Browser to open it, or add one with + Add > New Class.");
					else
						Gui.TextDisabled("Pick a function in the Outline, or double-click an asset in the Project Browser.");
					Gui.igPopTextWrapPos();
				}
				else if (Gui.igBeginTabBar("##graphs", 1 << 0 /* Reorderable */))
				{
					for (int i = 0; i < Tabs.Count; i++)
					{
						let tab = Tabs[i];
						let mg = tab.Doc.FindMethod(tab.MethodKey);
						// Broken members have no body but open as a read-only error graph.
						if (mg == null || (!mg.Graphable && !mg.IsBroken))
						{
							// The function was removed or renamed in the source.
							Tabs.RemoveAt(i);
							delete tab;
							if (ActiveTab >= Tabs.Count)
								ActiveTab = Tabs.Count - 1;
							i--;
							continue;
						}
						int32 flags = 0;
						if (mSelectTab == tab)
						{
							flags |= TabItemFlags.SetSelected;
							mSelectTab = null;
						}
						String label = scope .();
						label.AppendF("{}  {}{}###graphtab{}", Icon.Function, tab.Title, tab.Doc.Modified ? " *" : "", tab.Uid);
						bool open = true;
						if (Gui.igBeginTabItem(label, &open, flags))
						{
							graphSelected = true;
							ActiveTab = i;
							if (tab != mLastActiveTab)
							{
								// Switching tabs switches the side panels to that tab's file.
								mLastActiveTab = tab;
								Doc = tab.Doc;
							}
							mGraphPanel.Draw(tab, mg);
							Gui.igEndTabItem();
						}
						if (!open)
						{
							if (mLastActiveTab == tab)
								mLastActiveTab = null;
							Tabs.RemoveAt(i);
							delete tab;
							if (ActiveTab >= Tabs.Count)
								ActiveTab = Tabs.Count - 1;
							i--;
						}
					}
					// Asset editors (Enum editor, type overview) share the tab bar with the graphs.
					for (int i = 0; i < mAssetTabs.Count; i++)
					{
						let tab = mAssetTabs[i];
						int32 flags = 0;
						if (mSelectAssetTab == tab)
						{
							flags |= TabItemFlags.SetSelected;
							mSelectAssetTab = null;
						}
						let tabDoc = FindDoc(tab.FilePath);
						String label = scope .();
						label.AppendF("{}  {}{}###asset|{}|{}|{}", (tab.Asset == .Enum) ? Icon.Enum : ((tab.Asset == .Struct) ? Icon.Struct : Icon.Class), tab.TypeName, (tabDoc != null && tabDoc.Modified) ? " *" : "", (int)tab.Kind, tab.FilePath, tab.TypeName);
						bool open = true;
						Gui.igPushStyleColor_U32(Col.Text, Theme.Mix(AssetStyle.KindColor(tab.Asset), Gui.Color(255, 255, 255), 0.55f));
						bool visible = Gui.igBeginTabItem(label, &open, flags);
						Gui.igPopStyleColor(1);
						if (visible)
						{
							assetSelected = tab;
							if (!graphSelected)
							{
								if (mLastActiveAsset != tab && tabDoc != null)
								{
									Doc = tabDoc;
									mSourceVersion = -1;
								}
								mLastActiveAsset = tab;
								mActiveAssetTab = tab;
								ActiveTab = -1;
								mLastActiveTab = null;
							}
							DrawAssetTab(tab);
							Gui.igEndTabItem();
						}
						if (!open)
						{
							RemoveAssetTab(i);
							i--;
						}
					}
					Gui.igEndTabBar();
				}
				if (graphSelected || assetSelected == null)
				{
					mActiveAssetTab = null;
					mLastActiveAsset = null;
				}
			}
			else
				Gui.igPopStyleVar(1);
			Gui.End();
		}

		// ------------------------------------------------------------------ details

		// The Properties panel (node / function / variable property grids) is in PropertiesPanel.bf.

		/// A Sheet's name: the function name; a constructor also gets its parameter types (Greeter.this(float)).
		static void AppendSheetName(String into, MethodGraph mg)
		{
			into.Append(mg.Method.Name);
			if (mg.Method.IsCtor && mg.Method.Name == "this")
			{
				into.Append("(");
				for (let p in mg.Method.Params)
				{
					if (@p.Index > 0)
						into.Append(", ");
					into.Append(p.Type);
				}
				into.Append(")");
			}
		}

		/// After a signature change: the tabs on the old key follow the same function (its new key,
		/// from SourceDocument.LastSignatureKey), never another overload of the same name.
		void RetargetTabToKey(SourceDocument doc, StringView oldKey, StringView newKey)
		{
			let mg = doc.FindMethod(newKey);
			if (mg == null)
				return;
			for (let tab in Tabs)
			{
				if (tab.Doc != doc || tab.MethodKey != oldKey)
					continue;
				tab.MethodKey.Set(mg.Key);
				tab.Title.Clear();
				if (mg.Owner != null)
					tab.Title.AppendF("{}.", mg.Owner.Name);
				AppendSheetName(tab.Title, mg);
			}
		}

		/// After a rename/signature change, points the active tab at the method's new key.
		void RetargetTab(StringView oldKey, StringView methodName)
		{
			for (let tab in Tabs)
			{
				if (tab.MethodKey != oldKey)
					continue;
				for (let mg in tab.Doc.Methods)
				{
					if (mg.Method.Name == methodName && (mg.Owner == null || tab.Title.StartsWith(mg.Owner.Name)))
					{
						tab.MethodKey.Set(mg.Key);
						tab.Title.Clear();
						if (mg.Owner != null)
							tab.Title.AppendF("{}.", mg.Owner.Name);
						AppendSheetName(tab.Title, mg);
						break;
					}
				}
			}
		}

		// ------------------------------------------------------------------ source

		void DrawSourcePanel()
		{
			if (Gui.Begin(Panels.BeefSource))
			{
				if (Gui.igBeginTabBar("##src", 0))
				{
					if (Gui.igBeginTabItem("Function", null, 0))
					{
						let mg = CurrentMethod;
						if (mg != null)
						{
							Gui.TextColored(Theme.TextDim, "Live Beef for this graph (edit it in the File tab or in the graph):");
							let unit = mg.Doc.Unit;
							String text = scope .();
							let first = unit.Tokens[mg.Method.FirstTok];
							let last = unit.Tokens[mg.Method.LastTok];
							// Include the indentation of the first line so the block lines up.
							int lineStart = first.Start;
							while (lineStart > 0 && unit.Text[lineStart - 1] != '\n')
								lineStart--;
							text.Append(StringView(unit.Text, lineStart, last.End - lineStart));
							text.Replace("\t", "    ");
							mFieldBuf.Set(text);
							if (mMono != null)
								Gui.igPushFont(mMono, 0);
							Gui.igInputTextMultiline("##fn", mFieldBuf.Ptr, (.)mFieldBuf.Capacity, .(-1, -1), InputTextFlags.ReadOnly, null, null);
							if (mMono != null)
								Gui.igPopFont();
						}
						else
							Gui.TextDisabled("No function open.");
						Gui.igEndTabItem();
					}
					int32 fileTabFlags = 0;
					if (mSelectSourceFileTab)
					{
						fileTabFlags = TabItemFlags.SetSelected;
						mSelectSourceFileTab = false;
					}
					if (Gui.igBeginTabItem("File", null, fileTabFlags))
					{
						if (mSourceDoc != Doc)
						{
							if (mSourceDirty)
								SetStatus("Discarded unapplied text edits (switched files)");
							mSourceDoc = Doc;
							mSourceDirty = false;
							mSourceVersion = -1;
						}
						if (mSourceVersion != Doc.Version && !mSourceDirty)
						{
							mSourceBuf.Set(Doc.Text);
							mSourceVersion = Doc.Version;
						}
						if (Gui.Button("Apply Text To Graph") || (mSourceDirty && Gui.IsCtrlDown && Gui.IsKeyPressed(Key.Enter, false)))
						{
							String text = scope .(mSourceBuf.View);
							Doc.ApplyText(text);
							mSourceDirty = false;
							mSourceVersion = -1;
							UpdateTitle();
							SetStatus("Source applied; graphs rebuilt");
						}
						Gui.SameLine();
						Gui.igBeginDisabled(!mSourceDirty);
						if (Gui.Button("Revert"))
						{
							mSourceDirty = false;
							mSourceVersion = -1;
						}
						Gui.igEndDisabled();
						Gui.SameLine();
						if (mSourceDirty)
							Gui.TextColored(Theme.Warning, "Edited - click Apply (Ctrl+Enter) to update the graphs");
						else
							Gui.TextColored(Theme.TextDim, "In sync with the graphs");
						if (mMono != null)
							Gui.igPushFont(mMono, 0);
						if (mSourceScrollLine > 0)
						{
							// A message outside every graph (ShowSourceLine): bring its line into view,
							// a few lines below the top. The multiline box is a child window.
							float lineH = Gui.igGetTextLineHeight();
							Gui.igSetNextWindowScroll(.(-1, Math.Max(0, (mSourceScrollLine - 4) * lineH)));
							mSourceScrollLine = 0;
						}
						if (Gui.igInputTextMultiline("##file",mSourceBuf.Ptr, (.)mSourceBuf.Capacity, .(-1, -1), InputTextFlags.AllowTabInput, null, null))
							mSourceDirty = true;
						if (mMono != null)
							Gui.igPopFont();
						Gui.igEndTabItem();
					}
					if (!Doc.Messages.IsEmpty && Gui.igBeginTabItem("Messages", null, 0))
					{
						for (let msg in Doc.Messages)
							Gui.TextColored(Theme.Warning, msg);
						Gui.igEndTabItem();
					}
					Gui.igEndTabBar();
				}
			}
			Gui.End();
		}

		SourceDocument mSourceDoc;


		// ------------------------------------------------------------------ popups

		public void RequestQuit()
		{
			if (ModifiedCount > 0)
				mShowQuitModal = true;
			else
				QuitNow = true;
		}

		void DrawPopups()
		{
			// Action menu
			let chosen = mNodeMenu.Draw();
			if (chosen != null)
			{
				ExecuteAction(chosen);
				delete chosen;
			}

			// Node context menu
			if (mOpenNodeContext)
			{
				Gui.OpenPopup("##nodectx");
				mOpenNodeContext = false;
			}
			if (Gui.BeginPopup("##nodectx"))
			{
				let mg = CurrentMethod;
				let node = (mg != null) ? mg.Graph.FindNode(mContextNode) : null;
				if (node == null)
					Gui.igCloseCurrentPopup();
				else
				{
					String title = scope .();
					node.GetTitle(title);
					Gui.TextDisabled(title);
					Gui.Separator();
					if (node != mg.Graph.Entry && Gui.MenuItem("Delete", "Del"))
						DeleteSelection(CurrentTab);
					if (Gui.MenuItem("Break All Links"))
					{
						BeginEdit();
						for (let p in node.Inputs)
							mg.Graph.DisconnectPin(p);
						for (let p in node.Outputs)
							mg.Graph.DisconnectPin(p);
						CommitCurrent();
					}
					if (node != mg.Graph.Entry && Gui.MenuItem("Copy", "Ctrl+C")) // UX: Copy in node menu
						CopySelection(CurrentTab);
					if (node != mg.Graph.Entry && Gui.MenuItem("Duplicate", "Ctrl+D"))
						DuplicateSelection(CurrentTab);
					if (Gui.MenuItem("Create Comment from Selection", "C")) // UX: UE comment box
						mGraphPanel.CreateComment(CurrentTab, mg.Graph);
					if (node.IsExecNode && node != mg.Graph.Entry && Gui.MenuItem((node.LeadingComments != null && !node.LeadingComments.IsEmpty) ? "Edit Comment" : "Add Comment"))
						mGraphPanel.BeginBubbleEdit(node.Id);
					if (node.Kind == .Call && Gui.MenuItem("Go To Function"))
						NodeDoubleClicked(node);
					if (node.Kind == .Call && Gui.MenuItem("Add Argument Pin"))
						AddArgument(node);
					Gui.Separator();
					if (Gui.MenuItem("Reload Node"))
						ReloadNode(mg, node);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Rebuilds this node's pins, types and messages from the function as it is now");
				}
				Gui.EndPopup();
			}

			DrawFileBrowser();
			DrawFolderPopup();
			DrawAddFunctionPopup();
			DrawAddVariablePopup();
			DrawRenamePopup();
			DrawClassPopups();
			DrawProjectBrowserPopups();
			DrawModals();
		}

		void DrawFileBrowser()
		{
			if (mOpenFilePopup)
			{
				Gui.OpenPopup("Open Beef File");
				mOpenFilePopup = false;
			}
			Gui.igSetNextWindowSize(.(640, 480), Cond.Appearing);
			if (Gui.igBeginPopupModal("Open Beef File", null, 0))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("Path (a .bf file or a folder):");
				Gui.igSetNextItemWidth(-90);
				bool enter = Gui.igInputText("##path", mPathBuf.Ptr, (.)mPathBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				Gui.SameLine();
				bool openClicked = Gui.Button("Open", .(80 * Look.Scale, 0));
				String typed = scope .(mPathBuf.View);
				if (enter || openClicked)
				{
					if (File.Exists(typed) && typed.EndsWith(".bf", .OrdinalIgnoreCase))
					{
						Gui.igCloseCurrentPopup();
						RequestOpen(typed);
					}
					else if (Directory.Exists(typed))
						mBrowseDir.Set(typed);
				}
				if (Directory.Exists(typed) && typed != mBrowseDir)
					mBrowseDir.Set(typed);

				Gui.Separator();
				if (Gui.igBeginChild_Str("##entries", .(0, -40), ChildFlags.Borders, 0))
				{
					if (Gui.Selectable(".. (up)"))
					{
						String parent = scope .();
						Path.GetDirectoryPath(mBrowseDir, parent).IgnoreError(); // a root has no parent: parent stays empty and is checked below
						if (!parent.IsEmpty)
						{
							mBrowseDir.Set(parent);
							mPathBuf.Set(parent);
						}
					}
					if (Directory.Exists(mBrowseDir))
					{
						List<String> dirs = scope .();
						List<String> files = scope .();
						for (let e in Directory.EnumerateDirectories(mBrowseDir))
						{
							String p = new .();
							e.GetFilePath(p);
							dirs.Add(p);
						}
						for (let e in Directory.EnumerateFiles(mBrowseDir))
						{
							String p = new .();
							e.GetFilePath(p);
							if (p.EndsWith(".bf", .OrdinalIgnoreCase))
								files.Add(p);
							else
								delete p;
						}
						dirs.Sort(scope (a, b) => String.Compare(a, b, true));
						files.Sort(scope (a, b) => String.Compare(a, b, true));
						for (let d in dirs)
						{
							String name = scope .();
							Path.GetFileName(d, name);
							if (Gui.Selectable(scope $"[dir] {name}"))
							{
								mBrowseDir.Set(d);
								mPathBuf.Set(d);
							}
						}
						for (let f in files)
						{
							String name = scope .();
							Path.GetFileName(f, name);
							if (Gui.Selectable(scope $"      {name}", false, SelectableFlags.AllowDoubleClick))
							{
								mPathBuf.Set(f);
								if (Gui.igIsMouseDoubleClicked_Nil(0))
								{
									Gui.igCloseCurrentPopup();
									RequestOpen(scope String(f));
								}
							}
						}
						ClearAndDeleteItems!(dirs);
						ClearAndDeleteItems!(files);
					}
					Gui.igEndChild();
				}
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.SameLine();
				Gui.TextDisabled("Tip: you can also drop a .bf file onto the window.");
				Gui.EndPopup();
			}
		}

		void DrawFolderPopup()
		{
			if (mOpenFolderPopup)
			{
				Gui.OpenPopup("Open Folder");
				mOpenFolderPopup = false;
			}
			if (Gui.igBeginPopupModal("Open Folder", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("Folder to show in the Project panel (e.g. D:\\ClockWork):");
				Gui.igSetNextItemWidth(520 * Look.Scale);
				bool enter = Gui.igInputText("##folder", mPathBuf.Ptr, (.)mPathBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (Gui.Button("Open", .(100 * Look.Scale, 0)) || enter)
				{
					String dir = scope .(mPathBuf.View);
					if (Directory.Exists(dir))
					{
						RequestOpenProject(dir);
						Gui.igCloseCurrentPopup();
					}
					else
						SetStatus("That folder doesn't exist");
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		Member FindType(StringView name)
		{
			if (Doc == null || Doc.Unit == null)
				return null;
			List<Member> types = scope .();
			Doc.Unit.CollectTypes(types);
			for (let t in types)
				if (t.Name == name)
					return t;
			return null;
		}

		void DrawAddFunctionPopup()
		{
			StringView popupName = mAddCtorMode ? "Add Constructor" : "Add Function";
			if (mOpenAddFunction)
			{
				mOpenAddFunction = false;
				mAddFnInit = true;
				if (Doc == null || Doc.Unit == null)
					mDialogRefusals++;
				else
					Gui.OpenPopup(popupName);
			}
			if (Gui.igBeginPopupModal(scope String(popupName), null, WindowFlags.AlwaysAutoResize))
			{
				if (mSelfTestCloseDialog)
				{
					mSelfTestCloseDialog = false;
					Gui.igCloseCurrentPopup();
				}
				if (mAddCtorMode)
				{
					DrawAddConstructorBody();
					Gui.EndPopup();
					return;
				}
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text(scope $"New function in {mAddTargetType}");
				Gui.Text("Name");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##name", mNameBuf.Ptr, (.)mNameBuf.Capacity, 0, null, null);
				if (mAddFnInit)
				{
					// The fields start from what the opener set (Return Type, a parameter list).
					mAddFnInit = false;
					var ret = mTypeBuf.View;
					ret.Trim();
					mAddFnRet.Set(ret.IsEmpty ? "void" : ret);
					ClearAndDeleteItems!(mAddFnRows);
					ParamRowsFromText(mParamsBuf.View, mAddFnRows);
				}
				let addFnType = FindType(mAddTargetType);
				Gui.Text("Return Type");
				// A chooser like the other type fields: only what Beef takes as a Return Type.
				TypeButton("##ret", mAddFnRet, 360 * Look.Scale, .Return, addFnType);
				// Each reason sits under the field it is about.
				bool retOk = TypeErrorText(mAddFnRet, .Return, addFnType);
				Gui.Text("Inputs");
				int removeAt = -1;
				for (let r in mAddFnRows)
				{
					Gui.PushID((int32)@r.Index);
					Gui.igSetNextItemWidth(120 * Look.Scale);
					PropertyGrid.Text("##pn", r.Name, ?, false, null, "name");
					Gui.SameLine(0, 4 * Look.Scale);
					PassingCombo("##pm", r, 62 * Look.Scale);
					Gui.SameLine(0, 4 * Look.Scale);
					float x = Gui.igGetFrameHeight();
					TypeButton("##pt", r.Type, (360 - 120 - 62 - 12) * Look.Scale - x, .Param, addFnType);
					Gui.SameLine(0, 4 * Look.Scale);
					if (Gui.Button(Icon.X, .(x, x)))
						removeAt = @r.Index;
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Remove this input");
					Gui.PopID();
				}
				if (removeAt >= 0)
				{
					delete mAddFnRows[removeAt];
					mAddFnRows.RemoveAt(removeAt);
				}
				if (Gui.Button(scope $"{Icon.Plus}  Add Input"))
				{
					ParamRow r = new .();
					r.Type.Set("int");
					String name = scope .("value");
					for (int n = 2; ParamRowNamed(mAddFnRows, name); n++)
					{
						name.Clear();
						name.AppendF("value{}", n);
					}
					r.Name.Set(name);
					mAddFnRows.Add(r);
				}
				String pars = scope .();
				ParamRowsText(mAddFnRows, pars);
				bool parOk = ParamsErrorText(pars, addFnType);
				Gui.igBeginDisabled(!retOk || !parOk);
				bool create = Gui.Button("Create", .(120 * Look.Scale, 0));
				Gui.igEndDisabled();
				if (create)
				{
					let type = FindType(mAddTargetType);
					if (type != null && !mNameBuf.View.IsEmpty)
					{
						String key = scope .();
						String name = scope .(mNameBuf.View);
						Doc.AddMethod(type, mAddFnRet, name, pars, key);
						let mg = Doc.FindMethod(key);
						if (mg != null)
							OpenTab(mg);
						UpdateTitle();
					}
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		static StringView[4] sCtorAccess = .("public", "protected", "internal", "private");

		bool mAddFnInit;
		String mAddFnRet = new .() ~ delete _;
		List<ParamRow> mAddFnRows = new .() ~ DeleteContainerAndItems!(_);

		static bool ParamRowNamed(List<ParamRow> rows, StringView name)
		{
			for (let r in rows)
				if (r.Name == name)
					return true;
			return false;
		}

		/// "out int a, String b = null" from the rows (rows without a name or type are left out).
		static void ParamRowsText(List<ParamRow> rows, String outText)
		{
			for (let r in rows)
			{
				if (r.Name.IsEmpty || r.Type.IsEmpty)
					continue;
				if (!outText.IsEmpty)
					outText.Append(", ");
				if (!r.Modifier.IsEmpty)
					outText.AppendF("{} ", r.Modifier);
				outText.AppendF("{} {}", r.Type, r.Name);
				if (r.Default != null)
					outText.AppendF(" = {}", r.Default);
			}
		}

		/// Rows from a parameter list as text ("ref int a, List<int> b = null").
		static void ParamRowsFromText(StringView text, List<ParamRow> outRows)
		{
			int depth = 0;
			int start = 0;
			void Piece(StringView piece)
			{
				var t = piece;
				t.Trim();
				if (t.IsEmpty)
					return;
				ParamRow r = new .();
				int d = 0;
				for (int i < t.Length)
				{
					let c = t[i];
					if (c == '(' || c == '<' || c == '[') d++;
					else if (c == ')' || c == '>' || c == ']') d--;
					else if (c == '=' && d == 0)
					{
						var def = StringView(t, i + 1);
						def.Trim();
						r.Default = new String(def);
						t = StringView(t, 0, i);
						t.Trim();
						break;
					}
				}
				for (let word in StringView[5]("ref ", "out ", "in ", "params ", "mut "))
				{
					if (t.StartsWith(word))
					{
						r.Modifier.Set(StringView(word, 0, word.Length - 1));
						t = StringView(t, word.Length);
						t.TrimStart();
						break;
					}
				}
				int last = t.Length;
				while (last > 0 && !t[last - 1].IsWhiteSpace)
					last--;
				r.Name.Set(StringView(t, last));
				var ty = StringView(t, 0, last);
				ty.Trim();
				r.Type.Set(ty);
				outRows.Add(r);
			}
			for (int i < text.Length)
			{
				let c = text[i];
				if (c == '(' || c == '<' || c == '[') depth++;
				else if (c == ')' || c == '>' || c == ']') depth--;
				else if (c == ',' && depth == 0)
				{
					Piece(StringView(text, start, i - start));
					start = i + 1;
				}
			}
			Piece(StringView(text, start, text.Length - start));
		}

		/// "a, b" from "int a, ref String b = null": the argument names of a parameter list.
		static void ArgNamesOf(StringView paramsText, String o)
		{
			int depth = 0;
			int start = 0;
			void Piece(StringView piece)
			{
				var t = piece;
				int d = 0;
				for (int i < t.Length)
				{
					let c = t[i];
					if (c == '(' || c == '<' || c == '[') d++;
					else if (c == ')' || c == '>' || c == ']') d--;
					else if (c == '=' && d == 0)
					{
						t = StringView(t, 0, i);
						break;
					}
				}
				t.Trim();
				if (t.IsEmpty)
					return;
				int last = t.Length;
				while (last > 0 && !t[last - 1].IsWhiteSpace)
					last--;
				if (!o.IsEmpty)
					o.Append(", ");
				// `ref int x` / `out int x` are passed as `ref x` / `out x`; an `in int x` as `x`
				// (Beef 0.43.6 has no `in` in an argument list).
				for (let word in StringView[2]("ref ", "out "))
					if (t.StartsWith(word))
						o.Append(word);
				o.Append(StringView(t, last));
			}
			for (int i < paramsText.Length)
			{
				let c = paramsText[i];
				if (c == '(' || c == '<' || c == '[') depth++;
				else if (c == ')' || c == '>' || c == ']') depth--;
				else if (c == ',' && depth == 0)
				{
					Piece(StringView(paramsText, start, i - start));
					start = i + 1;
				}
			}
			Piece(StringView(paramsText, start, paramsText.Length - start));
		}

		/// The `: base(...)` / `: this(...)` choices of a new constructor: the parent's constructors
		/// and this class's own others, by signature. `labels[i]` is shown, `texts[i]` is written.
		void BuildCtorChains(Member type, List<String> labels, List<String> texts)
		{
			labels.Add(new String("(no chaining)"));
			texts.Add(new String(""));
			let info = ClassInfoFor(Doc, type);
			if (type.TypeKind == "class" && !info.BaseClass.IsEmpty)
			{
				for (let bc in info.BaseCtors)
				{
					String args = scope .();
					ArgNamesOf(bc, args);
					labels.Add(new String()..AppendF("base({})", bc));
					texts.Add(new String()..AppendF("base({})", args));
				}
			}
			if (type.Members != null)
			{
				for (let m in type.Members)
				{
					if (m.Kind != .Method || !m.IsCtor || m.IsStatic || m.Params == null)
						continue;
					String types = scope .();
					SourceDocument.CtorTypesText(m, types);
					String args = scope .();
					for (let p in m.Params)
					{
						if (@p.Index > 0)
							args.Append(", ");
						if (p.Modifier == "ref" || p.Modifier == "out")
							args.AppendF("{} ", p.Modifier);
						args.Append(p.Name);
					}
					labels.Add(new String()..AppendF("this({})   (this class)", types));
					texts.Add(new String()..AppendF("this({})", args));
				}
			}
		}

		void DrawAddConstructorBody()
		{
			if (Gui.IsKeyPressed(Key.Escape, false))
				Gui.igCloseCurrentPopup();
			let type = FindType(mAddTargetType);
			Gui.Text(scope $"New constructor in {mAddTargetType}");
			Gui.Text("Access");
			Gui.igSetNextItemWidth(360 * Look.Scale);
			PropertyGrid.Combo("##ctoracc", ref mCtorAccess, sCtorAccess);
			Gui.Text("Parameters (e.g. int a, String b); none: the default constructor");
			Gui.igSetNextItemWidth(360 * Look.Scale);
			Gui.igInputText("##ctorparams", mParamsBuf.Ptr, (.)mParamsBuf.Capacity, 0, null, null);
			bool parOk = ParamsErrorText(mParamsBuf.View, type);
			List<String> labels = scope .();
			List<String> texts = scope .();
			defer { ClearAndDeleteItems!(labels); ClearAndDeleteItems!(texts); }
			if (type != null)
				BuildCtorChains(type, labels, texts);
			if (mCtorChain >= labels.Count)
				mCtorChain = 0;
			if (labels.Count > 1)
			{
				Gui.Text("Chain to another constructor first");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				if (Gui.igBeginCombo("##ctorchain", scope String(labels[mCtorChain]), 0))
				{
					for (int i < labels.Count)
						if (Gui.Selectable(scope $"{labels[i]}##chain{i}", i == mCtorChain))
							mCtorChain = (int32)i;
					Gui.igEndCombo();
				}
			}
			String sigKey = scope .();
			SourceDocument.ParamTypesKey(mParamsBuf.View, sigKey);
			bool dup = false;
			if (type != null && parOk)
			{
				let other = Doc.FindConstructor(type, sigKey);
				if (other != null)
				{
					String types = scope .();
					SourceDocument.CtorTypesText(other, types);
					ErrorText(scope $"{type.Name} already has Constructor ({types}). Change the parameters.");
					dup = true;
				}
			}
			Gui.igBeginDisabled(!parOk || dup || type == null);
			bool create = Gui.Button("Create", .(120 * Look.Scale, 0));
			Gui.igEndDisabled();
			if (create)
			{
				String key = scope .();
				if (Doc.AddConstructor(type, sCtorAccess[mCtorAccess], mParamsBuf.View, texts[mCtorChain], key))
				{
					let mg = Doc.FindMethod(key);
					if (mg != null)
						OpenTab(mg);
					UpdateTitle();
				}
				else
					SetStatus(scope $"Constructor: {Doc.LastError}", .Warning);
				Gui.igCloseCurrentPopup();
			}
			Gui.SameLine();
			if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				Gui.igCloseCurrentPopup();
		}

		void DrawAddVariablePopup()
		{
			if (mOpenAddVariable)
			{
				mOpenAddVariable = false;
				if (Doc == null || Doc.Unit == null)
					mDialogRefusals++;
				else
				{
					Gui.OpenPopup("Add Variable");
					mAddVarTypeSeen.Set("?"); // the dialog's defaults follow the first type shown
				}
			}
			if (Gui.igBeginPopupModal("Add Variable", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false) || mSelfTestClosePopups || mSelfTestCloseDialog)
				{
					mSelfTestClosePopups = false;
					mSelfTestCloseDialog = false;
					Gui.igCloseCurrentPopup();
				}
				if (Gui.igIsWindowAppearing())
				{
					Gui.igSetKeyboardFocusHere(0);
					mAddSetOnCreate = false;
					mAddStatic = false;
				}
				Gui.Text(scope $"New variable in {mAddTargetType}");
				Gui.Text("Name");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				Gui.igInputText("##vname", mNameBuf.Ptr, (.)mNameBuf.Capacity, 0, null, null);
				Gui.Text("Type");
				{
					// The type picker (basic types first, then the project's and the libraries' types, and
					// the containers); a type it does not list is typed into its search box and taken from there.
					String picked = scope .(mTypeBuf.View);
					if (TypeButton("##vtype", picked, 360 * Look.Scale, .Member, FindType(mAddTargetType)))
						mTypeBuf.Set(picked);
				}
				var varTyped = mTypeBuf.View;
				varTyped.Trim();
				MemberInit varInit = scope .();
				String varType = scope .();
				let addTarget = FindType(mAddTargetType);
				bool addLib = addTarget != null && addTarget.IsNodeLibrary;
				{
					// A static variable is global: Get / Set from any sheet as Owner.Name.
					bool sv = mAddStatic || addLib;
					Gui.igBeginDisabled(addLib);
					if (Gui.Checkbox("Static (a global variable)", &sv))
						mAddStatic = sv;
					Gui.igEndDisabled();
					if (Gui.igIsItemHovered(1 << 10 /* AllowWhenDisabled */))
						Gui.Tooltip(addLib ? scope $"{mAddTargetType} is a Node Library: every variable in it is static." : "One value for the whole program, read and written as Owner.Name from any sheet.");
				}
				bool addStatic = mAddStatic || addLib;
				DrawAddVarInit(varTyped, addTarget, varInit, varType, addStatic);
				if (!addStatic)
				{
					Gui.Checkbox("Set on create", &mAddSetOnCreate);
					if (Gui.igIsItemHovered(0))
						Gui.Tooltip("Creating the object asks for this value: it becomes a parameter of the create constructor.");
				}
				if (!varTyped.IsEmpty && !mNameBuf.View.IsEmpty)
				{
					// The line Create writes (SourceDocument.FieldDeclarationText), following the picked type.
					String preview = scope .();
					String tail = scope .();
					varInit.Emit(tail);
					SourceDocument.FieldDeclarationText(varType, mNameBuf.View, tail, addStatic, preview);
					SelfTestAddVarPreview.Set(preview);
					Gui.igDummy(.(0, 2 * Look.Scale));
					InitCodeText(preview, 360 * Look.Scale);
				}
				bool varOk = TypeErrorText(varTyped, .Member, FindType(mAddTargetType));
				Gui.igBeginDisabled(!varOk);
				bool createVar = Gui.Button("Create", .(120 * Look.Scale, 0)) || (SelfTestAddVarCreate && varOk);
				SelfTestAddVarCreate = false;
				Gui.igEndDisabled();
				if (createVar)
				{
					let type = FindType(mAddTargetType);
					if (type != null && !mNameBuf.View.IsEmpty)
					{
						if (AddVariableChecked(Doc, type, varType, mNameBuf.View, varInit, mAddSetOnCreate && !addStatic, addStatic))
							mLastVarType.Set(varTyped); // the next Add Variable starts with this type
						UpdateTitle();
					}
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}
		}

		void DrawRenamePopup()
		{
			if (mOpenRename)
			{
				Gui.OpenPopup("Rename");
				mOpenRename = false;
			}
			if (Gui.igBeginPopupModal("Rename", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("New name (every reference in the project is renamed; a preview comes first):");
				Gui.igSetNextItemWidth(360 * Look.Scale);
				bool enter = Gui.igInputText("##rename", mNameBuf.Ptr, (.)mNameBuf.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				if (mRenameTarget != null && mRenameVersion != Doc.Version)
				{
					// The source changed underneath the popup; the member pointer is stale.
					mRenameTarget = null;
					Gui.igCloseCurrentPopup();
				}
				if ((Gui.Button("Rename", .(120 * Look.Scale, 0)) || enter) && mRenameTarget != null && !mNameBuf.View.IsEmpty)
				{
					String newName = scope .(mNameBuf.View);
					String key = scope .(mRenameKey);
					// The type that declares it: references are renamed project-wide.
					List<Member> types = scope .();
					Doc.Unit.CollectTypes(types);
					Member owner = null;
					for (let t in types)
						if (t.Members != null && t.Members.Contains(mRenameTarget))
							owner = t;
					if (owner != null)
						StartProjectRename(.Member, mRenameTarget.Name, newName, owner.Name, key, Doc.FilePath);
					else
					{
						Doc.RenameMember(mRenameTarget, newName);
						if (!key.IsEmpty)
							RetargetTab(key, newName);
					}
					mRenameTarget = null;
					UpdateTitle();
					Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
				{
					mRenameTarget = null;
					Gui.igCloseCurrentPopup();
				}
				Gui.EndPopup();
			}
		}

		void DrawModals()
		{
			DrawRecoveryModal();
			if (mShowQuitModal)
			{
				Gui.OpenPopup("Unsaved Changes##quit");
				mShowQuitModal = false;
			}
			if (Gui.igBeginPopupModal("Unsaved Changes##quit", null, WindowFlags.AlwaysAutoResize))
			{
				if (Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.Text("These files have unsaved changes:");
				for (let d in mDocs)
				{
					if (!d.NeedsSave)
						continue;
					String name = scope .();
					Path.GetFileName(d.FilePath, name);
					Gui.TextColored(Theme.Warning, scope $"   {name}");
				}
				Gui.igSpacing();
				if (Gui.Button("Save All", .(100 * Look.Scale, 0)))
				{
					// Quit only when everything was written; a conflict keeps the editor open.
					if (SaveAll())
						QuitNow = true;
					else
						Gui.igCloseCurrentPopup();
				}
				Gui.SameLine();
				if (Gui.Button("Don't Save", .(100 * Look.Scale, 0)))
					QuitNow = true;
				Gui.SameLine();
				if (Gui.Button("Cancel", .(100 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				Gui.EndPopup();
			}

			DrawSafetyModals();

			SourceDocument changed = null;
			for (let d in mDocs)
				if (d.ExternalChange)
					changed = d;
			if (changed != null)
			{
				Gui.igSetNextWindowPos(.(Gui.igGetMainViewport().WorkPos.x + 20, Gui.igGetMainViewport().WorkPos.y + 30), Cond.Always, .(0, 0));
				if (Gui.Begin("##extchange", null, WindowFlags.AlwaysAutoResize | WindowFlags.NoTitleBar | WindowFlags.NoDocking | WindowFlags.NoSavedSettings))
				{
					String name = scope .();
					Path.GetFileName(changed.FilePath, name);
					Gui.TextColored(Theme.Warning, scope $"{name} changed on disk while you have unsaved edits to it.");
					if (Gui.Button("Reload (lose my edits)"))
						ReloadFromDisk(changed);
					Gui.SameLine();
					if (Gui.Button("Keep mine"))
					{
						changed.ExternalChange = false;
						if (File.GetLastWriteTime(changed.FilePath) case .Ok(let t))
							changed.DiskTime = t;
					}
				}
				Gui.End();
			}
		}

		/// Save-conflict and error dialogs (plain ImGui modals; the shell can restyle them).
		void DrawSafetyModals()
		{
			for (int i = mConflicts.Count - 1; i >= 0; i--)
				if (!mDocs.Contains(mConflicts[i]))
					mConflicts.RemoveAt(i);
			if (!mConflicts.IsEmpty && !Gui.igIsPopupOpen_Str("File Changed on Disk##conflict", 0) && mErrors.IsEmpty)
				Gui.OpenPopup("File Changed on Disk##conflict");
			if (Gui.igBeginPopupModal("File Changed on Disk##conflict", null, WindowFlags.AlwaysAutoResize))
			{
				if (mConflicts.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
				{
					let d = mConflicts[0];
					Gui.Text("This file was changed outside VisualBeef after you opened it:");
					Gui.TextColored(Theme.Warning, scope $"   {d.FilePath}");
					Gui.Text("Saving now would overwrite those changes.");
					Gui.igSpacing();
					if (Gui.Button("Overwrite", .(110 * Look.Scale, 0)))
					{
						mConflicts.RemoveAt(0);
						if (SaveDoc(d, true))
							SetStatus(scope $"Saved {d.FilePath} (overwrote the disk version)");
					}
					Gui.SameLine();
					if (Gui.Button("Reload", .(110 * Look.Scale, 0)))
					{
						mConflicts.RemoveAt(0);
						ReloadFromDisk(d);
					}
					Gui.SameLine();
					if (Gui.Button("Cancel", .(110 * Look.Scale, 0)))
						mConflicts.RemoveAt(0);
					Gui.igSpacing();
					Gui.TextDisabled("Overwrite keeps your version (the disk version goes to the .bak file). Reload discards your edits.");
				}
				Gui.EndPopup();
			}

			if (!mErrors.IsEmpty && !Gui.igIsPopupOpen_Str("Something went wrong##vberror", 0))
				Gui.OpenPopup("Something went wrong##vberror");
			if (Gui.igBeginPopupModal("Something went wrong##vberror", null, WindowFlags.AlwaysAutoResize))
			{
				if (mErrors.IsEmpty)
					Gui.igCloseCurrentPopup();
				else
				{
					Gui.TextColored(Theme.Warning, mErrors[0]);
					Gui.igSpacing();
					if (Gui.Button("OK", .(100 * Look.Scale, 0)) || Gui.IsKeyPressed(Key.Escape, false) || Gui.IsKeyPressed(Key.Enter, false))
					{
						delete mErrors[0];
						mErrors.RemoveAt(0);
						if (mErrors.IsEmpty)
							Gui.igCloseCurrentPopup();
					}
				}
				Gui.EndPopup();
			}
		}

		public void OnFileDropped(StringView path)
		{
			if (path.EndsWith(".bf", .OrdinalIgnoreCase))
				RequestOpen(path);
			else if (Directory.Exists(path))
				RequestOpenProject(path);
		}
	}
}
