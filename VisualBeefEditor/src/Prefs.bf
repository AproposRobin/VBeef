using System;
using System.Collections;
using System.IO;
using ImGui;

namespace VisualBeef.Editor
{
	/// Editor Preferences, stored per user in the "preferences" object of
	/// %LOCALAPPDATA%\VisualBeef\settings.json (see Settings), so they follow the user across
	/// projects. The old %APPDATA%\VisualBeef\EditorPreferences.ini is read once to migrate.
	static class Prefs
	{
		public static float FontSize = 16;
		/// 0 = Dark, 1 = Darker.
		public static int32 Theme = 0;
		public static bool GridSnap = true;
		public static bool ShowMinimap = false;
		/// Minutes between autosaves of modified files (0 = off).
		public static int32 AutosaveMinutes = 0;
		public static bool ShowToasts = true;
		/// Sleep the frame loop while nothing happens (Desktop.PaceFrame). Off = render every frame.
		public static bool IdlePacing = true;
		/// Seconds between recovery-journal writes of unsaved documents (0 = off). The journal
		/// is restored after a crash ("Recover unsaved changes?" on the next start).
		public static int32 RecoverySeconds = 30;
		/// Compile configuration when a project has no choice of its own: 0 = automatic (Release
		/// for UMP mods, else the Beef IDE's last configuration, else Debug), 1 = Debug, 2 = Release.
		public static int32 DefaultConfig = 0;

		/// The pre-JSON preferences file (read once for migration).
		public static void GetLegacyPath(String outPath)
		{
			String dir = scope .();
#if BF_PLATFORM_WINDOWS
			Environment.GetEnvironmentVariable("APPDATA", dir).IgnoreError(); // APPDATA unset: dir stays empty, falls back to "."
#else
			Environment.GetEnvironmentVariable("HOME", dir).IgnoreError(); // HOME unset: dir stays empty, falls back to "."
			if (!dir.IsEmpty)
				dir.Append("/.config");
#endif
			if (dir.IsEmpty)
				dir.Set(".");
			outPath.AppendF("{}{}VisualBeef{}EditorPreferences.ini", dir, Path.DirectorySeparatorChar, Path.DirectorySeparatorChar);
		}

		public static void GetPath(String outPath)
		{
			Settings.GetPath(outPath);
		}

		public static void Load()
		{
			Settings.Load();
			let p = Settings.Root.Get("preferences");
			if (p == null)
			{
				// First start with settings.json: take over the old preferences file, if any.
				LoadLegacy();
				Save();
				return;
			}
			FontSize = Math.Clamp((float)p.GetNumber("fontSize", FontSize), 11, 26);
			Theme = (int32)Math.Clamp(p.GetNumber("theme", Theme), 0, 1);
			GridSnap = p.GetBool("gridSnap", GridSnap);
			ShowMinimap = p.GetBool("showMinimap", ShowMinimap);
			AutosaveMinutes = (int32)Math.Clamp(p.GetNumber("autosaveMinutes", AutosaveMinutes), 0, 120);
			ShowToasts = p.GetBool("showToasts", ShowToasts);
			IdlePacing = p.GetBool("idlePacing", IdlePacing);
			RecoverySeconds = (int32)Math.Clamp(p.GetNumber("recoverySeconds", RecoverySeconds), 0, 3600);
			DefaultConfig = (int32)Math.Clamp(p.GetNumber("defaultConfig", DefaultConfig), 0, 2);
		}

		static void LoadLegacy()
		{
			String path = scope .();
			GetLegacyPath(path);
			String text = scope .();
			if (File.ReadAllText(path, text) case .Err)
				return;
			for (var line in text.Split('\n'))
			{
				line.Trim();
				int eq = line.IndexOf('=');
				if (eq <= 0)
					continue;
				StringView key = line.Substring(0, eq);
				StringView val = line.Substring(eq + 1);
				switch (key)
				{
				case "FontSize": if (float.Parse(val) case .Ok(let v)) FontSize = Math.Clamp(v, 11, 26);
				case "Theme": if (int32.Parse(val) case .Ok(let v)) Theme = Math.Clamp(v, 0, 1);
				case "GridSnap": GridSnap = val == "1";
				case "ShowMinimap": ShowMinimap = val == "1";
				case "AutosaveMinutes": if (int32.Parse(val) case .Ok(let v)) AutosaveMinutes = Math.Clamp(v, 0, 120);
				case "ShowToasts": ShowToasts = val == "1";
				case "IdlePacing": IdlePacing = val == "1";
				default:
				}
			}
		}

