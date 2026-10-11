// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// The swap / backup / health-check flow follows UniversalUMP's launcher updater (src/Update/UpdateApply.bf, same owner,
// same licence), cut down to what a folder install of the editor needs.

using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Threading;

namespace VisualBeef.Update
{
	/// Installs a verified, extracted package over the editor's folder (Windows), and the file helpers both platforms use.
	///
	/// Windows: the editor copies its own program and vbhost.dll to <data>\update\helper\ and starts that copy as
	///   VisualBeefEditor.exe --apply-update <installDir> <editorPid> <stagedDir> <updateDir>
	/// then closes. The helper (RunHelper) waits for the editor to exit, copies every item it is about to replace into
	/// <updateDir>\previous\ (the rollback copy), copies the staged items over the install, records the new version, and
	/// starts the new editor with a health request. The new editor answers once it has drawn its first frames
	/// (ReportHealthy). If it exits first or does not answer within 60 s, the helper puts `previous` back and starts the
	/// old editor. The outcome is left in <updateDir>\last-result.json for the next start to report.
	public static class UpdateApply
	{
		public const StringView HelperSwitch = "--apply-update";
		public const int32 HealthTimeoutMs = 60000;

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetCurrentProcessId();
#else
		[CLink] static extern int32 getpid();
		[CLink] static extern int32 chmod(char8* path, uint32 mode);
#endif

		public static int32 CurrentPid()
		{
#if BF_PLATFORM_WINDOWS
			return (int32)GetCurrentProcessId();
#else
			return getpid();
#endif
		}

		/// Marks a file runnable (Linux); nothing on Windows.
		public static bool MakeRunnable(StringView path)
		{
#if BF_PLATFORM_WINDOWS
			return true;
#else
			return chmod(scope String(path).CStr(), 0o755) == 0;
#endif
		}

		static char8 Sep => Path.DirectorySeparatorChar;

		public static void Join(String outPath, StringView a, StringView b)
		{
			outPath.Set(a);
			if (!outPath.EndsWith('\\') && !outPath.EndsWith('/'))
				outPath.Append(Sep);
			outPath.Append(b);
		}

		public static void EnsureDir(StringView dir)
		{
			if (dir.IsEmpty || Directory.Exists(dir))
				return;
			String parent = scope .();
			if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty && parent != dir)
				EnsureDir(parent);
			Directory.CreateDirectory(dir).IgnoreError(); // callers check for what they need
		}

		/// Deletes a file or a folder tree; true when nothing is left at `path`.
		public static bool DeletePath(StringView path)
		{
			if (Directory.Exists(path))
				Directory.DelTree(path).IgnoreError(); // checked below
			else if (File.Exists(path))
				File.Delete(path).IgnoreError(); // checked below
			return !Directory.Exists(path) && !File.Exists(path);
		}

		/// Copies a file (overwriting), retrying for up to `retryMs` while the target is locked.
		public static bool CopyFile(StringView from, StringView to, int retryMs = 0)
		{
			int waited = 0;
			while (true)
			{
				if (File.Copy(from, to, true) case .Ok)
					return true;
				if (waited >= retryMs)
					return false;
				Thread.Sleep(250);
				waited += 250;
			}
		}

		/// Copies a file or a folder tree to `to` (created). False on the first failure.
		public static bool CopyTree(StringView from, StringView to, int retryMs = 0)
		{
			if (File.Exists(from))
				return CopyFile(from, to, retryMs);
			if (!Directory.Exists(from))
				return false;
			EnsureDir(to);
			if (!Directory.Exists(to))
				return false;
			for (let entry in Directory.Enumerate(from))
			{
				String name = scope .();
				entry.GetFileName(name);
				String src = scope .();
				Join(src, from, name);
				String dst = scope .();
				Join(dst, to, name);
				if (entry.IsDirectory)
				{
					if (!CopyTree(src, dst, retryMs))
						return false;
				}
				else if (!CopyFile(src, dst, retryMs))
					return false;
			}
			return true;
		}

