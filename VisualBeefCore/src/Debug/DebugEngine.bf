using System;
using System.IO;

namespace VisualBeef.Debug
{
	/// The run states the engine reports (IDEHelper `RunState`, same order).
	enum EngineRunState : int32
	{
		NotStarted,
		Running,
		Running_ToTempBreakpoint,
		Paused,
		Breakpoint,
		DebugEval,
		DebugEval_Done,
		HotStep,
		Exception,
		Terminating,
		Terminated,
		SearchingSymSrv,
		HotResolve,
		TargetUnloaded
	}

	/// Beef's own debugger engine: the C API of `IDEHelper64.dll` from the Beef install, the same
	/// DLL and calls the Beef IDE drives (IDE/src/Debugger/DebugManager.bf in the Beef repository,
	/// MIT). Loaded at run time with LoadLibrary / GetProcAddress, so VisualBeef starts and edits
	/// without it and says clearly when debugging is not available.
	///
	/// Every export below was checked against the DLL of Beef 0.43.6 (`dumpbin /exports`) and its
	/// signature against IDEHelper/DebugManager.cpp of the 0.43.5 sources (the closest tag; there
	/// is no 0.43.6 tag). Not `Beef042Dbg64.dll`: that is the runtime's debug allocator, which a
	/// Debug build of a Beef program imports; it has no debugger in it.
	///
	/// The engine is one global per process (the DLL keeps a single `gDebugger`), so there is at
	/// most one DebugSession at a time.
	static class DebugEngine
	{
		public const String DllName = "IDEHelper64.dll";
		/// What the editor says when the DLL is missing or does not fit.
		public const String NeedBeef = "Debugging needs Beef 0.43.6 installed (it uses the debugger of the Beef IDE, IDEHelper64.dll).";

		// x64 has one calling convention; the DLL's BF_CALLTYPE (stdcall) is the same thing there.
		public function void VoidFn();
		public function void SetSymSrvOptionsFn(char8* cacheDir, char8* servers, int32 flags);
		public function void IntFn(int32 v);
		public function void BoolArgFn(bool v);
		public function bool OpenFileFn(char8* launchPath, char8* targetPath, char8* args, char8* workingDir, void* envBlock, int32 envBlockLen, bool hotSwap, uint8 openFileFlags);
		public function bool AttachFn(int32 processId, uint8 attachFlags);
		public function void GetStdHandlesFn(void** outStdIn, void** outStdOut, void** outStdErr);
		public function bool LoadDebugVisualizersFn(char8* fileName);
		public function int32 IntRetFn();
		public function char8* StrRetFn();
		public function bool BoolRetFn();
		public function void* CreateBreakpointFn(char8* fileName, int32 lineNum, int32 wantColumn, int32 instrOffset);
		public function void BreakpointFn(void* bp);
		public function int BreakpointGetAddressFn(void* bp, void** outLinkedSibling);
		public function int BreakpointGetLineNumFn(void* bp);
		public function void StepFn(bool inAssembly);
		/// `StringView Debugger_Evaluate(...)` returns a 16-byte C++ object: on Win64 that is a
		/// hidden result pointer passed first (and returned in RAX). Declared that way so the call
		/// does not depend on how a function pointer lowers a struct return.
		public function void* EvaluateFn(EvalResult* outResult, char8* expr, int32 callStackIdx, int32 cursorPos, int32 language, uint16 flags);
		public function char8* AutoLocalsFn(int32 callStackIdx, bool showRegs);
		public function char8* StackFrameInfoFn(int32 frameIdx, int* outAddr, char8** outFile, int32* outHotIdx, int32* outDefLineStart, int32* outDefLineEnd, int32* outLine, int32* outColumn, int32* outLanguage, int32* outStackSize, int8* outFlags);
		public function void SetActiveThreadFn(int32 threadId);

		[CRepr]
		public struct EvalResult
		{
			public char8* Ptr;
			public int Length;
		}

