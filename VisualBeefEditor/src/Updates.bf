using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using ImGui;
using VisualBeef.Update;

namespace VisualBeef.Editor
{
	/// Update settings, stored in settings.json under "updates" (docs/Updating.md):
	///   "check": true      look for a new version at start (and once a day while open); false = only when asked
	///   "channel": "stable" | "preview"   preview also offers pre-releases
	static class UpdatePrefs
	{
		public static bool CheckAtStart = true;
		/// 0 = stable, 1 = preview.
		public static int32 Channel = 0;

		public static StringView ChannelName => (Channel == 1) ? "preview" : "stable";

		public static void Load()
		{
			Settings.Load();
			let u = Settings.Root.Get("updates");
			if (u == null)
				return;
			CheckAtStart = u.GetBool("check", true);
			Channel = (u.GetString("channel", "stable") == "preview") ? 1 : 0;
		}

		public static void Save()
		{
			Settings.Load();
			let u = Settings.Root.Obj("updates");
			u.Set("check", Json.NewBool(CheckAtStart));
			u.Set("channel", Json.NewString(ChannelName));
			Settings.Save();
		}
	}

	extension EditorApp
	{
		UpdateService mUpdates ~ delete _;
		UpdateStatus mUpdateView = new .() ~ delete _;
		int32 mUpdateSerialSeen = -1;
		double mUpdateNextAuto = -1;
		/// "Later" hides the notice for this session (until another check finds something).
		bool mUpdateHidden;
		/// The reason Restart was refused (shown in the notice line), cleared once it no longer applies.
		String mUpdateBlocked = new .() ~ delete _;
		/// Unsaved files when Restart was refused for them (0: refused for another reason); the reason clears once they are saved.
		int mUpdateBlockedUnsaved;
		int32 mUpdateFrames;
		const double cUpdateFirstDelay = 8.0;
		const double cUpdateInterval = 24 * 3600.0;

		public void InitUpdates()
		{
			UpdatePrefs.Load();
			mUpdates = new .();
			mUpdates.OnLog = new (line) => Notify.Log(.Info, "Update", line);
			String dir = scope .();
			AppPaths.Root(dir);
			dir.AppendF("{}update", Path.DirectorySeparatorChar);
			mUpdates.Init(dir);
			mUpdates.Channel.Set(UpdatePrefs.ChannelName);
			String why = scope .();
			mUpdates.AutomaticBlocker(why);
			Notify.Log(.Verbose, "Update", scope $"VisualBeef {mUpdates.Install.Version} ({mUpdates.Install.Kind}), updates {(UpdatePrefs.CheckAtStart ? "checked at start" : "checked when asked")}, channel {UpdatePrefs.ChannelName}{(why.IsEmpty ? "" : ": ")}{why}");
			String msg = scope .();
			if (mUpdates.TakeLastResult(let ok, msg))
			{
				if (ok)
					Notify.Success(msg);
				else
					Notify.Error(scope $"Update failed: {msg}");
			}
			if (why.IsEmpty && UpdatePrefs.CheckAtStart)
				mUpdateNextAuto = Desktop.Now + cUpdateFirstDelay;
		}

		/// Help > Check for Updates and the Preferences button.
		public void CheckForUpdatesNow()
		{
			if (mUpdates == null)
				return;
			mUpdateHidden = false;
			mUpdates.Channel.Set(UpdatePrefs.ChannelName);
			if (mUpdates.Install.Kind == .Bundled)
			{
				Notify.Info("This copy of VisualBeef came with UniversalUMP; the UniversalUMP launcher updates it.");
				return;
			}
			if (mUpdateView.State == .Ready)
			{
				// Already downloaded and verified: bring the notice line (and its Restart to finish) back.
				SetStatus(scope $"VisualBeef {mUpdateView.LatestVersion} is downloaded and verified; Restart to finish is in the notice line.", .Info, false);
				return;
			}
			if (!mUpdates.StartCheck(true))
				Notify.Info("An update check or download is already running.");
			else
				SetStatus("Checking for updates...", .Info, false);
		}

