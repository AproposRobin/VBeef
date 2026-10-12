using System;
using System.IO;
using System.Collections;
using System.Diagnostics;
using VisualBeef.Catalog;
using VisualBeef.Document;

namespace VisualBeef.Tests
{
	/// `VisualBeefTests workspace [-build]`: the workspace and project files behind the Project Browser's project
	/// entries and Project Settings (WorkspaceFiles.bf): TomlText reads and edits BeefSpace.toml / BeefProj.toml in
	/// both forms the Beef IDE writes (`Projects = {...}` and `[Projects]`) and keeps comments, unknown keys and line
	/// endings; projects added (new, existing, from File > New Project), the startup project, build kinds,
	/// dependencies, per-configuration values, a project folder renamed (paths, name, dependents, `.vbproject`) and
	/// deleted. With `-build` BeefBuild compiles the edited scratch workspace.
	static class WorkspaceTests
	{
		static int sChecks;
		static int sFailures;

		static void Check(bool cond, StringView what)
		{
			sChecks++;
			if (cond)
				Console.WriteLine("  ok   {}", what);
			else
			{
				Console.WriteLine("  FAIL {}", what);
				sFailures++;
			}
		}

		static void Scratch(StringView name, String outDir)
		{
			String tmp = scope .();
			Path.GetTempPath(tmp).IgnoreError();
			outDir.AppendF("{}VisualBeefWorkspaceTests{}{}", tmp, Path.DirectorySeparatorChar, name);
#if BF_PLATFORM_WINDOWS
			outDir.Replace('/', '\\');
#endif
			if (Directory.Exists(outDir))
				Directory.DelTree(outDir).IgnoreError();
			Directory.CreateDirectory(outDir).IgnoreError();
		}

		static void Put(StringView dir, StringView rel, StringView text)
		{
			String path = scope .();
			WorkspaceFiles.Join(dir, rel, path);
#if BF_PLATFORM_WINDOWS
			path.Replace('/', '\\');
#endif
			String parent = scope .();
			Path.GetDirectoryPath(path, parent).IgnoreError();
			Directory.CreateDirectory(parent).IgnoreError();
			File.WriteAllText(path, text).IgnoreError();
		}

		static String Read(StringView dir, StringView rel, String outText)
		{
			String path = scope .();
			WorkspaceFiles.Join(dir, rel, path);
#if BF_PLATFORM_WINDOWS
			path.Replace('/', '\\');
#endif
			outText.Clear();
			File.ReadAllText(path, outText, true).IgnoreError();
			return outText;
		}

		static void PathOf(StringView dir, StringView rel, String outPath)
		{
			WorkspaceFiles.Join(dir, rel, outPath);
#if BF_PLATFORM_WINDOWS
			outPath.Replace('/', '\\');
#endif
		}

		static int Count(StringView text, StringView what)
		{
			int n = 0;
			int i = 0;
			while (true)
			{
				i = text.IndexOf(what, i);
				if (i < 0)
					return n;
				n++;
				i += what.Length;
			}
		}

		static void Changes(List<String> changes)
		{
			for (let c in changes)
				Console.WriteLine("       {}", c);
		}

		// ------------------------------------------------------------------ TomlText

