using System;
using System.IO;
using System.Threading;

namespace VisualBeef.Editor
{
	/// Win32 calls used by the session log and the crash handler. Declared here (not through
	/// corlib wrappers) so the crash path never allocates.
	static class Win32Raw
	{
		public const uint32 GENERIC_WRITE = 0x40000000;
		public const uint32 FILE_APPEND_DATA = 0x0004;
		public const uint32 FILE_SHARE_READ = 1;
		public const uint32 FILE_SHARE_WRITE = 2;
		public const uint32 FILE_SHARE_DELETE = 4;
		public const uint32 CREATE_ALWAYS = 2;
		public const uint32 OPEN_ALWAYS = 4;
		public const uint32 FILE_ATTRIBUTE_NORMAL = 0x80;
		public const int INVALID_HANDLE = -1;

		[CRepr]
		public struct SystemTime
		{
			public uint16 Year, Month, DayOfWeek, Day, Hour, Minute, Second, Milliseconds;
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int CreateFileW(char16* name, uint32 access, uint32 share, void* security, uint32 disposition, uint32 flags, int templateFile);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 WriteFile(int handle, void* data, uint32 count, uint32* written, void* overlapped);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 FlushFileBuffers(int handle);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 CloseHandle(int handle);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void GetLocalTime(SystemTime* time);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetCurrentProcessId();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetCurrentThreadId();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int GetCurrentProcess();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* SetUnhandledExceptionFilter(void* filter);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 GetModuleHandleExW(uint32 flags, void* address, int* outModule);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern uint32 GetModuleFileNameW(int module, char16* buf, uint32 size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* RtlLookupFunctionEntry(uint64 pc, uint64* imageBase, void* history);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* RtlVirtualUnwind(uint32 handlerType, uint64 imageBase, uint64 pc, void* functionEntry, void* context, void** handlerData, uint64* establisherFrame, void* contextPointers);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void RtlCaptureContext(void* context);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 SetThreadStackGuarantee(uint32* size);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 WideCharToMultiByte(uint32 codePage, uint32 flags, char16* wide, int32 wideLen, char8* outBytes, int32 outLen, void* defaultChar, void* usedDefault);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int LoadLibraryW(char16* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern void* GetProcAddress(int module, char8* name);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		public static extern int32 IsDebuggerPresent();
#endif // the POSIX equivalents are in PosixRaw.bf

		/// Opens a file for appending (created when missing), shared so other tools can read it.
		public static int OpenAppend(char16* path) =>
			CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

		public static int Create(char16* path) =>
			CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);

		public static void Write(int handle, StringView text)
		{
			if (handle == 0 || handle == INVALID_HANDLE || text.IsEmpty)
				return;
			uint32 written = 0;
			WriteFile(handle, text.Ptr, (uint32)text.Length, &written, null);
		}
	}

	/// A fixed-size text buffer on the stack: formatting with no allocation (crash path).
	struct RawText
	{
		public char8[2048] Buf;
		public int Len;

		public void Clear() mut { Len = 0; }

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
				Add((nib < 10) ? (char8)('0' + nib) : (char8)('A' + nib - 10));
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

		/// UTF-16 to UTF-8 without allocating.
		public void Wide(char16* w, int32 len) mut
		{
			if (len <= 0)
				return;
			let room = (int32)(Buf.Count - Len);
			if (room <= 0)
				return;
			let n = Win32Raw.WideCharToMultiByte(65001, 0, w, len, &Buf[Len], room, null, null);
			if (n > 0)
				Len += n;
		}

		public StringView GetView() mut => StringView(&Buf[0], Len);
	}

	/// The always-on session log: %LOCALAPPDATA%\VisualBeef\logs\visualbeef-<date>.log, one per
	/// day, appended by every session. Every Output Log line is mirrored into it (Notify), so a
	/// user can send the log of a session that went wrong. Writes go straight to the file (no
	/// buffering), so the lines before a crash are on disk.
	static class SessionLog
	{
		static int sHandle;
		static Monitor sLock = new .() ~ delete _;
		/// Folder for logs and crash reports, with a trailing separator, as UTF-16 (crash path).
		public static char16[520] LogDirW;
		public static int32 LogDirLen;
		public static String LogPath = new .() ~ delete _;
		public static String LogDir = new .() ~ delete _;