		public static VoidFn Debugger_Create;
		public static VoidFn Debugger_Delete;
		public static VoidFn IDEHelper_ProgramStart;
		public static VoidFn Targets_Create;
		public static SetSymSrvOptionsFn Debugger_SetSymSrvOptions;
		public static IntFn Debugger_SetOutputFilterFlags;
		public static BoolArgFn Debugger_SetStepOverExternalFiles;
		public static OpenFileFn Debugger_OpenFile;
		public static AttachFn Debugger_Attach;
		public static GetStdHandlesFn Debugger_GetStdHandles;
		public static LoadDebugVisualizersFn Debugger_LoadDebugVisualizers;
		public static VoidFn Debugger_Run;
		public static VoidFn Debugger_Update;
		public static IntRetFn Debugger_GetRunState;
		public static BoolRetFn Debugger_HasPendingDebugLoads;
		public static StrRetFn Debugger_PopMessage;
		public static StrRetFn Debugger_GetCurrentException;
		public static VoidFn Debugger_Continue;
		public static VoidFn Debugger_BreakAll;
		public static StepFn Debugger_StepInto;
		public static StepFn Debugger_StepOver;
		public static StepFn Debugger_StepOut;
		public static VoidFn Debugger_StopDebugging;
		public static VoidFn Debugger_Terminate;
		public static VoidFn Debugger_Detach;
		public static IntRetFn Debugger_GetProcessId;
		public static StrRetFn Debugger_GetThreadInfo;
		public static SetActiveThreadFn Debugger_SetActiveThread;
		public static CreateBreakpointFn Debugger_CreateBreakpoint;
		public static BreakpointFn Breakpoint_Delete;
		public static BreakpointFn Breakpoint_Check;
		public static BreakpointGetAddressFn Breakpoint_GetAddress;
		public static BreakpointGetLineNumFn Breakpoint_GetLineNum;
		public static EvaluateFn Debugger_Evaluate;
		public static StrRetFn Debugger_EvaluateContinue;
		public static AutoLocalsFn Debugger_GetAutoLocals;
		public static VoidFn CallStack_Update;
		public static IntRetFn CallStack_GetCount;
		public static StackFrameInfoFn CallStack_GetStackFrameInfo;

		static int sModule;
		static bool sTried;
		static bool sCreated;
		static String sError = new .() ~ delete _;
		static String sPath = new .() ~ delete _;

		/// The DLL that was loaded (or tried last).
		public static StringView DllPath => sPath;
		/// Why Load failed ("" after a successful load).
		public static StringView LoadError => sError;
		public static bool IsLoaded => sModule != 0 && sError.IsEmpty;

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int LoadLibraryExW(char16* name, void* file, uint32 flags);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* GetProcAddress(int module, char8* name);
		const uint32 LOAD_WITH_ALTERED_SEARCH_PATH = 0x00000008;
#endif

		/// Where IDEHelper64.dll is looked for, in order: next to this program (a package that
		/// carries it), `VB_BEEF_BIN`, the folder of the configured BeefBuild, the default install.
		public static void Candidates(StringView beefBuildPath, System.Collections.List<String> outPaths)
		{
			String exeDir = scope .();
			Path.GetDirectoryPath(Environment.GetExecutableFilePath(.. scope .()), exeDir).IgnoreError(); // no folder: skipped below
			if (!exeDir.IsEmpty)
				outPaths.Add(new $"{exeDir}\\{DllName}");
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_BEEF_BIN", env) case .Ok && !env.IsEmpty)
				outPaths.Add(new $"{env}\\{DllName}");
			if (!beefBuildPath.IsEmpty)
			{
				String dir = scope .();
				if (Path.GetDirectoryPath(beefBuildPath, dir) case .Ok && !dir.IsEmpty)
					outPaths.Add(new $"{dir}\\{DllName}");
			}
			outPaths.Add(new $"C:\\Program Files\\BeefLang\\bin\\{DllName}");
		}