		static void TomlTests()
		{
			Console.WriteLine("toml text");
			{
				TomlText t = scope .();
				t.Set("FileVersion = 1\r\n# my projects\r\n\r\n[Workspace]\r\nStartupProject = \"App\" # the program\r\n\r\n[Projects]\r\nApp = {Path = \"App\"}\r\n\"My.Lib\" = {Path = \"libs/My.Lib\"}\r\n");
				String s = scope .();
				Check(t.GetString("Workspace", "StartupProject", s) && s == "App", "a string value with a comment after it reads 'App'");
				Check(t.FormOf("Projects") == .Table, "[Projects] is read as a table");
				List<(String key, String raw)> e = scope .();
				defer { for (let x in e) { delete x.key; delete x.raw; } }
				t.MapEntries("Projects", e);
				Check(e.Count == 2 && e[1].key == "My.Lib" && e[1].raw == "{Path = \"libs/My.Lib\"}", "a quoted key and an inline table value");
				t.SetString("Workspace", "StartupProject", "Tool");
				Check(t.Text.Contains("StartupProject = \"Tool\" # the program\r\n") && t.Text.Contains("# my projects\r\n"), "a value replaced in place keeps its comment and the other comments");
				t.MapSet("Projects", "Tool", "{Path = \"Tool\"}");
				Check(t.Text.EndsWith("\"My.Lib\" = {Path = \"libs/My.Lib\"}\r\nTool = {Path = \"Tool\"}\r\n"), "a key added to a table goes after its last key, with the file's CRLF");
				Check(!t.Text.Contains("\n") || Count(t.Text, "\n") == Count(t.Text, "\r\n"), "no bare LF was written into a CRLF file");
				t.MapRemove("Projects", "My.Lib");
				Check(!t.Text.Contains("My.Lib") && t.Text.Contains("App = {Path = \"App\"}\r\nTool"), "a quoted key removed with its line");
				t.MapRenameKey("Projects", "Tool", "Tool2");
				Check(t.Text.Contains("Tool2 = {Path = \"Tool\"}"), "a key renamed keeps its value");
			}
			{
				TomlText t = scope .();
				t.Set("FileVersion = 1\nDependencies = {corlib = \"*\", Core = \"*\"}\n\n[Project]\nName = \"Tester\"\n");
				Check(t.FormOf("Dependencies") == .Inline, "Dependencies = {...} is read as an inline table");
				t.MapSet("Dependencies", "Lib-2", "\"*\"");
				Check(t.Text.Contains("Dependencies = {corlib = \"*\", Core = \"*\", Lib-2 = \"*\"}\n"), "an inline entry added after the last one");
				t.MapRemove("Dependencies", "Core");
				Check(t.Text.Contains("Dependencies = {corlib = \"*\", Lib-2 = \"*\"}\n"), "an inline entry in the middle removed with its comma");
				t.MapRemove("Dependencies", "Lib-2");
				Check(t.Text.Contains("Dependencies = {corlib = \"*\"}\n"), "the last inline entry removed with the comma before it");
				t.MapRemove("Dependencies", "corlib");
				Check(t.Text.Contains("Dependencies = {}\n"), "the only inline entry removed leaves {}");
				t.MapSet("Dependencies", "corlib", "\"*\"");
				Check(t.Text.Contains("Dependencies = {corlib = \"*\"}\n"), "an entry added to an empty inline table");
				t.MapSet("Other", "x", "\"1\"");
				Check(t.Text.Contains("Other = {x = \"1\"}\n[Project]") || t.Text.Contains("Other = {x = \"1\"}\n\n[Project]"), "a missing map is added as a root inline table before the first table");
			}
			{
				TomlText t = scope .();
				t.Set("FileVersion = 1\n\n[Project]\nName = \"A\"\n\n[Configs.Debug.Win64]\nPostBuildCmds = [\n\t\"CopyFilesIfNewer(\\\"$(ProjectDir)/assets\\\", \\\"$(TargetDir)\\\")\", # assets\n\t\"echo done\"\n]\nTargetName = \"A\"\n");
				List<String> cmds = scope .();
				defer { ClearAndDeleteItems!(cmds); }
				Check(t.GetStringArray("Configs.Debug.Win64", "PostBuildCmds", cmds) && cmds.Count == 2 && cmds[0] == "CopyFilesIfNewer(\"$(ProjectDir)/assets\", \"$(TargetDir)\")",
					"a multi-line array with escapes and a comment reads two commands");
				String tn = scope .();
				Check(t.GetString("Configs.Debug.Win64", "TargetName", tn) && tn == "A", "the key after a multi-line value is found");
				cmds.Add(new String("echo \"quoted\" C:\\path"));
				t.SetStringArray("Configs.Debug.Win64", "PostBuildCmds", cmds);
				List<String> back = scope .();
				defer { ClearAndDeleteItems!(back); }
				t.GetStringArray("Configs.Debug.Win64", "PostBuildCmds", back);
				Check(back.Count == 3 && back[2] == "echo \"quoted\" C:\\path" && t.Text.Contains("TargetName = \"A\"\n"), "a list written on one line reads back the same, the next key kept");
				t.Remove("Configs.Debug.Win64", "PostBuildCmds");
				t.Remove("Configs.Debug.Win64", "TargetName");
				Check(t.RemoveTableIfEmpty("Configs.Debug.Win64") && t.Text == "FileVersion = 1\n\n[Project]\nName = \"A\"\n", "an emptied configuration table is removed with the blank line before it");
				t.SetString("Configs.Release.Win64", "BuildKind", "DynamicLib");
				Check(t.Text == "FileVersion = 1\n\n[Project]\nName = \"A\"\n\n[Configs.Release.Win64]\nBuildKind = \"DynamicLib\"\n", "a missing table is added at the end after a blank line");
			}
			{
				// What the rest of the editor reads (LibraryIndex, DebugTarget) agrees with an edited file.
				TomlText t = scope .();
				t.Set("FileVersion = 1\n\n[Workspace]\nStartupProject = \"App\"\n\n[Projects]\nApp = {Path = \"App\"}\n");
				t.MapSet("Projects", "Lib", "{Path = \"../Shared/Lib\"}");
				MiniToml m = scope .();
				m.Parse(t.Text);
				Check(m.Get("Projects.Lib.Path") == "../Shared/Lib" && m.Get("Workspace.StartupProject") == "App", "MiniToml (library discovery, debugger) reads the edited workspace");
			}
		}

		// ------------------------------------------------------------------ paths