		/// The top-level names in a folder.
		public static void TopLevel(StringView dir, List<String> outNames)
		{
			for (let entry in Directory.Enumerate(dir))
			{
				String name = new .();
				entry.GetFileName(name);
				outNames.Add(name);
			}
		}

		/// Swaps `staged` into `install`: every top-level item of `staged` is first copied from `install` (when it
		/// exists) into `previous`, whose `.added` file lists the items that did not exist; then each item is replaced
		/// (a folder as a whole). On a failure everything is restored (Restore) and false is returned with `outReason`.
		public static bool Swap(StringView install, StringView staged, StringView previous, String outReason, delegate void(StringView) log)
		{
			if (!DeletePath(previous))
			{
				outReason.Set(scope $"could not clear the previous copy at {previous}");
				return false;
			}
			EnsureDir(previous);
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			TopLevel(staged, names);
			if (names.IsEmpty)
			{
				outReason.Set("the new version is empty");
				return false;
			}
			String added = scope .();
			for (let name in names)
			{
				String cur = scope .();
				Join(cur, install, name);
				String bak = scope .();
				Join(bak, previous, name);
				if (File.Exists(cur) || Directory.Exists(cur))
				{
					if (!CopyTree(cur, bak))
					{
						outReason.Set(scope $"could not keep a copy of {cur}");
						return false;
					}
				}
				else
					added.AppendF("{}\n", name);
			}
			String addedFile = scope .();
			Join(addedFile, previous, ".added");
			if (File.WriteAllText(addedFile, added) case .Err)
			{
				outReason.Set("could not write the rollback list");
				return false;
			}
			if (log != null) log(scope $"previous copy kept in {previous} ({names.Count} items)");
			for (let name in names)
			{
				String src = scope .();
				Join(src, staged, name);
				String dst = scope .();
				Join(dst, install, name);
				bool ok;
				if (Directory.Exists(src))
					ok = DeletePath(dst) && CopyTree(src, dst, 10000);
				else
					ok = CopyFile(src, dst, 10000);
				if (!ok)
				{
					outReason.Set(scope $"could not replace {dst} (is another copy of VisualBeef still open?)");
					if (log != null) log(scope $"replace failed at {dst}; restoring the previous copy");
					String why = scope .();
					Restore(install, previous, why, log);
					return false;
				}
			}
			return true;
		}

		/// Puts `previous` back over `install` and removes the items the update added.
		public static bool Restore(StringView install, StringView previous, String outReason, delegate void(StringView) log)
		{
			bool ok = true;
			String addedFile = scope .();
			Join(addedFile, previous, ".added");
			String added = scope .();
			if (File.ReadAllText(addedFile, added) case .Ok)
			{
				for (var name in added.Split('\n'))
				{
					name.Trim();
					if (name.IsEmpty || name.Contains('/') || name.Contains('\\') || name == "..")
						continue;
					String p = scope .();
					Join(p, install, name);
					if (!DeletePath(p))
						ok = false;
				}
			}
			List<String> names = scope .();
			defer { ClearAndDeleteItems!(names); }
			if (Directory.Exists(previous))
				TopLevel(previous, names);
			for (let name in names)
			{
				if (name == ".added")
					continue;
				String src = scope .();
				Join(src, previous, name);
				String dst = scope .();
				Join(dst, install, name);
				bool one;
				if (Directory.Exists(src))
					one = DeletePath(dst) && CopyTree(src, dst, 10000);
				else
					one = CopyFile(src, dst, 10000);
				if (!one)
				{
					ok = false;
					outReason.Set(scope $"could not restore {dst}");
				}
			}
			if (log != null) log(ok ? "previous copy restored" : scope $"restore incomplete: {outReason}");
			return ok;
		}

