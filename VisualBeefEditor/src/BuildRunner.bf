using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Runs BeefBuild on a workspace in the background and collects its errors and warnings,
	/// like Blueprint's Compile button. Messages are parsed by BuildOutput (VisualBeefCore) and
	/// mapped to graph nodes by DiagnosticMap.
	class BuildRunner
	{
		SpawnedProcess mProcess ~ delete _;
		Thread mOutThread ~ delete _;
		Thread mErrThread ~ delete _;
		Monitor mMonitor = new .() ~ delete _;
		List<String> mPending = new .() ~ DeleteContainerAndItems!(_);

		public List<String> Output = new .() ~ DeleteContainerAndItems!(_);
		public List<Diagnostic> Messages = new .() ~ DeleteContainerAndItems!(_);
		public bool Running;
		public bool Succeeded;
		public int32 DocVersion;
		public String Workspace = new .() ~ delete _;
		/// "Debug" / "Release".
		public String Config = new .() ~ delete _;
		/// The command as run (shown in the Output Log).
		public String CommandLine = new .() ~ delete _;
		/// Process id of the running BeefBuild (0 when none).
		public int ProcessId => (mProcess != null) ? mProcess.ProcessId : 0;

		public ~this()
		{
			if (mProcess != null && !mProcess.HasExited)
				mProcess.Kill();
			mOutThread?.Join();
			mErrThread?.Join();
		}

		/// Finds the folder with a BeefSpace.toml at or above the given file.
		public static bool FindWorkspace(StringView filePath, String outDir)
		{
			String dir = scope .();
			Path.GetDirectoryPath(filePath, dir).IgnoreError(); // no parent (root or bare name): dir stays empty
			for (int depth = 0; depth < 16 && !dir.IsEmpty; depth++)
			{
				String probe = scope .();
				probe.AppendF("{}{}BeefSpace.toml", dir, Path.DirectorySeparatorChar);
				if (File.Exists(probe))
				{
					outDir.Set(dir);
					return true;
				}
				String parent = scope .();
				// At a root there is no parent (.Err); stop walking.
				if (Path.GetDirectoryPath(dir, parent) case .Err || parent == dir)
					break;
				dir.Set(parent);
			}
			return false;
		}

		/// Resolves a bare program name ("BeefBuild") through PATH.
		public static void ResolveExe(StringView name, String outPath)
		{
			outPath.Set(name);
			if (name.Contains('/') || name.Contains('\\') || File.Exists(name))
				return;
			String pathVar = scope .();
			Environment.GetEnvironmentVariable("PATH", pathVar).IgnoreError(); // PATH unset: stays empty, no search
			char8 sep = (Path.DirectorySeparatorChar == '\\') ? ';' : ':';
			for (let dir in pathVar.Split(sep))
			{
				if (dir.IsEmpty)
					continue;
				for (let ext in StringView[2]("", ".exe"))
				{
					String probe = scope .();
					probe.AppendF("{}{}{}{}", dir, Path.DirectorySeparatorChar, name, ext);
					if (File.Exists(probe))
					{
						outPath.Set(probe);
						return;
					}
				}
			}
		}

		/// The BeefBuild arguments for a workspace and configuration.
		public static void MakeArgs(StringView workspaceDir, StringView config, String outArgs)
		{
			// BeefBuild splits a folder name with a space even inside quotes; Start runs it in the workspace folder, so "." names it.
			if (workspaceDir.Contains(' '))
				outArgs.Append("-workspace=.");
			else
				outArgs.AppendF("-workspace=\"{}\"", workspaceDir);
			if (!config.IsEmpty)
				outArgs.AppendF(" -config={}", config);
#if BF_PLATFORM_WINDOWS
			outArgs.Append(" -platform=Win64");
#endif
		}

		public Result<void> Start(StringView beefBuildPath, StringView workspaceDir, StringView config = "")
		{
			Workspace.Set(workspaceDir);
			Config.Set(config);
			ProcessStartInfo psi = scope .();
			String exe = scope .();
			ResolveExe(beefBuildPath, exe);
			psi.SetFileName(exe);
			String args = scope .();
			MakeArgs(workspaceDir, config, args);
			CommandLine.Clear();
			CommandLine.AppendF("\"{}\" {}", exe, args);
			psi.SetArguments(args);
			psi.SetWorkingDirectory(workspaceDir);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = true;
			psi.RedirectStandardError = true;
			psi.CreateNoWindow = true;

			mProcess = new SpawnedProcess();
			if (mProcess.Start(psi) case .Err)
			{
				delete mProcess;
				mProcess = null;
				return .Err;
			}
			Running = true;
			mOutThread = new Thread(new () => ReadThread(false));
			mOutThread.Start(false);
			mErrThread = new Thread(new () => ReadThread(true));
			mErrThread.Start(false);
			return .Ok;
		}

		void ReadThread(bool stdErr)
		{
			FileStream stream = scope .();
			if ((stdErr ? mProcess.AttachStandardError(stream) : mProcess.AttachStandardOutput(stream)) case .Err)
				return;
			StreamReader reader = scope .(stream, null, false, 4096);
			while (true)
			{
				String line = scope .();
				if (reader.ReadLine(line) case .Err)
					break;
				using (mMonitor.Enter())
					mPending.Add(new String(line));
			}
		}

		/// Call once per frame. Returns true when the build just finished.
		public bool Update()
		{
			using (mMonitor.Enter())
			{
				for (let line in mPending)
					TakeLine(line);
				mPending.Clear();
			}
			if (Running && mProcess != null && mProcess.HasExited)
			{
				mOutThread.Join();
				mErrThread.Join();
				using (mMonitor.Enter())
				{
					for (let line in mPending)
						TakeLine(line);
					mPending.Clear();
				}
				Running = false;
				Succeeded = mProcess.ExitCode == 0;
				for (let m in Messages)
					if (m.IsError)
						Succeeded = false;
				return true;
			}
			return false;
		}

		/// Takes ownership of a raw output line: cleans it, parses it, keeps it.
		void TakeLine(String line)
		{
			CleanLine(line);
			if (line.IsEmpty)
			{
				delete line;
				return;
			}
			Parse(line);
			Output.Add(line);
		}

		/// BeefBuild draws a console progress bar ("[    ]****" in OEM box characters); it shows
		/// as mojibake in a log. Drops non-text bytes and the bar itself.
		public static void CleanLine(String line)
		{
			String clean = scope .(line.Length);
			for (let c in line.RawChars)
			{
				if (c == '\t' || (c >= ' ' && (uint8)c < 0x7F))
					clean.Append(c);
			}
			StringView v = clean;
			if (v.StartsWith('['))
			{
				int close = v.IndexOf(']');
				if (close > 0)
				{
					bool bar = true;
					for (let c in v.Substring(1, close - 1).RawChars)
						if (c != ' ' && c != '*' && c != '?' && c != '=' && c != '#')
							bar = false;
					if (bar)
					{
						v = v.Substring(close + 1);
						while (v.StartsWith('*') || v.StartsWith('?'))
							v = v.Substring(1);
					}
				}
			}
			v.Trim();
			String result = scope .(v);
			line.Set(result);
		}

		/// "ERROR: Unable to ... at line 12:8 in C:\path\File.bf" and the other formats
		/// BuildOutput knows.
		void Parse(StringView line)
		{
			let d = BuildOutput.Parse(line);
			if (d != null)
				Messages.Add(d);
		}

		public static bool SamePath(StringView a, StringView b)
		{
			if (a.Length != b.Length)
				return false;
			for (int i < a.Length)
			{
				char8 ca = a[i];
				char8 cb = b[i];
				if (ca == '\\') ca = '/';
				if (cb == '\\') cb = '/';
				if (ca.ToLower != cb.ToLower)
					return false;
			}
			return true;
		}
	}
}
