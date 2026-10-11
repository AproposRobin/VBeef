#if !BF_PLATFORM_WINDOWS
using System;
using System.IO;
using System.Collections;

namespace VisualBeef.Document
{
	/// The Linux crash report writer (docs/Linux.md > Crash reports). The editor's signal handler
	/// (VisualBeefEditor CrashHandler) calls `Write` from inside a SIGSEGV / SIGABRT / SIGFPE /
	/// SIGILL / SIGBUS handler, so everything on that path uses fixed buffers and raw `write(2)`:
	/// no allocation, no stdio, no locks. Everything that allocates (`ResolveDir`, `SetProject`,
	/// `FindNewer`) runs outside the signal, at start-up or once per frame.
	///
	/// A report is `<dir>/visualbeef-crash-YYYY-MM-DD-HHMMSS-<pid>.log` (UTC) holding the version,
	/// the signal, the fault address, the registers (when the handler passes the ucontext), the
	/// open project, a `backtrace(3)` stack (`backtrace_symbols_fd`: "binary(+offset) [address]",
	/// resolved with `addr2line -f -C -e <binary> <offset>`) and whatever the caller appends.
	static class PosixCrashReport
	{
		/// Report folder with a trailing '/', NUL-terminated (set by SetDir / ResolveDir).
		static char8[1024] sDir;
		static int32 sDirLen;
		/// The open project folder, NUL-terminated; empty when none.
		static char8[1024] sProject;
		static int32 sProjectLen;
		static String sProjectCopy = new .() ~ delete _;
		static bool sBacktraceReady;

		public const String FilePrefix = "visualbeef-crash-";

		[CRepr]
		struct TimeSpec
		{
			public int tv_sec;
			public int tv_nsec;
		}

		[CLink] static extern int32 open(char8* path, int32 flags, int32 mode);
		[CLink] static extern int write(int32 fd, void* data, int count);
		[CLink] static extern int32 fsync(int32 fd);
		[CLink] static extern int32 close(int32 fd);
		[CLink] static extern int32 getpid();
		[CLink] static extern int32 gettid();
		[CLink] static extern int32 clock_gettime(int32 clock, TimeSpec* ts);
		[CLink] static extern int32 backtrace(void** buffer, int32 size);
		[CLink] static extern void backtrace_symbols_fd(void** buffer, int32 size, int32 fd);

		/// Where reports go: `$VB_HOME/crashes` when VB_HOME is set (tests, portable installs, as
		/// for every other per-user file), else `$XDG_STATE_HOME/visualbeef/crashes`, else
		/// `~/.local/state/visualbeef/crashes`. No trailing separator. The folder is not created.
		public static void ResolveDir(String outDir)
		{
			String v = scope .();
			if (Environment.GetEnvironmentVariable("VB_HOME", v) case .Ok && !v.IsEmpty)
			{
				while (v.Length > 1 && v.EndsWith('/'))
					v.RemoveFromEnd(1);
				outDir.AppendF("{}/crashes", v);
				return;
			}
			v.Clear();
			if (Environment.GetEnvironmentVariable("XDG_STATE_HOME", v) case .Ok && v.StartsWith('/'))
			{
				while (v.Length > 1 && v.EndsWith('/'))
					v.RemoveFromEnd(1);
				outDir.AppendF("{}/visualbeef/crashes", v);
				return;
			}
			v.Clear();
			Environment.GetEnvironmentVariable("HOME", v).IgnoreError(); // HOME unset: relative ".local/state"
			if (v.IsEmpty)
				v.Set(".");
			while (v.Length > 1 && v.EndsWith('/'))
				v.RemoveFromEnd(1);
			outDir.AppendF("{}/.local/state/visualbeef/crashes", v);
		}

		/// Sets the report folder (created, with its parents) and warms up backtrace(3), whose first
		/// call loads libgcc_s (it allocates; it must not do that inside the signal).
		public static void SetDir(StringView dir)
		{
			EnsureDir(dir);
			sDirLen = 0;
			for (let c in dir.RawChars)
			{
				if (sDirLen >= sDir.Count - 2)
					break;
				sDir[sDirLen++] = c;
			}
			if (sDirLen > 0 && sDir[sDirLen - 1] != '/')
				sDir[sDirLen++] = '/';
			sDir[sDirLen] = 0;
			if (!sBacktraceReady)
			{
				void*[4] frames = ?;
				backtrace(&frames[0], 4);
				sBacktraceReady = true;
			}
		}

		public static StringView Dir => StringView(&sDir[0], sDirLen);

		static void EnsureDir(StringView dir)
		{
			if (dir.IsEmpty || Directory.Exists(dir))
				return;
			String parent = scope .();
			if (Path.GetDirectoryPath(dir, parent) case .Ok && !parent.IsEmpty && parent != dir)
				EnsureDir(parent);
			Directory.CreateDirectory(dir).IgnoreError(); // best effort: Write reports a missing folder by writing nothing
		}