		/// The first line of a VERSION.txt ("" when missing).
		public static void ReadVersionFile(StringView dir, String outVersion)
		{
			String p = scope .();
			Join(p, dir, "VERSION.txt");
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
				return;
			int nl = text.IndexOf('\n');
			if (nl >= 0)
				text.RemoveToEnd(nl);
			text.Trim();
			outVersion.Set(text);
		}

		/// Records the version + signed sequence of the build now installed (`installed.json`).
		public static void WriteInstalled(StringView updateDir, StringView version, int64 sequence)
		{
			String p = scope .();
			Join(p, updateDir, "installed.json");
			String text = scope .();
			text.Append("{\"version\": ");
			UpdateJson.WriteString(version, text);
			text.AppendF(", \"sequence\": {}}}\n", sequence);
			File.WriteAllText(p, text).IgnoreError(); // without it the next check compares versions instead
		}

		/// The signed sequence recorded for `version`, or -1.
		public static int64 ReadInstalledSequence(StringView updateDir, StringView version)
		{
			String p = scope .();
			Join(p, updateDir, "installed.json");
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
				return -1;
			if (UpdateJson.Parse(text) case .Ok(let j))
			{
				defer delete j;
				String v = scope .();
				if (j.GetString("version", v) && v == version && j.GetInt("sequence", let seq) && seq >= 1)
					return seq;
			}
			return -1;
		}

		public static void WriteResult(StringView updateDir, bool ok, StringView from, StringView to, StringView message)
		{
			String p = scope .();
			Join(p, updateDir, "last-result.json");
			String text = scope .();
			text.AppendF("{{\"ok\": {}, \"from\": ", ok ? "true" : "false");
			UpdateJson.WriteString(from, text);
			text.Append(", \"to\": ");
			UpdateJson.WriteString(to, text);
			text.Append(", \"message\": ");
			UpdateJson.WriteString(message, text);
			text.Append("}\n");
			File.WriteAllText(p, text).IgnoreError(); // the outcome is also in update.log
		}

		static void AppendLog(StringView updateDir, StringView line)
		{
			String p = scope .();
			Join(p, updateDir, "update.log");
			let now = DateTime.Now;
			String text = scope .();
			text.AppendF("{0:yyyy-MM-dd HH:mm:ss} {1}\n", now, line);
			File.WriteAllText(p, text, true).IgnoreError(); // logging is best effort
		}

		static bool StartEditor(StringView installDir, SpawnedProcess proc)
		{
			String exe = scope .();
#if BF_PLATFORM_WINDOWS
			Join(exe, installDir, "VisualBeefEditor.exe");
#else
			Join(exe, installDir, "VisualBeefEditor");
#endif
			ProcessStartInfo psi = scope .();
			psi.SetFileName(exe);
			psi.SetWorkingDirectory(installDir);
			psi.UseShellExecute = false;
			return proc.Start(psi) case .Ok;
		}

		static bool WaitForExit(int32 pid, int timeoutMs)
		{
			int waited = 0;
			while (VisualBeef.Debug.GameProcesses.IsRunning(pid))
			{
				if (waited >= timeoutMs)
					return false;
				Thread.Sleep(200);
				waited += 200;
			}
			return true;
		}

