using System;
using System.Collections;
using System.IO;
using VisualBeef.Catalog;

namespace VisualBeef.Debug
{
	/// What Start Debugging runs for a workspace: the startup project's Debug command, arguments
	/// and working folder, resolved the way the Beef IDE does (BeefSpace.toml `StartupProject`;
	/// BeefProj.toml `[Configs.<Config>.<Platform>]` TargetDirectory / TargetName / DebugCommand /
	/// DebugCommandArguments / DebugWorkingDirectory, with the IDE's defaults).
	class DebugTarget
	{
		public String Project = new .() ~ delete _;
		public String ProjectDir = new .() ~ delete _;
		public String Exe = new .() ~ delete _;
		public String Args = new .() ~ delete _;
		public String WorkDir = new .() ~ delete _;
		public String TargetType = new .() ~ delete _;
		/// What the startup project builds: the .exe, the .dll of a dynamic library (a mod), or
		/// the folder + name of a static library.
		public String TargetPath = new .() ~ delete _;

		/// Fills the target for `workspaceDir` (holding BeefSpace.toml) and a configuration; false
		/// with a reason the editor can show.
		public bool Resolve(StringView workspaceDir, StringView config, String outError, StringView platform = "Win64")
		{
			return Resolve(workspaceDir, config, outError, platform, false);
		}

		/// Only what the startup project builds (TargetPath, Project, TargetType), not how it runs:
		/// for a mod, the DLL a game loads. True when the file exists.
		public bool ResolveOutput(StringView workspaceDir, StringView config, String outError, StringView platform = "Win64")
		{
			return Resolve(workspaceDir, config, outError, platform, true);
		}

		bool Resolve(StringView workspaceDir, StringView config, String outError, StringView platform, bool outputOnly)
		{
			String wsDir = scope .(workspaceDir);
			wsDir.Replace('/', '\\');
			while (wsDir.EndsWith('\\'))
				wsDir.RemoveFromEnd(1);
			MiniToml space = scope .();
			if (!MiniToml.Load(scope $"{wsDir}\\BeefSpace.toml", space))
			{
				outError.AppendF("No BeefSpace.toml in {}", wsDir);
				return false;
			}
			Project.Set(space.Get("Workspace.StartupProject"));
			if (Project.IsEmpty)
			{
				outError.Set("The workspace has no startup project (BeefSpace.toml [Workspace] StartupProject).");
				return false;
			}
			var projPath = space.Get(scope $"Projects.{Project}.Path");
			if (projPath.IsEmpty)
				projPath = Project;
			String dir = scope .();
			if (projPath.Length > 1 && projPath[1] == ':')
				dir.Set(projPath);
			else
				dir.AppendF("{}\\{}", wsDir, projPath);
			dir.Replace('/', '\\');
			while (dir.EndsWith("\\.") || dir.EndsWith('\\'))
				dir.RemoveFromEnd(dir.EndsWith('\\') ? 1 : 2);
			ProjectDir.Set(dir);

			MiniToml proj = scope .();
			if (!MiniToml.Load(scope $"{ProjectDir}\\BeefProj.toml", proj))
			{
				outError.AppendF("The startup project {} has no BeefProj.toml in {}", Project, ProjectDir);
				return false;
			}
			let name = proj.Get("Project.Name");
			if (!name.IsEmpty)
				Project.Set(name);
			TargetType.Set(proj.Get("Project.TargetType"));
			if (TargetType.IsEmpty)
				TargetType.Set("BeefConsoleApplication");

			String sec = scope $"Configs.{config}.{platform}.";
			StringView Opt(StringView key, StringView def)
			{
				let v = proj.Get(scope $"{sec}{key}");
				return v.IsEmpty ? def : v;
			}

			String buildDir = scope $"{wsDir}\\build\\{config}_{platform}\\{Project}";
			String targetDir = scope .();
			String targetName = scope .();
			Expand(Opt("TargetDirectory", "$(BuildDir)"), wsDir, buildDir, "", config, platform, targetDir);
			Expand(Opt("TargetName", "$(ProjectName)"), wsDir, buildDir, "", config, platform, targetName);
			String targetPath = scope $"{targetDir}\\{targetName}";
			bool isLib = TargetType == "BeefLib";
			if (TargetType == "BeefDynLib")
				targetPath.Append(".dll");
			else if (!isLib)
				targetPath.Append(".exe");
			TargetPath.Set(targetPath);
			// A mod is a library whose build kind is a DLL (BeefProj.toml `BuildKind = "DynamicLib"`).
			if (isLib && Opt("BuildKind", "") == "DynamicLib")
			{
				TargetPath.Append(".dll");
				targetPath.Append(".dll");
			}
			if (outputOnly)
			{
				if (!File.Exists(TargetPath))
				{
					outError.AppendF("Not built in {}: {}", config, TargetPath);
					return false;
				}
				return true;
			}

			let cmd = Opt("DebugCommand", "$(TargetPath)");
			if (isLib && cmd == "$(TargetPath)")
			{
				outError.AppendF("The startup project {} is a library: set a Debug command in its properties (BeefProj.toml DebugCommand) to the program that uses it.", Project);
				return false;
			}
			String cmdOut = scope .();
			Expand(cmd, wsDir, buildDir, targetPath, config, platform, cmdOut);
			Expand(Opt("DebugCommandArguments", ""), wsDir, buildDir, targetPath, config, platform, Args);
			String work = scope .();
			Expand(Opt("DebugWorkingDirectory", "$(ProjectDir)"), wsDir, buildDir, targetPath, config, platform, work);
			Absolute(work, ProjectDir, WorkDir);
			Absolute(cmdOut, WorkDir, Exe);
			if (!File.Exists(Exe))
			{
				outError.AppendF("The program to debug was not built: {} (Compile in Debug first)", Exe);
				return false;
			}
			return true;
		}

