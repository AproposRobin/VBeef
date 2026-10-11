// Copyright 2026 AproposRobin. Licensed under the Apache License, Version 2.0 (LICENSE at the repository root).
// Mirrors UniversalUMP's launcher updater (src/Update, GitHub Releases variant; same owner, same licence).

using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

namespace VisualBeef.Update
{
	/// What kind of copy of the editor is running, and whether it may update itself.
	public class InstallInfo
	{
		public enum Kind
		{
			/// A packaged folder (Windows zip) the user may write to.
			Folder,
			/// The Linux AppImage ($APPIMAGE).
			AppImage,
			/// A Linux folder (the tarball): checks work, installing is by hand.
			LinuxFolder,
			/// No VERSION.txt beside the program: a build from source.
			Development,
			/// The copy UniversalUMP ships in tools\VisualBeef: the launcher updates it.
			Bundled
		}

		public Kind Kind;
		public String ExePath = new .() ~ delete _;
		public String Dir = new .() ~ delete _;
		/// The package version (first line of VERSION.txt), "" for a development build.
		public String Version = new .() ~ delete _;
		public String AppImagePath = new .() ~ delete _;
		/// No docs folder: the minimal (blank) package.
		public bool Minimal;

		public void Detect()
		{
			Environment.GetExecutableFilePath(ExePath);
			Path.GetDirectoryPath(ExePath, Dir).IgnoreError(); // no folder: stays empty, a development build below
			UpdateApply.ReadVersionFile(Dir, Version);
			String docs = scope .();
			UpdateApply.Join(docs, Dir, "docs");
			Minimal = !Directory.Exists(docs);
			Kind = .Folder;
#if !BF_PLATFORM_WINDOWS
			Kind = .LinuxFolder;
			if (Environment.GetEnvironmentVariable("APPIMAGE", AppImagePath) case .Ok && !AppImagePath.IsEmpty && File.Exists(AppImagePath))
				Kind = .AppImage;
			else
				AppImagePath.Clear();
#endif
			if (Version.IsEmpty)
				Kind = .Development;
			else if (IsBundled(Dir))
				Kind = .Bundled;
		}

		/// <root>\tools\VisualBeef with UnrealUMP.exe in <root>.
		public static bool IsBundled(StringView dir)
		{
			String d = scope .(dir);
			while (d.EndsWith('\\') || d.EndsWith('/'))
				d.RemoveFromEnd(1);
			String name = scope .();
			Path.GetFileName(d, name);
			if (!name.Equals("VisualBeef", .OrdinalIgnoreCase))
				return false;
			String tools = scope .();
			if (Path.GetDirectoryPath(d, tools) case .Err)
				return false;
			String toolsName = scope .();
			Path.GetFileName(tools, toolsName);
			if (!toolsName.Equals("tools", .OrdinalIgnoreCase))
				return false;
			String root = scope .();
			if (Path.GetDirectoryPath(tools, root) case .Err)
				return false;
			String launcher = scope .();
			UpdateApply.Join(launcher, root, "UnrealUMP.exe");
			return File.Exists(launcher);
		}

		/// True when a file can be created in the folder.
		public static bool CanWrite(StringView dir)
		{
			String probe = scope .();
			UpdateApply.Join(probe, dir, scope $".vb-write-test-{UpdateApply.CurrentPid()}");
			if (File.WriteAllText(probe, "x") case .Err)
				return false;
			File.Delete(probe).IgnoreError(); // a leftover probe is harmless
			return true;
		}
	}

	public enum UpdateState
	{
		Idle,
		/// Automatic and manual checks do not apply to this copy (Message says why).
		Unavailable,
		Checking,
		UpToDate,
		Available,
		Downloading,
		Verifying,
		/// Downloaded and verified: restart to finish.
		Ready,
		Error
	}

	/// A copy of the updater's state for the UI (UpdateService.GetStatus).
	public class UpdateStatus
	{
		public UpdateState State;
		public String Message = new .() ~ delete _;
		public String CurrentVersion = new .() ~ delete _;
		public String LatestVersion = new .() ~ delete _;
		public String Notes = new .() ~ delete _;
		public String NotesUrl = new .() ~ delete _;
		public int64 Received;
		public int64 Total;
		/// The last check was asked for by the user (results are reported, not only logged).
		public bool Manual;
		public int32 Serial;
	}

