using System;
using System.Collections;
using System.IO;

namespace VisualBeef.Debug
{
	/// A running process the debugger can attach to (Debug > Attach to game...).
	class GameProcess
	{
		public int32 ProcessId;
		/// "HogwartsLegacy.exe".
		public String ExeName = new .() ~ delete _;
		/// Full paths of the DLLs loaded from a UMP mods folder (`...\mods\<game>\<id>\X.dll`).
		public List<String> Mods = new .() ~ DeleteContainerAndItems!(_);
	}

	/// The symbol file a DLL or EXE names in its debug directory (the CodeView record the linker
	/// writes: the PDB's full path at build time, its GUID and age). The debugger engine reads the
	/// PDB from that path, so a mod DLL copied into the launcher's mods folder still finds the PDB
	/// next to its build output.
	class SymbolInfo
	{
		public String PdbPath = new .() ~ delete _;
		public Guid Signature;
		public uint32 Age;

		public bool SameBuild(SymbolInfo other) => other != null && Signature == other.Signature && Age == other.Age;

		/// Reads the CodeView (RSDS) record of a PE file on disk; false when there is none. Reads
		/// only the headers and the debug directory (a game executable can be hundreds of MB).
		public bool Read(StringView pePath)
		{
			PdbPath.Clear();
			FileStream fs = scope .();
			if (fs.Open(pePath, .Read, .ReadWrite) case .Err)
				return false;
			bool ReadAt(int64 pos, Span<uint8> outData)
			{
				if (fs.Seek(pos) case .Err)
					return false;
				if (fs.TryRead(outData) case .Ok(let got))
					return got == outData.Length;
				return false;
			}
			uint8[4096] head = ?;
			let fileLen = fs.Length;
			int Len = (int)Math.Min(fileLen, 4096);
			if (Len < 0x40 || !ReadAt(0, .(&head, Len)))
				return false;
			uint16 U16(int at) => (at + 2 <= Len) ? *(uint16*)&head[at] : 0;
			uint32 U32(int at) => (at + 4 <= Len) ? *(uint32*)&head[at] : 0;
			if (U16(0) != 0x5A4D) // "MZ"
				return false;
			int pe = (int)U32(0x3C);
			if (U32(pe) != 0x00004550) // "PE" and two zero bytes
				return false;
			int numSections = U16(pe + 6);
			int optSize = U16(pe + 20);
			int opt = pe + 24;
			let magic = U16(opt);
			// The data directories: PE32+ (0x20B) at 112, PE32 at 96; debug is entry 6.
			int dirs = opt + ((magic == 0x20B) ? 112 : 96);
			uint32 debugRva = U32(dirs + 6 * 8);
			uint32 debugSize = U32(dirs + 6 * 8 + 4);
			if (debugRva == 0 || debugSize == 0 || debugSize > 28 * 64)
				return false;
			int sections = opt + optSize;
			int64 RvaToOffset(uint32 rva)
			{
				for (int i < numSections)
				{
					int sec = sections + i * 40;
					uint32 va = U32(sec + 12);
					uint32 rawSize = U32(sec + 16);
					uint32 virtSize = Math.Max(U32(sec + 8), rawSize);
					uint32 raw = U32(sec + 20);
					if (rva >= va && rva < va + virtSize)
						return (int64)(rva - va + raw);
				}
				return -1;
			}
			let dbgOff = RvaToOffset(debugRva);
			if (dbgOff < 0)
				return false;
			uint8[28 * 64] dir = ?;
			if (!ReadAt(dbgOff, .(&dir, (int)debugSize)))
				return false;
			for (int e = 0; e + 28 <= (int)debugSize; e += 28)
			{
				let type = *(uint32*)&dir[e + 12];
				let size = *(uint32*)&dir[e + 16];
				let ptr = *(uint32*)&dir[e + 24];
				if (type != 2 /* CODEVIEW */ || size < 24 || size > 4096 || (int64)ptr + size > fileLen)
					continue;
				uint8[4096] cv = ?;
				if (!ReadAt(ptr, .(&cv, (int)size)))
					continue;
				if (*(uint32*)&cv[0] != 0x53445352) // "RSDS"
					continue;
				Internal.MemCpy(&Signature, &cv[4], 16);
				Age = *(uint32*)&cv[20];
				int p = 24;
				while (p < (int)size && cv[p] != 0)
					PdbPath.Append((char8)cv[p++]);
				return !PdbPath.IsEmpty;
			}
			return false;
		}
	}