		/// Loads the engine once (later calls return the first result). `beefBuildPath` is the
		/// editor's BeefBuild setting, whose folder holds the DLL in a normal install.
		public static bool Load(StringView beefBuildPath = default)
		{
			if (sTried)
				return IsLoaded;
			sTried = true;
#if BF_PLATFORM_WINDOWS
			System.Collections.List<String> candidates = scope .();
			defer { for (let c in candidates) delete c; }
			Candidates(beefBuildPath, candidates);
			for (let c in candidates)
			{
				if (!File.Exists(c))
					continue;
				sPath.Set(c);
				// Altered search path: the DLL's own folder is searched for its dependencies.
				sModule = LoadLibraryExW(c.ToScopedNativeWChar!(), null, LOAD_WITH_ALTERED_SEARCH_PATH);
				if (sModule != 0)
					break;
			}
			if (sModule == 0)
			{
				sError.Set(sPath.IsEmpty ? "IDEHelper64.dll was not found" : scope $"{sPath} could not be loaded");
				return false;
			}
			bool ok = true;
			mixin Bind(var target, String name)
			{
				let p = GetProcAddress(sModule, name);
				if (p == null)
				{
					ok = false;
					sError.AppendF("{}{}", sError.IsEmpty ? "missing exports: " : ", ", name);
				}
				target = (.)p;
			}
			Bind!(Debugger_Create, "Debugger_Create");
			Bind!(Debugger_Delete, "Debugger_Delete");
			Bind!(IDEHelper_ProgramStart, "IDEHelper_ProgramStart");
			Bind!(Targets_Create, "Targets_Create");
			Bind!(Debugger_SetSymSrvOptions, "Debugger_SetSymSrvOptions");
			Bind!(Debugger_SetOutputFilterFlags, "Debugger_SetOutputFilterFlags");
			Bind!(Debugger_SetStepOverExternalFiles, "Debugger_SetStepOverExternalFiles");
			Bind!(Debugger_OpenFile, "Debugger_OpenFile");
			Bind!(Debugger_Attach, "Debugger_Attach");
			Bind!(Debugger_GetStdHandles, "Debugger_GetStdHandles");
			Bind!(Debugger_LoadDebugVisualizers, "Debugger_LoadDebugVisualizers");
			Bind!(Debugger_Run, "Debugger_Run");
			Bind!(Debugger_Update, "Debugger_Update");
			Bind!(Debugger_GetRunState, "Debugger_GetRunState");
			Bind!(Debugger_HasPendingDebugLoads, "Debugger_HasPendingDebugLoads");
			Bind!(Debugger_PopMessage, "Debugger_PopMessage");
			Bind!(Debugger_GetCurrentException, "Debugger_GetCurrentException");
			Bind!(Debugger_Continue, "Debugger_Continue");
			Bind!(Debugger_BreakAll, "Debugger_BreakAll");
			Bind!(Debugger_StepInto, "Debugger_StepInto");
			Bind!(Debugger_StepOver, "Debugger_StepOver");
			Bind!(Debugger_StepOut, "Debugger_StepOut");
			Bind!(Debugger_StopDebugging, "Debugger_StopDebugging");
			Bind!(Debugger_Terminate, "Debugger_Terminate");
			Bind!(Debugger_Detach, "Debugger_Detach");
			Bind!(Debugger_GetProcessId, "Debugger_GetProcessId");
			Bind!(Debugger_GetThreadInfo, "Debugger_GetThreadInfo");
			Bind!(Debugger_SetActiveThread, "Debugger_SetActiveThread");
			Bind!(Debugger_CreateBreakpoint, "Debugger_CreateBreakpoint");
			Bind!(Breakpoint_Delete, "Breakpoint_Delete");
			Bind!(Breakpoint_Check, "Breakpoint_Check");
			Bind!(Breakpoint_GetAddress, "Breakpoint_GetAddress");
			Bind!(Breakpoint_GetLineNum, "Breakpoint_GetLineNum");
			Bind!(Debugger_Evaluate, "Debugger_Evaluate");
			Bind!(Debugger_EvaluateContinue, "Debugger_EvaluateContinue");
			Bind!(Debugger_GetAutoLocals, "Debugger_GetAutoLocals");
			Bind!(CallStack_Update, "CallStack_Update");
			Bind!(CallStack_GetCount, "CallStack_GetCount");
			Bind!(CallStack_GetStackFrameInfo, "CallStack_GetStackFrameInfo");
			if (!ok)
				return false;
			InstallReadHook();
			return true;
#else
			sError.Set("the debugger is only available on Windows");
			return false;
#endif
		}

		// ------------------------------------------------------------ images the engine must not read

		/// The engine reads every module of the debugged process from its file, for symbols and
		/// unwind data. Beef 0.43.6's reader crashes (an access violation on the engine's thread,
		/// which ends the editor) on some protected executables: a 457 MB game executable with
		/// a protector's section layout does it every time; reproduced without the game by mapping
		/// the file into a stand-in process (`VisualBeefTests attachprobe`).
		/// For an image listed here the engine reads a stripped copy of its headers instead of the
		/// file: the same image base and size, no sections and no data directories (no exports,
		/// exception data or debug record), then end of file. The module is known to the engine
		/// (addresses inside it are attributed to it, frames in it have no names) and nothing in it
		/// is parsed. Other modules (the mod DLL with its symbols) are read as usual.
		/// Done by pointing the engine DLL's import of kernel32 ReadFile (its IAT entry, in this
		/// process only) at HookReadFile.
		const int MaxSkip = 4;
		const int HeadSize = 4096;
		static char16[MaxSkip][1024] sSkip;
		static int[MaxSkip] sSkipLen;
		static uint8[MaxSkip][HeadSize] sSkipHead;
		static int sSkipCount;
		/// Handles of open skipped images, found at their first read (slot + 1; 0 = free).
		static void*[16] sSkipHandles;
		static int[16] sSkipHandleSlot;
		/// How many reads were served from a stripped copy (since the last ClearSkippedImages).
		public static int SkippedImages;