		public static void Save()
		{
			Settings.Load();
			let p = Settings.Preferences;
			p.Set("fontSize", Json.NewNumber((int)FontSize));
			p.Set("theme", Json.NewNumber(Theme));
			p.Set("gridSnap", Json.NewBool(GridSnap));
			p.Set("showMinimap", Json.NewBool(ShowMinimap));
			p.Set("autosaveMinutes", Json.NewNumber(AutosaveMinutes));
			p.Set("showToasts", Json.NewBool(ShowToasts));
			p.Set("idlePacing", Json.NewBool(IdlePacing));
			p.Set("recoverySeconds", Json.NewNumber(RecoverySeconds));
			p.Set("defaultConfig", Json.NewNumber(DefaultConfig));
			Settings.Save();
		}

		/// Applies theme + font size at the current DPI.
		public static void ApplyAppearance()
		{
			Look.FontSize = FontSize;
			Look.Darker = Theme == 1;
			Look.Apply(Look.Scale);
		}
	}

	extension EditorApp
	{
		bool mShowPrefs;
		int32 mPrefsCategory;
		TextBuffer mPrefsBeefBuild = new .(1024) ~ delete _;
		double mLastAutosave = -1;

		public void OpenPreferences()
		{
			mShowPrefs = true;
			mPrefsBeefBuild.Set(mBeefBuildPath);
		}

		/// Editor Preferences > Node Hotkeys: every hotkey and favorite (global, settings.json
		/// `editor.nodeHotkeys` / `editor.favorites`), a Clear per key and Reset to Defaults. Keys
		/// are given in the Node menu (the key-capture control on a favorite's row).
		void DrawNodeHotkeyPrefs()
		{
			let prefs = NodePrefs;
			let hotkeys = prefs.Hotkeys;
			if (PropertyGrid.Category("Node Hotkeys", true, Icon.Keyboard))
			{
				PropertyGrid.Row("How to use", "Node hotkeys are plain letters; they work while the Sheet has the keyboard (no text field active)");
				PropertyGrid.WrappedValue("Hold the letter and click the Sheet, or press it while dragging a wire from a pin.");
				PropertyGrid.Row("Change a key", "The key-capture control is the small box before the star on a favorite's row");
				PropertyGrid.WrappedValue("Node menu: click the key box of a favorite, press a letter (Esc clears).");
				List<(char8 key, StringView nodeKey)> bindings = scope .();
				hotkeys.GetBindings(bindings);
				char8 clear = '\0';
				for (let b in bindings)
				{
					String cat = scope .(b.nodeKey);
					int tab = cat.IndexOf('\t');
					if (tab >= 0)
						cat.RemoveToEnd(tab);
					PropertyGrid.Row(scope String()..Append(b.key), scope $"Hold {b.key} and click the Sheet, or press {b.key} while dragging a wire");
					Gui.igAlignTextToFramePadding();
					Gui.Text(VisualBeef.Catalog.NodeHotkeys.LabelOf(b.nodeKey));
					Gui.SameLine();
					Gui.TextColored(Look.ForegroundDim, scope $"({cat})");
					Gui.SameLine();
					if (Gui.SmallButton(scope $"Clear##hk{b.key}"))
						clear = b.key;
				}
				if (bindings.IsEmpty)
				{
					PropertyGrid.Row("Keys");
					PropertyGrid.Value("No node hotkeys. Reset to Defaults brings back the default set.");
				}
				if (clear != '\0' && hotkeys.ClearKey(clear))
					prefs.SaveSettings();
				PropertyGrid.Row("Taken by the Sheet", "Letters the Sheet uses on their own; they cannot be node hotkeys");
				PropertyGrid.WrappedValue("C comment box, F frame, M minimap, Q straighten wires");
			}
			if (PropertyGrid.Category("Favorites", true, Icon.Star))
			{
				for (let f in hotkeys.Favorites)
				{
					if (hotkeys.KeyOf(f) != '\0')
						continue;
					String cat = scope .(f);
					int tab = cat.IndexOf('\t');
					if (tab >= 0)
						cat.RemoveToEnd(tab);
					PropertyGrid.Row(VisualBeef.Catalog.NodeHotkeys.LabelOf(f), "A favorite with no hotkey");
					PropertyGrid.Value(scope $"{cat}  (no hotkey)");
				}
				PropertyGrid.Row("Total", "Favorites are listed first in the Node menu; the star on a row adds or removes one");
				PropertyGrid.Value(scope $"{hotkeys.Favorites.Count} favorites, {hotkeys.KeyCount} with a hotkey");
			}
			PropertyGrid.WideRow();
			if (Gui.Button("Reset to Defaults"))
			{
				prefs.ResetHotkeys();
				Notify.Log(.Info, "Editor", "Node hotkeys and favorites reset to the defaults");
			}
			if (Gui.igIsItemHovered(0))
				Gui.Tooltip("The default favorites and keys (B Branch, S Sequence, E For Each Loop, ...). Your other favorites are removed.");
		}