	/// Finds the processes a visual mod can be debugged in: the ones with the UMP runtime
	/// (`UMPRuntime.dll`) loaded, by listing each process's modules with the Win32 tool help
	/// snapshot (no file system scan).
	static class GameProcesses
	{
		public const String RuntimeModule = "UMPRuntime.dll";

#if BF_PLATFORM_WINDOWS
		[CRepr]
		struct PROCESSENTRY32W
		{
			public uint32 dwSize;
			public uint32 cntUsage;
			public uint32 th32ProcessID;
			public uint th32DefaultHeapID;
			public uint32 th32ModuleID;
			public uint32 cntThreads;
			public uint32 th32ParentProcessID;
			public int32 pcPriClassBase;
			public uint32 dwFlags;
			public char16[260] szExeFile;
		}

		[CRepr]
		struct MODULEENTRY32W
		{
			public uint32 dwSize;
			public uint32 th32ModuleID;
			public uint32 th32ProcessID;
			public uint32 GlblcntUsage;
			public uint32 ProccntUsage;
			public uint8* modBaseAddr;
			public uint32 modBaseSize;
			public void* hModule;
			public char16[256] szModule;
			public char16[260] szExePath;
		}

		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* CreateToolhelp32Snapshot(uint32 flags, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Process32FirstW(void* snap, PROCESSENTRY32W* entry);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Process32NextW(void* snap, PROCESSENTRY32W* entry);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Module32FirstW(void* snap, MODULEENTRY32W* entry);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 Module32NextW(void* snap, MODULEENTRY32W* entry);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CloseHandle(void* h);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* OpenProcess(uint32 access, int32 inherit, uint32 pid);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 WaitForSingleObject(void* h, uint32 ms);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 CheckRemoteDebuggerPresent(void* process, int32* present);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetLastError();
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern uint32 GetCurrentProcessId();

		const uint32 TH32CS_SNAPPROCESS = 0x2;
		const uint32 TH32CS_SNAPMODULE = 0x8;
		const uint32 PROCESS_ALL_ACCESS = 0x1FFFFF;
		const uint32 PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
		const uint32 SYNCHRONIZE = 0x00100000;
		static void* INVALID => (void*)(int)(-1);

		static void Wide(char16* w, int max, String outText)
		{
			int n = 0;
			while (n < max && w[n] != 0)
				n++;
			System.Text.UTF16.Decode(Span<char16>(w, n), outText);
		}
#endif

		/// Every process with `moduleName` loaded (the UMP runtime by default), sorted by name.
		public static void Find(List<GameProcess> outList, StringView moduleName = RuntimeModule)
		{
#if BF_PLATFORM_WINDOWS
			let snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
			if (snap == INVALID || snap == null)
				return;
			defer CloseHandle(snap);
			let self = GetCurrentProcessId();
			PROCESSENTRY32W pe = default;
			pe.dwSize = sizeof(PROCESSENTRY32W);
			if (Process32FirstW(snap, &pe) == 0)
				return;
			repeat
			{
				let pid = pe.th32ProcessID;
				if (pid <= 4 || pid == self)
					continue;
				List<String> modules = scope .();
				defer { ClearAndDeleteItems!(modules); }
				if (!Modules((int32)pid, modules))
					continue;
				bool has = false;
				for (let m in modules)
					if (FileNameIs(m, moduleName))
						has = true;
				if (!has)
					continue;
				let gp = new GameProcess();
				gp.ProcessId = (int32)pid;
				Wide(&pe.szExeFile, 260, gp.ExeName);
				for (let m in modules)
					if (IsModPath(m))
						gp.Mods.Add(new String(m));
				outList.Add(gp);
			}
			while (Process32NextW(snap, &pe) != 0);
			outList.Sort(scope (a, b) => a.ExeName.CompareTo(b.ExeName, true));
#endif
		}

		/// Full paths of the modules (EXE and DLLs) loaded in a process; false when it cannot be read
		/// (access denied, a 32-bit process, the process ended).
		public static bool Modules(int32 pid, List<String> outPaths)
		{
#if BF_PLATFORM_WINDOWS
			let snap = CreateToolhelp32Snapshot(TH32CS_SNAPMODULE, (uint32)pid);
			if (snap == INVALID || snap == null)
				return false;
			defer CloseHandle(snap);
			MODULEENTRY32W me = default;
			me.dwSize = sizeof(MODULEENTRY32W);
			if (Module32FirstW(snap, &me) == 0)
				return false;
			repeat
			{
				let s = new String();
				Wide(&me.szExePath, 260, s);
				outPaths.Add(s);
			}
			while (Module32NextW(snap, &me) != 0);
			return true;
#else
			return false;
#endif
		}

		/// The loaded module of `pid` whose file name is `fileName` ("HelloMod.dll"); false when none.
		public static bool FindModule(int32 pid, StringView fileName, String outPath)
		{
			List<String> modules = scope .();
			defer { ClearAndDeleteItems!(modules); }
			if (!Modules(pid, modules))
				return false;
			for (let m in modules)
			{
				if (FileNameIs(m, fileName))
				{
					outPath.Set(m);
					return true;
				}
			}
			return false;
		}

		/// A DLL loaded from a UMP mods folder (`...\mods\<game>\<id>\X.dll`).
		public static bool IsModPath(StringView path)
		{
			String lower = scope .(path);
			lower.ToLower();
			lower.Replace('/', '\\');
			return lower.EndsWith(".dll") && lower.Contains("\\mods\\");
		}

		public static bool FileNameIs(StringView path, StringView name)
		{
			if (path.Length < name.Length)
				return false;
			let tail = path.Substring(path.Length - name.Length);
			if (!tail.Equals(name, true))
				return false;
			return path.Length == name.Length || path[path.Length - name.Length - 1] == '\\' || path[path.Length - name.Length - 1] == '/';
		}

		/// True while the process exists and has not ended.
		public static bool IsRunning(int32 pid)
		{
#if BF_PLATFORM_WINDOWS
			let h = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint32)pid);
			if (h == null)
				return false;
			let r = WaitForSingleObject(h, 0);
			CloseHandle(h);
			return r == 0x102; // WAIT_TIMEOUT: still running
#else
			return false;
#endif
		}

		/// Why attaching to `pid` cannot work, checked before the engine tries (it only says
		/// "Unable to attach"); false when nothing is in the way.
		public static bool AttachBlocker(int32 pid, String outWhy)
		{
#if BF_PLATFORM_WINDOWS
			let h = OpenProcess(PROCESS_ALL_ACCESS, 0, (uint32)pid);
			if (h == null)
			{
				let err = GetLastError();
				if (err == 5)
					outWhy.AppendF("Access denied to process {}: it runs with more rights than VisualBeef (as administrator, or protected). Start VisualBeef the same way, or start the game without administrator rights.", pid);
				else if (err == 87)
					outWhy.AppendF("Process {} is not running any more.", pid);
				else
					outWhy.AppendF("Process {} cannot be opened (Windows error {}).", pid, err);
				return true;
			}
			int32 present = 0;
			CheckRemoteDebuggerPresent(h, &present);
			CloseHandle(h);
			if (present != 0)
			{
				outWhy.AppendF("Process {} already has a debugger attached (another VisualBeef, the Beef IDE or Visual Studio): detach it first.", pid);
				return true;
			}
			return false;
#else
			outWhy.Set("Attaching is only available on Windows.");
			return true;
#endif
		}
	}
}
