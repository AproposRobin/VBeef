using System;
using ImGui;

namespace VisualBeef.Editor
{
	/// Small OS layer for the shell: the main window handle, per-monitor DPI and the idle wait
	/// that keeps the frame loop from spinning when nothing happens. Windows-only parts compile
	/// to no-ops elsewhere.
	static class Desktop
	{
#if BF_PLATFORM_WINDOWS
		[CLink, CallingConvention(.Stdcall)] static extern uint32 GetCurrentThreadId();
		[CLink, CallingConvention(.Stdcall)] static extern int32 EnumThreadWindows(uint32 threadId, function [CallingConvention(.Stdcall)] int32(void* hwnd, int lParam) cb, int lParam);
		[CLink, CallingConvention(.Stdcall)] static extern int32 IsWindowVisible(void* hwnd);
		[CLink, CallingConvention(.Stdcall)] static extern int32 GetClassNameA(void* hwnd, char8* buf, int32 max);
		[CLink, CallingConvention(.Stdcall)] static extern uint32 GetDpiForWindow(void* hwnd);
		[CLink, CallingConvention(.Stdcall)] static extern uint32 MsgWaitForMultipleObjectsEx(uint32 count, void* handles, uint32 ms, uint32 wakeMask, uint32 flags);
		[CLink, CallingConvention(.Stdcall)] static extern int32 IsIconic(void* hwnd);
		[CLink, CallingConvention(.Stdcall)] static extern void* GetForegroundWindow();
		[CLink, CallingConvention(.Stdcall)] static extern int32 GetWindowTextA(void* hwnd, char8* buf, int32 max);
		[CLink, CallingConvention(.Stdcall)] static extern int32 SetWindowTextW(void* hwnd, char16* text);

		const uint32 QS_ALLINPUT = 0x04FF;
		const uint32 MWMO_INPUTAVAILABLE = 0x0004;
		const uint32 WAIT_TIMEOUT = 258;

		static void* sHwnd;

		[CallingConvention(.Stdcall)]
		static int32 FindProc(void* hwnd, int lParam)
		{
			char8[64] cls = default;
			GetClassNameA(hwnd, &cls, 63);
			if (StringView(&cls) == "SDL_app")
			{
				sHwnd = hwnd;
				return 0;
			}
			return 1;
		}
#endif

		/// The editor's top-level window (null until it exists, or on other platforms).
		public static void* MainWindow
		{
			get
			{
#if BF_PLATFORM_WINDOWS
				if (sHwnd == null)
					EnumThreadWindows(GetCurrentThreadId(), => FindProc, 0);
				return sHwnd;
#else
				return null;
#endif
			}
		}

		/// `VB_UI_SCALE` (e.g. 1.25) overrides the monitor's scale, so a 125 % or 150 % layout can be
		/// checked on a 100 % screen (docs/Testing.md > Verifying the UI). 0 when unset.
		static float sScaleOverride = -1;

		/// DPI scale of the monitor the window is on (1.0 = 96 dpi).
		public static float WindowDpiScale()
		{
			if (sScaleOverride < 0)
			{
				sScaleOverride = 0;
				String v = scope .();
				if (Environment.GetEnvironmentVariable("VB_UI_SCALE", v) case .Ok && (float.Parse(v) case .Ok(let f)) && f >= 0.5f && f <= 3)
					sScaleOverride = f;
			}
			if (sScaleOverride > 0)
				return sScaleOverride;
#if BF_PLATFORM_WINDOWS
			let hwnd = MainWindow;
			if (hwnd != null)
			{
				uint32 dpi = GetDpiForWindow(hwnd);
				if (dpi > 0)
					return dpi / 96.0f;
			}
			return 1.0f;
#else
			// The host's scale (GDK_SCALE, as the host read it when it sized the window and loaded
			// the fonts): without it Look.Apply would undo the host's scaling and a 2x display
			// would draw at half size.
			let hostScale = Host.vbh_get_window_scale();
			return (hostScale >= 0.5f && hostScale <= 3) ? hostScale : 1.0f;
#endif
		}

		public static bool IsMinimized
		{
			get
			{
#if BF_PLATFORM_WINDOWS
				let hwnd = MainWindow;
				return hwnd != null && IsIconic(hwnd) != 0;
#else
				return (Host.vbh_window_flags() & 0x40) != 0; // SDL_WINDOW_MINIMIZED
#endif
			}
		}

		public static bool IsForeground
		{
			get
			{
#if BF_PLATFORM_WINDOWS
				let hwnd = MainWindow;
				return hwnd != null && GetForegroundWindow() == hwnd;
#else
				return (Host.vbh_window_flags() & 0x200) != 0; // SDL_WINDOW_INPUT_FOCUS
#endif
			}
		}

		/// Sets the window title (UTF-8 in, UTF-16 to Windows so non-ASCII names survive).
		public static void SetTitle(StringView title)
		{
#if BF_PLATFORM_WINDOWS
			let hwnd = MainWindow;
			if (hwnd != null)
			{
				let wide = title.ToScopedNativeWChar!();
				SetWindowTextW(hwnd, wide);
				return;
			}
#endif
			Host.vbh_set_title(scope String(title));
		}

		// ---------------------------------------------------------------- idle

		static double sLastWake = -100;
		static int64 sFrameCounter;

		/// Seconds since start, from the OS clock (usable before ImGui's first frame).
		public static double Now => (double)Internal.GetTickCountMicro() / 1000000.0;

