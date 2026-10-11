using System;
using System.IO;
using System.Collections;
using ImGui;
using VisualBeef.Document;

namespace VisualBeef.Editor
{
	/// Host asserts (IM_ASSERT in the host's ImGui, SDL's own). The host never aborts and never
	/// shows a dialog: it calls OnAssert once per distinct site and returns. Each one becomes an
	/// `[ASSERT] <expr> at <file>:<line>` Output Log line (and session log line). The self tests
	/// count them as failures (SelfTest.bf). See docs/Architecture.md, "Host asserts".
	static class HostAsserts
	{
		/// `[ASSERT]` lines logged this run.
		public static int32 Count;

		public static void Register()
		{
			Host.vbh_set_assert_handler((void*)(function void(char8*, char8*, int32))=> OnAssert);
		}

		static void OnAssert(char8* expr, char8* file, int32 line)
		{
			Count++;
			let e = scope String(expr);
			let f = scope String(file);
			Notify.Log(.Error, "Assert", scope $"[ASSERT] {e} at {f}:{line}");
		}
	}

	class Program
	{
		/// UTF-8 path of the dock layout file, kept alive for ImGui (io.IniFilename).
		static char8[1024] sLayoutIni;

		/// The dock layout lives in %LOCALAPPDATA%\VisualBeef\layout.ini (not the working
		/// directory); an old VisualBeef_layout.ini there is copied over once.
		static void SetLayoutPath()
		{
			String path = scope .();
			AppPaths.Root(path);
			AppPaths.EnsureDir(path);
			path.AppendF("{}layout.ini", Path.DirectorySeparatorChar);
			if (!File.Exists(path) && File.Exists("VisualBeef_layout.ini"))
				File.Copy("VisualBeef_layout.ini", path).IgnoreError(); // migration is best effort: the default layout is rebuilt otherwise
			if (path.Length >= sLayoutIni.Count)
				return;
			Internal.MemCpy(&sLayoutIni[0], path.Ptr, path.Length);
			sLayoutIni[path.Length] = 0;
			Gui.igGetIO_Nil().IniFilename = &sLayoutIni[0];
		}

#if BF_PLATFORM_WINDOWS
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern int32 AttachConsole(uint32 processId);
		[Import("kernel32.lib"), CLink, CallingConvention(.Stdcall)]
		static extern void* GetStdHandle(uint32 which);
#else
		// A Linux process keeps the terminal's stdout / stderr: nothing to attach.
		static int32 AttachConsole(uint32 processId) => 1;
		static void* GetStdHandle(uint32 which) => (void*)(int)1;
#endif

		/// A GUI exe has no console: print into the parent's console (a terminal) unless stdout is already
		/// redirected (a pipe or a file, which the process inherits as it is).
		static void ConsoleOut(StringView text, bool error = false)
		{
			void* handle = GetStdHandle(error ? (uint32)-12 : (uint32)-11);
			if (handle == null || (int)handle == -1)
				AttachConsole((uint32)-1);
			if (error)
				Console.Error.WriteLine(text);
			else
				Console.WriteLine(text);
		}

		/// Command line before any window (docs/UMP-Integration.md): --version / --help / usage errors exit here;
		/// --new-ump-mod writes its files here so a failure is an exit code, not a dialog. -1 = carry on.
		static int PrepareArgs(String[] args, EditorArgs parsed, String root, String file)
		{
			EditorArgs.Parse(args, parsed);
			switch (parsed.Action)
			{
			case .PrintHelp:
				ConsoleOut(EditorArgs.Usage);
				return EditorArgs.ExitOk;
			case .PrintVersion:
				ConsoleOut(scope $"{VisualBeefInfo.Name} {VisualBeefInfo.Version}-{VisualBeefInfo.Channel} (UMP contract {VisualBeefInfo.UmpContract})");
				return EditorArgs.ExitOk;
			case .Usage:
				ConsoleOut(scope $"VisualBeef: {parsed.Error}\n\n{EditorArgs.Usage}", true);
				return EditorArgs.ExitUsage;
			case .Open:
			}
			if (parsed.IsEmpty)
				return -1;
			String error = scope .();
			if (!ProjectContract.ResolveTarget(parsed.Path, parsed.File, root, file, error))
			{
				ConsoleOut(scope $"VisualBeef: {error}", true);
				return EditorArgs.ExitUsage;
			}
			if (parsed.NewUmpMod)
			{
				if (file.IsEmpty)
					file.Set(scope $"{root}{System.IO.Path.DirectorySeparatorChar}{ProjectContract.DefaultMain}");
				List<String> created = scope .();
				defer { ClearAndDeleteItems!(created); }
				if (ProjectContract.WriteUmpMod(parsed, root, file, created, error) case .Err)
				{
					ConsoleOut(scope $"VisualBeef: {error}", true);
					return EditorArgs.ExitFailed;
				}
				for (let c in created)
					ConsoleOut(scope $"Created {c}");
				if (created.IsEmpty)
					ConsoleOut(scope $"{file} exists; not overwritten");
			}
			return -1;
		}

#if !BF_PLATFORM_WINDOWS
		[CLink] static extern int32 setenv(char8* name, char8* value, int32 overwrite);
		[CLink] static extern int32 unsetenv(char8* name);