		public static void ClearSkippedImages()
		{
			sSkipCount = 0;
			SkippedImages = 0;
			for (int i < 16)
				sSkipHandles[i] = null;
		}

		/// Adds an image (full path) the engine reads as stripped headers only. False when its
		/// headers cannot be read (then it is not listed).
		public static bool SkipImage(StringView path)
		{
			if (sSkipCount >= MaxSkip)
				return false;
			let k = sSkipCount;
			uint8* head = &sSkipHead[k];
			Internal.MemSet(head, 0, HeadSize);
			{
				FileStream fs = scope .();
				if (fs.Open(path, .Read, .ReadWrite) case .Err)
					return false;
				if (!(fs.TryRead(.(head, HeadSize)) case .Ok(let got)) || got < 512)
					return false;
			}
			if (*(uint16*)head != 0x5A4D)
				return false;
			int32 pe = *(int32*)(head + 0x3C);
			if (pe < 0 || pe + 24 + 240 > HeadSize || *(uint32*)(head + pe) != 0x00004550)
				return false;
			uint8* fileHdr = head + pe + 4;
			let optSize = *(uint16*)(fileHdr + 16);
			uint8* opt = head + pe + 24;
			let magic = *(uint16*)opt;
			int dirs = (magic == 0x20B) ? 112 : 96;
			uint32 numDirs = *(uint32*)(opt + dirs - 4);
			// No sections, no COFF symbols, every data directory empty; the section table bytes are cleared.
			*(uint16*)(fileHdr + 2) = 0;
			*(uint32*)(fileHdr + 8) = 0;
			*(uint32*)(fileHdr + 12) = 0;
			for (uint32 d < Math.Min(numDirs, 16))
				*(uint64*)(opt + dirs + d * 8) = 0;
			int secTable = pe + 24 + optSize;
			if (secTable < HeadSize)
				Internal.MemSet(head + secTable, 0, HeadSize - secTable);
			let w = path.ToScopedNativeWChar!();
			int n = 0;
			while (w[n] != 0 && n < 1023)
			{
				char16 c = (char16)w[n];
				if (c == '/')
					c = '\\';
				sSkip[k][n] = c;
				n++;
			}
			sSkip[k][n] = 0;
			sSkipLen[k] = n;
			sSkipCount++;
			return true;
		}

#if BF_PLATFORM_WINDOWS
		public function int32 ReadFileFn(void* h, void* buf, uint32 n, uint32* read, void* overlapped);
		static ReadFileFn sRealReadFile;

		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 SetFilePointerEx(void* h, int64 dist, int64* newPos, uint32 method);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetFinalPathNameByHandleW(void* h, char16* path, uint32 len, uint32 flags);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 VirtualProtect(void* addr, uint size, uint32 newProtect, uint32* oldProtect);

		static char16 Lower(char16 c) => (c >= 'A' && c <= 'Z') ? (char16)(c + 32) : c;

		/// The skipped image whose path `path` (a final path, maybe with the long-path prefix) ends with, or -1.
		static int SkipSlot(char16* path, int len)
		{
			for (int k < sSkipCount)
			{
				let sl = sSkipLen[k];
				if (sl == 0 || sl > len)
					continue;
				bool same = true;
				for (int i < sl)
				{
					if (Lower(path[len - sl + i]) != Lower(sSkip[k][i]))
					{
						same = false;
						break;
					}
				}
				if (same)
					return k;
			}
			return -1;
		}

		/// Runs on the engine's own thread: no allocation, stack buffers only.
		static int32 HookReadFile(void* h, void* buf, uint32 n, uint32* read, void* overlapped)
		{
			if (sSkipCount > 0 && overlapped == null)
			{
				int64 pos = -1;
				if (SetFilePointerEx(h, 0, &pos, 1 /* FILE_CURRENT */) != 0)
				{
					int slot = -1;
					int known = -1;
					for (int i < 16)
						if (sSkipHandles[i] == h)
							known = i;
					if (pos == 0)
					{
						// A file read from its start: find out whether it is a skipped image.
						char16[1024] path = ?;
						let len = GetFinalPathNameByHandleW(h, &path, 1024, 0);
						if (len > 0 && len < 1024)
							slot = SkipSlot(&path, (int)len);
						if (slot < 0 && known >= 0)
							sSkipHandles[known] = null; // a reused handle value
						else if (slot >= 0 && known < 0)
						{
							for (int i < 16)
							{
								if (sSkipHandles[i] == null)
								{
									sSkipHandles[i] = h;
									sSkipHandleSlot[i] = slot;
									break;
								}
							}
						}
					}
					else if (known >= 0)
						slot = sSkipHandleSlot[known];
					if (slot >= 0)
					{
						// Serve the stripped headers, then end of file; move the file pointer the same way.
						uint32 got = 0;
						if (pos < HeadSize)
						{
							got = (uint32)Math.Min((int64)n, HeadSize - pos);
							Internal.MemCpy(buf, &sSkipHead[slot][(int)pos], got);
							SetFilePointerEx(h, pos + got, null, 0 /* FILE_BEGIN */);
						}
						if (read != null)
							*read = got;
						SkippedImages++;
						return 1;
					}
				}
			}
			return sRealReadFile(h, buf, n, read, overlapped);
		}