		void UpdateTick()
		{
			if (mUpdates == null)
				return;
			mUpdateFrames++;
			// The helper that installed this version waits for a sign of life before it lets the update stand.
			if (mUpdateFrames == 30)
				UpdateApply.ReportHealthy(mUpdates.UpdateDir);
			let now = Desktop.Now;
			if (mUpdateNextAuto > 0 && now >= mUpdateNextAuto && mSelfTestStep == -2)
			{
				mUpdateNextAuto = UpdatePrefs.CheckAtStart ? now + cUpdateInterval : -1;
				if (UpdatePrefs.CheckAtStart)
				{
					mUpdates.Channel.Set(UpdatePrefs.ChannelName);
					mUpdates.StartCheck(false);
				}
			}
			mUpdates.GetStatus(mUpdateView);
			if (mUpdateView.Serial != mUpdateSerialSeen)
			{
				mUpdateSerialSeen = mUpdateView.Serial;
				Desktop.Wake();
				if (mUpdateView.State == .Available || mUpdateView.State == .Ready)
					mUpdateHidden = false;
				// The answer to a check the user asked for, when there is nothing to install: a toast.
				if (mUpdateView.Manual && !mUpdateView.Message.IsEmpty)
				{
					switch (mUpdateView.State)
					{
					case .UpToDate: SetStatus(mUpdateView.Message, .Info);
					case .Unavailable: SetStatus(mUpdateView.Message, .Warning);
					case .Available, .Error: mStatus.Set(mUpdateView.Message);
					default:
					}
				}
			}
			if (!mUpdateBlocked.IsEmpty && (mUpdateView.State != .Ready || (mUpdateBlockedUnsaved > 0 && ModifiedCount == 0)))
				mUpdateBlocked.Clear();
		}

		bool UpdateBusyElsewhere => (mBuild != null && mBuild.Running) || IsDebugging;

		void RestartToUpdate()
		{
			mUpdateBlocked.Clear();
			mUpdates.ApplyBlocker(ModifiedCount, UpdateBusyElsewhere, mUpdateBlocked);
			mUpdateBlockedUnsaved = ModifiedCount;
			if (!mUpdateBlocked.IsEmpty)
			{
				Notify.Warn(mUpdateBlocked);
				return;
			}
			String why = scope .();
			if (!mUpdates.Apply(why))
			{
				mUpdateBlocked.Set(why);
				Notify.Error(why);
				return;
			}
			SaveSettings();
			QuitNow = true;
		}

		static void OpenUrl(StringView url)
		{
			if (!url.StartsWith("https://"))
				return;
			ProcessStartInfo psi = scope .();
#if BF_PLATFORM_WINDOWS
			psi.SetFileName("explorer.exe");
#else
			psi.SetFileName("xdg-open");
#endif
			psi.SetArguments(scope $"\"{url}\"");
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
				Notify.Warn(scope $"Could not open {url}");
		}

		/// One text of the notice line, cut with "..." to end before `limitX` (window coordinates); the whole text is the
		/// tooltip of a cut one.
		void UpdateBarText(StringView text, uint32 color, float limitX)
		{
			Gui.igAlignTextToFramePadding();
			float avail = limitX - Gui.igGetCursorPosX();
			String shown = scope .(text);
			bool cut = false;
			if (Gui.CalcTextSize(shown).x > avail)
			{
				cut = true;
				while (shown.Length > 0 && Gui.CalcTextSize(scope $"{shown}...").x > avail)
				{
					shown.RemoveFromEnd(1);
					while (shown.Length > 0 && ((uint8)shown[shown.Length - 1] & 0xC0) == 0x80)
						shown.RemoveFromEnd(1);
					if (shown.Length > 0 && (uint8)shown[shown.Length - 1] >= 0xC0)
						shown.RemoveFromEnd(1);
				}
				shown.Append("...");
			}
			if (color == 0)
				Gui.Text(shown);
			else
				Gui.TextColored(color, shown);
			if (cut && Gui.igIsItemHovered(0))
				Gui.Tooltip(text);
		}

