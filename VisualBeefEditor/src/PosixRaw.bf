#if !BF_PLATFORM_WINDOWS
using System;

namespace VisualBeef.Editor
{
	/// Linux / POSIX versions of the Win32Raw calls (CrashHandler.bf), same signatures so the
	/// session log, the recovery journal and the crash path compile unchanged. File handles are
	/// file descriptors; text conversion uses stack buffers (the crash path never allocates).
	///
	/// Not available on Linux: minidumps (no dbghelp), the unhandled-exception filter (the Beef
	/// runtime's own signal handler reports the crash) and the RtlVirtualUnwind stack walk, so a
	/// crash report has the time, process and fatal message but no registers or stack.
	extension Win32Raw
	{
		const int32 O_WRONLY = 0x1;
		const int32 O_CREAT = 0x40;
		const int32 O_TRUNC = 0x200;
		const int32 O_APPEND = 0x400;
		const int32 O_CLOEXEC = 0x80000;

		[CRepr]
		struct Tm
		{
			public int32 tm_sec, tm_min, tm_hour, tm_mday, tm_mon, tm_year, tm_wday, tm_yday, tm_isdst;
			public int tm_gmtoff;
			public char8* tm_zone;
		}

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
		[CLink] static extern Tm* localtime_r(int* time, Tm* result);

		/// UTF-16 to UTF-8 into a fixed buffer; returns the bytes written (no terminator).
		static int32 Utf16ToUtf8(char16* wide, int32 wideLen, char8* outBytes, int32 outLen)
		{
			int32 n = 0;
			for (int32 i = 0; (wideLen < 0) ? (wide[i] != 0) : (i < wideLen); i++)
			{
				uint32 c = (uint32)wide[i];
				if (c >= 0xD800 && c < 0xDC00 && ((wideLen < 0) || (i + 1 < wideLen)))
				{
					uint32 lo = (uint32)wide[i + 1];
					if (lo >= 0xDC00 && lo < 0xE000)
					{
						c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
						i++;
					}
				}
				int32 need = (c < 0x80) ? 1 : ((c < 0x800) ? 2 : ((c < 0x10000) ? 3 : 4));
				if (n + need > outLen)
					break;
				switch (need)
				{
				case 1:
					outBytes[n++] = (char8)c;
				case 2:
					outBytes[n++] = (char8)(0xC0 | (c >> 6));
					outBytes[n++] = (char8)(0x80 | (c & 0x3F));
				case 3:
					outBytes[n++] = (char8)(0xE0 | (c >> 12));
					outBytes[n++] = (char8)(0x80 | ((c >> 6) & 0x3F));
					outBytes[n++] = (char8)(0x80 | (c & 0x3F));
				default:
					outBytes[n++] = (char8)(0xF0 | (c >> 18));
					outBytes[n++] = (char8)(0x80 | ((c >> 12) & 0x3F));
					outBytes[n++] = (char8)(0x80 | ((c >> 6) & 0x3F));
					outBytes[n++] = (char8)(0x80 | (c & 0x3F));
				}
			}
			return n;
		}

		/// `share` and FILE_FLAG_DELETE_ON_CLOSE have no POSIX meaning: the recovery
		/// session.lock stays on disk after a crash and a running session cannot hold
		/// another editor off its folder (docs/Linux.md, known gaps).
		public static int CreateFileW(char16* name, uint32 access, uint32 share, void* security, uint32 disposition, uint32 flags, int templateFile)
		{
			char8[2048] path = ?;
			let len = Utf16ToUtf8(name, -1, &path[0], (int32)path.Count - 1);
			path[len] = 0;
			int32 oflags = O_WRONLY | O_CREAT | O_CLOEXEC;
			if ((access & FILE_APPEND_DATA) != 0)
				oflags |= O_APPEND;
			if (disposition == CREATE_ALWAYS)
				oflags |= O_TRUNC;
			let fd = open(&path[0], oflags, 0x1A4 /* 0644 */);
			return (fd < 0) ? INVALID_HANDLE : (int)fd;
		}

		public static int32 WriteFile(int handle, void* data, uint32 count, uint32* written, void* overlapped)
		{
			let n = write((int32)handle, data, (int)count);
			if (written != null)
				*written = (n < 0) ? 0 : (uint32)n;
			return (n < 0) ? 0 : 1;
		}

		public static int32 FlushFileBuffers(int handle) => (fsync((int32)handle) == 0) ? 1 : 0;
		public static int32 CloseHandle(int handle) => (close((int32)handle) == 0) ? 1 : 0;

		public static void GetLocalTime(SystemTime* time)
		{
			TimeSpec ts = default;
			clock_gettime(0 /* CLOCK_REALTIME */, &ts);
			int secs = ts.tv_sec;
			Tm tm = default;
			localtime_r(&secs, &tm);
			time.Year = (uint16)(tm.tm_year + 1900);
			time.Month = (uint16)(tm.tm_mon + 1);
			time.DayOfWeek = (uint16)tm.tm_wday;
			time.Day = (uint16)tm.tm_mday;
			time.Hour = (uint16)tm.tm_hour;
			time.Minute = (uint16)tm.tm_min;
			time.Second = (uint16)tm.tm_sec;
			time.Milliseconds = (uint16)(ts.tv_nsec / 1000000);
		}

		public static uint32 GetCurrentProcessId() => (uint32)getpid();
		public static uint32 GetCurrentThreadId() => (uint32)gettid();
		public static int GetCurrentProcess() => 0;
		public static void* SetUnhandledExceptionFilter(void* filter) => null;
		public static int32 GetModuleHandleExW(uint32 flags, void* address, int* outModule) { *outModule = 0; return 0; }
		public static uint32 GetModuleFileNameW(int module, char16* buf, uint32 size) => 0;
		public static void* RtlLookupFunctionEntry(uint64 pc, uint64* imageBase, void* history) => null;
		public static void* RtlVirtualUnwind(uint32 handlerType, uint64 imageBase, uint64 pc, void* functionEntry, void* context, void** handlerData, uint64* establisherFrame, void* contextPointers) => null;
		/// No register capture: a zeroed context makes the report skip the stack walk (pc == 0).
		public static void RtlCaptureContext(void* context) => Internal.MemSet(context, 0, 0x4D0);
		public static int32 SetThreadStackGuarantee(uint32* size) => 1;
		public static int32 WideCharToMultiByte(uint32 codePage, uint32 flags, char16* wide, int32 wideLen, char8* outBytes, int32 outLen, void* defaultChar, void* usedDefault) =>
			Utf16ToUtf8(wide, wideLen, outBytes, outLen);
		public static int LoadLibraryW(char16* name) => 0;
		public static void* GetProcAddress(int module, char8* name) => null;
		public static int32 IsDebuggerPresent() => 0;
	}
}
#endif