		public static void Open()
		{
			AppPaths.Sub("logs", LogDir);
			Win32Raw.SystemTime t = default;
			Win32Raw.GetLocalTime(&t);
			LogPath.AppendF("{}{}visualbeef-{:D4}-{:D2}-{:D2}.log", LogDir, Path.DirectorySeparatorChar, t.Year, t.Month, t.Day);
			String dirWithSep = scope .(LogDir);
			dirWithSep.Append(Path.DirectorySeparatorChar);
			let w = Utf16Text.Scoped!(dirWithSep);
			LogDirLen = 0;
			while (w[LogDirLen] != 0 && LogDirLen < LogDirW.Count - 1)
			{
				LogDirW[LogDirLen] = w[LogDirLen];
				LogDirLen++;
			}
			LogDirW[LogDirLen] = 0;
			sHandle = Win32Raw.OpenAppend(Utf16Text.Scoped!(LogPath));
			if (sHandle == Win32Raw.INVALID_HANDLE)
				sHandle = 0;
			String exe = scope .();
			Environment.GetExecutableFilePath(exe);
			String head = scope .();
			head.AppendF("\r\n==== VisualBeef session {:D4}-{:D2}-{:D2} {:D2}:{:D2}:{:D2}  pid {}  {} ====\r\n", t.Year, t.Month, t.Day, t.Hour, t.Minute, t.Second, Win32Raw.GetCurrentProcessId(), exe);
			WriteRaw(head);
			PruneOld();
		}

		/// Keeps the 30 newest session logs and 30 newest crash reports.
		static void PruneOld()
		{
			for (let prefix in StringView[2]("visualbeef-crash-", "visualbeef-2"))
			{
				System.Collections.List<String> files = scope .();
				defer { for (let f in files) delete f; }
				for (let entry in Directory.EnumerateFiles(LogDir))
				{
					String name = scope .();
					entry.GetFileName(name);
					if (name.StartsWith(prefix))
					{
						String p = new .();
						entry.GetFilePath(p);
						files.Add(p);
					}
				}
				if (files.Count <= 30)
					continue;
				files.Sort(scope (a, b) => String.Compare(a, b, true));
				for (int i < files.Count - 30)
					File.Delete(files[i]).IgnoreError(); // a log still open elsewhere stays; next start retries
			}
		}

		public static void Close()
		{
			if (sHandle != 0)
			{
				WriteRaw("==== session end ====\r\n");
				Win32Raw.CloseHandle(sHandle);
				sHandle = 0;
			}
		}

		public static int Handle => sHandle;

		public static void WriteRaw(StringView text)
		{
			Win32Raw.Write(sHandle, text);
		}

		/// One Output Log line ("[hh:mm:ss] Warning Build: text").
		public static void Line(StringView stamp, LogLevel level, StringView category, StringView text)
		{
			if (sHandle == 0)
				return;
			String line = scope .(text.Length + 48);
			line.AppendF("[{}] {,-7} {}: ", stamp, level, category);
			for (let c in text.RawChars)
			{
				if (c == '\n')
					line.Append("\r\n    ");
				else if (c != '\r')
					line.Append(c);
			}
			line.Append("\r\n");
			using (sLock.Enter())
				WriteRaw(line);
		}
	}

	/// Crash reporting. Installs an unhandled-exception filter (chained to the Beef runtime's
	/// own crash catcher) and a Beef runtime error handler (FatalError, failed asserts). On a
	/// crash it writes %LOCALAPPDATA%\VisualBeef\logs\visualbeef-crash-<date>-<time>.log with
	/// the exception, module + RVA, registers and a best-effort stack (RtlVirtualUnwind), a
	/// minidump next to it (dbghelp, when present), a line in the session log, and flushes the
	/// recovery journal (Recovery.CrashFlush).
	///
	/// Everything on the crash path uses stack buffers and raw Win32 writes: it can run on any
	/// thread, including non-Beef threads, in a process whose heap may be corrupt.
	static class CrashHandler
	{
		[CRepr]
		struct ExceptionRecord
		{
			public uint32 Code;
			public uint32 Flags;
			public ExceptionRecord* Inner;
			public void* Address;
			public uint32 NumParams;
			public uint32 Pad;
			public uint64[15] Info;
		}

		[CRepr]
		struct ExceptionPointers
		{
			public ExceptionRecord* Record;
			public uint8* Context;
		}

		[CRepr, Packed]
		struct MiniDumpExceptionInfo
		{
			public uint32 ThreadId;
			public ExceptionPointers* Pointers;
			public int32 ClientPointers;
		}

