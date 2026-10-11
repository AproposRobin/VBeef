using System;
using System.Collections;
using System.Threading;
using ImGui;

namespace VisualBeef.Editor
{
	enum LogLevel
	{
		Verbose,
		Info,
		Success,
		Warning,
		Error
	}

	class LogEntry
	{
		public LogLevel Level;
		public String Category = new .() ~ delete _;
		public String Text = new .() ~ delete _;
		/// Wall-clock "hh:mm:ss".
		public String Stamp = new .() ~ delete _;
		/// Optional source location (compiler messages): double-click jumps there.
		public String Path ~ delete _;
		public int32 Line;
		public int32 Repeat = 1;
	}

	/// The editor's message API, shared by every part of the editor:
	///
	///     Notify.Info("Saved Player.bf");        // Output Log + toast
	///     Notify.Warn("...");  Notify.Error("...");  Notify.Success("...");
	///     Notify.Log(.Verbose, "Index", "...");  // Output Log only
	///
	/// Thread-safe: worker threads may call it; toasts are drawn by the main thread.
	static class Notify
	{
		class Toast
		{
			public LogLevel Level;
			public String Text = new .() ~ delete _;
			public double Born;
			public double Life;
			public int32 Id;
			public int32 Repeat = 1;
			public bool Hovered;
		}

		static Monitor sLock = new .() ~ delete _;
		static List<LogEntry> sEntries = new .() ~ DeleteContainerAndItems!(_);
		static List<Toast> sToasts = new .() ~ DeleteContainerAndItems!(_);
		static int32 sNextToastId = 1;
		/// Bumped whenever the log changes (the Output Log scrolls to the end on change).
		public static int32 Version;
		public const int MaxEntries = 20000;

		public static void Info(StringView text) => Post(.Info, "Editor", text, true);
		public static void Success(StringView text) => Post(.Success, "Editor", text, true);
		public static void Warn(StringView text) => Post(.Warning, "Editor", text, true);
		public static void Error(StringView text) => Post(.Error, "Editor", text, true);

		/// Output Log only (no toast).
		public static void Log(LogLevel level, StringView category, StringView text) => Post(level, category, text, false);

		/// Output Log line with a source location (double-click in the log jumps to it).
		public static void LogAt(LogLevel level, StringView category, StringView text, StringView path, int32 line)
		{
			using (sLock.Enter())
			{
				let e = AddEntry(level, category, text);
				if (e != null && !path.IsEmpty)
				{
					e.Path = new String(path);
					e.Line = line;
				}
			}
		}

		public static void Post(LogLevel level, StringView category, StringView text, bool toast)
		{
			using (sLock.Enter())
			{
				AddEntry(level, category, text);
				if (toast && (Prefs.ShowToasts || level == .Error))
					AddToast(level, text);
			}
		}

		static LogEntry AddEntry(LogLevel level, StringView category, StringView text)
		{
			// Every line also goes to the session log file (repeats included).
			{
				let now = DateTime.Now;
				String stamp = scope:: String(16);
				stamp.AppendF("{:D2}:{:D2}:{:D2}", now.Hour, now.Minute, now.Second);
				SessionLog.Line(stamp, level, category, text);
			}
			// Collapse immediate repeats like UE's "x2".
			if (!sEntries.IsEmpty)
			{
				let last = sEntries.Back;
				if (last.Level == level && last.Category == category && last.Text == text && last.Path == null)
				{
					last.Repeat++;
					Version++;
					return null;
				}
			}
			LogEntry e = new .();
			e.Level = level;
			e.Category.Set(category);
			e.Text.Set(text);
			let now = DateTime.Now;
			e.Stamp.AppendF("{:D2}:{:D2}:{:D2}", now.Hour, now.Minute, now.Second);
			sEntries.Add(e);
			if (sEntries.Count > MaxEntries)
			{
				delete sEntries[0];
				sEntries.RemoveAt(0);
			}
			Version++;
			return e;
		}

		static void AddToast(LogLevel level, StringView text)
		{
			let now = Desktop.Now;
			for (let t in sToasts)
			{
				if (t.Level == level && t.Text == text)
				{
					t.Repeat++;
					t.Born = now;
					return;
				}
			}
			Toast t = new .();
			t.Level = level;
			t.Text.Set(text);
			t.Born = now;
			t.Life = (level == .Error) ? 8.0 : ((level == .Warning) ? 6.0 : 4.0);
			t.Id = sNextToastId++;
			sToasts.Add(t);
			while (sToasts.Count > 5)
			{
				delete sToasts[0];
				sToasts.RemoveAt(0);
			}
			Desktop.Wake();
		}

		/// True while a toast is on screen (the frame loop keeps drawing to animate it).
		public static bool Animating
		{
			get
			{
				using (sLock.Enter())
					return !sToasts.IsEmpty;
			}
		}