	/// The updater (docs/Updating.md for users, docs/Releasing.md for the release side). Every network and disk step
	/// runs on one worker thread; the UI reads GetStatus each frame and calls StartCheck / StartDownload / Apply.
	///
	/// Check: GET <repo>/releases/latest/download/release.json (stable), or for the preview channel the newest
	/// published release in the GitHub releases list, then its release.json. The descriptor must parse, verify against
	/// ReleaseKeys.Keys, carry the asked-for channel (preview accepts both) and be newer (UpdateRules.Decide).
	/// Download: <repo>/releases/download/<tag>/<asset> into <data>/update/staging/<version>/, size and sha256 checked,
	/// then (Windows) extracted with the system's tar and its layout and VERSION.txt checked. Apply: UpdateApply.
	public class UpdateService
	{
		public const StringView DefaultRepository = "https://github.com/AproposRobin/VBeef";
		public const StringView ApiRepository = "https://api.github.com/repos/AproposRobin/VBeef";

		/// <data>/update
		public String UpdateDir = new .() ~ delete _;
		public InstallInfo Install = new .() ~ delete _;
		/// "stable" or "preview".
		public String Channel = new .("stable") ~ delete _;
		/// Called from the worker thread with one log line (thread-safe sink expected).
		public delegate void(StringView) OnLog ~ delete _;
		/// Trusted keys (tests pass their own).
		public String Keys = new .(ReleaseKeys.Keys) ~ delete _;

		Monitor mLock = new .() ~ delete _;
		Thread mThread;
		bool mCancel;
		UpdateStatus mStatus = new .() ~ delete _;
		ReleaseDescriptor mLatest ~ delete _;
		ReleaseAsset mAsset;
		String mStagedDir = new .() ~ delete _;
		String mStagedFile = new .() ~ delete _;

		public this()
		{
		}

		public ~this()
		{
			mCancel = true;
			if (mThread != null)
			{
				mThread.Join();
				delete mThread;
			}
		}

		void Log(StringView line)
		{
			if (OnLog != null)
				OnLog(line);
		}

		public void Init(StringView updateDir)
		{
			UpdateDir.Set(updateDir);
			UpdateApply.EnsureDir(UpdateDir);
			Install.Detect();
			mStatus.CurrentVersion.Set(Install.Version.IsEmpty ? VisualBeef.Document.VisualBeefInfo.Version : Install.Version);
			// Staging of the version now running is no longer needed.
			String staging = scope .();
			UpdateApply.Join(staging, UpdateDir, "staging");
			if (Directory.Exists(staging))
			{
				String mine = scope .();
				UpdateApply.Join(mine, staging, Install.Version);
				if (!Install.Version.IsEmpty && Directory.Exists(mine))
					UpdateApply.DeletePath(mine);
			}
		}

		/// Why this copy does not update itself automatically ("" when it does).
		public void AutomaticBlocker(String outWhy)
		{
			switch (Install.Kind)
			{
			case .Development: outWhy.Set("This is a development build (no VERSION.txt beside the program), so it does not look for updates by itself.");
			case .Bundled: outWhy.Set("This copy of VisualBeef came with UniversalUMP; the UniversalUMP launcher updates it.");
			default:
				if (!ReleaseDescriptor.HasKeys(Keys))
					outWhy.Set("Updates are not set up in this build. New versions are on the VisualBeef release page.");
			}
		}

		public bool Busy
		{
			get
			{
				using (mLock.Enter())
					return mStatus.State == .Checking || mStatus.State == .Downloading || mStatus.State == .Verifying;
			}
		}

		public void GetStatus(UpdateStatus outStatus)
		{
			using (mLock.Enter())
			{
				outStatus.State = mStatus.State;
				outStatus.Message.Set(mStatus.Message);
				outStatus.CurrentVersion.Set(mStatus.CurrentVersion);
				outStatus.LatestVersion.Set(mStatus.LatestVersion);
				outStatus.Notes.Set(mStatus.Notes);
				outStatus.NotesUrl.Set(mStatus.NotesUrl);
				outStatus.Received = mStatus.Received;
				outStatus.Total = mStatus.Total;
				outStatus.Manual = mStatus.Manual;
				outStatus.Serial = mStatus.Serial;
			}
		}