		/// Started from the AppImage (packaging/linux/AppRun): the bundled SDL2 is loaded by now,
		/// so give programs the editor starts (BeefBuild, zenity, the compiled program) the
		/// caller's LD_LIBRARY_PATH back instead of the AppImage's.
		static void RestoreAppImageLibraryPath()
		{
			String orig = scope .();
			if (Environment.GetEnvironmentVariable("VB_APPIMAGE_ORIG_LD_LIBRARY_PATH", orig) case .Err)
				return;
			if (orig.IsEmpty)
				unsetenv("LD_LIBRARY_PATH");
			else
				setenv("LD_LIBRARY_PATH", orig.CStr(), 1);
			unsetenv("VB_APPIMAGE_ORIG_LD_LIBRARY_PATH");
		}
#endif

		public static int Main(String[] args)
		{
			// The update helper (a copy of the editor in <data>/update/helper, started by Restart to finish): it installs
			// the staged version and exits without opening a window (VisualBeef.Update.UpdateApply).
			if (args.Count > 0 && args[0] == VisualBeef.Update.UpdateApply.HelperSwitch)
				return VisualBeef.Update.UpdateApply.RunHelper(args);
			EditorArgs parsed = scope .();
			String argRoot = scope .();
			String argFile = scope .();
			int early = PrepareArgs(args, parsed, argRoot, argFile);
			if (early >= 0)
				return early;

			// Log file and crash handler first, so a failure anywhere after this is recorded.
			// With VB_HOME set, the symbol cache moves there too (everything per-user in one place).
			String home = scope .();
			if (Environment.GetEnvironmentVariable("VB_HOME", home) case .Ok && !home.IsEmpty)
			{
				AppPaths.Root(VisualBeef.Catalog.LibraryIndex.sCacheDirOverride);
				VisualBeef.Catalog.LibraryIndex.sCacheDirOverride.AppendF("{}index", Path.DirectorySeparatorChar);
			}
			SessionLog.Open();
			CrashHandler.Install();
			Recovery.Start();
			HostAsserts.Register();
			if (Host.vbh_init("VisualBeef", 1600, 960) == 0)
			{
				Console.WriteLine("VisualBeef: failed to create the window (see stderr).");
				SessionLog.WriteRaw("vbh_init failed: could not create the window\r\n");
				SessionLog.Close();
				return 1;
			}
#if !BF_PLATFORM_WINDOWS
			RestoreAppImageLibraryPath();
#endif
			SetLayoutPath();

			// Theme and DPI before the first frame; the icon font is merged after it (the UI font
			// pointer is only known once a frame has started).
			Prefs.Load();
			Look.FontSize = Prefs.FontSize;
			Look.Darker = Prefs.Theme == 1;
			Look.Apply(Desktop.WindowDpiScale());

			Notify.Log(.Info, "Editor", "VisualBeef started");
			Notify.Log(.Info, "Editor", scope $"Session log: {SessionLog.LogPath}");
#if !BF_PLATFORM_WINDOWS
			// A report the last session left (written by its signal handler) is announced once.
			String lastCrash = scope .();
			if (VisualBeef.Document.PosixCrashReport.FindNewer(CrashHandler.CrashDir, lastCrash))
				Notify.Warn(scope $"The last session crashed. Crash report: {lastCrash}");
			Notify.Log(.Verbose, "Editor", scope $"Crash reports: {CrashHandler.CrashDir}");
#endif
			String settingsPath = scope .();
			Settings.GetPath(settingsPath);
			Notify.Log(.Verbose, "Editor", scope $"Settings: {settingsPath}");
			Desktop.InitPacing();
			Desktop.IdlePacing = Prefs.IdlePacing;
			if (Desktop.IdleDisabledByEnv)
				Notify.Log(.Info, "Editor", "Frame pacing: continuous (VB_NO_IDLE is set)");
			else
				Notify.Log(.Info, "Editor", Prefs.IdlePacing ? "Frame pacing: idle (sleeps when nothing happens; VB_NO_IDLE=1 or Preferences > Graph Editor turns it off)" : "Frame pacing: continuous (Idle frame pacing is off in Preferences)");
			EditorApp app = new .();
			app.HandleArgs(parsed, argRoot, argFile);
			app.CheckRecovery();
			app.InitUpdates();
			bool iconsLoaded = false;

			while (!app.QuitNow)
			{
				// Sleep while nothing happens (no input, no build, no animation): idle CPU ~0.
				Desktop.PaceFrame(app.WantsContinuousFrames, app.IdleTimeoutMs);
				if (!iconsLoaded && app.UiFont != null)
				{
					iconsLoaded = true;
					Icon.Load(app.UiFont, Host.vbh_get_mono_font(), 16 * Look.HostScale);
				}
				if (Host.vbh_begin_frame() == 0)
				{
					// Window close requested: let the app ask about unsaved changes.
					Host.vbh_cancel_quit();
					app.RequestQuit();
				}
				let dropped = Host.vbh_poll_drop();
				if (dropped != null)
					app.OnFileDropped(StringView(dropped));
				app.Frame();
				Desktop.NoteActivity();
				Host.vbh_end_frame();
			}

			app.SaveSettings();
			delete app; // ends a debugging session (the program being debugged is stopped)
			VisualBeef.Debug.DebugEngine.Shutdown();
			Host.vbh_shutdown();
			// Clean exit: the recovery journal of this session is no longer needed.
			Recovery.EndSession();
			Notify.Log(.Info, "Editor", "VisualBeef exited");
			SessionLog.Close();
			return 0;
		}
	}
}