		/// Records the open project for the next report. Cheap when unchanged (called every frame).
		public static void SetProject(StringView path)
		{
			if (sProjectCopy == path)
				return;
			sProjectCopy.Set(path);
			int32 n = 0;
			for (let c in path.RawChars)
			{
				if (n >= sProject.Count - 1)
					break;
				sProject[n++] = c;
			}
			// Publish the length last: a signal in the middle sees the old length or the new text.
			sProject[n] = 0;
			sProjectLen = n;
		}

		public static StringView SignalName(int32 sig)
		{
			switch (sig)
			{
			case 4: return "SIGILL (illegal instruction)";
			case 5: return "SIGTRAP (break)";
			case 6: return "SIGABRT (abort)";
			case 7: return "SIGBUS (bus error)";
			case 8: return "SIGFPE (arithmetic error)";
			case 11: return "SIGSEGV (invalid memory access)";
			case 0: return "none (Beef runtime error)";
			default: return "signal";
			}
		}

		/// A fixed-size line buffer (no allocation).
		struct Line
		{
			public char8[512] Buf;
			public int32 Len;

			public void Add(StringView s) mut
			{
				for (let c in s.RawChars)
				{
					if (Len >= Buf.Count)
						return;
					Buf[Len++] = c;
				}
			}

			public void Add(char8 c) mut
			{
				if (Len < Buf.Count)
					Buf[Len++] = c;
			}

			public void Hex(uint64 v, int digits = 16) mut
			{
				for (int i = digits - 1; i >= 0; i--)
				{
					let nib = (int)((v >> (i * 4)) & 0xF);
					Add((nib < 10) ? (char8)('0' + nib) : (char8)('a' + nib - 10));
				}
			}

			public void Dec(int64 value, int minDigits = 1) mut
			{
				var v = value;
				if (v < 0)
				{
					Add('-');
					v = -v;
				}
				char8[24] tmp = default;
				int n = 0;
				repeat
				{
					tmp[n++] = (char8)('0' + (v % 10));
					v /= 10;
				}
				while (v > 0 && n < 24);
				while (n < minDigits && n < 24)
					tmp[n++] = '0';
				while (n > 0)
					Add(tmp[--n]);
			}

			public void Flush(int32 fd) mut
			{
				if (fd >= 0 && Len > 0)
					write(fd, &Buf[0], Len);
				Len = 0;
			}
		}

		/// Civil date from days since 1970-01-01 (Howard Hinnant's algorithm): no localtime_r,
		/// whose time-zone lock is not safe inside a signal.
		static void CivilFromDays(int64 z0, out int64 y, out int32 m, out int32 d)
		{
			let z = z0 + 719468;
			let era = ((z >= 0) ? z : z - 146096) / 146097;
			let doe = z - era * 146097;
			let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
			y = yoe + era * 400;
			let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
			let mp = (5 * doy + 2) / 153;
			d = (int32)(doy - (153 * mp + 2) / 5 + 1);
			m = (int32)((mp < 10) ? mp + 3 : mp - 9);
			if (m <= 2)
				y++;
		}

