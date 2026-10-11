#if !BF_PLATFORM_WINDOWS
using System;
using System.Threading;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Linux crash reports (docs/Linux.md > Crash reports). Installs SIGSEGV / SIGBUS / SIGILL /
	/// SIGFPE / SIGABRT handlers in front of the Beef runtime's own crash catcher. On a crash the
	/// handler writes a report with PosixCrashReport (signal, fault address, registers, the open
	/// project, the version, a backtrace(3) stack), flushes the recovery journal, puts a line in the
	/// session log, then hands the signal to the handler that was there before (the runtime prints
	/// its backtrace to stderr and the process ends with the original signal).
	extension CrashHandler
	{
		[CRepr]
		struct SigAction
		{
			public void* Handler;
			public uint64[16] Mask;
			public int32 Flags;
			public int32 Pad;
			public void* Restorer;
		}

		[CRepr]
		struct SigInfo
		{
			public int32 Signo;
			public int32 Errno;
			public int32 Code;
			public int32 Pad;
			public void* Addr;
		}

		[CLink] static extern int32 sigaction(int32 sig, SigAction* act, SigAction* old);
		[CLink] static extern int32 raise(int32 sig);

		const int32 SA_SIGINFO = 4;
		const int32 SA_ONSTACK = 0x08000000;

		static int32[5] sSignals = .(11, 7, 4, 8, 6); // SIGSEGV SIGBUS SIGILL SIGFPE SIGABRT
		static SigAction[5] sPrevActions;
		static char8[1100] sLastReport;
		static String sCrashDir = new .() ~ delete _;

		/// The folder reports go to (PosixCrashReport.ResolveDir).
		public static StringView CrashDir => sCrashDir;

		static void InstallPosix()
		{
			PosixCrashReport.ResolveDir(sCrashDir);
			PosixCrashReport.SetDir(sCrashDir);
			PosixCrashReport.Prune(sCrashDir, 30);
			for (int i < sSignals.Count)
			{
				SigAction act = default;
				act.Handler = (void*)(function void(int32, SigInfo*, void*))=> OnSignal;
				// SA_ONSTACK: the runtime gives the main thread a signal stack, so a stack overflow
				// still gets its report. The signal stays blocked while the handler runs.
				act.Flags = SA_SIGINFO | SA_ONSTACK;
				sigaction(sSignals[i], &act, &sPrevActions[i]);
			}
		}

		/// The open project for the next report (every frame; cheap when unchanged).
		public static void SetProject(StringView root) => PosixCrashReport.SetProject(root);

		static void FlushRecovery(int32 fd)
		{
			StringView line = Recovery.CrashFlush() ? "\nrecovery journal: flushed\n" : "\nrecovery journal: nothing to flush\n";
			Win32Raw.WriteFile(fd, line.Ptr, (uint32)line.Length, null, null);
		}

		static void WritePosixReport(int32 sig, int32 code, void* addr, void* ucontext, StringView message)
		{
			if (Interlocked.Exchange(ref sInCrash, 1) != 0)
				return;
			Crashed = true;
			let len = PosixCrashReport.Write(sig, code, addr, ucontext, cVersionText, message, &sLastReport[0], (int32)sLastReport.Count, => FlushRecovery);
			RawText line = default;
			if (len > 0)
			{
				line.Add("[CRASH] report written: ");
				line.Add(StringView(&sLastReport[0], len));
			}
			else
				line.Add("[CRASH] the crash report could not be written");
			line.Add("\n");
			Win32Raw.Write(SessionLog.Handle, line.GetView());
			if (SessionLog.Handle != 0)
				Win32Raw.FlushFileBuffers(SessionLog.Handle);
			// stderr too: a terminal user sees where the report is.
			Win32Raw.WriteFile(2, &line.Buf[0], (uint32)line.Len, null, null);
		}

		const String cVersionText = VisualBeefInfo.Version + "-" + VisualBeefInfo.Channel;

		static void OnSignal(int32 sig, SigInfo* info, void* ucontext)
		{
			WritePosixReport(sig, (info != null) ? info.Code : 0, (info != null) ? info.Addr : null, ucontext, default);
			// Hand the signal to the previous handler (the Beef runtime's crash catcher, or the
			// default action): put it back and raise again. The signal is blocked while this
			// handler runs, so it is delivered to that handler as soon as this one returns.
			for (int i < sSignals.Count)
				if (sSignals[i] == sig)
					sigaction(sig, &sPrevActions[i], null);
			raise(sig);
		}
	}
}
#endif