		void Expand(StringView text, StringView wsDir, StringView buildDir, StringView targetPath, StringView config, StringView platform, String outText)
		{
			outText.Set(text);
			outText.Replace("$(WorkspaceDir)", wsDir);
			outText.Replace("$(ProjectDir)", ProjectDir);
			outText.Replace("$(ProjectName)", Project);
			outText.Replace("$(BuildDir)", buildDir);
			outText.Replace("$(TargetPath)", targetPath);
			String targetDir = scope .();
			if (!targetPath.IsEmpty)
				Path.GetDirectoryPath(targetPath, targetDir).IgnoreError(); // no folder: stays empty
			outText.Replace("$(TargetDir)", targetDir);
			outText.Replace("$(Configuration)", config);
			outText.Replace("$(Config)", config);
			outText.Replace("$(Platform)", platform);
			outText.Replace("$(Arguments)", "");
			outText.Replace('/', '\\');
		}

		static void Absolute(StringView path, StringView baseDir, String outPath)
		{
			if (path.IsEmpty)
				outPath.Set(baseDir);
			else if ((path.Length > 1 && path[1] == ':') || path.StartsWith("\\\\"))
				outPath.Set(path);
			else
				outPath.Set(scope $"{baseDir}\\{path}");
		}
	}
}

namespace VisualBeef.Debug
{
	/// Child processes the debugger flow starts (the build before debugging) run at BelowNormal
	/// priority, so a build never makes the machine or the editor sluggish.
	static class LowPriority
	{
#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* OpenProcess(uint32 access, int32 inherit, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SetPriorityClass(void* process, uint32 priorityClass);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
		const uint32 PROCESS_SET_INFORMATION = 0x0200;
		const uint32 BELOW_NORMAL_PRIORITY_CLASS = 0x00004000;
#endif

		/// Lowers a running process (by id) to BelowNormal. False when that was not possible.
		public static bool Apply(int processId)
		{
#if BF_PLATFORM_WINDOWS
			if (processId == 0)
				return false;
			let h = OpenProcess(PROCESS_SET_INFORMATION, 0, (uint32)processId);
			if (h == null)
				return false;
			let ok = SetPriorityClass(h, BELOW_NORMAL_PRIORITY_CLASS) != 0;
			CloseHandle(h);
			return ok;
#else
			return false;
#endif
		}
	}
}