		void SetState(UpdateState state, StringView message = "")
		{
			using (mLock.Enter())
			{
				mStatus.State = state;
				mStatus.Message.Set(message);
				mStatus.Serial++;
			}
		}

		/// Forgets a shown result (Later / Dismiss): back to Idle unless something is running or staged.
		public void Dismiss()
		{
			using (mLock.Enter())
			{
				if (mStatus.State == .Error || mStatus.State == .UpToDate || mStatus.State == .Unavailable || mStatus.State == .Available)
				{
					mStatus.State = .Idle;
					mStatus.Message.Clear();
					mStatus.Serial++;
				}
			}
		}

		bool StartWorker(delegate void() work)
		{
			if (mThread != null)
			{
				if (mThread.IsAlive)
				{
					delete work;
					return false;
				}
				mThread.Join();
				DeleteAndNullify!(mThread);
			}
			mCancel = false;
			mThread = new Thread(new () =>
			{
				work();
				delete work;
			});
			mThread.SetName("VisualBeef updater");
			mThread.Start(false);
			return true;
		}

		/// Starts a check on the worker. `manual` = asked for by the user. False when one is already running.
		public bool StartCheck(bool manual)
		{
			using (mLock.Enter())
			{
				if (mStatus.State == .Checking || mStatus.State == .Downloading || mStatus.State == .Verifying)
					return false;
				if (mStatus.State == .Ready)
					return false;
				mStatus.Manual = manual;
				mStatus.State = .Checking;
				mStatus.Message.Clear();
				mStatus.Serial++;
			}
			return StartWorker(new () => DoCheck(manual));
		}

		public bool StartDownload()
		{
			using (mLock.Enter())
			{
				if (mStatus.State != .Available && mStatus.State != .Error)
					return false;
				if (mLatest == null || mAsset == null)
					return false;
				mStatus.State = .Downloading;
				mStatus.Received = 0;
				mStatus.Total = mAsset.Size;
				mStatus.Message.Clear();
				mStatus.Serial++;
			}
			return StartWorker(new () => DoDownload());
		}

		/// Editor self tests only (captures of the notice line): puts the status in a state without the network.
		public void SetTestState(UpdateState state, StringView latest, StringView message, int64 received, int64 total)
		{
			using (mLock.Enter())
			{
				mStatus.State = state;
				mStatus.LatestVersion.Set(latest);
				mStatus.Message.Set(message);
				mStatus.Received = received;
				mStatus.Total = total;
				mStatus.Manual = false;
				mStatus.Notes.Set("Test notes for the capture.");
				mStatus.NotesUrl.Set(scope $"{DefaultRepository}/releases");
				mStatus.Serial++;
			}
		}

		/// Editor self tests only: marks an extracted package folder as the verified update (no network, no signature:
		/// the end-to-end test of Restart to finish, the helper, the health check and the rollback).
		public void StageForTest(StringView filesDir, StringView version, int64 sequence)
		{
			using (mLock.Enter())
			{
				delete mLatest;
				mLatest = new .();
				mLatest.Version.Set(version);
				mLatest.Sequence = sequence;
				mStagedDir.Set(filesDir);
				mStagedFile.Set(filesDir);
				mStatus.State = .Ready;
				mStatus.LatestVersion.Set(version);
				mStatus.Message.Set(scope $"VisualBeef {version} is downloaded and verified. Restart to finish.");
				mStatus.Serial++;
			}
			String parent = scope .();
			Path.GetDirectoryPath(filesDir, parent).IgnoreError(); // ready.json sits beside the files folder
			String ready = scope .();
			UpdateApply.Join(ready, parent, "ready.json");
			File.WriteAllText(ready, scope $"{{\"version\": \"{version}\", \"sequence\": {sequence}}}").IgnoreError(); // the helper records the sequence from it
		}

		public void Cancel()
		{
			mCancel = true;
		}