		/// The helper process: `--apply-update <installDir> <editorPid> <stagedDir> <updateDir>`. Returns the exit code.
		public static int RunHelper(String[] args)
		{
			if (args.Count < 5 || args[0] != HelperSwitch)
				return 2;
			StringView install = args[1];
			let pid = int32.Parse(args[2]).GetValueOrDefault();
			StringView staged = args[3];
			StringView updateDir = args[4];
			delegate void(StringView) log = scope (line) => AppendLog(updateDir, line);
			log(scope $"helper started: install {install}, editor pid {pid}, staged {staged}");

			String from = scope .();
			ReadVersionFile(install, from);
			String to = scope .();
			ReadVersionFile(staged, to);
			int64 sequence = -1;
			{
				String ready = scope .();
				String readyPath = scope .();
				String stagedParent = scope .();
				Path.GetDirectoryPath(staged, stagedParent).IgnoreError(); // ready.json sits beside the staged folder
				Join(readyPath, stagedParent, "ready.json");
				if (File.ReadAllText(readyPath, ready) case .Ok && UpdateJson.Parse(ready) case .Ok(let j))
				{
					j.GetInt("sequence", out sequence);
					delete j;
				}
			}

			if (pid > 0 && !WaitForExit(pid, 60000))
			{
				log("the editor did not close within 60 s; nothing was changed");
				WriteResult(updateDir, false, from, to, "VisualBeef did not close, so the update was not installed. Nothing was changed.");
				return 1;
			}

			String previous = scope .();
			Join(previous, updateDir, "previous");
			String reason = scope .();
			if (!Swap(install, staged, previous, reason, log))
			{
				log(scope $"update failed: {reason}");
				WriteResult(updateDir, false, from, to, scope $"The update to {to} could not be installed: {reason}. {from} was kept.");
				SpawnedProcess old = scope .();
				StartEditor(install, old);
				return 1;
			}
			log(scope $"installed {to} over {from}");

			// Health check: the new editor answers health.request with health.ok once it has drawn its first frames.
			String request = scope .();
			Join(request, updateDir, "health.request");
			String answer = scope .();
			Join(answer, updateDir, "health.ok");
			File.Delete(answer).IgnoreError(); // a stale answer must not count
			String token = scope .();
			token.AppendF("{}-{}", CurrentPid(), Internal.GetTickCountMicro());
			File.WriteAllText(request, token).IgnoreError(); // without it the new editor never answers: rolled back below

			int healthMs = HealthTimeoutMs;
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_UPDATE_HEALTH_MS", env) case .Ok && int32.Parse(env) case .Ok(let ms) && ms > 0)
				healthMs = ms;

			// Written before the start so the new editor reports it; replaced below when the health check fails.
			WriteResult(updateDir, true, from, to, scope $"VisualBeef was updated to {to}.");
			SpawnedProcess proc = scope .();
			bool healthy = false;
			String why = scope .();
			if (!StartEditor(install, proc))
				why.Set("it could not be started");
			else
			{
				int waited = 0;
				while (true)
				{
					String got = scope .();
					if (File.ReadAllText(answer, got) case .Ok && got == token)
					{
						healthy = true;
						break;
					}
					if (proc.WaitFor(250))
					{
						why.Set(scope $"it closed with code {proc.ExitCode} before it finished starting");
						break;
					}
					waited += 250;
					if (waited >= healthMs)
					{
						why.Set(scope $"it did not finish starting within {healthMs / 1000} s");
						proc.Kill();
						proc.WaitFor(5000);
						break;
					}
				}
			}
			File.Delete(request).IgnoreError(); // done either way
			File.Delete(answer).IgnoreError();

			if (healthy)
			{
				if (sequence >= 1)
					WriteInstalled(updateDir, to, sequence);
				log(scope $"VisualBeef {to} started; update complete");
				return 0;
			}

			log(scope $"VisualBeef {to} did not start correctly ({why}); restoring {from}");
			String restoreWhy = scope .();
			Restore(install, previous, restoreWhy, log);
			WriteResult(updateDir, false, from, to, scope $"VisualBeef {to} did not start correctly ({why}), so {from} was restored.");
			SpawnedProcess old = scope .();
			StartEditor(install, old);
			return 1;
		}

		/// Called by a starting editor once it has drawn its first frames: answers the helper's health request.
		public static void ReportHealthy(StringView updateDir)
		{
			String request = scope .();
			Join(request, updateDir, "health.request");
			String token = scope .();
			if (File.ReadAllText(request, token) case .Err)
				return;
			String answer = scope .();
			Join(answer, updateDir, "health.ok");
			File.WriteAllText(answer, token).IgnoreError(); // the helper times out and restores without it
		}
	}
}