		/// Writes one report. `sig` is the signal (0 for a Beef runtime error), `faultAddr` the
		/// siginfo address, `ucontext` the handler's third argument (x86-64 registers; null skips
		/// them), `message` a Beef fatal error text, `extra` appends lines to the open file (the
		/// editor's recovery flush). The report path (NUL-terminated) goes to `outPath`; returns its
		/// length, or 0 when the file could not be created. Safe inside a signal handler.
		public static int32 Write(int32 sig, int32 sigCode, void* faultAddr, void* ucontext, StringView version, StringView message,
			char8* outPath, int32 outPathSize, function void(int32 fd) extra = null)
		{
			TimeSpec ts = default;
			clock_gettime(0 /* CLOCK_REALTIME */, &ts);
			let secs = (int64)ts.tv_sec;
			int64 year;
			int32 month, day;
			CivilFromDays(secs / 86400, out year, out month, out day);
			let sod = secs % 86400;
			let pid = getpid();

			// Path: <dir>visualbeef-crash-YYYY-MM-DD-HHMMSS-<pid>.log
			Line name = default;
			name.Add(FilePrefix);
			name.Dec(year, 4); name.Add('-'); name.Dec(month, 2); name.Add('-'); name.Dec(day, 2); name.Add('-');
			name.Dec(sod / 3600, 2); name.Dec((sod / 60) % 60, 2); name.Dec(sod % 60, 2);
			name.Add('-'); name.Dec(pid);
			name.Add(".log");
			int32 len = 0;
			for (int32 i < sDirLen)
			{
				if (len >= outPathSize - 1)
					break;
				outPath[len++] = sDir[i];
			}
			for (int32 i < name.Len)
			{
				if (len >= outPathSize - 1)
					break;
				outPath[len++] = name.Buf[i];
			}
			outPath[len] = 0;
			// O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644
			let fd = open(outPath, 0x1 | 0x40 | 0x200 | 0x80000, 0x1A4);
			if (fd < 0)
			{
				outPath[0] = 0;
				return 0;
			}

			Line t = default;
			t.Add("VisualBeef crash report\n");
			t.Add("version  VisualBeef "); t.Add(version); t.Add(" (Linux x86-64)\n");
			t.Add("time     "); t.Dec(year, 4); t.Add('-'); t.Dec(month, 2); t.Add('-'); t.Dec(day, 2); t.Add(' ');
			t.Dec(sod / 3600, 2); t.Add(':'); t.Dec((sod / 60) % 60, 2); t.Add(':'); t.Dec(sod % 60, 2); t.Add(" UTC\n");
			t.Add("process  "); t.Dec(pid); t.Add("  thread "); t.Dec(gettid()); t.Add('\n');
			t.Add("signal   "); t.Dec(sig); t.Add(' '); t.Add(SignalName(sig));
			if (sig != 0)
			{
				t.Add("  code "); t.Dec(sigCode);
			}
			t.Add('\n');
			if (sig == 11 || sig == 7 || sig == 8 || sig == 4)
			{
				t.Add("address  0x"); t.Hex((uint64)(int)faultAddr); t.Add('\n');
			}
			t.Add("project  ");
			t.Flush(fd);
			let projectLen = sProjectLen;
			if (projectLen > 0)
				write(fd, &sProject[0], projectLen);
			else
				t.Add("(none open)");
			t.Add('\n');
			t.Flush(fd);
			if (!message.IsEmpty)
			{
				t.Add("fatal    Beef runtime error: ");
				t.Flush(fd);
				write(fd, message.Ptr, message.Length);
				t.Add('\n');
				t.Flush(fd);
			}

			if (ucontext != null)
			{
				// x86-64 glibc ucontext_t: uc_flags, uc_link, uc_stack (24 bytes), then gregs[23].
				let gregs = (uint64*)((uint8*)ucontext + 40);
				t.Add("\nregisters\n");
				t.Flush(fd);
				StringView[17] names = .("RAX", "RBX", "RCX", "RDX", "RSI", "RDI", "RBP", "RSP", "R8 ", "R9 ", "R10", "R11", "R12", "R13", "R14", "R15", "RIP");
				int32[17] index = .(13, 11, 14, 12, 9, 8, 10, 15, 0, 1, 2, 3, 4, 5, 6, 7, 16);
				for (int i < 17)
				{
					t.Add("  "); t.Add(names[i]); t.Add(" 0x"); t.Hex(gregs[index[i]]);
					if (i % 3 == 2 || i == 16)
					{
						t.Add('\n');
						t.Flush(fd);
					}
				}
				t.Add("  EFLAGS 0x"); t.Hex(gregs[17], 8); t.Add('\n');
				t.Flush(fd);
			}

			t.Add("\nstack (backtrace(3); resolve with addr2line -f -C -e <binary> <offset>)\n");
			t.Flush(fd);
			void*[64] frames = ?;
			let n = backtrace(&frames[0], 64);
			if (n > 0)
				backtrace_symbols_fd(&frames[0], n, fd);
			if (n < 2)
			{
				// Fewer than two frames is not a stack: say so, and how to find the fault by hand.
				t.Add("stack: no frames available (backtrace returned "); t.Dec(n);
				t.Add("); resolve the fault address with addr2line\n");
				t.Flush(fd);
			}

			if (extra != null)
				extra(fd);
			fsync(fd);
			close(fd);
			return len;
		}

		/// Reports in `dir` newer than the one named in `<dir>/last-seen.txt` (by name: names sort
		/// by time): the newest goes to `outNewest` (full path) and `last-seen.txt` is updated, so a
		/// report is announced once. Returns false when there is nothing new.
		public static bool FindNewer(StringView dir, String outNewest)
		{
			if (!Directory.Exists(dir))
				return false;
			String seenPath = scope $"{dir}/last-seen.txt";
			String seen = scope .();
			if (File.ReadAllText(seenPath, seen) case .Err)
				seen.Clear();
			seen.Trim();
			String newest = scope .();
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String fname = scope .();
				entry.GetFileName(fname);
				if (!fname.StartsWith(FilePrefix) || !fname.EndsWith(".log"))
					continue;
				if (String.Compare(fname, seen, false) > 0 && String.Compare(fname, newest, false) > 0)
					newest.Set(fname);
			}
			if (newest.IsEmpty)
				return false;
			outNewest.AppendF("{}/{}", dir, newest);
			File.WriteAllText(seenPath, newest).IgnoreError(); // not recorded: the notice repeats next start, harmless
			return true;
		}

		/// Keeps the `keep` newest reports.
		public static void Prune(StringView dir, int keep)
		{
			if (!Directory.Exists(dir))
				return;
			List<String> files = scope .();
			defer { for (let f in files) delete f; }
			for (let entry in Directory.EnumerateFiles(dir))
			{
				String fname = scope .();
				entry.GetFileName(fname);
				if (fname.StartsWith(FilePrefix))
				{
					String p = new .();
					entry.GetFilePath(p);
					files.Add(p);
				}
			}
			if (files.Count <= keep)
				return;
			files.Sort(scope (a, b) => String.Compare(a, b, false));
			for (int i < files.Count - keep)
				File.Delete(files[i]).IgnoreError(); // best effort: next start retries
		}
	}
}
#endif
