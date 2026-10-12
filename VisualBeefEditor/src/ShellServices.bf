using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Catalog;
using VisualBeef.Document;
using VisualBeef.Graph;

namespace VisualBeef.Editor
{
	/// Shell services: background indexing, the recovery prompt, the compile configuration and
	/// compiler diagnostics on nodes (Problems panel). See docs/Editor-UI.md.
	extension EditorApp
	{
		// ---------------------------------------------------------------- background indexing

		IndexJob mIndexJob ~ delete _;
		/// True once Index holds a complete index of mProjectRoot (rescans can then be
		/// incremental and synchronous).
		bool mIndexReady;
		/// Open documents built before the libraries were known: rebuilt (retyped) after indexing.
		bool mRetypePending;

		public bool IsIndexing => mIndexJob != null;

		/// Starts (or restarts) indexing of mProjectRoot on a worker thread. The editor stays
		/// usable: graphs open and edit as usual, types and the catalog arrive when it finishes.
		void StartIndexing()
		{
			CancelIndexing(false);
			mIndexReady = false;
			// The Project Browser's change detection waits for the job; a change on disk while it
			// runs is caught by comparing this signature when it finishes.
			mCBSignature = ComputeCBSignature();
			mIndexJob = new IndexJob(mProjectRoot);
			mIndexJob.Start();
			Notify.Log(.Info, "Index", scope $"Indexing {mProjectRoot} in the background");
		}

		void CancelIndexing(bool report)
		{
			if (mIndexJob == null)
				return;
			mIndexJob.Cancel();
			delete mIndexJob; // waits for the worker (it stops at the next file)
			mIndexJob = null;
			if (report)
				SetStatus("Indexing cancelled: types and the node catalog are incomplete (Project Browser F5 indexes again)", .Warning);
		}

		/// Called every frame: takes the finished index.
		void PollIndexing()
		{
			if (mIndexJob == null || !mIndexJob.IsDone)
				return;
			let job = mIndexJob;
			mIndexJob = null;
			defer delete job;
			job.Wait();
			if (job.Cancelled || !ProjectIndex.SamePath(job.Root, mProjectRoot))
				return;
			Index.TakeFrom(job.Project);
			// The worker built the libraries' catalog entries: adopting them only renumbers
			// categories, so the first node menu does not build anything on the UI thread.
			double prebuiltMs = (job.Catalogs != null) ? job.Catalogs.BuildMs : 0;
			mNodeMenu.Types.Catalog.Adopt(job.Catalogs);
			job.Catalogs = null;
			mNodeMenu.Types.SetLibraries(job.Libraries, job.Root, job.LibraryMs, job.CacheHits);
			mIndexReady = true;
			{
				let swWarm = scope System.Diagnostics.Stopwatch(true);
				mNodeMenu.Catalog.Refresh();
				let adoptMs = swWarm.Elapsed.TotalMilliseconds;
				swWarm.Restart();
				let tree = mNodeMenu.Catalog.Tree;
				Notify.Log(.Info, "Index", scope $"Node catalog: {mNodeMenu.Catalog.TotalEntries} entries built on the indexer in {prebuiltMs:0} ms; adopted in {adoptMs:0.0} ms, category tree {swWarm.Elapsed.TotalMilliseconds:0.0} ms ({tree.Total} nodes)");
			}
			let startSignature = mCBSignature;
			FinishScan();
			if (mCBSignature != startSignature)
				ScanProject(); // files changed while indexing: an incremental rescan picks them up
			mRetypePending = true;
			String libs = scope .();
			for (let l in mNodeMenu.Types.Libraries)
				libs.AppendF("{}{}", libs.IsEmpty ? "" : ", ", l.Name);
			Notify.Log(.Info, "Index", scope $"Indexed {job.Root}: {Index.Files.Count} files in {job.ProjectMs:0} ms ({Index.GeneratedLibraries.Count} generated SDK folders loaded as libraries); libraries {libs} in {job.LibraryMs:0} ms ({job.CacheHits} from cache, {job.LibrariesParsed} parsed)");
			SetStatus(scope $"Indexed {Index.Files.Count} files, {mNodeMenu.Types.Libraries.Count} libraries ({job.ProjectMs + job.LibraryMs:0} ms)", .Info, false);
		}