		/// The notice line under the toolbar: shown while an update is available, downloading, ready, or failed.
		void DrawUpdateBar()
		{
			if (mUpdates == null || mUpdateHidden)
				return;
			let s = mUpdateView;
			bool show = s.State == .Available || s.State == .Downloading || s.State == .Verifying || s.State == .Ready ||
				(s.State == .Error && s.Manual) || (s.State == .Error && !s.LatestVersion.IsEmpty);
			if (!show)
				return;
			let vp = Gui.igGetMainViewport();
			float fs = Gui.igGetFontSize();
			float h = Math.Round(fs * 2.0f);
			Gui.igPushStyleVar_Vec2(StyleVar.WindowPadding, .(10 * Look.Scale, 0));
			Gui.igPushStyleVar_Vec2(StyleVar.FramePadding, .(10 * Look.Scale, fs * 0.15f));
			Gui.igPushStyleColor_U32(Col.WindowBg, Look.Header);
			int32 flags = WindowFlags.NoScrollbar | WindowFlags.NoSavedSettings | WindowFlags.NoScrollWithMouse;
			if (Gui.igBeginViewportSideBar("##VBUpdateBar", vp, Dir.Up, h, flags))
			{
				Gui.igSetCursorPosY((h - Gui.igGetFrameHeight()) * 0.5f);
				uint32 iconColor = Look.AccentBlue;
				String icon = Icon.ArrowDownToLine;
				String text = scope .();
				switch (s.State)
				{
				case .Available:
					text.AppendF("VisualBeef {} is available.", s.LatestVersion);
					if (!s.Message.IsEmpty && s.Message.StartsWith("Download cancelled"))
						text.Append(" Download cancelled.");
				case .Downloading:
					text.AppendF("Downloading VisualBeef {}...", s.LatestVersion);
				case .Verifying:
					text.AppendF("Checking VisualBeef {}...", s.LatestVersion);
				case .Ready:
					text.AppendF("VisualBeef {} is downloaded and verified.", s.LatestVersion);
					icon = Icon.Ok;
					iconColor = Look.Success;
				case .Error:
					text.Set(s.Message);
					icon = Icon.Warning;
					iconColor = Look.Warning;
				default:
				}
				// Buttons on the right; the texts are cut (with the whole text as a tooltip) so they never run under them.
				float spacing = 6 * Look.Scale;
				List<StringView> buttons = scope .();
				switch (s.State)
				{
				case .Available: buttons.Add("Update"); buttons.Add("Release notes"); buttons.Add("Later");
				case .Downloading: buttons.Add("Cancel");
				case .Ready: buttons.Add("Restart to finish"); buttons.Add("Release notes"); buttons.Add("Later");
				case .Error: buttons.Add("Dismiss");
				default:
				}
				float total = 0;
				for (let b in buttons)
					total += Gui.CalcTextSize(b).x + Gui.igGetStyle().FramePadding.x * 2 + spacing;
				float right = Gui.igGetWindowWidth() - total - 4 * Look.Scale;
				float gap = 12 * Look.Scale;
				bool progress = s.State == .Downloading || s.State == .Verifying;
				String progressText = scope .();
				float f = 0;
				if (progress)
				{
					f = (s.Total > 0) ? Math.Clamp((float)s.Received / (float)s.Total, 0, 1) : 0;
					if (s.State == .Verifying)
						f = 1;
					if (s.State == .Downloading && s.Total > 0)
						progressText.AppendF("{}%  {} / {} MB", (int)(f * 100), s.Received / (1024 * 1024), (s.Total + 1024 * 1024 - 1) / (1024 * 1024));
					else
						progressText.Append("SHA-256 and signature");
				}
				float barW = 180 * Look.Scale;
				float reserve = 0;
				if (progress)
					reserve = gap + barW + 8 * Look.Scale + Gui.CalcTextSize(progressText).x;
				bool blocked = !mUpdateBlocked.IsEmpty && s.State == .Ready;
				if (blocked)
					reserve = Math.Min(gap + Gui.CalcTextSize(mUpdateBlocked).x, (right - Gui.igGetCursorPosX()) * 0.55f);

				Gui.igAlignTextToFramePadding();
				Gui.TextColored(iconColor, icon);
				Gui.SameLine(0, 8 * Look.Scale);
				UpdateBarText(text, 0, right - gap - reserve);
				if (progress && Gui.igGetCursorPosX() + reserve < right)
				{
					Gui.SameLine(0, gap);
					let pos = Gui.igGetCursorScreenPos();
					float bh = fs * 0.45f;
					float y = pos.y + (Gui.igGetFrameHeight() - bh) * 0.5f;
					let dl = Gui.igGetWindowDrawList();
					Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + barW, y + bh), Look.Recessed, 2, 0);
					Gui.ImDrawList_AddRectFilled(dl, .(pos.x, y), .(pos.x + barW * f, y + bh), Look.Primary, 2, 0);
					Gui.igDummy(.(barW, Gui.igGetFrameHeight()));
					Gui.SameLine(0, 8 * Look.Scale);
					UpdateBarText(progressText, Look.ForegroundDim, right - gap);
				}
				if (blocked)
				{
					Gui.SameLine(0, gap);
					UpdateBarText(mUpdateBlocked, Look.Warning, right - gap);
				}
				Gui.SameLine(Math.Max(right, Gui.igGetCursorPosX() + gap), 0);
				for (let b in buttons)
				{
					bool primary = b == "Update" || b == "Restart to finish";
					if (primary)
					{
						Gui.igPushStyleColor_U32(Col.Button, Look.Primary);
						Gui.igPushStyleColor_U32(Col.ButtonHovered, Look.PrimaryHover);
						Gui.igPushStyleColor_U32(Col.ButtonActive, Look.PrimaryPress);
					}
					bool clicked = Gui.Button(scope $"{b}##upd");
					if (primary)
						Gui.igPopStyleColor(3);
					if (Gui.igIsItemHovered(0))
					{
						switch (b)
						{
						case "Update": Gui.Tooltip("Download the new version now; it is checked before anything is installed");
						case "Release notes": Gui.Tooltip(s.Notes.IsEmpty ? "Open the release page" : scope $"{s.Notes}\n\nClick to open the release page");
						case "Later": Gui.Tooltip("Hide this until the next check");
						case "Restart to finish": Gui.Tooltip("Close VisualBeef, install the new version and start it again (unsaved work must be saved first)");
						case "Cancel": Gui.Tooltip("Stop the download");
						default:
						}
					}
					if (clicked)
					{
						switch (b)
						{
						case "Update":
							if (!mUpdates.StartDownload())
								Notify.Warn("The download could not be started.");
						case "Release notes": OpenUrl(s.NotesUrl);
						case "Later": mUpdateHidden = true;
						case "Restart to finish": RestartToUpdate();
						case "Cancel": mUpdates.Cancel();
						case "Dismiss":
							mUpdates.Dismiss();
							mUpdateHidden = true;
						default:
						}
					}
					Gui.SameLine(0, spacing);
				}
				Gui.igDummy(.(1, 1));
				// 1 px separator under the notice line, like the toolbar's
				let wp = Gui.igGetWindowPos();
				let ws = Gui.igGetWindowSize();
				Gui.ImDrawList_AddLine(Gui.igGetWindowDrawList(), .(wp.x, wp.y + ws.y - 1), .(wp.x + ws.x, wp.y + ws.y - 1), Look.WindowBorder, 1);
			}
			Gui.End();
			Gui.igPopStyleColor(1);
			Gui.igPopStyleVar(2);
		}

		/// Editor Preferences > Updates.
		void DrawUpdatePrefs()
		{
			if (!PropertyGrid.Category("Updates", true, Icon.ArrowDownToLine))
				return;
			let s = mUpdateView;
			PropertyGrid.Row("Version", "The version of this copy (VERSION.txt beside the program)");
			PropertyGrid.Value((mUpdates != null && !mUpdates.Install.Version.IsEmpty) ? mUpdates.Install.Version : scope $"{VisualBeef.Document.VisualBeefInfo.Version} (development build)");
			PropertyGrid.Row("Check at Start", "Look for a new version a few seconds after VisualBeef starts, and once a day while it stays open. Off: only when you use Check Now or Help > Check for Updates.");
			bool changed = PropertyGrid.Bool("##updcheck", ref UpdatePrefs.CheckAtStart);
			PropertyGrid.Row("Channel", "Stable: published releases only. Preview: also pre-releases, which can be less finished.");
			StringView[2] channels = .("Stable", "Preview");
			if (PropertyGrid.Combo("##updchannel", ref UpdatePrefs.Channel, channels))
				changed = true;
			if (changed)
			{
				UpdatePrefs.Save();
				if (mUpdates != null)
					mUpdates.Channel.Set(UpdatePrefs.ChannelName);
			}
			PropertyGrid.Row("Status", "The last check");
			String state = scope .();
			String why = scope .();
			if (mUpdates != null)
				mUpdates.AutomaticBlocker(why);
			switch (s.State)
			{
			case .Idle: state.Set(why.IsEmpty ? "Not checked yet" : why);
			case .Checking: state.Set("Checking...");
			default: state.Set(s.Message.IsEmpty ? "Not checked yet" : s.Message);
			}
			PropertyGrid.WrappedValue(state);
			PropertyGrid.Row("Releases", "Where new versions are published");
			PropertyGrid.Value(UpdateService.DefaultRepository);
			PropertyGrid.WideRow();
			bool busy = mUpdates == null || mUpdates.Busy;
			if (busy)
				Gui.igBeginDisabled(true);
			if (Gui.Button("Check Now##updnow"))
				CheckForUpdatesNow();
			if (busy)
				Gui.igEndDisabled();
			Gui.SameLine();
			if (Gui.Button("Open Release Page##updpage"))
				OpenUrl(scope $"{UpdateService.DefaultRepository}/releases");
		}

		/// Self test `update-stage:<files folder>`: the end-to-end install of an extracted package (Restart to finish, the
		/// helper, the health check). Runs once per VB_HOME (a marker in the update folder), so the editor the helper starts
		/// with the same environment does not install again.
		void SelfTestUpdateStage(StringView filesDir)
		{
			if (mUpdates == null)
				return;
			String marker = scope .();
			UpdateApply.Join(marker, mUpdates.UpdateDir, "selftest-staged");
			if (File.Exists(marker))
			{
				String v = scope .();
				UpdateApply.ReadVersionFile(mUpdates.Install.Dir, v);
				Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] update-stage: already done; running {v}");
				return;
			}
			File.WriteAllText(marker, "1").IgnoreError(); // without it the restarted editor would install again
			String v = scope .();
			UpdateApply.ReadVersionFile(filesDir, v);
			mUpdates.StageForTest(filesDir, v, 2);
			mUpdates.GetStatus(mUpdateView);
			Notify.Log(.Info, "SelfTest", scope $"[SELFTEST] update-stage: {v} staged from {filesDir}; restarting");
			RestartToUpdate();
		}

		/// Self test steps for captures: `update:<state>` puts the notice line in a state without the network.
		void SelfTestUpdateState(StringView state)
		{
			if (mUpdates == null)
				return;
			mUpdateHidden = false;
			mUpdateBlocked.Clear();
			switch (state)
			{
			case "available": mUpdates.SetTestState(.Available, "0.2.0-alpha", "VisualBeef 0.2.0-alpha is available (this is 0.1.9-alpha).", 0, 0);
			case "downloading": mUpdates.SetTestState(.Downloading, "0.2.0-alpha", "", 4 * 1024 * 1024 + 300000, 11 * 1024 * 1024);
			case "verifying": mUpdates.SetTestState(.Verifying, "0.2.0-alpha", "Checking the download...", 11 * 1024 * 1024, 11 * 1024 * 1024);
			case "ready": mUpdates.SetTestState(.Ready, "0.2.0-alpha", "VisualBeef 0.2.0-alpha is downloaded and verified. Restart to finish.", 0, 0);
			case "unsaved":
				mUpdates.SetTestState(.Ready, "0.2.0-alpha", "VisualBeef 0.2.0-alpha is downloaded and verified. Restart to finish.", 0, 0);
				mUpdateBlocked.Set("Save your work first (2 unsaved files).");
			case "error": mUpdates.SetTestState(.Error, "0.2.0-alpha", "The update was refused: the download's SHA-256 does not match the signed release (the file was altered or damaged).", 0, 0);
			case "long":
				mUpdates.SetTestState(.Ready, "0.2.0-alpha", "", 0, 0);
				mUpdateBlocked.Set("The folder D:/Tools/VisualBeef/an/unusually/long/install/folder/name/for/this/capture cannot be written to (for example Program Files); unzip the new version by hand.");
			case "uptodate": mUpdates.SetTestState(.UpToDate, "", "VisualBeef 0.1.9-alpha is up to date (newest release: 0.1.9-alpha).", 0, 0);
			case "none": mUpdates.SetTestState(.Idle, "", "", 0, 0);
			default: SelfTestCheck(false, scope $"unknown update state {state}");
			}
		}
	}
}