		// ------------------------------------------------------------------ check

		static void RepoBase(String outBase)
		{
			String env = scope .();
			if (Environment.GetEnvironmentVariable("VB_UPDATE_REPOSITORY", env) case .Ok && env.StartsWith("https://github.com/"))
			{
				env.Trim();
				while (env.EndsWith('/'))
					env.RemoveFromEnd(1);
				outBase.Set(env);
				return;
			}
			outBase.Set(DefaultRepository);
		}

		/// GET with the ETag cache: `<update>/cache/<name>` holds the last body, `<name>.etag` its ETag.
		bool FetchCached(StringView url, StringView name, bool api, int64 maxBytes, String outBody, String outReason, out UpdateHttp.Outcome outcome, out int32 status)
		{
			String cacheDir = scope .();
			UpdateApply.Join(cacheDir, UpdateDir, "cache");
			UpdateApply.EnsureDir(cacheDir);
			String bodyPath = scope .();
			UpdateApply.Join(bodyPath, cacheDir, name);
			String etagPath = scope .();
			etagPath.AppendF("{}.etag", bodyPath);
			String etag = scope .();
			if (File.Exists(bodyPath))
				File.ReadAllText(etagPath, etag).IgnoreError(); // no ETag: a plain GET
			etag.Trim();
			String tmp = scope .();
			tmp.AppendF("{}.download", bodyPath);
			File.Delete(tmp).IgnoreError(); // stale scratch file
			UpdateHttp.Response r = scope .();
			UpdateHttp.Get(url, tmp, etag, maxBytes, 5, 20, api, r, null, &mCancel);
			outcome = r.Outcome;
			status = r.Status;
			defer { File.Delete(tmp).IgnoreError(); } // scratch file
			if (r.Outcome != .Ok)
			{
				switch (r.Outcome)
				{
				case .NoClient: outReason.Set("no curl program was found on this system");
				case .Unreachable: outReason.Set("the update server could not be reached");
				case .TooLarge: outReason.Set("the answer was larger than expected");
				case .Cancelled: outReason.Set("cancelled");
				default: outReason.Set(scope $"the download tool failed (code {r.CurlExit})");
				}
				return false;
			}
			if (r.Status == 304 && File.ReadAllText(bodyPath, outBody) case .Ok)
				return true;
			if (r.Status != 200)
			{
				outReason.Set(scope $"the server answered {r.Status}");
				return false;
			}
			if (File.ReadAllText(tmp, outBody) case .Err)
			{
				outReason.Set("the answer could not be read");
				return false;
			}
			File.WriteAllText(bodyPath, outBody).IgnoreError(); // cache only
			if (!r.ETag.IsEmpty)
				File.WriteAllText(etagPath, r.ETag).IgnoreError();
			else
				File.Delete(etagPath).IgnoreError();
			return true;
		}

		/// The tag of the newest published release (preview channel), from the GitHub releases list: the first entry that
		/// is not a draft and carries a release.json.
		public static bool PickPreviewTag(StringView listJson, String outTag)
		{
			if (!(UpdateJson.Parse(listJson) case .Ok(let list)))
				return false;
			defer delete list;
			if (!list.IsArray)
				return false;
			for (let rel in list.Items)
			{
				if (!rel.IsObject || rel.GetBool("draft", true))
					continue;
				String tag = scope .();
				if (!rel.GetString("tag_name", tag) || !ReleaseDescriptor.IsSafeSegment(tag))
					continue;
				let assets = rel.Get("assets");
				if (assets == null || !assets.IsArray)
					continue;
				for (let a in assets.Items)
				{
					String n = scope .();
					if (a.IsObject && a.GetString("name", n) && n == "release.json")
					{
						outTag.Set(tag);
						return true;
					}
				}
			}
			return false;
		}

		void Finish(UpdateState state, StringView message)
		{
			SetState(state, message);
			Log(message);
		}