		/// Points the engine DLL's import of kernel32 ReadFile at HookReadFile.
		static void InstallReadHook()
		{
			if (sRealReadFile != null)
				return;
			uint8* b = (uint8*)(void*)sModule;
			int32 lfanew = *(int32*)(b + 0x3C);
			uint8* opt = b + lfanew + 24;
			if (*(uint16*)opt != 0x20B)
				return;
			uint32 importRva = *(uint32*)(opt + 112 + 8);
			if (importRva == 0)
				return;
			for (uint8* desc = b + importRva; *(uint32*)(desc + 12) != 0; desc += 20)
			{
				StringView dll = .((char8*)(b + *(uint32*)(desc + 12)));
				if (!dll.Equals("KERNEL32.dll", true))
					continue;
				uint32 nameRva = *(uint32*)desc;
				uint64* names = (uint64*)(b + ((nameRva != 0) ? nameRva : *(uint32*)(desc + 16)));
				uint64* slots = (uint64*)(b + *(uint32*)(desc + 16));
				for (int i = 0; names[i] != 0; i++)
				{
					if ((names[i] >> 63) != 0)
						continue;
					StringView fn = .((char8*)(b + (uint32)(names[i] & 0x7FFFFFFF) + 2));
					if (fn != "ReadFile")
						continue;
					uint32 old = 0;
					if (VirtualProtect(&slots[i], 8, 0x04 /* PAGE_READWRITE */, &old) == 0)
						return;
					sRealReadFile = (ReadFileFn)(void*)(int)slots[i];
					ReadFileFn hook = => HookReadFile;
					slots[i] = (uint64)(int)(void*)hook;
					VirtualProtect(&slots[i], 8, old, &old);
					return;
				}
			}
		}
#else
		static void InstallReadHook() {}
#endif

		/// Creates the engine's global debugger once (Debugger_Create; the IDE does it at start).
		/// Symbol servers are switched off: a session never goes to the network.
		public static bool EnsureCreated(StringView beefBuildPath = default)
		{
			if (!Load(beefBuildPath))
				return false;
			if (sCreated)
				return true;
			sCreated = true;
			IDEHelper_ProgramStart();
			// The CPU description the debugger disassembles and unwinds with (gX86Target); the IDE
			// creates it with its compiler, before its debugger. Without it Debugger_Create crashes.
			Targets_Create();
			Debugger_Create();
			// No symbol servers (an empty list: a session never goes to the network). The "disable"
			// flag cannot be used: it also stops the engine from reading the PDB next to the
			// program. The cache folder is only searched, never filled without servers.
			String cache = scope .();
			Path.GetTempPath(cache).IgnoreError(); // no temp folder: a relative name, still never written
			cache.Append("VisualBeef-symcache");
			Debugger_SetSymSrvOptions(cache, "", 0);
			// Keep process-exit messages, drop module / thread / symbol chatter
			// (BfOutputFilterFlags: ModuleLoad 1, ModuleUnload 2, ThreadCreate 8, ThreadExit 0x10, SymbolLoad 0x20).
			Debugger_SetOutputFilterFlags(0x01 | 0x02 | 0x08 | 0x10 | 0x20);
			Debugger_SetStepOverExternalFiles(true);
			// Display rules for corlib types (String, List, Dictionary...): BeefDbgVis.toml next to the DLL.
			String dir = scope .();
			if (Path.GetDirectoryPath(sPath, dir) case .Ok)
			{
				let vis = scope $"{dir}\\BeefDbgVis.toml";
				if (File.Exists(vis))
					Debugger_LoadDebugVisualizers(vis);
			}
			return true;
		}

		/// Deletes the engine's global debugger (at program exit, with no session running).
		public static void Shutdown()
		{
			if (!sCreated)
				return;
			sCreated = false;
			Debugger_Delete();
		}
	}
}