		/// Blocks until there is input for the window, or `timeoutMs` passes. Returns true when
		/// woken by input. Call before starting a frame when nothing is animating.
		public static bool WaitForInput(int32 timeoutMs)
		{
#if BF_PLATFORM_WINDOWS
			let r = MsgWaitForMultipleObjectsEx(0, null, (uint32)Math.Max(0, timeoutMs), QS_ALLINPUT, MWMO_INPUTAVAILABLE);
			return r != WAIT_TIMEOUT;
#else
			System.Threading.Thread.Sleep(Math.Min(timeoutMs, 16));
			return true;
#endif
		}

		/// How long frames keep coming after the last input ImGui processed (hover delays, popups
		/// settling, tooltips, ImGui's trickled input queue draining).
		public const double HoldSeconds = 1.2;

		/// False = render every frame (vsync only), the pre-idle behaviour. Set from the
		/// "Idle frame pacing" preference; the VB_NO_IDLE=1 environment variable forces it off.
		public static bool IdlePacing = true;
		public static bool IdleDisabledByEnv;

		/// Reads VB_NO_IDLE once at startup.
		public static void InitPacing()
		{
			String v = scope .();
			Environment.GetEnvironmentVariable("VB_NO_IDLE", v).IgnoreError();
			v.Trim();
			IdleDisabledByEnv = !v.IsEmpty && v != "0";
		}

		public static bool PacingActive => IdlePacing && !IdleDisabledByEnv;

		/// Frame pacing for the main loop. Renders continuously while `busy` or for HoldSeconds
		/// after the last input (see NoteActivity), otherwise sleeps until input arrives or
		/// `idleTimeoutMs` passes (polling such as file watching still runs then).
		public static void PaceFrame(bool busy, int32 idleTimeoutMs)
		{
			sFrameCounter++;
			if (!PacingActive)
				return;
			let now = Now;
			if (busy || sFrameCounter < 4)
				return;
			if (now - sLastWake < HoldSeconds)
				return;
			if (WaitForInput(idleTimeoutMs))
				sLastWake = Now;
		}

		/// Marks "something just happened": keeps frames coming for a moment.
		public static void Wake() => sLastWake = Now;

		static int32 sRaiseTestStep;

		/// Hidden check of BringToFront: VB_DEBUG_RAISE_TEST=<seconds> raises the window that many
		/// seconds after start (minimize or cover it first, e.g. `xdotool windowminimize`) and logs
		/// the minimized / focus state before and after.
		public static void MaybeRaiseForTest()
		{
			if (sRaiseTestStep >= 2)
				return;
			String v = scope .();
			float secs = 0;
			if (Environment.GetEnvironmentVariable("VB_DEBUG_RAISE_TEST", v) case .Ok && (float.Parse(v) case .Ok(let f)))
				secs = f;
			if (secs <= 0)
			{
				sRaiseTestStep = 2;
				return;
			}
			if (sRaiseTestStep == 0 && Now - sStart >= secs)
			{
				Notify.Log(.Info, "Editor", scope $"VB_DEBUG_RAISE_TEST: before: minimized={IsMinimized} focused={IsForeground}");
				BringToFront();
				sRaiseTestStep = 1;
				sRaiseTestTime = Now;
			}
			else if (sRaiseTestStep == 1 && Now - sRaiseTestTime >= 1.0)
			{
				Notify.Log(.Info, "Editor", scope $"VB_DEBUG_RAISE_TEST: after: minimized={IsMinimized} focused={IsForeground}");
				sRaiseTestStep = 2;
			}
		}
		static double sStart = Now;
		static double sRaiseTestTime;

#if BF_PLATFORM_WINDOWS
		[CLink, CallingConvention(.Stdcall)] static extern int32 SetForegroundWindow(void* hwnd);
#endif

		/// Raises the editor window (the debugger stopped, VB_SELFTEST=raise) and wakes the idle loop.
		/// Windows refuses SDL_RaiseWindow for a background process, so SetForegroundWindow goes
		/// first; the SDL raise then restores a minimized window (SetForegroundWindow cannot) and
		/// is the same call Linux makes.
		public static void BringToFront()
		{
#if BF_PLATFORM_WINDOWS
			let h = MainWindow;
			if (h != null)
				SetForegroundWindow(h);
#endif
			Host.vbh_raise_window(); // SDL_RestoreWindow (if minimized) + SDL_RaiseWindow
			Wake();
		}

		static ImVec2 sLastMouse = .(-1e30f, -1e30f);
		static ImVec2 sLastDisplay;

		/// Called after every frame. Input that arrives while frames are already running (busy or
		/// inside the hold) never goes through WaitForInput, so without this the hold would expire
		/// mid-interaction: the frame after a popup closes or a drag ends would sleep while ImGui
		/// still had the release / trickled events to process. Any input ImGui saw this frame
		/// (mouse moved, button or wheel, key, active widget, window resized) restarts the hold.
		public static void NoteActivity()
		{
			bool active = false;
			let mouse = Gui.igGetMousePos();
			if (mouse.x != sLastMouse.x || mouse.y != sLastMouse.y)
				active = true;
			sLastMouse = mouse;
			let io = Gui.igGetIO_Nil();
			if (io != null)
			{
				if (io.DisplaySize.x != sLastDisplay.x || io.DisplaySize.y != sLastDisplay.y)
					active = true;
				sLastDisplay = io.DisplaySize;
			}
			if (!active && (Gui.igIsAnyMouseDown() || Gui.igIsAnyItemActive()))
				active = true;
			if (!active)
			{
				// Named keys incl. mouse buttons and wheel (ImGuiKey_Tab .. ImGuiKey_MouseWheelY).
				for (int32 k = Key.Tab; k <= Key.MouseWheelY; k++)
				{
					if (Gui.igIsKeyDown_Nil(k) || Gui.igIsKeyReleased_Nil(k))
					{
						active = true;
						break;
					}
				}
			}
			if (active)
				sLastWake = Now;
		}
	}
}