		void DoCheck(bool manual)
		{
			if (!ReleaseDescriptor.HasKeys(Keys))
			{
				Finish(.Unavailable, "Updates are not set up in this build. New versions are on the VisualBeef release page.");
				return;
			}
			String repo = scope .();
			RepoBase(repo);
			String url = scope .();
			String body = scope .();
			String reason = scope .();
			bool preview = Channel == "preview";
			UpdateHttp.Outcome outcome;
			int32 status;
			String tag = scope .();
			if (preview)
			{
				String api = scope .(ApiRepository);
				if (repo != DefaultRepository)
					api.Set(scope $"https://api.github.com/repos/{repo.Substring("https://github.com/".Length)}");
				url.AppendF("{}/releases?per_page=15", api);
				String list = scope .();
				if (!FetchCached(url, "releases-list.json", true, 4 * 1024 * 1024, list, reason, out outcome, out status))
				{
					CheckFailed(manual, outcome, reason);
					return;
				}
				if (!PickPreviewTag(list, tag))
				{
					Finish(.UpToDate, "No VisualBeef release is published yet.");
					return;
				}
				url.Clear();
				url.AppendF("{}/releases/download/{}/release.json", repo, tag);
				if (!FetchCached(url, "release-preview.json", false, ReleaseDescriptor.MaxBytes, body, reason, out outcome, out status))
				{
					CheckFailed(manual, outcome, reason);
					return;
				}
			}
			else
			{
				url.AppendF("{}/releases/latest/download/release.json", repo);
				if (!FetchCached(url, "release-stable.json", false, ReleaseDescriptor.MaxBytes, body, reason, out outcome, out status))
				{
					if (outcome == .Ok && status == 404)
					{
						Finish(.UpToDate, "No VisualBeef release is published yet.");
						return;
					}
					CheckFailed(manual, outcome, reason);
					return;
				}
			}

			ReleaseDescriptor desc;
			switch (ReleaseDescriptor.Parse(body, reason))
			{
			case .Ok(let d): desc = d;
			case .Err:
				Finish(.Error, scope $"The update was refused: {reason}.");
				return;
			}
			if (!desc.Verify(reason, Keys))
			{
				Finish(.Error, scope $"The update was refused: {reason}.");
				delete desc;
				return;
			}
			if (!preview && desc.Channel != "stable")
			{
				Finish(.Error, "The update was refused: the newest release is not on the stable channel.");
				delete desc;
				return;
			}
			String running = scope .(Install.Version.IsEmpty ? VisualBeef.Document.VisualBeefInfo.Version : Install.Version);
			let runningSeq = UpdateApply.ReadInstalledSequence(UpdateDir, running);
			if (UpdateRules.Decide(running, runningSeq, desc) == .NotNewer)
			{
				Finish(.UpToDate, scope $"VisualBeef {running} is up to date (newest release: {desc.Version}).");
				delete desc;
				return;
			}
			List<StringView> keys = scope .();
			UpdateRules.PlatformKeys(Install.Minimal, Install.Kind == .AppImage, keys);
			let asset = desc.SelectAsset(keys);
			using (mLock.Enter())
			{
				delete mLatest;
				mLatest = desc;
				mAsset = asset;
				mStatus.LatestVersion.Set(desc.Version);
				mStatus.Notes.Set(desc.Notes);
				mStatus.NotesUrl.Clear();
				mStatus.NotesUrl.AppendF("{}/releases/tag/{}", repo, desc.Tag);
			}
			Finish(.Available, scope $"VisualBeef {desc.Version} is available (this is {running}).");
		}

		void CheckFailed(bool manual, UpdateHttp.Outcome outcome, StringView reason)
		{
			if (outcome == .Unreachable || outcome == .NoClient)
			{
				// Offline or air-gapped: one log line; a manual check says so, an automatic one stays quiet.
				Log(scope $"Update check skipped: {reason}");
				SetState(manual ? .Error : .Idle, manual ? scope $"Could not check for updates: {reason}." : "");
				return;
			}
			Finish(.Error, scope $"Could not check for updates: {reason}.");
		}

		// ------------------------------------------------------------------ download

		public static bool Sha256OfFile(StringView path, String outHex)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .Read) case .Err)
				return false;
			SHA256 sha = scope .();
			uint8[65536] buf = ?;
			while (true)
			{
				switch (fs.TryRead(.(&buf[0], buf.Count)))
				{
				case .Ok(let n):
					if (n == 0)
					{
						let hash = sha.Finish();
						for (let b in hash.mHash)
						{
							outHex.Append("0123456789abcdef"[b >> 4]);
							outHex.Append("0123456789abcdef"[b & 15]);
						}
						return true;
					}
					sha.Update(.(&buf[0], n));
				case .Err:
					return false;
				}
			}
		}

		/// Checks a downloaded file against the signed size and sha256.
		public static bool CheckFile(StringView path, ReleaseAsset asset, String outReason)
		{
			FileStream fs = scope .();
			if (fs.Open(path, .Read, .Read) case .Err)
			{
				outReason.Set("the download could not be read");
				return false;
			}
			let len = fs.Length;
			fs.Close();
			if (len != asset.Size)
			{
				outReason.Set(scope $"the download has {len} bytes, the signed release says {asset.Size}");
				return false;
			}
			String hex = scope .();
			if (!Sha256OfFile(path, hex))
			{
				outReason.Set("the download could not be read");
				return false;
			}
			if (hex != asset.Sha256)
			{
				outReason.Set("the download's SHA-256 does not match the signed release (the file was altered or damaged)");
				return false;
			}
			return true;
		}

		/// The extracted Windows package must hold the editor, its host library and the release's VERSION.txt.
		public static bool CheckLayout(StringView dir, StringView version, String outReason)
		{
			StringView[4] required = .("VisualBeefEditor.exe", "vbhost.dll", "VERSION.txt", "LICENSE");
			for (let name in required)
			{
				String p = scope .();
				UpdateApply.Join(p, dir, name);
				if (!File.Exists(p))
				{
					outReason.Set(scope $"the package has no {name}");
					return false;
				}
			}
			String v = scope .();
			UpdateApply.ReadVersionFile(dir, v);
			if (v != version)
			{
				outReason.Set(scope $"the package says it is {v}, the signed release says {version}");
				return false;
			}
			return true;
		}

		static bool Extract(StringView zip, StringView dir, String outReason)
		{
#if BF_PLATFORM_WINDOWS
			String root = scope .();
			if (Environment.GetEnvironmentVariable("SystemRoot", root) case .Err || root.IsEmpty)
				root.Set("C:\\Windows");
			String tar = scope .();
			tar.AppendF("{}\\System32\\tar.exe", root);
			if (!File.Exists(tar))
			{
				outReason.Set("this system has no tar program to unpack the update");
				return false;
			}
			UpdateApply.EnsureDir(dir);
			ProcessStartInfo psi = scope .();
			psi.SetFileName(tar);
			psi.SetArguments(scope $"-xf \"{zip}\" -C \"{dir}\"");
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				outReason.Set("tar could not be started");
				return false;
			}
			if (!proc.WaitFor(300000) || proc.ExitCode != 0)
			{
				outReason.Set("the update package could not be unpacked");
				return false;
			}
			return true;