		/// After indexing: rebuild the graphs of untouched documents so their pins get types.
		/// Documents with edits, undo history or unsaved layout are left as they are.
		void RetypeOpenDocuments()
		{
			if (!mRetypePending || Gui.igIsPopupOpen_Str("", PopupFlags.AnyPopup) || Gui.igIsAnyItemActive() || mCommitPending)
				return;
			mRetypePending = false;
			for (let d in mDocs)
			{
				if (d.FilePath.IsEmpty || d.Modified || d.CanUndo || d.LayoutTouched || !File.Exists(d.FilePath))
					continue;
				if (d.Load(d.FilePath) case .Ok)
				{
					if (File.GetLastWriteTime(d.FilePath) case .Ok(let t))
						d.DiskTime = t;
					Index.Update(d.FilePath, d.Unit);
					d.IndexedVersion = d.Version;
				}
			}
			mSourceVersion = -1;
		}

		/// The rest of a scan once Index is complete: the Project Browser's file list and tree.
		void FinishScan()
		{
			ClearAndDeleteItems!(mProjectFiles);
			// Files already open use their live (possibly unsaved) text.
			for (let d in mDocs)
				if (d.Unit != null && d.FilePath.StartsWith(mProjectRoot))
					Index.Update(d.FilePath, d.Unit);
			for (let f in Index.Files)
				mProjectFiles.Add(new String(f.Path));
			BuildContentTree();
			mCBSignature = ComputeCBSignature();
		}