		static void PathTests()
		{
			Console.WriteLine("paths");
			String r = scope .();
#if BF_PLATFORM_WINDOWS
			WorkspaceFiles.RelativePath(@"D:\Work\Space", @"D:\Work\Space\Core", r);
			Check(r == "Core", "a project inside the workspace folder: 'Core'");
			r.Clear();
			WorkspaceFiles.RelativePath(@"D:\Work\Space", @"D:\Work\Space", r);
			Check(r == ".", "the workspace folder itself: '.'");
			r.Clear();
			WorkspaceFiles.RelativePath(@"D:\Work\Space", @"d:\work\Shared\Lib", r);
			Check(r == "../Shared/Lib", "a project beside the workspace: '../Shared/Lib' (case does not matter)");
			r.Clear();
			WorkspaceFiles.RelativePath(@"D:\Work\Space", @"E:\Lib", r);
			Check(r == "E:/Lib", "another drive: the absolute path with /");
			String a = scope .();
			WorkspaceFiles.Resolve(@"D:\Work\Space", "../Shared/./Lib/", a);
			Check(a == @"D:\Work\Shared\Lib", scope $"'../Shared/./Lib/' resolves to {a}");
			a.Clear();
			WorkspaceFiles.Resolve(@"D:\Work\Space", ".", a);
			Check(a == @"D:\Work\Space", "'.' resolves to the workspace folder");
#else
			WorkspaceFiles.RelativePath("/home/u/Space", "/home/u/Shared/Lib", r);
			Check(r == "../Shared/Lib", "a project beside the workspace: '../Shared/Lib'");
			String a = scope .();
			WorkspaceFiles.Resolve("/home/u/Space", "../Shared/Lib", a);
			Check(a == "/home/u/Shared/Lib", scope $"'../Shared/Lib' resolves to {a}");
#endif
			String err = scope .();
			Check(WorkspaceFiles.ValidProjectName("WebUI-Beef", err) && WorkspaceFiles.ValidProjectName("My.Lib", err) && !WorkspaceFiles.ValidProjectName("2Fast", err) && !WorkspaceFiles.ValidProjectName("a b", err),
				"project names: WebUI-Beef and My.Lib yes, 2Fast and 'a b' no");
		}

		// ------------------------------------------------------------------ workspace edits

		static void WorkspaceEditTests()
		{
			Console.WriteLine("workspace");
			String root = scope .();
			Scratch("ws", root);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String text = scope .();

			// A workspace as the Beef IDE writes it ([Projects] table), with a comment and an unknown key.
			Put(root, "BeefSpace.toml", "FileVersion = 1\n# kept\nExtraPlatforms = [\"wasm32\"]\n\n[Workspace]\nStartupProject = \"App\"\n\n[Projects]\nApp = {Path = \"App\"}\nSDL2 = \"*\"\n");
			Put(root, "App/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = \"App\"\nStartupObject = \"App.Program\"\n");
			Put(root, "App/src/Program.bf", "namespace App { class Program { public static int Main() => 0; } }\n");
			String ws = scope .();
			PathOf(root, "BeefSpace.toml", ws);
			BeefWorkspace w = scope .();
			Check(w.Load(ws) && w.Projects.Count == 2 && w.Startup == "App" && w.Find("App").HasPath && !w.Find("SDL2").HasPath, "the workspace lists App (a path) and SDL2 (a version) and App is the startup project");
			String appDir = scope .();
			PathOf(root, "App", appDir);
			Check(w.ProjectOf(scope $"{appDir}{Path.DirectorySeparatorChar}src") == w.Find("App") && w.FindDir(appDir) == w.Find("App"), "a folder inside App belongs to App");

			// File > New Project into this workspace: the [Projects] table gets the entry, no second Projects key.
			String mainFile = scope .();
			Check(WorkspaceFiles.CreateProject(ws, root, "Core", true, mainFile, changes, err) case .Ok, scope $"New project Core (a library) created and registered {err}");
			Read(root, "BeefSpace.toml", text);
			Check(Count(text, "Projects") == 1 && text.Contains("SDL2 = \"*\"\nCore = {Path = \"Core\"}\n") && text.Contains("# kept\nExtraPlatforms = [\"wasm32\"]\n"),
				"Core is added to [Projects] (no duplicate Projects key), the comment and the unknown key kept");
			Check(File.Exists(mainFile) && mainFile.EndsWith("Core.bf") && Read(root, "Core/BeefProj.toml", scope String()).Contains("TargetType = \"BeefLib\""), "the library has src/Core.bf and TargetType BeefLib");
			Check(WorkspaceFiles.CreateProject(ws, root, "Core", false, scope String(), changes, err) case .Err, "a second project named Core is refused");
			err.Clear();

			// An existing project beside the workspace folder.
			String outside = scope .();
			Scratch("outside", outside);
			Put(outside, "Shared/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = \"SharedKit\"\nTargetType = \"BeefLib\"\n");
			String sharedDir = scope .();
			PathOf(outside, "Shared", sharedDir);
			String name = scope .();
			Check(WorkspaceFiles.AddExistingProject(ws, sharedDir, name, changes, err) case .Ok, scope $"Add existing project: {err}");
			Read(root, "BeefSpace.toml", text);
			Check(name == "SharedKit" && text.Contains("SharedKit = {Path = \"../outside/Shared\"}"), scope $"it is registered by its [Project] Name with a relative path ('{name}')");
			Check(WorkspaceFiles.AddExistingProject(ws, sharedDir, name, changes, err) case .Err && err.Contains("already"), "adding it twice is refused");
			err.Clear();
			Check(WorkspaceFiles.AddExistingProject(ws, outside, name, changes, err) case .Err && err.Contains("BeefProj.toml"), "a folder without BeefProj.toml is refused");
			err.Clear();

			// The startup project.
			Check(WorkspaceFiles.SetStartup(ws, "Core", changes, err) case .Ok, "Set as startup project");
			Read(root, "BeefSpace.toml", text);
			Check(text.Contains("[Workspace]\nStartupProject = \"Core\"\n"), "StartupProject = \"Core\"");
			WorkspaceFiles.SetStartup(ws, "App", changes, err).IgnoreError();

			// A workspace with the inline form (the form VisualBeef wrote before) and a new workspace file.
			String root2 = scope .();
			Scratch("ws2", root2);
			Put(root2, "BeefSpace.toml", "FileVersion = 1\nProjects = {A = {Path = \"A\"}}\n\n[Workspace]\nStartupProject = \"A\"\n");
			String ws2 = scope .();
			PathOf(root2, "BeefSpace.toml", ws2);
			Check(WorkspaceFiles.CreateProject(ws2, root2, "B", false, scope String(), changes, err) case .Ok, "New project B in an inline-form workspace");
			Read(root2, "BeefSpace.toml", text);
			Check(text == "FileVersion = 1\nProjects = {A = {Path = \"A\"}, B = {Path = \"B\"}}\n\n[Workspace]\nStartupProject = \"A\"\n", "B is added to the inline Projects table, the startup project kept");
			String root3 = scope .();
			Scratch("ws3", root3);
			String ws3 = scope .();
			PathOf(root3, "BeefSpace.toml", ws3);
			Check(WorkspaceFiles.CreateProject(ws3, root3, "Solo", false, scope String(), changes, err) case .Ok, "New project with no workspace yet");
			Read(root3, "BeefSpace.toml", text);
			Check(text.Contains("Projects = {Solo = {Path = \"Solo\"}}") && text.Contains("StartupProject = \"Solo\""), "BeefSpace.toml is created with the project as startup project");

			// Read-only: nothing is written.
			FileSafety.ReadOnlyProject = true;
			Check(WorkspaceFiles.SetStartup(ws, "Core", changes, err) case .Err && err.Contains("Read-only"), "read-only mode refuses an edit");
			FileSafety.ReadOnlyProject = false;
			err.Clear();
			Read(root, "BeefSpace.toml", text);
			Check(text.Contains("StartupProject = \"App\""), "and the file is unchanged");
			Changes(changes);
		}