#else
			outReason.Set("unpacking is only needed on Windows");
			return false;
#endif
		}

		void DoDownload()
		{
			ReleaseDescriptor desc;
			ReleaseAsset asset;
			using (mLock.Enter())
			{
				desc = mLatest;
				asset = mAsset;
			}
			if (asset == null)
			{
				Finish(.Error, "This release has no package for this system; download it from the release page.");
				return;
			}
			String repo = scope .();
			RepoBase(repo);
			String dir = scope .();
			UpdateApply.Join(dir, UpdateDir, "staging");
			UpdateApply.Join(dir, scope String(dir), desc.Version);
			UpdateApply.DeletePath(dir);
			UpdateApply.EnsureDir(dir);
			String part = scope .();
			UpdateApply.Join(part, dir, scope $"{asset.Name}.part");
			String url = scope $"{repo}/releases/download/{desc.Tag}/{asset.Name}";
			Log(scope $"Downloading {url}");
			UpdateHttp.Response r = scope .();
			delegate void(int64) progress = scope (n) =>
			{
				using (mLock.Enter())
				{
					mStatus.Received = n;
					mStatus.Serial++;
				}
			};
			UpdateHttp.Get(url, part, "", asset.Size, 15, 0, false, r, progress, &mCancel);
			if (r.Outcome == .Cancelled)
			{
				UpdateApply.DeletePath(dir);
				using (mLock.Enter())
				{
					mStatus.State = .Available;
					mStatus.Message.Set("Download cancelled.");
					mStatus.Serial++;
				}
				return;
			}
			if (r.Outcome != .Ok || r.Status != 200)
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, (r.Outcome == .Unreachable) ? "The download failed: the server could not be reached." :
					(r.Outcome == .TooLarge) ? "The download was refused: it is larger than the signed release says." :
					scope $"The download failed (code {r.CurlExit}, answer {r.Status}).");
				return;
			}
			SetState(.Verifying, "Checking the download...");
			String reason = scope .();
			if (!CheckFile(part, asset, reason))
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, scope $"The update was refused: {reason}.");
				return;
			}
			String file = scope .();
			UpdateApply.Join(file, dir, asset.Name);
			if (File.Move(part, file) case .Err)
			{
				Finish(.Error, "The download could not be moved into place.");
				return;
			}
			String files = scope .();
			UpdateApply.Join(files, dir, "files");