		function int32 MiniDumpWriteDumpFn(int process, uint32 pid, int file, uint32 type, MiniDumpExceptionInfo* exc, void* user, void* callback);

		static void* sPrevFilter;
		static MiniDumpWriteDumpFn sMiniDump;
		static bool sInstalled;
		static int32 sInCrash;
		/// Set when a crash report was written this session (tests, the exit path).
		public static bool Crashed;

		const int cContextSize = 0x4D0;
		const int cRip = 0xF8;
		const int cRsp = 0x98;

		public static void Install()
		{
			if (sInstalled)
				return;
			sInstalled = true;
			// Leave room for the handler when the crash is a stack overflow.
			uint32 guarantee = 64 * 1024;
			Win32Raw.SetThreadStackGuarantee(&guarantee);
			let dbghelp = Win32Raw.LoadLibraryW(Utf16Text.Scoped!("dbghelp.dll"));
			if (dbghelp != 0)
				sMiniDump = (MiniDumpWriteDumpFn)Win32Raw.GetProcAddress(dbghelp, "MiniDumpWriteDump");
			sPrevFilter = Win32Raw.SetUnhandledExceptionFilter((void*)(function int32(ExceptionPointers*))=> UnhandledFilter);
#if !BF_PLATFORM_WINDOWS
			InstallPosix();
#endif
			Runtime.AddErrorHandler(new => OnRuntimeError);
		}

		static Runtime.ErrorHandlerResult OnRuntimeError(Runtime.ErrorStage stage, Runtime.Error error)
		{
			if (stage != .PreFail)
				return .ContinueFailure;
			StringView message = default;
			if (let fatal = error as Runtime.FatalError)
				message = fatal.mError;
			else if (let assert = error as Runtime.AssertError)
				message = assert.mError;
			else
				return .ContinueFailure;
#if !BF_PLATFORM_WINDOWS
			WritePosixReport(0, 0, null, null, message);
			return .ContinueFailure;
#else
			uint8[cContextSize + 16] raw = ?;
			uint8* rawPtr = (uint8*)&raw;
			uint8* ctx = (uint8*)(void*)(((int)(void*)rawPtr + 15) & ~15);
			Win32Raw.RtlCaptureContext(ctx);
			WriteReport(null, ctx, message);
			return .ContinueFailure;
#endif
		}

		[CallingConvention(.Stdcall)]
		static int32 UnhandledFilter(ExceptionPointers* ep)
		{
			WriteReport(ep, (ep != null) ? ep.Context : null, default);
			if (sPrevFilter != null)
				return ((function [CallingConvention(.Stdcall)] int32(ExceptionPointers*))sPrevFilter)(ep);
			return 0; // EXCEPTION_CONTINUE_SEARCH
		}

		static StringView CodeName(uint32 code)
		{
			switch (code)
			{
			case 0xC0000005: return "EXCEPTION_ACCESS_VIOLATION";
			case 0xC00000FD: return "EXCEPTION_STACK_OVERFLOW";
			case 0xC0000094: return "EXCEPTION_INT_DIVIDE_BY_ZERO";
			case 0xC000001D: return "EXCEPTION_ILLEGAL_INSTRUCTION";
			case 0xC0000096: return "EXCEPTION_PRIV_INSTRUCTION";
			case 0xC0000006: return "EXCEPTION_IN_PAGE_ERROR";
			case 0xC000008C: return "EXCEPTION_ARRAY_BOUNDS_EXCEEDED";
			case 0xC0000409: return "STATUS_STACK_BUFFER_OVERRUN";
			case 0xC0000374: return "STATUS_HEAP_CORRUPTION";
			case 0x80000003: return "EXCEPTION_BREAKPOINT";
			case 0xE06D7363: return "C++ exception";
			default: return "exception";
			}
		}

		/// "module.dll+0x1234" for an address.
		static void AddModule(ref RawText t, uint64 address)
		{
			int module = 0;
			// FROM_ADDRESS | UNCHANGED_REFCOUNT
			if (Win32Raw.GetModuleHandleExW(4 | 2, (void*)(int)address, &module) == 0 || module == 0)
			{
				t.Add("?");
				return;
			}
			char16[520] name = ?;
			let n = (int32)Win32Raw.GetModuleFileNameW(module, &name[0], 520);
			int32 start = 0;
			for (int32 i < n)
				if (name[i] == '\\' || name[i] == '/')
					start = i + 1;
			t.Wide(&name[start], n - start);
			t.Add("+0x");
			t.Hex(address - (uint64)module, 8);
		}