		// ------------------------------------------------------------------ project settings

		static void SettingsTests()
		{
			Console.WriteLine("project settings");
			String root = scope .();
			Scratch("settings", root);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String text = scope .();
			Put(root, "Mod/BeefProj.toml", "FileVersion = 1\n# deps\n[Dependencies]\ncorlib = \"*\"\n\n[Project]\nName = \"Mod\"\nStartupObject = \"Mod.Program\"\nCustomKey = 3\n\n[Configs.Release.Linux64]\nOtherLinkFlags = \"-x\"\n");
			String dir = scope .();
			PathOf(root, "Mod", dir);
			BeefProjectFile pf = scope .();
			Check(pf.Load(dir) && pf.Kind == .Console, "no TargetType reads as a console application");

			Check(WorkspaceFiles.SetBuildKind(dir, .DynamicLibrary, changes, err) case .Ok, "build kind: Dynamic library");
			Read(root, "Mod/BeefProj.toml", text);
			Check(text.Contains("[Project]\nName = \"Mod\"\nStartupObject = \"Mod.Program\"\nCustomKey = 3\nTargetType = \"BeefLib\"\n"), "TargetType BeefLib added after the project's keys, the unknown key kept");
			Check(text.Contains("[Configs.Release.Linux64]\nOtherLinkFlags = \"-x\"\nBuildKind = \"DynamicLib\"\n") && text.Contains("[Configs.Debug.Win64]\nBuildKind = \"DynamicLib\"\n") &&
				text.Contains("[Configs.Release.Win64]\nBuildKind = \"DynamicLib\"\n"), "BuildKind DynamicLib in every configuration (Debug and Release Win64 added)");
			pf.Load(dir);
			Check(pf.Kind == .DynamicLibrary, "it reads back as a dynamic library");
			Check(WorkspaceFiles.SetBuildKind(dir, .Console, changes, err) case .Ok, "build kind: Console application");
			Read(root, "Mod/BeefProj.toml", text);
			Check(!text.Contains("BuildKind") && !text.Contains("Configs.Debug.Win64") && text.Contains("[Configs.Release.Linux64]\nOtherLinkFlags = \"-x\"\n") && text.Contains("TargetType = \"BeefConsoleApplication\""),
				"back to a console application: BuildKind removed, the emptied tables gone, the other configuration kept");
			pf.Load(dir);
			Check(pf.Kind == .Console, "it reads back as a console application");
			WorkspaceFiles.SetBuildKind(dir, .Library, changes, err).IgnoreError();
			pf.Load(dir);
			Check(pf.Kind == .Library, "Library: TargetType BeefLib, no BuildKind");
			WorkspaceFiles.SetBuildKind(dir, .Windows, changes, err).IgnoreError();
			pf.Load(dir);
			Check(pf.Kind == .Windows, "Windows application: BeefGUIApplication");

			Check(WorkspaceFiles.SetDependency(dir, "Core", true, changes, err) case .Ok, "dependency Core on");
			Read(root, "Mod/BeefProj.toml", text);
			Check(text.Contains("# deps\n[Dependencies]\ncorlib = \"*\"\nCore = \"*\"\n"), "added as a line of [Dependencies], the comment kept");
			String before = scope .(text);
			WorkspaceFiles.SetDependency(dir, "Core", true, changes, err).IgnoreError();
			Check(Read(root, "Mod/BeefProj.toml", text) == before, "turning it on again writes nothing");
			Check(WorkspaceFiles.SetDependency(dir, "Core", false, changes, err) case .Ok && !Read(root, "Mod/BeefProj.toml", text).Contains("Core"), "dependency Core off");

			List<String> cmds = scope .();
			defer { ClearAndDeleteItems!(cmds); }
			cmds.Add(new String("CopyToDependents(\"$(ProjectDir)/x.dll\")"));
			Check(WorkspaceFiles.SetList(dir, "Configs.Debug.Win64", "PostBuildCmds", cmds, changes, err) case .Ok, "a post-build command for Debug | Win64");
			pf.Load(dir);
			List<String> back = scope .();
			defer { ClearAndDeleteItems!(back); }
			Check(pf.Toml.GetStringArray("Configs.Debug.Win64", "PostBuildCmds", back) && back.Count == 1 && back[0] == cmds[0], "it reads back with its quotes");
			Check(WorkspaceFiles.SetValue(dir, "Configs.Debug.Win64", "DebugCommand", "$(TargetDir)/Game.exe", changes, err) case .Ok &&
				Read(root, "Mod/BeefProj.toml", text).Contains("DebugCommand = \"$(TargetDir)/Game.exe\""), "a debug command for Debug | Win64");
			ClearAndDeleteItems!(cmds);
			WorkspaceFiles.SetList(dir, "Configs.Debug.Win64", "PostBuildCmds", cmds, changes, err).IgnoreError();
			WorkspaceFiles.SetValue(dir, "Configs.Debug.Win64", "DebugCommand", "", changes, err).IgnoreError();
			Check(!Read(root, "Mod/BeefProj.toml", text).Contains("Configs.Debug.Win64"), "both cleared: the configuration table is gone");
			Check(WorkspaceFiles.SetValue(dir, "Project", "StartupObject", "Mod.Main", changes, err) case .Ok && Read(root, "Mod/BeefProj.toml", text).Contains("StartupObject = \"Mod.Main\""), "startup object changed in place");
			Changes(changes);
		}