#if BF_PLATFORM_WINDOWS
			if (!Extract(file, files, reason) || !CheckLayout(files, desc.Version, reason))
			{
				UpdateApply.DeletePath(dir);
				Finish(.Error, scope $"The update was refused: {reason}.");
				return;
			}
#else
			UpdateApply.MakeRunnable(file);
#endif
			String ready = scope .();
			ready.Append("{\"version\": ");
			UpdateJson.WriteString(desc.Version, ready);
			ready.AppendF(", \"sequence\": {}, \"platform\": ", desc.Sequence);
			UpdateJson.WriteString(asset.Platform, ready);
			ready.Append(", \"file\": ");
			UpdateJson.WriteString(asset.Name, ready);
			ready.Append("}\n");
			String readyPath = scope .();
			UpdateApply.Join(readyPath, dir, "ready.json");
			File.WriteAllText(readyPath, ready).IgnoreError(); // only the helper's sequence record needs it
			using (mLock.Enter())
			{
				mStagedDir.Set(files);
				mStagedFile.Set(file);
			}
			Finish(.Ready, scope $"VisualBeef {desc.Version} is downloaded and verified. Restart to finish.");
		}

		// ------------------------------------------------------------------ apply

		/// Why installing is refused right now ("" when it can go ahead). `unsaved` = sheets with unsaved changes.
		public void ApplyBlocker(int unsaved, bool busy, String outWhy)
		{
			if (unsaved > 0)
			{
				outWhy.Set(scope $"Save your work first ({unsaved} unsaved {(unsaved == 1) ? "file" : "files"}).");
				return;
			}
			if (busy)
			{
				outWhy.Set("Wait for the compile or the debugging session to end first.");
				return;
			}
			switch (Install.Kind)
			{
			case .Development: outWhy.Set("This is a development build; updates install only into a packaged copy.");
			case .Bundled: outWhy.Set("This copy came with UniversalUMP; the launcher updates it.");
			case .LinuxFolder: outWhy.Set("Updates install into the AppImage only. Download the new tarball from the release page.");
			case .AppImage:
				String dir = scope .();
				Path.GetDirectoryPath(Install.AppImagePath, dir).IgnoreError(); // checked by CanWrite
				if (!InstallInfo.CanWrite(dir))
					outWhy.Set(scope $"The folder {dir} cannot be written to; download the new AppImage by hand.");
			case .Folder:
				if (!InstallInfo.CanWrite(Install.Dir))
					outWhy.Set(scope $"The folder {Install.Dir} cannot be written to (for example Program Files); unzip the new version by hand.");
			}
		}

		/// Starts the install of the staged update. On success the caller closes the editor at once (Windows: the helper
		/// is waiting for it; Linux: the new AppImage is already started).
		public bool Apply(String outReason)
		{
			String staged = scope .();
			String stagedFile = scope .();
			String version = scope .();
			int64 sequence = 0;
			using (mLock.Enter())
			{
				if (mStatus.State != .Ready || mLatest == null)
				{
					outReason.Set("No verified update is waiting.");
					return false;
				}
				staged.Set(mStagedDir);
				stagedFile.Set(mStagedFile);
				version.Set(mLatest.Version);
				sequence = mLatest.Sequence;
			}
#if BF_PLATFORM_WINDOWS
			String helperDir = scope .();
			UpdateApply.Join(helperDir, UpdateDir, "helper");
			UpdateApply.DeletePath(helperDir);
			UpdateApply.EnsureDir(helperDir);
			String helperExe = scope .();
			UpdateApply.Join(helperExe, helperDir, "VisualBeefEditor.exe");
			String hostDll = scope .();
			UpdateApply.Join(hostDll, Install.Dir, "vbhost.dll");
			String helperDll = scope .();
			UpdateApply.Join(helperDll, helperDir, "vbhost.dll");
			if (!UpdateApply.CopyFile(Install.ExePath, helperExe) || !UpdateApply.CopyFile(hostDll, helperDll))
			{
				outReason.Set("The update helper could not be prepared.");
				return false;
			}
			ProcessStartInfo psi = scope .();
			psi.SetFileName(helperExe);
			psi.SetArguments(scope $"{UpdateApply.HelperSwitch} \"{Install.Dir}\" {UpdateApply.CurrentPid()} \"{staged}\" \"{UpdateDir}\"");
			psi.SetWorkingDirectory(helperDir);
			psi.UseShellExecute = false;
			psi.CreateNoWindow = true;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				outReason.Set("The update helper could not be started.");
				return false;
			}
			Log(scope $"Update helper started for {version}; closing the editor");
			return true;
