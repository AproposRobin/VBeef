using System;
using System.Collections;
using System.IO;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Project Settings in the Properties panel (a project's right-click > Project Settings): what the project
	/// builds, its startup object and namespace, the startup project, its dependencies (corlib and the
	/// workspace's projects as checkboxes) and the values BeefProj.toml keeps per configuration (pre- and
	/// post-build commands, target, debug command, macros, link flags). Every edit is one write of
	/// BeefProj.toml or BeefSpace.toml (WorkspaceFiles: atomic, the other lines kept) and is logged.
	extension EditorApp
	{
		bool mSelProjectActive;
		bool mPSReloadPending;
		String mSelProjectDir = new .() ~ delete _;
		BeefProjectFile mPS ~ delete _;
		DateTime mPSTime;
		String mPSName = new .() ~ delete _;
		String mPSConfig = new .("Debug.Win64") ~ delete _;
		String mPSStartupObject = new .() ~ delete _;
		String mPSNamespace = new .() ~ delete _;
		String mPSPre = new .() ~ delete _;
		String mPSPost = new .() ~ delete _;
		String mPSTargetDir = new .() ~ delete _;
		String mPSTargetName = new .() ~ delete _;
		String mPSDebugCmd = new .() ~ delete _;
		String mPSDebugArgs = new .() ~ delete _;
		String mPSDebugDir = new .() ~ delete _;
		String mPSMacros = new .() ~ delete _;
		String mPSLinkFlags = new .() ~ delete _;

		static StringView[?] sPSKinds = .("Console application", "Windows application", "Library", "Dynamic library");
		static StringView[?] sPSDefaultConfigs = .("Debug.Win64", "Release.Win64", "Paranoid.Win64", "Test.Win64");
		/// Per-configuration keys the panel edits (the others are listed as they are).
		static StringView[?] sPSConfigKeys = .("PreBuildCmds", "PostBuildCmds", "TargetDirectory", "TargetName", "DebugCommand", "DebugCommandArguments", "DebugWorkingDirectory",
			"PreprocessorMacros", "OtherLinkFlags", "BuildKind");

		/// Shows the project in `dir` in Properties.
		public void OpenProjectSettings(StringView dir)
		{
			mSelProjectDir.Set(dir);
			mSelProjectActive = true;
			mSelClassActive = false;
			mSelVarActive = false;
			mSelLocalActive = false;
			mSelVarSigPending = true;
			ReloadProjectSettings();
			Panels.Focus(Panels.PropertiesId);
		}

		static DateTime WriteTimeOf(StringView path)
		{
			if (File.GetLastWriteTime(path) case .Ok(let t))
				return t;
			return default;
		}

		void ReloadProjectSettings()
		{
			DeleteAndNullify!(mPS);
			mPS = new .();
			if (!mPS.Load(mSelProjectDir))
			{
				DeleteAndNullify!(mPS);
				return;
			}
			mPSTime = WriteTimeOf(mPS.FilePath);
			mPS.GetName(mPSName);
			mPS.Toml.GetString("Project", "StartupObject", mPSStartupObject);
			mPS.Toml.GetString("Project", "DefaultNamespace", mPSNamespace);
			LoadConfigFields();
		}

		static void JoinLines(List<String> items, StringView sep, String outText)
		{
			outText.Clear();
			for (let s in items)
			{
				if (@s.Index > 0)
					outText.Append(sep);
				outText.Append(s);
			}
		}

		void LoadConfigFields()
		{
			if (mPS == null)
				return;
			String table = scope $"Configs.{mPSConfig}";
			List<String> items = scope .();
			defer { ClearAndDeleteItems!(items); }
			mPS.Toml.GetStringArray(table, "PreBuildCmds", items);
			JoinLines(items, "\n", mPSPre);
			ClearAndDeleteItems!(items);
			mPS.Toml.GetStringArray(table, "PostBuildCmds", items);
			JoinLines(items, "\n", mPSPost);
			ClearAndDeleteItems!(items);
			mPS.Toml.GetStringArray(table, "PreprocessorMacros", items);
			JoinLines(items, "; ", mPSMacros);
			mPS.Toml.GetString(table, "TargetDirectory", mPSTargetDir);
			mPS.Toml.GetString(table, "TargetName", mPSTargetName);
			mPS.Toml.GetString(table, "DebugCommand", mPSDebugCmd);
			mPS.Toml.GetString(table, "DebugCommandArguments", mPSDebugArgs);
			mPS.Toml.GetString(table, "DebugWorkingDirectory", mPSDebugDir);
			mPS.Toml.GetString(table, "OtherLinkFlags", mPSLinkFlags);
		}

		/// The result of one settings edit: logged, the panel and the tree re-read; false with the error shown.
		bool ProjectEditDone(Result<void> result, List<String> changes, StringView err, StringView what)
		{
			LogWorkspaceChanges(changes);
			if (result case .Err)
			{
				ReportError(scope $"{what}: {err}");
				mPSReloadPending = true;
				return false;
			}
			if (!changes.IsEmpty)
				SetStatus(scope $"{mPSName}: {what}");
			mPSReloadPending = true;
			return true;
		}

		public bool SetProjectBuildKind(ProjectBuildKind kind)
		{
			if (mPS == null || !CheckWritable())
				return false;
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			let r = WorkspaceFiles.SetBuildKind(mSelProjectDir, kind, changes, err);
			bool ok = ProjectEditDone(r, changes, err, scope $"build kind {WorkspaceFiles.KindLabel(kind)}");
			if (ok)
				mWsRescanPending = true;
			return ok;
		}

		public bool SetProjectValue(StringView table, StringView key, StringView value)
		{
			if (mPS == null || !CheckWritable())
				return false;
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			let r = WorkspaceFiles.SetValue(mSelProjectDir, table, key, value, changes, err);
			return ProjectEditDone(r, changes, err, scope $"{key} changed");
		}

		/// A list value from the panel's text: one item per line (`sep` '\n') or separated by ';'.
		public bool SetProjectList(StringView table, StringView key, StringView text, char8 sep)
		{
			if (mPS == null || !CheckWritable())
				return false;
			List<String> items = scope .();
			defer { ClearAndDeleteItems!(items); }
			for (var part in text.Split(sep))
			{
				part.Trim();
				if (!part.IsEmpty)
					items.Add(new String(part));
			}
			List<String> changes = scope .();
			defer { ClearAndDeleteItems!(changes); }
			String err = scope .();
			let r = WorkspaceFiles.SetList(mSelProjectDir, table, key, items, changes, err);
			return ProjectEditDone(r, changes, err, scope $"{key} changed");
		}

		/// A text row of the settings grid bound to `value`; the edit is written when the field is left.
		bool PSText(StringView label, StringView id, String value, StringView tip, StringView hint = default)
		{
			PropertyGrid.Row(label, tip);
			return PropertyGrid.Text(id, value, ?, false, null, hint);
		}

		bool PSLines(StringView label, StringView id, String value, StringView tip)
		{
			PropertyGrid.Row(label, tip);
			float h = Gui.igGetTextLineHeight() * 3.4f + 8 * Look.Scale;
			return PropertyGrid.Multiline(id, value, h, ?, mMono);
		}

		bool DrawProjectSettings()
		{
			if (mPSReloadPending && !Gui.igIsAnyItemActive())
			{
				mPSReloadPending = false;
				ReloadProjectSettings();
			}
			if (mPS == null || !Directory.Exists(mSelProjectDir))
			{
				mSelProjectActive = false;
				return false;
			}
			// Changed outside (the Beef IDE, a text editor): read again while nothing is being typed.
			if (mFrame % 30 == 7 && !Gui.igIsAnyItemActive() && WriteTimeOf(mPS.FilePath) != mPSTime)
				ReloadProjectSettings();
			if (mPS == null)
				return false;
			let ws = mWorkspace;
			let wp = ws?.FindDir(mSelProjectDir);
			String projName = scope .(wp != null ? wp.Name : mPSName);
			bool startup = ws != null && wp != null && ws.Startup == wp.Name;
			String rel = scope .();
			if (IsUnder(mSelProjectDir, mProjectRoot))
				RelativeToRoot(mSelProjectDir, rel);
			else
				rel.Set(mSelProjectDir);
			DetailsHeader(Icon.Package, ProjectColor, scope $"{projName}", scope $"Project Settings  -  {rel}{(startup ? "  (startup project)" : "")}");

			if (PropertyGrid.Begin("##projectsettings", 0.45f))
			{
				if (PropertyGrid.Category("Project", true))
				{
					PropertyGrid.Row("Name", "The project's name ([Project] Name). Rename the project's folder in the Project Browser to rename it");
					PropertyGrid.Value(projName);
					PropertyGrid.Row("File", "The project file the settings are written to");
					PropertyGrid.Value(mPS.FilePath);
					PropertyGrid.Row("Build kind", "What the project builds: TargetType (and BuildKind = \"DynamicLib\" in every configuration for a dynamic library, a DLL)");
					let kind = mPS.Kind;
					int32 index = (kind == .Other) ? -1 : (int32)kind;
					if (kind == .Other)
					{
						String tt = scope .();
						mPS.GetTargetType(tt);
						PropertyGrid.Value(scope $"{tt} (kept; pick a kind to change it)");
						PropertyGrid.Row("", "");
					}
					if (PropertyGrid.Combo("##pskind", ref index, sPSKinds) && index >= 0 && index != (int32)kind)
						SetProjectBuildKind((ProjectBuildKind)index);
					if (PSText("Startup object", "##psstartupobj", mPSStartupObject, "The class whose static Main starts the program ([Project] StartupObject)", scope $"e.g. {projName}.Program"))
						SetProjectValue("Project", "StartupObject", mPSStartupObject);
					if (PSText("Namespace", "##psns", mPSNamespace, "Default namespace: the namespace new files get ([Project] DefaultNamespace)", scope $"default: {projName}"))
						SetProjectValue("Project", "DefaultNamespace", mPSNamespace);
					PropertyGrid.Row("Startup project", "The project Compile and Start build and run (BeefSpace.toml [Workspace] StartupProject)");
					if (startup)
						PropertyGrid.Value("Yes", StartupColor);
					else if (wp == null)
						PropertyGrid.Value("Not in the workspace");
					else if (Gui.Button(scope $"{Icon.Play}  Set as startup"))
						QueueWsAction(.SetStartup, wp.Dir, wp.Name);
				}

				if (PropertyGrid.Category("Dependencies", true))
				{
					List<String> deps = scope .();
					defer { ClearAndDeleteItems!(deps); }
					mPS.Dependencies(deps);
					List<String> rows = scope .();
					defer { ClearAndDeleteItems!(rows); }
					rows.Add(new String("corlib"));
					if (ws != null)
						for (let p in ws.Projects)
							if (p.Name != projName && !rows.Contains(p.Name))
								rows.Add(new String(p.Name));
					for (let d in deps)
						if (!rows.Contains(d) && d != projName)
							rows.Add(new String(d));
					for (let r in rows)
					{
						let p = ws?.Find(r);
						String tip = scope .();
						if (r == "corlib")
							tip.Set("Beef's core library (System)");
						else if (p == null)
							tip.Set("Not a project of this workspace (a library of the Beef installation, or missing)");
						else if (p.HasPath)
							tip.AppendF("Workspace project ({})", p.RelPath);
						else
							tip.Set("Workspace library (listed by version)");
						PropertyGrid.Row(r, tip);
						bool on = deps.Contains(r);
						bool was = on;
						Gui.PushID(r);
						PropertyGrid.Bool("##dep", ref on);
						Gui.PopID();
						if (on != was)
							QueueWsAction(on ? .AddDependency : .RemoveDependency, mSelProjectDir, r, projName);
					}
				}

				if (PropertyGrid.Category("Configuration", true))
				{
					List<String> configs = scope .();
					defer { ClearAndDeleteItems!(configs); }
					for (let c in sPSDefaultConfigs)
						configs.Add(new String(c));
					List<String> found = scope .();
					defer { ClearAndDeleteItems!(found); }
					mPS.ConfigSections(found);
					for (let c in found)
						if (!configs.Contains(c))
							configs.Add(new String(c));
					List<String> labels = scope .();
					defer { ClearAndDeleteItems!(labels); }
					List<StringView> views = scope .();
					int32 cur = 0;
					for (let c in configs)
					{
						String l = new .(c);
						l.Replace(".", " | ");
						labels.Add(l);
						views.Add(l);
						if (c == mPSConfig)
							cur = (int32)@c.Index;
					}
					PropertyGrid.Row("Configuration", "The configuration and platform the values below belong to ([Configs.<Configuration>.<Platform>])");
					if (PropertyGrid.Combo("##psconfig", ref cur, views))
					{
						mPSConfig.Set(configs[cur]);
						LoadConfigFields();
					}
					String table = scope $"Configs.{mPSConfig}";
					if (PSLines("Pre-build", "##pspre", mPSPre, "Pre-build commands: run before the build, one per line (PreBuildCmds)"))
						SetProjectList(table, "PreBuildCmds", mPSPre, '\n');
					if (PSLines("Post-build", "##pspost", mPSPost, "Post-build commands: run after the build, one per line (PostBuildCmds), e.g. CopyToDependents(\"$(ProjectDir)/x.dll\")"))
						SetProjectList(table, "PostBuildCmds", mPSPost, '\n');
					if (PSText("Output folder", "##pstdir", mPSTargetDir, "Where the output goes (TargetDirectory)", "default: $(BuildDir)"))
						SetProjectValue(table, "TargetDirectory", mPSTargetDir);
					if (PSText("Output name", "##pstname", mPSTargetName, "The output's file name (TargetName)", "default: $(ProjectName)"))
						SetProjectValue(table, "TargetName", mPSTargetName);
					if (PSText("Run program", "##psdcmd", mPSDebugCmd, "Debug command: the program Start runs (DebugCommand); set it for a library to the program that loads it", "default: $(TargetPath)"))
						SetProjectValue(table, "DebugCommand", mPSDebugCmd);
					if (PSText("Run arguments", "##psdargs", mPSDebugArgs, "Debug command arguments: its command line (DebugCommandArguments)", "none"))
						SetProjectValue(table, "DebugCommandArguments", mPSDebugArgs);
					if (PSText("Run in folder", "##psddir", mPSDebugDir, "Debug working directory: where it starts (DebugWorkingDirectory)", "default: $(ProjectDir)"))
						SetProjectValue(table, "DebugWorkingDirectory", mPSDebugDir);
					if (PSText("Macros", "##psmacros", mPSMacros, "Preprocessor macros: symbols for #if, separated by ';' (PreprocessorMacros)", "none"))
						SetProjectList(table, "PreprocessorMacros", mPSMacros, ';');
					if (PSText("Link flags", "##pslink", mPSLinkFlags, "Other link flags: extra linker flags (OtherLinkFlags)", "default: $(LinkFlags)"))
						SetProjectValue(table, "OtherLinkFlags", mPSLinkFlags);
					// What else this configuration holds, as written (kept on every edit).
					List<(String key, String raw)> entries = scope .();
					defer { for (let e in entries) { delete e.key; delete e.raw; } }
					mPS.Toml.Entries(table, entries);
					for (let e in entries)
					{
						bool known = false;
						for (let k in sPSConfigKeys)
							if (e.key == k)
								known = true;
						if (known)
							continue;
						PropertyGrid.Row(e.key, "Kept as it is; edit it in the Beef IDE or a text editor");
						PropertyGrid.Value(e.raw);
					}
				}
				PropertyGrid.End();
			}
			return true;
		}
	}
}
