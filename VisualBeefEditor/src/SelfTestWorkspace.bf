using System;
using System.Collections;
using System.IO;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// `VB_SELFTEST=workspace`: the Project Browser's projects and Project Settings through the calls the UI makes,
	/// on a scratch workspace the caller writes (docs/Testing.md): `BeefSpace.toml` in the Beef IDE's form
	/// (`[Projects]`) with `Core` (a library: `src/Greeter.bf`, static `Hello()`) and `Tester` (the startup program:
	/// `src/Program.bf` calls `Core.Greeter.Hello()`, depends on Core, and has an `assets` folder), and a project
	/// folder `../Outside/Ext` beside the workspace. Checks the project rows (startup mark, src beneath, no
	/// "Core/src" chain), the menus and Project Settings (captures), build kind / list / dependency / startup edits
	/// written to the files, New Project in This Workspace (a library the current project depends on), Add Existing
	/// Project (relative path, the row outside the folder), the Core folder renamed to Engine (BeefSpace.toml,
	/// BeefProj.toml, the dependency, the open document, no error), the delete dialog's note, Remove from Workspace,
	/// and a compile of the edited workspace.
	extension EditorApp
	{
		int mWsStep;
		int mWsWait;
		String mWsShot = new .() ~ delete _;
		int mWsErrors;
		/// The context menus close on the next frame (captures of one menu after another).
		bool mSelfTestCloseMenus;

		void WsPath(StringView rel, String outPath)
		{
			WorkspaceFiles.Join(mProjectRoot, rel, outPath);
			outPath.Replace('/', Path.DirectorySeparatorChar);
		}

		String WsRead(StringView rel, String outText)
		{
			String p = scope .();
			WsPath(rel, p);
			outText.Clear();
			File.ReadAllText(p, outText, true).IgnoreError();
			return outText;
		}

		void WsNote(StringView text) => Notify.Log(.Info, "SelfTest", scope $"[WORKSPACE] {text}");

		void WsShotNext(StringView name, int wait = 4)
		{
			mWsShot.Set(name);
			mWsWait = wait;
		}

		CBItem WsFolderItem(StringView path)
		{
			CBItem item = new .();
			item.Kind = .Folder;
			Path.GetFileName(path, item.Name);
			item.Path.Set(path);
			CBItem.MakeKey(.Folder, path, "", item.Key);
			return item;
		}

		bool SelfTestWorkspace()
		{
			mSelfTestCloseMenus = false;
			if (mWsWait > 0)
			{
				mWsWait--;
				return false;
			}
			if (!mWsShot.IsEmpty)
			{
				if (!SelfTestShot(mWsShot))
					return false;
				mWsShot.Clear();
			}
			String core = scope .();
			String tester = scope .();
			WsPath("Core", core);
			WsPath("Tester", tester);
			String text = scope .();
			let step = mWsStep++;
			switch (step)
			{
			case 0:
				mWsErrors = mErrors.Count;
				SelfTestCheck(mWorkspace != null && mWorkspace.Projects.Count == 2, scope $"workspace 1: BeefSpace.toml read with {mWorkspace?.Projects.Count ?? 0} projects");
				let coreDir = FindCBDir(core);
				let testerDir = FindCBDir(tester);
				SelfTestCheck(coreDir?.ProjectName == "Core" && testerDir?.ProjectName == "Tester", "workspace 1: Core and Tester are project rows");
				SelfTestCheck(testerDir != null && testerDir.Startup && coreDir != null && !coreDir.Startup, "workspace 1: Tester is marked as the startup project");
				bool coreSrc = false;
				if (coreDir != null)
					for (let sub in coreDir.Dirs)
						if (sub.Name == "src")
							coreSrc = true;
				SelfTestCheck(coreSrc && coreDir.Files.IsEmpty && coreDir.Dirs.Count == 1, "workspace 1: Core's src folder is a row beneath the project (no 'Core/src' chain)");
				SelfTestCheck(mCBTree != null && mCBTree.ProjectName == null, "workspace 1: the workspace is the root row");
				String greeter = scope .();
				WsPath("Core/src/Greeter.bf", greeter);
				OpenFile(greeter, false);
				// The current project is the open document's: Tester's Program.bf.
				String program = scope .();
				WsPath("Tester/src/Program.bf", program);
				OpenFile(program, false);
				SelfTestCheck(CurrentProject()?.Name == "Tester", "workspace 1: the current project is the open document's (Tester)");
				mCBFolder.Set(mProjectRoot);
				mCBReveal = true;
				SelfTestPanel("browser");
				WsShotNext("ws-tree");
			case 1:
				mSelfTestTreeMenu.Set(core);
				WsShotNext("ws-project-menu");
			case 2:
				mSelfTestCloseMenus = true;
				mWsWait = 2;
			case 3:
				String src = scope .();
				WsPath("Tester/src", src);
				mSelfTestTreeMenu.Set(src);
				WsShotNext("ws-folder-menu");
			case 4:
				mSelfTestCloseMenus = true;
				mWsWait = 2;
			case 5:
				OpenProjectSettings(core);
				SelfTestCheck(mSelProjectActive && mPS != null && mPS.Kind == .Library, "workspace 2: Project Settings of Core: a library");
				SelfTestPanel("properties");
				WsShotNext("ws-settings");
			case 6:
				SelfTestCheck(SetProjectBuildKind(.DynamicLibrary), "workspace 3: build kind Dynamic library");
				WsRead("Core/BeefProj.toml", text);
				SelfTestCheck(text.Contains("[Configs.Debug.Win64]\nBuildKind = \"DynamicLib\"") && text.Contains("[Configs.Release.Win64]\nBuildKind = \"DynamicLib\"") && text.Contains("# the core library"),
					"workspace 3: BuildKind DynamicLib written for Debug and Release, the comment kept");
				WsShotNext("ws-settings-dll");
			case 7:
				SelfTestCheck(SetProjectBuildKind(.Library) && !WsRead("Core/BeefProj.toml", text).Contains("BuildKind"), "workspace 3: back to Library: BuildKind removed");
				SelfTestCheck(SetProjectList("Configs.Debug.Win64", "PostBuildCmds", "echo built\necho \"twice\"", '\n') &&
					WsRead("Core/BeefProj.toml", text).Contains("PostBuildCmds = [\"echo built\", \"echo \\\"twice\\\"\"]"), "workspace 4: two post-build commands written as a list");
				SelfTestCheck(SetProjectList("Configs.Debug.Win64", "PostBuildCmds", "", '\n') && !WsRead("Core/BeefProj.toml", text).Contains("Configs.Debug.Win64"), "workspace 4: cleared again, the table gone");
				SelfTestCheck(SetProjectValue("Project", "DefaultNamespace", "Core") && WsRead("Core/BeefProj.toml", text).Contains("DefaultNamespace = \"Core\""), "workspace 4: default namespace written");
				SetProjectValue("Project", "DefaultNamespace", "");
			case 8:
				SelfTestCheck(SetProjectDependency(tester, "Tester", "Core", false) && !WsRead("Tester/BeefProj.toml", text).Contains("Core"), "workspace 5: Tester no longer depends on Core");
				SelfTestCheck(SetProjectDependency(tester, "Tester", "Core", true) && WsRead("Tester/BeefProj.toml", text).Contains("Core = \"*\""), "workspace 5: Add as Dependency of Tester writes Core = \"*\"");
				SelfTestCheck(SetStartupProject("Core") && WsRead("BeefSpace.toml", text).Contains("StartupProject = \"Core\""), "workspace 6: Set as Startup Project: Core");
				FlushWorkspaceRescan();
				SelfTestCheck(FindCBDir(core)?.Startup == true && FindCBDir(tester)?.Startup == false, "workspace 6: the tree marks Core as the startup project");
				SetStartupProject("Tester");
				FlushWorkspaceRescan();
			case 9:
				SelfTestPanel("browser");
				mCBFolder.Set(tester);
				mSelfTestAddMenu = true;
				WsShotNext("ws-add-menu");
			case 10:
				mSelfTestCloseMenus = true;
				mWsWait = 2;
			case 11:
				StartNewWorkspaceProject(true);
				mWsNewName.Set("Kit");
				String loc = scope .();
				NewWorkspaceProjectLocation(loc);
				SelfTestCheck(ProjectIndex.SamePath(loc, mProjectRoot), scope $"workspace 7: a new project goes beside the current one ({loc})");
				WsShotNext("ws-newproject");
			case 12:
				mSelfTestClosePopups = true;
				let cur = CurrentProject();
				StringView curName = (cur != null) ? cur.Name : "none";
				SelfTestCheck(cur != null && cur.Name == "Tester", scope $"workspace 7: the current project is the open document's ({curName})");
				SelfTestCheck(CreateWorkspaceProject("Kit", true, true), "workspace 7: New Project in This Workspace: library Kit");
				WsRead("BeefSpace.toml", text);
				SelfTestCheck(text.Contains("Kit = {Path = \"Kit\"}") && text.Contains("# the workspace") && text.IndexOf("Projects") == text.IndexOf("[Projects]") + 1 && text.IndexOf("Projects", text.IndexOf("[Projects]") + 2) < 0,
					"workspace 7: Kit listed in [Projects], the comment kept, one Projects table");
				SelfTestCheck(WsRead("Kit/BeefProj.toml", text).Contains("TargetType = \"BeefLib\"") && WsRead("Tester/BeefProj.toml", text).Contains("Kit = \"*\""), "workspace 7: Kit is a library and Tester depends on it");
				String kit = scope .();
				WsPath("Kit", kit);
				SelfTestCheck(FindCBDir(kit)?.ProjectName == "Kit", "workspace 7: Kit is a project row");
			case 13:
				String ext = scope .();
				WorkspaceFiles.ParentDir(mProjectRoot, ext);
				ext.AppendF("{0}Outside{0}Ext", Path.DirectorySeparatorChar);
				SelfTestCheck(AddExistingProjectAt(ext), "workspace 8: Add Existing Project ../Outside/Ext (the folder dialog's answer)");
				FlushWorkspaceRescan();
				SelfTestCheck(WsRead("BeefSpace.toml", text).Contains("Ext = {Path = \"../Outside/Ext\"}"), "workspace 8: registered by a path relative to the workspace");
				SelfTestCheck(mCBOutsideProjects.Count == 1 && mCBOutsideProjects[0].ProjectName == "Ext", "workspace 8: listed as a project row outside the folder");
				SelfTestCheck(!AddExistingProjectAt(ext) && mErrors.Count == mWsErrors + 1, "workspace 8: adding it again is refused with a message");
				if (mErrors.Count > mWsErrors)
				{
					WsNote(scope $"refusal: {mErrors.Back}");
					delete mErrors.PopBack();
				}
				mCBFolder.Set(mProjectRoot);
				mCBReveal = true;
				WsShotNext("ws-outside");
			case 14:
				let item = WsFolderItem(core);
				StartRename(item);
				delete item;
				mCBNameBuf.Set("Engine");
				WsShotNext("ws-rename-dialog");
			case 15:
				DeleteAndNullify!(mCBRenameItem);
				let item = WsFolderItem(core);
				defer delete item;
				RenameAsset(item, "Engine");
				String engine = scope .();
				WsPath("Engine", engine);
				SelfTestCheck(mErrors.Count == mWsErrors && Directory.Exists(engine) && !Directory.Exists(core), "workspace 9: the Core folder renamed to Engine with no error");
				WsRead("BeefSpace.toml", text);
				SelfTestCheck(text.Contains("Engine = {Path = \"Engine\"}") && !text.Contains("Core"), "workspace 9: BeefSpace.toml lists Engine at Engine");
				SelfTestCheck(WsRead("Engine/BeefProj.toml", text).Contains("Name = \"Engine\"") && WsRead("Tester/BeefProj.toml", text).Contains("Engine = \"*\"") && !text.Contains("Core"),
					"workspace 9: BeefProj.toml Name and Tester's dependency follow");
				String greeter = scope .();
				WsPath("Engine/src/Greeter.bf", greeter);
				SelfTestCheck(FindDoc(greeter) != null, "workspace 9: the open document follows the folder");
				SelfTestCheck(FindCBDir(engine)?.ProjectName == "Engine", "workspace 9: the tree shows the project Engine");
				OpenProjectSettings(engine);
				mCBFolder.Set(engine);
				mCBReveal = true;
				WsShotNext("ws-renamed");
			case 16:
				String kit = scope .();
				WsPath("Kit", kit);
				ClearAndDeleteItems!(mCBDeleteItems);
				mCBDeleteItems.Add(WsFolderItem(kit));
				mOpenCBDelete = true;
				WsShotNext("ws-delete-dialog");
			case 17:
				ClearAndDeleteItems!(mCBDeleteItems); // Cancel: nothing deleted
				String kit = scope .();
				WsPath("Kit", kit);
				SelfTestCheck(Directory.Exists(kit), "workspace 10: the delete dialog asked and nothing was deleted");
				SelfTestCheck(RemoveProjectFromWorkspace("Ext") && !WsRead("BeefSpace.toml", text).Contains("Ext"), "workspace 10: Remove from Workspace: Ext");
				FlushWorkspaceRescan();
				SelfTestCheck(mCBOutsideProjects.IsEmpty, "workspace 10: its row is gone, its folder kept");
				// The edited workspace builds: Tester -> Engine -> Kit.
				SaveAll();
				Compile();
			case 18:
				if (mBuild != null && mBuild.Running)
				{
					mWsStep--;
					return false;
				}
				mWsWait = 5;
			case 19:
				let st = GetCompileState();
				SelfTestCheck(st == .Good || st == .Warnings, scope $"workspace 11: the edited workspace compiles ({st})");
				SelfTestCheck(mErrors.Count == mWsErrors, scope $"workspace 11: no error dialogs ({mErrors.Count - mWsErrors})");
				WsNote(scope $"BeefSpace.toml at the end:\n{WsRead("BeefSpace.toml", text)}");
				return true;
			}
			return false;
		}
	}
}