		/// Saves modified files every Prefs.AutosaveMinutes (off by default).
		void Autosave(double now)
		{
			if (mLastAutosave < 0)
				mLastAutosave = now;
			if (Prefs.AutosaveMinutes <= 0 || now - mLastAutosave < Prefs.AutosaveMinutes * 60.0)
				return;
			mLastAutosave = now;
			if (ModifiedCount == 0 || Gui.igIsAnyItemActive())
				return;
			SaveAll();
			Notify.Info("Autosaved modified files");
		}

		void DrawPreferences()
		{
			if (!mShowPrefs)
				return;
			let vp = Gui.igGetMainViewport();
			Gui.igSetNextWindowSize(.(780 * Look.Scale, 520 * Look.Scale), Cond.Appearing);
			Gui.igSetNextWindowPos(.(vp.Pos.x + vp.Size.x * 0.5f, vp.Pos.y + vp.Size.y * 0.5f), Cond.Appearing, .(0.5f, 0.5f));
			if (Gui.Begin(scope $"{Icon.Settings}  Editor Preferences###Editor Preferences", &mShowPrefs, WindowFlags.NoDocking | WindowFlags.NoCollapse | WindowFlags.NoSavedSettings))
			{
				// Category list on the left, like UE's Editor Preferences.
				Gui.igPushStyleColor_U32(Col.ChildBg, Look.Recessed);
				if (Gui.igBeginChild_Str("##prefcats", .(180 * Look.Scale, 0), ChildFlags.Borders, 0))
				{
					Gui.TextDisabled("General");
					StringView[5] cats = .("Appearance", "Graph Editor", "Saving", "Build", "Node Hotkeys");
					StringView[5] icons = .(Icon.Palette, Icon.Workflow, Icon.Save, Icon.Compile, Icon.Keyboard);
					for (int i < cats.Count)
					{
						if (Gui.Selectable(scope $"  {icons[i]}  {cats[i]}", mPrefsCategory == i))
							mPrefsCategory = (int32)i;
					}
				}
				Gui.igEndChild();
				Gui.igPopStyleColor(1);
				Gui.SameLine();
				if (Gui.igBeginChild_Str("##prefbody", .(0, 0), 0, 0))
				{
					bool changed = false;
					if (PropertyGrid.Begin("##prefgrid", 0.45f))
					{
						switch (mPrefsCategory)
						{
						case 0:
							if (PropertyGrid.Category("Appearance", true, Icon.Palette))
							{
								PropertyGrid.Row("Theme", "Editor colour theme");
								StringView[2] themes = .("Dark", "Darker");
								if (PropertyGrid.Combo("##theme", ref Prefs.Theme, themes))
									changed = true;
								PropertyGrid.Row("Font Size", "UI font size in pixels at 100% display scale (drag or double-click to type)");
								if (PropertyGrid.Float("##fontsize", ref Prefs.FontSize, 0.1f, 11, 26, "%.0f px"))
									changed = true;
								PropertyGrid.Row("Display Scale", "Follows the monitor the window is on (per-monitor DPI)");
								PropertyGrid.Value(scope $"{(int)(Look.Scale * 100 + 0.5f)}%  (automatic)");
								PropertyGrid.Row("Show Notifications", "Toasts in the bottom-right corner (everything also goes to the Output Log)");
								if (PropertyGrid.Bool("##toasts", ref Prefs.ShowToasts))
									changed = true;
							}
						case 1:
							if (PropertyGrid.Category("Graph Editor", true, Icon.Workflow))
							{
								PropertyGrid.Row("Snap to Grid", "Snap dragged and newly placed nodes to the 16-unit grid");
								if (PropertyGrid.Bool("##snap", ref Prefs.GridSnap))
									changed = true;
								PropertyGrid.Row("Show Minimap", "Overview of the whole graph in the bottom-right corner (M)");
								if (PropertyGrid.Bool("##minimap", ref Prefs.ShowMinimap))
									changed = true;
								PropertyGrid.Row("Idle Frame Pacing", "Sleep the frame loop while nothing happens (near-zero CPU when idle). Turn off to render every frame; the VB_NO_IDLE=1 environment variable also turns it off.");
								if (PropertyGrid.Bool("##idlepacing", ref Prefs.IdlePacing))
								{
									Desktop.IdlePacing = Prefs.IdlePacing;
									Notify.Log(.Info, "Editor", Prefs.IdlePacing ? "Frame pacing: idle" : "Frame pacing: continuous");
									changed = true;
								}
							}
						case 2:
							if (PropertyGrid.Category("Saving", true, Icon.Save))
							{
								PropertyGrid.Row("Autosave Interval", "Save modified files every N minutes (0 = off)");
								if (PropertyGrid.Int("##autosave", ref Prefs.AutosaveMinutes, 0.2f, 0, 120, (Prefs.AutosaveMinutes == 0) ? "Off" : "%d min"))
									changed = true;
								PropertyGrid.Row("Recovery Journal", "Copy unsaved documents to the recovery folder every N seconds (never into your project). After a crash the next start offers them back. 0 = off.");
								if (PropertyGrid.Int("##recovery", ref Prefs.RecoverySeconds, 0.5f, 0, 3600, (Prefs.RecoverySeconds == 0) ? "Off" : "%d s"))
									changed = true;
								PropertyGrid.Row("Recovery Folder", "Where the journal is kept");
								String recDir = scope .();
								AppPaths.Root(recDir);
								recDir.AppendF("{}recovery", System.IO.Path.DirectorySeparatorChar);
								PropertyGrid.Value(recDir);
								PropertyGrid.Row("Logs Folder", "Session logs (the Output Log of every session) and crash reports");
								String logDir = scope .();
								AppPaths.Root(logDir);
								logDir.AppendF("{}logs", System.IO.Path.DirectorySeparatorChar);
								PropertyGrid.Value(logDir);
							}
						case 3:
							if (PropertyGrid.Category("Build", true, Icon.Compile))
							{
								PropertyGrid.Row("BeefBuild Path", "BeefBuild.exe used by Compile (F7)");
								Gui.igInputText("##beefbuild", mPrefsBeefBuild.Ptr, (.)mPrefsBeefBuild.Capacity, 0, null, null);
								if (Gui.igIsItemDeactivatedAfterEdit())
								{
									mBeefBuildPath.Set(mPrefsBeefBuild.View);
									SaveSettings();
									Notify.Log(.Info, "Editor", scope $"BeefBuild path set to {mBeefBuildPath}");
								}
								PropertyGrid.Row("Found", "Whether the BeefBuild program exists");
								String resolved = scope .();
								BuildRunner.ResolveExe(mBeefBuildPath, resolved);
								bool ok = File.Exists(resolved);
								PropertyGrid.Value(ok ? scope $"{Icon.Ok}  yes" : scope $"{Icon.Error}  not found", ok ? Look.Success : Look.Error);
								PropertyGrid.Row("Default Configuration", "Compile configuration for projects you have not chosen one for. Automatic: Release for UMP mods (ModConfig.json beside BeefSpace.toml), else the Beef IDE's last configuration (BeefSpace_User.toml), else Debug. The toolbar's configuration menu overrides it per project.");
								StringView[3] cfgs = .("Automatic", "Debug", "Release");
								if (PropertyGrid.Combo("##defcfg", ref Prefs.DefaultConfig, cfgs))
									changed = true;
							}
						case 4:
							DrawNodeHotkeyPrefs();
						default:
						}
						PropertyGrid.End();
					}
					if (changed)
					{
						Prefs.ApplyAppearance();
						Prefs.Save();
					}
					Gui.igSpacing();
					String path = scope .();
					Prefs.GetPath(path);
					Gui.TextDisabled(scope $"Saved to {path}");
				}
				Gui.igEndChild();
			}
			Gui.End();
		}
	}
}