		// ------------------------------------------------------------------ folder rename / delete

		static void FolderTests()
		{
			Console.WriteLine("project folders");
			String root = scope .();
			Scratch("folders", root);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String text = scope .();
			Put(root, "BeefSpace.toml", "FileVersion = 1\nProjects = {Core = {Path = \"Core\"}, Tester = {Path = \"Tester\"}, Deep = {Path = \"libs/Deep\"}, Odd = {Path = \"OddFolder\"}}\nLocked = [\"Core\"]\n\n[Workspace]\nStartupProject = \"Core\"\n");
			Put(root, "Core/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = \"Core\"\nTargetType = \"BeefLib\"\n");
			Put(root, "Tester/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\", Core = \"*\"}\n\n[Project]\nName = \"Tester\"\n");
			Put(root, "libs/Deep/BeefProj.toml", "FileVersion = 1\n[Dependencies]\nCore = \"*\"\n\n[Project]\nName = \"Deep\"\n");
			Put(root, "OddFolder/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"Odd\"\n");
			Put(root, ".vbproject", "{\n  \"vbproject\": 1,\n  \"main\": \"Core/src/Main.bf\",\n  \"hostId\": \"keep-me\",\n  \"libraries\": [\"Core/lib\", \"D:/abs\"]\n}\n");
			String ws = scope .();
			PathOf(root, "BeefSpace.toml", ws);
			String oldDir = scope .();
			String newDir = scope .();
			PathOf(root, "Core", oldDir);
			PathOf(root, "Engine", newDir);
			Directory.Move(oldDir, newDir).IgnoreError();
			Check(WorkspaceFiles.FolderMoved(ws, oldDir, newDir, root, changes, err) case .Ok, scope $"the Core folder renamed to Engine {err}");
			Read(root, "BeefSpace.toml", text);
			Check(text.Contains("Engine = {Path = \"Engine\"}") && !text.Contains("Core"), "the workspace entry is Engine with Path Engine");
			Check(text.Contains("StartupProject = \"Engine\"") && text.Contains("Locked = [\"Engine\"]"), "the startup project and the Locked list follow");
			Check(Read(root, "Engine/BeefProj.toml", text).Contains("Name = \"Engine\""), "BeefProj.toml Name = Engine");
			Check(Read(root, "Tester/BeefProj.toml", text).Contains("Dependencies = {corlib = \"*\", Engine = \"*\"}"), "Tester's dependency follows (inline form)");
			Check(Read(root, "libs/Deep/BeefProj.toml", text).Contains("[Dependencies]\nEngine = \"*\"\n"), "Deep's dependency follows (table form)");
			Read(root, ".vbproject", text);
			Check(text.Contains("\"main\": \"Engine/src/Main.bf\"") && text.Contains("\"Engine/lib\"") && text.Contains("\"D:/abs\"") && text.Contains("\"hostId\": \"keep-me\""),
				".vbproject main and the relative library follow; the absolute one and the host's own key are kept");
			MiniToml m = scope .();
			m.Parse(Read(root, "BeefSpace.toml", scope String()));
			Check(m.Get("Projects.Engine.Path") == "Engine", "library discovery reads Projects.Engine.Path");

			// A folder holding a project (libs) renamed: only the path changes.
			ClearAndDeleteItems!(changes);
			oldDir.Clear();
			newDir.Clear();
			PathOf(root, "libs", oldDir);
			PathOf(root, "third", newDir);
			Directory.Move(oldDir, newDir).IgnoreError();
			Check(WorkspaceFiles.FolderMoved(ws, oldDir, newDir, root, changes, err) case .Ok && Read(root, "BeefSpace.toml", text).Contains("Deep = {Path = \"third/Deep\"}") &&
				Read(root, "third/Deep/BeefProj.toml", scope String()).Contains("Name = \"Deep\""), "a folder around a project renamed: Deep's path follows, its name stays");

			// A project not named like its folder keeps its name.
			oldDir.Clear();
			newDir.Clear();
			PathOf(root, "OddFolder", oldDir);
			PathOf(root, "Renamed", newDir);
			Directory.Move(oldDir, newDir).IgnoreError();
			Check(WorkspaceFiles.FolderMoved(ws, oldDir, newDir, root, changes, err) case .Ok && Read(root, "BeefSpace.toml", text).Contains("Odd = {Path = \"Renamed\"}") &&
				Read(root, "Renamed/BeefProj.toml", scope String()).Contains("Name = \"Odd\""), "a project named unlike its folder: path follows, name kept");

			// A rename to a name another project has: the folder moves, the name stays.
			oldDir.Clear();
			newDir.Clear();
			PathOf(root, "Tester", oldDir);
			PathOf(root, "Odd", newDir);
			Directory.Move(oldDir, newDir).IgnoreError();
			Check(WorkspaceFiles.FolderMoved(ws, oldDir, newDir, root, changes, err) case .Ok && Read(root, "BeefSpace.toml", text).Contains("Tester = {Path = \"Odd\"}") &&
				Read(root, "Odd/BeefProj.toml", scope String()).Contains("Name = \"Tester\""), "renamed to a name the workspace has: path follows, name kept");
			Changes(changes);

			// The Engine folder deleted: the project leaves the workspace and the dependencies on it go.
			ClearAndDeleteItems!(changes);
			String engine = scope .();
			PathOf(root, "Engine", engine);
			Check(WorkspaceFiles.FolderRemoved(ws, engine, changes, err) case .Ok, "the Engine folder deleted");
			Read(root, "BeefSpace.toml", text);
			Check(!text.Contains("Engine = {") && text.Contains("StartupProject = \"Tester\""), "Engine left the workspace; the startup project moved to Tester");
			Check(Read(root, "Odd/BeefProj.toml", text).Contains("Dependencies = {corlib = \"*\"}"), "Tester's dependency on Engine removed");
			Changes(changes);
		}

