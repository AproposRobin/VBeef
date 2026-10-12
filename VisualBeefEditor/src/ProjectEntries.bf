using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// The workspace's projects in the Project Browser: the folder tree marks every project BeefSpace.toml lists
	/// (its own icon and name, the startup project marked), the project context menu (Project Settings, Set as
	/// Startup Project, Add as Dependency of the current project, Remove from Workspace), Add > New Project in
	/// This Workspace and Add Existing Project, and the workspace edits that follow a project folder renamed,
	/// moved or deleted. The files are edited by WorkspaceFiles (VisualBeefCore); every change is logged.
	extension EditorApp
	{
		/// BeefSpace.toml of the open folder (at or above it), read when the tree is built; null when there is none.
		BeefWorkspace mWorkspace ~ delete _;
		/// Projects of the workspace whose folders are outside the open folder (leaf rows at the end of the tree).
		List<CBDir> mCBOutsideProjects = new .() ~ DeleteContainerAndItems!(_);

		/// A tree / tile action, run after the Project Browser is drawn (it may rebuild the tree).
		enum WsAction
		{
			None,
			Settings,
			SetStartup,
			AddDependency,
			RemoveDependency,
			AddToWorkspace,
			RemoveFromWorkspace,
			AddExisting,
			RenameProject
		}
		WsAction mWsAction;
		bool mWsRescanPending;
		String mWsActionPath = new .() ~ delete _;
		String mWsActionName = new .() ~ delete _;
		String mWsActionTarget = new .() ~ delete _;
		bool mWsActionFlag;

		// New Project in This Workspace
		bool mOpenWsNew;
		bool mWsNewOpen;
		TextBuffer mWsNewName = new .(256) ~ delete _;
		int32 mWsNewKind;
		bool mWsNewAddDep = true;
		String mWsNewLocation = new .() ~ delete _;
		bool mWsNewRefocus;
		// Add Existing Project without a native folder dialog
		bool mOpenWsExisting;
		TextBuffer mWsExistingPath = new .(2048) ~ delete _;

		/// Self tests: the tree row whose context menu opens on its next draw (path), and the + Add menu.
		String mSelfTestTreeMenu = new .() ~ delete _;
		bool mSelfTestAddMenu;

		static uint32 ProjectColor => Gui.Color(110, 176, 255);
		static uint32 StartupColor => Gui.Color(139, 194, 74);

		// ------------------------------------------------------------------ the workspace model

		/// The BeefSpace.toml the open folder belongs to (nearest at or above it), or empty.
		void WorkspaceFileOf(String outFile)
		{
			outFile.Clear();
			if (mProjectRoot.IsEmpty)
				return;
			WorkspaceFiles.FindWorkspace(mProjectRoot, outFile);
		}

		/// Where a new workspace file goes when there is none yet: the open folder.
		void WorkspaceFileOrNew(String outFile)
		{
			WorkspaceFileOf(outFile);
			if (outFile.IsEmpty && !mProjectRoot.IsEmpty)
				WorkspaceFiles.Join(mProjectRoot, WorkspaceFiles.WorkspaceFileName, outFile);
		}

		/// Reads the workspace and marks the folders of its projects in the tree (called by BuildContentTree).
		void MarkProjects()
		{
			delete mWorkspace;
			mWorkspace = null;
			ClearAndDeleteItems!(mCBOutsideProjects);
			if (mCBTree == null)
				return;
			String wsFile = scope .();
			WorkspaceFileOf(wsFile);
			if (!wsFile.IsEmpty)
			{
				mWorkspace = new .();
				if (!mWorkspace.Load(wsFile))
				{
					delete mWorkspace;
					mWorkspace = null;
				}
			}
			MarkProjects(mCBTree);
			if (mWorkspace == null)
				return;
			for (let p in mWorkspace.Projects)
			{
				if (!p.HasPath || FindCBDir(p.Dir) != null)
					continue;
				CBDir d = new .();
				d.Name.Set(p.RelPath);
				d.Path.Set(p.Dir);
				d.ProjectName = new String(p.Name);
				d.Startup = p.Name == mWorkspace.Startup;
				d.Outside = true;
				mCBOutsideProjects.Add(d);
			}
		}

		void MarkProjects(CBDir dir)
		{
			DeleteAndNullify!(dir.ProjectName);
			dir.Startup = false;
			dir.LooseProject = false;
			let p = mWorkspace?.FindDir(dir.Path);
			if (p != null)
			{
				dir.ProjectName = new String(p.Name);
				dir.Startup = p.Name == mWorkspace.Startup;
			}
			else
			{
				String toml = scope .();
				WorkspaceFiles.Join(dir.Path, BeefProjectFile.FileName, toml);
				dir.LooseProject = File.Exists(toml);
			}
			for (let sub in dir.Dirs)
				MarkProjects(sub);
		}

		/// The project the user works in: the one of the open document, else the startup project.
		WorkspaceProject CurrentProject()
		{
			if (mWorkspace == null)
				return null;
			let doc = EditDoc;
			if (doc != null && !doc.FilePath.IsEmpty)
			{
				let p = mWorkspace.ProjectOf(doc.FilePath);
				if (p != null)
					return p;
			}
			return mWorkspace.Find(mWorkspace.Startup);
		}

		/// The tree row of a project folder, or null.
		CBDir ProjectDirOf(StringView path)
		{
			let d = FindCBDir(path);
			if (d != null && d.ProjectName != null)
				return d;
			for (let o in mCBOutsideProjects)
				if (ProjectIndex.SamePath(o.Path, path))
					return o;
			return null;
		}

		void LogWorkspaceChanges(List<String> changes)
		{
			for (let c in changes)
				Notify.Log(.Info, "Project", c);
		}

		void QueueWsAction(WsAction action, StringView path, StringView name, StringView target = default, bool flag = false)
		{
			mWsAction = action;
			mWsActionFlag = flag;
			mWsActionPath.Set(path);
			mWsActionName.Set(name);
			mWsActionTarget.Set(target);
		}

		// ------------------------------------------------------------------ menus

		/// A menu item with an icon-font glyph where the asset menus draw their icons.
		bool GlyphMenuItem(StringView glyph, uint32 color, StringView label, StringView shortcut = "", bool enabled = true)
		{
			String l = scope .();
			l.AppendF("      {}", label);
			bool r = Gui.MenuItem(l, shortcut, false, enabled);
			let min = Gui.igGetItemRectMin();
			let max = Gui.igGetItemRectMax();
			float h = max.y - min.y;
			let size = Gui.CalcTextSize(glyph);
			Gui.DrawText(Gui.igGetWindowDrawList(), .(min.x + h * 0.5f - size.x * 0.5f, min.y + (h - size.y) * 0.5f), enabled ? color : Look.ForegroundDim, glyph);
			return r;
		}

		/// The PROJECTS part of the + Add / right-click menu.
		void DrawProjectAddItems()
		{
			Gui.TextDisabled("PROJECTS");
			if (GlyphMenuItem(Icon.Package, ProjectColor, "New Project in This Workspace..."))
				StartNewWorkspaceProject();
			if (GlyphMenuItem(Icon.FolderOpen, ProjectColor, "Add Existing Project..."))
				QueueWsAction(.AddExisting, "", "");
		}

		/// The right-click menu of a project row (tree) or a project folder tile.
		void DrawProjectMenu(CBDir d)
		{
			let name = d.ProjectName;
			Gui.TextColored(ProjectColor, scope $"{Icon.Package}  Project {name}");
			if (d.Startup)
			{
				Gui.SameLine();
				Gui.TextColored(StartupColor, "(startup)");
			}
			Gui.Separator();
			if (GlyphMenuItem(Icon.SlidersHorizontal, Look.Foreground, "Project Settings"))
				QueueWsAction(.Settings, d.Path, name);
			if (GlyphMenuItem(Icon.Pencil, Look.Foreground, "Rename Project..."))
				StartRenameProject(d);
			if (GlyphMenuItem(Icon.Play, StartupColor, "Set as Startup Project", "", !d.Startup))
				QueueWsAction(.SetStartup, d.Path, name);
			let cur = CurrentProject();
			if (cur != null && cur.Name != name && cur.HasPath)
			{
				String curName = scope .(cur.Name);
				BeefProjectFile pf = scope .();
				bool depends = pf.Load(cur.Dir) && pf.DependsOn(name);
				if (depends)
				{
					if (GlyphMenuItem(Icon.Minus, Look.Foreground, scope $"Remove as Dependency of {curName}"))
						QueueWsAction(.RemoveDependency, cur.Dir, name, curName);
				}
				else if (GlyphMenuItem(Icon.Plus, Look.Foreground, scope $"Add as Dependency of {curName}"))
					QueueWsAction(.AddDependency, cur.Dir, name, curName);
			}
			if (d.Outside || mWorkspace?.FindDir(d.Path)?.RelPath != ".")
			{
				if (GlyphMenuItem(Icon.X, Look.Foreground, "Remove from Workspace"))
					QueueWsAction(.RemoveFromWorkspace, d.Path, name);
				if (Gui.igIsItemHovered(0))
					Gui.Tooltip("Takes the project out of BeefSpace.toml; its folder and files stay");
			}
		}

		/// Rename, New Folder and Delete of a folder row (and of a project's folder).
		void DrawFolderOps(CBDir d)
		{
			if (GlyphMenuItem(Icon.Pencil, Look.Foreground, d.ProjectName != null ? "Rename Project Folder..." : "Rename...", "F2"))
			{
				CBItem item = new .();
				item.Kind = .Folder;
				item.Name.Set(d.Name);
				item.Path.Set(d.Path);
				CBItem.MakeKey(.Folder, d.Path, "", item.Key);
				StartRename(item);
				delete item;
			}
			if (GlyphMenuItem(Icon.FolderPlus, Look.AccentFolder, "New Folder..."))
				StartNewAsset(.Folder, d.Path);
			if (GlyphMenuItem(Icon.Trash2, Look.Foreground, "Delete...", "Del"))
			{
				ClearAndDeleteItems!(mCBDeleteItems);
				CBItem item = new .();
				item.Kind = .Folder;
				item.Name.Set(d.Name);
				item.Path.Set(d.Path);
				CBItem.MakeKey(.Folder, d.Path, "", item.Key);
				mCBDeleteItems.Add(item);
				mOpenCBDelete = true;
			}
			if (d.LooseProject && GlyphMenuItem(Icon.Package, ProjectColor, "Add to Workspace"))
				QueueWsAction(.AddToWorkspace, d.Path, d.Name);
		}

		/// The right-click menu of a tree row: the workspace (root), a project, or a folder.
		void DrawTreeRowMenu(CBDir d, bool isRoot, bool asProject)
		{
			if (mSelfTestCloseMenus)
				Gui.igCloseCurrentPopup();
			if (asProject)
			{
				DrawProjectMenu(d);
				if (!d.Outside)
				{
					Gui.Separator();
					if (!isRoot)
						DrawFolderOps(d);
					else if (GlyphMenuItem(Icon.FolderPlus, Look.AccentFolder, "New Folder..."))
						StartNewAsset(.Folder, d.Path);
					Gui.Separator();
					DrawAddMenu(d.Path, false);
				}
				return;
			}
			Gui.TextColored(isRoot ? Look.Foreground : Look.AccentFolder, scope $"{(isRoot ? Icon.Boxes : Icon.Folder)}  {d.Name}");
			if (isRoot && mWorkspace != null)
			{
				Gui.SameLine();
				Gui.TextDisabled("(workspace)");
			}
			Gui.Separator();
			if (!isRoot)
				DrawFolderOps(d);
			else if (GlyphMenuItem(Icon.FolderPlus, Look.AccentFolder, "New Folder..."))
				StartNewAsset(.Folder, d.Path);
			Gui.Separator();
			DrawAddMenu(d.Path, false);
		}

		/// A tree row's label and the marks after it. Returns the row's text colour.
		uint32 TreeRowLabel(CBDir d, StringView name, bool isRoot, bool asProject, String outLabel)
		{
			if (asProject)
			{
				outLabel.AppendF("{}  {}", Icon.Package, d.ProjectName);
				return ProjectColor;
			}
			if (isRoot)
			{
				outLabel.AppendF("{}  {}", (mWorkspace != null) ? Icon.Boxes : Icon.FolderOpen, name);
				return Gui.Color(230, 230, 230);
			}
			outLabel.AppendF("{}  {}", Icon.Folder, name);
			return Gui.Color(214, 190, 136);
		}

		/// After a project row: "startup", and the folder when it is not named like the project.
		void TreeRowMarks(CBDir d, bool asProject)
		{
			if (!asProject)
				return;
			if (d.Startup)
			{
				Gui.SameLine();
				Gui.TextColored(StartupColor, "startup");
			}
			if (d.Outside)
			{
				Gui.SameLine();
				Gui.TextDisabled(scope $"({d.Name})");
			}
			else if (StringView.Compare(d.Name, d.ProjectName, true) != 0)
			{
				Gui.SameLine();
				Gui.TextDisabled(scope $"({d.Name})");
			}
		}

		void TreeRowTooltip(CBDir d, bool isRoot, bool asProject)
		{
			if (!Gui.igIsItemHovered(0))
				return;
			if (asProject)
			{
				String rel = scope .();
				if (d.Outside)
					rel.Set(d.Path);
				else
					RelativeToRoot(d.Path, rel);
				Gui.Tooltip(scope $"Project {d.ProjectName}{(d.Startup ? " (startup project)" : "")}\n{rel}{(d.Outside ? "  (outside the open folder)" : "")}\nRight-click: Project Settings, startup project, dependencies");
			}
			else if (isRoot)
				Gui.Tooltip((mWorkspace != null) ? scope $"Workspace ({mWorkspace.FilePath})" : StringView(mProjectRoot));
		}

		// ------------------------------------------------------------------ actions

		/// Runs the action a menu asked for (after the Project Browser is drawn: it may rebuild the tree).
		void ProcessWorkspaceRequest()
		{
			let action = mWsAction;
			if (action == .None)
			{
				FlushWorkspaceRescan();
				return;
			}
			mWsAction = .None;
			String path = scope .(mWsActionPath);
			String name = scope .(mWsActionName);
			String target = scope .(mWsActionTarget);
			bool flag = mWsActionFlag;
			switch (action)
			{
			case .Settings: OpenProjectSettings(path);
			case .SetStartup: SetStartupProject(name);
			case .AddDependency: SetProjectDependency(path, target, name, true);
			case .RemoveDependency: SetProjectDependency(path, target, name, false);
			case .AddToWorkspace: AddExistingProjectAt(path);
			case .RemoveFromWorkspace: RemoveProjectFromWorkspace(name);
			case .AddExisting: StartAddExistingProject();
			case .RenameProject: RenameProject(path, target, flag);
			case .None:
			}
			FlushWorkspaceRescan();
		}

		/// Re-reads the workspace and the tree after an edit of the workspace files: on the next
		/// ProcessWorkspaceRequest (a menu or Properties may be drawing from the current tree).
		void AfterWorkspaceEdit()
		{
			mWsRescanPending = true;
			if (mSelProjectActive)
				mPSReloadPending = true;
		}

		/// Applies a pending re-read now (self tests; the frame does it in ProcessWorkspaceRequest).
		void FlushWorkspaceRescan()
		{
			if (!mWsRescanPending)
				return;
			mWsRescanPending = false;
			ScanProject();
		}

		public bool SetStartupProject(StringView name)
		{
			if (!CheckWritable())
				return false;
			String ws = scope .();
			WorkspaceFileOf(ws);
			if (ws.IsEmpty)
			{
				ReportError("There is no BeefSpace.toml for this folder: add a project to the workspace first.");
				return false;
			}
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			if (WorkspaceFiles.SetStartup(ws, name, changes, err) case .Err)
			{
				ReportError(scope $"Could not set the startup project: {err}");
				return false;
			}
			LogWorkspaceChanges(changes);
			AfterWorkspaceEdit();
			SetStatus(scope $"{name} is the startup project");
			return true;
		}

		/// Adds or removes `dep` in the dependencies of the project in `projDir` (named `projName`).
		public bool SetProjectDependency(StringView projDir, StringView projName, StringView dep, bool on)
		{
			if (!CheckWritable())
				return false;
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			if (WorkspaceFiles.SetDependency(projDir, dep, on, changes, err) case .Err)
			{
				ReportError(scope $"Could not change the dependencies of {projName}: {err}");
				return false;
			}
			LogWorkspaceChanges(changes);
			AfterWorkspaceEdit();
			SetStatus(on ? scope $"{projName} now depends on {dep}" : scope $"{projName} no longer depends on {dep}");
			return true;
		}

		public bool RemoveProjectFromWorkspace(StringView name)
		{
			if (!CheckWritable())
				return false;
			String ws = scope .();
			WorkspaceFileOf(ws);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			if (WorkspaceFiles.RemoveProject(ws, name, changes, err) case .Err)
			{
				ReportError(scope $"Could not remove {name} from the workspace: {err}");
				return false;
			}
			LogWorkspaceChanges(changes);
			AfterWorkspaceEdit();
			SetStatus(scope $"Removed {name} from the workspace (its files are kept)");
			return true;
		}

		/// Add > Add Existing Project...: the native folder dialog, else a path box.
		void StartAddExistingProject()
		{
			char8[4096] buf = default;
			String start = scope .(mProjectRoot);
			int32 r = Host.vbh_native_dialog(1, start, &buf, 4096);
			if (r == 1)
			{
				AddExistingProjectAt(StringView(&buf));
				return;
			}
			if (r == 0)
				return;
			mWsExistingPath.Set(mProjectRoot);
			mOpenWsExisting = true;
		}

		/// Registers the project folder `path` (holding BeefProj.toml) in the workspace. The call the folder
		/// dialog's answer goes to.
		public bool AddExistingProjectAt(StringView pathIn)
		{
			if (!CheckWritable())
				return false;
			String path = scope .(pathIn);
			while (path.Length > 3 && (path.EndsWith('\\') || path.EndsWith('/')))
				path.RemoveFromEnd(1);
			String ws = scope .();
			WorkspaceFileOrNew(ws);
			if (ws.IsEmpty)
			{
				ReportError("Open a folder first: the project is added to its BeefSpace.toml.");
				return false;
			}
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String name = scope .();
			if (WorkspaceFiles.AddExistingProject(ws, path, name, changes, err) case .Err)
			{
				ReportError(scope $"Could not add the project: {err}");
				return false;
			}
			LogWorkspaceChanges(changes);
			AfterWorkspaceEdit();
			let d = FindCBDir(path);
			if (d != null)
			{
				mCBFolder.Set(d.Path);
				mCBReveal = true;
			}
			SetStatus(scope $"Added project {name} to the workspace");
			return true;
		}

		/// Project names, folder names: why `newName` can't be the name of the project in `dir` (currently
		/// `oldName`), or true. The folder checks apply only with `renameFolder`.
		public bool ValidateProjectRename(StringView dir, StringView oldName, StringView newName, bool renameFolder, String outError)
		{
			if (!WorkspaceFiles.ValidProjectName(newName, outError))
				return false;
			if (mWorkspace != null)
				for (let p in mWorkspace.Projects)
					if (p.Name == newName && !(p.HasPath && ProjectIndex.SamePath(p.Dir, dir)))
					{
						outError.Set(scope $"The workspace already has a project named '{newName}'.");
						return false;
					}
			if (!renameFolder)
				return true;
			let wp = mWorkspace?.FindDir(dir);
			if (wp != null && wp.RelPath == ".")
			{
				outError.Set("This project is the workspace folder itself: its folder can't be renamed here.");
				return false;
			}
			if (!ValidateFileName(newName, outError))
				return false;
			String folder = scope .();
			Path.GetFileName(dir, folder);
			if (StringView.Compare(folder, newName, true) != 0)
			{
				String parent = scope .();
				WorkspaceFiles.ParentDir(dir, parent);
				if (EntryExists(parent, newName))
				{
					outError.Set(scope $"Something named '{newName}' already exists next to the project's folder.");
					return false;
				}
			}
			return true;
		}

		/// Project Properties > Name, and Rename Project...: the project in `dir` gets the name `newNameIn` in
		/// BeefProj.toml, BeefSpace.toml (entry, startup project, Locked / Unlocked) and the dependencies of
		/// the other projects; with `renameFolder` its folder is renamed too (the folder-rename path). Every
		/// file changed is one `Project:` line in the Output Log. False (with the reason in the status bar)
		/// when refused or when a file could not be written.
		public bool RenameProject(StringView dirIn, StringView newNameIn, bool renameFolder)
		{
			if (!CheckWritable())
				return false;
			String dir = scope .(dirIn);
			String newName = scope .(newNameIn);
			newName.Trim();
			let wp = mWorkspace?.FindDir(dir);
			String oldName = scope .();
			if (wp != null)
				oldName.Set(wp.Name);
			else
			{
				BeefProjectFile pf = scope .();
				if (!pf.Load(dir))
				{
					SetStatus(scope $"Can't rename the project: {dir} has no BeefProj.toml", .Warning);
					return false;
				}
				pf.GetName(oldName);
			}
			String folderName = scope .();
			Path.GetFileName(dir, folderName);
			bool folderMoves = renameFolder && folderName != newName;
			if (newName == oldName && !folderMoves)
				return true;
			String err = scope .();
			if (!ValidateProjectRename(dir, oldName, newName, renameFolder, err))
			{
				SetStatus(scope $"Can't rename project {oldName}: {err}", .Warning);
				return false;
			}
			String ws = scope .();
			WorkspaceFileOf(ws);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			if (WorkspaceFiles.RenameProject(ws, dir, oldName, newName, changes, err) case .Err)
			{
				ReportError(scope $"Could not rename project {oldName}: {err}");
				return false;
			}
			LogWorkspaceChanges(changes);
			AfterWorkspaceEdit();
			bool folderDone = false;
			if (folderMoves)
			{
				CBItem item = new .();
				item.Kind = .Folder;
				item.Name.Set(folderName);
				item.Path.Set(dir);
				CBItem.MakeKey(.Folder, dir, "", item.Key);
				String parent = scope .();
				WorkspaceFiles.ParentDir(dir, parent);
				String newDir = scope .();
				JoinPath(parent, newName, newDir);
				RenameAsset(item, newName);
				delete item;
				folderDone = Directory.Exists(newDir) && (!Directory.Exists(dir) || ProjectIndex.SamePath(dir, newDir));
				if (folderDone && mSelProjectActive && ProjectIndex.SamePath(mSelProjectDir, dir))
					mSelProjectDir.Set(newDir);
				if (!folderDone)
				{
					Notify.Log(.Warning, "Project", scope $"The project is renamed to {newName}, but its folder was not renamed");
					SetStatus(scope $"Renamed project {oldName} to {newName}; the folder was not renamed");
					mPSRenameFolder = false;
					return false;
				}
			}
			mPSRenameFolder = false;
			SetStatus(scope $"Renamed project {oldName} to {newName}{(folderDone ? " (and its folder)" : "")}");
			return true;
		}

		/// Rename Project... in a project row's menu: the rename dialog with the project's name.
		void StartRenameProject(CBDir d)
		{
			CBItem item = new .();
			item.Kind = .Folder;
			item.Name.Set(d.Name);
			item.Path.Set(d.Path);
			CBItem.MakeKey(.Folder, d.Path, "", item.Key);
			StartRename(item);
			delete item;
			mCBRenameProject = true;
			mCBRenameProjectOld.Set(d.ProjectName);
			mCBNameBuf.Set(d.ProjectName);
			mCBRenameProjectFolder = StringView.Compare(d.Name, d.ProjectName, true) == 0 && mWorkspace?.FindDir(d.Path)?.RelPath != ".";
		}

		// ------------------------------------------------------------------ New Project in This Workspace

		/// Where a new project of the workspace goes: beside the current project (in its folder's parent), or in
		/// the workspace folder when the current project is the workspace folder itself.
		void NewWorkspaceProjectLocation(String outDir)
		{
			outDir.Clear();
			let cur = CurrentProject();
			if (cur != null && cur.HasPath && cur.RelPath != ".")
			{
				WorkspaceFiles.ParentDir(cur.Dir, outDir);
				if (!outDir.IsEmpty && (ProjectIndex.SamePath(outDir, mProjectRoot) || IsUnder(outDir, mProjectRoot)))
					return;
			}
			if (mWorkspace != null && (ProjectIndex.SamePath(mWorkspace.Dir, mProjectRoot) || IsUnder(mWorkspace.Dir, mProjectRoot)))
				outDir.Set(mWorkspace.Dir);
			else
				outDir.Set(mProjectRoot);
		}

		public void StartNewWorkspaceProject(bool library = true)
		{
			if (mProjectRoot.IsEmpty)
			{
				StartNewProject();
				return;
			}
			NewWorkspaceProjectLocation(mWsNewLocation);
			mWsNewKind = library ? 1 : 0;
			mWsNewAddDep = library;
			String name = scope .(library ? "NewLibrary" : "NewProgram");
			for (int i = 2; i < 100 && EntryExists(mWsNewLocation, name); i++)
				name.Set(scope $"{(library ? "NewLibrary" : "NewProgram")}{i}");
			mWsNewName.Set(name);
			mOpenWsNew = true;
		}

		bool ValidateWorkspaceProject(StringView name, String outError)
		{
			if (!WorkspaceFiles.ValidProjectName(name, outError))
				return false;
			if (EntryExists(mWsNewLocation, name))
			{
				outError.Set(scope $"'{name}' already exists in that folder.");
				return false;
			}
			if (mWorkspace?.Find(name) != null)
			{
				outError.Set(scope $"The workspace already has a project named '{name}'.");
				return false;
			}
			return true;
		}

		/// Creates the project (BeefProj.toml and its first source file), registers it, and with `addDependency`
		/// makes the current project depend on it.
		public bool CreateWorkspaceProject(StringView nameIn, bool library, bool addDependency)
		{
			if (!CheckWritable())
				return false;
			String name = scope .(nameIn);
			name.Trim();
			String err = scope .();
			if (!ValidateWorkspaceProject(name, err))
			{
				ReportError(err);
				return false;
			}
			let cur = CurrentProject();
			String curName = scope .();
			String curDir = scope .();
			if (cur != null && cur.HasPath)
			{
				curName.Set(cur.Name);
				curDir.Set(cur.Dir);
			}
			String ws = scope .();
			WorkspaceFileOrNew(ws);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String mainFile = scope .();
			if (WorkspaceFiles.CreateProject(ws, mWsNewLocation, name, library, mainFile, changes, err) case .Err)
			{
				LogWorkspaceChanges(changes);
				ReportError(scope $"Could not create the project: {err}");
				return false;
			}
			if (addDependency && !curDir.IsEmpty && WorkspaceFiles.SetDependency(curDir, name, true, changes, err) case .Err)
				Notify.Log(.Warning, "Project", scope $"{curName} could not depend on {name}: {err}");
			LogWorkspaceChanges(changes);
			ScanProject();
			SaveSettings();
			String srcDir = scope .();
			WorkspaceFiles.ParentDir(mainFile, srcDir);
			if (FindCBDir(srcDir) != null)
			{
				mCBFolder.Set(FindCBDir(srcDir).Path);
				mCBReveal = true;
				CBSelectOnly("");
			}
			if (!library)
				OpenFunction(mainFile, "Program", "Main");
			SetStatus(scope $"Created {(library ? "library" : "program")} {name} in the workspace{(addDependency && !curName.IsEmpty ? scope $" ({curName} depends on it)" : "")}");
			return true;
		}

		void DrawWorkspacePopups()
		{
			if (mOpenWsNew)
			{
				Gui.OpenPopup("New Project in Workspace");
				mOpenWsNew = false;
			}
			mWsNewOpen = false;
			if (Gui.igBeginPopupModal("New Project in Workspace", null, WindowFlags.AlwaysAutoResize))
			{
				mWsNewOpen = true;
				if (Gui.IsKeyPressed(Key.Escape, false) || mSelfTestClosePopups)
				{
					mSelfTestClosePopups = false;
					Gui.igCloseCurrentPopup();
				}
				{
					let p = Gui.igGetCursorScreenPos();
					float s = Gui.igGetFrameHeight() * 1.6f;
					Gui.igDummy(.(s, s));
					let size = Gui.CalcTextSize(Icon.Package);
					float k = s / Math.Max(size.y, 1);
					Gui.DrawText(Gui.igGetWindowDrawList(), .(p.x + (s - size.x * k) / 2, p.y + (s - size.y * k) / 2), ProjectColor, Icon.Package, Gui.igGetFontSize() * k);
					Gui.SameLine();
					Gui.igBeginGroup();
					Gui.Text("New project in this workspace");
					String rel = scope .();
					RelativeToRoot(mWsNewLocation, rel);
					Gui.TextDisabled(scope $"in {(rel.IsEmpty ? "the workspace folder" : rel)}");
					Gui.igEndGroup();
				}
				Gui.igSpacing();
				Gui.Text("Name");
				if (Gui.igIsWindowAppearing() || mWsNewRefocus)
					Gui.igSetKeyboardFocusHere(0);
				mWsNewRefocus = false;
				Gui.igSetNextItemWidth(380 * Look.Scale);
				bool enter = Gui.igInputText("##wsname", mWsNewName.Ptr, (.)mWsNewName.Capacity, InputTextFlags.EnterReturnsTrue | InputTextFlags.AutoSelectAll, null, null);
				Gui.igSpacing();
				Gui.igAlignTextToFramePadding();
				Gui.Text("Kind");
				Gui.SameLine(90 * Look.Scale);
				if (Gui.igRadioButton_Bool("Library", mWsNewKind == 1))
					mWsNewKind = 1;
				Gui.SameLine();
				if (Gui.igRadioButton_Bool("Program", mWsNewKind == 0))
					mWsNewKind = 0;
				let cur = CurrentProject();
				if (cur != null && cur.HasPath)
					Gui.Checkbox(scope $"Add as a dependency of {cur.Name}", &mWsNewAddDep);
				String name = scope .(mWsNewName.View);
				name.Trim();
				String err = scope .();
				bool valid = ValidateWorkspaceProject(name, err);
				ErrorLine(err);
				if (valid)
					Gui.TextDisabled(scope $"Creates {name}/BeefProj.toml and {name}/src/{(mWsNewKind == 1 ? scope $"{name}.bf" : "Program.bf")}, listed in BeefSpace.toml");
				else
					Gui.TextDisabled(" ");
				Gui.igBeginDisabled(!valid);
				bool create = Gui.Button("Create", .(120 * Look.Scale, 0)) || (enter && valid);
				if (enter && !valid)
					mWsNewRefocus = true;
				Gui.igEndDisabled();
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)))
					Gui.igCloseCurrentPopup();
				if (create && valid)
				{
					Gui.igCloseCurrentPopup();
					CreateWorkspaceProject(name, mWsNewKind == 1, mWsNewAddDep && cur != null);
				}
				Gui.EndPopup();
			}

			if (mOpenWsExisting)
			{
				Gui.OpenPopup("Add Existing Project");
				mOpenWsExisting = false;
			}
			if (Gui.igBeginPopupModal("Add Existing Project", null, WindowFlags.AlwaysAutoResize))
			{
				mWsNewOpen = true;
				Gui.Text("The folder of a Beef project (it holds BeefProj.toml)");
				if (Gui.igIsWindowAppearing())
					Gui.igSetKeyboardFocusHere(0);
				Gui.igSetNextItemWidth(460 * Look.Scale);
				bool enter = Gui.igInputText("##wsexisting", mWsExistingPath.Ptr, (.)mWsExistingPath.Capacity, InputTextFlags.EnterReturnsTrue, null, null);
				String toml = scope .();
				WorkspaceFiles.Join(mWsExistingPath.View, BeefProjectFile.FileName, toml);
				bool valid = File.Exists(toml);
				ErrorLine(valid ? "" : "No BeefProj.toml in this folder.");
				Gui.igBeginDisabled(!valid);
				bool go = Gui.Button("Add", .(120 * Look.Scale, 0)) || (enter && valid);
				Gui.igEndDisabled();
				Gui.SameLine();
				if (Gui.Button("Cancel", .(120 * Look.Scale, 0)) || Gui.IsKeyPressed(Key.Escape, false))
					Gui.igCloseCurrentPopup();
				if (go && valid)
				{
					Gui.igCloseCurrentPopup();
					AddExistingProjectAt(scope String(mWsExistingPath.View));
				}
				Gui.EndPopup();
			}
		}

		// ------------------------------------------------------------------ folder moves and deletes

		/// After a folder was renamed or moved (`oldPath` -> `newPath`): BeefSpace.toml, the project files and
		/// `.vbproject` follow (WorkspaceFiles.FolderMoved). False (with the error shown) when they could not be
		/// written; the caller then moves the folder back.
		bool WorkspaceAfterFolderMove(StringView oldPath, StringView newPath)
		{
			String ws = scope .();
			WorkspaceFileOf(ws);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			if (WorkspaceFiles.FolderMoved(ws, oldPath, newPath, mProjectRoot, changes, err) case .Err)
			{
				ReportError(scope $"The folder was not renamed: the workspace files could not be updated ({err}).");
				return false;
			}
			LogWorkspaceChanges(changes);
			return true;
		}

		/// After a folder went to the Recycle Bin: its projects leave the workspace.
		void WorkspaceAfterFolderDelete(StringView path)
		{
			String ws = scope .();
			WorkspaceFileOf(ws);
			if (ws.IsEmpty)
				return;
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			if (WorkspaceFiles.FolderRemoved(ws, path, changes, err) case .Err)
				ReportError(scope $"The folder was deleted, but BeefSpace.toml could not be updated: {err}");
			LogWorkspaceChanges(changes);
		}

		/// A project's folder tile: the project glyph on the folder, and a green dot for the startup project.
		void DrawProjectTileMark(ImDrawList* dl, CBItem item, ImVec2 p0, float tile)
		{
			let d = ProjectDirOf(item.Path);
			if (d == null)
				return;
			float fs = tile * 0.34f;
			let size = Gui.CalcTextSize(Icon.Package);
			float k = fs / Math.Max(size.y, 1);
			ImVec2 c = .(p0.x + tile / 2, p0.y + tile * 0.58f);
			Gui.DrawText(dl, .(c.x - size.x * k / 2, c.y - size.y * k / 2), Gui.Color(30, 30, 30), Icon.Package, Gui.igGetFontSize() * k);
			if (d.Startup)
				Gui.ImDrawList_AddCircleFilled(dl, .(p0.x + tile * 0.8f, p0.y + tile * 0.32f), tile * 0.07f, StartupColor, 0);
		}

		/// The rename dialog of a folder: what happens to the projects in it.
		void DrawRenameProjectNote(StringView path)
		{
			List<String> projects = scope .();
			defer { ClearAndDeleteItems!(projects); }
			ProjectsUnder(path, projects);
			String folderName = scope .();
			Path.GetFileName(path, folderName);
			for (let p in projects)
			{
				if (@p.Index >= 3)
					break;
				let wp = mWorkspace?.Find(p);
				bool self = wp != null && ProjectIndex.SamePath(wp.Dir, path);
				if (self && StringView.Compare(p, folderName, true) == 0)
					Gui.TextColored(ProjectColor, scope $"{Icon.Package}  Project {p} is renamed with its folder: BeefSpace.toml, BeefProj.toml and the projects that use it follow.");
				else
					Gui.TextColored(ProjectColor, scope $"{Icon.Package}  Project {p}: its path in BeefSpace.toml follows the folder.");
			}
		}

		/// The delete dialog of a folder: the projects that leave the workspace with it.
		void DrawDeleteProjectNote(StringView path)
		{
			List<String> projects = scope .();
			defer { ClearAndDeleteItems!(projects); }
			ProjectsUnder(path, projects);
			if (projects.IsEmpty)
				return;
			String names = scope .();
			for (let p in projects)
				names.AppendF("{}{}", names.IsEmpty ? "" : ", ", p);
			Gui.TextColored(Theme.Warning, scope $"      {Icon.Package}  {names} leave{(projects.Count == 1) ? "s" : ""} the workspace (BeefSpace.toml); dependencies on {(projects.Count == 1) ? "it" : "them"} are removed.");
		}

		/// Workspace projects in (or at) `path`, for the rename and delete dialogs.
		void ProjectsUnder(StringView path, List<String> outNames)
		{
			if (mWorkspace == null)
				return;
			for (let p in mWorkspace.Projects)
				if (p.HasPath && p.RelPath != "." && (ProjectIndex.SamePath(p.Dir, path) || WorkspaceFiles.IsUnder(p.Dir, path)))
					outNames.Add(new String(p.Name));
		}
	}
}