#else
			// Linux AppImage: keep a copy of the running file, then rename the new one over it (the running copy stays
			// mounted until this process exits) and start it.
			let target = Install.AppImagePath;
			String name = scope .();
			Path.GetFileName(target, name);
			String previous = scope .();
			UpdateApply.Join(previous, UpdateDir, "previous");
			UpdateApply.DeletePath(previous);
			UpdateApply.EnsureDir(previous);
			String keep = scope .();
			UpdateApply.Join(keep, previous, name);
			if (!UpdateApply.CopyFile(target, keep))
			{
				outReason.Set("A copy of the running AppImage could not be kept, so nothing was changed.");
				return false;
			}
			String dir = scope .();
			Path.GetDirectoryPath(target, dir).IgnoreError(); // CanWrite checked it
			String tmp = scope .();
			UpdateApply.Join(tmp, dir, scope $".{name}.new");
			if (!UpdateApply.CopyFile(stagedFile, tmp) || !UpdateApply.MakeRunnable(tmp) || (File.Move(tmp, target) case .Err))
			{
				File.Delete(tmp).IgnoreError(); // the running AppImage is untouched
				outReason.Set("The new AppImage could not be put in place; nothing was changed.");
				return false;
			}
			UpdateApply.WriteInstalled(UpdateDir, version, sequence);
			UpdateApply.WriteResult(UpdateDir, true, Install.Version, version, scope $"VisualBeef was updated to {version}.");
			ProcessStartInfo psi = scope .();
			psi.SetFileName(target);
			psi.UseShellExecute = false;
			SpawnedProcess proc = scope .();
			if (proc.Start(psi) case .Err)
			{
				outReason.Set(scope $"VisualBeef {version} is installed but could not be started; start it again by hand.");
				return false;
			}
			Log(scope $"Installed {version} into {target}; restarting");
			return true;
#endif
		}

		/// The outcome an update left for this start (last-result.json), read once and deleted. False when none.
		public bool TakeLastResult(out bool ok, String outMessage)
		{
			ok = false;
			String p = scope .();
			UpdateApply.Join(p, UpdateDir, "last-result.json");
			String text = scope .();
			if (File.ReadAllText(p, text) case .Err)
				return false;
			File.Delete(p).IgnoreError(); // shown once
			if (!(UpdateJson.Parse(text) case .Ok(let j)))
				return false;
			defer delete j;
			ok = j.GetBool("ok", false);
			j.GetString("message", outMessage);
			return !outMessage.IsEmpty;
		}
	}
}