		/// Status bar: indexing progress with a cancel button. Returns the width used.
		void DrawIndexingStatus()
		{
			if (mIndexJob == null)
				return;
			String text = scope .();
			mIndexJob.Progress.GetPhase(text);
			let f = mIndexJob.Progress.Fraction;
			Gui.SameLine(0, 16 * Look.Scale);
			Gui.igAlignTextToFramePadding();
			Gui.TextColored(Look.AccentBlue, Icon.LoaderCircle);
			Gui.SameLine(0, 6 * Look.Scale);
			if (f >= 0)
			{
				let pos = Gui.igGetCursorScreenPos();
				float w = 120 * Look.Scale;
				float h = Gui.igGetFontSize() * 0.45f;
				float y = pos.y + (Gui.igGetFrameHeight() - h) * 0.5f;
				let dl = Gui.igGetWindowDrawList();
				Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + w, y + h), Look.Recessed, 2, 0);
				Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + w * f, y + h), Look.Primary, 2, 0);
				Gui.igDummy(.(w, Gui.igGetFrameHeight()));
				Gui.SameLine(0, 6 * Look.Scale);
			}
			Gui.igAlignTextToFramePadding();
			Gui.TextColored(Look.ForegroundDim, text);
			Gui.SameLine(0, 4 * Look.Scale);
			if (Gui.SmallButton(scope $"{Icon.X}##cancelindex"))
				CancelIndexing(true);
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("Cancel indexing (the editor keeps working without full types and catalog)");
		}

		// ---------------------------------------------------------------- recovery prompt

		List<RecoveredFile> mRecovered = new .() ~ DeleteContainerAndItems!(_);
		bool mShowRecoveryModal;

		/// At start-up: journal entries of sessions that crashed or were killed.
		public void CheckRecovery()
		{
			Recovery.FindOrphans(mRecovered);
			if (mRecovered.IsEmpty)
				return;
			mShowRecoveryModal = true;
			Notify.Log(.Warning, "Editor", scope $"Found unsaved changes of {mRecovered.Count} file(s) from a session that did not exit cleanly");
		}

		void RecoverAll()
		{
			int restored = 0;
			for (let rf in mRecovered)
			{
				if (!File.Exists(rf.SourcePath))
				{
					Notify.Log(.Warning, "Editor", scope $"Recovery: {rf.SourcePath} no longer exists; the text stays in {rf.JournalPath}");
					continue;
				}
				let doc = OpenFile(rf.SourcePath, false);
				if (doc == null)
					continue;
				if (doc.Unit != null && doc.Unit.Text == rf.Text)
					continue; // the file already holds that text
				doc.ApplyText(rf.Text);
				doc.RefreshModified();
				restored++;
				Notify.Log(.Info, "Editor", scope $"Recovered unsaved changes of {rf.SourcePath} (from {rf.Time})");
			}
			bool keepJournal = false;
			for (let rf in mRecovered)
				if (!File.Exists(rf.SourcePath))
					keepJournal = true;
			if (!keepJournal)
				Recovery.DeleteOrphans();
			ClearAndDeleteItems!(mRecovered);
			UpdateTitle();
			if (restored > 0)
				Notify.Success(scope $"Recovered {restored} file(s): review and save them (Ctrl+Shift+S)");
		}

		void DrawRecoveryModal()
		{
			if (mShowRecoveryModal)
			{
				Gui.OpenPopup("Recover unsaved changes?##recovery");
				mShowRecoveryModal = false;
			}
			if (!Gui.igBeginPopupModal("Recover unsaved changes?##recovery", null, WindowFlags.AlwaysAutoResize))
				return;
			Gui.Text("VisualBeef did not exit cleanly last time. These files had unsaved changes:");
			Gui.igSpacing();
			for (let rf in mRecovered)
			{
				Gui.TextColored(Theme.Warning, scope $"   {rf.SourcePath}");
				Gui.SameLine();
				Gui.TextDisabled(scope $"  {rf.Time}, {rf.Text.Length} chars{File.Exists(rf.SourcePath) ? "" : "  (file no longer exists)"}");
			}
			Gui.igSpacing();
			Gui.TextDisabled("Recover opens each file with the recovered text as unsaved changes (undo goes back to the disk version).");
			Gui.igSpacing();
			if (Gui.Button("Recover", .(120 * Look.Scale, 0)))
			{
				RecoverAll();
				Gui.igCloseCurrentPopup();
			}
			Gui.SameLine();
			if (Gui.Button("Discard", .(120 * Look.Scale, 0)))
			{
				Recovery.DeleteOrphans();
				ClearAndDeleteItems!(mRecovered);
				Notify.Log(.Info, "Editor", "Discarded the recovered changes");
				Gui.igCloseCurrentPopup();
			}
			Gui.SameLine();
			if (Gui.Button("Decide Later", .(120 * Look.Scale, 0)))
			{
				ClearAndDeleteItems!(mRecovered);
				Gui.igCloseCurrentPopup();
			}
			Gui.EndPopup();
		}

		// ---------------------------------------------------------------- compile configuration

		/// "Debug" / "Release" for the workspace, and why ("your choice", "the project's .vbproject", ...).
		public void ResolveCompileConfig(StringView workspaceDir, String outConfig, String outReason = null)
		{
			let chosen = Settings.ProjectValue(workspaceDir, "config");
			if (chosen == "Debug" || chosen == "Release")
			{
				outConfig.Set(chosen);
				outReason?.Set("chosen for this project");
				return;
			}
			if (Prefs.DefaultConfig == 1 || Prefs.DefaultConfig == 2)
			{
				outConfig.Set((Prefs.DefaultConfig == 1) ? "Debug" : "Release");
				outReason?.Set("Editor Preferences default");
				return;
			}
			ProjectManifest manifest = scope .();
			if (manifest.Read(workspaceDir) && (manifest.Configuration == "Debug" || manifest.Configuration == "Release"))
			{
				outConfig.Set(manifest.Configuration);
				outReason?.Set(manifest.Host.IsEmpty ? "named by the project's .vbproject" : scope $"named by the project's .vbproject ({manifest.Host})");
				return;
			}
			String probe = scope .();
			probe.AppendF("{}{}BeefSpace_User.toml", workspaceDir, Path.DirectorySeparatorChar);
			MiniToml user = scope .();
			if (MiniToml.Load(probe, user))
			{
				let last = user.Get("LastConfig");
				if (last == "Debug" || last == "Release")
				{
					outConfig.Set(last);
					outReason?.Set("the Beef IDE's last configuration (BeefSpace_User.toml)");
					return;
				}
			}
			outConfig.Set("Debug");
			outReason?.Set("default");
		}

		/// The workspace Compile would build (empty when none).
		void CurrentWorkspace(String outDir)
		{
			String probe = scope .();
			if (!Doc.FilePath.IsEmpty)
				probe.Set(Doc.FilePath);
			else if (!mProjectRoot.IsEmpty)
				probe.AppendF("{}{}x.bf", mProjectRoot, Path.DirectorySeparatorChar);
			else
				return;
			BuildRunner.FindWorkspace(probe, outDir);
		}

		void SetCompileConfig(StringView config)
		{
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
				return;
			let proj = Settings.Project(ws);
			if (config.IsEmpty)
				proj.Remove("config");
			else
				proj.Set("config", Json.NewString(config));
			Settings.Save();
			String cfg = scope .();
			ResolveCompileConfig(ws, cfg);
			Notify.Log(.Info, "Build", scope $"Compile configuration for {ws}: {cfg}");
		}

		/// Items for the toolbar dropdown and the Build menu.
		void DrawConfigItems()
		{
			String ws = scope .();
			CurrentWorkspace(ws);
			if (ws.IsEmpty)
			{
				Gui.TextDisabled("No workspace (BeefSpace.toml) for the current file");
				return;
			}
			String cfg = scope .();
			String reason = scope .();
			ResolveCompileConfig(ws, cfg, reason);
			let chosen = Settings.ProjectValue(ws, "config");
			if (Gui.MenuItem("Debug", "", cfg == "Debug"))
				SetCompileConfig("Debug");
			if (Gui.MenuItem("Release", "", cfg == "Release"))
				SetCompileConfig("Release");
			Gui.Separator();
			if (Gui.MenuItem("Use the project default", "", chosen.IsEmpty))
				SetCompileConfig("");
			Gui.TextDisabled(scope $"Now: {cfg} ({reason})");
		}

		void DrawBuildMenu()
		{
			if (!Gui.BeginMenu("Build"))
				return;
			if (Gui.MenuItem(scope $"{Icon.Compile}  Compile", "F7"))
				Compile();
			Gui.Separator();
			Gui.TextDisabled("Configuration");
			DrawConfigItems();
			Gui.Separator();
			if (Gui.MenuItem(scope $"{Icon.CircleX}  Problems"))
			{
				ShowCompilerResults = true;
				mFocusCompilerResults = true;
			}
			if (Gui.MenuItem(scope $"{Icon.FolderOpen}  Open Logs Folder"))
			{
				String dir = scope .();
				AppPaths.Sub("logs", dir);
				ShowInExplorer(dir, false);
			}
			Gui.EndMenu();
		}

		// ---------------------------------------------------------------- diagnostics on nodes

		/// Maps every located compiler message to the method / node that owns its line. Files
		/// that are not open are loaded just for the mapping.
		void MapDiagnostics()
		{
			if (mBuild == null)
				return;
			Dictionary<String, SourceDocument> temp = scope .();
			defer { for (let kv in temp) { delete kv.key; delete kv.value; } }
			int onNodes = 0;
			for (let d in mBuild.Messages)
			{
				if (!d.HasLocation || !File.Exists(d.Path))
					continue;
				var doc = FindDoc(d.Path);
				bool isTemp = false;
				if (doc == null)
				{
					String key = scope .(d.Path);
					key.ToLower();
					key.Replace('/', '\\');
					if (!temp.TryGetValue(key, out doc))
					{
						doc = new SourceDocument();
						if (doc.Load(d.Path) case .Err)
						{
							delete doc;
							doc = null;
						}
						temp[new String(key)] = doc;
					}
					isTemp = true;
				}
				if (doc == null)
					continue;
				if (DiagnosticMap.Locate(doc, d))
					onNodes++;
				if (isTemp)
				{
					// The temporary graph is deleted below: resolve again from the key later.
					d.ResolvedSerial = 0;
					d.NodeId = -1;
				}
			}
			if (!mBuild.Messages.IsEmpty)
				Notify.Log(.Verbose, "Build", scope $"{mBuild.Messages.Count} message(s), {onNodes} mapped to graph nodes");
		}

		/// Compile errors and warnings of this graph, by node id (a node keeps its first message).
		public void GetNodeDiagnostics(MethodGraph mg, Dictionary<int32, String> outErrors, Dictionary<int32, String> outWarnings)
		{
			if (mBuild == null || mBuild.Running)
				return;
			for (let d in mBuild.Messages)
			{
				if (!d.OnNode || d.MethodKey != mg.Key || !BuildRunner.SamePath(d.Path, mg.Doc.FilePath))
					continue;
				let node = DiagnosticMap.Resolve(mg, d);
				if (node == null)
					continue;
				let target = d.IsError ? outErrors : outWarnings;
				if (!target.ContainsKey(node.Id) && !outErrors.ContainsKey(node.Id))
					target[node.Id] = new String(d.Text);
			}
		}

		/// Opens the graph and selects the node of a diagnostic; falls back to the line.
		void JumpToDiagnostic(Diagnostic d)
		{
			if (!d.HasLocation || !File.Exists(d.Path))
				return;
			if (!d.MethodKey.IsEmpty)
			{
				let doc = OpenFile(d.Path, false);
				let mg = doc?.FindMethod(d.MethodKey);
				if (mg != null && mg.Graphable)
				{
					OpenTab(mg);
					let node = DiagnosticMap.Resolve(mg, d);
					if (node != null)
					{
						let tab = CurrentTab;
						tab.SelectOnly(node.Id);
						tab.CenterOn(node.X + 100, node.Y + 40);
						return;
					}
				}
			}
			JumpToLine(d.Path, d.Line);
		}
	}
}