		static void Flush(int file, ref RawText t)
		{
			Win32Raw.Write(file, t.GetView());
			t.Clear();
		}

		static void WriteReport(ExceptionPointers* ep, uint8* context, StringView fatalMessage)
		{
			// One report per process: a second fault inside the handler must not recurse.
			if (Interlocked.Exchange(ref sInCrash, 1) != 0)
				return;
			Crashed = true;
			Win32Raw.SystemTime st = default;
			Win32Raw.GetLocalTime(&st);

			// Report path: <logs>\visualbeef-crash-YYYY-MM-DD-HHMMSS.log (and .dmp).
			char16[600] path = ?;
			int32 len = 0;
			for (int32 i < SessionLog.LogDirLen)
				path[len++] = SessionLog.LogDirW[i];
			RawText name = default;
			name.Add("visualbeef-crash-");
			name.Dec(st.Year, 4); name.Add('-'); name.Dec(st.Month, 2); name.Add('-'); name.Dec(st.Day, 2); name.Add('-');
			name.Dec(st.Hour, 2); name.Dec(st.Minute, 2); name.Dec(st.Second, 2);
			for (let c in name.GetView().RawChars)
				path[len++] = (char16)c;
			int32 stemLen = len;
			for (let c in ".log".RawChars)
				path[len++] = (char16)c;
			path[len] = 0;

			int file = Win32Raw.Create(&path[0]);
			if (file == Win32Raw.INVALID_HANDLE)
				file = 0;

			RawText t = default;
			t.Add("VisualBeef crash report\r\n");
			t.Add("time    "); t.Dec(st.Year, 4); t.Add('-'); t.Dec(st.Month, 2); t.Add('-'); t.Dec(st.Day, 2); t.Add(' ');
			t.Dec(st.Hour, 2); t.Add(':'); t.Dec(st.Minute, 2); t.Add(':'); t.Dec(st.Second, 2); t.Add("\r\n");
			t.Add("process "); t.Dec(Win32Raw.GetCurrentProcessId()); t.Add("  thread "); t.Dec(Win32Raw.GetCurrentThreadId()); t.Add("\r\n");
			if (ep != null && ep.Record != null)
			{
				let rec = ep.Record;
				t.Add("code    0x"); t.Hex(rec.Code, 8); t.Add(' '); t.Add(CodeName(rec.Code)); t.Add("\r\n");
				t.Add("address 0x"); t.Hex((uint64)(int)rec.Address); t.Add("  "); AddModule(ref t, (uint64)(int)rec.Address); t.Add("\r\n");
				if (rec.Code == 0xC0000005 && rec.NumParams >= 2)
				{
					t.Add((rec.Info[0] == 0) ? "access  read of 0x" : ((rec.Info[0] == 1) ? "access  write to 0x" : "access  execute at 0x"));
					t.Hex(rec.Info[1]);
					t.Add("\r\n");
				}
			}
			if (!fatalMessage.IsEmpty)
			{
				t.Add("fatal   Beef runtime error: ");
				Flush(file, ref t);
				// The message may be long: write it directly.
				Win32Raw.Write(file, fatalMessage);
				t.Add("\r\n");
			}
			Flush(file, ref t);

			if (context != null)
			{
				t.Add("\r\nregisters\r\n");
				StringView[17] names = .("RAX", "RCX", "RDX", "RBX", "RSP", "RBP", "RSI", "RDI", "R8 ", "R9 ", "R10", "R11", "R12", "R13", "R14", "R15", "RIP");
				for (int i < 17)
				{
					t.Add("  "); t.Add(names[i]); t.Add(" 0x");
					t.Hex(*(uint64*)(context + 0x78 + i * 8));
					if (i % 3 == 2)
						t.Add("\r\n");
				}
				t.Add("\r\n  EFLAGS 0x"); t.Hex(*(uint32*)(context + 0x44), 8); t.Add("\r\n");
				Flush(file, ref t);

				// Best-effort stack: unwind a copy of the context with the modules' unwind data.
				t.Add("\r\nstack (best effort)\r\n");
				Flush(file, ref t);
				uint8[cContextSize + 16] raw = ?;
				uint8* rawPtr = (uint8*)&raw;
				uint8* ctx = (uint8*)(void*)(((int)(void*)rawPtr + 15) & ~15);
				Internal.MemCpy(ctx, context, cContextSize);
				for (int frame < 64)
				{
					let pc = *(uint64*)(ctx + cRip);
					if (pc == 0)
						break;
					t.Add("  #"); t.Dec(frame, 2); t.Add("  0x"); t.Hex(pc); t.Add("  "); AddModule(ref t, pc); t.Add("\r\n");
					Flush(file, ref t);
					uint64 imageBase = 0;
					let fe = Win32Raw.RtlLookupFunctionEntry(pc, &imageBase, null);
					if (fe == null)
					{
						// Leaf function: the return address is at the top of the stack.
						let rsp = *(uint64*)(ctx + cRsp);
						if (rsp == 0 || (rsp & 7) != 0)
							break;
						*(uint64*)(ctx + cRip) = *(uint64*)(void*)(int)rsp;
						*(uint64*)(ctx + cRsp) = rsp + 8;
					}
					else
					{
						void* handlerData = null;
						uint64 establisher = 0;
						Win32Raw.RtlVirtualUnwind(0, imageBase, pc, fe, ctx, &handlerData, &establisher, null);
					}
					if (*(uint64*)(ctx + cRip) == pc && *(uint64*)(ctx + cRsp) == 0)
						break;
				}
			}

			// Unsaved documents first (they matter most), then the minidump.
			t.Add("\r\nrecovery journal: ");
			t.Add(Recovery.CrashFlush() ? "flushed\r\n" : "nothing to flush\r\n");
			Flush(file, ref t);

			if (sMiniDump != null && ep != null)
			{
				path[stemLen] = '.'; path[stemLen + 1] = 'd'; path[stemLen + 2] = 'm'; path[stemLen + 3] = 'p'; path[stemLen + 4] = 0;
				let dump = Win32Raw.Create(&path[0]);
				if (dump != Win32Raw.INVALID_HANDLE)
				{
					MiniDumpExceptionInfo info = default;
					info.ThreadId = Win32Raw.GetCurrentThreadId();
					info.Pointers = ep;
					info.ClientPointers = 0;
					// MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithIndirectlyReferencedMemory
					let ok = sMiniDump(Win32Raw.GetCurrentProcess(), Win32Raw.GetCurrentProcessId(), dump, 0x1000 | 0x20 | 0x40, &info, null, null);
					Win32Raw.CloseHandle(dump);
					t.Add((ok != 0) ? "minidump written next to this report (.dmp)\r\n" : "minidump failed\r\n");
					Flush(file, ref t);
				}
			}
			if (file != 0)
			{
				Win32Raw.FlushFileBuffers(file);
				Win32Raw.CloseHandle(file);
			}

			// The session log points at the report.
			RawText line = default;
			line.Add("[CRASH] report written: ");
			line.Wide(&path[0], stemLen);
			line.Add(".log\r\n");
			Win32Raw.Write(SessionLog.Handle, line.GetView());
			if (SessionLog.Handle != 0)
				Win32Raw.FlushFileBuffers(SessionLog.Handle);
		}