		// ------------------------------------------------------------------ project rename

		static void RenameTests()
		{
			Console.WriteLine("project rename");
			String root = scope .();
			Scratch("rename", root);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String text = scope .();
			Put(root, "BeefSpace.toml", "FileVersion = 1\nProjects = {Core = {Path = \"Core\"}, Tester = {Path = \"Tester\"}, Deep = {Path = \"libs/Deep\"}, Other = {Path = \"Other\"}}\nLocked = [\"Core\", \"Other\"]\nUnlocked = [\"Core\"]\n\n[Workspace]\nStartupProject = \"Core\"\n");
			Put(root, "Core/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\"}\n\n[Project]\nName = \"Core\"\nTargetType = \"BeefLib\"\n");
			Put(root, "Tester/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\", Core = \"*\"}\n\n[Project]\nName = \"Tester\"\n");
			Put(root, "libs/Deep/BeefProj.toml", "FileVersion = 1\n[Dependencies]\nCore = \"*\"\n\n[Project]\nName = \"Deep\"\n");
			Put(root, "Other/BeefProj.toml", "FileVersion = 1\n\n[Project]\nName = \"Other\"\n");
			Put(root, ".vbproject", "{\n  \"vbproject\": 1,\n  \"main\": \"Core/src/Main.bf\",\n  \"libraries\": [\"Core/lib\"]\n}\n");
			String ws = scope .();
			PathOf(root, "BeefSpace.toml", ws);
			String coreDir = scope .();
			PathOf(root, "Core", coreDir);

			// A name the workspace has, an empty one and a bad shape are refused, nothing is written.
			Check(WorkspaceFiles.RenameProject(ws, coreDir, "Core", "Tester", changes, err) case .Err && err.Contains("already has a project"), scope $"a name another project has is refused ({err})");
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws, coreDir, "Core", "", changes, err) case .Err && !err.IsEmpty, scope $"an empty name is refused ({err})");
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws, coreDir, "Core", "9Lives", changes, err) case .Err, "a name starting with a digit is refused");
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws, coreDir, "Core", "Has Space", changes, err) case .Err, "a name with a space is refused");
			Check(changes.IsEmpty && Read(root, "BeefSpace.toml", text).Contains("Core = {Path = \"Core\"}") && Read(root, "Core/BeefProj.toml", scope String()).Contains("Name = \"Core\""), "the refusals wrote nothing");

			// Core -> Engine (the startup project, in both lists, depended on by Tester inline and Deep as a table).
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws, coreDir, "Core", "Engine", changes, err) case .Ok, scope $"Core renamed to Engine ({err})");
			Read(root, "BeefSpace.toml", text);
			Check(text.Contains("Engine = {Path = \"Core\"}") && !text.Contains("Core = {"), "the workspace entry is Engine and still points at the Core folder");
			Check(text.Contains("StartupProject = \"Engine\""), "the startup project follows");
			Check(text.Contains("Locked = [\"Engine\", \"Other\"]") && text.Contains("Unlocked = [\"Engine\"]"), "the Locked and Unlocked lists follow");
			Check(Read(root, "Core/BeefProj.toml", text).Contains("Name = \"Engine\""), "Name in BeefProj.toml is Engine");
			Check(Read(root, "Tester/BeefProj.toml", text).Contains("Dependencies = {corlib = \"*\", Engine = \"*\"}"), "Tester's dependency follows (inline form)");
			Check(Read(root, "libs/Deep/BeefProj.toml", text).Contains("[Dependencies]\nEngine = \"*\"\n"), "Deep's dependency follows (table form)");
			Check(Read(root, ".vbproject", text).Contains("\"main\": \"Core/src/Main.bf\""), ".vbproject keeps its paths (the folder did not move)");
			int lines = 0;
			for (let c in changes)
				if (c.Contains("BeefSpace.toml") || c.Contains("BeefProj.toml"))
					lines++;
			Check(changes.Count >= 5 && lines == changes.Count, scope $"one log line per change, all in project files ({changes.Count})");
			Changes(changes);
			Check(File.Exists(scope $"{coreDir}{Path.DirectorySeparatorChar}BeefProj.toml.bak") && File.Exists(scope $"{root}{Path.DirectorySeparatorChar}BeefSpace.toml.bak"), "a .bak of each edited project file is kept");
			BeefWorkspace model = scope .();
			Check(model.Load(ws) && model.Find("Engine") != null && model.Find("Core") == null && model.Startup == "Engine", "the workspace reads back with Engine as the startup project");

			// With the folder renamed too, the way the UI does it: the path follows and the name stays Engine.
			ClearAndDeleteItems!(changes);
			String engineDir = scope .();
			PathOf(root, "Engine", engineDir);
			Directory.Move(coreDir, engineDir).IgnoreError();
			err.Clear();
			Check(WorkspaceFiles.FolderMoved(ws, coreDir, engineDir, root, changes, err) case .Ok, scope $"the folder renamed to Engine ({err})");
			Read(root, "BeefSpace.toml", text);
			Check(text.Contains("Engine = {Path = \"Engine\"}") && Read(root, "Engine/BeefProj.toml", scope String()).Contains("Name = \"Engine\""), "folder renamed after the project: path Engine, name Engine, no second rename");
			Check(Read(root, ".vbproject", text).Contains("\"main\": \"Engine/src/Main.bf\"") && text.Contains("\"Engine/lib\""), ".vbproject follows the folder");
			Check(Read(root, "Tester/BeefProj.toml", text).Contains("Engine = \"*\"") && !text.Contains("Core"), "the dependency is not renamed twice");

			// A name that needs quoting in the workspace (the folder stays: folder rename off).
			ClearAndDeleteItems!(changes);
			String testerDir = scope .();
			PathOf(root, "Tester", testerDir);
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws, testerDir, "Tester", "My.Tester", changes, err) case .Ok && Read(root, "BeefSpace.toml", text).Contains("\"My.Tester\" = {Path = \"Tester\"}"), scope $"a name with a dot is written as a quoted key ({err})");
			Check(Read(root, "Tester/BeefProj.toml", text).Contains("Name = \"My.Tester\"") && Directory.Exists(testerDir), "its BeefProj.toml Name is My.Tester and its folder is still Tester");
			Check(model.Load(ws) && model.Find("My.Tester") != null && model.Find("Tester") == null, "the workspace reads the quoted name back");

			// Table-form [Projects] and a project whose BeefProj.toml has no Name.
			String root2 = scope .();
			Scratch("rename2", root2);
			Put(root2, "BeefSpace.toml", "FileVersion = 1\n\n[Projects]\nApp = {Path = \"App\"}\nLib = {Path = \"Lib\"}\n\n[Workspace]\nStartupProject = \"App\"\n");
			Put(root2, "App/BeefProj.toml", "FileVersion = 1\nDependencies = {corlib = \"*\", Lib = \"*\"}\n");
			Put(root2, "Lib/BeefProj.toml", "FileVersion = 1\n\n[Project]\nTargetType = \"BeefLib\"\n");
			String ws2 = scope .();
			PathOf(root2, "BeefSpace.toml", ws2);
			String libDir = scope .();
			PathOf(root2, "Lib", libDir);
			ClearAndDeleteItems!(changes);
			err.Clear();
			Check(WorkspaceFiles.RenameProject(ws2, libDir, "Lib", "Toolkit", changes, err) case .Ok, scope $"table-form workspace: Lib renamed ({err})");
			Read(root2, "BeefSpace.toml", text);
			Check(text.Contains("Toolkit = {Path = \"Lib\"}") && text.Contains("StartupProject = \"App\""), "table-form entry renamed, startup project untouched");
			Check(Read(root2, "App/BeefProj.toml", text).Contains("Toolkit = \"*\"") && Read(root2, "Lib/BeefProj.toml", text).Contains("Name = \"Toolkit\""), "App depends on Toolkit; Lib's file gained Name = Toolkit");

			// The same name again does nothing; read-only mode writes nothing.
			ClearAndDeleteItems!(changes);
			Check(WorkspaceFiles.RenameProject(ws2, libDir, "Toolkit", "Toolkit", changes, err) case .Ok && changes.IsEmpty, "renaming to the same name changes nothing");
			FileSafety.ReadOnlyProject = true;
			String beforeText = scope .();
			Read(root2, "BeefSpace.toml", beforeText);
			Check(WorkspaceFiles.RenameProject(ws2, libDir, "Toolkit", "Again", changes, err) case .Err && Read(root2, "BeefSpace.toml", text) == beforeText, "read-only mode: refused, nothing written");
			FileSafety.ReadOnlyProject = false;
		}

		// ------------------------------------------------------------------ BeefBuild

		static int RunProcess(StringView exe, StringView args, StringView workDir, String outText)
		{
			ProcessStartInfo psi = scope .();
			psi.SetFileName(exe);
			psi.SetArguments(args);
			psi.SetWorkingDirectory(workDir);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = true;
			psi.CreateNoWindow = true;
			SpawnedProcess process = scope .();
			if (process.Start(psi) case .Err)
				return -1;
			FileStream stream = scope .();
			if (process.AttachStandardOutput(stream) case .Ok)
			{
				StreamReader reader = scope .(stream, null, false, 4096);
				reader.ReadToEnd(outText).IgnoreError();
			}
			process.WaitFor();
			return process.ExitCode;
		}

		/// Two projects made, one renamed through its folder, a dependency added: BeefBuild builds the result.
		static void BuildTests()
		{
			Console.WriteLine("BeefBuild on the edited workspace");
			String root = scope .();
			Scratch("build", root);
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			String ws = scope .();
			PathOf(root, "BeefSpace.toml", ws);
			WorkspaceFiles.CreateProject(ws, root, "App", false, scope String(), changes, err).IgnoreError();
			WorkspaceFiles.CreateProject(ws, root, "Kit", true, scope String(), changes, err).IgnoreError();
			String appDir = scope .();
			PathOf(root, "App", appDir);
			WorkspaceFiles.SetDependency(appDir, "Kit", true, changes, err).IgnoreError();
			String oldDir = scope .();
			String newDir = scope .();
			PathOf(root, "Kit", oldDir);
			PathOf(root, "Tools", newDir);
			Directory.Move(oldDir, newDir).IgnoreError();
			WorkspaceFiles.FolderMoved(ws, oldDir, newDir, root, changes, err).IgnoreError();
			Put(root, "Tools/src/Kit.bf", "using System;\nnamespace Kit\n{\n\tpublic static class Kit\n\t{\n\t\tpublic static int Answer() => 42;\n\t}\n}\n");
			Put(root, "App/src/Program.bf", "using System;\nnamespace App\n{\n\tclass Program\n\t{\n\t\tpublic static int Main(String[] args)\n\t\t{\n\t\t\tConsole.WriteLine(\"answer {}\", Kit.Kit.Answer());\n\t\t\treturn 0;\n\t\t}\n\t}\n}\n");
			Changes(changes);
#if BF_PLATFORM_WINDOWS
			String beefBuild = scope .(@"C:\Program Files\BeefLang\bin\BeefBuild.exe");
			String platform = scope .("Win64");
#else
			String beefBuild = scope .("BeefBuild");
			Environment.GetEnvironmentVariable("VB_BEEFBUILD", beefBuild).IgnoreError();
			String platform = scope .("Linux64");
#endif
			String output = scope .();
			int code = RunProcess(beefBuild, scope $"\"-workspace={root}\" -config=Debug -platform={platform}", root, output);
			if (code != 0)
				Console.WriteLine(output);
			Check(code == 0, scope $"BeefBuild builds App with its dependency Tools (renamed from Kit): exit {code}");
			String exe = scope .();
			PathOf(root, scope $"build/Debug_{platform}/App/App", exe);
#if BF_PLATFORM_WINDOWS
			exe.Append(".exe");
#endif
			String run = scope .();
			int runCode = RunProcess(exe, "", root, run);
			Check(runCode == 0 && run.Contains("answer 42"), scope $"the program runs: '{run..Trim()}'");
		}

		public static int Run(String[] args)
		{
			sChecks = 0;
			sFailures = 0;
			TomlTests();
			PathTests();
			WorkspaceEditTests();
			SettingsTests();
			FolderTests();
			RenameTests();
			for (let a in args)
				if (a == "-build")
					BuildTests();
			Console.WriteLine("workspace checks: {}  failures: {}", sChecks, sFailures);
			return (sFailures == 0) ? 0 : 1;
		}
	}
}
