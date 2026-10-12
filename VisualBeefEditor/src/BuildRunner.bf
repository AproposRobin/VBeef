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
		/// Takes the inputs' fingerprint and the source hash, then starts BeefBuild (or decides
		/// that nothing changed), so the frame that pressed Compile does no file work.
		Thread mPrepThread ~ delete _;
		Monitor mMonitor = new .() ~ delete _;
		List<String> mPending = new .() ~ DeleteContainerAndItems!(_);
		String mExe = new .() ~ delete _;
		String mArgs = new .() ~ delete _;
		/// Set under mMonitor by the preparing thread when it is done (BeefBuild started, up to
		/// date, or could not start).
		bool mPrepared;
		bool mCancelled;
		/// The previous compile's messages, shown again when this one finds nothing changed.
		List<Diagnostic> mCarried = new .() ~ DeleteContainerAndItems!(_);
		CompileInputs mSkipIf ~ delete _;

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
		/// BeefBuild runs at BelowNormal priority (the build before debugging).
		public bool LowerPriority;
		/// Fingerprint of the compile's inputs when it started (BuildInputs; 0: none taken).
		public uint64 Inputs;
		/// Content hash of the workspace sources when it started (the compile indicator).
		public uint64 SourceHash;
		/// Nothing changed since the last successful compile of this configuration: BeefBuild
		/// was not run, the output is the one already built.
		public bool UpToDate;
		/// BeefBuild could not be started (StartError says why).
		public bool StartFailed;
		public String StartError = new .() ~ delete _;
		/// Process id of the running BeefBuild (0 when none).
		public int ProcessId
		{
			get
			{
				using (mMonitor.Enter())
					return (mProcess != null) ? mProcess.ProcessId : 0;
			}
		}
		/// Runs from Start until the editor sees the compile end (the progress line's elapsed time).
		Stopwatch mWatch = new .() ~ delete _;
		/// Milliseconds the compile took (from Start until its end was seen; 0 before it ended).
		public double BuildMs;
		/// Milliseconds since Start (live while running, BuildMs after).
		public double ElapsedMs => Running ? mWatch.Elapsed.TotalMilliseconds : BuildMs;

		public ~this()
		{
			using (mMonitor.Enter())
				mCancelled = true;
			mPrepThread?.Join();
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

		/// The platform BeefBuild builds for (MakeArgs passes it on Windows; elsewhere BeefBuild's
		/// default is the system's).
#if BF_PLATFORM_WINDOWS
		public const String Platform = "Win64";
#else
		public const String Platform = "Linux64";
#endif

		/// Starts a compile. The fingerprint, the source hash and BeefBuild itself start on a
		/// worker thread; Update reports the end. `skipIf` (taken over): what the last successful
		/// compile was built from; when the inputs are the same and its output is unchanged,
		/// BeefBuild is not run and the compile ends at once as UpToDate with `carried` (copied)
		/// as its messages. .Err only when BeefBuild is not there at all.
		public Result<void> Start(StringView beefBuildPath, StringView workspaceDir, StringView config = "", CompileInputs skipIf = null, List<Diagnostic> carried = null)
		{
			Workspace.Set(workspaceDir);
			Config.Set(config);
			mSkipIf = skipIf;
			if (carried != null)
				for (let m in carried)
				{
					let copy = new Diagnostic();
					copy.Severity = m.Severity;
					copy.Text.Set(m.Text);
					copy.Path.Set(m.Path);
					copy.Line = m.Line;
					copy.Column = m.Column;
					mCarried.Add(copy);
				}
			ResolveExe(beefBuildPath, mExe);
			if (!File.Exists(mExe))
			{
				// A bare name that is not on PATH: let the start below report it.
				if (mExe.Contains('/') || mExe.Contains('\\'))
					return .Err;
			}
			MakeArgs(workspaceDir, config, mArgs);
			CommandLine.Clear();
			CommandLine.AppendF("\"{}\" {}", mExe, mArgs);
			mWatch.Restart();
			Running = true;
			mPrepThread = new Thread(new => Prepare);
			mPrepThread.SetName("VisualBeef compile");
			mPrepThread.Start(false);
			return .Ok;
		}

		/// Worker: fingerprint, source hash, then BeefBuild (or nothing when up to date).
		void Prepare()
		{
			Inputs = BuildInputs.Fingerprint(Workspace, mExe, Config, Platform);
			SourceHash = CompileRecord.HashWorkspace(Workspace);
			bool upToDate = mSkipIf != null && mSkipIf.Covers(Config, Inputs);
			using (mMonitor.Enter())
			{
				if (mCancelled || upToDate)
				{
					UpToDate = upToDate && !mCancelled;
					mPrepared = true;
					return;
				}
			}
			// Started outside the lock: the frame loop drains output under it and must not wait.
			ProcessStartInfo psi = scope .();
			psi.SetFileName(mExe);
			psi.SetArguments(mArgs);
			psi.SetWorkingDirectory(Workspace);
			psi.UseShellExecute = false;
			psi.RedirectStandardOutput = true;
			psi.RedirectStandardError = true;
			psi.CreateNoWindow = true;
			let process = new SpawnedProcess();
			if (process.Start(psi) case .Err)
			{
				delete process;
				using (mMonitor.Enter())
				{
					StartFailed = true;
					StartError.AppendF("Could not run BeefBuild at '{}'", mExe);
					mPrepared = true;
				}
				return;
			}
			if (LowerPriority)
				VisualBeef.Debug.LowPriority.Apply(process.ProcessId);
			using (mMonitor.Enter())
			{
				mProcess = process;
				mOutThread = new Thread(new () => ReadThread(false));
				mOutThread.Start(false);
				mErrThread = new Thread(new () => ReadThread(true));
				mErrThread.Start(false);
				mPrepared = true;
			}
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
			bool prepared;
			using (mMonitor.Enter())
			{
				for (let line in mPending)
					TakeLine(line);
				mPending.Clear();
				prepared = mPrepared;
			}
			if (!Running || !prepared)
				return false;
			if (UpToDate || StartFailed)
			{
				mPrepThread.Join();
				mWatch.Stop();
				BuildMs = mWatch.Elapsed.TotalMilliseconds;
				Running = false;
				Succeeded = UpToDate;
				if (UpToDate)
				{
					Messages.AddRange(mCarried);
					mCarried.Clear();
				}
				return true;
			}
			if (mProcess != null && mProcess.HasExited)
			{
				mPrepThread.Join();
				mOutThread.Join();
				mErrThread.Join();
				using (mMonitor.Enter())
				{
					for (let line in mPending)
						TakeLine(line);
					mPending.Clear();
				}
				mWatch.Stop();
				BuildMs = mWatch.Elapsed.TotalMilliseconds;
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