		/// Hidden debug switch, to check the crash report and the recovery prompt:
		/// VB_DEBUG_CRASH_TEST=1 (access violation on the UI thread), =thread (on a worker
		/// thread), =fatal (Beef Runtime.FatalError). Adding "dirty" (=dirty, =fatal-dirty, ...)
		/// first appends a comment line to the open document, so it is unsaved when the crash
		/// happens (`markDirty` is called at frame 30, the crash comes at frame 45).
		public static void MaybeCrashForTest(int frame, delegate void() markDirty)
		{
			if (frame != 30 && frame != 45)
				return;
			String v = scope .();
			if (Environment.GetEnvironmentVariable("VB_DEBUG_CRASH_TEST", v) case .Err || v.IsEmpty || v == "0")
				return;
			if (frame == 30)
			{
				if (v.Contains("dirty"))
					markDirty();
				return;
			}
			Notify.Log(.Warning, "Editor", scope $"VB_DEBUG_CRASH_TEST={v}: crashing on purpose");
			if (v.StartsWith("fatal"))
				Runtime.FatalError("VB_DEBUG_CRASH_TEST: deliberate fatal error");
			if (v.StartsWith("thread"))
			{
				Thread t = new .(new () => { CrashNow(); });
				t.Start(true);
				Thread.Sleep(5000);
				return;
			}
			CrashNow();
		}

		static int* sCrashTarget = (int*)(void*)(int)0x10;

		static void CrashNow()
		{
			*sCrashTarget = 0x5EB;
		}
	}
}