		// ---- Output Log access (main thread)

		public static int EntryCount
		{
			get
			{
				using (sLock.Enter())
					return sEntries.Count;
			}
		}

		/// Runs `fn` with the log locked (the Output Log panel draws through this).
		public static void WithEntries(delegate void(List<LogEntry> entries) fn)
		{
			using (sLock.Enter())
				fn(sEntries);
		}

		/// Removes every toast at once (self-test captures: earlier toasts must not cover the view).
		public static void DismissToasts()
		{
			using (sLock.Enter())
				ClearAndDeleteItems!(sToasts);
		}

		public static void Clear()
		{
			using (sLock.Enter())
			{
				ClearAndDeleteItems!(sEntries);
				Version++;
			}
		}

		public static uint32 LevelColor(LogLevel level)
		{
			switch (level)
			{
			case .Verbose: return Gui.Color(128, 128, 128);
			case .Info: return Gui.Color(192, 192, 192);
			case .Success: return Gui.Color(31, 228, 75);
			case .Warning: return Gui.Color(255, 184, 0);
			case .Error: return Gui.Color(239, 53, 53);
			}
		}

		public static StringView LevelIcon(LogLevel level)
		{
			switch (level)
			{
			case .Verbose: return Icon.Info;
			case .Info: return Icon.Info;
			case .Success: return Icon.Ok;
			case .Warning: return Icon.Warning;
			case .Error: return Icon.Error;
			}
		}

		// ---- Toasts (UE's bottom-right notifications)

		/// Draws the toasts stacked in the bottom-right corner. `bottomInset` keeps them above
		/// the status bar.
		public static void DrawToasts(float bottomInset)
		{
			using (sLock.Enter())
			{
				let vp = Gui.igGetMainViewport();
				let now = Desktop.Now;
				float scale = Gui.igGetFontSize() / 16.0f;
				float y = vp.Pos.y + vp.Size.y - bottomInset - 12 * scale;
				float x = vp.Pos.x + vp.Size.x - 16 * scale;
				for (int i = sToasts.Count - 1; i >= 0; i--)
				{
					let t = sToasts[i];
					if (t.Hovered)
						t.Born = now - Math.Min(now - t.Born, 0.5);
					double age = now - t.Born;
					if (age > t.Life)
					{
						delete t;
						sToasts.RemoveAt(i);
						continue;
					}
					float alpha = (float)Math.Min(1.0, Math.Min(age / 0.15, (t.Life - age) / 0.6));
					Gui.igSetNextWindowPos(.(x, y), Cond.Always, .(1, 1));
					Gui.igSetNextWindowBgAlpha(0.97f * alpha);
					Gui.igSetNextWindowSizeConstraints(.(260 * scale, 0), .(460 * scale, 400 * scale), null, null);
					Gui.igPushStyleVar_Float(0 /* Alpha */, Math.Max(alpha, 0.01f));
					Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(12 * scale, 10 * scale));
					Gui.igPushStyleColor_U32(Col.WindowBg, Gui.Color(45, 45, 45));
					Gui.igPushStyleColor_U32(Col.Border, Theme.WithAlpha(LevelColor(t.Level), 160));
					String id = scope $"##toast{t.Id}";
					int32 flags = WindowFlags.NoTitleBar | WindowFlags.NoResize | WindowFlags.NoMove | WindowFlags.NoSavedSettings |
						WindowFlags.NoDocking | WindowFlags.AlwaysAutoResize | WindowFlags.NoScrollbar | WindowFlagsX.NoFocusOnAppearing | WindowFlagsX.NoNav;
					if (Gui.Begin(id, null, flags))
					{
						let wp = Gui.igGetWindowPos();
						let ws = Gui.igGetWindowSize();
						let dl = Gui.igGetWindowDrawList();
						// Severity stripe on the left edge.
						Gui.ImDrawList_AddRectFilled(dl, wp, .(wp.x + 3 * scale, wp.y + ws.y), LevelColor(t.Level), 0, 0);
						Gui.TextColored(LevelColor(t.Level), LevelIcon(t.Level));
						Gui.SameLine(0, 8 * scale);
						Gui.igPushTextWrapPos(Gui.igGetCursorPos().x + 380 * scale);
						String text = scope .(t.Text);
						if (t.Repeat > 1)
							text.AppendF("  (x{})", t.Repeat);
						Gui.TextColored(Gui.Color(230, 230, 230), text);
						Gui.igPopTextWrapPos();
						t.Hovered = Gui.igIsWindowHovered(0);
						if (t.Hovered && Gui.igIsMouseClicked_Bool(0, false))
							t.Born = now - t.Life + 0.3; // click dismisses
						y -= ws.y + 8 * scale;
					}
					Gui.End();
					Gui.igPopStyleColor(2);
					Gui.igPopStyleVar(2);
				}
			}
		}
	}
}
