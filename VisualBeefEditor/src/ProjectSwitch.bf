using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Opening, switching and closing the project: the one path every way of opening a project takes (the start page,
	/// File > Open Project Folder, File > Open Recent, File > New Project, a dropped folder). Opening a project closes
	/// the previous one first, after asking about unsaved changes, so the Project Browser, the Outline, the Sheets, the
	/// window title and the recent list all follow the new project. Also keeps the recent projects list in the
	/// preferences (`preferences.recentProjects` in settings.json).
	extension EditorApp
	{
		RecentProjects mRecent = new .() ~ delete _;
		bool mRecentLoaded;

		/// A switch waiting for the answer to "unsaved changes" (an empty root = close the project).
		String mSwitchRoot = new .() ~ delete _;
		String mSwitchFile = new .() ~ delete _;
		bool mSwitchOpenGraph = true;
		String mNPLocationScratch = new .() ~ delete _;

		const String cRecentKey = "recentProjects";
		const String cNewProjectLocationKey = "newProjectLocation";

		/// True while no project is open: the start page shows.
		public bool StartPageVisible => mProjectRoot.IsEmpty;

		public RecentProjects Recent
		{
			get
			{
				LoadRecentProjects();
				return mRecent;
			}
		}

		static int64 UnixNow()
		{
			// Ticks are 100 ns since 0001-01-01; 621355968000000000 is 1970-01-01.
			return (DateTime.UtcNow.Ticks - 621355968000000000L) / 10000000L;
		}

		// ------------------------------------------------------------------ the recent list

		void LoadRecentProjects()
		{
			if (mRecentLoaded)
				return;
			mRecentLoaded = true;
			Settings.Load();
			let list = Settings.Preferences.Get(cRecentKey);
			if (list == null || list.Type != .Array)
				return;
			String dataRoot = scope .();
			AppPaths.Root(dataRoot);
			for (let item in list.Items)
			{
				if (item.Type != .Object)
					continue;
				String path = scope .();
				RecentProjects.FromStored(item.GetString("path"), dataRoot, path);
				mRecent.AddStored(path, (int64)item.GetNumber("opened", 0));
			}
		}

		void SaveRecentProjects()
		{
			Settings.Load();
			String dataRoot = scope .();
			AppPaths.Root(dataRoot);
			let list = Settings.Preferences.Set(cRecentKey, Json.NewArray());
			for (let r in mRecent.Items)
			{
				let item = Json.NewObject();
				String stored = scope .();
				RecentProjects.ToStored(r.Path, dataRoot, stored);
				item.Set("path", Json.NewString(stored));
				item.Set("name", Json.NewString(r.Name));
				item.Set("opened", Json.NewNumber((double)r.Opened));
				list.Items.Add(item);
			}
			Settings.Save();
		}

		/// The folder was opened (or just made): it goes to the top of the recent list.
		void RememberProject(StringView root)
		{
			LoadRecentProjects();
			mRecent.Touch(root, UnixNow());
			SaveRecentProjects();
		}

		void ForgetRecentProject(StringView path)
		{
			LoadRecentProjects();
			if (mRecent.Remove(path))
				SaveRecentProjects();
		}

		/// Where the New Project dialog starts: the folder the last new project was made in, else the folder that holds
		/// the open project, else Documents.
		StringView NewProjectLocation()
		{
			mNPLocationScratch.Clear();
			Settings.Load();
			let saved = Settings.Preferences.GetString(cNewProjectLocationKey);
			if (!saved.IsEmpty && Directory.Exists(saved))
			{
				mNPLocationScratch.Set(saved);
				return mNPLocationScratch;
			}
			if (!mProjectRoot.IsEmpty)
			{
				String parent = scope .();
				if (Path.GetDirectoryPath(mProjectRoot, parent) case .Ok && !parent.IsEmpty && Directory.Exists(parent))
				{
					mNPLocationScratch.Set(parent);
					return mNPLocationScratch;
				}
			}
			String home = scope .();
#if BF_PLATFORM_WINDOWS
			Environment.GetEnvironmentVariable("USERPROFILE", home).IgnoreError(); // unset: stays empty, the field is left blank
#else
			Environment.GetEnvironmentVariable("HOME", home).IgnoreError(); // unset: stays empty, the field is left blank
#endif
			if (!home.IsEmpty)
			{
				String docs = scope .(home);
				docs.AppendF("{}Documents", Path.DirectorySeparatorChar);
				mNPLocationScratch.Set(Directory.Exists(docs) ? docs : home);
			}
			return mNPLocationScratch;
		}

		void SaveNewProjectLocation(StringView location)
		{
			Settings.Load();
			Settings.Preferences.Set(cNewProjectLocationKey, Json.NewString(location));
			Settings.Save();
		}

		// ------------------------------------------------------------------ opening and closing

		/// Opens `rootIn` as the project and closes the open one. With unsaved changes a question comes first (the switch
		/// finishes when it is answered). `file` is focused in the new project (its graph opens too when `openFirstGraph`).
		/// False when the folder is not there.
		public bool RequestOpenProject(StringView rootIn, StringView file = "", bool openFirstGraph = true)
		{
			String root = scope .(rootIn);
			root.Trim();
			TrimSeparators(root);
			if (root.IsEmpty || !Directory.Exists(root))
			{
				SetStatus(scope $"Can't open {root}: that folder doesn't exist");
				return false;
			}
			if (ModifiedCount > 0)
			{
				mSwitchRoot.Set(root);
				mSwitchFile.Set(file);
				mSwitchOpenGraph = openFirstGraph;
				mShowSwitchModal = true;
				return true;
			}
			OpenProjectNow(root, file, openFirstGraph);
			return true;
		}

		/// File > Close Project: back to the start page (after the unsaved-changes question).
		public void RequestCloseProject()
		{
			if (mProjectRoot.IsEmpty)
				return;
			if (ModifiedCount > 0)
			{
				mSwitchRoot.Clear();
				mSwitchFile.Clear();
				mShowSwitchModal = true;
				return;
			}
			OpenProjectNow("", "", true);
		}

		/// Drops everything that belongs to the open project: documents, Sheets, asset tabs, compile and find results,
		/// the debug session, the Project Browser's folder and selection.
		void CloseProjectContents()
		{
			if (IsDebugging)
				StopDebugging();
			delete mBuild; // a compile still running is stopped
			mBuild = null;
			mConflicts.Clear();
			ClearAndDeleteItems!(mFindHits);
			mFindFiles = 0;
			mRefsTitle.Clear();
			while (mAssetTabs.Count > 0)
				RemoveAssetTab(mAssetTabs.Count - 1);
			while (mDocs.Count > 0)
				CloseDoc(mDocs.Back);
			Doc = mEmptyDoc;
			ActiveTab = -1;
			mLastActiveTab = null;
			mSelectTab = null;
			mActionTab = null;
			mSourceDoc = null;
			mSourceVersion = -1;
			mSourceDirty = false;
			mRenameTarget = null;
			ClearAndDeleteItems!(mCBSelected);
			mCBAnchor.Clear();
			mCBScrollTo.Clear();
			mCBFolder.Clear();
			mCBSearch.Set("");
		}

		/// The switch itself: close the open project, make `root` the project (an empty `root` closes it), focus `file`.
		void OpenProjectNow(StringView rootIn, StringView fileIn, bool openFirstGraph)
		{
			String root = scope .(rootIn);
			String file = scope .(fileIn);
			CloseProjectContents();
			mProjectRoot.Set(root);
			ScanProject();
			if (root.IsEmpty)
			{
				SaveSettings();
				UpdateTitle();
				SetStatus("Closed the project");
				return;
			}
			RememberProject(root);
			if (!file.IsEmpty && File.Exists(file))
			{
				OpenFile(file, openFirstGraph);
				String dir = scope .();
				Path.GetDirectoryPath(file, dir).IgnoreError(); // a file always has a folder part
				if (FindCBDir(dir) != null)
				{
					mCBFolder.Set(FindCBDir(dir).Path);
					mCBReveal = true;
				}
			}
			SaveSettings();
			UpdateTitle();
			Notify.Log(.Info, "Editor", scope $"Opened project {root}");
			SetStatus(scope $"Opened project {root}");
		}

		/// File > Open Recent.
		void DrawOpenRecentMenu()
		{
			LoadRecentProjects();
			if (!Gui.BeginMenu(scope $"{Icon.History}  Open Recent", !mRecent.Items.IsEmpty))
				return;
			String pick = null;
			for (let r in mRecent.Items)
			{
				bool exists = Directory.Exists(r.Path);
				String label = scope $"{r.Name}{(exists ? "" : "  (missing)")}###recent{@r.Index}";
				if (Gui.MenuItem(label, "", false, exists))
					pick = scope:: String(r.Path);
				if (exists && Gui.igIsItemHovered(0))
					Gui.Tooltip(r.Path);
			}
			Gui.Separator();
			if (Gui.MenuItem("Clear List"))
			{
				ClearAndDeleteItems!(mRecent.Items);
				SaveRecentProjects();
			}
			Gui.EndMenu();
			if (pick != null)
			{
				FileSafety.ReadOnlyProject = false;
				RequestOpenProject(pick);
			}
		}

		/// The answer to the unsaved-changes question: with `save` everything is written first (a conflict keeps the
		/// project open), then the waiting switch runs. False when nothing was switched.
		bool FinishSwitch(bool save)
		{
			if (save && !SaveAll())
				return false;
			String root = scope .(mSwitchRoot);
			String file = scope .(mSwitchFile);
			mSwitchRoot.Clear();
			mSwitchFile.Clear();
			OpenProjectNow(root, file, mSwitchOpenGraph);
			return true;
		}

		/// "Open project X?" with unsaved changes: Save All, Don't Save or Cancel.
		void DrawSwitchModal()
		{
			if (mShowSwitchModal)
			{
				Gui.OpenPopup("Unsaved Changes##switch");
				mShowSwitchModal = false;
			}
			if (!Gui.igBeginPopupModal("Unsaved Changes##switch", null, WindowFlags.AlwaysAutoResize))
				return;
			if (Gui.IsKeyPressed(Key.Escape, false) || mSpSwitchClose)
			{
				mSpSwitchClose = false;
				mSwitchRoot.Clear();
				mSwitchFile.Clear();
				Gui.igCloseCurrentPopup();
			}
			if (Gui.igIsWindowAppearing())
				Gui.igSetKeyboardFocusHere(0);
			bool closing = mSwitchRoot.IsEmpty;
			if (closing)
				Gui.Text("Closing the project discards these unsaved changes:");
			else
			{
				String name = scope .();
				RecentProjects.NameOf(mSwitchRoot, name);
				Gui.Text(scope $"Opening {name} closes the current project. These files have unsaved changes:");
			}
			for (let d in mDocs)
			{
				if (!d.Modified)
					continue;
				String name = scope .();
				Path.GetFileName(d.FilePath, name);
				Gui.TextColored(Theme.Warning, scope $"   {name}");
			}
			Gui.igSpacing();
			if (Gui.Button("Save All", .(110 * Look.Scale, 0)))
			{
				Gui.igCloseCurrentPopup();
				FinishSwitch(true);
			}
			Gui.SameLine();
			if (Gui.Button("Don't Save", .(110 * Look.Scale, 0)))
			{
				Gui.igCloseCurrentPopup();
				FinishSwitch(false);
			}
			Gui.SameLine();
			if (Gui.Button("Cancel", .(110 * Look.Scale, 0)))
			{
				mSwitchRoot.Clear();
				mSwitchFile.Clear();
				Gui.igCloseCurrentPopup();
			}
			Gui.EndPopup();
		}
	}
}
